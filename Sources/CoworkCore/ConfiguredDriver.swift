import Foundation

/// The single, descriptor-driven `OneShotDriver`. It replaces the three hand-written
/// drivers with one interpreter: `invocation` assembles argv/stdin/env from the
/// descriptor, `parse` runs the selected output extractor and then calls the real
/// `Verdict.*` function for the selected strategy. It does NOT reimplement verdict
/// logic — config picks a tested rule, never authors one (ADR 000).
///
/// Substitution is whole-arg exact-token: an argv element that is *exactly* `{task}`,
/// `{workspace}` or `{resume}` is replaced; an element that merely contains such text
/// is left verbatim, and the process is exec'd via posix_spawn (no shell), so a task
/// value can never inject an argument or a command.
//: @use-case:cli.generic.wired_from_config_alone#descriptor_interpreter
public struct ConfiguredDriver: OneShotDriver {
    public let name: String
    public let executable: URL
    public let descriptor: CliDescriptor

//: @use-case:end cli.generic.wired_from_config_alone#descriptor_interpreter
    public init(name: String, executable: URL, descriptor: CliDescriptor) {
        self.name = name
        self.executable = executable
        self.descriptor = descriptor
    }

    public var deadlineDiagnostic: String { descriptor.deadlineDiagnostic }

    public func prepareIsolation() -> IsolationHandle? {
        guard let isolate = descriptor.isolate else { return nil }
        return IsolationHandle.make(variable: isolate.variable, seed: isolate.seed)
    }

    public func invocation(task: String, workspace: Workspace?, resume: String?) -> Invocation {
        let ws = workspace?.root.path
        var arguments = substitute(descriptor.baseArguments, task: task, workspace: ws, resume: resume)
        if workspace != nil, !descriptor.workspaceArguments.isEmpty {
            arguments += substitute(descriptor.workspaceArguments, task: task, workspace: ws, resume: resume)
        }
        if let resume, !descriptor.resumeArguments.isEmpty {
            arguments += substitute(descriptor.resumeArguments, task: task, workspace: ws, resume: resume)
        }

        let stdin: Data?
        switch descriptor.taskDelivery {
        case .argv:
            stdin = nil
        case .stdinRaw:
            stdin = Data(task.utf8)
        case .stdinJSONStreamUser:
            // Claude's exact one-shot envelope. Built key-for-key as the oracle did,
            // so JSONSerialization emits identical bytes.
            let message: [String: Any] = [
                "type": "user",
                "message": ["role": "user", "content": [["type": "text", "text": task]]],
            ]
            stdin = (try? JSONSerialization.data(withJSONObject: message)).map { $0 + Data("\n".utf8) }
        }

//: @use-case:cli.generic.env_reference_is_a_pointer_never_a_secret#env_pointer
        var extraEnvironment = descriptor.env.map { entry -> String in
            switch entry.value {
            case let .literal(v): return "\(entry.key)=\(v)"
            case let .reference(name):
                // A pointer, never a secret: resolve from cowork's own environment at
                // dispatch. An unset reference becomes empty rather than leaking the name.
                return "\(entry.key)=\(ProcessInfo.processInfo.environment[name] ?? "")"
            }
        }
//: @use-case:end cli.generic.env_reference_is_a_pointer_never_a_secret#env_pointer
        if descriptor.prependExeDirToPath {
            let binDir = executable.deletingLastPathComponent().path
            extraEnvironment.append("PATH=\(binDir):/usr/bin:/bin:/usr/sbin:/sbin")
        }

        return Invocation(arguments: arguments, stdin: stdin, extraEnvironment: extraEnvironment)
    }

    public func parse(output: Data, exitStatus: Int32) -> CliOutcome {
        let exitCode = (exitStatus & 0x7f) == 0 ? (exitStatus >> 8) & 0xff : -1
        let signals = extract(output)
        let verdict: (state: DispatchRecord.State, diagnostics: [String])
        switch descriptor.verdict {
        case .exitCodeOnly:
            verdict = Verdict.exitOnly(cliName: name, exitCode: exitCode)
        case .claudeDeclared:
            verdict = Verdict.cli(declaredSubtype: signals.subtype, isError: signals.isError, exitCode: exitCode)
        case .grokStopReason:
            verdict = Verdict.grok(stopReason: signals.stopReason, exitCode: exitCode)
        }
        return CliOutcome(state: verdict.state, text: signals.text,
                          diagnostics: verdict.diagnostics + signals.extraDiagnostics,
                          transcript: signals.transcript, continuation: signals.continuation)
    }

    // MARK: output extraction

    private struct Signals {
        var text = ""
        var transcript = ""
        var continuation: String?
        var subtype: String?
        var isError = false
        var stopReason: String?
        var extraDiagnostics: [String] = []
    }

    private func extract(_ output: Data) -> Signals {
        switch descriptor.output {
        case .raw: return extractRaw(output)
        case let .jsonField(field): return extractJSONField(output, field: field)
        case .streamJSONResult: return extractStreamJSONResult(output)
        }
    }

    /// Codex's shape: the whole stdout is the answer; the exit code is the only signal.
    private func extractRaw(_ output: Data) -> Signals {
        let text = String(decoding: output, as: UTF8.self)
        return Signals(text: text, transcript: String(text.prefix(2000)))
    }

    /// Grok's shape: the last well-formed JSON object; `field` holds the answer,
    /// `stopReason` the declaration, `continuationField` the resume handle. Tolerates
    /// preamble by scanning for the last top-level object.
    private func extractJSONField(_ output: Data, field: String) -> Signals {
        guard let obj = lastJSONObject(in: output) else {
            return Signals(transcript: String(String(decoding: output, as: UTF8.self).prefix(2000)),
                           extraDiagnostics: ["cli.\(name).unparseable-output"])
        }
        var s = Signals()
        s.text = (obj[field] as? String) ?? ""
        s.stopReason = obj["stopReason"] as? String
        if let cf = descriptor.continuationField { s.continuation = obj[cf] as? String }
        if let thought = obj["thought"] as? String, !thought.isEmpty { s.transcript += "thinking: \(thought)\n" }
        if !s.text.isEmpty { s.transcript += "said: \(s.text)\n" }
        return s
    }

    /// Claude's shape: a stream of JSON events; assistant text builds the transcript,
    /// the final `result` object carries the answer + declaration, `session_id` (last
    /// non-empty) is the continuation.
    private func extractStreamJSONResult(_ output: Data) -> Signals {
        var s = Signals()
        var result = ""
        let text = String(decoding: output, as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let id = obj["session_id"] as? String, !id.isEmpty { s.continuation = id }
            switch obj["type"] as? String {
            case "assistant":
                if let msg = obj["message"] as? [String: Any],
                   let content = msg["content"] as? [[String: Any]] {
                    for c in content where c["type"] as? String == "text" {
                        let t = (c["text"] as? String) ?? ""
                        if !t.isEmpty { s.transcript += "said: \(t)\n" }
                    }
                }
            case "result":
                s.subtype = (obj["subtype"] as? String) ?? "<absent>"
                s.isError = (obj["is_error"] as? Bool) ?? false
                result = (obj["result"] as? String) ?? result
            default:
                break
            }
        }
        s.text = result
        return s
    }

    /// The last brace-delimited JSON object in the output: the whole thing first (the
    /// common single-object case), then the last `{`-to-end, tolerating preamble.
    private func lastJSONObject(in output: Data) -> [String: Any]? {
        let text = String(decoding: output, as: UTF8.self)
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        guard let firstBrace = text.firstIndex(of: "{") else { return nil }
        let candidate = String(text[firstBrace...])
        if let data = candidate.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        return nil
    }

//: @use-case:cli.generic.task_value_cannot_inject_an_argument_or_a_command#whole_arg_substitution
    private func substitute(_ args: [String], task: String, workspace: String?, resume: String?) -> [String] {
        args.map { arg in
            switch arg {
            case "{task}": return task
            case "{workspace}": return workspace ?? arg
            case "{resume}": return resume ?? arg
            default: return arg   // whole-arg only: a value containing a token is inert
            }
        }
    }
//: @use-case:end cli.generic.task_value_cannot_inject_an_argument_or_a_command#whole_arg_substitution
}

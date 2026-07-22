import Foundation

/// Grok's one-shot wire, lifted verbatim from `GrokBackend`.
///
/// Grok speaks a different one-shot protocol from claude's stream-json: the task is
/// a command-line argument (`grok -p "<task>"`) and the result is a single JSON
/// object (`--output-format json`) rather than a stream of events. The verdict
/// still lives in the core — grok declares a `stopReason`, and `Verdict.grok`
/// decides what it means beside the exit code.
public struct GrokOneShotDriver: OneShotDriver {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    public var deadlineDiagnostic: String { "cli.grok.deadline" }

    public func invocation(task: String, workspace: Workspace?, resume: String?) -> Invocation {
        var arguments = ["-p", task, "--output-format", "json", "--no-auto-update"]
        // The worker owns its loop and tools (ADR 000); cowork does not approve them
        // turn by turn, so auto-approve — the dispatch is already contained.
        arguments += ["--always-approve"]
        if let workspace { arguments += ["--cwd", workspace.root.path] }
        if let resume { arguments += ["-r", resume] }

        // grok reads its cached subscription token from ~/.grok/auth.json (HOME is in
        // the shared allowlist); its own binary dir is added to PATH in case it
        // shells out to helpers. Overrides the base PATH entry.
        let grokBin = executable.deletingLastPathComponent().path
        let path = "PATH=\(grokBin):/usr/bin:/bin:/usr/sbin:/sbin"

        // The task is an argument, not stdin — so nothing is written to stdin.
        return Invocation(arguments: arguments, stdin: nil, extraEnvironment: [path])
    }

    /// Grok prints one JSON object: `{ "text", "stopReason", "sessionId", ... }`.
    /// The verdict comes from `stopReason` (via the core), the answer from `text`,
    /// and the continuation handle from `sessionId`.
    public func parse(output: Data, exitStatus: Int32) -> CliOutcome {
        let exitCode = (exitStatus & 0x7f) == 0 ? (exitStatus >> 8) & 0xff : -1

        // Grok may print human chatter before the JSON object under some flags, so
        // parse the last well-formed JSON object rather than assuming the whole
        // stream is it.
        guard let obj = lastJSONObject(in: output) else {
            let verdict = Verdict.grok(stopReason: nil, exitCode: exitCode)
            return CliOutcome(state: verdict.state, text: "",
                              diagnostics: verdict.diagnostics + ["cli.grok.unparseable-output"],
                              transcript: String(decoding: output, as: UTF8.self).prefix(2000).description)
        }

        let text = (obj["text"] as? String) ?? ""
        let stopReason = obj["stopReason"] as? String
        let sessionID = obj["sessionId"] as? String
        var transcript = ""
        if let thought = obj["thought"] as? String, !thought.isEmpty {
            transcript += "thinking: \(thought)\n"
        }
        if !text.isEmpty { transcript += "said: \(text)\n" }

        let verdict = Verdict.grok(stopReason: stopReason, exitCode: exitCode)
        return CliOutcome(state: verdict.state, text: text, diagnostics: verdict.diagnostics,
                          transcript: transcript, continuation: sessionID)
    }

    /// The last brace-delimited JSON object in the output. Grok's `--output-format
    /// json` prints one object; scanning for the last one tolerates any preamble
    /// without assuming a fixed layout.
    private func lastJSONObject(in output: Data) -> [String: Any]? {
        let text = String(decoding: output, as: UTF8.self)
        // Try the whole thing first — the common case is exactly one object.
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        // Otherwise, find the last top-level object by scanning from the last `{`
        // that yields valid JSON to the end.
        guard let firstBrace = text.firstIndex(of: "{") else { return nil }
        let candidate = String(text[firstBrace...])
        if let data = candidate.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        return nil
    }
}

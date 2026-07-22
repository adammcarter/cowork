import Foundation

/// Claude's one-shot wire, lifted verbatim from `CliBackend`.
///
/// Claude's streaming JSON surface is used deliberately: `--input-format
/// stream-json` is the only mode that *can* accept a message mid-session, so
/// choosing it for the one-shot path keeps `send` possible (ADR 001) even though
/// this dispatch closes stdin immediately. The task is fed as one streaming-JSON
/// user message; the outcome comes from claude's `result` object, not its exit
/// code (ADR 000).
public struct ClaudeOneShotDriver: OneShotDriver {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// The stream-json flags. Fixed for the dialect, not configuration: they were
    /// only ever passed as this exact literal.
    static let baseArguments = ["-p", "--input-format", "stream-json",
                                "--output-format", "stream-json", "--verbose",
                                "--permission-mode", "dontAsk",
                                "--allowed-tools", "Read", "Write",
                                "--strict-mcp-config"]

    public var deadlineDiagnostic: String { "cli.deadline" }

    public func invocation(task: String, workspace: Workspace?, resume: String?) -> Invocation {
        // Feed the task as one streaming-JSON user message: the only mode that could
        // accept a follow-up message, chosen now even though this path closes stdin.
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": task]]],
        ]
        let stdin = (try? JSONSerialization.data(withJSONObject: message)).map { $0 + Data("\n".utf8) }
        let arguments = Self.baseArguments + (resume.map { ["--resume", $0] } ?? [])
        return Invocation(arguments: arguments, stdin: stdin)
    }

    /// The verdict comes from what the agent *said*, not from how it exited (ADR
    /// 000). Claude's stream-json emits a `result` object carrying its own `subtype`
    /// and `is_error`; an exit code is a diagnostic beside it.
//: @use-case:cli.claude.dispatch_is_contained_and_collected#dispatch_is_contained_an
    public func parse(output: Data, exitStatus: Int32) -> CliOutcome {
        let text = String(decoding: output, as: UTF8.self)
        var transcript = ""
        var declared: (subtype: String, isError: Bool)?
        var result = ""
        var sessionID: String?

        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // Every line carries it; the last one wins, which is the session the
            // agent actually ended in.
            if let s = obj["session_id"] as? String, !s.isEmpty { sessionID = s }
            switch obj["type"] as? String {
            case "assistant":
                if let msg = obj["message"] as? [String: Any],
                   let content = msg["content"] as? [[String: Any]] {
                    for c in content where c["type"] as? String == "text" {
                        let t = (c["text"] as? String) ?? ""
                        if !t.isEmpty { transcript += "said: \(t)\n" }
                    }
                }
            case "result":
                declared = ((obj["subtype"] as? String) ?? "<absent>", (obj["is_error"] as? Bool) ?? false)
                result = (obj["result"] as? String) ?? result
            default:
                break
            }
        }

        let exitCode = (exitStatus & 0x7f) == 0 ? (exitStatus >> 8) & 0xff : -1

        // The verdict is a decision and lives in the testable core: what the agent
        // declared about itself, weighed against what the process did (ADR 000).
        let verdict = Verdict.cli(declaredSubtype: declared?.subtype,
                                  isError: declared?.isError ?? false,
                                  exitCode: exitCode)
        return CliOutcome(state: verdict.state, text: result, diagnostics: verdict.diagnostics,
                          transcript: transcript, continuation: sessionID)
    }
}

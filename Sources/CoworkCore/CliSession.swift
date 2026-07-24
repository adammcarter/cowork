import Darwin
import Foundation

/// A **live** CLI worker: spawned once, spoken to many times.
///
/// This is what `send` needs and what `CliBackend.run` cannot give it. `run`
/// spawns, writes one message, closes stdin and waits for exit — a driver that
/// restarts its worker per message has implemented `follow_up`, not `send`,
/// because the worker would remember nothing.
///
/// Verified live: `claude -p --input-format stream-json` accepts further user
/// messages on stdin while the session lives, each producing its own declared
/// result. Two messages to one process, eight seconds apart, both answered.
///
/// Containment and line-oriented stdio live in `ContainedPipe`; this type only
/// speaks the claude stream-json dialect on top of that pipe.
public final class CliSession: @unchecked Sendable {
    private let pipe: ContainedPipe
    /// The worker's own continuation handle, kept so an interactive dispatch can
    /// still be followed up after it concludes (ADR 001).
    public private(set) var lastSessionID: String?
    private let turnTimeout: TimeInterval

    /// Whether the worker is still running. A dispatch whose worker has gone is
    /// over, whatever anyone still wants to send it.
    public var workerAlive: Bool { pipe.isAlive }

    /// - Parameter workingDirectory: Dispatch workspace grant, applied to the
    ///   child at spawn. `nil` leaves the process in cowork's cwd.
    public init(executable: URL, arguments: [String], environment: [String: String],
                workingDirectory: String? = nil,
                cpuSecondsLimit: rlim_t = 900, turnTimeout: TimeInterval = 300) throws {
        do {
            self.pipe = try ContainedPipe(executable: executable, arguments: arguments,
                                          environment: environment,
                                          workingDirectory: workingDirectory,
                                          cpuSecondsLimit: cpuSecondsLimit)
        } catch ContainedPipe.Error.spawnFailed(let rc) {
            throw SessionError.spawnFailed(rc)
        }
        self.turnTimeout = turnTimeout
    }

    public enum SessionError: Error { case spawnFailed(Int32) }

    /// Give the worker a prompt and read until it declares that turn's outcome.
    ///
    /// Reading stops at the worker's own `result` line rather than at EOF: EOF
    /// never comes while the session is alive, and waiting for it is how the whole
    /// dispatch hangs.
    public func turn(_ prompt: String) -> InteractiveSession.Turn {
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": prompt]]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            return .init(state: .failed, text: "", diagnostics: ["cli.message-unencodable"],
                         transcript: "", workerAlive: workerAlive)
        }
        do { try pipe.writeLine(data) } catch {
            // The worker is gone, or its stdin is closed. Either way this dispatch
            // cannot continue, and saying so beats waiting for a reply that will
            // never come.
            pipe.markExited()
            return .init(state: .failed, text: "", diagnostics: ["cli.worker-unreachable"],
                         transcript: "", workerAlive: false)
        }

        var transcript = ""
        var declared: (subtype: String, isError: Bool)?
        var result = ""
        var sessionID: String?

        let deadline = Date().addingTimeInterval(turnTimeout)
        while let line = pipe.readLine(deadline: deadline) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
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
                // The turn is over the moment the worker says it is. The session
                // stays alive for the next one.
                let verdict = Verdict.declaredResult(declaredSubtype: declared?.subtype,
                                                     isError: declared?.isError ?? false,
                                                     exitCode: 0)
                lastSessionID = sessionID
                return .init(state: verdict.state, text: result, diagnostics: verdict.diagnostics,
                             transcript: transcript, workerAlive: workerAlive)
            default:
                break
            }
        }

        pipe.markExited()
        // No declaration and no more output: the worker died mid-turn. An exit is
        // not an outcome (ADR 000), so this is a failure that names itself.
        lastSessionID = sessionID
        return .init(state: .failed, text: result,
                     diagnostics: ["cli.no-declared-result", "cli.worker-exited-mid-turn"],
                     transcript: transcript, workerAlive: false)
    }

    /// Close stdin — the worker's signal that nothing more is coming — then make
    /// sure it is gone. Containment is not optional just because we asked nicely
    /// (ADR 003 rule 3).
    public func close() {
        pipe.close()
    }
}

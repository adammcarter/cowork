import Darwin
import Foundation

/// A **live** grok ACP worker: spawned once, spoken to many times over JSON-RPC
/// stdio (Agent Client Protocol).
///
/// This is what interactive `send`/`finish` needs from grok. One-shot
/// `GrokOneShotDriver` spawns, runs one prompt, and exits — a driver that
/// restarts per message has implemented `follow_up`, not `send`, because the
/// worker would remember nothing.
///
/// Containment and line-oriented stdio live in `ContainedPipe`; this type only
/// speaks the ACP JSON-RPC dialect on top of that pipe: `initialize` →
/// `session/new` at start, then `session/prompt` per turn with
/// `session/update` agent_message_chunk accumulation until the matching result.
public final class GrokAcpSession: SessionTransport, @unchecked Sendable {
    private let pipe: ContainedPipe
    private let sessionId: String
    private let turnTimeout: TimeInterval
    /// Next JSON-RPC request id. 1 and 2 are consumed by the handshake.
    private var nextId: Int = 3

    public var isAlive: Bool { pipe.isAlive }
    /// The ACP `sessionId` from `session/new` — the worker's continuation handle.
    public var continuation: String? { sessionId }

    /// Take ownership of an already-spawned contained pipe and complete the ACP
    /// handshake (`initialize` then `session/new`) before the first turn.
    public init(pipe: ContainedPipe, cwd: String,
                turnTimeout: TimeInterval = 300) throws {
        self.pipe = pipe
        self.turnTimeout = turnTimeout
        self.sessionId = try Self.handshake(pipe: pipe, cwd: cwd, turnTimeout: turnTimeout)
    }

    public enum SessionError: Error, Equatable {
        case handshakeFailed(String)
        case unencodable
    }

    public func close() {
        pipe.close()
    }

    /// One `session/prompt` exchange: write the prompt, accumulate
    /// `agent_message_chunk` notifications, stop at the result for this request id.
    public func turn(_ prompt: String) -> InteractiveSession.Turn {
        let requestId = nextId
        nextId += 1

        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId,
            "method": "session/prompt",
            "params": [
                "sessionId": sessionId,
                "prompt": [["type": "text", "text": prompt]],
            ] as [String: Any],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            return .init(state: .failed, text: "", diagnostics: ["cli.acp.message-unencodable"],
                         transcript: "", workerAlive: isAlive)
        }
        do {
            try pipe.writeLine(data)
        } catch {
            pipe.markExited()
            return .init(state: .failed, text: "", diagnostics: ["cli.acp.worker-unreachable"],
                         transcript: "", workerAlive: false)
        }

        var accumulated = ""
        var transcript = ""
        let deadline = Date().addingTimeInterval(turnTimeout)

        while let line = pipe.readLine(deadline: deadline) {
            guard let obj = Self.parseJSON(line) else { continue }

            // Matching result ends the turn. Ignore results (or errors) for any
            // other id — noise or out-of-order traffic must not steal the turn.
            if Self.matchesId(obj, requestId) {
                if let error = obj["error"] {
                    let detail = String(describing: error)
                    return .init(state: .failed, text: accumulated,
                                 diagnostics: ["cli.acp.rpc-error", detail],
                                 transcript: transcript, workerAlive: isAlive)
                }
                let result = obj["result"] as? [String: Any]
                let stopReason = (result?["stopReason"] as? String) ?? "<absent>"
                let verdict = Verdict.acp(stopReason: stopReason)
                if !accumulated.isEmpty { transcript += "said: \(accumulated)\n" }
                return .init(state: verdict.state, text: accumulated,
                             diagnostics: verdict.diagnostics,
                             transcript: transcript, workerAlive: isAlive)
            }

            // Notifications only: method present, no correlated request id we own.
            if let method = obj["method"] as? String {
                if method == "session/update",
                   let chunk = Self.agentMessageChunk(from: obj) {
                    accumulated += chunk
                }
                // Ignore `_x.ai/*`, other session/update kinds, mcp progress, etc.
                continue
            }
        }

        // No result before the deadline: the worker died mid-turn or went silent.
        pipe.markExited()
        return .init(state: .failed, text: accumulated,
                     diagnostics: ["cli.acp.no-declared-result",
                                   "cli.acp.worker-exited-mid-turn"],
                     transcript: transcript, workerAlive: false)
    }

    // MARK: - Handshake

    private static func handshake(pipe: ContainedPipe, cwd: String,
                                  turnTimeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(turnTimeout)

        try writeRequest(pipe: pipe, id: 1, method: "initialize", params: [
            "protocolVersion": 1,
            "clientCapabilities": [
                "fs": [
                    "readTextFile": false,
                    "writeTextFile": false,
                ] as [String: Any],
            ] as [String: Any],
        ])
        guard readResult(pipe: pipe, id: 1, deadline: deadline) != nil else {
            pipe.markExited()
            throw SessionError.handshakeFailed("initialize")
        }

        try writeRequest(pipe: pipe, id: 2, method: "session/new", params: [
            "cwd": cwd,
            "mcpServers": [] as [Any],
        ])
        guard let newResult = readResult(pipe: pipe, id: 2, deadline: deadline) else {
            pipe.markExited()
            throw SessionError.handshakeFailed("session/new")
        }
        guard let sid = newResult["sessionId"] as? String, !sid.isEmpty else {
            pipe.markExited()
            throw SessionError.handshakeFailed("session/new.missing-sessionId")
        }
        return sid
    }

    private static func writeRequest(pipe: ContainedPipe, id: Int, method: String,
                                     params: [String: Any]) throws {
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            throw SessionError.unencodable
        }
        do {
            try pipe.writeLine(data)
        } catch {
            pipe.markExited()
            throw SessionError.handshakeFailed("write:\(method)")
        }
    }

    /// Read lines until a JSON-RPC **result** (or error) for `id` arrives.
    /// Notifications and unrelated traffic are skipped, not treated as answers.
    private static func readResult(pipe: ContainedPipe, id: Int,
                                   deadline: Date) -> [String: Any]? {
        while let line = pipe.readLine(deadline: deadline) {
            guard let obj = parseJSON(line) else { continue }
            guard matchesId(obj, id) else { continue }
            if obj["error"] != nil { return nil }
            return obj["result"] as? [String: Any]
        }
        return nil
    }

    // MARK: - JSON helpers

    private static func parseJSON(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    /// JSON-RPC ids may decode as Int or NSNumber depending on the payload.
    private static func matchesId(_ obj: [String: Any], _ expected: Int) -> Bool {
        if let i = obj["id"] as? Int { return i == expected }
        if let n = obj["id"] as? NSNumber { return n.intValue == expected }
        return false
    }

    /// Extract text from
    /// `session/update` → `update.sessionUpdate == agent_message_chunk` →
    /// `content.type == text`.
    private static func agentMessageChunk(from obj: [String: Any]) -> String? {
        guard let params = obj["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "agent_message_chunk",
              let content = update["content"] as? [String: Any],
              content["type"] as? String == "text",
              let text = content["text"] as? String
        else { return nil }
        return text
    }
}

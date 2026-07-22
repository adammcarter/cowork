import Darwin
import Foundation

/// A **live** codex worker: spawned once as `codex mcp-server`, spoken to many times
/// over MCP's JSON-RPC stdio.
///
/// This is codex's half of interactive `send`/`finish`. Where grok's ACP session
/// mints its `sessionId` up front in `session/new`, codex has no such call — the
/// thread does not exist until the first turn, so `continuation` is nil until then
/// and the first turn uses the `codex` tool while every later turn uses `codex-reply`
/// with the captured `threadId`.
///
/// Containment and line-oriented stdio live in `ContainedPipe`; this type only speaks
/// the MCP dialect on top of it: `initialize` + `notifications/initialized` at start,
/// then a `tools/call` per turn, draining `codex/event*` notifications until the
/// matching result. The assistant text is `result.structuredContent.content` and the
/// continuation handle is `result.structuredContent.threadId` (both proven live).
public final class CodexMcpSession: SessionTransport, @unchecked Sendable {
    private let pipe: ContainedPipe
    private let cwd: String
    private let turnTimeout: TimeInterval
    /// Next JSON-RPC request id. Id 1 is consumed by the `initialize` handshake.
    private var nextId: Int = 2
    /// The codex thread, captured from the first turn's result. Nil until then, which
    /// is also how `turn` knows to call `codex` rather than `codex-reply`.
    private var threadId: String?

    public var isAlive: Bool { pipe.isAlive }
    /// The codex `threadId` — the worker's continuation handle. Nil before the first
    /// turn, because codex mints it as part of answering, not at session start.
    public var continuation: String? { threadId }

    /// Take ownership of an already-spawned contained pipe and complete the MCP
    /// handshake (`initialize` then the `notifications/initialized` notification)
    /// before the first turn.
    public init(pipe: ContainedPipe, cwd: String,
                turnTimeout: TimeInterval = 300) throws {
        self.pipe = pipe
        self.cwd = cwd
        self.turnTimeout = turnTimeout
        try Self.handshake(pipe: pipe, turnTimeout: turnTimeout)
    }

    public enum SessionError: Error, Equatable {
        case handshakeFailed(String)
        case unencodable
    }

    public func close() {
        pipe.close()
    }

    /// One `tools/call` exchange. The first turn (no thread yet) calls the `codex`
    /// tool; every later turn calls `codex-reply` with the captured `threadId`. The
    /// reply text and the thread come back in the result's `structuredContent`;
    /// `codex/event*` notifications streamed during the turn are progress noise and
    /// are ignored — the result body is the answer.
    public func turn(_ prompt: String) -> InteractiveSession.Turn {
        let requestId = nextId
        nextId += 1

        let arguments: [String: Any]
        let toolName: String
        if let threadId {
            toolName = "codex-reply"
            arguments = ["threadId": threadId, "prompt": prompt]
        } else {
            toolName = "codex"
            arguments = ["prompt": prompt, "cwd": cwd,
                         "approval-policy": "never", "sandbox": "danger-full-access"]
        }
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId,
            "method": "tools/call",
            "params": ["name": toolName, "arguments": arguments] as [String: Any],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            return .init(state: .failed, text: "", diagnostics: ["cli.codex-mcp.message-unencodable"],
                         transcript: "", workerAlive: isAlive)
        }
        do {
            try pipe.writeLine(data)
        } catch {
            pipe.markExited()
            return .init(state: .failed, text: "", diagnostics: ["cli.codex-mcp.worker-unreachable"],
                         transcript: "", workerAlive: false)
        }

        let deadline = Date().addingTimeInterval(turnTimeout)
        while let line = pipe.readLine(deadline: deadline) {
            guard let obj = Self.parseJSON(line) else { continue }

            // Matching result ends the turn. Ignore results for any other id and every
            // `codex/event` notification — out-of-order traffic must not steal the turn.
            guard Self.matchesId(obj, requestId) else { continue }

            if let error = obj["error"] {
                let detail = String(describing: error)
                let verdict = Verdict.codexMcp(hasContent: false, rpcError: detail)
                return .init(state: verdict.state, text: "", diagnostics: verdict.diagnostics,
                             transcript: "", workerAlive: isAlive)
            }

            let structured = (obj["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            // Capture/refresh the thread so the next turn uses `codex-reply`.
            if let sid = structured?["threadId"] as? String, !sid.isEmpty { threadId = sid }
            let text = (structured?["content"] as? String) ?? ""
            let verdict = Verdict.codexMcp(hasContent: structured != nil, rpcError: nil)
            var transcript = ""
            if !text.isEmpty { transcript += "said: \(text)\n" }
            return .init(state: verdict.state, text: text, diagnostics: verdict.diagnostics,
                         transcript: transcript, workerAlive: isAlive)
        }

        // No result before the deadline: the worker died mid-turn or went silent.
        pipe.markExited()
        return .init(state: .failed, text: "",
                     diagnostics: ["cli.codex-mcp.no-declared-result",
                                   "cli.codex-mcp.worker-exited-mid-turn"],
                     transcript: "", workerAlive: false)
    }

    // MARK: - Handshake

    private static func handshake(pipe: ContainedPipe, turnTimeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(turnTimeout)

        try writeRequest(pipe: pipe, id: 1, method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "cowork", "version": "0"] as [String: Any],
        ])
        guard readResult(pipe: pipe, id: 1, deadline: deadline) != nil else {
            pipe.markExited()
            throw SessionError.handshakeFailed("initialize")
        }

        // A notification (no id) completing the MCP handshake; codex expects it before
        // it will accept a tools/call.
        try writeNotification(pipe: pipe, method: "notifications/initialized")
    }

    private static func writeRequest(pipe: ContainedPipe, id: Int, method: String,
                                     params: [String: Any]) throws {
        try write(pipe: pipe, message: ["jsonrpc": "2.0", "id": id, "method": method, "params": params],
                  label: method)
    }

    private static func writeNotification(pipe: ContainedPipe, method: String) throws {
        try write(pipe: pipe, message: ["jsonrpc": "2.0", "method": method], label: method)
    }

    private static func write(pipe: ContainedPipe, message: [String: Any], label: String) throws {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            throw SessionError.unencodable
        }
        do {
            try pipe.writeLine(data)
        } catch {
            pipe.markExited()
            throw SessionError.handshakeFailed("write:\(label)")
        }
    }

    /// Read lines until a JSON-RPC **result** (or error) for `id` arrives.
    /// Notifications (`codex/event*`) and unrelated traffic are skipped, not treated
    /// as answers.
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
}

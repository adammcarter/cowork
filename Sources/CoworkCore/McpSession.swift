import Darwin
import Foundation

/// A **live** worker on MCP's JSON-RPC stdio: spawned once as the agent's own MCP
/// server, spoken to many times.
///
/// Where ACP mints a session id up front in `session/new`, MCP has no such call — the
/// thread does not exist until the first turn, so `continuation` is nil until then
/// and the first turn calls the descriptor's `tool` while every later turn calls its
/// `reply_tool` with the captured thread.
///
/// Containment and line-oriented stdio live in `ContainedPipe`; this type only speaks
/// the MCP dialect on top of it: `initialize` + `notifications/initialized` at start,
/// then a `tools/call` per turn, draining progress notifications until the matching
/// result. Only the two TOOL NAMES come from config — MCP fixes the envelope but not
/// which tool answers a prompt. The RESULT shape stays here in code on purpose: a
/// config that could name the member the verdict is read from would be authoring the
/// success predicate, which ADR 000 reserves for reviewed Swift.
public final class McpSession: SessionTransport, @unchecked Sendable {
    private let pipe: ContainedPipe
    private let cwd: String
    private let spec: CliDescriptor.SessionSpec
    private let turnTimeout: TimeInterval
    /// Next JSON-RPC request id. Id 1 is consumed by the `initialize` handshake.
    private var nextId: Int = 2
    /// The worker's thread, captured from the first turn's result. Nil until then,
    /// which is also how `turn` knows to call `tool` rather than `reply_tool`.
    private var threadId: String?

    public var isAlive: Bool { pipe.isAlive }
    /// The thread id — the worker's continuation handle. Nil before the first turn,
    /// because MCP mints it as part of answering, not at session start.
    public var continuation: String? { threadId }

    /// Take ownership of an already-spawned contained pipe and complete the MCP
    /// handshake (`initialize` then the `notifications/initialized` notification)
    /// before the first turn.
    public init(pipe: ContainedPipe, cwd: String, spec: CliDescriptor.SessionSpec,
                turnTimeout: TimeInterval = 300) throws {
        self.pipe = pipe
        self.cwd = cwd
        self.spec = spec
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

    /// One `tools/call` exchange. The first turn (no thread yet) calls the descriptor's
    /// `tool`; every later turn calls its `reply_tool` with the captured `threadId`.
    /// The reply text and the thread come back in the result; progress notifications
    /// streamed during the turn are noise and are ignored — the result body is the
    /// answer.
    public func turn(_ prompt: String) -> InteractiveSession.Turn {
        let requestId = nextId
        nextId += 1

        var arguments: [String: Any]
        let toolName: String
        if let threadId {
            toolName = spec.replyTool ?? ""
            arguments = ["threadId": threadId, "prompt": prompt]
        } else {
            toolName = spec.tool ?? ""
            // The agent's own per-session switches (approval policy, sandbox mode) are
            // the user's to choose, so they ride along from config rather than being
            // decided here for an agent cowork knows nothing about.
            arguments = spec.toolArguments.mapValues { $0 as Any }
            arguments["prompt"] = prompt
            arguments["cwd"] = cwd
        }
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId,
            "method": "tools/call",
            "params": ["name": toolName, "arguments": arguments] as [String: Any],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            return .init(state: .failed, text: "", diagnostics: ["cli.mcp.message-unencodable"],
                         transcript: "", workerAlive: isAlive)
        }
        do {
            try pipe.writeLine(data)
        } catch {
            pipe.markExited()
            return .init(state: .failed, text: "", diagnostics: ["cli.mcp.worker-unreachable"],
                         transcript: "", workerAlive: false)
        }

        let deadline = Date().addingTimeInterval(turnTimeout)
        while let line = pipe.readLine(deadline: deadline) {
            guard let obj = Self.parseJSON(line) else { continue }

            // Matching result ends the turn. Ignore results for any other id and every
            // progress notification — out-of-order traffic must not steal the turn.
            guard Self.matchesId(obj, requestId) else { continue }

            if let error = obj["error"] {
                let detail = String(describing: error)
                let verdict = Verdict.mcp(hasContent: false, rpcError: detail)
                return .init(state: verdict.state, text: "", diagnostics: verdict.diagnostics,
                             transcript: "", workerAlive: isAlive)
            }

            let result = obj["result"] as? [String: Any]
            let structured = result?["structuredContent"] as? [String: Any]
            // Capture/refresh the thread so the next turn uses the reply tool.
            if let sid = structured?["threadId"] as? String, !sid.isEmpty { threadId = sid }
            let text = Self.assistantText(result: result, structured: structured)
            // The TEXT is the verdict, not the presence of a member: a result object
            // that carries no answer is an empty success, which is the exact lie this
            // product exists to prevent.
            let verdict = Verdict.mcp(hasContent: !text.isEmpty, rpcError: nil)
            var transcript = ""
            if !text.isEmpty { transcript += "said: \(text)\n" }
            return .init(state: verdict.state, text: text, diagnostics: verdict.diagnostics,
                         transcript: transcript, workerAlive: isAlive)
        }

        // No result before the deadline: the worker died mid-turn or went silent.
        pipe.markExited()
        return .init(state: .failed, text: "",
                     diagnostics: ["cli.mcp.no-declared-result",
                                   "cli.mcp.worker-exited-mid-turn"],
                     transcript: "", workerAlive: false)
    }

    /// The assistant's reply, from either shape MCP servers actually use: a plain
    /// string under `structuredContent`, or the spec's own `content` array of typed
    /// blocks. Reading only the first would silently return "" for every agent that
    /// speaks the standard shape, and an empty answer is worse than an error.
    private static func assistantText(result: [String: Any]?,
                                      structured: [String: Any]?) -> String {
        if let s = structured?["content"] as? String, !s.isEmpty { return s }
        let blocks = (structured?["content"] as? [[String: Any]]) ?? (result?["content"] as? [[String: Any]])
        let parts = (blocks ?? []).compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            let text = (block["text"] as? String) ?? ""
            return text.isEmpty ? nil : text
        }
        return parts.joined(separator: "\n")
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

        // A notification (no id) completing the MCP handshake; a server expects it
        // before it will accept a tools/call.
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
    /// Progress notifications and unrelated traffic are skipped, not treated
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

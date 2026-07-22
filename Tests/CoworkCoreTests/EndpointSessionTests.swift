import Foundation
import Testing

@testable import CoworkCore

/// An endpoint held open across turns.
///
/// A CLI worker keeps a warm *process*; an endpoint has none. But cowork owns the
/// message list the endpoint loop is built from, so `send` is real for an endpoint
/// too: append a further user message and re-run. That is what `capabilities` has
/// been promising for every endpoint — `supports_message: true` — while the
/// supervisor refused to start an interactive endpoint dispatch at all. This is
/// the code that makes the promise true.
///
/// The mock endpoint echoes back every user message it has seen, so a second turn
/// answering with the first turn's content can only mean one persisted list — the
/// endpoint equivalent of the CLI worker remembering.
@Suite("Endpoint session")
struct EndpointSessionTests {
    private final class FakeHTTPBoundary: @unchecked Sendable {
        typealias Reply = (message: [String: Any], finish: String)

        private let reply: @Sendable ([[String: Any]]) async throws -> Reply
        private let lock = NSLock()
        private var capturedMessages: [[[String: Any]]] = []

        init(reply: @escaping @Sendable ([[String: Any]]) async throws -> Reply) {
            self.reply = reply
        }

        func send(_ body: Data) async throws -> Data {
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let messages = json?["messages"] as? [[String: Any]] ?? []
            lock.withLock { capturedMessages.append(messages) }
            let result = try await reply(messages)
            return try JSONSerialization.data(withJSONObject: [
                "choices": [["message": result.message, "finish_reason": result.finish]],
            ])
        }

        var requests: [[[String: Any]]] { lock.withLock { capturedMessages } }
    }

    /// A stand-in endpoint that remembers by construction: it replies with every
    /// user message it has been given, joined. No network, so the test measures the
    /// session's own list-keeping, not a model.
    private func rememberingChat() -> @Sendable ([[String: Any]]) async throws -> (message: [String: Any], finish: String) {
        return { messages in
            let saidByUser = messages.compactMap { m -> String? in
                (m["role"] as? String) == "user" ? (m["content"] as? String) : nil
            }
            return (["role": "assistant", "content": "heard: " + saidByUser.joined(separator: " | ")], "stop")
        }
    }

    private func conversation(boundary: FakeHTTPBoundary,
                              executeTool: @escaping (String, String) -> String) -> EndpointConversation {
        EndpointConversation(model: "test", tools: Tools.definitions(),
                             dialect: OpenAIDialect(), http: boundary.send,
                             executeTool: executeTool)
    }

    @Test("a second turn sees the first — send reaches a live message list")
    func secondTurnRemembers() async {
        let boundary = FakeHTTPBoundary(reply: rememberingChat())
        let session = EndpointSession(conversation: conversation(
            boundary: boundary, executeTool: { _, _ in "" }))

        let first = await session.turn("first")
        #expect(first.state == .succeeded)
        #expect(first.text == "heard: first")
        #expect(first.workerAlive, "an endpoint session has no process to die; it is always ready for the next turn")

        let second = await session.turn("second")
        #expect(second.text == "heard: first | second",
                "the second turn must see the first, or send has not actually reached a live worker")
        #expect(boundary.requests.count == 2)
        #expect(boundary.requests[1].compactMap { message in
            (message["role"] as? String) == "user" ? message["content"] as? String : nil
        } == ["first", "second"], "the injected HTTP boundary must receive one retained history")
    }

    /// The worker's declared `finish_reason` is the verdict, exactly as for a
    /// one-shot endpoint dispatch — an interactive turn does not get a softer rule.
    @Test("the finish_reason decides the turn's state")
    func finishReasonIsTheVerdict() async {
        let refusing: @Sendable ([[String: Any]]) async throws -> (message: [String: Any], finish: String) = { _ in
            (["role": "assistant", "content": "no"], "content_filter")
        }
        let boundary = FakeHTTPBoundary(reply: refusing)
        let session = EndpointSession(conversation: conversation(
            boundary: boundary, executeTool: { _, _ in "" }))
        let turn = await session.turn("do a thing")
        #expect(turn.state != .succeeded, "content_filter is not a success, mid-conversation or not")
    }

    /// A tool call is a continuation, not a conclusion: the session runs the tool,
    /// feeds the result back, and only the model's own terminal finish ends the turn.
    @Test("a tool call within a turn is executed and looped back")
    func toolCallWithinATurn() async {
        // First reply asks for a tool; second (seeing the tool result) concludes.
        actor Step { var n = 0; func next() -> Int { n += 1; return n } }
        let step = Step()
        let chat: @Sendable ([[String: Any]]) async throws -> (message: [String: Any], finish: String) = { messages in
            if await step.next() == 1 {
                return (["role": "assistant", "content": "",
                         "tool_calls": [["id": "c1", "function": ["name": "probe", "arguments": "{}"]]]], "tool_calls")
            }
            let sawTool = messages.contains { ($0["role"] as? String) == "tool" }
            return (["role": "assistant", "content": sawTool ? "used the tool" : "no tool seen"], "stop")
        }
        let boundary = FakeHTTPBoundary(reply: chat)
        let session = EndpointSession(conversation: conversation(
            boundary: boundary, executeTool: { name, _ in "result-of-\(name)" }))
        let turn = await session.turn("use a tool")
        #expect(turn.state == .succeeded)
        #expect(turn.text == "used the tool", "the tool result must be fed back into the same turn")
    }

    /// A turn that never converges is a named failure, never a silent truncation —
    /// the same bound the one-shot loop has.
    @Test("a non-converging turn fails with the turn-limit named")
    func nonConvergingTurnFails() async {
        let alwaysTools: @Sendable ([[String: Any]]) async throws -> (message: [String: Any], finish: String) = { _ in
            (["role": "assistant", "content": "",
              "tool_calls": [["id": "c", "function": ["name": "spin", "arguments": "{}"]]]], "tool_calls")
        }
        let boundary = FakeHTTPBoundary(reply: alwaysTools)
        let session = EndpointSession(conversation: conversation(
            boundary: boundary, executeTool: { _, _ in "again" }))
        let turn = await session.turn("spin forever")
        #expect(turn.state == .failed)
        #expect(turn.diagnostics.contains { $0.contains("turn-limit") })
        #expect(boundary.requests.count == 8,
                "the shared conversation must enforce the one endpoint turn cap")
        #expect(turn.diagnostics.contains("max_turns=8"))
    }

    @Test("the conversation owns the endpoint turn cap")
    func conversationOwnsTurnCap() async {
        let boundary = FakeHTTPBoundary { _ in
            (["role": "assistant", "content": "",
              "tool_calls": [["id": "c", "function": ["name": "spin", "arguments": "{}"]]]],
             "tool_calls")
        }
        let conversation = conversation(boundary: boundary, executeTool: { _, _ in "again" })

        let result = await conversation.turn("spin forever")

        #expect(result.state == .failed)
        #expect(result.diagnostics == ["endpoint.turn-limit", "max_turns=8"])
        #expect(boundary.requests.count == 8)
    }
}

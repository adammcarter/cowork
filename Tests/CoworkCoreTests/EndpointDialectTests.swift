import Foundation
import Testing

@testable import CoworkCore

@Suite("Endpoint dialect")
struct EndpointDialectTests {
    private struct TinyDialect: EndpointDialect {
        func encodeRequest(model: String, maxTokens: Int?,
                           messages: [EndpointMessage], tools: [EndpointTool]) throws -> Data {
            let turns = messages.map { message -> [String: Any] in
                switch message {
                case let .user(text): return ["speaker": "human", "text": text]
                case let .assistant(text, _, _): return ["speaker": "agent", "text": text]
                case let .toolResult(id, content):
                    return ["speaker": "function", "call": id, "text": content]
                }
            }
            return try JSONSerialization.data(withJSONObject: [
                "engine": model,
                "turns": turns,
                "functions": tools.map(\.name),
            ])
        }

        func decodeResponse(_ data: Data) throws -> EndpointDialectResponse {
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return EndpointDialectResponse(
                text: json["answer"] as? String ?? "",
                reasoning: nil,
                toolCalls: [],
                finishReason: json["stop"] as? String ?? "<absent>")
        }
    }

    @Test("a second dialect runs a conversation end to end")
    func tinyDialectConversation() async throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "answer": "alternate shape worked", "stop": "stop",
        ])
        let captured = LockedBox<Data?>(nil)
        let conversation = EndpointConversation(
            model: "tiny-model",
            tools: [EndpointTool(name: "probe", description: "Probe", inputSchema: [:])],
            dialect: TinyDialect(),
            http: { body in captured.withLock { $0 = body }; return response },
            executeTool: { _, _ in "" })

        let outcome = await conversation.turn("hello")

        #expect(outcome.state == .succeeded)
        #expect(outcome.text == "alternate shape worked")
        let body = try #require(captured.withLock { $0 })
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["engine"] as? String == "tiny-model")
        #expect((json["turns"] as? [[String: Any]])?.first?["speaker"] as? String == "human")
        #expect(json["functions"] as? [String] == ["probe"])
    }

    @Test("OpenAI request and response mapping remains compatible")
    func openAIMapping() throws {
        let dialect = OpenAIDialect()
        let body = try dialect.encodeRequest(
            model: "qwen", maxTokens: 321,
            messages: [
                .user("inspect"),
                .assistant(text: "", reasoning: "checking",
                           toolCalls: [.init(id: "call-1", name: "probe", arguments: "{\"x\":1}")]),
                .toolResult(id: "call-1", content: "ok"),
            ],
            tools: [.init(name: "probe", description: "Probe things",
                          inputSchema: ["type": "object", "required": ["x"]])])
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "qwen")
        #expect(json["stream"] as? Bool == false)
        #expect(json["max_tokens"] as? Int == 321)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "inspect")
        #expect(messages[1]["reasoning_content"] as? String == "checking")
        let encodedCalls = try #require(messages[1]["tool_calls"] as? [[String: Any]])
        #expect(encodedCalls[0]["id"] as? String == "call-1")
        #expect(messages[2]["tool_call_id"] as? String == "call-1")
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools[0]["type"] as? String == "function")

        let response = try JSONSerialization.data(withJSONObject: [
            "choices": [[
                "message": [
                    "role": "assistant", "content": "done", "reasoning_content": "thought",
                    "tool_calls": [["id": "call-2", "function": [
                        "name": "probe", "arguments": "{}",
                    ]]],
                ],
                "finish_reason": "tool_calls",
            ]],
        ])
        let decoded = try dialect.decodeResponse(response)
        #expect(decoded.text == "done")
        #expect(decoded.reasoning == "thought")
        #expect(decoded.finishReason == "tool_calls")
        #expect(decoded.toolCalls == [.init(id: "call-2", name: "probe", arguments: "{}")])
    }

    @Test("an unsupported provider kind is named at resolution")
    func unsupportedKindIsNamed() throws {
        let provider = ProviderConfig(
            name: "future", kind: "future_native", baseURL: URL(string: "http://127.0.0.1")!,
            chatPath: "chat", credential: nil, origin: .global)

        let backend = BackendResolver.resolveEndpoint(id: "future/model", provider: provider, model: "model")

        #expect(backend.available == false)
        #expect(backend.diagnostics == ["endpoint.dialect-unsupported", "kind=future_native"])
        #expect(backend.oneShot(DispatchContext()) == nil)
        #expect(backend.canOpenInteractiveSession == false)
    }

    @Test("malformed OpenAI JSON keeps the named response diagnostic")
    func malformedOpenAIResponseIsNamed() async {
        let conversation = EndpointConversation(
            model: "qwen", tools: [], dialect: OpenAIDialect(),
            http: { _ in Data("not-json".utf8) }, executeTool: { _, _ in "" })

        let outcome = await conversation.turn("hello")

        #expect(outcome.state == .failed)
        #expect(outcome.diagnostics == ["endpoint.malformed-response"])
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

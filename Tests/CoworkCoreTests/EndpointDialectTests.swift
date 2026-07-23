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

        func headers(credential: Credential?) -> [String: String] { [:] }
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

    // MARK: Anthropic dialect — the Messages API is a different shape, proven the same way

    @Test("Anthropic request and response mapping")
    func anthropicMapping() throws {
        let dialect = AnthropicDialect()
        let body = try dialect.encodeRequest(
            model: "ornith", maxTokens: 321,
            messages: [
                .user("inspect"),
                .assistant(text: "looking", reasoning: nil,
                           toolCalls: [.init(id: "tu-1", name: "probe", arguments: "{\"x\":1}")]),
                .toolResult(id: "tu-1", content: "ok"),
            ],
            tools: [.init(name: "probe", description: "Probe things",
                          inputSchema: ["type": "object", "required": ["x"]])])
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "ornith")
        #expect(json["max_tokens"] as? Int == 321)
        let messages = try #require(json["messages"] as? [[String: Any]])
        // user text is a plain string, assistant/tool_result are content-block arrays
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "inspect")
        #expect(messages[1]["role"] as? String == "assistant")
        let asstBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(asstBlocks.contains { $0["type"] as? String == "text" && $0["text"] as? String == "looking" })
        let toolUse = try #require(asstBlocks.first { $0["type"] as? String == "tool_use" })
        #expect(toolUse["id"] as? String == "tu-1")
        #expect(toolUse["name"] as? String == "probe")
        #expect(toolUse["input"] as? [String: Any] != nil)
        let resultBlocks = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(resultBlocks[0]["type"] as? String == "tool_result")
        #expect(resultBlocks[0]["tool_use_id"] as? String == "tu-1")
        // Anthropic tools carry input_schema, not the OpenAI function wrapper
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools[0]["name"] as? String == "probe")
        #expect(tools[0]["input_schema"] as? [String: Any] != nil)

        let response = try JSONSerialization.data(withJSONObject: [
            "content": [
                ["type": "text", "text": "done"],
            ],
            "stop_reason": "end_turn",
        ])
        let decoded = try dialect.decodeResponse(response)
        #expect(decoded.text == "done")
        #expect(decoded.finishReason == "stop")   // normalized from end_turn
    }

    @Test("Anthropic max_tokens is always present — the API requires it — defaulted when unset")
    func anthropicMaxTokensDefaulted() throws {
        let body = try AnthropicDialect().encodeRequest(
            model: "ornith", maxTokens: nil, messages: [.user("hi")], tools: [])
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["max_tokens"] as? Int != nil, "Anthropic rejects a request with no max_tokens")
    }

    @Test("Anthropic tool_use decodes to a normalized tool call with JSON-string arguments")
    func anthropicToolUseDecode() throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "content": [
                ["type": "tool_use", "id": "tu-9", "name": "probe", "input": ["x": 1]],
            ],
            "stop_reason": "tool_use",
        ])
        let decoded = try AnthropicDialect().decodeResponse(response)
        #expect(decoded.finishReason == "tool_calls")   // normalized from tool_use
        #expect(decoded.toolCalls.count == 1)
        #expect(decoded.toolCalls[0].id == "tu-9")
        #expect(decoded.toolCalls[0].name == "probe")
        let args = try #require(JSONSerialization.jsonObject(
            with: Data(decoded.toolCalls[0].arguments.utf8)) as? [String: Any])
        #expect(args["x"] as? Int == 1)
    }

    @Test("Anthropic stop_reason normalizes onto the verdict vocabulary")
    func anthropicStopReasonNormalization() throws {
        func finish(_ stop: String) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: [
                "content": [["type": "text", "text": "x"]], "stop_reason": stop])
            return try AnthropicDialect().decodeResponse(data).finishReason
        }
        #expect(try finish("end_turn") == "stop")        // → succeeded
        #expect(try finish("stop_sequence") == "stop")   // clean intended stop → succeeded
        #expect(try finish("max_tokens") == "length")    // truncation → failed (Verdict)
        #expect(try finish("tool_use") == "tool_calls")  // → continuation
        // An unknown Anthropic stop_reason is passed through untranslated so Verdict
        // refuses it rather than guessing.
        #expect(try finish("some_new_reason") == "some_new_reason")
    }

    @Test("each dialect shapes its own auth headers")
    func dialectAuthHeaders() {
        // OpenAI: bearer or nothing.
        #expect(OpenAIDialect().headers(credential: Credential("k")) == ["Authorization": "Bearer k"])
        #expect(OpenAIDialect().headers(credential: nil).isEmpty)
        // Anthropic: x-api-key (not bearer) + the required version header; version rides
        // even with no credential (a local proxy needs no key).
        let withKey = AnthropicDialect().headers(credential: Credential("k"))
        #expect(withKey["x-api-key"] == "k")
        #expect(withKey["Authorization"] == nil)
        #expect(withKey["anthropic-version"] == "2023-06-01")
        let noKey = AnthropicDialect().headers(credential: nil)
        #expect(noKey["x-api-key"] == nil)
        #expect(noKey["anthropic-version"] == "2023-06-01")
    }

    @Test("kind 'anthropic' resolves to a working dialect")
    func anthropicKindResolves() throws {
        #expect(EndpointDialects.resolve(kind: "anthropic") != nil)
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

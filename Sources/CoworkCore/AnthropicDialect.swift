import Foundation

/// The Anthropic Messages API (`POST /v1/messages`) as an endpoint dialect.
///
/// It differs from the OpenAI shape in every part the dialect owns: the request
/// carries `max_tokens` as a *required* field, messages are content-block arrays
/// rather than plain strings, tool calls are `tool_use` blocks, tools carry
/// `input_schema`, auth is `x-api-key` (not a bearer token) plus a required
/// version header, and completion is a `stop_reason` with its own vocabulary.
/// Each of those is normalized here so the conversation loop and the verdict layer
/// stay provider-neutral — a worker on a local Anthropic-serving endpoint (oMLX)
/// and one on api.anthropic.com go through the same code.
public struct AnthropicDialect: EndpointDialect {
    public init() {}

    /// Anthropic rejects a request without `max_tokens`. When the caller sets none,
    /// send a bounded default rather than omitting it — the loop still owns the real
    /// budget, this only satisfies the API's hard requirement.
    static let defaultMaxTokens = 4096
    static let version = "2023-06-01"

//: @use-case:endpoint.anthropic.local_messages_dispatch_succeeds
    public func encodeRequest(model: String, maxTokens: Int?,
                              messages: [EndpointMessage], tools: [EndpointTool]) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens ?? Self.defaultMaxTokens,
            "messages": messages.map(encodeMessage),
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                ["name": tool.name,
                 "description": tool.description,
                 "input_schema": tool.inputSchema] as [String: Any]
            }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    public func decodeResponse(_ data: Data) throws -> EndpointDialectResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else {
            throw EndpointConversation.Failure(
                state: .failed, diagnostics: ["endpoint.malformed-response"])
        }
        // Text is the concatenation of every text block; tool_use blocks become
        // normalized tool calls whose arguments are the JSON-encoded `input`.
        var text = ""
        var calls: [EndpointToolCall] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                text += block["text"] as? String ?? ""
            case "tool_use":
                let input = block["input"] as? [String: Any] ?? [:]
                let arguments = (try? JSONSerialization.data(withJSONObject: input))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                calls.append(EndpointToolCall(
                    id: block["id"] as? String ?? "",
                    name: block["name"] as? String ?? "",
                    arguments: arguments))
            default:
                break
            }
        }
        return EndpointDialectResponse(
            text: text,
            reasoning: nil,
            toolCalls: calls,
            finishReason: normalize(stopReason: json["stop_reason"] as? String))
    }

    public func headers(credential: Credential?) -> [String: String] {
        var headers = ["anthropic-version": Self.version]
        if let credential {
            headers["x-api-key"] = credential.exposeForAuthorizationHeader()
        }
        return headers
    }

    /// Map Anthropic's `stop_reason` onto the shared verdict vocabulary. An
    /// unknown reason is passed through untranslated so the verdict refuses it
    /// rather than guessing it was fine.
    private func normalize(stopReason: String?) -> String {
        switch stopReason {
        case "end_turn", "stop_sequence": return "stop"
        case "max_tokens": return "length"
        case "tool_use": return "tool_calls"
        case let other?: return other
        case nil: return "<absent>"
        }
    }

    private func encodeMessage(_ message: EndpointMessage) -> [String: Any] {
        switch message {
        case let .user(text):
            return ["role": "user", "content": text]
        case let .assistant(text, _, toolCalls):
            var blocks: [[String: Any]] = []
            if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
            for call in toolCalls {
                let input = (try? JSONSerialization.jsonObject(
                    with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
                blocks.append(["type": "tool_use", "id": call.id,
                               "name": call.name, "input": input])
            }
            return ["role": "assistant", "content": blocks]
        case let .toolResult(id, content):
            return ["role": "user",
                    "content": [["type": "tool_result", "tool_use_id": id, "content": content]]]
        }
    }
}

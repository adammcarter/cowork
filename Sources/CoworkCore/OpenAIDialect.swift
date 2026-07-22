import Foundation

public struct OpenAIDialect: EndpointDialect {
    public init() {}

    public func encodeRequest(model: String, maxTokens: Int?,
                              messages: [EndpointMessage], tools: [EndpointTool]) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map(encodeMessage),
            "stream": false,
            "tools": tools.map { tool in
                ["type": "function", "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.inputSchema,
                ]] as [String: Any]
            },
        ]
        if let maxTokens { body["max_tokens"] = maxTokens }
        return try JSONSerialization.data(withJSONObject: body)
    }

    public func decodeResponse(_ data: Data) throws -> EndpointDialectResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any]
        else {
            throw EndpointConversation.Failure(
                state: .failed, diagnostics: ["endpoint.malformed-response"])
        }
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).map { call in
            let function = call["function"] as? [String: Any] ?? [:]
            return EndpointToolCall(
                id: call["id"] as? String ?? "",
                name: function["name"] as? String ?? "",
                arguments: function["arguments"] as? String ?? "{}")
        }
        return EndpointDialectResponse(
            text: message["content"] as? String ?? "",
            reasoning: (message["reasoning_content"] as? String)
                ?? (message["reasoning"] as? String),
            toolCalls: calls,
            finishReason: first["finish_reason"] as? String ?? "<absent>")
    }

    private func encodeMessage(_ message: EndpointMessage) -> [String: Any] {
        switch message {
        case let .user(text):
            return ["role": "user", "content": text]
        case let .assistant(text, reasoning, toolCalls):
            var encoded: [String: Any] = ["role": "assistant", "content": text]
            if let reasoning { encoded["reasoning_content"] = reasoning }
            if !toolCalls.isEmpty {
                encoded["tool_calls"] = toolCalls.map { call in
                    ["id": call.id, "type": "function",
                     "function": ["name": call.name, "arguments": call.arguments]] as [String: Any]
                }
            }
            return encoded
        case let .toolResult(id, content):
            return ["role": "tool", "tool_call_id": id, "content": content]
        }
    }
}

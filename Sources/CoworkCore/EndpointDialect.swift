import Foundation

/// Provider-neutral values retained by the conversation between HTTP exchanges.
public enum EndpointMessage: @unchecked Sendable {
    case user(String)
    case assistant(text: String, reasoning: String?, toolCalls: [EndpointToolCall])
    case toolResult(id: String, content: String)
}

public struct EndpointToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct EndpointTool: @unchecked Sendable {
    public let name: String
    public let description: String
    public let inputSchema: [String: Any]

    public init(name: String, description: String, inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct EndpointDialectResponse: Sendable {
    public let text: String
    public let reasoning: String?
    public let toolCalls: [EndpointToolCall]
    public let finishReason: String

    public init(text: String, reasoning: String?, toolCalls: [EndpointToolCall],
                finishReason: String) {
        self.text = text
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.finishReason = finishReason
    }
}

/// The complete provider-shaped seam. Location, authentication, transport, the
/// conversation loop, and verdict policy deliberately remain outside it.
public protocol EndpointDialect: Sendable {
    func encodeRequest(model: String, maxTokens: Int?, messages: [EndpointMessage],
                       tools: [EndpointTool]) throws -> Data
    func decodeResponse(_ data: Data) throws -> EndpointDialectResponse
}

public enum EndpointDialects {
    public static func resolve(kind: String) -> (any EndpointDialect)? {
        switch kind {
        case "openai_compatible": OpenAIDialect()
        default: nil
        }
    }
}

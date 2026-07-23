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
    /// A **normalized** completion signal, not a raw provider string. Each dialect
    /// maps its provider's vocabulary onto the shared set the verdict layer reads:
    /// `stop` (clean finish), `length` (truncated), `tool_calls` (continuation).
    /// Any other value is passed through so the verdict refuses it rather than
    /// guessing — a provider that invents a signal is not assumed successful.
    public let finishReason: String

    public init(text: String, reasoning: String?, toolCalls: [EndpointToolCall],
                finishReason: String) {
        self.text = text
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.finishReason = finishReason
    }
}

/// The complete provider-shaped seam. Location, transport, the conversation loop,
/// and verdict policy remain outside it — but **authentication is provider-shaped**
/// and lives here: OpenAI carries a bearer token, Anthropic an `x-api-key` plus a
/// required version header. Assuming one auth scheme for every endpoint was wrong,
/// so the dialect declares how a credential becomes headers.
public protocol EndpointDialect: Sendable {
    func encodeRequest(model: String, maxTokens: Int?, messages: [EndpointMessage],
                       tools: [EndpointTool]) throws -> Data
    func decodeResponse(_ data: Data) throws -> EndpointDialectResponse

    /// The request headers this provider's API requires, including how the
    /// credential is presented. `credential` is nil when none is configured (a
    /// local proxy may need none). The credential is used here at one point and
    /// never stored, logged, or passed to a child.
    func headers(credential: Credential?) -> [String: String]
}

public enum EndpointDialects {
    public static func resolve(kind: String) -> (any EndpointDialect)? {
        switch kind {
        case "openai_compatible": OpenAIDialect()
        case "anthropic": AnthropicDialect()
        default: nil
        }
    }
}

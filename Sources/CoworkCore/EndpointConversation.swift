import Foundation

/// The stateful, bounded conversation shared by one-shot and interactive endpoints.
/// Provider location, credentials, and HTTP request construction stay outside this type.
public final class EndpointConversation: @unchecked Sendable {
    public typealias HTTPBoundary = @Sendable (Data) async throws -> Data

    private static let maxTurns = 8

    private var messages: [EndpointMessage] = []
    private let model: String
    private let maxTokens: Int?
    private let tools: [EndpointTool]
    private let dialect: any EndpointDialect
    private let http: HTTPBoundary
    private let executeTool: (String, String) -> String

    public init(model: String, maxTokens: Int? = nil, tools: [EndpointTool],
                dialect: any EndpointDialect, http: @escaping HTTPBoundary,
                executeTool: @escaping (String, String) -> String) {
        self.model = model
        self.maxTokens = maxTokens
        self.tools = tools
        self.dialect = dialect
        self.http = http
        self.executeTool = executeTool
    }

    public func turn(_ prompt: String) async -> Outcome {
        messages.append(.user(prompt))
        var transcript = ""

        for turn in 1...Self.maxTurns {
            let step: EndpointDialectResponse
            do {
                let request = try dialect.encodeRequest(
                    model: model, maxTokens: maxTokens, messages: messages, tools: tools)
                step = try dialect.decodeResponse(await http(request))
            } catch let error as Failure {
                return Outcome(state: error.state, text: "", diagnostics: error.diagnostics,
                               transcript: transcript)
            } catch {
                return Outcome(state: .failed, text: "",
                               diagnostics: ["endpoint.unexpected", "\(error)"],
                               transcript: transcript)
            }

            let content = step.text
            if let reasoning = step.reasoning, !reasoning.isEmpty {
                transcript += "[turn \(turn)] thinking: \(reasoning)\n"
            }
            if !content.isEmpty { transcript += "[turn \(turn)] said: \(content)\n" }

            switch Verdict.endpoint(finishReason: step.finishReason) {
            case let .terminal(state, diagnostics):
                messages.append(.assistant(text: content, reasoning: step.reasoning,
                                           toolCalls: step.toolCalls))
                return Outcome(state: state, text: content, diagnostics: diagnostics,
                               transcript: transcript)

            case .toolCalls:
//: @use-case:truth.endpoint.tool_calls_declared_but_absent_is_failed
                guard !step.toolCalls.isEmpty else {
                    return Outcome(state: .failed, text: content,
                                   diagnostics: ["endpoint.tool-calls-absent"],
                                   transcript: transcript)
                }
//: @use-case:end truth.endpoint.tool_calls_declared_but_absent_is_failed
                messages.append(.assistant(text: content, reasoning: step.reasoning,
                                           toolCalls: step.toolCalls))
                for call in step.toolCalls {
                    let result = executeTool(call.name, call.arguments)
                    transcript += "[turn \(turn)] tool \(call.name)(\(call.arguments)) -> \(result.prefix(160))\n"
                    messages.append(.toolResult(id: call.id, content: result))
                }
            }
        }

//: @use-case:endpoint.conversation.turn_cap_stops_a_runaway_tool_loop
        return Outcome(state: .failed, text: "",
                       diagnostics: ["endpoint.turn-limit", "max_turns=\(Self.maxTurns)"],
                       transcript: transcript)
//: @use-case:end endpoint.conversation.turn_cap_stops_a_runaway_tool_loop
    }

    public struct Outcome: Sendable {
        public let state: DispatchRecord.State
        public let text: String
        public let diagnostics: [String]
        public let transcript: String
    }

    public struct Failure: Error {
        public let state: DispatchRecord.State
        public let diagnostics: [String]

        public init(state: DispatchRecord.State, diagnostics: [String]) {
            self.state = state
            self.diagnostics = diagnostics
        }
    }
}

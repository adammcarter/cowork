import Foundation

/// An endpoint held open across turns, so `send` and `finish` are as real for a
/// model endpoint as for a CLI worker.
///
/// A CLI worker keeps a warm process; an endpoint keeps nothing of its own. But
/// cowork owns the message list the endpoint loop is built from (ADR 000), so the
/// warmth lives in the retained `EndpointConversation`: a `send` appends to it,
/// and the next turn continues with the whole history. That is
/// why `capabilities` can honestly report `supports_message` for an endpoint — and
/// why, until this existed, that report was a promise nothing kept.
///
public final class EndpointSession: @unchecked Sendable {
    private let conversation: EndpointConversation

    /// There is no process, so there is nothing to outlive the conversation. The
    /// session is ready for another turn until `finish` or an idle timeout ends it.
    public var workerAlive: Bool { true }

    /// An endpoint has no continuation handle of its own — continuing means
    /// replaying cowork's own message list, which is `follow_up`, a different
    /// mechanism. Reported nil so capabilities stays truthful about it.
    public var lastSessionID: String? { nil }

    public init(conversation: EndpointConversation) {
        self.conversation = conversation
    }

    /// One turn on the retained conversation, adapted to the session transport API.
    public func turn(_ prompt: String) async -> InteractiveSession.Turn {
        let outcome = await conversation.turn(prompt)
        return .init(state: outcome.state, text: outcome.text,
                     diagnostics: outcome.diagnostics, transcript: outcome.transcript,
                     workerAlive: true)
    }

    /// Nothing to tear down — there is no process. Present so a caller can treat an
    /// endpoint session and a CLI session the same way.
    public func close() {}
}

extension EndpointSession: SessionTransport {
    public var isAlive: Bool { workerAlive }
    public var continuation: String? { lastSessionID }
}

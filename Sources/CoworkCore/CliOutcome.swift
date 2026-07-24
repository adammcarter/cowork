import Foundation

/// What a CLI one-shot dispatch declared: the verdict, the answer, the diagnostics
/// beside it, and — when the agent hands one back — a continuation handle.
///
/// One value shared by every CLI dialect. `CliBackend.Outcome` and
/// the per-agent outcome types were field-identical structs; the fork abstraction
/// makes them one, so a driver's `parse` and the runner that calls it speak the
/// same type rather than re-declaring it per backend.
public struct CliOutcome: Sendable, Equatable {
    public let state: DispatchRecord.State
    public let text: String
    public let diagnostics: [String]
    public var transcript: String
    /// The agent's own handle for continuing this context, read from the key the
    /// row named. Nil when the agent gives none.
    public var continuation: String?

    public init(state: DispatchRecord.State, text: String, diagnostics: [String],
                transcript: String = "", continuation: String? = nil) {
        self.state = state
        self.text = text
        self.diagnostics = diagnostics
        self.transcript = transcript
        self.continuation = continuation
    }
}

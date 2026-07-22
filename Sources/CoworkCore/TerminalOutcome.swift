import Foundation

/// How a dispatch ends — the record it leaves, the event it emits, the code it
/// exits with — as a value that can be inspected before any of it happens.
///
/// Every dispatch reaches a terminal event, no exceptions (ADR 003 rule 5). That
/// rule was enforced inside a `Never`-returning function in the executable target,
/// where nothing could check it. The exiting still belongs there; the description
/// of the ending does not.
public struct TerminalOutcome {
    public let closing: DispatchRecord
    public let event: String
    public let detail: String?
    public let exitCode: Int32

    public init(record: DispatchRecord, state: DispatchRecord.State, result: String,
                diagnostics: [String], continuation: String? = nil) {
        var closing = record
        closing.state = state
        closing.result = result
        // Replaced, not appended: the diagnostics a dispatch ends with should
        // describe its ending, not a pile gathered on the way there.
        closing.diagnostics = diagnostics
        // Recorded on the way out, so a later `follow_up` has something real to
        // continue from rather than cowork inventing one.
        closing.continuation = continuation
        self.closing = closing

        self.event = state.rawValue
        // Absent rather than empty. An empty detail string is noise in a stream
        // readers are meant to be able to skim.
        self.detail = diagnostics.isEmpty ? nil : diagnostics.joined(separator: ",")
        // Only success looks like success to a shell. A timeout or a cancellation
        // is not a smaller kind of working.
        self.exitCode = state == .succeeded ? 0 : 1
    }

    /// The teardown POLICY (ADR 002 rule 10), as a value tests can reach: the
    /// dispatch's `on_terminal` command runs only when it SUCCEEDED. Every other
    /// ending keeps its workspace — unconditional cleanup destroys the evidence a
    /// failure exists to provide. The core runs the command without knowing what it
    /// is for (rule 9); this function only decides WHETHER.
    public static func teardownCommand(for state: DispatchRecord.State,
                                       record: DispatchRecord) -> String? {
        guard state == .succeeded else { return nil }
        return record.onTerminal
    }
}

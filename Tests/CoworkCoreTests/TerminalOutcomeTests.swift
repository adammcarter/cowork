import Foundation
import Testing

@testable import CoworkCore

/// How a dispatch ends, as a value.
///
/// The closing of a dispatch — the record it leaves, the event it emits, the code
/// it exits with — lived inside a `Never`-returning function in the executable
/// target and so was never tested. It is the last thing a caller ever learns about
/// a dispatch, and ADR 003 rule 5 turns on it: every dispatch reaches a terminal
/// event, no exceptions.
@Suite("Terminal outcome")
struct TerminalOutcomeTests {
    private func record() -> DispatchRecord {
        DispatchRecord(id: "j_end", parent: "s_e", root: "s_e", backend: "claude",
                       task: "work", workspace: nil, state: .running,
                       diagnostics: ["earlier"], result: nil)
    }

    @Test("success exits zero; every other ending exits non-zero")
    func exitCodes() {
        #expect(TerminalOutcome(record: record(), state: .succeeded, result: "ok",
                                diagnostics: []).exitCode == 0)
        for state in [DispatchRecord.State.failed, .timedOut, .cancelled] {
            #expect(TerminalOutcome(record: record(), state: state, result: "",
                                    diagnostics: []).exitCode != 0,
                    "\(state.rawValue) must not look like success to a shell")
        }
    }

    /// The event names the state, so a reader following the stream learns the same
    /// fact as a reader loading the record.
    @Test("the terminal event names the state")
    func eventNamesState() {
        for state in [DispatchRecord.State.succeeded, .failed, .timedOut, .cancelled] {
            let outcome = TerminalOutcome(record: record(), state: state, result: "",
                                          diagnostics: [])
            #expect(outcome.event == state.rawValue)
        }
    }

    /// Diagnostics ride along when there are any, and are absent — not empty — when
    /// there are none. An empty detail string is noise in the stream.
    @Test("diagnostics travel with the event, or are absent entirely")
    func diagnosticsDetail() {
        let withDiags = TerminalOutcome(record: record(), state: .failed, result: "",
                                        diagnostics: ["a", "b"])
        #expect(withDiags.detail == "a,b")

        let without = TerminalOutcome(record: record(), state: .succeeded, result: "ok",
                                      diagnostics: [])
        #expect(without.detail == nil, "an empty detail is noise, not information")
    }

    /// The closing record replaces the running one's fields rather than appending
    /// to them: the diagnostics a dispatch ends with are the ones that describe its
    /// ending, not a pile accumulated along the way.
    @Test("the closing record carries the ending's own state, result and diagnostics")
    func closingRecord() {
        let closing = TerminalOutcome(record: record(), state: .failed, result: "partial",
                                      diagnostics: ["cli.no-declared-result"]).closing
        #expect(closing.state == .failed)
        #expect(closing.result == "partial")
        #expect(closing.diagnostics == ["cli.no-declared-result"])
        #expect(closing.state.isTerminal, "a dispatch may only close into a terminal state")
    }

    /// Recorded on the way out so a later `follow_up` continues from something real
    /// rather than cowork inventing a handle.
    @Test("a continuation handle is kept when the worker gave one, and nil when it did not")
    func continuationKept() {
        let with = TerminalOutcome(record: record(), state: .succeeded, result: "ok",
                                   diagnostics: [], continuation: "sess-9").closing
        #expect(with.continuation == "sess-9")

        let without = TerminalOutcome(record: record(), state: .succeeded, result: "ok",
                                      diagnostics: []).closing
        #expect(without.continuation == nil, "inventing a handle is worse than admitting there is none")
    }

    // MARK: on_terminal — teardown is conditional on outcome (ADR 002 rules 9–10)

    private func record(onTerminal: String?) -> DispatchRecord {
        var r = record()
        r.onTerminal = onTerminal
        return r
    }

    /// The core runs a command and does not know what it is for; sugar passes
    /// `git worktree remove`. The POLICY is rule 10's table: succeeded → tear down,
    /// every other ending → KEEP, because the evidence is the point.
    @Test("teardown runs only on success")
    func teardownOnlyOnSuccess() {
        let r = record(onTerminal: "rm -rf /tmp/ws")
        #expect(TerminalOutcome.teardownCommand(for: .succeeded, record: r) == "rm -rf /tmp/ws")
        for state in [DispatchRecord.State.failed, .timedOut, .cancelled] {
            #expect(TerminalOutcome.teardownCommand(for: state, record: r) == nil,
                    "\(state.rawValue) keeps its workspace — unconditional cleanup destroys evidence")
        }
    }

    @Test("no on_terminal command means no teardown, whatever the ending")
    func noCommandNoTeardown() {
        let r = record(onTerminal: nil)
        #expect(TerminalOutcome.teardownCommand(for: .succeeded, record: r) == nil)
    }

    /// The hook survives the round trip: a supervisor is a fresh process that reloads
    /// the record, so a hook that does not persist is a hook that never runs.
    @Test("on_terminal persists through save and load")
    func onTerminalPersists() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-onterm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try Store.$rootOverride.withValue(home) {
            try Store.prepare()
            var r = record(onTerminal: "echo done")
            r = DispatchRecord(id: "j_hook", parent: r.parent, root: r.root, backend: r.backend,
                               task: r.task, workspace: r.workspace, state: r.state,
                               diagnostics: r.diagnostics, result: r.result)
            r.onTerminal = "echo done"
            try r.save()
            #expect(DispatchRecord.load("j_hook")?.onTerminal == "echo done")
        }
    }
}

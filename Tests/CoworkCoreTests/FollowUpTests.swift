import Foundation
import Testing

@testable import CoworkCore

/// `follow_up(id, task) -> id` (ADR 001): a NEW dispatch carrying a finished
/// dispatch's context. It is not `send`, and the difference is not cosmetic —
/// `send` speaks to a worker that is alive, `follow_up` starts a fresh worker that
/// remembers. They map to different mechanisms and fail in different ways.
///
/// Verified live: `claude -p --resume <session_id>` genuinely
/// carries context — a second dispatch recalled a codeword given to the first.
/// The continuation handle is therefore real, and cowork must capture it.
@Suite("follow_up", .serialized)
struct FollowUpTests {
    private func withHome(_ body: () throws -> Void) throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-fu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try Store.$rootOverride.withValue(home) { try body() }
    }

    private func put(_ id: String, backend: String = "claude",
                     state: DispatchRecord.State = .succeeded,
                     continuation: String? = nil) throws {
        var r = DispatchRecord(id: id, parent: "s_a", root: "s_a", backend: backend,
                               task: "original task", workspace: "/tmp/ws",
                               state: state, diagnostics: [], result: "done")
        r.continuation = continuation
        try r.save()
    }

    private func corruptRecord(_ id: String) throws {
        try Store.writeAtomically(Data("{not json".utf8),
                                  to: Store.dispatchDir(id).appendingPathComponent("job.json"))
    }

    @Test("a finished dispatch's continuation handle is what makes follow_up possible")
    func continuationIsRecorded() throws {
        try withHome {
            try put("j_1", continuation: "sess-abc")
            #expect(DispatchRecord.load("j_1")?.continuation == "sess-abc")
        }
    }

    /// The inheritance rule: a follow-up takes everything from its predecessor
    /// except the task. Asking the caller to re-supply backend and workspace would
    /// invite them to differ, and a follow-up whose workspace differs is not a
    /// follow-up.
    @Test("a follow-up inherits backend and workspace, and takes only a new task")
    func inheritsFromPredecessor() throws {
        try withHome {
            try put("j_1", continuation: "sess-abc")
            let plan = try FollowUp.plan(from: "j_1", task: "the next thing")
            #expect(plan.backend == "claude")
            #expect(plan.workspace == "/tmp/ws")
            #expect(plan.task == "the next thing")
            #expect(plan.continuation == "sess-abc")
        }
    }

    @Test("the follow-up is a new dispatch, attributed to the one it continues")
    func attributedToPredecessor() throws {
        try withHome {
            try put("j_1", continuation: "sess-abc")
            let plan = try FollowUp.plan(from: "j_1", task: "next")
            #expect(plan.parent == "j_1",
                    "a follow-up's parent is the dispatch it continues, so the tree shows the thread")
            #expect(plan.root == "s_a", "the root is whose work it is, and that has not changed")
        }
    }

    // MARK: refusals — each names a different mistake

    @Test("following up an unknown dispatch is an error")
    func unknownDispatch() throws {
        try withHome {
            do {
                _ = try FollowUp.plan(from: "j_nope", task: "x")
                Issue.record("missing dispatch was accepted")
            } catch let error as FollowUp.Failure {
                #expect(error.description == "followup.unknown-dispatch,id=j_nope")
            }
        }
    }

    @Test("following up an unreadable record names corruption instead of an unknown dispatch")
    func unreadableDispatch() throws {
        try withHome {
            try corruptRecord("j_corrupt")
            do {
                _ = try FollowUp.plan(from: "j_corrupt", task: "x")
                Issue.record("corrupt dispatch was accepted")
            } catch let error as FollowUp.Failure {
                #expect(error.description == "followup.unreadable-record,id=j_corrupt")
                #expect(!error.description.contains("unknown-dispatch"))
            }
        }
    }

    /// A running dispatch has not produced the context a follow-up would continue.
    /// The honest answer names `send` — the caller almost certainly wants to steer
    /// the live worker, not fork a new one.
    @Test("following up a dispatch that has not finished is refused, and points at send")
    func notYetTerminal() throws {
        try withHome {
            try put("j_1", state: .running, continuation: "sess-abc")
            #expect(throws: FollowUp.Failure.self) { _ = try FollowUp.plan(from: "j_1", task: "x") }
            do { _ = try FollowUp.plan(from: "j_1", task: "x") } catch let e as FollowUp.Failure {
                #expect(e.description.contains("send"))
            }
        }
    }

    /// The failure that matters most. Without a continuation handle, a follow-up
    /// would silently become a fresh dispatch that has forgotten everything — the
    /// caller would get an answer built on no context and never know. Refusing is
    /// the only honest move.
    @Test("a dispatch with no continuation handle cannot be followed up, and is not faked")
    func noContinuationHandle() throws {
        try withHome {
            try put("j_1", continuation: nil)
            #expect(throws: FollowUp.Failure.self) { _ = try FollowUp.plan(from: "j_1", task: "x") }
            do { _ = try FollowUp.plan(from: "j_1", task: "x") } catch let e as FollowUp.Failure {
                #expect(e.description.contains("continuation"))
                #expect(!e.description.contains("starting fresh"))
            }
        }
    }

    @Test("a cancelled dispatch may still be followed up if it left a handle")
    func cancelledStillContinuable() throws {
        try withHome {
            // Cancelled is terminal and its context is real: the worker did work
            // before it was stopped, and continuing from it is legitimate.
            try put("j_1", state: .cancelled, continuation: "sess-abc")
            let plan = try FollowUp.plan(from: "j_1", task: "carry on")
            #expect(plan.continuation == "sess-abc")
        }
    }
}

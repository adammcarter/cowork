import Darwin
import Foundation
import Testing

@testable import CoworkCore

/// `send` and `finish` (ADR 001).
///
/// Every test here is about a *refusal*. The happy path is one line; the value of
/// these tools is that each way of misusing them produces a distinct, true
/// diagnostic rather than a comfortable silence. A `send` that is dropped, queued
/// for a worker that will never read it, or acknowledged for a finished dispatch
/// is the exact failure ADR 000 calls worse than having no tool at all.
@Suite("Interaction", .serialized)
struct InteractionTests {
    private let canMessage: Interaction.SupportsMessage = { _ in true }
    private let cannotMessage: Interaction.SupportsMessage = { _ in false }

    /// The test process stands in for the supervisor: it is provably alive, so
    /// `send` sees a real owner rather than a fixture pretending to be one.
    private func record(_ id: String, state: DispatchRecord.State,
                        interactive: Bool, owned: Bool = true) throws -> DispatchRecord {
        let me = Liveness.current()
        var r = DispatchRecord(id: id, parent: "s_t", root: "s_t", backend: "fixture",
                               task: "the original task", workspace: nil, state: state,
                               diagnostics: [], result: nil,
                               ownerPID: owned ? me.pid : 999_999,
                               ownerStart: owned ? me.start : 1,
                               interactive: interactive)
        try r.save()
        return r
    }

    private func withHome(_ body: () throws -> Void) throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-int-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try Store.$rootOverride.withValue(home) {
            try Store.prepare()
            try body()
        }
    }

    private func corruptRecord(_ id: String) throws {
        try Store.writeAtomically(Data("{not json".utf8),
                                  to: Store.dispatchDir(id).appendingPathComponent("job.json"))
    }

    /// Nothing may be left in the mailbox. A refusal that still queues the message
    /// is a lie with a delay on it.
    private func mailboxIsEmpty(_ id: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: Mailbox.url(id).path) else { return true }
        let receiver = try Mailbox.receive(id)
        defer { receiver.close() }
        return try receiver.next(timeout: 0.2) == nil
    }

    @Test("send to a dispatch that does not exist is an error")
    func unknownDispatch() throws {
        try withHome {
            do {
                try Interaction.send(id: "j_nope", message: "hi", supportsMessage: canMessage)
                Issue.record("missing dispatch was accepted")
            } catch let error as Interaction.Failure {
                #expect(error.description == "interaction.unknown-dispatch,id=j_nope")
            }
        }
    }

    @Test("send names an unreadable record instead of reporting an unknown dispatch")
    func unreadableDispatch() throws {
        try withHome {
            try corruptRecord("j_corrupt")
            do {
                try Interaction.send(id: "j_corrupt", message: "hi", supportsMessage: canMessage)
                Issue.record("corrupt dispatch was accepted")
            } catch let error as Interaction.Failure {
                #expect(error.description == "interaction.unreadable-record,id=j_corrupt")
                #expect(!error.description.contains("unknown-dispatch"))
            }
        }
    }

    /// ADR 001 rule 3: capabilities are facts, never comfort. A backend that cannot
    /// be messaged must make the caller branch — the alternative is accepting a
    /// message the backend will never see and letting the caller believe otherwise.
    @Test("send to a backend that cannot be messaged is refused, not silently queued")
    func unsupportedBackendIsRefused() throws {
        try withHome {
            let id = "j_unsupported"
            _ = try record(id, state: .awaitingInput, interactive: true)
            try Mailbox.create(id)

            #expect {
                try Interaction.send(id: id, message: "hi", supportsMessage: cannotMessage)
            } throws: { error in
                guard case .backendCannotBeMessaged = error as? Interaction.Failure else { return false }
                return true
            }
            #expect(try mailboxIsEmpty(id), "a refused message must not be waiting for a worker")
        }
    }

    /// A finished dispatch has no worker to speak to. Accepting the message would
    /// be a no-op that pretends — the caller would go on believing their pivot
    /// landed.
    @Test("send to a terminal dispatch is an error, not a no-op")
    func terminalDispatchIsRefused() throws {
        for state in [DispatchRecord.State.succeeded, .failed, .cancelled, .timedOut] {
            try withHome {
                let id = "j_terminal"
                _ = try record(id, state: state, interactive: true)
                try Mailbox.create(id)

                #expect {
                    try Interaction.send(id: id, message: "one more thing", supportsMessage: canMessage)
                } throws: { error in
                    guard case let .alreadyTerminal(_, observed) = error as? Interaction.Failure
                    else { return false }
                    return observed == state
                }
                #expect(try mailboxIsEmpty(id))
            }
        }
    }

    /// `interactive` defaults to false (ADR 001 rule 4), so the common dispatch has
    /// closed its worker's stdin and there is nobody to receive this. Saying so is
    /// more useful than "worker gone": the caller's mistake was at `dispatch`.
    @Test("send to a non-interactive dispatch names that as the reason")
    func nonInteractiveIsRefused() throws {
        try withHome {
            let id = "j_oneshot"
            _ = try record(id, state: .running, interactive: false)

            #expect {
                try Interaction.send(id: id, message: "hi", supportsMessage: canMessage)
            } throws: { error in
                guard case .notInteractive = error as? Interaction.Failure else { return false }
                return true
            }
        }
    }

    /// A dispatch whose supervisor died is not awaiting anything, whatever the
    /// record last said. The owner's liveness is checked by (pid, start) so a
    /// recycled pid cannot present itself as a live worker.
    @Test("send to a dispatch whose worker is gone reports the worker as gone")
    func deadWorkerIsReported() throws {
        try withHome {
            let id = "j_dead"
            _ = try record(id, state: .awaitingInput, interactive: true, owned: false)
            try Mailbox.create(id)

            #expect {
                try Interaction.send(id: id, message: "hi", supportsMessage: canMessage)
            } throws: { error in
                guard case .workerGone = error as? Interaction.Failure else { return false }
                return true
            }
        }
    }

    @Test("send to a live interactive worker delivers the message")
    func sendDelivers() throws {
        try withHome {
            let id = "j_live"
            _ = try record(id, state: .awaitingInput, interactive: true)
            try Mailbox.create(id)
            let receiver = try Mailbox.receive(id)
            defer { receiver.close() }

            try Interaction.send(id: id, message: "actually, use tabs", supportsMessage: canMessage)
            let got = try receiver.next(timeout: 2)
            #expect(got?.kind == .message)
            #expect(got?.text == "actually, use tabs")
        }
    }

    /// A worker mid-turn is still `running`, and messaging it is the whole point of
    /// the proven Claude behaviour: two messages to one live process, each
    /// producing its own declared result. Refusing here would make `send` useless
    /// for exactly the pivot it exists for.
    @Test("send to a running interactive worker is allowed, not only an idle one")
    func sendToRunningWorker() throws {
        try withHome {
            let id = "j_busy"
            _ = try record(id, state: .running, interactive: true)
            try Mailbox.create(id)
            let receiver = try Mailbox.receive(id)
            defer { receiver.close() }

            try Interaction.send(id: id, message: "extra detail", supportsMessage: canMessage)
            #expect(try receiver.next(timeout: 2)?.text == "extra detail")
        }
    }

    @Test("finish posts an end to a live interactive worker")
    func finishPosts() throws {
        try withHome {
            let id = "j_finishing"
            _ = try record(id, state: .awaitingInput, interactive: true)
            try Mailbox.create(id)
            let receiver = try Mailbox.receive(id)
            defer { receiver.close() }

            // Nothing is reading on the supervisor's behalf here, so `finish`
            // observes the state it can honestly observe: not yet terminal.
            let observed = try Interaction.finish(id: id, settle: 0.3)
            #expect(try receiver.next(timeout: 2)?.kind == .finish)
            #expect(observed == .awaitingInput, "the observed state is reported, never assumed")
        }
    }

    /// `finish` differs from `send` deliberately: its postcondition — this dispatch
    /// is over — already holds for a terminal dispatch, so reporting the true state
    /// is honest where a `send` acknowledgement would not be. Nothing is pretended;
    /// the caller is told what state it is in.
    @Test("finish on an already-terminal dispatch reports its state without pretending")
    func finishIsIdempotent() throws {
        try withHome {
            let id = "j_done"
            _ = try record(id, state: .succeeded, interactive: true)
            try Mailbox.create(id)
            #expect(try Interaction.finish(id: id, settle: 0.2) == .succeeded)
        }
    }

    /// A one-shot dispatch has nothing to release. `cancel` is the tool that stops
    /// it, and saying so beats a success the caller would misread as a stop.
    @Test("finish on a non-interactive dispatch is refused and points at cancel")
    func finishNonInteractive() throws {
        try withHome {
            let id = "j_oneshot2"
            _ = try record(id, state: .running, interactive: false)
            #expect {
                _ = try Interaction.finish(id: id, settle: 0.2)
            } throws: { error in
                guard case .notInteractive = error as? Interaction.Failure else { return false }
                return "\(error)".contains("cancel")
            }
        }
    }
}

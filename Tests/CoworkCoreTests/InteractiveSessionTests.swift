import Darwin
import Foundation
import Testing

@testable import CoworkCore

/// The supervisor's half of an interactive dispatch (ADR 001 lifecycle + rule 2).
///
/// The distinction under test throughout: **a turn ending is not a dispatch
/// ending**. `awaiting_input` is a real state, and a session that collapsed it
/// into `succeeded` would destroy the worker's context at exactly the moment a
/// caller wanted to use it.
@Suite("InteractiveSession", .serialized)
struct InteractiveSessionTests {
    private func withHome(_ body: (DispatchRecord) async throws -> Void) async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-sess-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try await Store.$rootOverride.withValue(home) {
            try Store.prepare()
            let me = Liveness.current()
            var r = DispatchRecord(id: "j_sess01", parent: "s_t", root: "s_t", backend: "fixture",
                                   task: "first task", workspace: nil, state: .running,
                                   diagnostics: [], result: nil,
                                   ownerPID: me.pid, ownerStart: me.start, interactive: true)
            try r.save()
            try Mailbox.create(r.id)
            try await body(r)
        }
    }

    private func events() -> [String] {
        guard let text = try? String(contentsOf: Store.eventStream, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["event"] as? String
        }
    }

    /// A message posted from another task stands in for the orchestrator. It is
    /// posted only once the session is provably parked, so the test pins the real
    /// ordering rather than racing it.
    private func sendWhenAwaiting(_ id: String, _ message: Mailbox.Message) {
        let root = Store.root
        DispatchQueue.global().async {
            Store.$rootOverride.withValue(root) {
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    if DispatchRecord.load(id)?.state == .awaitingInput { break }
                    usleep(50_000)
                }
                try? Mailbox.post(id, message)
            }
        }
    }

    @Test("a turn's outcome parks the dispatch in awaiting_input, and a message resumes it")
    func turnsThenFinish() async throws {
        try await withHome { record in
            sendWhenAwaiting(record.id, .init(kind: .message, text: "second task"))
            let session = InteractiveSession(record: record, idleTimeout: 10)

            let seen = Tasks()
            let conclusion = await session.run { prompt in
                seen.append(prompt)
                if prompt == "second task" {
                    // The dispatch ends on `finish`, so the second turn parks too —
                    // until the finish posted below arrives.
                    sendWhenAwaiting(record.id, .init(kind: .finish))
                }
                return .init(state: .succeeded, text: "did: \(prompt)", diagnostics: [])
            }

            #expect(seen.all == ["first task", "second task"],
                    "the worker's context is reused; each message is its own turn")
            #expect(conclusion.state == .succeeded)
            #expect(conclusion.result == "did: second task", "the last turn is the declared result")
            #expect(events() == ["awaiting_input", "running", "awaiting_input", "succeeded"])
        }
    }

    /// ADR 001 rule 2, stated as sharply as it can be: a worker declaring a turn
    /// failed has not declared the dispatch failed. Ending here would throw away
    /// the live context precisely when the caller needs it to correct course.
    @Test("a turn that declares failure still parks in awaiting_input, not a terminal state")
    func failedTurnIsNotAFailedDispatch() async throws {
        try await withHome { record in
            sendWhenAwaiting(record.id, .init(kind: .message, text: "try again"))
            let session = InteractiveSession(record: record, idleTimeout: 10)

            let conclusion = await session.run { prompt in
                prompt == "first task"
                    ? .init(state: .failed, text: "could not find the file", diagnostics: ["cli.declared-error"])
                    : { sendWhenAwaiting(record.id, .init(kind: .finish))
                        return .init(state: .succeeded, text: "found it", diagnostics: []) }()
            }

            #expect(conclusion.state == .succeeded, "the dispatch's verdict is the turn it ended on")
            #expect(conclusion.result == "found it")
            #expect(events().contains("awaiting_input"))
        }
    }

    /// A warm worker holds a live process *and* its context. Nobody may be relied
    /// upon to call `finish`, so the supervisor bounds the cost itself — otherwise
    /// the leak ADR 001 accepts becomes unbounded.
    @Test("an interactive dispatch nobody finishes times out rather than living forever")
    func idleTimeoutEndsAWarmWorker() async throws {
        try await withHome { record in
            let session = InteractiveSession(record: record, idleTimeout: 0.5)
            let began = Date()
            let conclusion = await session.run { _ in
                .init(state: .succeeded, text: "turn done", diagnostics: [])
            }
            #expect(Date().timeIntervalSince(began) < 5)
            #expect(conclusion.state == .timedOut, "an abandoned warm worker is not a success")
            #expect(conclusion.diagnostics.contains("interaction.idle-timeout"))
            #expect(events().last == "timed_out")
        }
    }

    /// The third way a dispatch ends. A worker that has exited cannot take another
    /// message, so parking in `awaiting_input` would advertise a `send` that could
    /// only ever be refused.
    @Test("a worker that exits ends the dispatch with its own declared outcome")
    func workerExitEndsTheDispatch() async throws {
        try await withHome { record in
            let session = InteractiveSession(record: record, idleTimeout: 30)
            let began = Date()
            let conclusion = await session.run { _ in
                .init(state: .failed, text: "crashed", diagnostics: ["cli.declared-error"],
                      workerAlive: false)
            }
            #expect(Date().timeIntervalSince(began) < 5, "a dead worker must not wait out the idle timeout")
            #expect(conclusion.state == .failed)
            #expect(conclusion.diagnostics.contains("interaction.worker-exited"))
        }
    }

    /// Bulk output accumulates across turns rather than being replaced: the log of
    /// an interactive dispatch is the whole conversation, not just its last word.
    @Test("the transcript accumulates across turns")
    func transcriptAccumulates() async throws {
        try await withHome { record in
            sendWhenAwaiting(record.id, .init(kind: .message, text: "second"))
            let session = InteractiveSession(record: record, idleTimeout: 10)
            let conclusion = await session.run { prompt in
                if prompt == "second" { sendWhenAwaiting(record.id, .init(kind: .finish)) }
                return .init(state: .succeeded, text: "ok", diagnostics: [],
                             transcript: "said: \(prompt)\n")
            }
            #expect(conclusion.transcript == "said: first task\nsaid: second\n")
        }
    }
}

/// A tiny lock around the prompts a session handed the worker, collected from the
/// turn closure across suspension points.
final class Tasks: @unchecked Sendable {
    private var items: [String] = []
    private let lock = NSLock()
    func append(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

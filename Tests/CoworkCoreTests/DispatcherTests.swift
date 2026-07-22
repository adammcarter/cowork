import Darwin
import Foundation
import Testing

@testable import CoworkCore

/// The dispatcher's contract (ADR 001 + ADR 003 rules 0, 1, 5).
///
/// NOTE: this suite points the store at a temporary home via `COWORK_HOME`, which
/// is a **process-global**. It therefore cannot run beside another suite that does
/// the same, and the target is run with `--no-parallel`. Injecting the store root
/// instead of reading a global is the better design; it is a bigger change than
/// this step earns, and it is recorded here rather than hidden.
///
/// A stand-in "supervisor" is used: `/bin/sh` sleeping. These tests pin the
/// *dispatcher's* promises — returns immediately, records before spawning, always
/// reaches a terminal event — not any backend's behaviour.
@Suite("Dispatcher", .serialized)
struct DispatcherTests {
    /// A stand-in supervisor: `launch` re-execs `<executable> __supervise`, so the
    /// fixture must be something that ignores that argument and stays alive.
    private func makeStandInSupervisor(in dir: URL) throws -> URL {
        let script = dir.appendingPathComponent("stand-in-supervisor")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "#!/bin/sh\nsleep 300\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func withHome(_ body: (Dispatcher) throws -> Void) throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-disp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let supervisor = try makeStandInSupervisor(in: home)
        try Store.$rootOverride.withValue(home) { try body(Dispatcher(executable: supervisor)) }
    }

    private func events(_ home: String) -> [String] {
        let url = URL(fileURLWithPath: home).appendingPathComponent("events.ndjson")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["event"] as? String
        }
    }

    /// The whole point of the supervisor: the contract says `dispatch` returns an
    /// id, not a result. If it blocked, `status` would always be terminal, `wait`
    /// pointless, and `send` and `cancel` impossible.
    @Test("dispatch returns immediately, before the work is done")
    func returnsImmediately() throws {
        try withHome { dispatcher in
            let began = Date()
            let started = try dispatcher.start(task: "300", backend: "fixture",
                                               workspace: nil, parent: "s_t", root: "s_t")
            let elapsed = Date().timeIntervalSince(began)
            defer { close(started.deathPipeWriteEnd); dispatcher.cancel(id: started.id, grace: 0.2) }

            #expect(elapsed < 1.0, "dispatch must not wait for the worker")
            let record = DispatchRecord.load(started.id)
            #expect(record?.state == .running, "the work is live, not finished")
        }
    }

    @Test("the record exists before the supervisor does, and names its owner")
    func recordPrecedesProcess() throws {
        try withHome { dispatcher in
            let started = try dispatcher.start(task: "300", backend: "fixture",
                                               workspace: nil, parent: "s_t", root: "s_t")
            defer { close(started.deathPipeWriteEnd); dispatcher.cancel(id: started.id, grace: 0.2) }

            let record = try #require(DispatchRecord.load(started.id))
            let pid = try #require(record.ownerPID)
            let start = try #require(record.ownerStart)
            #expect(Liveness.isAlive(pid: pid, start: start),
                    "the owner must be identifiable, or reconciliation cannot tell abandoned from running")
            #expect(events(Store.root.path).prefix(2) == ["queued", "started"])
        }
    }

    @Test("an id is minted per dispatch and never reused")
    func idsAreUnique() throws {
        try withHome { dispatcher in
            var ids = Set<String>()
            var handles: [Dispatcher.Started] = []
            for _ in 0..<5 {
                let s = try dispatcher.start(task: "300", backend: "fixture",
                                             workspace: nil, parent: "s_t", root: "s_t")
                handles.append(s)
                ids.insert(s.id)
            }
            defer { handles.forEach { close($0.deathPipeWriteEnd); dispatcher.cancel(id: $0.id, grace: 0.2) } }
            #expect(ids.count == 5)
        }
    }

    @Test("cancel terminates the worker and reaches a terminal event")
    func cancelIsTerminal() throws {
        try withHome { dispatcher in
            let started = try dispatcher.start(task: "300", backend: "fixture",
                                               workspace: nil, parent: "s_t", root: "s_t")
            defer { close(started.deathPipeWriteEnd) }
            let before = try #require(DispatchRecord.load(started.id))
            let pid = try #require(before.ownerPID)

            #expect(dispatcher.cancel(id: started.id, grace: 0.2))

            let after = try #require(DispatchRecord.load(started.id))
            #expect(after.state == .cancelled)
            #expect(after.state.isTerminal)
            #expect(kill(pid, 0) != 0 || Liveness.startTime(of: pid) == nil,
                    "cancel must leave nothing running")
            #expect(events(Store.root.path).last == "cancelled")
        }
    }

    @Test("cancelling an already-terminal dispatch is a no-op, not a second event")
    func cancelIsIdempotent() throws {
        try withHome { dispatcher in
            let started = try dispatcher.start(task: "300", backend: "fixture",
                                               workspace: nil, parent: "s_t", root: "s_t")
            defer { close(started.deathPipeWriteEnd) }
            #expect(dispatcher.cancel(id: started.id, grace: 0.2))
            let count = events(Store.root.path).filter { $0 == "cancelled" }.count
            #expect(dispatcher.cancel(id: started.id, grace: 0.2))
            #expect(events(Store.root.path).filter { $0 == "cancelled" }.count == count,
                    "a dispatch reaches a terminal event once, not once per caller")
        }
    }

    @Test("wait returns the live state at the cap rather than blocking forever")
    func waitHasAHardCap() throws {
        try withHome { dispatcher in
            let started = try dispatcher.start(task: "300", backend: "fixture",
                                               workspace: nil, parent: "s_t", root: "s_t")
            defer { close(started.deathPipeWriteEnd); dispatcher.cancel(id: started.id, grace: 0.2) }

            let began = Date()
            let record = dispatcher.wait(id: started.id, timeout: 1)
            #expect(Date().timeIntervalSince(began) < 3)
            #expect(record?.state == .running, "'still running' is an honest answer")
        }
    }

    @Test("wait returns as soon as the dispatch is terminal")
    func waitReturnsOnTerminal() throws {
        try withHome { dispatcher in
            let started = try dispatcher.start(task: "300", backend: "fixture",
                                               workspace: nil, parent: "s_t", root: "s_t")
            defer { close(started.deathPipeWriteEnd) }
            // A task-local does not cross into a GCD thread, so the scope is
            // re-entered here. That is the cost of the store root being ambient
            // rather than passed.
            let root = Store.root
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                Store.$rootOverride.withValue(root) {
                    dispatcher.cancel(id: started.id, grace: 0.2)
                }
            }
            let record = dispatcher.wait(id: started.id, timeout: 10)
            #expect(record?.state.isTerminal == true)
        }
    }

    /// A dispatch that cannot start is still a dispatch: the record already exists,
    /// so vanishing silently is the one outcome rule 5 forbids.
    @Test("a supervisor that cannot launch still reaches a terminal event")
    func launchFailureIsTerminal() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-disp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        try Store.$rootOverride.withValue(home) {
            let dispatcher = Dispatcher(executable: URL(fileURLWithPath: "/nonexistent/cowork"))
            #expect(throws: Dispatcher.DispatchError.self) {
                _ = try dispatcher.start(task: "x", backend: "fixture",
                                         workspace: nil, parent: "s_t", root: "s_t")
            }
        }
        #expect(events(home.path).last == "failed",
                "the record was written before the spawn, so it must be resolved after it")
    }
}

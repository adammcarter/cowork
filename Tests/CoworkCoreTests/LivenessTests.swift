import Darwin
import Foundation
import Testing

@testable import CoworkCore

/// Reconciliation depends entirely on this answering correctly. A false "alive"
/// leaves an abandoned dispatch believed to be running forever — a leak nothing
/// will ever report, which is the outcome ADR 003 rule 5 forbids.
@Suite("Owner liveness")
struct LivenessTests {
    @Test("this process is alive by its own identity")
    func selfIsAlive() {
        let me = Liveness.current()
        #expect(me.pid == getpid())
        #expect(me.start > 0, "the kernel must report a start time, or identity is unverifiable")
        #expect(Liveness.isAlive(pid: me.pid, start: me.start))
    }

    @Test("a pid that does not exist is not alive")
    func absentPidIsDead() {
        // pid 0 is the kernel's own; no real dispatch can own it, and asking for
        // its start time must not report a live owner.
        #expect(Liveness.startTime(of: 999_999) == nil)
        #expect(!Liveness.isAlive(pid: 999_999, start: 12345))
    }

    /// The reason identity is (pid, start) rather than a bare pid: pids are
    /// recycled. A live pid with the wrong start time is a *different* process,
    /// and treating it as the owner would strand the dispatch forever.
    @Test("a live pid with a different start time is not the same owner")
    func recycledPidIsNotTheOwner() {
        let me = Liveness.current()
        #expect(Liveness.isAlive(pid: me.pid, start: me.start))
        #expect(!Liveness.isAlive(pid: me.pid, start: me.start - 1),
                "a recycled pid must not masquerade as the original owner")
    }

    @Test("a real child is alive, and dead once reaped")
    func childLifecycle() throws {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = ["/bin/sleep", "30", nil].map { $0.map { strdup($0) } }
        defer { argv.forEach { $0.map { free($0) } } }
        #expect(posix_spawn(&pid, "/bin/sleep", nil, nil, argv, environ) == 0)

        guard let start = Liveness.startTime(of: pid) else {
            Issue.record("a running child must have a start time")
            return
        }
        #expect(Liveness.isAlive(pid: pid, start: start))

        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        #expect(!Liveness.isAlive(pid: pid, start: start),
                "a reaped child must not be reported alive, or its dispatch never reconciles")
    }
}

extension LivenessTests {
    /// A zombie is a process that has exited and is only awaiting reaping. It still
    /// sits in the process table with its original start time, so a naive
    /// (pid, start) match calls it alive — and a dispatch whose supervisor was
    /// killed would then never reconcile, which is the leak rule 5 forbids.
    @Test("a killed-but-unreaped child (a zombie) is not alive")
    func zombieIsNotAlive() throws {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = ["/bin/sleep", "30", nil].map { $0.map { strdup($0) } }
        defer { argv.forEach { $0.map { free($0) } } }
        #expect(posix_spawn(&pid, "/bin/sleep", nil, nil, argv, environ) == 0)
        guard let start = Liveness.startTime(of: pid) else {
            Issue.record("a running child must have a start time"); return
        }

        kill(pid, SIGKILL)
        usleep(300_000)          // dead, but deliberately NOT reaped yet

        #expect(!Liveness.isAlive(pid: pid, start: start),
                "a zombie cannot run code, so it cannot be an owner")

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        #expect(!Liveness.isAlive(pid: pid, start: start))
    }
}

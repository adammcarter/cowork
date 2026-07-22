import Darwin
import Foundation
import Testing

@testable import CoworkCore

/// ADR 003 rules 1-4. These tests use `/bin/sh` as a stand-in worker so they pin
/// the *mechanism* — death pipe, process group, grace period — rather than any
/// backend's behaviour.
@Suite("Supervisor mechanics")
struct SupervisorTests {
    /// Spawn a process holding the death pipe on fd 3, exactly as a supervisor
    /// does: it blocks reading fd 3 and exits the moment that read returns EOF.
    private func spawnPipeWatcher(marker: URL) throws -> Supervisor.Launch {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let readEnd = fds[0], writeEnd = fds[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, readEnd, Supervisor.deathPipeFD)
        posix_spawn_file_actions_addclose(&actions, writeEnd)
        if readEnd != Supervisor.deathPipeFD {
            posix_spawn_file_actions_addclose(&actions, readEnd)
        }
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attrs, 0)

        // `read` on fd 3 blocks until every write end closes; then it records that
        // it noticed and exits. A worker child is spawned too, to prove the group
        // dies as a unit.
        let script = "sleep 300 & head -c 1 <&3 >/dev/null; echo died > \(marker.path)"
        let argv: [UnsafeMutablePointer<CChar>?] =
            ["/bin/sh", "-c", script, nil].map { $0.map { strdup($0) } }
        defer { argv.forEach { $0.map { free($0) } } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/sh", &actions, &attrs, argv, environ)
        close(readEnd)
        #expect(rc == 0)
        return Supervisor.Launch(pid: pid, start: Liveness.startTime(of: pid) ?? 0,
                                 deathPipeWriteEnd: writeEnd)
    }

    private func temporaryMarker() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-sup-\(UUID().uuidString)")
    }

    /// The mechanism the whole no-orphans rule rests on: the orchestrator does not
    /// have to *do* anything. Its descriptors closing is the signal.
    @Test("closing the death pipe tells the supervisor its orchestrator is gone")
    func deathPipeSignalsOnClose() throws {
        let marker = temporaryMarker()
        defer { try? FileManager.default.removeItem(at: marker) }
        let launch = try spawnPipeWatcher(marker: marker)
        defer { kill(-launch.pid, SIGKILL) }

        #expect(Liveness.isAlive(pid: launch.pid, start: launch.start))
        #expect(!FileManager.default.fileExists(atPath: marker.path),
                "it must not think the orchestrator is gone while the pipe is open")

        close(launch.deathPipeWriteEnd)   // the orchestrator's descriptors close

        // A generous ceiling on purpose. A working implementation touches the marker
        // in milliseconds, so waiting longer costs nothing when this passes — while
        // a tight bound turns a busy machine into a failure of the containment
        // guarantee, which is the one signal here that must never cry wolf. This
        // test did exactly that once, on a machine loaded by another test run.
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            usleep(20_000)
        }
        #expect(FileManager.default.fileExists(atPath: marker.path),
                "EOF on the death pipe is the orchestrator's death, and must be noticed")
        var status: Int32 = 0
        waitpid(launch.pid, &status, 0)
    }

    @Test("a supervisor gets its own process group, so killing it cannot kill us")
    func ownsItsProcessGroup() throws {
        let marker = temporaryMarker()
        defer { try? FileManager.default.removeItem(at: marker) }
        let launch = try spawnPipeWatcher(marker: marker)
        defer { close(launch.deathPipeWriteEnd); kill(-launch.pid, SIGKILL) }

        #expect(getpgid(launch.pid) == launch.pid,
                "the supervisor must lead its own group")
        #expect(getpgid(launch.pid) != getpgid(getpid()),
                "sharing our group would mean killing a dispatch kills the orchestrator")
    }

    /// Terminating the group must take the worker's children too — that is the
    /// point of the group.
    @Test("terminating a supervisor takes its whole process group")
    func terminateKillsTheGroup() throws {
        let marker = temporaryMarker()
        defer { try? FileManager.default.removeItem(at: marker) }
        let launch = try spawnPipeWatcher(marker: marker)
        defer { close(launch.deathPipeWriteEnd) }

        let group = getpgid(launch.pid)
        usleep(300_000)                       // let `sleep 300` start
        var members = 0
        for pid in try livePids() where getpgid(pid) == group { members += 1 }
        #expect(members >= 2, "expected the supervisor and its worker child")

        #expect(Supervisor.terminate(pid: launch.pid, start: launch.start, grace: 2))
        usleep(300_000)

        var survivors = 0
        for pid in try livePids() where getpgid(pid) == group && kill(pid, 0) == 0 { survivors += 1 }
        #expect(survivors == 0, "a terminated dispatch must leave nothing running")
        var status: Int32 = 0
        waitpid(launch.pid, &status, WNOHANG)
    }

    @Test("terminating an already-dead supervisor is not an error")
    func terminateIsIdempotent() throws {
        let marker = temporaryMarker()
        defer { try? FileManager.default.removeItem(at: marker) }
        let launch = try spawnPipeWatcher(marker: marker)
        close(launch.deathPipeWriteEnd)
        kill(-launch.pid, SIGKILL)
        var status: Int32 = 0
        waitpid(launch.pid, &status, 0)

        #expect(Supervisor.terminate(pid: launch.pid, start: launch.start, grace: 1),
                "reconciliation calls this on dispatches that may already be gone")
    }

    private func livePids() throws -> [pid_t] {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(count))).filter { $0 > 0 }
    }
}

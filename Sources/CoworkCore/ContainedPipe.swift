import Darwin
import Foundation

/// A spawned child process with line-oriented stdio and ADR-003 containment.
///
/// Owns process-group spawn, CPU rlimit inheritance, fd hygiene, poll-then-read
/// line reads with a hard deadline, zombie-aware liveness, and reap-then-kill
/// close. Protocol sessions (stream-json, JSON-RPC) layer on top; they do not
/// reimplement containment.
public final class ContainedPipe: @unchecked Sendable {
    private let pid: pid_t
    private let stdin: FileHandle
    private let stdout: FileHandle
    private var pending = Data()
    private var exited = false

    /// Whether the child is still running. A zombie is reaped and reported dead —
    /// `kill(pid, 0)` alone would still call it alive.
    public var isAlive: Bool {
        if exited { return false }
        // waitpid, not `kill(pid, 0)`. An exited child stays a zombie until it is
        // reaped, and a zombie still owns its pid — so `kill(pid, 0)` answers
        // "alive" about a process that has already died. A dispatch parked on a
        // dead worker would then wait out its entire idle timeout before admitting
        // the turn it is waiting for can never be taken. Reaping here is also what
        // stops those zombies accumulating.
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { exited = true; return false }
        return kill(pid, 0) == 0
    }

    /// - Parameter workingDirectory: When set, the *child* chdirs here at spawn
    ///   via `posix_spawn_file_actions_addchdir_np`. The parent process is never
    ///   chdir'd — cowork is multi-dispatch and a parent chdir would corrupt every
    ///   other in-flight worker. `nil` inherits cowork's cwd (unconfined / no grant).
    public init(executable: URL, arguments: [String], environment: [String: String],
                workingDirectory: String? = nil,
                cpuSecondsLimit: rlim_t = 900) throws {
        let inPipe = Pipe(), outPipe = Pipe()

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe.fileHandleForReading.fileDescriptor, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, outPipe.fileHandleForWriting.fileDescriptor, 2)
        // posix_spawn hands the child every descriptor. Without these closes the
        // child holds a copy of its own stdin's WRITE end, so stdin never reaches
        // EOF and the worker waits forever for input that cannot arrive. This bug
        // has already been paid for once.
        for fd in [inPipe.fileHandleForReading.fileDescriptor,
                   inPipe.fileHandleForWriting.fileDescriptor,
                   outPipe.fileHandleForReading.fileDescriptor,
                   outPipe.fileHandleForWriting.fileDescriptor] where fd > 2 {
            posix_spawn_file_actions_addclose(&actions, fd)
        }
        // Root the child at the dispatch workspace when granted. Fail loudly if
        // the chdir action cannot be recorded — never spawn in the wrong directory
        // and hope a protocol-level cwd flag papered over it.
        if let workingDirectory {
            let chdirRC = workingDirectory.withCString { path in
                posix_spawn_file_actions_addchdir_np(&actions, path)
            }
            guard chdirRC == 0 else { throw Error.spawnFailed(chdirRC) }
        }

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))   // ADR 003 rule 3
        posix_spawnattr_setpgroup(&attrs, 0)

        var previous = rlimit()
        getrlimit(RLIMIT_CPU, &previous)
        var limit = rlimit(rlim_cur: cpuSecondsLimit, rlim_max: cpuSecondsLimit)
        setrlimit(RLIMIT_CPU, &limit)                                    // ADR 003 rule 7
        defer { setrlimit(RLIMIT_CPU, &previous) }

        let argv: [UnsafeMutablePointer<CChar>?] =
            ([executable.path] + arguments + [String?.none]).map { $0.map { strdup($0) } ?? nil }
        let envp: [UnsafeMutablePointer<CChar>?] =
            (environment.map { "\($0.key)=\($0.value)" } + [String?.none]).map { $0.map { strdup($0) } ?? nil }
        defer {
            argv.forEach { $0.map { free($0) } }
            envp.forEach { $0.map { free($0) } }
        }

        var spawned: pid_t = 0
        let rc = posix_spawn(&spawned, executable.path, &actions, &attrs, argv, envp)
        guard rc == 0 else { throw Error.spawnFailed(rc) }

        try? outPipe.fileHandleForWriting.close()
        try? inPipe.fileHandleForReading.close()
        self.pid = spawned
        self.stdin = inPipe.fileHandleForWriting
        self.stdout = outPipe.fileHandleForReading
    }

    public enum Error: Swift.Error { case spawnFailed(Int32) }

    /// Write one line. Appends a trailing newline so callers pass payload only.
    public func writeLine(_ data: Data) throws {
        try stdin.write(contentsOf: data + Data("\n".utf8))
    }

    /// Force subsequent `isAlive` / `close` paths to treat the child as gone
    /// (write failure, mid-turn timeout with no further use of the worker).
    public func markExited() {
        exited = true
    }

    /// Close stdin — the child's signal that nothing more is coming — then make
    /// sure it is gone. Containment is not optional just because we asked nicely
    /// (ADR 003 rule 3).
    public func close() {
        try? stdin.close()
        var status: Int32 = 0
        // A worker already reaped — by `isAlive`, or by an earlier close — can
        // never satisfy waitpid again: it returns -1/ECHILD, not the pid. Without
        // this guard the loop below spins its entire ten-second deadline waiting
        // for an answer that already arrived, and every interactive dispatch pays
        // ten seconds to shut down something that is long gone.
        if !exited {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let reaped = waitpid(pid, &status, WNOHANG)
                if reaped == pid || (reaped < 0 && errno == ECHILD) { exited = true; break }
                usleep(100_000)
            }
        }
        kill(-pid, SIGKILL)
        if !exited { waitpid(pid, &status, 0); exited = true }
        try? stdout.close()
    }

    /// Read one line, without waiting for EOF.
    ///
    /// The deadline is enforced *around* the read, not merely before it. Checking
    /// the clock and then calling a blocking read gives you a deadline the read is
    /// free to ignore: a worker that says nothing blocks forever, and the timeout
    /// that was supposed to bound the dispatch never gets consulted again. So the
    /// wait happens in `poll`, which takes a timeout, and `read` is only called
    /// once there is something to read.
    public func readLine(deadline: Date) -> String? {
        while true {
            if let n = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[..<n], as: UTF8.self)
                pending.removeSubrange(...n)
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
                continue
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }

            var poller = pollfd(fd: stdout.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(remaining * 1000, Double(Int32.max))))
            if ready == 0 { return nil }              // deadline reached, worker silent
            if ready < 0 {
                if errno == EINTR { continue }        // a signal is not an answer
                return nil
            }

            // Raw read(2), not FileHandle.read(upToCount:). Foundation's version
            // waits for the *full* count or EOF, so asking for 64K blocks until
            // the worker sends 64K — even with a single line already sitting in
            // the pipe. poll says ready, the read blocks anyway, and the whole
            // dispatch hangs. A stack trace, not a guess: this was the bug.
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = buffer.withUnsafeMutableBytes {
                read(stdout.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard count > 0 else { return nil }        // EOF: the worker is gone
            pending.append(contentsOf: buffer[..<count])
        }
    }
}

import Darwin
import Foundation

/// Spawning someone else's process, contained (ADR 003).
///
/// Every CLI worker, whichever agent it is, gets the same treatment: its own
/// process group so it and its descendants die as a unit, a hard kernel CPU limit
/// it cannot raise, a sanitized allowlist environment, and output drained
/// concurrently so a full pipe buffer cannot deadlock the worker before it exits.
/// The protocol on top (what goes in on stdin, how the output is read) differs per
/// backend; this containment does not, so it lives in one place rather than being
/// re-derived — and re-bugged — per backend.
enum ContainedProcess {
    struct Result {
        let output: Data
        let exitStatus: Int32
        let timedOut: Bool
    }

    /// Run `executable` with `arguments`, optionally writing `stdinData` then
    /// closing stdin. Returns what it printed, how it exited, and whether it had to
    /// be killed for exceeding `timeout`.
    /// - Parameter workingDirectory: When set, the *child* chdirs here at spawn
    ///   via `posix_spawn_file_actions_addchdir_np`. The parent process is never
    ///   chdir'd — cowork is multi-dispatch and a parent chdir would corrupt every
    ///   other in-flight worker. `nil` inherits cowork's cwd (unconfined / no grant).
//: @use-case:containment.workspace_grant_is_worker_cwd
    static func run(executable: URL,
                    arguments: [String],
                    environment: [String],
                    stdinData: Data?,
                    workingDirectory: String? = nil,
                    cpuSecondsLimit: rlim_t,
                    timeout: TimeInterval) -> Result {
        let outPipe = Pipe()
        let inPipe = Pipe()

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, inPipe.fileHandleForReading.fileDescriptor, 0)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe.fileHandleForWriting.fileDescriptor, 2)
        // Descriptor hygiene, and it is not optional. posix_spawn hands the child
        // *every* open descriptor, so without these closes the child inherits a
        // copy of its own stdin's write end — and then stdin never reaches EOF,
        // because the reader is also the writer. The agent waits forever for input
        // that cannot arrive. Each original is closed once its dup2 has been made.
        for fd in [inPipe.fileHandleForReading.fileDescriptor,
                   inPipe.fileHandleForWriting.fileDescriptor,
                   outPipe.fileHandleForReading.fileDescriptor,
                   outPipe.fileHandleForWriting.fileDescriptor] where fd > 2 {
            posix_spawn_file_actions_addclose(&fileActions, fd)
        }

        // The workspace grant is the child's *starting directory* (ADR 003:
        // a cwd grant, not a sandbox). If the chdir action cannot be recorded,
        // fail the spawn — never start the worker in the wrong directory.
        if let workingDirectory {
            let chdirRC = workingDirectory.withCString { path in
                posix_spawn_file_actions_addchdir_np(&fileActions, path)
            }
            guard chdirRC == 0 else {
                return Result(output: Data(), exitStatus: Int32(chdirRC) << 8, timedOut: false)
            }
        }

        // ADR 003 rule 3: the worker owns its process group, so it and its
        // descendants can be killed as a unit without touching the orchestrator.
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attrs, 0)

        // ADR 003 rule 7: the kernel enforces the bound, not cowork. Inherited
        // across fork, exec and setsid, and unraisable — so it holds even for a
        // helper that escapes the process group entirely.
        var previous = rlimit()
        getrlimit(RLIMIT_CPU, &previous)
        var limit = rlimit(rlim_cur: cpuSecondsLimit, rlim_max: cpuSecondsLimit)
        setrlimit(RLIMIT_CPU, &limit)
        defer { setrlimit(RLIMIT_CPU, &previous) }

        let argv: [UnsafeMutablePointer<CChar>?] =
            ([executable.path] + arguments + [String?.none]).map { $0.map { strdup($0) } ?? nil }
        let envp: [UnsafeMutablePointer<CChar>?] =
            (environment + [String?.none]).map { $0.map { strdup($0) } ?? nil }
        defer {
            argv.forEach { $0.map { free($0) } }
            envp.forEach { $0.map { free($0) } }
        }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable.path, &fileActions, &attrs, argv, envp)
        guard spawned == 0 else {
            return Result(output: Data(), exitStatus: Int32(spawned) << 8, timedOut: false)
        }

        try? outPipe.fileHandleForWriting.close()
        try? inPipe.fileHandleForReading.close()

        if let stdinData {
            try? inPipe.fileHandleForWriting.write(contentsOf: stdinData)
        }
        try? inPipe.fileHandleForWriting.close()

        // Drain concurrently (a full pipe buffer would otherwise deadlock the worker
        // before it could exit), reap with a deadline, then kill the group — which
        // is also what closes any helper's inherited copy of the pipe and releases
        // the reader. Reading to EOF alone is a trap: an agent's own helper runs in
        // its own process group AND inherits this pipe, holding the write end open
        // after the agent exits, so EOF never arrives.
        let collected = Collector()
        let reader = Thread {
            while let chunk = try? outPipe.fileHandleForReading.read(upToCount: 65536),
                  !chunk.isEmpty {
                collected.append(chunk)
            }
        }
        reader.start()

        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeout)
        var reaped = false
        while Date() < deadline {
            if waitpid(pid, &status, WNOHANG) == pid { reaped = true; break }
            usleep(100_000)
        }

        kill(-pid, SIGKILL)
        if !reaped { waitpid(pid, &status, 0) }
        try? outPipe.fileHandleForWriting.close()

        let joinDeadline = Date().addingTimeInterval(5)
        while !reader.isFinished && Date() < joinDeadline { usleep(50_000) }

        return Result(output: collected.data, exitStatus: status, timedOut: !reaped)
    }

    /// The exit code from a raw wait status, or -1 if the process was signalled
    /// rather than exiting normally.
    static func exitCode(from status: Int32) -> Int32 {
        (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
    }
}

/// A tiny lock around bytes collected off a worker's pipe by the drain thread.
final class Collector: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}

/// The real process boundary for `CliRunner`: contains the worker via
/// `ContainedProcess`. The runner and its drivers live in the testable core and
/// take this by injection, so the containment is the only thing that must run for
/// real — and it is exercised end to end elsewhere, not re-mocked here.
public struct ContainedProcessSpawner: CliProcessSpawning {
    public init() {}

    public func run(executable: URL, arguments: [String], environment: [String],
                    stdin: Data?, workingDirectory: String?,
                    cpuSecondsLimit: rlim_t, timeout: TimeInterval) -> CliProcessResult {
        let result = ContainedProcess.run(executable: executable, arguments: arguments,
                                          environment: environment, stdinData: stdin,
                                          workingDirectory: workingDirectory,
                                          cpuSecondsLimit: cpuSecondsLimit, timeout: timeout)
        return CliProcessResult(output: result.output, exitStatus: result.exitStatus,
                                timedOut: result.timedOut)
    }
}

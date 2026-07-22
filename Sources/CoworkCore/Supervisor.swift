import Darwin
import Foundation

/// Launching and signalling a dispatch's supervisor (ADR 003 rules 1–4).
///
/// A dispatch is a process, not a function call. The orchestrator writes the
/// record, spawns a supervisor, and returns an id **immediately** — so `dispatch`
/// stops blocking and `status`, `wait`, `send` and `cancel` have something live to
/// talk about.
///
/// The supervisor is this same binary re-executed in a hidden mode. That keeps one
/// artifact to build, sign and ship, and guarantees the supervisor is exactly the
/// version that spawned it.
public enum Supervisor {
    /// The descriptor the death pipe arrives on in the child. 0/1/2 are taken; 3 is
    /// the first free slot and is fixed by convention on both sides.
    public static let deathPipeFD: Int32 = 3

    public struct Launch {
        public let pid: pid_t
        public let start: Int64
        /// Held open by the orchestrator. Closing it — or dying — is what the
        /// supervisor detects.
        public let deathPipeWriteEnd: Int32
    }

    /// Spawn a supervisor for a recorded dispatch.
    ///
    /// The death pipe is the whole no-orphans mechanism (ADR 003 rule 2): the child
    /// inherits the read end, the parent keeps the write end, and if the parent
    /// dies by any means — including `SIGKILL` — the kernel closes its descriptors,
    /// the child reads EOF and terminates. No polling, no cooperation from the
    /// dying process, no detection window.
    public static func launch(executable: URL, dispatchID: String,
                              environment: [String: String] = [:]) throws -> Launch {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw SupervisorError.pipeFailed(errno) }
        let readEnd = fds[0], writeEnd = fds[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // The read end lands on a known descriptor; the write end must NOT reach the
        // child, or the child would hold its own death pipe open and never see EOF.
        posix_spawn_file_actions_adddup2(&actions, readEnd, deathPipeFD)
        posix_spawn_file_actions_addclose(&actions, writeEnd)
        if readEnd != deathPipeFD { posix_spawn_file_actions_addclose(&actions, readEnd) }

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        // Its own process group: killable as a unit, and killing it cannot take the
        // orchestrator with it (ADR 003 rule 3).
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attrs, 0)

//: @use-case:endpoint.credential.env_reference_resolves_from_the_environment#env_reference_resolves_f
        // The environment is an allowlist and stays one: the supervisor inherits
        // nothing it was not handed. `environment` carries what the orchestrator
        // decided this dispatch needs — including the variables a provider's
        // `credential = "env:NAME"` reference names, which the supervisor cannot
        // otherwise resolve, because it is a fresh process with a fresh
        // environment.
        //
        // This is the one boundary a credential may cross, and it is narrow: the
        // supervisor IS cowork, not a worker. A worker's environment is built
        // separately and never receives one (ADR 000). The Keychain is the target
        // that removes even this hop.
        var env = environment
        env["COWORK_SUPERVISE"] = dispatchID
        if let home = ProcessInfo.processInfo.environment["COWORK_HOME"] { env["COWORK_HOME"] = home }
        env["HOME"] = NSHomeDirectory()
        env["PATH"] = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        env["USER"] = NSUserName()
        // Lineage rides the environment, so a worker that dispatches is attributed
        // with no coordination (ADR 001).
        env["COWORK_DISPATCH_ID"] = dispatchID

//: @use-case:end endpoint.credential.env_reference_resolves_from_the_environment#env_reference_resolves_f
        let argv: [UnsafeMutablePointer<CChar>?] =
            [executable.path, "__supervise", nil].map { $0.map { strdup($0) } }
        let envp: [UnsafeMutablePointer<CChar>?] =
            (env.map { "\($0.key)=\($0.value)" } + [nil]).map { $0.map { strdup($0) } }
        defer {
            argv.forEach { $0.map { free($0) } }
            envp.forEach { $0.map { free($0) } }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable.path, &actions, &attrs, argv, envp)
        close(readEnd)                    // the parent has no use for it
        guard rc == 0 else {
            close(writeEnd)
            throw SupervisorError.spawnFailed(rc)
        }
        return Launch(pid: pid, start: Liveness.startTime(of: pid) ?? 0,
                      deathPipeWriteEnd: writeEnd)
    }

    /// Block until the orchestrator's end of the death pipe closes, then return.
    /// Called by the supervisor on a background thread: EOF means the orchestrator
    /// is gone, and under the no-orphans rule this dispatch goes with it.
//: @use-case:containment.no_orphan_survives_orchestrator_sigkill#no_orphan_survives_orche
    public static func waitForOrchestratorDeath(onDeath: @escaping @Sendable () -> Void) {
        let thread = Thread {
            var byte: UInt8 = 0
            // read returns 0 at EOF — every write end closed — and >0 never happens,
            // because nothing is ever written to this pipe. Its only message is
            // silence.
            while read(deathPipeFD, &byte, 1) > 0 { continue }
            onDeath()
        }
        thread.stackSize = 64 * 1024
        thread.start()
    }

    /// Terminate a dispatch's process group: `SIGTERM`, a grace period, then
    /// `SIGKILL` (ADR 003 rule 4). The grace is what lets a worker post its terminal
    /// event and run teardown rather than vanishing.
    @discardableResult
    public static func terminate(pid: pid_t, start: Int64, grace: TimeInterval = 5) -> Bool {
        guard Liveness.isAlive(pid: pid, start: start) else { return true }
        kill(-pid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if !Liveness.isAlive(pid: pid, start: start) { return true }
            usleep(50_000)
        }
        kill(-pid, SIGKILL)
        usleep(200_000)
        return !Liveness.isAlive(pid: pid, start: start)
    }
}

public enum SupervisorError: Error {
    case pipeFailed(Int32)
    case spawnFailed(Int32)
}

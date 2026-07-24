import Darwin
import Foundation

/// What a contained spawn produced: the drained output, the raw wait status, and
/// whether the worker had to be killed for exceeding its deadline. The core
/// analogue of `ContainedProcess.Result`, so `CliRunner` can be driven by a fake
/// in a unit test.
public struct CliProcessResult: Sendable {
    public let output: Data
    public let exitStatus: Int32
    public let timedOut: Bool

    public init(output: Data, exitStatus: Int32, timedOut: Bool) {
        self.output = output
        self.exitStatus = exitStatus
        self.timedOut = timedOut
    }
}

/// The one process boundary a CLI dispatch crosses, injected so the runner unit-
/// tests without spawning. The real implementation contains the worker
/// (`ContainedProcess`); a test substitutes a fake that records and scripts.
public protocol CliProcessSpawning: Sendable {
    func run(executable: URL, arguments: [String], environment: [String],
             stdin: Data?, workingDirectory: String?,
             cpuSecondsLimit: rlim_t, timeout: TimeInterval) -> CliProcessResult
}

/// The generic CLI one-shot runner: it owns the duplicated 80% every dialect shared
/// — the environment allowlist, the contained spawn, and the timeout short-circuit
/// — and defers the two things that actually differ to an `OneShotDriver`: how to
/// invoke, and how to parse.
///
/// One type replaces every per-agent backend. A new agent is a config row, with no
/// new runner, no new driver, and no engine `switch`.
public struct CliRunner: Sendable {
    public let executable: URL
    public let driver: OneShotDriver
    public let spawn: CliProcessSpawning
    public var cpuSecondsLimit: rlim_t
    public var timeout: TimeInterval
    public var resume: String?

    public init(executable: URL, driver: OneShotDriver, spawn: CliProcessSpawning,
                cpuSecondsLimit: rlim_t = 900, timeout: TimeInterval = 300, resume: String? = nil) {
        self.executable = executable
        self.driver = driver
        self.spawn = spawn
        self.cpuSecondsLimit = cpuSecondsLimit
        self.timeout = timeout
        self.resume = resume
    }

    public func run(task: String, workspace: Workspace?) -> CliOutcome {
        let invocation = driver.invocation(task: task, workspace: workspace, resume: resume)

//: @use-case:cli.generic.isolation_dir_never_outlives_the_worker#isolation_lifecycle
        // The isolation dir is the runner's to own for exactly this dispatch. `defer`
        // is what makes it leak-proof: it runs on the timeout short-circuit and the
        // normal return alike, so a seed dir that may hold secrets never outlives the
        // worker it was made for.
        let isolation = driver.prepareIsolation()
        defer { isolation?.remove() }
//: @use-case:end cli.generic.isolation_dir_never_outlives_the_worker#isolation_lifecycle

        let environment = ChildEnvironment.allowlist(
            extra: invocation.extraEnvironment + (isolation.map { [$0.environmentEntry] } ?? []))

        let result = spawn.run(executable: executable, arguments: invocation.arguments,
                               environment: environment, stdin: invocation.stdin,
                               workingDirectory: workspace?.root.path,
                               cpuSecondsLimit: cpuSecondsLimit, timeout: timeout)

        if result.timedOut {
            return CliOutcome(state: .timedOut, text: "",
                              diagnostics: [driver.deadlineDiagnostic, "timeout=\(Int(timeout))s"],
                              transcript: String(decoding: result.output, as: UTF8.self).prefix(2000).description)
        }
        return driver.parse(output: result.output, exitStatus: result.exitStatus)
    }

}

/// The environment every cowork-spawned worker gets, one-shot or live session.
///
/// A sanitized environment is an allowlist, not a denylist (ADR 003): the child
/// inherits nothing it was not explicitly given. Each entry is here because the
/// agent provably needs it — USER is what lets an agent reach its Keychain
/// credentials, without which it reports "Not logged in". Lineage (ADR 001) is
/// derived, not asserted: a worker that itself calls cowork is attributed
/// automatically because it inherits these, which is why the two spawn paths must
/// share this one definition rather than each keep its own idea of "the basics".
/// An `extra` entry overrides an allowlist entry by key, which is how an agent gets
/// its bin dir at the head of PATH.
public enum ChildEnvironment {
    /// `KEY=VALUE` form, for the posix_spawn envp of a one-shot.
    public static func allowlist(extra: [String]) -> [String] {
        var environment = [
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME=\(NSHomeDirectory())",
            "USER=\(NSUserName())",
            "LANG=en_US.UTF-8",
        ]
        if let id = ProcessInfo.processInfo.environment["COWORK_DISPATCH_ID"] {
            environment.append("COWORK_DISPATCH_ID=\(id)")
        }
        if let root = ProcessInfo.processInfo.environment["COWORK_ROOT"] {
            environment.append("COWORK_ROOT=\(root)")
        }
        for entry in extra {
            let key = entry.split(separator: "=", maxSplits: 1).first.map(String.init) ?? entry
            if let index = environment.firstIndex(where: { $0.hasPrefix("\(key)=") }) {
                environment[index] = entry
            } else {
                environment.append(entry)
            }
        }
        return environment
    }

    /// Keyed form, for the session spawn's dictionary-shaped API. Same content.
    public static func dictionary(extra: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for entry in allowlist(extra: extra) {
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            out[String(parts[0])] = String(parts[1])
        }
        return out
    }
}

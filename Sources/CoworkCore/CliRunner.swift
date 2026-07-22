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
             stdin: Data?, cpuSecondsLimit: rlim_t, timeout: TimeInterval) -> CliProcessResult
}

/// The generic CLI one-shot runner: it owns the duplicated 80% every dialect shared
/// — the environment allowlist, the contained spawn, and the timeout short-circuit
/// — and defers the two things that actually differ to an `OneShotDriver`: how to
/// invoke, and how to parse.
///
/// One type replaces `CliBackend` and `GrokBackend`. A new agent is a driver plus a
/// registry line, with no new runner and no engine `switch`.
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
        let environment = Self.environment(extra: invocation.extraEnvironment)

        let result = spawn.run(executable: executable, arguments: invocation.arguments,
                               environment: environment, stdin: invocation.stdin,
                               cpuSecondsLimit: cpuSecondsLimit, timeout: timeout)

        if result.timedOut {
            return CliOutcome(state: .timedOut, text: "",
                              diagnostics: [driver.deadlineDiagnostic, "timeout=\(Int(timeout))s"],
                              transcript: String(decoding: result.output, as: UTF8.self).prefix(2000).description)
        }
        return driver.parse(output: result.output, exitStatus: result.exitStatus)
    }

    /// A sanitized environment is an allowlist, not a denylist (ADR 003): the child
    /// inherits nothing it was not explicitly given. Each entry is here because the
    /// agent provably needs it — USER lets Claude Code reach its Keychain
    /// credentials, without which it reports "Not logged in". Lineage (ADR 001) is
    /// derived, not asserted: a worker that itself calls cowork is attributed
    /// automatically because it inherits these. A dialect's `extraEnvironment`
    /// overrides an entry by key (grok prepends its bin dir to PATH).
    static func environment(extra: [String]) -> [String] {
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
}

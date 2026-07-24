import Foundation

/// How to launch a CLI agent for one dispatch: the arguments, whatever is written
/// to stdin (a JSON envelope, nothing at all, or the raw task), and any environment
/// the row adds on top of the shared allowlist.
///
/// This is the true per-agent invocation surface. Everything around it — the base
/// environment allowlist, the containment, the timeout — is shared in `CliRunner`.
public struct Invocation: Sendable, Equatable {
    public let arguments: [String]
    /// Written to the worker's stdin, then stdin is closed. Nil means nothing is
    /// written, which is the case for an agent taking its task as an argument.
    public let stdin: Data?
    /// Environment entries the row adds or overrides on top of the shared allowlist,
    /// as `KEY=VALUE` strings. An entry whose key already exists in the base overrides
    /// it — that is how an agent gets its own bin dir at the head of PATH.
    public let extraEnvironment: [String]

    public init(arguments: [String], stdin: Data? = nil, extraEnvironment: [String] = []) {
        self.arguments = arguments
        self.stdin = stdin
        self.extraEnvironment = extraEnvironment
    }
}

/// One agent's one-shot protocol: how to invoke it and how to read what it said.
///
/// The verdict rule stays a free function in `Verdict` (it carries the tested
/// product decision and its `@use-case` annotations); `parse` calls it. A driver
/// owns only the wire — argv/stdin out, bytes in — not the judgement.
public protocol OneShotDriver: Sendable {
    /// The invocation for this task. `resume` continues a prior dispatch's context
    /// when the row wires it; `workspace` is the directory the worker may work in —
    /// a row with no workspace argument simply ignores it and runs in process cwd.
    func invocation(task: String, workspace: Workspace?, resume: String?) -> Invocation

    /// Turn what the agent printed, and how it exited, into an outcome — deferring
    /// the verdict itself to the core's `Verdict.*` rule.
    func parse(output: Data, exitStatus: Int32) -> CliOutcome

    /// The leading diagnostic when the dispatch is killed for exceeding its
    /// deadline. `CliRunner` adds `timeout=Ns` beside it. Fixed, never per-agent:
    /// which CLI ran out of time already lives in the dispatch record's backend id,
    /// and two agents that hit the same wall must be comparable.
    var deadlineDiagnostic: String { get }

    /// A per-dispatch isolation directory this driver wants, if any. `CliRunner` owns
    /// the lifecycle: it adds the handle's environment entry to the invocation and
    /// removes the directory on EVERY exit path, so a seed dir that may hold secrets
    /// never survives a completed, timed-out or failed dispatch.
    func prepareIsolation() -> IsolationHandle?
}

public extension OneShotDriver {
    func prepareIsolation() -> IsolationHandle? { nil }
    var deadlineDiagnostic: String { "cli.deadline" }
}

/// A fresh 0700 directory pointed at by one environment variable, owned by the
/// runner for exactly one dispatch. The declarative form of a throwaway agent home:
/// the user names the variable and, optionally, what to seed it with.
public struct IsolationHandle: Sendable {
    public let directory: URL
    public let environmentEntry: String

    public init(directory: URL, environmentEntry: String) {
        self.directory = directory
        self.environmentEntry = environmentEntry
    }

    /// Create the directory (0700), optionally seeding it by copying `seed` in.
    /// Returns nil when the directory cannot be created — the dispatch then runs
    /// unisolated rather than failing, and that is visible because the variable is
    /// simply absent.
    public static func make(variable: String, seed: URL?) -> IsolationHandle? {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-cli-isolate-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        var isDirectory: ObjCBool = false
        if let seed, fm.fileExists(atPath: seed.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                // Copy the seed's CONTENTS so the variable points at a directory shaped
                // like the original, not at a directory containing it.
                for entry in (try? fm.contentsOfDirectory(atPath: seed.path)) ?? [] {
                    try? fm.copyItem(at: seed.appendingPathComponent(entry),
                                     to: dir.appendingPathComponent(entry))
                }
            } else {
                // A single file seed is how a user hands a worker exactly one credential
                // and nothing else — the declarative replacement for cowork copying an
                // agent's auth on its own initiative because it recognised its name.
                // 0600 because that is what it is: a secret, in a dir the runner deletes.
                let destination = dir.appendingPathComponent(seed.lastPathComponent)
                try? fm.copyItem(at: seed, to: destination)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
        }
        return IsolationHandle(directory: dir, environmentEntry: "\(variable)=\(dir.path)")
    }

    public func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

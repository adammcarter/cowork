import Foundation

/// How to launch a CLI agent for one dispatch: the arguments, whatever is written
/// to stdin (a JSON envelope for claude, nothing for grok, the raw task for codex),
/// and any environment the dialect adds on top of the shared allowlist.
///
/// This is the true per-dialect invocation surface. Everything around it — the base
/// environment allowlist, the containment, the timeout — is shared in `CliRunner`.
public struct Invocation: Sendable, Equatable {
    public let arguments: [String]
    /// Written to the worker's stdin, then stdin is closed. Nil means nothing is
    /// written (grok takes its task as an argument).
    public let stdin: Data?
    /// Environment entries the dialect adds or overrides on top of the shared
    /// allowlist, as `KEY=VALUE` strings. An entry whose key already exists in the
    /// base overrides it (grok prepends its bin dir to PATH this way).
    public let extraEnvironment: [String]

    public init(arguments: [String], stdin: Data? = nil, extraEnvironment: [String] = []) {
        self.arguments = arguments
        self.stdin = stdin
        self.extraEnvironment = extraEnvironment
    }
}

/// One dialect's one-shot protocol: how to invoke it and how to read what it said.
///
/// The verdict rule stays a free function in `Verdict` (it carries the tested
/// product decision and its `@use-case` annotations); `parse` calls it. A driver
/// owns only the wire — argv/stdin out, bytes in — not the judgement.
public protocol OneShotDriver: Sendable {
    /// The invocation for this task. `resume` continues a prior dispatch's context
    /// when the dialect supports it; `workspace` is the directory the worker may
    /// work in (claude ignores it, grok passes `--cwd`).
    func invocation(task: String, workspace: Workspace?, resume: String?) -> Invocation

    /// Turn what the agent printed, and how it exited, into an outcome — deferring
    /// the verdict itself to the core's `Verdict.*` rule.
    func parse(output: Data, exitStatus: Int32) -> CliOutcome

    /// The leading diagnostic when the dispatch is killed for exceeding its
    /// deadline. `CliRunner` adds `timeout=Ns` beside it.
    var deadlineDiagnostic: String { get }
}

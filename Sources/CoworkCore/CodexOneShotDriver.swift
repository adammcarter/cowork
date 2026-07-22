import Foundation

/// Codex's one-shot wire: `codex exec`, with the raw task written to stdin.
///
/// The third stdin shape along an axis `ContainedProcess` already supports — claude
/// puts a JSON envelope on stdin, grok puts nothing (task in argv), codex puts the
/// raw task — so a new dialect is a new driver, not new machinery. Codex exec is
/// one-shot (stdin *is* the prompt), so its agent is not `SessionCapable`.
public struct CodexOneShotDriver: OneShotDriver {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    public var deadlineDiagnostic: String { "cli.codex.deadline" }

    public func invocation(task: String, workspace: Workspace?, resume: String?) -> Invocation {
        // `codex exec` reads the prompt from stdin; the raw task is that prompt.
        //
        // Codex refuses to run outside a directory it has been told to trust ("Not
        // inside a trusted directory") and sandboxes model-run commands itself. But
        // cowork already contains this worker (ADR 003: its own process group, a hard
        // CPU limit, an allowlist environment), so codex's trust prompt and sandbox
        // are redundant — and the bypass flag is documented as being *for* an
        // externally-sandboxed environment, which this is. It is the codex analogue
        // of claude's `--permission-mode dontAsk` and grok's `--always-approve`.
        var arguments = ["exec", "--ignore-user-config",
                         "--dangerously-bypass-approvals-and-sandbox",
                         "--skip-git-repo-check"]
        if let workspace { arguments += ["-C", workspace.root.path] }
        return Invocation(arguments: arguments, stdin: Data(task.utf8))
    }

//: @use-case:cli.codex.dispatch_is_contained_and_collected#dispatch_is_contained_an
    public func parse(output: Data, exitStatus: Int32) -> CliOutcome {
        let exitCode = (exitStatus & 0x7f) == 0 ? (exitStatus >> 8) & 0xff : -1
        let verdict = Verdict.codex(exitCode: exitCode)
        let text = String(decoding: output, as: UTF8.self)
        return CliOutcome(state: verdict.state, text: text, diagnostics: verdict.diagnostics,
                          transcript: text.prefix(2000).description)
    }
}

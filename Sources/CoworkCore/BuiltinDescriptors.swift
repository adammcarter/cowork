import Foundation

/// The three sealed built-in dialects as literal `CliDescriptor` constants, encoding
/// today's exact one-shot wire. These ARE the regression anchors: `ConfiguredDriver`
/// interpreting one of these must be byte-identical to the hand-written oracle driver
/// it replaces (pinned by the golden equivalence tests). A built-in is never authored
/// from config — it resolves to the constant here.
public enum BuiltinDescriptors {
    /// Claude: stream-json envelope on stdin, declaration read from the `result`
    /// object, `--resume` follow-up. Deadline diagnostic is the asymmetric `cli.deadline`.
    public static let claude = CliDescriptor(
        taskDelivery: .stdinJSONStreamUser,
        baseArguments: ["-p", "--input-format", "stream-json",
                        "--output-format", "stream-json", "--verbose",
                        "--permission-mode", "dontAsk",
                        "--allowed-tools", "Read", "Write", "--strict-mcp-config"],
        workspaceArguments: [],
        resumeArguments: ["--resume", "{resume}"],
        output: .streamJSONResult,
        continuationField: "session_id",
        verdict: .claudeDeclared,
        deadlineDiagnostic: "cli.deadline")

    /// Grok: task in argv, single JSON object read by `text`/`stopReason`/`sessionId`,
    /// `--cwd`/`-r`, and its bin dir prepended to PATH.
    public static let grok = CliDescriptor(
        taskDelivery: .argv,
        baseArguments: ["-p", "{task}", "--output-format", "json",
                        "--no-auto-update", "--always-approve"],
        workspaceArguments: ["--cwd", "{workspace}"],
        resumeArguments: ["-r", "{resume}"],
        prependExeDirToPath: true,
        output: .jsonField("text"),
        continuationField: "sessionId",
        verdict: .grokStopReason,
        deadlineDiagnostic: "cli.grok.deadline")

    /// Codex: `codex exec`, raw task on stdin, raw stdout answer, verdict by exit code,
    /// `-C` workspace, no follow-up handle.
    public static let codex = CliDescriptor(
        taskDelivery: .stdinRaw,
        baseArguments: ["exec", "--ignore-user-config",
                        "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check"],
        workspaceArguments: ["-C", "{workspace}"],
        resumeArguments: [],
        output: .raw,
        continuationField: nil,
        verdict: .exitCodeOnly,
        deadlineDiagnostic: "cli.codex.deadline")

    /// The descriptor for a recognised built-in dialect, or nil for `.unknown`.
    public static func forDialect(_ dialect: CliDialect) -> CliDescriptor? {
        switch dialect {
        case .claude: return claude
        case .grok: return grok
        case .codex: return codex
        case .unknown: return nil
        }
    }
}

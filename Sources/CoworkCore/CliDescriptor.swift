import Foundation

/// The declarative shape of one CLI's one-shot wire, so a CLI is wired from
/// `~/.cowork/config.toml` with no new Swift per CLI (the generalisation of the
/// hand-written `OneShotDriver`s). Every enum below is CLOSED: each case is tested
/// code and an unknown config value is a load error, never a silent fallback that
/// would dispatch one agent as though it spoke another's protocol.
///
/// A descriptor SELECTS behaviour from a tested set; it never AUTHORS it. In
/// particular `verdict` picks one of a fixed set of `Verdict.*` functions (ADR
/// 000): config can choose which truthful rule applies, but cannot write a new
/// success predicate. A genuinely new declaration shape needs a new tested
/// `Verdict.*` function in reviewed Swift, not a config knob.
public struct CliDescriptor: Sendable, Equatable {
    /// Where the prompt is delivered to the process.
    public enum TaskDelivery: Sendable, Equatable {
        case argv                  // {task} substituted into args
        case stdinRaw              // raw task bytes on stdin (codex shape)
        case stdinJSONStreamUser   // claude's exact stream-json user-message envelope

        init?(configValue: String) {
            switch configValue {
            case "argv": self = .argv
            case "stdin_raw": self = .stdinRaw
            case "stdin_json_stream_user": self = .stdinJSONStreamUser
            default: return nil
            }
        }
    }

    /// How the answer is extracted from what the process printed. Each case is a
    /// tested extractor that also owns its transcript/diagnostic shape; config
    /// selects one, it never authors one.
    public enum OutputMode: Sendable, Equatable {
        case raw                    // the whole stdout is the answer
        case jsonField(String)      // last well-formed JSON object; `field` holds the answer
        case streamJSONResult       // claude's stream-json events; the `result` object
    }

    /// A fixed set of tested truthful-outcome rules the descriptor may pick from.
    /// Each maps to an existing `Verdict.*` function VERBATIM (ADR 000).
    public enum VerdictStrategy: String, Sendable, Equatable {
        case exitCodeOnly = "exit_code_only"    // exit 0 ⇒ succeeded; honest only when no declaration is emitted
        case claudeDeclared = "claude_declared" // Verdict.cli(declaredSubtype:isError:exitCode:)
        case grokStopReason = "grok_stop_reason" // Verdict.grok(stopReason:exitCode:)
    }

    /// One environment entry. A value is either a literal (non-secret) or an
    /// `env:NAME` reference resolved from cowork's live environment at dispatch —
    /// a config file holds a pointer, never a secret (ADR 005).
    public struct EnvEntry: Sendable, Equatable {
        public enum Value: Sendable, Equatable {
            case literal(String)
            case reference(String)   // the NAME of a var in cowork's own environment
        }
        public let key: String
        public let value: Value
        public init(key: String, value: Value) { self.key = key; self.value = value }
    }

    /// Per-dispatch filesystem isolation: point `variable` at a fresh 0700 temp dir,
    /// optionally seeded by copying `seed` in. The runtime owns the lifecycle and
    /// removes the dir on every exit path (generalises `CodexAgent.isolatedHome`).
    public struct Isolation: Sendable, Equatable {
        public let variable: String
        public let seed: URL?
        public init(variable: String, seed: URL?) { self.variable = variable; self.seed = seed }
    }

    public let taskDelivery: TaskDelivery
    public let baseArguments: [String]
    public let workspaceArguments: [String]     // appended (with {workspace}) only when a workspace is granted
    public let resumeArguments: [String]         // appended (with {resume}) only when resuming; empty ⇒ no follow-up
    public let env: [EnvEntry]
    public let prependExeDirToPath: Bool         // the only sanctioned way to touch PATH (reproduces grok)
    public let output: OutputMode
    public let continuationField: String?        // JSON key of the resume handle; nil ⇒ no follow-up
    public let verdict: VerdictStrategy
    public let isolate: Isolation?
    public let deadlineDiagnostic: String
    public let timeoutSeconds: Int
    public let cpuSeconds: Int

    public init(taskDelivery: TaskDelivery,
                baseArguments: [String],
                workspaceArguments: [String] = [],
                resumeArguments: [String] = [],
                env: [EnvEntry] = [],
                prependExeDirToPath: Bool = false,
                output: OutputMode,
                continuationField: String? = nil,
                verdict: VerdictStrategy,
                isolate: Isolation? = nil,
                deadlineDiagnostic: String,
                timeoutSeconds: Int = 1800,
                cpuSeconds: Int = 1800) {
        self.taskDelivery = taskDelivery
        self.baseArguments = baseArguments
        self.workspaceArguments = workspaceArguments
        self.resumeArguments = resumeArguments
        self.env = env
        self.prependExeDirToPath = prependExeDirToPath
        self.output = output
        self.continuationField = continuationField
        self.verdict = verdict
        self.isolate = isolate
        self.deadlineDiagnostic = deadlineDiagnostic
        self.timeoutSeconds = timeoutSeconds
        self.cpuSeconds = cpuSeconds
    }
}

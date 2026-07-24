import Foundation

/// One identity type for an installed CLI agent, derived from the executable rather
/// than from the name a user gave it in config — so capabilities and dispatch read
/// the *same* truth, and a mislabeled binary cannot make them disagree.
///
/// `unknown` carries the executable's own name so a diagnostic can report exactly
/// what cowork did not recognise — and it is also the identity a config-wired
/// (`kind = "generic"`) CLI carries, since its binary is by definition not one of
/// the built-ins.
public enum CliDialect: Equatable, Sendable {
    case claude, codex, grok
    case unknown(String)

    public init(executable: URL) {
        switch executable.lastPathComponent.lowercased() {
        case "claude": self = .claude
        case "codex": self = .codex
        case "grok": self = .grok
        case let other: self = .unknown(other)
        }
    }

    /// The dialect's own name, for a config-facing value or a diagnostic. An unknown
    /// dialect reports the executable name cowork did not recognise.
    public var name: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .grok: return "grok"
        case let .unknown(other): return other
        }
    }

    /// The code-backed live-session transport for this dialect, if it has one. Only a
    /// built-in can: a session speaks a bespoke stateful wire (stream-json, ACP, MCP)
    /// that a descriptor cannot express, and the codex adapter carries a copy of the
    /// user's auth, which must never be handed to an arbitrary binary.
    var sessionAdapter: ConfiguredAgent.SessionAdapter? {
        switch self {
        case .claude: return .claudeStreamJSON
        case .grok: return .grokACP
        case .codex: return .codexMCP
        case .unknown: return nil
        }
    }
}

/// The one place a configured CLI becomes a runnable agent.
///
/// A built-in resolves to its sealed `BuiltinDescriptors` constant plus its
/// code-backed session adapter; a `kind = "generic"` row resolves to the descriptor
/// the user wrote, with no adapter (one-shot only). An unrecognised executable with
/// no descriptor and no `kind` to fall back on has no agent (registry-nil), which is
/// how `capabilities` reports `cli.driver-unknown`.
public enum CliRegistry {
    /// The dialect cowork will actually speak to this configured binary.
    ///
    /// The executable's own name wins **when it is recognised** — so a canonically
    /// named binary can never be run as something it is not, however it is labelled.
    /// When the name is *not* self-identifying — a wrapper, a shim, a version-suffixed
    /// binary like `claude-3.5` — the config's explicit `kind` is the fallback, so a
    /// working binary is not refused over a name cowork's heuristic did not recognise.
    /// Both capabilities and dispatch resolve through here, so they cannot disagree.
    public static func dialect(for cli: CliConfig) -> CliDialect {
        let fromExecutable = CliDialect(executable: cli.executable)
        if case .unknown = fromExecutable { return cli.kind }   // kind may itself be .unknown → still nil below
        return fromExecutable
    }

    public static func agent(for cli: CliConfig) -> ConfiguredAgent? {
        // A config-wired descriptor is one-shot only: no session adapter exists for it,
        // so `supports_message` cannot be forged (ADR 006 — refused, never silently
        // degraded to a one-shot).
        if let descriptor = cli.descriptor {
            return ConfiguredAgent(name: cli.name, executable: cli.executable,
                                   descriptor: descriptor, sessionAdapter: nil,
                                   isConfigured: true)
        }
        let dialect = dialect(for: cli)
        guard let descriptor = BuiltinDescriptors.forDialect(dialect) else { return nil }
        return ConfiguredAgent(name: dialect.name, executable: cli.executable,
                               descriptor: descriptor, sessionAdapter: dialect.sessionAdapter,
                               isConfigured: false)
    }
}

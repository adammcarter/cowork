import Foundation

/// One identity type for an installed CLI agent, derived from the executable rather
/// than from the name a user gave it in config — so capabilities and dispatch read
/// the *same* truth, and a mislabeled binary cannot make them disagree.
///
/// This is the single identity the design collapses `CliConfig.Kind` and the old
/// private `Capabilities.CliDriver` into. `unknown` carries the executable's own
/// name so a diagnostic can report exactly what cowork did not recognise.
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
}

/// One installed agent: which dialect it is, how to invoke it one-shot, and — if it
/// cannot be messaged or followed up — why not. Interactive capability is expressed
/// by *also* conforming `SessionCapable`, never by a Bool; follow-up capability is
/// expressed by conforming `FollowUpCapable` the same way. Either capability cannot
/// drift from the code that actually performs it.
public protocol CliAgent {
    static var dialect: CliDialect { get }
    init(executable: URL)
    func oneShot() -> OneShotDriver
    /// The diagnostics explaining why this agent cannot be messaged. Empty for a
    /// `SessionCapable` agent (there is nothing to explain).
    var messageBlocker: [String] { get }
    /// The diagnostics explaining why this agent cannot carry a finished dispatch's
    /// context into a new one. Empty for a `FollowUpCapable` agent.
    var followUpBlocker: [String] { get }
}

/// An agent that can hold a live conversation: it is compiler-forced to vend a
/// session. `capabilities.supports_message` is literally `agent is SessionCapable`
/// (and on a `ResolvedBackend`, the presence of the interactive operation).
public protocol SessionCapable: CliAgent {
    /// Open a live session. `ctx` carries the dispatch workspace (so the session
    /// roots at the granted path) and any resume handle.
    func makeSession(_ ctx: DispatchContext) throws -> SessionTransport
}

/// An agent that can carry a finished dispatch's context into a fresh one-shot:
/// its driver produces a continuation handle and its invocation can resume from
/// that handle. `capabilities.supports_follow_up` is literally
/// `agent is FollowUpCapable`, so the advertised fact cannot drift from the
/// mechanism that performs it.
///
/// Conformance is a claim about the one-shot path (`follow_up` starts a new
/// worker that remembers — not a live `send`). Only agents whose driver both
/// captures a handle and accepts resume may conform.
public protocol FollowUpCapable: CliAgent {}

/// Claude: the one-shot stream-json driver, and a live `CliSession` for interactive
/// dispatch — the only dialect proven to accept a further message mid-session.
/// Follow-up is real: parse captures `session_id`, invocation accepts `--resume`.
public struct ClaudeAgent: SessionCapable, FollowUpCapable {
    public static let dialect: CliDialect = .claude
    public let executable: URL

    public init(executable: URL) { self.executable = executable }

    public func oneShot() -> OneShotDriver { ClaudeOneShotDriver(executable: executable) }

    public var messageBlocker: [String] { [] }
    public var followUpBlocker: [String] { [] }

    public func makeSession(_ ctx: DispatchContext) throws -> SessionTransport {
        // The same flags and allowlist the one-shot path uses, plus the resume
        // handle when continuing a prior context. Claude has no protocol cwd flag;
        // process cwd is the only root — ContainedPipe chdirs the child when a
        // workspace was granted. Without that, relative paths land in cowork's cwd.
        try CliSession(
            executable: executable,
            arguments: ClaudeOneShotDriver.baseArguments
                + (ctx.resume.map { ["--resume", $0] } ?? []),
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                          "HOME": NSHomeDirectory(),
                          "USER": NSUserName(),
                          "LANG": "en_US.UTF-8"],
            workingDirectory: ctx.workspace)
    }
}

/// Grok: the one-shot print driver, and a live `GrokAcpSession` for interactive
/// dispatch — its interactive mode is ACP JSON-RPC over `grok agent stdio`, now
/// built, so it is `SessionCapable` on the same conformance capabilities reads.
/// Follow-up is real on the one-shot path: parse captures `sessionId`, invocation
/// accepts `-r` — so it is `FollowUpCapable` on the same pattern.
public struct GrokAgent: SessionCapable, FollowUpCapable {
    public static let dialect: CliDialect = .grok
    public let executable: URL

    public init(executable: URL) { self.executable = executable }

    public func oneShot() -> OneShotDriver { GrokOneShotDriver(executable: executable) }

    public var messageBlocker: [String] { [] }
    public var followUpBlocker: [String] { [] }

    public func makeSession(_ ctx: DispatchContext) throws -> SessionTransport {
        // A fresh `grok agent stdio` process cannot rejoin a prior ACP session — the
        // worker that held it is gone — so `resume` is not an ACP re-attach handle
        // here; interactive send keeps one long-lived process instead (ADR 001).
        //
        // GROK_CLAUDE_MCPS_ENABLED=false isolates the worker: grok otherwise imports
        // the host's MCP servers (cowork among them) from ~/.claude.json as a compat
        // feature. This is grok's equivalent of claude's --strict-mcp-config and
        // codex's --ignore-user-config — a per-process env, so the user's global
        // ~/.grok config and auth (in ~/.grok, via HOME) are untouched. Belt and
        // suspenders with the ACP session/new `mcpServers: []`.
        //
        // PROCESS cwd is the dispatch workspace when granted (ContainedPipe
        // chdir); protocol session/new also carries cwd — belt and braces.
        let pipe = try ContainedPipe(
            executable: executable,
            arguments: ["agent", "--always-approve", "stdio"],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                          "HOME": NSHomeDirectory(),
                          "USER": NSUserName(),
                          "LANG": "en_US.UTF-8",
                          "GROK_CLAUDE_MCPS_ENABLED": "false"],
            workingDirectory: ctx.workspace)
        return try GrokAcpSession(pipe: pipe, cwd: ctx.sessionCwd)
    }
}

/// Codex: the `codex exec` one-shot driver, and a live `CodexMcpSession` for
/// interactive dispatch — its interactive mode is MCP JSON-RPC over `codex
/// mcp-server` (first turn `codex`, later turns `codex-reply`), now built, so it is
/// `SessionCapable` on the same conformance capabilities reads.
///
/// Not `FollowUpCapable`: `CodexOneShotDriver.parse` leaves no continuation handle
/// and its invocation ignores `resume`, so a follow-up would start fresh — and
/// claiming otherwise would be a lie.
public struct CodexAgent: SessionCapable {
    public static let dialect: CliDialect = .codex
    public let executable: URL

    public init(executable: URL) { self.executable = executable }

    public func oneShot() -> OneShotDriver { CodexOneShotDriver(executable: executable) }

    public var messageBlocker: [String] { [] }
    public var followUpBlocker: [String] { ["cli.follow-up-unproven"] }

    public func makeSession(_ ctx: DispatchContext) throws -> SessionTransport {
        // Isolate the worker in a pristine CODEX_HOME holding only a copy of the user's
        // auth. `codex mcp-server` otherwise loads the host's MCP servers (cowork among
        // them) and ~/.codex hooks, which derail the turn (a blocking user-prompt hook
        // returns an empty answer). This is codex's equivalent of claude's
        // --strict-mcp-config and grok's GROK_CLAUDE_MCPS_ENABLED. codex needs a real
        // login — an isolated HOME alone gives a 401 — so auth.json is copied in rather
        // than dropped. resume is not a codex re-attach handle across processes; a fresh
        // mcp-server has no prior thread, so interactive send keeps one process (ADR 001).
        //
        // PROCESS cwd is the dispatch workspace when granted; protocol tool args
        // still carry cwd too — belt and braces with ContainedPipe chdir.
        let home = try Self.isolatedHome()
        do {
            let pipe = try ContainedPipe(
                executable: executable,
                arguments: ["mcp-server"],
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                              "HOME": NSHomeDirectory(),
                              "USER": NSUserName(),
                              "LANG": "en_US.UTF-8",
                              "CODEX_HOME": home.path],
                workingDirectory: ctx.workspace)
            let session = try CodexMcpSession(pipe: pipe, cwd: ctx.sessionCwd)
            return IsolatedCodexSession(inner: session, home: home)
        } catch {
            try? FileManager.default.removeItem(at: home)
            throw error
        }
    }

    /// A throwaway CODEX_HOME with only a 0600 copy of the user's auth, in a 0700 dir.
    private static func isolatedHome() throws -> URL {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-codex-home-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let auth = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json")
        if fm.fileExists(atPath: auth.path) {
            let dest = home.appendingPathComponent("auth.json")
            try fm.copyItem(at: auth, to: dest)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        }
        return home
    }
}

/// Wraps a codex session with the isolated CODEX_HOME it runs in, removing that home
/// — which holds a copy of the user's auth — when the session closes. Keeps
/// `CodexMcpSession` pure of the isolation concern (it only speaks the wire), exactly
/// as `GrokAcpSession` stays unaware of `GROK_CLAUDE_MCPS_ENABLED`.
private final class IsolatedCodexSession: SessionTransport, @unchecked Sendable {
    private let inner: CodexMcpSession
    private let home: URL

    init(inner: CodexMcpSession, home: URL) {
        self.inner = inner
        self.home = home
    }

    func turn(_ prompt: String) async -> InteractiveSession.Turn { inner.turn(prompt) }
    var isAlive: Bool { inner.isAlive }
    var continuation: String? { inner.continuation }
    func close() {
        inner.close()
        try? FileManager.default.removeItem(at: home)
    }
}

/// The one place a dialect is mapped to its agent. A new agent is one case here plus
/// its file — no engine `switch dialect` anywhere else. An unrecognised executable
/// with no `kind` to fall back on has no agent (registry-nil), which is how
/// `capabilities` reports `cli.driver-unknown`.
public enum CliRegistry {
    /// The dialect cowork will actually speak to this configured binary.
    ///
    /// The executable's own name wins **when it is recognised** — so a canonically
    /// named binary can never be run as something it is not, however it is labelled
    /// (the mislabel protection `CapabilitiesTests` pins). When the name is *not*
    /// self-identifying — a wrapper, a shim, a version-suffixed binary like
    /// `claude-3.5` — the config's explicit `kind` is the fallback, so a working
    /// binary is not refused over a name cowork's heuristic did not recognise. Both
    /// capabilities and dispatch resolve through here, so they cannot disagree.
    public static func dialect(for cli: CliConfig) -> CliDialect {
        let fromExecutable = CliDialect(executable: cli.executable)
        if case .unknown = fromExecutable { return cli.kind }   // kind may itself be .unknown → still nil below
        return fromExecutable
    }

    public static func agent(for cli: CliConfig) -> CliAgent? {
        switch dialect(for: cli) {
        case .claude: return ClaudeAgent(executable: cli.executable)
        case .grok: return GrokAgent(executable: cli.executable)
        case .codex: return CodexAgent(executable: cli.executable)
        case .unknown: return nil
        }
    }
}

import Foundation

/// One installed agent — built-in or config-wired — as a single value type.
///
/// This replaces the three hand-written `CliAgent` structs and the `SessionCapable`
/// / `FollowUpCapable` marker protocols. Those markers were *static* conformances,
/// so they could only ever describe a dialect known at compile time; a config-wired
/// CLI needs the same facts derived from the descriptor it was actually given.
///
/// Capabilities stay derived from mechanism, never declared:
/// - `isSessionCapable` is the presence of a code-backed session adapter, which only
///   a built-in can have — a generic row cannot select one, so it cannot forge it.
/// - `isFollowUpCapable` is the presence of BOTH halves of the mechanism (a handle to
///   capture and an argument to pass it back), exactly the old protocol's condition.
public struct ConfiguredAgent: Sendable {
    /// The live-session transports, bound to their built-in dialect. A generic
    /// descriptor cannot name one: the field does not exist in config. This closes
    /// both the false-capability hole and the credential-leak hole (the codex adapter
    /// copies the user's auth into the worker's isolated home — it must never be
    /// handed to an arbitrary binary).
    public enum SessionAdapter: Sendable {
        case claudeStreamJSON
        case grokACP
        case codexMCP
    }

    public let name: String
    public let executable: URL
    public let descriptor: CliDescriptor
    public let sessionAdapter: SessionAdapter?
    /// True when this agent's wire came from a config descriptor rather than a sealed
    /// built-in. Drives the provenance diagnostics: a configured capability is
    /// asserted, a built-in's was verified against the real CLI.
    public let isConfigured: Bool

    public init(name: String, executable: URL, descriptor: CliDescriptor,
                sessionAdapter: SessionAdapter?, isConfigured: Bool) {
        self.name = name
        self.executable = executable
        self.descriptor = descriptor
        self.sessionAdapter = sessionAdapter
        self.isConfigured = isConfigured
    }

    public func oneShot() -> OneShotDriver {
        ConfiguredDriver(name: name, executable: executable, descriptor: descriptor)
    }

//: @use-case:cli.generic.live_session_is_refused_never_degraded#session_code_only
    /// Whether a live session can be opened: a code-backed adapter exists.
    public var isSessionCapable: Bool { sessionAdapter != nil }
//: @use-case:end cli.generic.live_session_is_refused_never_degraded#session_code_only

    /// Whether a finished dispatch's context can be carried into a new one: the
    /// mechanism is wired at both ends (capture a handle, pass it back).
    public var isFollowUpCapable: Bool {
        descriptor.continuationField != nil && !descriptor.resumeArguments.isEmpty
    }

    /// Why this agent cannot be messaged. Empty when it can.
    public var messageBlocker: [String] {
        isSessionCapable ? [] : ["cli.session-code-only"]
    }

    /// Why this agent cannot carry context forward. Empty when it can.
    /// Codex's built-in wording is preserved exactly: its one-shot leaves no handle
    /// and its invocation ignores resume, so claiming follow-up would be a lie.
    public var followUpBlocker: [String] {
        if isFollowUpCapable { return [] }
        return isConfigured ? ["cli.\(name).follow-up-not-wired"] : ["cli.follow-up-unproven"]
    }

//: @use-case:cli.generic.capability_is_asserted_not_proven#provenance
    /// Provenance diagnostics: what is *asserted* by config versus *proven* against
    /// the real CLI (ADR 000 — a capability difference is reported, never papered over).
    public var provenanceDiagnostics: [String] {
        guard isConfigured else { return [] }
        var out: [String] = []
        if isFollowUpCapable {
            // The mechanism is wired, so cowork will capture and pass a handle — but
            // nothing has yet proven the worker HONORS it rather than starting fresh.
            out.append("cli.\(name).follow-up-configured-unverified")
        }
        if descriptor.verdict == .exitCode {
            // Honest only if this CLI's failures really do surface as a nonzero exit.
            // Statically unknowable; a performed journey clears it.
            out.append("cli.\(name).verdict-unverified")
        }
        return out
    }

//: @use-case:end cli.generic.capability_is_asserted_not_proven#provenance
    /// Open a live session. Only a built-in adapter can serve one; a configured agent
    /// is refused rather than silently degraded to a one-shot (ADR 006).
    public func makeSession(_ ctx: DispatchContext) throws -> SessionTransport {
        switch sessionAdapter {
        case .claudeStreamJSON:
            return try CliSession(
                executable: executable,
                arguments: BuiltinDescriptors.claude.baseArguments
                    + (ctx.resume.map { ["--resume", $0] } ?? []),
                environment: Self.baseEnvironment,
                workingDirectory: ctx.workspace)
        case .grokACP:
            // GROK_CLAUDE_MCPS_ENABLED=false isolates the worker: grok otherwise imports
            // the host's MCP servers (cowork among them) from ~/.claude.json.
            let pipe = try ContainedPipe(
                executable: executable,
                arguments: ["agent", "--always-approve", "stdio"],
                environment: Self.baseEnvironment.merging(["GROK_CLAUDE_MCPS_ENABLED": "false"]) { _, b in b },
                workingDirectory: ctx.workspace)
            return try GrokAcpSession(pipe: pipe, cwd: ctx.sessionCwd)
        case .codexMCP:
            // A pristine CODEX_HOME holding only a copy of the user's auth: codex
            // otherwise loads the host's MCP servers and hooks, which derail the turn.
            let home = try Self.isolatedCodexHome()
            do {
                let pipe = try ContainedPipe(
                    executable: executable,
                    arguments: ["mcp-server"],
                    environment: Self.baseEnvironment.merging(["CODEX_HOME": home.path]) { _, b in b },
                    workingDirectory: ctx.workspace)
                let session = try CodexMcpSession(pipe: pipe, cwd: ctx.sessionCwd)
                return IsolatedCodexSession(inner: session, home: home)
            } catch {
                try? FileManager.default.removeItem(at: home)
                throw error
            }
        case nil:
            throw CliSession.SessionError.spawnFailed(-1)
        }
    }

    private static var baseEnvironment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
         "HOME": NSHomeDirectory(),
         "USER": NSUserName(),
         "LANG": "en_US.UTF-8"]
    }

    /// A throwaway CODEX_HOME with only a 0600 copy of the user's auth, in a 0700 dir.
    private static func isolatedCodexHome() throws -> URL {
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
/// — which holds a copy of the user's auth — when the session closes.
final class IsolatedCodexSession: SessionTransport, @unchecked Sendable {
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

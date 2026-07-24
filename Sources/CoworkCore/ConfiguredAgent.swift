import Foundation

/// One installed agent as a single value type: a name to dispatch by, an executable,
/// and the descriptor that says everything about how to speak to it.
///
/// There is no longer a second, code-resident kind of agent. That collapse is the
/// point of the generalisation: cowork cannot recognise an agent by name, so it can
/// never mis-recognise one either, and two CLIs wired the same way are the same
/// thing to every part of the system.
///
/// Capabilities stay derived from mechanism, never declared:
/// - `isSessionCapable` is the presence of a session wire to speak.
/// - `isFollowUpCapable` is the presence of BOTH halves of the mechanism (a handle to
///   capture and an argument to pass it back).
public struct ConfiguredAgent: Sendable {
    public let name: String
    public let executable: URL
    public let descriptor: CliDescriptor

    public init(name: String, executable: URL, descriptor: CliDescriptor) {
        self.name = name
        self.executable = executable
        self.descriptor = descriptor
    }

    /// Total: a configured row IS a descriptor, so there is no row that fails to
    /// become an agent. What used to be a probe-time `cli.driver-unknown` is now a
    /// load-time refusal, which is strictly earlier and strictly louder.
    public init(_ cli: CliConfig) {
        self.init(name: cli.name, executable: cli.executable, descriptor: cli.descriptor)
    }

    public func oneShot() -> OneShotDriver {
        ConfiguredDriver(name: name, executable: executable, descriptor: descriptor)
    }

//: @use-case:cli.generic.live_session_is_refused_never_degraded#session_code_only
    /// Whether a live session can be opened: a session wire exists to speak.
    public var isSessionCapable: Bool { descriptor.session != nil }
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
    public var followUpBlocker: [String] {
        isFollowUpCapable ? [] : ["cli.follow-up-not-wired"]
    }

//: @use-case:cli.generic.capability_is_asserted_not_proven#provenance
    /// What is *asserted* by config versus *proven* against the real CLI (ADR 000 — a
    /// capability difference is reported, never papered over).
    ///
    /// Every row is config-authored now, so there is no privileged provenance left to
    /// compare against and these markers are unconditional. That is the honest
    /// reading: each one names a claim cowork made on the user's word and has not yet
    /// watched come true. A performed journey is what clears them.
    public var provenanceDiagnostics: [String] {
        var out: [String] = []
        if isFollowUpCapable {
            // The mechanism is wired, so cowork will capture and pass a handle — but
            // nothing has yet proven the worker HONORS it rather than starting fresh.
            out.append("cli.follow-up-unverified")
        }
        if isSessionCapable {
            // A `[session]` block asserts this binary speaks one of three stateful
            // wires. Cowork can spawn it and try, but nothing has proven it answers.
            out.append("cli.session-unverified")
        }
        if descriptor.verdict == .exitCode {
            // Honest only if this CLI's failures really do surface as a nonzero exit.
            // Statically unknowable; a performed journey clears it.
            out.append("cli.verdict-unverified")
        }
        return out
    }

//: @use-case:end cli.generic.capability_is_asserted_not_proven#provenance
    /// Open a live session on the wire the descriptor selected. A row with no
    /// `[session]` block is refused rather than silently degraded to a one-shot
    /// (ADR 006).
    public func makeSession(_ ctx: DispatchContext) throws -> SessionTransport {
        guard let spec = descriptor.session else { throw CliSessionError.notSessionCapable }

        // The isolation dir may hold a copy of a credential the user pointed at, so it
        // is created before the spawn and removed on EVERY way out of this function —
        // including a handshake that throws, which is the path that leaks it.
        let isolation = descriptor.isolate.flatMap {
            IsolationHandle.make(variable: $0.variable, seed: $0.seed)
        }
        do {
            // The same environment a one-shot of this row would get: the ADR 003
            // allowlist plus derived lineage (ADR 001), then the row's own entries and
            // PATH prepend, then the isolation dir last so it wins its key.
            let environment = ChildEnvironment.dictionary(
                extra: descriptor.environmentEntries(executable: executable)
                    + (isolation.map { [$0.environmentEntry] } ?? []))

            var arguments = spec.arguments
            if let resume = ctx.resume, !spec.resumeArguments.isEmpty {
                // Spliced at spawn, not per turn: a session's continuation is the live
                // process, so resuming is something only the launch can express.
                arguments += spec.resumeArguments.map { $0 == "{resume}" ? resume : $0 }
            }

            let pipe = try ContainedPipe(executable: executable, arguments: arguments,
                                         environment: environment,
                                         workingDirectory: ctx.workspace)
            let inner: SessionTransport
            switch spec.wire {
            case .streamJSON: inner = try StreamJsonSession(pipe: pipe)
            case .acp: inner = try AcpSession(pipe: pipe, cwd: ctx.sessionCwd)
            case .mcp: inner = try McpSession(pipe: pipe, cwd: ctx.sessionCwd, spec: spec)
            }
            guard let isolation else { return inner }
            return IsolatedSession(inner: inner, isolation: isolation)
        } catch {
            isolation?.remove()
            throw error
        }
    }
}

/// Wraps a session with the isolation directory it runs in — which may hold a copy of
/// a credential — and removes that directory when the session closes.
final class IsolatedSession: SessionTransport, @unchecked Sendable {
    private let inner: SessionTransport
    private let isolation: IsolationHandle

    init(inner: SessionTransport, isolation: IsolationHandle) {
        self.inner = inner
        self.isolation = isolation
    }

    func turn(_ prompt: String) async -> InteractiveSession.Turn { await inner.turn(prompt) }
    var isAlive: Bool { inner.isAlive }
    var continuation: String? { inner.continuation }
    func close() {
        inner.close()
        isolation.remove()
    }
}

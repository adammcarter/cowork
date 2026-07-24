import Foundation

/// What execution needs from the dispatch that granted it — carried into every
/// operation so interactive sessions and one-shots see the same grant.
///
/// Only fields needed today: a workspace path (optional = unconfined) and a
/// resume/continuation handle for follow-up. No speculative fields.
public struct DispatchContext: Sendable, Equatable {
    public var workspace: String?
    public var resume: String?

    public init(workspace: String? = nil, resume: String? = nil) {
        self.workspace = workspace
        self.resume = resume
    }

    /// Workspace grant for tools and confinement. `nil` when the dispatch is unconfined.
    public var workspaceGrant: Workspace? {
        guard let workspace else { return nil }
        return Workspace(root: URL(fileURLWithPath: workspace), writable: true)
    }

    /// Directory a live session should root itself at: the granted workspace when
    /// present, otherwise the process working directory (the historical fallback).
    public var sessionCwd: String {
        workspaceGrant?.root.path ?? FileManager.default.currentDirectoryPath
    }
}

/// Type-erased one-shot execution shared by CLI runners and endpoint backends.
public struct ResolvedOneShot: Sendable {
    public typealias Outcome = (state: DispatchRecord.State, text: String, diagnostics: [String],
                                transcript: String, continuation: String?)

    private let _execute: @Sendable (String, Workspace?) async -> Outcome

    public init(execute: @escaping @Sendable (String, Workspace?) async -> Outcome) {
        self._execute = execute
    }

    public func execute(task: String, workspace: Workspace?) async -> Outcome {
        await _execute(task, workspace)
    }
}

/// One backend, fully resolved: what it is, and what it can honestly do.
///
/// Created once from configuration. Dispatch, send, follow-up and capabilities all
/// go through this type so they cannot drift. Capability flags are **derived from
/// the presence of operations** (`interactiveSession` factory non-nil,
/// `followUp` factory non-nil) — never hand-maintained Bools that can disagree
/// with the mechanism.
public struct ResolvedBackend: Sendable {
    public let id: String
    public let kind: Capabilities.BackendFacts.Kind
    public let origin: ProviderConfig.Origin
    /// For a CLI: whether the executable is present on disk. For an endpoint:
    /// resolve-time placeholder (`true`); `capabilities` replaces it with a live probe.
    public let available: Bool
    public let diagnostics: [String]

    private let makeOneShot: (@Sendable (DispatchContext) -> ResolvedOneShot)?
    private let makeInteractive: (@Sendable (DispatchContext) throws -> SessionTransport)?
    private let makeFollowUp: (@Sendable (DispatchContext) -> ResolvedOneShot)?

    public init(id: String,
                kind: Capabilities.BackendFacts.Kind,
                origin: ProviderConfig.Origin,
                available: Bool,
                diagnostics: [String],
                oneShot: (@Sendable (DispatchContext) -> ResolvedOneShot)?,
                interactive: (@Sendable (DispatchContext) throws -> SessionTransport)?,
                followUp: (@Sendable (DispatchContext) -> ResolvedOneShot)?) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.available = available
        self.diagnostics = diagnostics
        self.makeOneShot = oneShot
        self.makeInteractive = interactive
        self.makeFollowUp = followUp
    }

    /// Fire-and-forget execution. `nil` when this backend cannot be dispatched one-shot
    /// (unknown CLI driver).
    public func oneShot(_ ctx: DispatchContext) -> ResolvedOneShot? {
        makeOneShot?(ctx)
    }

    /// Open a live interactive session. `nil` when this backend cannot be messaged
    /// (no interactive operation), or when session construction fails after a throw
    /// is absorbed by the caller. The factory itself being non-nil **is**
    /// `supports_message`.
    public func interactiveSession(_ ctx: DispatchContext) throws -> SessionTransport? {
        guard let makeInteractive else { return nil }
        return try makeInteractive(ctx)
    }

    /// One-shot that resumes a finished dispatch's context. `nil` when this backend
    /// cannot carry context (`supports_follow_up` is then false).
    public func followUp(_ ctx: DispatchContext) -> ResolvedOneShot? {
        makeFollowUp?(ctx)
    }

    /// Whether an interactive session operation exists. Derived, not stored.
    public var supportsMessage: Bool { makeInteractive != nil }

    /// Whether a follow-up operation exists. Derived, not stored.
    public var supportsFollowUp: Bool { makeFollowUp != nil }

    /// Same as `supportsMessage` — named for call sites that mean "can we open one?"
    public var canOpenInteractiveSession: Bool { supportsMessage }

    /// Facts report for `capabilities`. Supports flags always come from operations.
    public func facts(available: Bool? = nil, extraDiagnostics: [String] = []) -> Capabilities.BackendFacts {
        Capabilities.BackendFacts(
            id: id,
            kind: kind,
            origin: origin,
            available: available ?? self.available,
            supportsMessage: supportsMessage,
            supportsFollowUp: supportsFollowUp,
            diagnostics: diagnostics + extraDiagnostics)
    }
}

/// The single resolution entry point: configuration → `ResolvedBackend`.
///
/// Every path that previously resolved backends independently (dispatch, send,
/// interactive session, capabilities, follow-up) goes through here.
public enum BackendResolver {

    /// Resolve one backend id (`cli-name` or `provider/model`).
    ///
    /// Returns a backend even when the CLI driver is unknown (operations all nil)
    /// so capabilities can report it. Dispatch checks `oneShot` / interactive
    /// presence before launching. Returns `nil` only when the id is not a backend
    /// at all (unknown name, masked provider, empty model).
//: @use-case:contract.tools.unknown_backend_is_refused_not_guessed
    public static func resolve(_ id: String, config: Config) -> ResolvedBackend? {
        if let cli = config.cli[id] {
            return resolveCli(cli)
        }
        guard let slash = id.firstIndex(of: "/") else { return nil }
        let providerName = String(id[id.startIndex..<slash])
        let model = String(id[id.index(after: slash)...])
        guard !model.isEmpty, let provider = config.visible[providerName] else { return nil }
        return resolveEndpoint(id: id, provider: provider, model: model)
    }

    /// Every configured CLI, for an all-backends capabilities report.
    public static func resolveAllCli(config: Config) -> [ResolvedBackend] {
        config.cli.values.sorted { $0.name < $1.name }.map(resolveCli)
    }

    // MARK: CLI

    public static func resolveCli(_ cli: CliConfig) -> ResolvedBackend {
        var diagnostics: [String] = []
        let available = FileManager.default.isExecutableFile(atPath: cli.executable.path)
        if !available {
            diagnostics += ["cli.executable-absent", "path=\(cli.executable.path)"]
        }

        let executableDialect = CliDialect(executable: cli.executable)
        if case .unknown = executableDialect {
            // no recognised identity to disagree with — the kind fallback governs
        } else if cli.kind != executableDialect {
            diagnostics += ["cli.kind-mismatch", "configured=\(cli.kind.name)",
                            "executable=\(executableDialect.name)"]
        }

        guard let agent = CliRegistry.agent(for: cli) else {
            diagnostics += ["cli.driver-unknown",
                            "executable=\(cli.executable.lastPathComponent.lowercased())"]
            return ResolvedBackend(
                id: cli.name, kind: .cli, origin: cli.origin,
                available: available, diagnostics: diagnostics,
                oneShot: nil, interactive: nil, followUp: nil)
        }

        // Blockers explain a missing operation; they are not a second capability source.
        if !agent.isSessionCapable { diagnostics += agent.messageBlocker }
        if !agent.isFollowUpCapable { diagnostics += agent.followUpBlocker }
        // Asserted-by-config is reported DISTINCTLY from proven-against-the-CLI, so a
        // configured capability is never presented as a verified one (ADR 000).
        diagnostics += agent.provenanceDiagnostics

        // Re-resolve the agent inside each factory from the Sendable CliConfig so the
        // factories themselves stay @Sendable (the agent existential is not).
        let cliConfig = cli
        let oneShot: @Sendable (DispatchContext) -> ResolvedOneShot = { ctx in
            guard let agent = CliRegistry.agent(for: cliConfig) else {
                return ResolvedOneShot { _, _ in
                    (.failed, "", ["cli.driver-unknown"], "", nil)
                }
            }
            let runner = CliRunner(executable: cliConfig.executable, driver: agent.oneShot(),
                                   spawn: ContainedProcessSpawner(),
                                   cpuSecondsLimit: rlim_t(agent.descriptor.cpuSeconds),
                                   timeout: TimeInterval(agent.descriptor.timeoutSeconds),
                                   resume: ctx.resume)
            return ResolvedOneShot { task, workspace in
                let o = runner.run(task: task, workspace: workspace)
                return (o.state, o.text, o.diagnostics, o.transcript, o.continuation)
            }
        }

        let interactive: (@Sendable (DispatchContext) throws -> SessionTransport)?
        if agent.isSessionCapable {
            interactive = { ctx in
                guard let sessionAgent = CliRegistry.agent(for: cliConfig), sessionAgent.isSessionCapable else {
                    // Registry and the resolve-time check disagreed — refuse rather than crash.
                    throw CliSession.SessionError.spawnFailed(-1)
                }
                return try sessionAgent.makeSession(ctx)
            }
        } else {
            interactive = nil
        }

        let followUp: (@Sendable (DispatchContext) -> ResolvedOneShot)?
        if agent.isFollowUpCapable {
            // Follow-up is one-shot with a resume handle — the same runner path.
            followUp = oneShot
        } else {
            followUp = nil
        }

        return ResolvedBackend(
            id: cli.name, kind: .cli, origin: cli.origin,
            available: available, diagnostics: diagnostics,
            oneShot: oneShot, interactive: interactive, followUp: followUp)
    }

    // MARK: endpoints

    /// An endpoint can be messaged (cowork owns the message list) and cannot be
    /// followed up (no continuation handle). Those facts are the presence or
    /// absence of the operations below — never hand-set Bools.
//: @use-case:endpoint.dialect.unsupported_kind_is_refused_not_defaulted
    public static func resolveEndpoint(id: String, provider: ProviderConfig,
                                       model: String) -> ResolvedBackend {
        guard let dialect = EndpointDialects.resolve(kind: provider.kind) else {
            return ResolvedBackend(
                id: id, kind: .endpoint, origin: provider.origin,
                available: false,
                diagnostics: ["endpoint.dialect-unsupported", "kind=\(provider.kind)"],
                oneShot: nil, interactive: nil, followUp: nil)
        }
        let credentialName: String? = provider.credential.flatMap { ref in
            ref.hasPrefix("env:") ? String(ref.dropFirst(4)) : nil
        }
        let baseURL = provider.baseURL
        let chatPath = provider.chatPath

        let oneShot: @Sendable (DispatchContext) -> ResolvedOneShot = { _ in
            let backend = EndpointBackend(baseURL: baseURL, model: model, dialect: dialect,
                                          credentialName: credentialName, chatPath: chatPath)
            return ResolvedOneShot { task, workspace in
                let o = await backend.run(task: task, workspace: workspace)
                return (o.state, o.text, o.diagnostics, o.transcript, nil)
            }
        }

        let interactive: @Sendable (DispatchContext) throws -> SessionTransport = { ctx in
            let backend = EndpointBackend(baseURL: baseURL, model: model, dialect: dialect,
                                          credentialName: credentialName, chatPath: chatPath)
            return backend.session(workspace: ctx.workspaceGrant)
        }

        return ResolvedBackend(
            id: id, kind: .endpoint, origin: provider.origin,
            available: true,
            // Capability-limit diagnostic: same vocabulary capabilities used to attach.
            diagnostics: ["endpoint.no-continuation"],
            oneShot: oneShot,
            interactive: interactive,
            followUp: nil)
    }
}

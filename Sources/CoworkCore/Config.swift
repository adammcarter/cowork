import Foundation

/// Provider configuration (ADR 005).
///
/// A provider is an endpoint — host, dialect, auth reference. A dispatchable
/// backend id is derived as `provider/model`: models are never declared, because
/// what a host serves changes minute to minute and a config file records intent,
/// never truth. `capabilities` probes for that.
public enum ConfigError: Error, CustomStringConvertible {
    case unreadable(String)
    case malformed(String)
    case projectNamedCredential(provider: String, credential: String)
    case credentialNotAReference(provider: String)
    case unknownProfile(String)
    case projectGenericCli(String)
    case builtinImmutable(cli: String)
    case protectedEnvKey(cli: String, key: String)

    public var description: String {
        switch self {
        case let .unreadable(p): return "config.unreadable: \(p)"
        case let .malformed(m): return "config.malformed: \(m)"
        case let .projectNamedCredential(provider, credential):
            return """
                config.project-credential-refused: project provider '\(provider)' names \
                credential '\(credential)'. A project config may not name a credential at \
                all — a credential is bound to the provider the user declared it for. Add \
                this provider to ~/.cowork/config.toml if you want it to authenticate.
                """
        case let .credentialNotAReference(provider):
            return """
                config.credential-not-a-reference: provider '\(provider)' must use \
                'env:NAME'. A config file holds a pointer, never a secret.
                """
        case let .unknownProfile(name): return "config.unknown-profile: \(name)"
        case let .projectGenericCli(name):
            return """
                config.project-generic-cli-refused: project cli '\(name)' declares a \
                generic descriptor (kind='generic' or a descriptor field). A generic CLI \
                spawns an arbitrary executable with arbitrary argv/env, so a cloned repo \
                may not introduce one — define it in ~/.cowork/config.toml instead. A \
                project cli may only SELECT a built-in (kind='claude'|'grok'|'codex').
                """
        case let .builtinImmutable(cli):
            return """
                config.builtin-immutable: cli '\(cli)' is a built-in (claude/grok/codex) \
                yet carries a generic descriptor field. Built-in dialects are sealed; use \
                kind='generic' with a non-built-in executable to wire a custom CLI.
                """
        case let .protectedEnvKey(cli, key):
            return """
                config.protected-env-key: cli '\(cli)' env may not set '\(key)'. \
                PATH/HOME/USER/LANG/COWORK_*/DYLD_*/LD_* alter execution or leak state; \
                PATH's one legitimate use is prepend_exe_dir_to_path = true.
                """
        }
    }
}

public struct ProviderConfig: Equatable, Sendable {
    public enum Origin: String, Sendable { case global, project }

    public let name: String
    public let kind: String
    public let baseURL: URL
    public let chatPath: String
    public let credential: String?
    public let origin: Origin
}

public struct CliConfig: Equatable, Sendable {
    public let name: String
    public let executable: URL
    /// Which installed agent this is — one identity type, `CliDialect`, shared with
    /// capabilities and dispatch (it replaces the old split-brain `CliConfig.Kind`).
    /// Given explicitly as `kind = "claude" | "grok" | "codex"`, or derived from the
    /// executable when omitted. Cowork dispatches by the *executable's* dialect; a
    /// configured kind that disagrees is reported as a mismatch, not obeyed.
    public let kind: CliDialect
    /// The declarative wire for a `kind = "generic"` row; nil for a built-in, which
    /// resolves to a sealed `BuiltinDescriptors` constant instead.
    public let descriptor: CliDescriptor?
    public let origin: ProviderConfig.Origin

    public init(name: String, executable: URL, kind: CliDialect,
                descriptor: CliDescriptor? = nil, origin: ProviderConfig.Origin) {
        self.name = name
        self.executable = executable
        self.kind = kind
        self.descriptor = descriptor
        self.origin = origin
    }
}

public struct Config: Sendable {
    public let providers: [String: ProviderConfig]
    public let cli: [String: CliConfig]
    /// Providers this project may actually use: the union of its selected
    /// profiles, plus its own providers, which a profile never masks.
    public let visible: [String: ProviderConfig]

//: @use-case:endpoint.provider_is_configuration_not_code#provider_is_configuratio
    public static func load(global: URL, project: URL?) throws -> Config {
        let globalDoc = try Toml.parse(contentsOf: global, required: false)
        let projectDoc = try project.map { try Toml.parse(contentsOf: $0, required: false) } ?? [:]

        var providers: [String: ProviderConfig] = [:]
        var cli: [String: CliConfig] = [:]
//: @use-case:end endpoint.provider_is_configuration_not_code#provider_is_configuratio

        for (name, table) in Toml.subtables(of: globalDoc, prefix: "provider") {
            providers[name] = try provider(name: name, table: table, origin: .global)
        }
        for (name, table) in Toml.subtables(of: globalDoc, prefix: "cli") {
            cli[name] = try cliConfig(name: name, table: table, origin: .global)
        }

        // A credential belongs to the provider the user bound it to — never to a
        // credential *name* (ADR 005).
        //
        // The weaker rule "a project may reuse a credential the user declared
        // globally" is worthless, and testing it against a hostile config proved
        // it: a cloned repo declares its own endpoint, names the key the user
        // already uses for a legitimate provider, and the key leaves on first
        // dispatch. The binding that matters is (credential -> provider), so a
        // project-defined provider may not name a credential at all. If a project
        // genuinely needs an authenticated endpoint, the user adds it globally —
        // which is exactly the decision that should be theirs.
        for (name, table) in Toml.subtables(of: projectDoc, prefix: "provider") {
            let p = try provider(name: name, table: table, origin: .project)
            if let credential = p.credential {
//: @use-case:config.hostile_project_credential_is_refused#hostile_project_credenti
                throw ConfigError.projectNamedCredential(provider: name, credential: credential)
            }
//: @use-case:end config.hostile_project_credential_is_refused#hostile_project_credenti
            providers[name] = p    // a project wins a name collision
        }
        for (name, table) in Toml.subtables(of: projectDoc, prefix: "cli") {
            cli[name] = try cliConfig(name: name, table: table, origin: .project)
        }

        let visible = try mask(providers: providers, globalDoc: globalDoc, projectDoc: projectDoc)
        return Config(providers: providers, cli: cli, visible: visible)
    }

    /// Every environment variable NAME this config references — a provider's
    /// `credential = "env:NAME"` and a CLI descriptor's `env:NAME` value alike.
    ///
    /// The supervisor is a fresh process with an allowlist environment, so a name the
    /// config references is unresolvable there unless it travels with it. Collecting
    /// providers only was a real hole: a `[cli.*.env]` reference resolved to EMPTY in
    /// the worker, so a user who exported their variable exactly as the config said
    /// got a silently unset value — the kind of quiet wrongness ADR 000 exists to
    /// prevent. Names only; the values are read from the live environment by the
    /// caller, and a name that is not set is simply not forwarded.
    public var referencedEnvironmentNames: Set<String> {
        var names = Set<String>()
        for provider in providers.values {
            if let ref = provider.credential, ref.hasPrefix("env:") {
                names.insert(String(ref.dropFirst(4)))
            }
        }
        for entry in cli.values.compactMap(\.descriptor).flatMap(\.env) {
            if case let .reference(name) = entry.value { names.insert(name) }
        }
        return names
    }

    /// Profiles compose by union; an unselected provider is masked. A profile
    /// masks the *user's* providers and never the project's own, which the project
    /// declared deliberately — otherwise the two features fight.
//: @use-case:config.profiles_mask_hosted_providers#profiles_mask_hosted_pro
    private static func mask(providers: [String: ProviderConfig],
                             globalDoc: [String: Any],
                             projectDoc: [String: Any]) throws -> [String: ProviderConfig] {
        guard let selected = projectDoc["profiles"] as? [Any], !selected.isEmpty else {
            return providers      // no profiles selected: nothing is masked
        }
        let names = selected.compactMap { $0 as? String }
        var allowed = Set<String>()
        for name in names {
            guard let table = Toml.subtables(of: globalDoc, prefix: "profile")[name] else {
                // A typo must not silently mask everything into an empty world.
                throw ConfigError.unknownProfile(name)
            }
            for p in (table["providers"] as? [Any])?.compactMap({ $0 as? String }) ?? [] {
                allowed.insert(p)
            }
        }
        return providers.filter { allowed.contains($0.key) || $0.value.origin == .project }
    }
//: @use-case:end config.profiles_mask_hosted_providers#profiles_mask_hosted_pro

//: @use-case:config.credential_reference_must_be_env
    private static func provider(name: String, table: [String: Any],
                                 origin: ProviderConfig.Origin) throws -> ProviderConfig {
        let credential = table["credential"] as? String
        if let credential {
            // A reference, never a literal: the file holds a pointer to a secret.
            guard credential.hasPrefix("env:") else {
                throw ConfigError.credentialNotAReference(provider: name)
            }
        }
        guard let raw = table["base_url"] as? String, let url = URL(string: raw) else {
            throw ConfigError.malformed("provider '\(name)' needs a base_url")
        }
        return ProviderConfig(
            name: name,
            kind: (table["kind"] as? String) ?? "openai_compatible",
            baseURL: url,
            // The URL layout is configuration, not contract: NVIDIA and Ollama serve
            // /v1/chat/completions, z.ai serves /api/coding/paas/v4/chat/completions.
            chatPath: (table["chat_path"] as? String) ?? "v1/chat/completions",
            credential: credential,
            origin: origin)
    }
//: @use-case:end config.credential_reference_must_be_env

    private static func string(_ table: [String: Any], _ key: String, _ owner: String) throws -> String {
        guard let v = table[key] as? String else {
            throw ConfigError.malformed("'\(owner)' needs a \(key)")
        }
        return v
    }

    // The descriptor-only keys. Their presence on a NON-generic (built-in) row is a
    // load error (built-ins are sealed); `kind = "generic"` opts in to them.
    private static let genericFieldKeys = [
        "task_delivery", "args", "workspace_args", "resume_args", "output", "output_field",
        "continuation_field", "verdict", "env", "isolate", "prepend_exe_dir_to_path",
        "deadline_diagnostic", "timeout_seconds", "cpu_seconds",
    ]

    /// One `[cli.*]` table as a `CliConfig` — a sealed built-in, or a `kind='generic'`
    /// descriptor. The generic path carries the security guardrails an arbitrary
    /// executable demands: it is global-origin only (a cloned repo cannot introduce
    /// one), its env may not touch execution-sensitive keys, and its verdict/output
    /// pairing must be coherent so a mismatch cannot degrade to a permanent silent
    /// failure.
    private static func cliConfig(name: String, table: [String: Any],
                                  origin: ProviderConfig.Origin) throws -> CliConfig {
        let executable = expand(try string(table, "executable", name))
        let kindRaw = table["kind"] as? String
        let hasGenericField = genericFieldKeys.contains { table[$0] != nil }

//: @use-case:cli.generic.project_config_may_not_wire_a_generic_cli#origin_gate
        if kindRaw == "generic" {
            // ORIGIN GATE: a generic descriptor authors argv+env for an arbitrary
            // binary — strictly worse than the project-credential attack ADR 005
            // already refuses. A project may only SELECT a built-in.
            guard origin == .global else { throw ConfigError.projectGenericCli(name) }
            // A generic row may not point at a built-in executable name: that would
//: @use-case:end cli.generic.project_config_may_not_wire_a_generic_cli#origin_gate
//: @use-case:cli.generic.builtin_wire_is_sealed_from_config#builtin_sealed
            // let config re-author a sealed dialect's wire.
            guard case .unknown = CliDialect(executable: executable) else {
                throw ConfigError.builtinImmutable(cli: name)
            }
            let descriptor = try parseDescriptor(name: name, table: table, executable: executable)
            return CliConfig(name: name, executable: executable,
                             kind: CliDialect(executable: executable),
                             descriptor: descriptor, origin: origin)
        }

        // Built-in row: sealed. Any descriptor field is a load error.
        guard !hasGenericField else { throw ConfigError.builtinImmutable(cli: name) }
        return CliConfig(name: name, executable: executable,
//: @use-case:end cli.generic.builtin_wire_is_sealed_from_config#builtin_sealed
                         kind: try cliDialect(table, name, executable: executable),
                         descriptor: nil, origin: origin)
    }

    /// A built-in `[cli.*]` table's `kind` as a `CliDialect`. Omitted, it derives from
    /// the executable, so a grok binary is grok without saying so twice. Given, an
    /// unrecognized value is a config error the user can act on, not a silent fallback
    /// that would dispatch one agent as though it spoke another's protocol.
    private static func cliDialect(_ table: [String: Any], _ owner: String,
                                   executable: URL) throws -> CliDialect {
        guard let raw = table["kind"] as? String else { return CliDialect(executable: executable) }
        switch raw {
        case "claude": return .claude
        case "grok": return .grok
        case "codex": return .codex
        default:
            throw ConfigError.malformed(
                "cli '\(owner)' has unknown kind '\(raw)' (use 'claude', 'grok', 'codex' or 'generic')")
        }
    }

    private static let protectedEnvPrefixes = ["COWORK_", "DYLD_", "LD_"]
    private static let protectedEnvExact = ["PATH", "HOME", "USER", "LANG"]

    private static func parseDescriptor(name: String, table: [String: Any],
                                        executable: URL) throws -> CliDescriptor {
        let tdRaw = (table["task_delivery"] as? String) ?? "argv"
        guard let taskDelivery = CliDescriptor.TaskDelivery(configValue: tdRaw) else {
            throw ConfigError.malformed("cli '\(name)' has unknown task_delivery '\(tdRaw)'")
        }
        let args = stringArray(table["args"])
        let workspaceArgs = stringArray(table["workspace_args"])
        let resumeArgs = stringArray(table["resume_args"])

        let outRaw = (table["output"] as? String) ?? "raw"
        let outputField = table["output_field"] as? String
        let output: CliDescriptor.OutputMode
        switch outRaw {
        case "raw": output = .raw
        case "json_field":
            guard let field = outputField else {
                throw ConfigError.malformed("cli '\(name)' output='json_field' needs output_field")
            }
            output = .jsonField(field)
        case "stream_json_result": output = .streamJSONResult
        default: throw ConfigError.malformed("cli '\(name)' has unknown output '\(outRaw)'")
        }

        let verdictRaw = (table["verdict"] as? String) ?? "exit_code_only"
        guard let verdict = CliDescriptor.VerdictStrategy(rawValue: verdictRaw) else {
            throw ConfigError.malformed("cli '\(name)' has unknown verdict '\(verdictRaw)'")
        }

        let env = try parseEnv(name: name, table["env"] as? [String: Any] ?? [:])
        let prependPath = (table["prepend_exe_dir_to_path"] as? Bool) ?? false
        let isolate = try parseIsolate(table["isolate"] as? [String: Any])
        let continuationField = table["continuation_field"] as? String
        let deadlineDiagnostic = (table["deadline_diagnostic"] as? String) ?? "cli.\(name).deadline"
        let timeout = (table["timeout_seconds"] as? Int) ?? 1800
        let cpu = (table["cpu_seconds"] as? Int) ?? 1800

        try validateCoherence(name: name, taskDelivery: taskDelivery, args: args,
                              output: output, verdict: verdict)

        return CliDescriptor(
            taskDelivery: taskDelivery, baseArguments: args,
            workspaceArguments: workspaceArgs, resumeArguments: resumeArgs,
            env: env, prependExeDirToPath: prependPath, output: output,
            continuationField: continuationField, verdict: verdict, isolate: isolate,
            deadlineDiagnostic: deadlineDiagnostic, timeoutSeconds: timeout, cpuSeconds: cpu)
    }

    /// Reject the statically-detectable half of the ADR-000 "select a strategy that
    /// ignores the worker's declaration" hole, plus any pairing that would emit no
    /// signal and silently read as a permanent failure.
//: @use-case:cli.generic.incoherent_descriptor_is_refused_at_load#verdict_output_coherence
    private static func validateCoherence(name: String,
                                          taskDelivery: CliDescriptor.TaskDelivery,
                                          args: [String], output: CliDescriptor.OutputMode,
                                          verdict: CliDescriptor.VerdictStrategy) throws {
        if args.contains("{task}") && taskDelivery != .argv {
            throw ConfigError.malformed("cli '\(name)': {task} in args requires task_delivery='argv'")
        }
        switch verdict {
        case .claudeDeclared where output != .streamJSONResult:
            throw ConfigError.malformed("cli '\(name)': verdict='claude_declared' requires output='stream_json_result'")
        case .grokStopReason:
            if case .jsonField = output {} else {
                throw ConfigError.malformed("cli '\(name)': verdict='grok_stop_reason' requires output='json_field'")
            }
        case .exitCodeOnly where output != .raw:
            // A CLI that emits a declaration cowork can read may not be judged by exit
            // code alone — that is precisely selecting a strategy that ignores it.
            throw ConfigError.malformed("cli '\(name)': verdict='exit_code_only' requires output='raw' (a declaring CLI needs a declaration-reading verdict)")
        default: break
        }
//: @use-case:end cli.generic.incoherent_descriptor_is_refused_at_load#verdict_output_coherence
    }

//: @use-case:cli.generic.execution_sensitive_env_keys_are_refused#protected_env
    private static func parseEnv(name: String, _ dict: [String: Any]) throws -> [CliDescriptor.EnvEntry] {
        var entries: [CliDescriptor.EnvEntry] = []
        for key in dict.keys.sorted() {
            guard let raw = dict[key] as? String else {
                throw ConfigError.malformed("cli '\(name)' env '\(key)' must be a string")
            }
            if protectedEnvExact.contains(key) || protectedEnvPrefixes.contains(where: { key.hasPrefix($0) }) {
                throw ConfigError.protectedEnvKey(cli: name, key: key)
            }
            if raw.hasPrefix("env:") {
                entries.append(.init(key: key, value: .reference(String(raw.dropFirst(4)))))
            } else {
                entries.append(.init(key: key, value: .literal(raw)))
            }
        }
        return entries
//: @use-case:end cli.generic.execution_sensitive_env_keys_are_refused#protected_env
    }

    private static func parseIsolate(_ dict: [String: Any]?) throws -> CliDescriptor.Isolation? {
        guard let dict else { return nil }
        guard let variable = dict["var"] as? String else {
            throw ConfigError.malformed("cli isolate needs a 'var'")
        }
        let seed = (dict["seed"] as? String).map { expand($0) }
        return CliDescriptor.Isolation(variable: variable, seed: seed)
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [String]) ?? (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}

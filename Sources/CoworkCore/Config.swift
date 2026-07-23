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
    public let origin: ProviderConfig.Origin
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
            let executable = expand(try string(table, "executable", name))
            cli[name] = CliConfig(name: name, executable: executable,
                                  kind: try cliDialect(table, name, executable: executable), origin: .global)
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
            let executable = expand(try string(table, "executable", name))
            cli[name] = CliConfig(name: name, executable: executable,
                                  kind: try cliDialect(table, name, executable: executable), origin: .project)
        }

        let visible = try mask(providers: providers, globalDoc: globalDoc, projectDoc: projectDoc)
        return Config(providers: providers, cli: cli, visible: visible)
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

    private static func string(_ table: [String: Any], _ key: String, _ owner: String) throws -> String {
        guard let v = table[key] as? String else {
            throw ConfigError.malformed("'\(owner)' needs a \(key)")
        }
        return v
    }

    /// A `[cli.*]` table's `kind` as a `CliDialect`. Omitted, it derives from the
    /// executable, so a grok binary is grok without the user having to say so twice.
    /// Given, an unrecognized value is a config error the user can act on, not a
    /// silent fallback that would dispatch one agent as though it spoke another's
    /// protocol.
    private static func cliDialect(_ table: [String: Any], _ owner: String,
                                   executable: URL) throws -> CliDialect {
        guard let raw = table["kind"] as? String else { return CliDialect(executable: executable) }
        switch raw {
        case "claude": return .claude
        case "grok": return .grok
        case "codex": return .codex
        default:
            throw ConfigError.malformed(
                "cli '\(owner)' has unknown kind '\(raw)' (use 'claude', 'grok' or 'codex')")
        }
    }

    private static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}

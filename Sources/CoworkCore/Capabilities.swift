import Foundation

/// `capabilities(backend?) -> facts` (ADR 001).
///
/// Rule 3: capabilities are facts, never comfort. Two things follow from that,
/// and they are the whole design here.
///
/// **Reachability is live, so it is probed.** A config file records intent, never
/// truth: an endpoint bound to `127.0.0.1` on a VM host is invisible from the
/// guest — the host answered ping while its port stayed closed — and a
/// model unloaded since yesterday is not there. Probing costs latency and can
/// fail; a cached "available" would be fast and would be a lie, so nothing here
/// is cached.
///
/// **Differences are reported, not flattened.** A Claude worker can be messaged
/// mid-session and `codex exec` cannot, so `supportsMessage` is true for one and
/// false for the other in the same report. Anywhere cowork cannot honestly claim
/// a capability, it says false and says why, rather than promising a mechanism it
/// has not got.
public enum Capabilities {

    /// Facts about one dispatchable backend id.
    ///
    /// A backend id is `provider/model` for an endpoint or a configured CLI name
    /// (ADR 005). Models are never declared in config — what a host serves changes
    /// minute to minute — so every endpoint id here was seen live, just now.
    public struct BackendFacts: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable { case endpoint, cli }

        public let id: String
        public let kind: Kind
        /// Whose configuration this backend came from. A dispatch to a
        /// project-defined provider is recorded as such (ADR 005), so a caller can
        /// see whose provider would run their work before it does.
//: @use-case:config.project_provider_origin_is_reported#project_provider_origin_
        public let origin: ProviderConfig.Origin
        /// Live: this exact id could be dispatched at the moment it was probed.
//: @use-case:end config.project_provider_origin_is_reported#project_provider_origin_
        /// Never a memory of a previous probe.
        public let available: Bool
        public let supportsMessage: Bool
        public let supportsFollowUp: Bool
        /// Why, in the same vocabulary the backends use for a failed dispatch —
        /// `endpoint.unreachable,code=-1004`, `endpoint.auth-rejected,status=401`,
        /// `endpoint.deadline` — because "unreachable", "rejected" and "too slow"
        /// are three different things to do about it. Never a credential.
        public let diagnostics: [String]

        public init(id: String, kind: Kind, origin: ProviderConfig.Origin, available: Bool,
                    supportsMessage: Bool, supportsFollowUp: Bool, diagnostics: [String]) {
            self.id = id; self.kind = kind; self.origin = origin; self.available = available
            self.supportsMessage = supportsMessage; self.supportsFollowUp = supportsFollowUp
            self.diagnostics = diagnostics
        }
    }

    /// Reports facts for one backend id, one provider (expanded to every model it
    /// serves), or — with `backend` absent — everything this project can see.
    ///
    /// Throws only when the id is not a backend at all: an unknown name is the
    /// caller's mistake to fix and must not be answered with a fact-shaped guess.
    /// Everything else — unreachable, rejected, absent model — is a *reported*
    /// fact, because those are the truth about a real backend.
//: @use-case:contract.tools.capabilities_probe_live_models#capabilities_probe_live_
    public static func facts(backend: String? = nil,
                             config: Config,
                             probe: any EndpointProbe = URLSessionEndpointProbe(),
                             secrets: @escaping @Sendable (String) -> Credential? = { Secrets.load($0) })
        async throws -> [BackendFacts] {

        guard let backend else {
            return await all(config: config, probe: probe, secrets: secrets)
        }

        // A configured CLI name is checked first: it is a whole backend id, while a
        // provider name is only half of one. CLI facts come from the same resolver
        // dispatch/send use — supports_message / supports_follow_up are operation
        // presence, not a second hand-maintained opinion.
        if config.cli[backend] != nil, let resolved = BackendResolver.resolve(backend, config: config) {
            return [resolved.facts()]
        }
        if let provider = config.visible[backend] {
            return await facts(for: provider, model: nil, probe: probe, secrets: secrets)
        }
        if let slash = backend.firstIndex(of: "/") {
            let name = String(backend[backend.startIndex..<slash])
            let model = String(backend[backend.index(after: slash)...])
            if !model.isEmpty, let provider = config.visible[name] {
                return await facts(for: provider, model: model, probe: probe, secrets: secrets)
            }
        }
        // Masked providers are genuinely not backends for this project (ADR 005), so
        // the visible list — not the configured one — is what a caller is told.
        throw CapabilitiesError.noSuchBackend(backend,
                                              providers: config.visible.keys.sorted(),
                                              cli: config.cli.keys.sorted())
    }

    private static func all(config: Config, probe: any EndpointProbe,
                            secrets: @escaping @Sendable (String) -> Credential?)
        async -> [BackendFacts] {
        // Probing is network-bound and every provider is independent, so the report
        // costs one provider's latency rather than the sum of them all.
        // CLI facts: same BackendResolver every other path uses.
        var collected = BackendResolver.resolveAllCli(config: config).map { $0.facts() }
        await withTaskGroup(of: [BackendFacts].self) { group in
            for provider in config.visible.values {
                group.addTask { await facts(for: provider, model: nil, probe: probe, secrets: secrets) }
            }
            for await batch in group { collected += batch }
        }
        // Sorted so two reports taken minutes apart can be diffed by a caller, which
        // is the point of reporting live facts at all.
        return collected.sorted { $0.id < $1.id }
    }

    // MARK: endpoints

    private static func facts(for provider: ProviderConfig, model: String?,
                              probe: any EndpointProbe,
                              secrets: @Sendable (String) -> Credential?) async -> [BackendFacts] {
        // When a model was named, the fact is about that id even in failure; when it
        // was not, cowork reports the provider itself rather than inventing model
        // ids it could not see.
        let subject = model.map { "\(provider.name)/\($0)" } ?? provider.name

        var headers = ["Accept": "application/json"]
        if let reference = provider.credential {
            switch credentialHeader(reference: reference, secrets: secrets) {
            case let .header(value):
                headers["Authorization"] = value
            case let .refused(diagnostics):
                // A credential cowork has not got cannot be sent, so the request is
                // never made: an unauthenticated probe would report a different
                // provider's answer to a different question.
                return [unavailableEndpoint(subject, provider, diagnostics)]
            }
        }

        let url = provider.baseURL.appendingPathComponent(modelsPath(chatPath: provider.chatPath))
        let response: ProbeResponse
        do {
            response = try await probe.get(url: url, headers: headers)
        } catch let failure as ProbeTransportFailure {
            return [unavailableEndpoint(subject, provider, failure.diagnostics)]
        } catch {
            return [unavailableEndpoint(subject, provider, ["endpoint.probe-failed"])]
        }

        guard response.status == 200 else {
            return [unavailableEndpoint(subject, provider, diagnostics(for: response))]
        }
        guard let served = servedModels(in: response.body) else {
            return [unavailableEndpoint(subject, provider, ["endpoint.malformed-models"])]
        }

        if let model {
            guard served.contains(model) else {
                // The provider answered; this model is simply not loaded. That is a
                // different fact from "the provider is down", and the caller's next
                // move differs accordingly.
                return [unavailableEndpoint(subject, provider,
                                            ["endpoint.model-absent", "provider=\(provider.name)"])]
            }
            return [availableEndpoint(subject, provider)]
        }
        return served.sorted().map { availableEndpoint("\(provider.name)/\($0)", provider) }
    }

    /// Cowork owns the endpoint loop and the message list it is built from, so
    /// appending a further user message is a real `send`. Follow-up is not: an
    /// endpoint produces no continuation handle (`EndpointSession.lastSessionID`
    /// is always nil), and `follow_up` refuses without one. Claiming true here
    /// was the inverted truthfulness bug.
    ///
    /// supports_message / supports_follow_up come from the resolved operations
    /// (interactive present, follow-up absent) — same source dispatch uses.
    private static func availableEndpoint(_ id: String, _ provider: ProviderConfig) -> BackendFacts {
        let model = id.split(separator: "/").dropFirst().joined(separator: "/")
        let resolved = BackendResolver.resolveEndpoint(id: id, provider: provider,
                                                       model: model.isEmpty ? id : model)
        return resolved.facts(available: true)
    }

    private static func unavailableEndpoint(_ id: String, _ provider: ProviderConfig,
                                            _ diagnostics: [String]) -> BackendFacts {
        let model = id.split(separator: "/").dropFirst().joined(separator: "/")
        let resolved = BackendResolver.resolveEndpoint(id: id, provider: provider,
                                                       model: model.isEmpty ? id : model)
        // Probe failure diagnostics replace the static capability-limit list for
        // unavailable endpoints; keep the no-continuation marker for continuity.
        return resolved.facts(available: false, extraDiagnostics: diagnostics)
    }

    /// The model list is the chat resource's sibling under the same API root.
    ///
    /// "OpenAI-compatible" fixes the request and response *shape*; it does not fix
    /// the URL layout. NVIDIA and Ollama serve `/v1/chat/completions` and list at
    /// `/v1/models`; z.ai carries its root in `base_url` and serves
    /// `chat/completions`, listing at `models`. So the rule is derived from the one
    /// path cowork is told rather than hardcoded: drop the chat resource from the
    /// end of `chat_path` and ask for `models` in its place. Hardcoding `/v1` here
    /// would silently exclude real providers while looking as though *they* were
    /// non-compliant.
    static func modelsPath(chatPath: String) -> String {
        var parts = chatPath.split(separator: "/").map(String.init)
        if parts.count >= 2, parts.suffix(2) == ["chat", "completions"] {
            parts.removeLast(2)
        } else if !parts.isEmpty {
            parts.removeLast()
        }
        return (parts + ["models"]).joined(separator: "/")
    }

    private static func servedModels(in body: Data) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = json["data"] as? [[String: Any]]
        else { return nil }
        return data.compactMap { $0["id"] as? String }
    }

    /// The provider's own message is the only part of its refusal a caller can act
    /// on: "insufficient balance" says what to do, "429" does not — and in practice
    /// the status code was actively misleading, because the message was true and the
    /// real fault was a wrong endpoint. Two shapes are read because providers use
    /// both: OpenAI nests under `error`, z.ai puts `code` and `message` at the top.
    private static func diagnostics(for response: ProbeResponse) -> [String] {
        let kind = (response.status == 401 || response.status == 403)
            ? "endpoint.auth-rejected"
            : "endpoint.http-\(response.status)"
        var diagnostics = [kind, "status=\(response.status)"]

        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else { return diagnostics }
        let error = (json["error"] as? [String: Any]) ?? json
        if let message = error["message"] as? String, !message.isEmpty {
            diagnostics.append("provider=\(message.prefix(120))")
        }
        if let code = error["code"] {
            diagnostics.append("provider_code=\(code)")
        }
        return diagnostics
    }

    /// Fetched at the point of use and never stored, so the value cannot reach a
    /// record or an event by sitting somewhere it could be serialised from. A
    /// failure names the variable, never a value.
    private enum CredentialResolution {
        case header(String)
        case refused([String])
    }

    private static func credentialHeader(reference: String,
                                         secrets: @Sendable (String) -> Credential?)
        -> CredentialResolution {
        if reference.hasPrefix("env:") {
            let name = String(reference.dropFirst("env:".count))
            guard let credential = secrets(name) else {
                return .refused(["endpoint.credential-absent", "expected=\(name)"])
            }
            return .header("Bearer \(credential.exposeForAuthorizationHeader())")
        }
        // A reference cowork cannot resolve is reported rather than dropped: probing
        // without the credential would ask a question the caller did not ask, and
        // "unauthorized" would be cowork's fault reported as the provider's.
        let scheme = reference.split(separator: ":").first.map(String.init) ?? reference
        return .refused(["endpoint.credential-unsupported", "scheme=\(scheme)"])
    }

}

public enum CapabilitiesError: Error, CustomStringConvertible {
    case noSuchBackend(String, providers: [String], cli: [String])

    public var description: String {
        switch self {
        case let .noSuchBackend(id, providers, cli):
            return """
                capabilities.no-such-backend: '\(id)'. visible providers: \
                \(providers.joined(separator: ", ")); cli: \(cli.joined(separator: ", "))
                """
        }
    }
}

// MARK: - the HTTP boundary

/// One GET, injected — which is what makes reachability testable without a
/// network. A unit test that needs a live endpoint tests the endpoint.
public protocol EndpointProbe: Sendable {
    func get(url: URL, headers: [String: String]) async throws -> ProbeResponse
}

public struct ProbeResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// A request that never reached a provider. Distinguished from an HTTP status
/// because "nothing answered" and "something refused" are different facts.
public enum ProbeTransportFailure: Error, Sendable {
    case timedOut
    case unreachable(code: Int)

    var diagnostics: [String] {
        switch self {
        case .timedOut: return ["endpoint.deadline"]
        case let .unreachable(code): return ["endpoint.unreachable", "code=\(code)"]
        }
    }
}

public struct URLSessionEndpointProbe: EndpointProbe {
    /// A probe deadline is short, and deliberately unrelated to a dispatch
    /// deadline. Generation latency spans seconds to minutes and no single timeout
    /// serves that spread; listing what a host serves is a cheap read, and a host
    /// that cannot answer it in seconds is a fact worth reporting rather than
    /// waiting on.
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 10) { self.timeout = timeout }

    public func get(url: URL, headers: [String: String]) async throws -> ProbeResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return ProbeResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch {
            let ns = error as NSError
            if ns.code == NSURLErrorTimedOut { throw ProbeTransportFailure.timedOut }
            throw ProbeTransportFailure.unreachable(code: ns.code)
        }
    }
}

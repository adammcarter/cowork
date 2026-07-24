import Foundation
import Testing

@testable import CoworkCore

/// ADR 001 rule 3: capabilities are facts, never comfort. Live reachability is
/// probed rather than remembered, differences between backends are reported
/// rather than flattened, and a failure is named precisely enough to act on —
/// unreachable, auth-rejected and timed-out are three different facts.
///
/// Nothing here touches the network: the HTTP boundary is injected, because a
/// test that needs a live endpoint tests the endpoint rather than cowork.
@Suite("Capabilities")
struct CapabilitiesTests {

    // MARK: a scripted endpoint, standing in for a provider's HTTP surface

    /// Records what was asked of it so a test can assert on the request — most
    /// importantly that the Authorization header is present when a provider is
    /// configured with a credential, and absent when it is not.
    final class ScriptedProbe: EndpointProbe, @unchecked Sendable {
        enum Reply { case response(ProbeResponse), failure(ProbeTransportFailure) }

        private let reply: Reply
        private let lock = NSLock()
        private var seen: [(url: URL, headers: [String: String])] = []

        init(_ reply: Reply) { self.reply = reply }

        static func serving(models: [String]) -> ScriptedProbe {
            let data = try! JSONSerialization.data(
                withJSONObject: ["object": "list", "data": models.map { ["id": $0] }])
            return ScriptedProbe(.response(ProbeResponse(status: 200, body: data)))
        }

        /// Recorded synchronously: NSLock is unavailable from an async context.
        private func record(_ url: URL, _ headers: [String: String]) {
            lock.lock(); defer { lock.unlock() }
            seen.append((url, headers))
        }

        func get(url: URL, headers: [String: String]) async throws -> ProbeResponse {
            record(url, headers)
            switch reply {
            case let .response(r): return r
            case let .failure(f): throw f
            }
        }

        var requests: [(url: URL, headers: [String: String])] {
            lock.lock(); defer { lock.unlock() }
            return seen
        }
    }

    private func endpointConfig(name: String = "omlx",
                                baseURL: String = "http://192.168.64.1:8062",
                                chatPath: String = "v1/chat/completions",
                                credential: String? = nil,
                                origin: ProviderConfig.Origin = .global) -> Config {
        let p = ProviderConfig(name: name, kind: "openai_compatible",
                               baseURL: URL(string: baseURL)!, chatPath: chatPath,
                               credential: credential, origin: origin)
        return Config(providers: [name: p], cli: [:], visible: [name: p])
    }

    private func cliConfig(_ executables: [String: URL],
                           origin: ProviderConfig.Origin = .global) -> Config {
        var cli: [String: CliConfig] = [:]
        for (name, url) in executables {
            // kind matches the executable, the normal case — the parser derives it
            // this way when the user omits `kind`. Deliberate mismatches are set
            // explicitly by the tests that exercise them.
            cli[name] = CliConfig(name: name, executable: url,
                                  kind: CliDialect(executable: url), origin: origin)
        }
        return Config(providers: [:], cli: cli, visible: [:])
    }

    /// A real, executable file: `available` for a CLI is a live fact about the
    /// filesystem, so the test must give it a filesystem to be right about.
    private func installedExecutable(named name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: the models path is derived from the chat path, because the layout is configuration

    /// "OpenAI-compatible" fixes the request shape, not the URL layout: z.ai serves
    /// `/api/coding/paas/v4/chat/completions` and NVIDIA serves
    /// `/v1/chat/completions`. The model list is the chat resource's sibling under
    /// the same API root, so the rule is "replace the chat resource with `models`".
    @Test("the models path is the chat resource's sibling under the same API root",
          arguments: [
            ("v1/chat/completions", "v1/models"),          // NVIDIA, Ollama, oMLX
            ("chat/completions", "models"),                // z.ai: the root is in base_url
            ("api/coding/paas/v4/chat/completions", "api/coding/paas/v4/models"),
            ("/v1/chat/completions/", "v1/models"),        // stray slashes are not a layout
            ("v1/responses", "v1/models"),                 // any final resource, not just chat
          ])
    func modelsPathIsDerived(chatPath: String, expected: String) {
        #expect(Capabilities.modelsPath(chatPath: chatPath) == expected)
    }

    // MARK: live reachability

    @Test("a reachable provider reports one dispatchable backend id per served model")
    func servedModelsBecomeBackendIds() async throws {
        let probe = ScriptedProbe.serving(models: ["example-7b", "example-think"])
        let facts = try await Capabilities.facts(backend: "omlx", config: endpointConfig(),
                                                 probe: probe, secrets: { _ in nil })

        #expect(facts.map(\.id) == ["omlx/example-7b", "omlx/example-think"])
        #expect(facts.allSatisfy { $0.available })
        // Available endpoints still name why follow-up is false — a capability
        // limit, not a reachability failure. No failure diagnostics present.
        #expect(facts.allSatisfy { $0.diagnostics == ["endpoint.no-continuation"] })
        #expect(probe.requests.first?.url.absoluteString == "http://192.168.64.1:8062/v1/models")
    }

    /// The gotcha: an endpoint bound to 127.0.0.1 on a VM host is invisible from the
    /// guest — the host answers ping while the port stays closed. Config
    /// records intent; only a probe knows.
    @Test("an unreachable provider is reported unreachable, with the code that says so")
    func unreachableIsAFact() async throws {
        let probe = ScriptedProbe(.failure(.unreachable(code: -1004)))
        let facts = try await Capabilities.facts(backend: "omlx", config: endpointConfig(),
                                                 probe: probe, secrets: { _ in nil })

        // No model ids are invented for a provider cowork could not see.
        #expect(facts.count == 1)
        #expect(facts[0].id == "omlx")
        #expect(facts[0].available == false)
        #expect(facts[0].diagnostics.contains("endpoint.unreachable"))
        #expect(facts[0].diagnostics.contains("code=-1004"))
    }

    @Test("a timeout is not an unreachable host: they are different, actionable facts")
    func timeoutIsItsOwnFact() async throws {
        let probe = ScriptedProbe(.failure(.timedOut))
        let facts = try await Capabilities.facts(backend: "omlx", config: endpointConfig(),
                                                 probe: probe, secrets: { _ in nil })

        #expect(facts[0].available == false)
        #expect(facts[0].diagnostics.contains("endpoint.deadline"))
        #expect(facts[0].diagnostics.contains("endpoint.unreachable") == false)
    }

    @Test("a rejected credential is auth-rejected, not a generic HTTP failure",
          arguments: [401, 403])
    func authRejectionIsItsOwnFact(status: Int) async throws {
        let probe = ScriptedProbe(.response(ProbeResponse(status: status, body: Data())))
        let facts = try await Capabilities.facts(backend: "omlx",
                                                 config: endpointConfig(credential: "env:CAP_TEST_KEY"),
                                                 probe: probe,
                                                 secrets: { _ in Credential("sk-live-secret") })

        #expect(facts[0].available == false)
        #expect(facts[0].diagnostics.contains("endpoint.auth-rejected"))
        #expect(facts[0].diagnostics.contains("status=\(status)"))
    }

    /// "Insufficient balance" says what to do; "429" does not. The provider's own
    /// message is the only actionable part of its refusal, and reducing it to a
    /// status code was actively misleading in practice — the message was true and
    /// the real fault was a wrong endpoint.
    @Test("the provider's own error text survives, because it is the actionable part")
    func providerErrorTextIsPreserved() async throws {
        // z.ai's real shape: code and message at the top level, no `error` wrapper.
        let body = try JSONSerialization.data(
            withJSONObject: ["code": "1113", "message": "Insufficient balance or no resource package."])
        let probe = ScriptedProbe(.response(ProbeResponse(status: 429, body: body)))
        let facts = try await Capabilities.facts(backend: "zai",
                                                 config: endpointConfig(name: "zai"),
                                                 probe: probe, secrets: { _ in nil })

        #expect(facts[0].diagnostics.contains("endpoint.http-429"))
        #expect(facts[0].diagnostics.contains { $0.hasPrefix("provider=Insufficient balance") })
        #expect(facts[0].diagnostics.contains("provider_code=1113"))
    }

    @Test("an OpenAI-shaped error wrapper is preserved too")
    func nestedProviderErrorTextIsPreserved() async throws {
        let body = try JSONSerialization.data(
            withJSONObject: ["error": ["message": "model not found", "code": "404"]])
        let probe = ScriptedProbe(.response(ProbeResponse(status: 404, body: body)))
        let facts = try await Capabilities.facts(backend: "omlx", config: endpointConfig(),
                                                 probe: probe, secrets: { _ in nil })

        #expect(facts[0].diagnostics.contains("provider=model not found"))
        #expect(facts[0].diagnostics.contains("provider_code=404"))
    }

    @Test("an explicitly named model the provider does not serve is not available")
    func namedModelAbsent() async throws {
        let probe = ScriptedProbe.serving(models: ["example-7b"])
        let facts = try await Capabilities.facts(backend: "omlx/gone-since-yesterday",
                                                 config: endpointConfig(),
                                                 probe: probe, secrets: { _ in nil })

        #expect(facts.count == 1)
        #expect(facts[0].id == "omlx/gone-since-yesterday")
        #expect(facts[0].available == false)
        #expect(facts[0].diagnostics.contains("endpoint.model-absent"))
    }

    @Test("an explicitly named model the provider does serve is available")
    func namedModelPresent() async throws {
        let probe = ScriptedProbe.serving(models: ["a", "example-7b"])
        let facts = try await Capabilities.facts(backend: "omlx/example-7b",
                                                 config: endpointConfig(),
                                                 probe: probe, secrets: { _ in nil })

        #expect(facts.map(\.id) == ["omlx/example-7b"])
        #expect(facts[0].available)
    }

    @Test("a model list cowork cannot parse is malformed, never an empty world")
    func malformedModelList() async throws {
        let probe = ScriptedProbe(.response(ProbeResponse(status: 200, body: Data("<html/>".utf8))))
        let facts = try await Capabilities.facts(backend: "omlx", config: endpointConfig(),
                                                 probe: probe, secrets: { _ in nil })

        #expect(facts[0].available == false)
        #expect(facts[0].diagnostics.contains("endpoint.malformed-models"))
    }

    // MARK: credentials

    @Test("a provider with a credential is probed with its bearer header")
    func credentialIsSentAsBearer() async throws {
        let probe = ScriptedProbe.serving(models: ["glm-4.6"])
        _ = try await Capabilities.facts(backend: "zai",
                                         config: endpointConfig(name: "zai", credential: "env:ZAI_KEY"),
                                         probe: probe,
                                         secrets: { name in
                                             name == "ZAI_KEY" ? Credential("sk-live-secret") : nil
                                         })

        #expect(probe.requests.first?.headers["Authorization"] == "Bearer sk-live-secret")
    }

    @Test("a provider without a credential is probed without one")
    func noCredentialMeansNoHeader() async throws {
        let probe = ScriptedProbe.serving(models: ["llama3.2:3b"])
        _ = try await Capabilities.facts(backend: "ollama", config: endpointConfig(name: "ollama"),
                                         probe: probe, secrets: { _ in nil })

        #expect(probe.requests.first?.headers["Authorization"] == nil)
    }

    /// The rule the type exists to enforce: a credential never reaches a log, a
    /// record, an event, a diagnostic or a transcript. `capabilities` is output, so
    /// this is the place it would leak.
    @Test("a credential appears nowhere in the reported facts")
    func credentialNeverLeaks() async throws {
        let probe = ScriptedProbe(.response(ProbeResponse(status: 401, body: Data("sk-live-secret rejected".utf8))))
        let facts = try await Capabilities.facts(backend: "zai",
                                                 config: endpointConfig(name: "zai", credential: "env:ZAI_KEY"),
                                                 probe: probe,
                                                 secrets: { _ in Credential("sk-live-secret") })

        let rendered = facts.map { "\($0.id) \($0.diagnostics.joined(separator: ","))" }.joined()
        #expect(rendered.contains("sk-live-secret") == false)
    }

    @Test("a missing credential fails before the request is sent, naming the variable only")
    func missingCredentialNamesTheVariable() async throws {
        let probe = ScriptedProbe.serving(models: ["glm-4.6"])
        let facts = try await Capabilities.facts(backend: "zai",
                                                 config: endpointConfig(name: "zai", credential: "env:ZAI_KEY"),
                                                 probe: probe, secrets: { _ in nil })

        #expect(facts[0].available == false)
        #expect(facts[0].diagnostics.contains("endpoint.credential-absent"))
        #expect(facts[0].diagnostics.contains("expected=ZAI_KEY"))
        #expect(probe.requests.isEmpty, "a credential cowork does not have cannot be sent")
    }

    @Test("a credential reference cowork cannot resolve is reported, never guessed past")
    func unsupportedCredentialScheme() async throws {
        let probe = ScriptedProbe.serving(models: ["glm-4.6"])
        let facts = try await Capabilities.facts(
            backend: "zai",
            config: endpointConfig(name: "zai", credential: "vault:cowork/zai"),
            probe: probe, secrets: { _ in nil })

        #expect(facts[0].available == false)
        #expect(facts[0].diagnostics.contains("endpoint.credential-unsupported"))
        #expect(facts[0].diagnostics.contains("scheme=vault"))
        #expect(probe.requests.isEmpty)
    }

    // MARK: CLI backends — where the differences must not be flattened

    /// ADR 001's confirmation, in one test: `supports_message` is true for a backend
    /// that can honestly do it and false for one that cannot, in the same report.
    @Test("supports_message differs between CLI drivers, and the report says so")
    func supportsMessageIsNotFlattened() async throws {
        // Every recognised dialect (claude, grok, codex) is now SessionCapable, so the
        // remaining honest "false" is a driver cowork does not recognise: it may well
        // accept messages, but cowork has no agent that can send one, and the capability
        // reported is cowork's.
        let claude = try installedExecutable(named: "claude")
        let mystery = try installedExecutable(named: "mystery-agent")
        let facts = try await Capabilities.facts(
            backend: nil, config: cliConfig(["claude": claude, "mystery": mystery]),
            probe: ScriptedProbe.serving(models: []), secrets: { _ in nil })

        let byID = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
        #expect(byID["claude"]?.supportsMessage == true)
        #expect(byID["mystery"]?.supportsMessage == false)
        #expect(byID["mystery"]?.diagnostics.contains("cli.driver-unknown") == true)
        #expect(byID["claude"]?.available == true)
        #expect(byID["mystery"]?.kind == .cli)
    }

    /// Grok is a recognised driver, and its interactive ACP transport is now built —
    /// so it reports supports_message true, backed by `GrokAgent: SessionCapable`,
    /// the same conformance dispatch reads. Never "driver-unknown".
    @Test("a grok backend is a known driver: one-shot AND interactive, never driver-unknown")
    func grokIsAKnownDriver() async throws {
        let grok = try installedExecutable(named: "grok")
        let facts = try await Capabilities.facts(
            backend: nil, config: cliConfig(["grok": grok]),
            probe: ScriptedProbe.serving(models: []), secrets: { _ in nil })

        let g = facts.first { $0.id == "grok" }
        #expect(g?.available == true)
        #expect(g?.supportsMessage == true, "grok's ACP session is built — supports_message is backed by SessionCapable")
        #expect(g?.diagnostics.contains("cli.driver-unknown") == false, "grok is recognised, not unknown")
    }

    /// An endpoint can be messaged (cowork owns the message list) but cannot be
    /// followed up: `EndpointSession` produces no continuation handle, so
    /// `follow_up` refuses. Claiming true here was the inverted truthfulness bug.
    @Test("an endpoint can be messaged but not followed up: no continuation handle")
    func endpointSupportsMessageNotFollowUp() async throws {
        let facts = try await Capabilities.facts(backend: "omlx", config: endpointConfig(),
                                                 probe: ScriptedProbe.serving(models: ["m"]),
                                                 secrets: { _ in nil })

        #expect(facts[0].supportsMessage)
        #expect(facts[0].supportsFollowUp == false)
        #expect(facts[0].diagnostics.contains("endpoint.no-continuation"))
    }

    /// Claude's one-shot captures `session_id` and accepts `--resume`, so it is
    /// `FollowUpCapable` and capabilities reports true — the same conformance
    /// that pins the mechanism, never a hand-maintained Bool.
    @Test("claude reports supports_follow_up true, backed by FollowUpCapable")
    func claudeFollowUpIsCapable() async throws {
        let claude = try installedExecutable(named: "claude")
        let facts = try await Capabilities.facts(backend: "claude", config: cliConfig(["claude": claude]),
                                                 probe: ScriptedProbe.serving(models: []),
                                                 secrets: { _ in nil })

        #expect(facts[0].supportsFollowUp == true)
        #expect(facts[0].diagnostics.contains("cli.follow-up-unproven") == false)
    }

    /// Codex exec leaves no continuation handle, so it is not `FollowUpCapable`
    /// and the report says false with a named reason — never a blanket lie about
    /// every CLI.
    @Test("a CLI whose one-shot has no continuation reports follow-up false, with the reason")
    func cliWithoutContinuationReportsFollowUpFalse() async throws {
        let codex = try installedExecutable(named: "codex")
        let facts = try await Capabilities.facts(backend: "codex", config: cliConfig(["codex": codex]),
                                                 probe: ScriptedProbe.serving(models: []),
                                                 secrets: { _ in nil })

        #expect(facts[0].supportsFollowUp == false)
        #expect(facts[0].diagnostics.contains("cli.follow-up-unproven"))
    }

    /// `supports_follow_up` is literally `agent is FollowUpCapable`, the same
    /// pattern as `supports_message` / `SessionCapable`. The two cannot drift.
    @Test("supports_follow_up is the agent's wired mechanism, not an independent Bool")
    func followUpIsTheConformance() async throws {
        let claude = try installedExecutable(named: "claude")
        let codex = try installedExecutable(named: "codex")
        let facts = try await Capabilities.facts(
            backend: nil, config: cliConfig(["claude": claude, "codex": codex]),
            probe: ScriptedProbe.serving(models: []), secrets: { _ in nil })
        let byID = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })

        let claudeAgent = CliRegistry.agent(for: CliConfig(
            name: "claude", executable: claude, kind: .claude, origin: .global))
        let codexAgent = CliRegistry.agent(for: CliConfig(
            name: "codex", executable: codex, kind: .codex, origin: .global))

        #expect(byID["claude"]?.supportsFollowUp == claudeAgent?.isFollowUpCapable)
        #expect(byID["codex"]?.supportsFollowUp == codexAgent?.isFollowUpCapable)
        #expect(claudeAgent?.isFollowUpCapable == true)
        #expect(codexAgent?.isFollowUpCapable == false)
    }

    /// A CLI cowork has no driver for cannot be messaged by cowork, whatever the
    /// binary itself can do. Reporting true here would be a guess.
    @Test("an unrecognised CLI cannot honestly be claimed as messageable")
    func unknownDriverClaimsNothing() async throws {
        let weird = try installedExecutable(named: "some-other-agent")
        let facts = try await Capabilities.facts(backend: "weird", config: cliConfig(["weird": weird]),
                                                 probe: ScriptedProbe.serving(models: []),
                                                 secrets: { _ in nil })

        #expect(facts[0].supportsMessage == false)
        #expect(facts[0].diagnostics.contains("cli.driver-unknown"))
        #expect(facts[0].diagnostics.contains("executable=some-other-agent"))
    }

    /// A non-canonically-named binary — a wrapper, a shim, a `claude-3.5` — that the
    /// executable heuristic cannot recognise is still dispatchable by the `kind` the
    /// user gave it, and reports that dialect's real capabilities. The explicit kind
    /// is a legitimate fallback, not a mismatch to warn about; refusing a working
    /// binary over a name is the regression this guards against.
    @Test("an explicit kind makes a non-canonically-named binary a known, capable agent")
    func explicitKindRoutesAWrapper() async throws {
        let wrapper = try installedExecutable(named: "claude-wrapper")
        let config = Config(providers: [:], cli: [
            "wrapped": CliConfig(name: "wrapped", executable: wrapper, kind: .claude, origin: .global),
        ], visible: [:])
        let facts = try await Capabilities.facts(backend: "wrapped", config: config,
                                                 probe: ScriptedProbe.serving(models: []),
                                                 secrets: { _ in nil })

        #expect(facts[0].supportsMessage == true, "a claude wrapper is claude, and claude can be messaged")
        #expect(facts[0].diagnostics.contains("cli.driver-unknown") == false)
        #expect(facts[0].diagnostics.contains("cli.kind-mismatch") == false,
                "the executable is unrecognised, so the kind is a fallback, not a disagreement")
    }

    @Test("a configured CLI that is not installed is not available")
    func cliExecutableMustExist() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/bin/claude")
        let facts = try await Capabilities.facts(backend: "claude", config: cliConfig(["claude": missing]),
                                                 probe: ScriptedProbe.serving(models: []),
                                                 secrets: { _ in nil })

        #expect(facts[0].available == false)
        #expect(facts[0].diagnostics.contains("cli.executable-absent"))
    }

    // MARK: scope and origin

    @Test("origin is reported: a caller must be able to see whose provider ran their work")
    func originIsReported() async throws {
        let facts = try await Capabilities.facts(backend: "scratch",
                                                 config: endpointConfig(name: "scratch", origin: .project),
                                                 probe: ScriptedProbe.serving(models: ["m"]),
                                                 secrets: { _ in nil })

        #expect(facts[0].origin == .project)
    }

    @Test("capabilities sees only what the project's profiles make visible")
    func maskedProviderIsNotABackend() async throws {
        let masked = ProviderConfig(name: "zai", kind: "openai_compatible",
                                    baseURL: URL(string: "https://api.z.ai")!,
                                    chatPath: "chat/completions", credential: nil, origin: .global)
        let config = Config(providers: ["zai": masked], cli: [:], visible: [:])

        await #expect(throws: CapabilitiesError.self) {
            _ = try await Capabilities.facts(backend: "zai", config: config,
                                             probe: ScriptedProbe.serving(models: ["glm-4.6"]),
                                             secrets: { _ in nil })
        }
    }

    @Test("an unknown backend id is refused with what is actually visible")
    func unknownBackendIsRefused() async throws {
        let config = endpointConfig()
        do {
            _ = try await Capabilities.facts(backend: "typo/model", config: config,
                                             probe: ScriptedProbe.serving(models: []),
                                             secrets: { _ in nil })
            Issue.record("an unknown backend must not be answered")
        } catch let error as CapabilitiesError {
            #expect(error.description.contains("omlx"), "the caller needs the real list to act")
        }
    }

    @Test("with no backend named, every visible endpoint and CLI is reported")
    func everythingIsReported() async throws {
        let claude = try installedExecutable(named: "claude")
        let p = ProviderConfig(name: "omlx", kind: "openai_compatible",
                               baseURL: URL(string: "http://192.168.64.1:8062")!,
                               chatPath: "v1/chat/completions", credential: nil, origin: .global)
        let config = Config(providers: ["omlx": p], cli: ["claude": CliConfig(name: "claude", executable: claude, kind: .claude, origin: .global)],
                            visible: ["omlx": p])

        let facts = try await Capabilities.facts(backend: nil, config: config,
                                                 probe: ScriptedProbe.serving(models: ["m1", "m2"]),
                                                 secrets: { _ in nil })

        #expect(facts.map(\.id) == ["claude", "omlx/m1", "omlx/m2"], "sorted, so a caller can diff two reports")
    }
}

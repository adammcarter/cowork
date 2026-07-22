import Foundation

/// An endpoint backend turns a model endpoint into a managed agent (ADR 000).
/// The model runs elsewhere — locally hosted or remote — and cowork owns the loop.
///
/// The loop is a **faithful client of the endpoint's own contract, not an
/// abstraction over it** (ADR 001). Tool calling and reasoning are native to the
/// endpoint; cowork passes them through rather than reimplementing inference or
/// flattening a provider that can think and call tools into one that cannot.
public struct EndpointBackend: Sendable {
    public let baseURL: URL
    public let model: String
    public let dialect: any EndpointDialect
    public var maxTokens: Int? = nil
    /// Resolved lazily at the point of use so the value never sits in a record.
//: @use-case:endpoint.ollama.lan_http_noauth_dispatch_succeeds#lan_http_noauth_dispatch
    public var credentialName: String? = nil
    /// "OpenAI-compatible" fixes the request and response *shape*, not the URL
//: @use-case:end endpoint.ollama.lan_http_noauth_dispatch_succeeds#lan_http_noauth_dispatch
    /// layout: NVIDIA and Ollama serve `/v1/chat/completions`, z.ai serves
    /// `/api/paas/v4/chat/completions`. The dialect is the contract; the path is
    /// configuration, and assuming otherwise silently excludes real providers.
//: @use-case:endpoint.qwen.hosted_https_key_dispatch_succeeds#hosted_https_key_dispatc
    public var chatPath: String = "v1/chat/completions"

    public init(baseURL: URL, model: String, dialect: any EndpointDialect,
                maxTokens: Int? = nil,
                credentialName: String? = nil, chatPath: String = "v1/chat/completions") {
        self.baseURL = baseURL
        self.model = model
        self.dialect = dialect
        self.maxTokens = maxTokens
        self.credentialName = credentialName
        self.chatPath = chatPath
    }

//: @use-case:end endpoint.qwen.hosted_https_key_dispatch_succeeds#hosted_https_key_dispatc
    public struct Outcome: Sendable {
        public let state: DispatchRecord.State
        public let text: String
        public let diagnostics: [String]
        public var transcript: String = ""

        public init(state: DispatchRecord.State, text: String, diagnostics: [String],
                    transcript: String = "") {
            self.state = state
            self.text = text
            self.diagnostics = diagnostics
            self.transcript = transcript
        }
    }

    /// Runs one fresh bounded conversation to completion.
    ///
    /// Truthfulness (ADR 000) applied at every hop: HTTP 200 is this backend's
    /// equivalent of "the process exited 0" — a diagnostic, never the verdict. The
    /// worker's declared `finish_reason` decides. `tool_calls` is a *continuation*;
    /// only the loop's own conclusion is terminal.
    public func run(task: String, workspace: Workspace?) async -> Outcome {
        let conversation = makeConversation(workspace: workspace)
        let outcome = await conversation.turn(task)
        return Outcome(state: outcome.state, text: outcome.text,
                       diagnostics: outcome.diagnostics, transcript: outcome.transcript)
    }

    /// The same endpoint, held open across turns for an interactive dispatch.
    ///
    /// `run` is one-shot; this is the warm form. The returned session retains one
    /// `EndpointConversation`, so a `send` continues its message history rather
    /// than starting a new one. This is what turns `capabilities`'
    /// long-standing `supports_message: true` for endpoints from a promise into a
    /// fact.
    public func session(workspace: Workspace?) -> EndpointSession {
        EndpointSession(conversation: makeConversation(workspace: workspace))
    }

    private func makeConversation(workspace: Workspace?) -> EndpointConversation {
        EndpointConversation(
            model: model, maxTokens: maxTokens, tools: Tools.definitions(), dialect: dialect,
            http: { body in try await self.post(body) },
            executeTool: { name, arguments in
                Tools.execute(name: name, arguments: arguments, workspace: workspace)
            })
    }

    private func post(_ body: Data) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(chatPath))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180
        // The credential is fetched here, used here, and never stored, logged, or
        // passed to a child. A missing one fails before the request is sent, with
        // a diagnostic that names the variable and never its value.
//: @use-case:endpoint.nvidia.hosted_https_key_dispatch_succeeds#hosted_https_key_dispatc
        if let credentialName {
            guard let cred = Secrets.load(credentialName) else {
                throw EndpointConversation.Failure(state: .failed,
                                    diagnostics: ["endpoint.credential-absent", "expected=\(credentialName)"])
            }
            req.setValue("Bearer \(cred.exposeForAuthorizationHeader())",
                         forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body
//: @use-case:end endpoint.nvidia.hosted_https_key_dispatch_succeeds#hosted_https_key_dispatc

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                // 401/403 are distinct, actionable facts, not generic failures.
//: @use-case:truth.capabilities.auth_rejected_is_distinct_from_generic_http#auth_rejected_is_distinc
                let kind = (code == 401 || code == 403) ? "endpoint.auth-rejected" : "endpoint.http-\(code)"
                // The provider's own error body is its declared outcome, and it is
//: @use-case:end truth.capabilities.auth_rejected_is_distinct_from_generic_http#auth_rejected_is_distinc
                // the part a caller can act on: "insufficient balance" says what to
                // do, "429" does not. Preserve it rather than reducing a provider's
                // diagnosis to a status code — the same rule that makes a worker's
                // finish_reason the verdict (ADR 000).
                var diagnostics = [kind, "status=\(code)"]
//: @use-case:truth.endpoint.provider_error_text_survives#provider_error_text_surv
                if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let err = body["error"] as? [String: Any] {
                    if let message = err["message"] as? String, !message.isEmpty {
                        diagnostics.append("provider=\(message.prefix(120))")
                    }
                    if let pcode = err["code"] {
                        diagnostics.append("provider_code=\(pcode)")
                    }
                }
                throw EndpointConversation.Failure(state: .failed, diagnostics: diagnostics)
//: @use-case:end truth.endpoint.provider_error_text_survives#provider_error_text_surv
            }
            return data
        } catch let e as EndpointConversation.Failure {
            throw e
        } catch {
            let ns = error as NSError
//: @use-case:truth.capabilities.unreachable_is_distinct_from_timeout#unreachable_is_distinct_
            if ns.code == NSURLErrorTimedOut {
                throw EndpointConversation.Failure(state: .timedOut, diagnostics: ["endpoint.deadline"])
            }
            throw EndpointConversation.Failure(state: .failed, diagnostics: ["endpoint.unreachable", "code=\(ns.code)"])
        }
    }
//: @use-case:end truth.capabilities.unreachable_is_distinct_from_timeout#unreachable_is_distinct_
}

import Foundation

/// The verdict: what a worker's own declaration means (ADR 000).
///
/// This is the product. Everything else is plumbing that carries bytes; this is
/// the rule that says a worker declaring an error while exiting 0 has **failed**,
/// and that HTTP 200 with a truncated body is **not** success.
///
/// It lives here, in the testable core, rather than inside a backend, because it
/// is a decision and not an I/O concern. Left inside the HTTP client it could only
/// ever be checked by a performed journey — and a journey cannot stage every
/// declaration a worker might make.
public enum Verdict {
    /// An endpoint's declared outcome.
    ///
    /// The transport is a diagnostic, never the verdict: HTTP 200 is an endpoint
    /// backend's equivalent of "the process exited 0".
    public enum Endpoint: Equatable {
        /// The loop continues: the model asked to use a tool. Not terminal — only
        /// the loop's own conclusion is.
        case toolCalls
        case terminal(DispatchRecord.State, diagnostics: [String])
    }

    public static func endpoint(finishReason: String) -> Endpoint {
        switch finishReason {
        case "stop":
            return .terminal(.succeeded, diagnostics: [])
//: @use-case:truth.endpoint.truncated_200_is_failed#truncated_200_is_failed
        case "length":
            // 200 OK, real content — and still a failure, because the worker said
            // so. Handing back a truncated answer as success is the exact lie this
            // product exists to prevent.
            return .terminal(.failed, diagnostics: ["endpoint.truncated", "finish_reason=length"])
        case "tool_calls":
            return .toolCalls
//: @use-case:end truth.endpoint.truncated_200_is_failed#truncated_200_is_failed
//: @use-case:truth.endpoint.unknown_finish_reason_is_not_a_success#unknown_finish_reason_is
        default:
            // An unknown declaration is not a success. A provider that invents a
            // finish_reason we have never seen may mean anything, and guessing
            // "probably fine" is how a wrong answer becomes a reported one.
            return .terminal(.failed, diagnostics: ["endpoint.unexpected-finish",
                                                    "finish_reason=\(finishReason)"])
        }
    }
//: @use-case:end truth.endpoint.unknown_finish_reason_is_not_a_success#unknown_finish_reason_is

    /// A CLI agent's declared outcome, weighed against its exit code.
    ///
    /// The two can disagree, and the disagreement is recorded rather than resolved
    /// in the transport's favour. Proven in the wild: Claude Code declared
    /// `subtype: "success"` AND `is_error: true` while exiting 1, when it was not
    /// logged in.
//: @use-case:truth.cli.declared_error_with_exit_zero_is_failed#declared_error_with_exit
    public static func cli(declaredSubtype: String?, isError: Bool, exitCode: Int32)
        -> (state: DispatchRecord.State, diagnostics: [String]) {
        guard let subtype = declaredSubtype else {
            // The agent never said anything about itself. An exit code alone is not
            // an outcome — it says the process ended, not that the work was done.
            return (.failed, ["cli.no-declared-result", "exit=\(exitCode)"])
        }
        if isError || subtype != "success" {
            return (.failed, ["cli.declared-error", "subtype=\(subtype)", "exit=\(exitCode)"])
        }
        if exitCode != 0 {
            // The worker declared success and the process disagreed. The worker's
            // declaration wins — it knows what it did — but the disagreement is a
            // fact the caller gets to see rather than one we quietly resolve.
            return (.succeeded, ["cli.nonzero-exit-despite-declared-success", "exit=\(exitCode)"])
        }
        return (.succeeded, [])
    }

    /// Grok's declared outcome, weighed against its exit code.
    ///
    /// Grok's one-shot JSON declares a `stopReason` rather than claude's `subtype`:
    /// `EndTurn` is a clean finish, `MaxTokens` is a truncation. The rule is the
    /// same one every backend gets — the worker's own declaration is the verdict,
    /// the exit code is a diagnostic beside it, and an unfamiliar declaration is
    /// never optimistically read as success.
    public static func grok(stopReason: String?, exitCode: Int32)
        -> (state: DispatchRecord.State, diagnostics: [String]) {
        guard let reason = stopReason else {
            // No readable declaration. The process ended; that is not the same as
            // the work being done.
            return (.failed, ["cli.grok.no-declared-result", "exit=\(exitCode)"])
        }
        switch reason {
        case "EndTurn":
            if exitCode != 0 {
                // The turn finished but the process disagreed. The declaration wins,
                // the disagreement is recorded rather than quietly resolved.
                return (.succeeded, ["cli.grok.nonzero-exit-despite-endturn", "exit=\(exitCode)"])
            }
            return (.succeeded, [])
        case "MaxTokens":
            // A truncated answer, however clean the exit. Handing it back as success
            // is the exact lie this product exists to prevent.
            return (.failed, ["cli.grok.truncated", "stopReason=MaxTokens"])
        default:
            return (.failed, ["cli.grok.unexpected-stop", "stopReason=\(reason)"])
        }
    }

    /// Codex-exec's declared outcome.
    ///
    /// `codex exec` runs the task from stdin and prints its work, but in this mode
    /// it declares no subtype or stopReason the way claude and grok do — so the exit
    /// is the only signal there is. That is a weaker declaration than the other
    /// dialects', and the rule says so plainly rather than inventing a richer one:
    /// a clean exit is a success, a nonzero exit is a failure that records the code.
    public static func codex(exitCode: Int32)
        -> (state: DispatchRecord.State, diagnostics: [String]) {
        if exitCode == 0 { return (.succeeded, []) }
        return (.failed, ["cli.codex.exit", "exit=\(exitCode)"])
    }

    /// Grok ACP (Agent Client Protocol) interactive stopReason.
    ///
    /// The live ACP wire uses snake_case `end_turn` rather than one-shot grok's
    /// `EndTurn`. Same product rule: the worker's declaration is the verdict, and
    /// an unfamiliar stopReason is never optimistically read as success.
    public static func grokAcp(stopReason: String)
        -> (state: DispatchRecord.State, diagnostics: [String]) {
        switch stopReason {
        case "end_turn":
            return (.succeeded, [])
        default:
            return (.failed, ["cli.grok-acp.unexpected-stop", "stopReason=\(stopReason)"])
        }
    }

    /// Codex MCP (interactive `codex mcp-server`) turn outcome.
    ///
    /// Codex's interactive turn declares no `stopReason` the way grok's ACP does; it
    /// returns an MCP `CallToolResult` whose `structuredContent.content` carries the
    /// assistant text (proven live — the body is non-empty on a clean turn, unlike a
    /// turn a host hook derailed). So the declaration cowork weighs is simply whether
    /// a result with content came back:
    /// - a JSON-RPC error member is the worker declaring the turn failed;
    /// - a result with no `structuredContent` is not an answer — the process replied,
    ///   but said nothing, which is the codex-mcp equivalent of a missing declaration;
    /// - a result carrying content is a success, and the content is the reply.
    ///
    /// `hasContent` is whether the result carried a usable `structuredContent`;
    /// `rpcError`, when present, is the JSON-RPC error described for the caller.
    public static func codexMcp(hasContent: Bool, rpcError: String?)
        -> (state: DispatchRecord.State, diagnostics: [String]) {
        if let rpcError {
            return (.failed, ["cli.codex-mcp.rpc-error", rpcError])
        }
        if !hasContent {
            return (.failed, ["cli.codex-mcp.no-result"])
        }
        return (.succeeded, [])
    }
}

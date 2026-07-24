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

    // MARK: CLI agents
    //
    // Each rule below is named for the DECLARATION SHAPE it weighs, never for the
    // agent that happens to emit it, and its diagnostics are fixed strings with no
    // name interpolated into them. Which CLI produced an outcome already lives in
    // the dispatch record's backend id; repeating it inside the diagnostic would
    // make two agents that spoke the identical protocol and failed the identical
    // way look like two different failures, and nothing could be compared across
    // them. A diagnostic names the protocol and the mechanism; the record names
    // the backend.

    /// Exit status only: the weakest declaration there is.
    ///
    /// Honest ONLY for a CLI that emits no machine declaration cowork reads — hence
    /// a row may select it only alongside raw output, and it carries a
    /// verdict-unverified marker in capabilities until a performed journey proves
    /// the failure mode really does surface as a nonzero exit (ADR 000).
    public static func exitCode(_ exitCode: Int32)
        -> (state: DispatchRecord.State, diagnostics: [String]) {
        if exitCode == 0 { return (.succeeded, []) }
        return (.failed, ["cli.exit", "exit=\(exitCode)"])
    }

    /// A result object carrying a subtype and an `is_error` flag (the stream-json
    /// shape), weighed against the exit code.
    ///
    /// The two can disagree, and the disagreement is recorded rather than resolved
    /// in the transport's favour. Proven in the wild: an agent declared
    /// `subtype: "success"` AND `is_error: true` while exiting 1, when it was not
    /// logged in.
//: @use-case:truth.cli.declared_error_with_exit_zero_is_failed#declared_error_with_exit
    public static func declaredResult(declaredSubtype: String?, isError: Bool, exitCode: Int32)
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
//: @use-case:end truth.cli.declared_error_with_exit_zero_is_failed#declared_error_with_exit

    /// A JSON field declaring why generation stopped, weighed against the exit code.
    ///
    /// `EndTurn` is a clean finish; `MaxTokens` is a truncation, and a truncated
    /// answer is a failure however clean the exit — the same rule an endpoint's
    /// `finish_reason: length` gets. An unfamiliar declaration is never optimistically
    /// read as success.
    public static func stopReason(_ reason: String?, exitCode: Int32)
        -> (state: DispatchRecord.State, diagnostics: [String]) {
        guard let reason else {
            // No readable declaration. The process ended; that is not the same as
            // the work being done.
            return (.failed, ["cli.stop-reason.absent", "exit=\(exitCode)"])
        }
        switch reason {
        case "EndTurn":
            if exitCode != 0 {
                // The turn finished but the process disagreed. The declaration wins,
                // the disagreement is recorded rather than quietly resolved — and it
                // is the identical product fact `declaredResult` records, so it is
                // named identically rather than given a shape-specific twin.
                return (.succeeded, ["cli.nonzero-exit-despite-declared-success", "exit=\(exitCode)"])
            }
            return (.succeeded, [])
        case "MaxTokens":
            // A truncated answer, however clean the exit. Handing it back as success
            // is the exact lie this product exists to prevent.
            return (.failed, ["cli.stop-reason.truncated", "stopReason=MaxTokens"])
        default:
            return (.failed, ["cli.stop-reason.unexpected", "stopReason=\(reason)"])
        }
    }

    /// An ACP (Agent Client Protocol) turn's declared stop reason.
    ///
    /// The live ACP wire declares snake_case `end_turn`; there is no exit code to
    /// weigh it against mid-session, so the declaration is the whole verdict. An
    /// unfamiliar stopReason is never optimistically read as success.
    public static func acp(stopReason: String)
        -> (state: DispatchRecord.State, diagnostics: [String]) {
        switch stopReason {
        case "end_turn":
            return (.succeeded, [])
        default:
            return (.failed, ["cli.acp.unexpected-stop", "stopReason=\(stopReason)"])
        }
    }

    /// An MCP `tools/call` turn's outcome.
    ///
    /// An MCP turn declares no stop reason the way ACP does; it returns a
    /// `CallToolResult` whose structured member carries the assistant text (proven
    /// live — the body is non-empty on a clean turn, unlike a turn a host hook
    /// derailed). So the declaration cowork weighs is simply whether a result with
    /// content came back:
    /// - a JSON-RPC error member is the worker declaring the turn failed;
    /// - a result with no content is not an answer — the process replied, but said
    ///   nothing, which is this protocol's equivalent of a missing declaration;
    /// - a result carrying content is a success, and the content is the reply.
    public static func mcp(hasContent: Bool, rpcError: String?)
        -> (state: DispatchRecord.State, diagnostics: [String]) {
        if let rpcError {
            return (.failed, ["cli.mcp.rpc-error", rpcError])
        }
        if !hasContent {
            return (.failed, ["cli.mcp.no-result"])
        }
        return (.succeeded, [])
    }
}

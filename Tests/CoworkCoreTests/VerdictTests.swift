import Foundation
import Testing

@testable import CoworkCore

/// The rule that is the product (ADR 000): the worker's declared outcome is the
/// verdict, and the transport is a diagnostic.
///
/// These were only ever proven by performed journeys, which is not enough — a
/// journey can show that one real failure was reported honestly, but it cannot
/// stage every declaration a worker might make. The wrong ones are exactly the
/// ones that never happen while you are watching.
@Suite("The verdict")
struct VerdictTests {
    // MARK: endpoints — HTTP 200 is not an answer

    @Test("a worker declaring stop succeeded")
    func stopSucceeds() {
        #expect(Verdict.endpoint(finishReason: "stop") == .terminal(.succeeded, diagnostics: []))
    }

    /// Proven live against a real provider: HTTP 200, genuine content, and the
    /// worker declared it was cut off. A seam that reads the transport calls this
    /// success and hands back a truncated essay.
    @Test("a worker declaring length FAILED, even though the transport said 200")
    func truncationIsFailure() {
        guard case let .terminal(state, diagnostics) = Verdict.endpoint(finishReason: "length") else {
            Issue.record("truncation must be terminal"); return
        }
        #expect(state == .failed)
        #expect(diagnostics.contains("endpoint.truncated"))
        #expect(diagnostics.contains("finish_reason=length"))
    }

    /// The state that a naive loop gets wrong in the other direction: a model
    /// asking for a tool has not finished, and calling it terminal would end a
    /// dispatch mid-thought.
    @Test("tool_calls is a continuation, not a terminal state")
    func toolCallsContinues() {
        #expect(Verdict.endpoint(finishReason: "tool_calls") == .toolCalls)
    }

    /// A provider inventing a reason we have never seen may mean anything.
    /// Guessing "probably fine" is how a wrong answer becomes a reported one.
    @Test("an unknown declaration is a failure that names itself, never a hopeful success")
    func unknownIsFailure() {
        for reason in ["content_filter", "cancelled", "<absent>", "", "SUCCESS"] {
            guard case let .terminal(state, diagnostics) = Verdict.endpoint(finishReason: reason) else {
                Issue.record("\(reason) must be terminal"); return
            }
            #expect(state == .failed, "'\(reason)' must not be read as success")
            #expect(diagnostics.contains("finish_reason=\(reason)"),
                    "the caller must be told what the provider actually said")
        }
    }

    // MARK: CLI agents — an exit code is not an outcome

    @Test("an agent declaring success and exiting 0 succeeded")
    func cliCleanSuccess() {
        let v = Verdict.declaredResult(declaredSubtype: "success", isError: false, exitCode: 0)
        #expect(v.state == .succeeded)
        #expect(v.diagnostics.isEmpty)
    }

    /// Found in the wild, not invented: Claude Code declares subtype "success" AND
    /// is_error true when it is not logged in. A reader of subtype alone reports a
    /// success that never happened.
    @Test("an agent declaring success AND is_error has failed — the contradiction is recorded")
    func cliSelfContradiction() {
        let v = Verdict.declaredResult(declaredSubtype: "success", isError: true, exitCode: 1)
        #expect(v.state == .failed)
        #expect(v.diagnostics.contains("cli.declared-error"))
        #expect(v.diagnostics.contains("subtype=success"),
                "the contradiction is recorded, not resolved silently")
    }

    @Test("an agent that declared nothing has failed, whatever its exit code says")
    func cliSilenceIsFailure() {
        for exit in [Int32(0), 1, 137] {
            let v = Verdict.declaredResult(declaredSubtype: nil, isError: false, exitCode: exit)
            #expect(v.state == .failed,
                    "an exit code says the process ended, not that the work was done")
            #expect(v.diagnostics.contains("cli.no-declared-result"))
        }
    }

    /// The disagreement is the interesting case: the worker knows what it did, so
    /// its declaration wins — but the caller gets told the process disagreed rather
    /// than having it quietly resolved.
    @Test("a nonzero exit despite declared success is succeeded, WITH the disagreement recorded")
    func cliDisagreementIsRecorded() {
        let v = Verdict.declaredResult(declaredSubtype: "success", isError: false, exitCode: 1)
        #expect(v.state == .succeeded, "the worker's declaration outranks the transport")
        #expect(v.diagnostics.contains("cli.nonzero-exit-despite-declared-success"),
                "and the caller is told, rather than the disagreement being swallowed")
        #expect(v.diagnostics.contains("exit=1"))
    }

    @Test("any declared subtype other than success is a failure")
    func cliOtherSubtypesFail() {
        for subtype in ["error_max_turns", "error_during_execution", "cancelled"] {
            let v = Verdict.declaredResult(declaredSubtype: subtype, isError: false, exitCode: 0)
            #expect(v.state == .failed, "'\(subtype)' exiting 0 must not be read as success")
            #expect(v.diagnostics.contains("subtype=\(subtype)"))
        }
    }

    // MARK: stop_reason — a field declaring why generation stopped

    /// `EndTurn` is the model finishing its turn cleanly — this shape's equivalent
    /// of a declared `subtype: success` or an endpoint's `finish_reason: stop`.
    @Test("a declared EndTurn is a success")
    func stopReasonEndTurnSucceeds() {
        let v = Verdict.stopReason("EndTurn", exitCode: 0)
        #expect(v.state == .succeeded)
        #expect(v.diagnostics.isEmpty)
    }

    /// Hitting the token ceiling is a truncated answer, and a truncated answer is
    /// a failure however clean the exit — the same rule endpoint `length` gets.
    @Test("a declared MaxTokens is a truncation failure, not a success")
    func stopReasonMaxTokensIsFailure() {
        let v = Verdict.stopReason("MaxTokens", exitCode: 0)
        #expect(v.state == .failed)
        #expect(v.diagnostics.contains("cli.stop-reason.truncated"))
    }

    /// An unknown stopReason is never optimistically read as success — a reason we
    /// have not seen may mean anything, and guessing is how a wrong answer ships.
    @Test("an unknown stop reason is a named failure, never a hopeful success")
    func stopReasonUnknownIsFailure() {
        let v = Verdict.stopReason("SomethingNew", exitCode: 0)
        #expect(v.state == .failed)
        #expect(v.diagnostics.contains("cli.stop-reason.unexpected"))
        #expect(v.diagnostics.contains { $0.contains("SomethingNew") })
    }

    /// The declaration is the verdict, but a process that declared nothing at all
    /// is a failure that names the absence and records the exit beside it.
    @Test("no readable stop reason is a named failure that records the exit code")
    func stopReasonAbsent() {
        let v = Verdict.stopReason(nil, exitCode: 1)
        #expect(v.state == .failed)
        #expect(v.diagnostics.contains("cli.stop-reason.absent"))
        #expect(v.diagnostics.contains("exit=1"))
    }

    /// EndTurn declared but the process exited nonzero: the declaration wins (the
    /// worker knows it finished its turn), but the disagreement is recorded, not
    /// silently resolved. It is the IDENTICAL product fact `declaredResult` records,
    /// so it must carry the identical diagnostic — otherwise two agents that failed
    /// the same way cannot be compared.
    @Test("EndTurn with a nonzero exit succeeds, recording the same disagreement declared_result does")
    func stopReasonEndTurnNonzeroExit() {
        let v = Verdict.stopReason("EndTurn", exitCode: 1)
        #expect(v.state == .succeeded)
        #expect(v.diagnostics == ["cli.nonzero-exit-despite-declared-success", "exit=1"])
    }

    // MARK: exit_code — the weakest declaration there is

    /// A CLI that declares no subtype and no stop reason leaves the exit as the only
    /// signal there is. The rule says so plainly rather than inventing a richer one.
    @Test("exiting 0 with nothing declared is a success")
    func exitCodeCleanExit() {
        let v = Verdict.exitCode(0)
        #expect(v.state == .succeeded)
        #expect(v.diagnostics.isEmpty)
    }

    /// The diagnostic names the mechanism only. Which CLI it was lives in the
    /// dispatch record's backend id; repeating it here would make two agents that
    /// failed identically look like two different failures.
    @Test("exiting nonzero is a failure named by mechanism alone, with no backend name in it")
    func exitCodeNonzeroExit() {
        let v = Verdict.exitCode(7)
        #expect(v.state == .failed)
        #expect(v.diagnostics == ["cli.exit", "exit=7"])
    }

    // MARK: acp — an interactive turn's declared stop reason

    /// The ACP wire declares snake_case `end_turn`. Same product rule: the worker's
    /// declaration is the verdict.
    @Test("an ACP end_turn is a success")
    func acpEndTurnSucceeds() {
        let v = Verdict.acp(stopReason: "end_turn")
        #expect(v.state == .succeeded)
        #expect(v.diagnostics.isEmpty)
    }

    /// An unknown stopReason is never optimistically read as success — mirror the
    /// endpoint and one-shot rules: name what the worker actually said.
    ///
    /// `EndTurn` is deliberately in this list: the one-shot `stop_reason` token set
    /// and the ACP token set stay literally disjoint, so a CamelCase declaration on
    /// an ACP wire is an unfamiliar declaration and is reported as one.
    @Test("an unknown ACP stop reason is a named failure, never a hopeful success")
    func acpUnknownIsFailure() {
        for reason in ["max_tokens", "cancelled", "tool_use", "", "EndTurn", "SUCCESS"] {
            let v = Verdict.acp(stopReason: reason)
            #expect(v.state == .failed, "'\(reason)' must not be read as success")
            #expect(v.diagnostics.contains("stopReason=\(reason)"),
                    "the caller must be told what the worker actually said")
            #expect(v.diagnostics.contains("cli.acp.unexpected-stop"),
                    "the failure must name the protocol and the mechanism, and nothing else")
        }
    }

    // MARK: mcp — an interactive turn declares by returning content

    /// An MCP turn that returns a result with content succeeded — the content is the
    /// reply. Proven live: on a clean turn the structured body is non-empty.
    @Test("an MCP turn with content is a success")
    func mcpContentSucceeds() {
        let v = Verdict.mcp(hasContent: true, rpcError: nil)
        #expect(v.state == .succeeded)
        #expect(v.diagnostics.isEmpty)
    }

    /// A JSON-RPC error is the worker declaring the turn failed — recorded, not swallowed.
    @Test("an MCP JSON-RPC error is a named failure")
    func mcpRpcErrorFails() {
        let v = Verdict.mcp(hasContent: false, rpcError: "code=-32000 message=boom")
        #expect(v.state == .failed)
        #expect(v.diagnostics.contains("cli.mcp.rpc-error"))
        #expect(v.diagnostics.contains("code=-32000 message=boom"))
    }

    /// A result with no content is the process replying without an answer — not a
    /// success, the same way an agent that declared nothing has failed.
    @Test("an MCP turn with no content is a named failure, never a hopeful success")
    func mcpNoContentFails() {
        let v = Verdict.mcp(hasContent: false, rpcError: nil)
        #expect(v.state == .failed)
        #expect(v.diagnostics.contains("cli.mcp.no-result"))
    }

    /// An error outranks content: if the worker declared an error, that is the verdict
    /// even if a body slipped through — the declaration wins (ADR 000).
    @Test("an MCP error wins even if content is present")
    func mcpErrorOutranksContent() {
        let v = Verdict.mcp(hasContent: true, rpcError: "code=-32001 message=cancelled")
        #expect(v.state == .failed)
        #expect(v.diagnostics.contains("cli.mcp.rpc-error"))
    }
}

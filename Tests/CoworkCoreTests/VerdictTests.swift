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
        let v = Verdict.cli(declaredSubtype: "success", isError: false, exitCode: 0)
        #expect(v.state == .succeeded)
        #expect(v.diagnostics.isEmpty)
    }

    /// Found in the wild, not invented: Claude Code declares subtype "success" AND
    /// is_error true when it is not logged in. A reader of subtype alone reports a
    /// success that never happened.
    @Test("an agent declaring success AND is_error has failed — the contradiction is recorded")
    func cliSelfContradiction() {
        let v = Verdict.cli(declaredSubtype: "success", isError: true, exitCode: 1)
        #expect(v.state == .failed)
        #expect(v.diagnostics.contains("cli.declared-error"))
        #expect(v.diagnostics.contains("subtype=success"),
                "the contradiction is recorded, not resolved silently")
    }

    @Test("an agent that declared nothing has failed, whatever its exit code says")
    func cliSilenceIsFailure() {
        for exit in [Int32(0), 1, 137] {
            let v = Verdict.cli(declaredSubtype: nil, isError: false, exitCode: exit)
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
        let v = Verdict.cli(declaredSubtype: "success", isError: false, exitCode: 1)
        #expect(v.state == .succeeded, "the worker's declaration outranks the transport")
        #expect(v.diagnostics.contains("cli.nonzero-exit-despite-declared-success"),
                "and the caller is told, rather than the disagreement being swallowed")
        #expect(v.diagnostics.contains("exit=1"))
    }

    @Test("any declared subtype other than success is a failure")
    func cliOtherSubtypesFail() {
        for subtype in ["error_max_turns", "error_during_execution", "cancelled"] {
            let v = Verdict.cli(declaredSubtype: subtype, isError: false, exitCode: 0)
            #expect(v.state == .failed, "'\(subtype)' exiting 0 must not be read as success")
            #expect(v.diagnostics.contains("subtype=\(subtype)"))
        }
    }

    // MARK: grok — a third CLI agent with its own declaration

    /// Grok's one-shot JSON declares a `stopReason`. `EndTurn` is the model
    /// finishing its turn cleanly — the grok equivalent of claude's
    /// `subtype: success` or an endpoint's `finish_reason: stop`.
    @Test("grok EndTurn is a success")
    func grokEndTurnSucceeds() {
        let v = Verdict.grok(stopReason: "EndTurn", exitCode: 0)
        #expect(v.state == .succeeded)
        #expect(v.diagnostics.isEmpty)
    }

    /// Hitting the token ceiling is a truncated answer, and a truncated answer is
    /// a failure however clean the exit — the same rule endpoint `length` gets.
    @Test("grok MaxTokens is a truncation failure, not a success")
    func grokMaxTokensIsFailure() {
        let v = Verdict.grok(stopReason: "MaxTokens", exitCode: 0)
        #expect(v.state == .failed)
        #expect(v.diagnostics.contains("cli.grok.truncated"))
    }

    /// An unknown stopReason is never optimistically read as success — a reason we
    /// have not seen may mean anything, and guessing is how a wrong answer ships.
    @Test("an unknown grok stopReason is a named failure, never a hopeful success")
    func grokUnknownIsFailure() {
        let v = Verdict.grok(stopReason: "SomethingNew", exitCode: 0)
        #expect(v.state == .failed)
        #expect(v.diagnostics.contains { $0.contains("SomethingNew") })
    }

    /// The declaration is the verdict, but a process that could not even run —
    /// a nonzero exit with no clean EndTurn — is a failure the exit code names.
    @Test("grok with no readable declaration falls back to the exit code")
    func grokNoDeclaration() {
        let v = Verdict.grok(stopReason: nil, exitCode: 1)
        #expect(v.state == .failed)
        #expect(v.diagnostics.contains { $0.contains("no-declared") })
    }

    /// EndTurn declared but the process exited nonzero: the declaration wins (the
    /// worker knows it finished its turn), but the disagreement is recorded, not
    /// silently resolved — exactly as for a CLI agent.
    @Test("grok EndTurn with a nonzero exit succeeds but records the disagreement")
    func grokEndTurnNonzeroExit() {
        let v = Verdict.grok(stopReason: "EndTurn", exitCode: 1)
        #expect(v.state == .succeeded)
        #expect(v.diagnostics.contains { $0.contains("nonzero-exit") })
    }

    // MARK: codex-exec — a one-shot with no richer declaration than its exit

    /// `codex exec` prints its work and exits; unlike claude and grok it declares no
    /// subtype or stopReason in this mode, so the exit is the only signal there is.
    @Test("codex exec exiting 0 is a success")
    func codexCleanExit() {
        let v = Verdict.codex(exitCode: 0)
        #expect(v.state == .succeeded)
        #expect(v.diagnostics.isEmpty)
    }

    @Test("codex exec exiting nonzero is a named failure that records the code")
    func codexNonzeroExit() {
        let v = Verdict.codex(exitCode: 7)
        #expect(v.state == .failed)
        #expect(v.diagnostics.contains("cli.codex.exit"))
        #expect(v.diagnostics.contains("exit=7"))
    }

    // MARK: grok ACP — interactive stopReason (snake_case wire)

    /// ACP's clean finish is `end_turn` (snake_case), not one-shot grok's `EndTurn`.
    /// Same product rule: the worker's declaration is the verdict.
    @Test("grok ACP end_turn is a success")
    func grokAcpEndTurnSucceeds() {
        let v = Verdict.grokAcp(stopReason: "end_turn")
        #expect(v.state == .succeeded)
        #expect(v.diagnostics.isEmpty)
    }

    /// An unknown stopReason is never optimistically read as success — mirror
    /// endpoint / one-shot grok: name what the worker said.
    @Test("an unknown grok ACP stopReason is a named failure, never a hopeful success")
    func grokAcpUnknownIsFailure() {
        for reason in ["max_tokens", "cancelled", "tool_use", "", "EndTurn", "SUCCESS"] {
            let v = Verdict.grokAcp(stopReason: reason)
            #expect(v.state == .failed, "'\(reason)' must not be read as success")
            #expect(v.diagnostics.contains("stopReason=\(reason)"),
                    "the caller must be told what the worker actually said")
            #expect(v.diagnostics.contains { $0.contains("unexpected") || $0.contains("grok-acp") },
                    "the failure must name itself as an ACP unexpected-stop")
        }
    }

    // MARK: codex MCP — interactive turn declares by returning content

    /// A codex MCP turn that returns a result with content succeeded — the content is
    /// the reply. Proven live: on a clean turn `structuredContent.content` is non-empty.
    @Test("codex MCP with content is a success")
    func codexMcpContentSucceeds() {
        let v = Verdict.codexMcp(hasContent: true, rpcError: nil)
        #expect(v.state == .succeeded)
        #expect(v.diagnostics.isEmpty)
    }

    /// A JSON-RPC error is the worker declaring the turn failed — recorded, not swallowed.
    @Test("codex MCP with a JSON-RPC error is a named failure")
    func codexMcpRpcErrorFails() {
        let v = Verdict.codexMcp(hasContent: false, rpcError: "code=-32000 message=boom")
        #expect(v.state == .failed)
        #expect(v.diagnostics.contains("cli.codex-mcp.rpc-error"))
        #expect(v.diagnostics.contains("code=-32000 message=boom"))
    }

    /// A result with no structuredContent is the process replying without an answer —
    /// not a success, the same way a CLI agent that declared nothing has failed.
    @Test("codex MCP with no content is a named failure, never a hopeful success")
    func codexMcpNoContentFails() {
        let v = Verdict.codexMcp(hasContent: false, rpcError: nil)
        #expect(v.state == .failed)
        #expect(v.diagnostics.contains("cli.codex-mcp.no-result"))
    }

    /// An error outranks content: if the worker declared an error, that is the verdict
    /// even if a body slipped through — the declaration wins (ADR 000).
    @Test("codex MCP error wins even if content is present")
    func codexMcpErrorOutranksContent() {
        let v = Verdict.codexMcp(hasContent: true, rpcError: "code=-32001 message=cancelled")
        #expect(v.state == .failed)
        #expect(v.diagnostics.contains("cli.codex-mcp.rpc-error"))
    }
}

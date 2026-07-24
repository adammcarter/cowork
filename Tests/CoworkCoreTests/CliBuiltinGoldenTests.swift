import Foundation
import Testing

@testable import CoworkCore

/// The regression gate: `ConfiguredDriver` interpreting a `BuiltinDescriptors`
/// constant must be byte-identical to the hand-written oracle driver it replaces —
/// argv, raw stdin bytes, and env on the invocation side; state/text/diagnostics/
/// transcript/continuation on the parse side — across the workspace×resume matrix
/// and the declaration fixtures (including the branches the spike got wrong).
///
/// The oracle IS the expected value, so this proves equivalence without re-specifying
/// the wire; when the oracle drivers are deleted these fixtures become the frozen pins.
@Suite("Built-in descriptor golden equivalence")
struct CliBuiltinGoldenTests {
    private let claudeExe = URL(fileURLWithPath: "/usr/local/bin/claude")
    private let grokExe = URL(fileURLWithPath: "/opt/grok/bin/grok")
    private let codexExe = URL(fileURLWithPath: "/usr/bin/codex")

    private var matrix: [(Workspace?, String?)] {
        let ws = Workspace(root: URL(fileURLWithPath: "/tmp/ws"), writable: true)
        return [(nil, nil), (ws, nil), (nil, "R-123"), (ws, "R-123")]
    }

    /// argv and env are byte-identical; stdin is compared SEMANTICALLY. A JSON envelope
    /// (claude) has no stable key order — `JSONSerialization` orders a dict arbitrarily,
    /// so the production driver itself varies run-to-run — and claude accepts any order.
    /// Byte-identity of a JSON envelope is not a real invariant; equal-JSON is.
    private func invocationsEquivalent(_ a: Invocation, _ b: Invocation) -> Bool {
        guard a.arguments == b.arguments, a.extraEnvironment == b.extraEnvironment else { return false }
        switch (a.stdin, b.stdin) {
        case (nil, nil): return true
        case let (x?, y?):
            if x == y { return true }
            let jx = try? JSONSerialization.jsonObject(with: x)
            let jy = try? JSONSerialization.jsonObject(with: y)
            return jx != nil && NSDictionary(dictionary: (jx as? [String: Any]) ?? [:])
                .isEqual(to: (jy as? [String: Any]) ?? [:])
        default: return false
        }
    }

    // Test 6 — invocation equivalence (argv/env byte-identical, JSON stdin semantically equal)
    @Test("claude invocation matches the oracle across workspace×resume")
    func claudeInvocationMatchesOracle() {
        let oracle = ClaudeOneShotDriver(executable: claudeExe)
        let cfg = ConfiguredDriver(name: "claude", executable: claudeExe, descriptor: BuiltinDescriptors.claude)
        for (ws, resume) in matrix {
            #expect(invocationsEquivalent(cfg.invocation(task: "do X", workspace: ws, resume: resume),
                                          oracle.invocation(task: "do X", workspace: ws, resume: resume)),
                    "claude ws=\(String(describing: ws?.root.path)) resume=\(String(describing: resume))")
        }
        #expect(cfg.deadlineDiagnostic == oracle.deadlineDiagnostic)
    }

    @Test("grok invocation is byte-identical to the oracle (argv, PATH env)")
    func grokInvocationMatchesOracle() {
        let oracle = GrokOneShotDriver(executable: grokExe)
        let cfg = ConfiguredDriver(name: "grok", executable: grokExe, descriptor: BuiltinDescriptors.grok)
        for (ws, resume) in matrix {
            #expect(cfg.invocation(task: "sum", workspace: ws, resume: resume)
                    == oracle.invocation(task: "sum", workspace: ws, resume: resume),
                    "grok ws=\(String(describing: ws?.root.path)) resume=\(String(describing: resume))")
        }
        #expect(cfg.deadlineDiagnostic == oracle.deadlineDiagnostic)
    }

    @Test("codex invocation is byte-identical to the oracle (raw stdin, dropped resume)")
    func codexInvocationMatchesOracle() {
        let oracle = CodexOneShotDriver(executable: codexExe)
        let cfg = ConfiguredDriver(name: "codex", executable: codexExe, descriptor: BuiltinDescriptors.codex)
        for (ws, resume) in matrix {
            #expect(cfg.invocation(task: "go", workspace: ws, resume: resume)
                    == oracle.invocation(task: "go", workspace: ws, resume: resume),
                    "codex ws=\(String(describing: ws?.root.path)) resume=\(String(describing: resume))")
        }
        #expect(cfg.deadlineDiagnostic == oracle.deadlineDiagnostic)
    }

    // Test 8 — parse equivalence incl. transcript, diagnostics, continuation
    @Test("claude parse matches the oracle across declaration fixtures")
    func claudeParseMatchesOracle() {
        let oracle = ClaudeOneShotDriver(executable: claudeExe)
        let cfg = ConfiguredDriver(name: "claude", executable: claudeExe, descriptor: BuiltinDescriptors.claude)
        let fixtures: [(String, Int32)] = [
            // success + session id
            ("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]},\"session_id\":\"S1\"}\n{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"DONE\",\"session_id\":\"S1\"}", 0),
            // declared error
            ("{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true,\"result\":\"partial\"}", 0),
            // no declaration at all
            ("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}", 0),
            // declared success but nonzero exit (the disagreement branch)
            ("{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"OK\",\"session_id\":\"S2\"}", 1 << 8),
        ]
        for (body, exit) in fixtures {
            #expect(cfg.parse(output: Data(body.utf8), exitStatus: exit)
                    == oracle.parse(output: Data(body.utf8), exitStatus: exit), "claude fixture exit=\(exit)")
        }
    }

    @Test("grok parse matches the oracle incl. preamble scan, truncation, unparseable")
    func grokParseMatchesOracle() {
        let oracle = GrokOneShotDriver(executable: grokExe)
        let cfg = ConfiguredDriver(name: "grok", executable: grokExe, descriptor: BuiltinDescriptors.grok)
        let fixtures: [(String, Int32)] = [
            ("{\"text\":\"ANS\",\"stopReason\":\"EndTurn\",\"sessionId\":\"G1\"}", 0),
            ("{\"text\":\"ANS\",\"stopReason\":\"EndTurn\",\"thought\":\"hmm\",\"sessionId\":\"G1\"}", 0),
            ("{\"text\":\"partial\",\"stopReason\":\"MaxTokens\"}", 0),
            ("chatter before {\"text\":\"ok\",\"stopReason\":\"EndTurn\"}", 0),  // two-stage scan
            ("not json at all", 1),                                             // unparseable
            ("{\"text\":\"ANS\",\"stopReason\":\"EndTurn\"}", 5 << 8),          // nonzero exit + EndTurn
        ]
        for (body, exit) in fixtures {
            #expect(cfg.parse(output: Data(body.utf8), exitStatus: exit)
                    == oracle.parse(output: Data(body.utf8), exitStatus: exit), "grok fixture exit=\(exit): \(body.prefix(30))")
        }
    }

    @Test("codex parse matches the oracle (raw text, exit-code verdict, cli.codex.exit)")
    func codexParseMatchesOracle() {
        let oracle = CodexOneShotDriver(executable: codexExe)
        let cfg = ConfiguredDriver(name: "codex", executable: codexExe, descriptor: BuiltinDescriptors.codex)
        let fixtures: [(String, Int32)] = [("did the work\n", 0), ("boom", 3 << 8), ("partial output", 1 << 8)]
        for (body, exit) in fixtures {
            #expect(cfg.parse(output: Data(body.utf8), exitStatus: exit)
                    == oracle.parse(output: Data(body.utf8), exitStatus: exit), "codex fixture exit=\(exit)")
        }
    }

    // Test 7/9 — verdict strategy delegates verbatim + exitOnly label
    @Test("exit-code strategy names the cli (cli.<name>.exit) and keeps codex bytes")
    func exitOnlyLabelling() {
        #expect(Verdict.exitOnly(cliName: "codex", exitCode: 1).diagnostics == ["cli.codex.exit", "exit=1"])
        #expect(Verdict.codex(exitCode: 1).diagnostics == ["cli.codex.exit", "exit=1"])
        // a generic CLI gets its own label
        let opencode = ConfiguredDriver(name: "opencode", executable: URL(fileURLWithPath: "/o/opencode"),
                                        descriptor: BuiltinDescriptors.codex)
        let out = opencode.parse(output: Data("x".utf8), exitStatus: 1 << 8)
        #expect(out.diagnostics == ["cli.opencode.exit", "exit=1"])
        #expect(out.state == .failed)
    }
}

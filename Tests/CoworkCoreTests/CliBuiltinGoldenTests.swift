import Foundation
import Testing

@testable import CoworkCore

/// The regression gate for the built-in descriptors, across the workspace×resume
/// matrix and the verdict-label surface.
///
/// History matters here: these expectations were first written as a live comparison
/// against the hand-written `ClaudeOneShotDriver` / `GrokOneShotDriver` /
/// `CodexOneShotDriver` and passed against them, which is what licensed deleting
/// those drivers. What remains are the frozen values that comparison proved — the
/// per-dialect wire itself is pinned in the three "built-in wire" suites.
@Suite("Built-in descriptor golden pins")
struct CliBuiltinGoldenTests {
    private let claudeExe = URL(fileURLWithPath: "/usr/local/bin/claude")
    private let grokExe = URL(fileURLWithPath: "/opt/grok/bin/grok")
    private let codexExe = URL(fileURLWithPath: "/usr/bin/codex")
    private let ws = Workspace(root: URL(fileURLWithPath: "/tmp/ws"), writable: true)

    private func driver(_ name: String, _ exe: URL, _ d: CliDescriptor) -> ConfiguredDriver {
        ConfiguredDriver(name: name, executable: exe, descriptor: d)
    }

    @Test("claude: workspace is ignored (no --cwd flag), resume appends --resume")
    func claudeMatrix() {
        let d = driver("claude", claudeExe, BuiltinDescriptors.claude)
        let base = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--verbose", "--permission-mode", "dontAsk",
                    "--allowed-tools", "Read", "Write", "--strict-mcp-config"]
        #expect(d.invocation(task: "t", workspace: nil, resume: nil).arguments == base)
        #expect(d.invocation(task: "t", workspace: ws, resume: nil).arguments == base,
                "claude has no workspace flag: process cwd is the only root")
        #expect(d.invocation(task: "t", workspace: ws, resume: "R").arguments == base + ["--resume", "R"])
        #expect(d.deadlineDiagnostic == "cli.deadline", "claude's diagnostic is the asymmetric one")
    }

    @Test("grok: --cwd then -r, in that order, and the bin dir leads PATH")
    func grokMatrix() {
        let d = driver("grok", grokExe, BuiltinDescriptors.grok)
        let base = ["-p", "t", "--output-format", "json", "--no-auto-update", "--always-approve"]
        #expect(d.invocation(task: "t", workspace: nil, resume: nil).arguments == base)
        #expect(d.invocation(task: "t", workspace: ws, resume: "R").arguments
                == base + ["--cwd", "/tmp/ws", "-r", "R"])
        #expect(d.invocation(task: "t", workspace: nil, resume: nil).extraEnvironment
                == ["PATH=/opt/grok/bin:/usr/bin:/bin:/usr/sbin:/sbin"])
        #expect(d.deadlineDiagnostic == "cli.grok.deadline")
    }

    @Test("codex: -C carries the workspace and a resume handle is dropped, never faked")
    func codexMatrix() {
        let d = driver("codex", codexExe, BuiltinDescriptors.codex)
        let base = ["exec", "--ignore-user-config",
                    "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check"]
        #expect(d.invocation(task: "t", workspace: nil, resume: nil).arguments == base)
        #expect(d.invocation(task: "t", workspace: ws, resume: "R").arguments == base + ["-C", "/tmp/ws"],
                "codex exec has no resume: the handle is dropped rather than invented")
        #expect(d.invocation(task: "t", workspace: nil, resume: nil).stdin == Data("t".utf8))
        #expect(d.deadlineDiagnostic == "cli.codex.deadline")
    }

    /// The label carries the MECHANISM, never the backend. Which CLI produced an
    /// outcome already lives in the dispatch record's backend id, so two CLIs that
    /// failed the identical way must be indistinguishable here — otherwise nothing
    /// about them can ever be compared.
    @Test("the exit-code strategy names the mechanism only — two different clis emit identical bytes")
    func exitCodeLabelIsBackendAgnostic() {
        #expect(Verdict.exitCode(1).diagnostics == ["cli.exit", "exit=1"])

        let one = driver("opencode", URL(fileURLWithPath: "/o/opencode"), BuiltinDescriptors.codex)
        let two = driver("somethingelse", URL(fileURLWithPath: "/s/somethingelse"), BuiltinDescriptors.codex)
        let outOne = one.parse(output: Data("x".utf8), exitStatus: 1 << 8)
        let outTwo = two.parse(output: Data("x".utf8), exitStatus: 1 << 8)
        #expect(outOne.diagnostics == ["cli.exit", "exit=1"])
        #expect(outOne.diagnostics == outTwo.diagnostics,
                "the backend name belongs to the record, never to the diagnostic")
        #expect(outOne.state == .failed)
    }

    /// The branches the shape spike got wrong: a declared success with a nonzero exit
    /// is still a success (with the disagreement recorded), and a missing declaration
    /// is a failure however the process exited.
    @Test("verdict strategies delegate verbatim on the honest-disagreement branches")
    func verdictDelegationBranches() {
        let claude = driver("claude", claudeExe, BuiltinDescriptors.claude)
        let ok = "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"OK\"}"
        let declaredSuccessNonzero = claude.parse(output: Data(ok.utf8), exitStatus: 1 << 8)
        #expect(declaredSuccessNonzero.state == .succeeded)
        #expect(declaredSuccessNonzero.diagnostics == ["cli.nonzero-exit-despite-declared-success", "exit=1"])

        let silent = claude.parse(output: Data("{\"type\":\"assistant\"}".utf8), exitStatus: 0)
        #expect(silent.state == .failed)
        #expect(silent.diagnostics == ["cli.no-declared-result", "exit=0"])

        let grok = driver("grok", grokExe, BuiltinDescriptors.grok)
        let endTurnNonzero = grok.parse(
            output: Data("{\"text\":\"a\",\"stopReason\":\"EndTurn\"}".utf8), exitStatus: 5 << 8)
        #expect(endTurnNonzero.state == .succeeded)
        #expect(endTurnNonzero.diagnostics == ["cli.nonzero-exit-despite-declared-success", "exit=5"])

        let noDeclaration = grok.parse(output: Data("{\"text\":\"a\"}".utf8), exitStatus: 0)
        #expect(noDeclaration.state == .failed)
        #expect(noDeclaration.diagnostics == ["cli.stop-reason.absent", "exit=0"])
    }
}

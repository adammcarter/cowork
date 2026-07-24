import Foundation
import Testing

@testable import CoworkCore

/// The raw-stdin one-shot wire: the task written verbatim to stdin, the whole stdout
/// taken as the answer, the exit code as the only signal. The third stdin shape (a
/// JSON envelope; nothing at all; the raw task).
///
/// These assertions are the FROZEN PIN for this shape. They were written against a
/// hand-written driver, proven identical to `ConfiguredDriver`, and now run against
/// the descriptor the shipped example config declares. A descriptor drift breaks
/// these — which is now also a drift in the file users copy.
@Suite("raw-stdin one-shot wire")
struct RawStdinWireTests {
    private let driver = try! ExampleConfig.driver("codex")

    @Test("invocation is `codex exec` — bypassing codex's own trust/sandbox, which cowork already provides — with the raw task on stdin")
    func invocationShape() {
        let inv = driver.invocation(task: "refactor the parser", workspace: nil, resume: nil)
        // cowork contains the worker itself (ADR 003), so codex's own directory-trust
        // and sandbox prompts are redundant and would otherwise refuse to run
        // ("Not inside a trusted directory"). Bypassing them is the codex equivalent
        // of claude's `dontAsk` and grok's `--always-approve`.
        #expect(inv.arguments == ["exec", "--ignore-user-config",
                                  "--dangerously-bypass-approvals-and-sandbox",
                                  "--skip-git-repo-check"])
        #expect(inv.stdin == Data("refactor the parser".utf8), "the raw task is the prompt, on stdin")
        #expect(inv.extraEnvironment.isEmpty)
    }

    @Test("a workspace becomes codex's working directory via -C")
    func invocationWithWorkspace() {
        let ws = Workspace(root: URL(fileURLWithPath: "/tmp/ws"), writable: true)
        let inv = driver.invocation(task: "go", workspace: ws, resume: nil)
        #expect(inv.arguments == ["exec", "--ignore-user-config",
                                  "--dangerously-bypass-approvals-and-sandbox",
                                  "--skip-git-repo-check", "-C", "/tmp/ws"])
    }

    @Test("a clean exit is a success carrying codex's output")
    func parseSuccess() {
        let outcome = driver.parse(output: Data("did the work".utf8), exitStatus: 0)
        #expect(outcome.state == .succeeded)
        #expect(outcome.text == "did the work")
        #expect(outcome.diagnostics.isEmpty)
    }

    @Test("a nonzero exit is a named failure")
    func parseFailure() {
        // exit code 3, encoded as a raw wait status (exited normally, code in high byte).
        let outcome = driver.parse(output: Data("boom".utf8), exitStatus: 3 << 8)
        #expect(outcome.state == .failed)
        #expect(outcome.diagnostics.contains("cli.exit"))
        #expect(outcome.diagnostics.contains("exit=3"))
    }

    @Test("a deadline is a deadline, whichever CLI hit it")
    func deadlineDiagnostic() {
        #expect(driver.deadlineDiagnostic == "cli.deadline")
    }
}

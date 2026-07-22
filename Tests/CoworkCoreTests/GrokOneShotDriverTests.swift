import Foundation
import Testing

@testable import CoworkCore

/// Grok's one-shot wire as a core value: a different protocol from claude's
/// stream-json (task as an argument, one JSON object out, its own PATH), now
/// exercised without spawning grok.
@Suite("GrokOneShotDriver")
struct GrokOneShotDriverTests {
    private let driver = GrokOneShotDriver(executable: URL(fileURLWithPath: "/opt/grok/bin/grok"))

    @Test("invocation passes the task as -p, asks for JSON, writes nothing to stdin, and puts grok's bin dir on PATH")
    func invocationShape() {
        let inv = driver.invocation(task: "summarise", workspace: nil, resume: nil)
        #expect(inv.arguments == ["-p", "summarise", "--output-format", "json",
                                  "--no-auto-update", "--always-approve"])
        #expect(inv.stdin == nil, "grok's task is an argument, not stdin")
        #expect(inv.extraEnvironment == ["PATH=/opt/grok/bin:/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    @Test("a workspace becomes --cwd and a resume id becomes -r, in that order")
    func workspaceAndResume() {
        let ws = Workspace(root: URL(fileURLWithPath: "/tmp/work"), writable: true)
        let inv = driver.invocation(task: "t", workspace: ws, resume: "grok-sess")
        #expect(inv.arguments == ["-p", "t", "--output-format", "json",
                                  "--no-auto-update", "--always-approve",
                                  "--cwd", "/tmp/work", "-r", "grok-sess"])
    }

    @Test("parse reads grok's single JSON object: text as the answer, EndTurn as success, sessionId as continuation")
    func parseSuccess() {
        let body = #"{"text":"the answer","stopReason":"EndTurn","sessionId":"g-1","thought":"pondering"}"#
        let outcome = driver.parse(output: Data(body.utf8), exitStatus: 0)
        #expect(outcome.state == .succeeded)
        #expect(outcome.text == "the answer")
        #expect(outcome.continuation == "g-1")
        #expect(outcome.transcript.contains("thinking: pondering"))
        #expect(outcome.transcript.contains("said: the answer"))
        #expect(outcome.diagnostics.isEmpty)
    }

    @Test("parse treats MaxTokens as a truncation failure, via Verdict.grok")
    func parseTruncated() {
        let body = #"{"text":"cut off","stopReason":"MaxTokens","sessionId":"g-2"}"#
        let outcome = driver.parse(output: Data(body.utf8), exitStatus: 0)
        #expect(outcome.state == .failed)
        #expect(outcome.diagnostics.contains("cli.grok.truncated"))
    }

    @Test("output with no readable JSON object is a named failure")
    func parseUnparseable() {
        let outcome = driver.parse(output: Data("not json at all".utf8), exitStatus: 1)
        #expect(outcome.state == .failed)
        #expect(outcome.diagnostics.contains("cli.grok.unparseable-output"))
    }

    /// Grok may print chatter before its JSON under some flags, so the parse scans
    /// for the object rather than assuming the whole stream is it.
    @Test("parse tolerates a preamble before the JSON object")
    func parseWithPreamble() {
        let body = "warming up...\n{\"text\":\"ok\",\"stopReason\":\"EndTurn\"}"
        let outcome = driver.parse(output: Data(body.utf8), exitStatus: 0)
        #expect(outcome.state == .succeeded)
        #expect(outcome.text == "ok")
    }

    @Test("the deadline diagnostic is grok's own")
    func deadlineDiagnostic() {
        #expect(driver.deadlineDiagnostic == "cli.grok.deadline")
    }
}

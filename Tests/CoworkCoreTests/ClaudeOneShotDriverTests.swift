import Foundation
import Testing

@testable import CoworkCore

/// The claude one-shot wire, now a testable value in the core rather than
/// app-target code no unit test could reach. Invocation shape (stream-json flags,
/// the task as a JSON user message on stdin) and NDJSON parse are exercised
/// directly, without spawning claude.
@Suite("ClaudeOneShotDriver")
struct ClaudeOneShotDriverTests {
    private let driver = ClaudeOneShotDriver(executable: URL(fileURLWithPath: "/bin/claude"))

    private func decodeStdin(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    @Test("invocation uses the stream-json flags and feeds the task as one JSON user message on stdin")
    func invocationShape() {
        let inv = driver.invocation(task: "do the thing", workspace: nil, resume: nil)
        #expect(inv.arguments == ["-p", "--input-format", "stream-json",
                                  "--output-format", "stream-json", "--verbose",
                                  "--permission-mode", "dontAsk",
                                  "--allowed-tools", "Read", "Write",
                                  "--strict-mcp-config"])
        #expect(inv.extraEnvironment.isEmpty)

        // stdin is a user message carrying the task verbatim; assert structure, not
        // byte order, since JSON key order is not guaranteed.
        let obj = decodeStdin(inv.stdin)
        #expect(obj?["type"] as? String == "user")
        let message = obj?["message"] as? [String: Any]
        let content = message?["content"] as? [[String: Any]]
        #expect(content?.first?["text"] as? String == "do the thing")
    }

    @Test("resume appends --resume <id>, and the workspace is ignored (claude does not take --cwd)")
    func resumeAndWorkspace() {
        let ws = Workspace(root: URL(fileURLWithPath: "/tmp/work"), writable: true)
        let inv = driver.invocation(task: "t", workspace: ws, resume: "sess-9")
        #expect(inv.arguments.suffix(2) == ["--resume", "sess-9"])
        #expect(inv.arguments.contains("--cwd") == false)
    }

    @Test("parse folds a stream-json result declaring success into a succeeded outcome, capturing the session id")
    func parseSuccess() {
        let stream = """
        {"type":"assistant","session_id":"s-1","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}
        {"type":"result","session_id":"s-1","subtype":"success","is_error":false,"result":"all done"}
        """
        let outcome = driver.parse(output: Data(stream.utf8), exitStatus: 0)
        #expect(outcome.state == .succeeded)
        #expect(outcome.text == "all done")
        #expect(outcome.continuation == "s-1")
        #expect(outcome.transcript.contains("said: hello"))
        #expect(outcome.diagnostics.isEmpty)
    }

    /// The bug found in the wild: subtype "success" AND is_error true is a failure,
    /// and the driver's parse defers that judgement to Verdict.cli.
    @Test("parse reports a declared error as failed, via Verdict.cli")
    func parseDeclaredError() {
        let stream = #"{"type":"result","subtype":"success","is_error":true,"result":"x"}"#
        let outcome = driver.parse(output: Data(stream.utf8), exitStatus: 1)
        #expect(outcome.state == .failed)
        #expect(outcome.diagnostics.contains("cli.declared-error"))
    }

    @Test("parse of a stream with no result line is a failure that names itself")
    func parseNoResult() {
        let stream = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"chatter"}]}}"#
        let outcome = driver.parse(output: Data(stream.utf8), exitStatus: 0)
        #expect(outcome.state == .failed)
        #expect(outcome.diagnostics.contains("cli.no-declared-result"))
    }

    @Test("the deadline diagnostic is claude's own")
    func deadlineDiagnostic() {
        #expect(driver.deadlineDiagnostic == "cli.deadline")
    }
}

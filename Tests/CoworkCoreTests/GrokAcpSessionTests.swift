import Foundation
import Testing

@testable import CoworkCore

/// A live ACP worker over stdio JSON-RPC: spawned once, spoken to many times.
///
/// Stand-in agent rather than real grok, deliberately — the mechanism is under
/// test, and a real model's latency would hide a hang behind a plausible wait.
@Suite("GrokAcpSession", .serialized)
struct GrokAcpSessionTests {
    /// Smallest ACP stand-in that honours initialize / session/new / session/prompt.
    ///
    /// Written in Python with explicit flushes (same lesson as CliSessionTests): a
    /// bash stand-in's printf to a pipe is block-buffered and every test hangs.
    private func makeAgent(_ dir: URL, body: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("acp-agent.py")
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func tempDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-acp-\(UUID().uuidString)")
    }

    /// Remembers prompts across turns so a second turn can prove the same process
    /// is still holding context — the whole point of interactive send.
    private let rememberingAgent = """
    #!/usr/bin/env python3
    import sys, json

    prompts = []
    session_id = "sess-acp-test-1"

    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        msg = json.loads(line)
        method = msg.get("method")
        mid = msg.get("id")

        if method == "initialize":
            print(json.dumps({
                "jsonrpc": "2.0",
                "id": mid,
                "result": {
                    "protocolVersion": 1,
                    "serverInfo": {"name": "stand-in", "version": "0"},
                    "capabilities": {}
                }
            }), flush=True)
            continue

        if method == "session/new":
            print(json.dumps({
                "jsonrpc": "2.0",
                "id": mid,
                "result": {"sessionId": session_id}
            }), flush=True)
            continue

        if method == "session/prompt":
            params = msg.get("params") or {}
            text = ""
            for part in params.get("prompt") or []:
                if part.get("type") == "text":
                    text += part.get("text") or ""
            prompts.append(text)

            # Noise the session must ignore: proprietary notifications and
            # non-chunk session/update kinds (and unrelated ids never appear as
            # this request's result).
            print(json.dumps({
                "jsonrpc": "2.0",
                "method": "_x.ai/noise",
                "params": {"ping": True}
            }), flush=True)
            print(json.dumps({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {"update": {"sessionUpdate": "tool_call_progress", "status": "running"}}
            }), flush=True)

            if text.startswith("FAIL_STOP:"):
                reply = "partial"
                stop = text[len("FAIL_STOP:"):] or "unknown"
            elif len(prompts) == 1:
                reply = "echo: " + text
                stop = "end_turn"
            else:
                reply = "prior: " + prompts[0] + " | now: " + text
                stop = "end_turn"

            # Stream assistant text as agent_message_chunk notifications.
            mid_idx = max(1, len(reply) // 2)
            for chunk in (reply[:mid_idx], reply[mid_idx:]):
                print(json.dumps({
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": {
                        "update": {
                            "sessionUpdate": "agent_message_chunk",
                            "content": {"type": "text", "text": chunk}
                        }
                    }
                }), flush=True)

            print(json.dumps({
                "jsonrpc": "2.0",
                "id": mid,
                "result": {"stopReason": stop}
            }), flush=True)
            continue
    """

    private func openSession(dir: URL, turnTimeout: TimeInterval = 5) throws -> GrokAcpSession {
        let agent = try makeAgent(dir, body: rememberingAgent)
        let pipe = try ContainedPipe(executable: agent, arguments: [],
                                     environment: ["PATH": "/usr/bin:/bin"],
                                     cpuSecondsLimit: 60)
        return try GrokAcpSession(pipe: pipe, cwd: dir.path, turnTimeout: turnTimeout)
    }

    @Test("a turn returns assistant text and succeeds on end_turn")
    func turnReturnsTextAndSucceeds() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = try openSession(dir: dir)
        defer { session.close() }

        let turn = session.turn("hello")
        #expect(turn.state == .succeeded)
        #expect(turn.text == "echo: hello")
        #expect(turn.workerAlive, "the worker must survive its turn for send to work")
        #expect(turn.diagnostics.isEmpty)
    }

    @Test("a second turn on the same session sees the first (memory)")
    func secondTurnSeesFirst() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = try openSession(dir: dir)
        defer { session.close() }

        let first = session.turn("alpha")
        #expect(first.state == .succeeded)
        #expect(first.text == "echo: alpha")

        // Same process answers again — a driver that respawns would forget "alpha".
        let second = session.turn("beta")
        #expect(second.state == .succeeded)
        #expect(second.text == "prior: alpha | now: beta",
                "a second turn on a restarted worker would not remember alpha")
        #expect(second.workerAlive)
    }

    @Test("sessionId from session/new is captured as continuation")
    func capturesContinuation() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = try openSession(dir: dir)
        defer { session.close() }

        #expect(session.continuation == "sess-acp-test-1",
                "continuation must be the ACP sessionId from handshake, before any turn")
        _ = session.turn("hi")
        #expect(session.continuation == "sess-acp-test-1")
    }

    @Test("unknown stopReason yields failed, never optimistic success")
    func unknownStopReasonFails() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = try openSession(dir: dir)
        defer { session.close() }

        let turn = session.turn("FAIL_STOP:max_tokens")
        #expect(turn.state == .failed)
        #expect(turn.text == "partial", "chunks still accumulate; the verdict is the stopReason")
        #expect(turn.diagnostics.contains("stopReason=max_tokens"))
        #expect(turn.workerAlive, "a failed turn is not a dead worker")
    }

    @Test("close leaves nothing running")
    func closeKillsTheWorker() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = try openSession(dir: dir)
        _ = session.turn("hi")
        #expect(session.isAlive)
        session.close()
        #expect(!session.isAlive, "a dispatch that ends must leave no worker behind")
    }
}

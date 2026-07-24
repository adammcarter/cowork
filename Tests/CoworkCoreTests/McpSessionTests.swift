import Foundation
import Testing

@testable import CoworkCore

/// A live codex MCP worker over stdio JSON-RPC: spawned once, spoken to many times.
///
/// Stand-in agent rather than real codex, deliberately — the mechanism is under test,
/// and a real model's latency (and its need for a real ~/.codex login) would hide a
/// hang behind a plausible wait. The stand-in speaks the exact wire proved live:
/// `initialize` + `notifications/initialized`, then `tools/call` of `codex` /
/// `codex-reply`, with the reply in `result.structuredContent.content` and the thread
/// in `result.structuredContent.threadId`.
@Suite("McpSession", .serialized)
struct McpSessionTests {
    /// Smallest MCP stand-in honouring initialize / codex / codex-reply.
    ///
    /// Written in Python with explicit flushes (same lesson as StreamJsonSessionTests /
    /// AcpSessionTests): a bash stand-in's printf to a pipe is block-buffered and
    /// every test hangs.
    private func makeAgent(_ dir: URL, body: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("mcp-agent.py")
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func tempDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-codexmcp-\(UUID().uuidString)")
    }

    /// Remembers the first prompt across turns so a second turn (codex-reply) can prove
    /// the same thread still holds context — the whole point of interactive send.
    private let rememberingAgent = """
    #!/usr/bin/env python3
    import sys, json

    first_prompt = None
    thread_id = "thr-test-1"

    def result(mid, reply, with_content=True, blocks_only=False):
        r = {}
        if blocks_only:
            # The MCP spec's own shape: an array of typed content blocks, which is
            # what an agent other than the one this wire was first proved against
            # actually returns.
            r["content"] = [{"type": "text", "text": reply}]
            r["structuredContent"] = {"threadId": thread_id}
        elif with_content:
            r["content"] = [{"type": "text", "text": reply}]
            r["structuredContent"] = {"threadId": thread_id, "content": reply}
        print(json.dumps({"jsonrpc": "2.0", "id": mid, "result": r}), flush=True)

    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        msg = json.loads(line)
        method = msg.get("method")
        mid = msg.get("id")

        if method == "initialize":
            print(json.dumps({
                "jsonrpc": "2.0", "id": mid,
                "result": {"protocolVersion": "2024-11-05", "capabilities": {},
                           "serverInfo": {"name": "stand-in", "version": "0"}}
            }), flush=True)
            continue
        if method == "notifications/initialized":
            continue  # a notification: no reply

        if method == "tools/call":
            params = msg.get("params") or {}
            name = params.get("name")
            args = params.get("arguments") or {}
            prompt = args.get("prompt") or ""

            # Noise the session must ignore: codex/event notifications + an unrelated id.
            print(json.dumps({"jsonrpc": "2.0", "method": "codex/event",
                              "params": {"msg": {"type": "task_started"}}}), flush=True)
            print(json.dumps({"jsonrpc": "2.0", "method": "codex/event",
                              "params": {"msg": {"type": "agent_message", "message": prompt}}}), flush=True)

            if name == "codex":
                first_prompt = prompt
                if prompt.startswith("FAIL_NOCONTENT"):
                    result(mid, "", with_content=False)
                elif prompt.startswith("BLOCKS_ONLY"):
                    result(mid, "echo: " + prompt, blocks_only=True)
                else:
                    result(mid, "echo: " + prompt)
            elif name == "codex-reply":
                # A restarted worker would not remember first_prompt.
                got_thread = args.get("threadId")
                if got_thread != thread_id:
                    result(mid, "WRONG THREAD", with_content=False)
                else:
                    result(mid, "prior: " + (first_prompt or "") + " | now: " + prompt)
            continue
    """

    private func openSession(dir: URL, turnTimeout: TimeInterval = 5) throws -> McpSession {
        let agent = try makeAgent(dir, body: rememberingAgent)
        let pipe = try ContainedPipe(executable: agent, arguments: [],
                                     environment: ["PATH": "/usr/bin:/bin"],
                                     cpuSecondsLimit: 60)
        // The tool names are config values: the stub answers to exactly what the spec
        // says, which is the same path a user's own MCP agent takes.
        let spec = CliDescriptor.SessionSpec(wire: .mcp, arguments: [],
                                             tool: "codex", replyTool: "codex-reply")
        return try McpSession(pipe: pipe, cwd: dir.path, spec: spec, turnTimeout: turnTimeout)
    }

    @Test("a turn returns assistant text and succeeds")
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

    @Test("a second turn (codex-reply) on the same thread sees the first (memory)")
    func secondTurnSeesFirst() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = try openSession(dir: dir)
        defer { session.close() }

        let first = session.turn("alpha")
        #expect(first.state == .succeeded)
        #expect(first.text == "echo: alpha")

        // Same thread answers again — a driver that respawned codex would forget "alpha",
        // and a turn that failed to switch to codex-reply would send the wrong thread.
        let second = session.turn("beta")
        #expect(second.state == .succeeded)
        #expect(second.text == "prior: alpha | now: beta",
                "the second turn must reach codex-reply on the captured thread")
        #expect(second.workerAlive)
    }

    @Test("threadId is captured as continuation only after the first turn")
    func capturesContinuationAfterFirstTurn() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = try openSession(dir: dir)
        defer { session.close() }

        // Codex mints the thread while answering, so there is nothing to continue yet.
        #expect(session.continuation == nil, "no thread exists before the first turn")
        _ = session.turn("hi")
        #expect(session.continuation == "thr-test-1",
                "the thread from the first result becomes the continuation handle")
    }

    /// The presence of a result member is not an answer. A turn that came back with
    /// no text at all is a failure, however well-formed the envelope was — an empty
    /// success is the exact lie this product exists to prevent.
    @Test("a result carrying no answer text is failed, never an optimistic success")
    func noContentIsFailure() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = try openSession(dir: dir)
        defer { session.close() }

        let turn = session.turn("FAIL_NOCONTENT: derailed turn")
        #expect(turn.state == .failed)
        #expect(turn.diagnostics.contains("cli.mcp.no-result"))
        #expect(turn.workerAlive, "a turn that returned no answer is not a dead worker")
    }

    /// The MCP spec returns an ARRAY of typed content blocks. Reading only the
    /// single-string shape this wire was first proved against would hand every other
    /// MCP agent an empty answer while calling the turn a success.
    @Test("the spec's content-block array is read as the answer, not just one agent's string")
    func standardContentBlocksAreRead() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = try openSession(dir: dir)
        defer { session.close() }

        let turn = session.turn("BLOCKS_ONLY please")
        #expect(turn.state == .succeeded)
        #expect(turn.text == "echo: BLOCKS_ONLY please")
        #expect(turn.diagnostics.isEmpty)
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

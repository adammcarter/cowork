import Foundation
import Testing

@testable import CoworkCore

/// A live worker: spawned once, spoken to many times. This is what `send` needs
/// and what a one-shot spawn cannot give it.
///
/// These use a stand-in agent rather than a real CLI, deliberately: the mechanism
/// is what is under test, and a real model's latency would hide a hang behind a
/// plausible wait. The stand-in answers instantly, so anything slow is a bug.
@Suite("CliSession", .serialized)
struct CliSessionTests {
    /// The smallest thing that honours the stream-json contract: read a line,
    /// declare a result, stay alive for the next.
    ///
    /// Written in Python with explicit flushes, deliberately. A bash stand-in
    /// looks simpler and lies: its `printf` to a pipe is block-buffered, so the
    /// reply never leaves the child and every test hangs — which reads exactly
    /// like a bug in the session under test.
    private func makeAgent(_ dir: URL, body: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("agent.sh")
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func tempDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-sess-\(UUID().uuidString)")
    }

    @Test("a worker answers a turn, and stays alive for the next")
    func twoTurnsOneWorker() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = try makeAgent(dir, body: """
        #!/usr/bin/env python3
        import sys
        n = 0
        for _ in sys.stdin:
            n += 1
            print('{"type":"result","session_id":"fake-1","subtype":"success","is_error":false,"result":"turn %d"}' % n, flush=True)
        """)

        let session = try CliSession(executable: agent, arguments: [],
                                     environment: ["PATH": "/usr/bin:/bin"],
                                     turnTimeout: 5)
        defer { session.close() }

        let first = session.turn("one")
        #expect(first.state == .succeeded)
        #expect(first.text == "turn 1")
        #expect(first.workerAlive, "the worker must survive its turn, or send has nothing to talk to")

        // The whole point: the SAME process answers again. A driver that respawns
        // has implemented follow_up, not send.
        let second = session.turn("two")
        #expect(second.text == "turn 2", "a second turn on a restarted worker would say 'turn 1'")
    }

    /// A worker that says nothing must not hang the dispatch forever. The deadline
    /// has to be enforced around a *blocking* read, which is exactly what a naive
    /// implementation gets wrong.
    @Test("a silent worker times out rather than hanging forever")
    func silentWorkerTimesOut() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = try makeAgent(dir, body: """
        #!/usr/bin/env python3
        import sys
        for _ in sys.stdin:
            pass
        """)

        let session = try CliSession(executable: agent, arguments: [],
                                     environment: ["PATH": "/usr/bin:/bin"],
                                     turnTimeout: 2)
        defer { session.close() }

        let began = Date()
        let turn = session.turn("hello?")
        #expect(Date().timeIntervalSince(began) < 10, "a deadline a blocking read can ignore is not a deadline")
        #expect(turn.state == .failed)
    }

    @Test("a worker that exits mid-turn is a failure that names itself")
    func workerExitsMidTurn() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = try makeAgent(dir, body: """
        #!/usr/bin/env python3
        import sys
        sys.stdin.readline()
        """)

        let session = try CliSession(executable: agent, arguments: [],
                                     environment: ["PATH": "/usr/bin:/bin"],
                                     turnTimeout: 5)
        defer { session.close() }

        let turn = session.turn("hello")
        #expect(turn.state == .failed)
        #expect(!turn.workerAlive)
        #expect(turn.diagnostics.contains { $0.contains("no-declared-result") },
                "an exit is not an outcome")
    }

    @Test("the worker's continuation handle is kept, so an interactive dispatch can be followed up")
    func capturesContinuation() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = try makeAgent(dir, body: """
        #!/usr/bin/env python3
        import sys
        for _ in sys.stdin:
            print('{"type":"result","session_id":"sess-xyz","subtype":"success","is_error":false,"result":"ok"}', flush=True)
        """)

        let session = try CliSession(executable: agent, arguments: [],
                                     environment: ["PATH": "/usr/bin:/bin"],
                                     turnTimeout: 5)
        defer { session.close() }
        _ = session.turn("hi")
        #expect(session.lastSessionID == "sess-xyz")
    }

    @Test("close leaves nothing running")
    func closeKillsTheWorker() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = try makeAgent(dir, body: """
        #!/usr/bin/env python3
        import sys
        for _ in sys.stdin:
            print('{"type":"result","subtype":"success","is_error":false,"result":"ok"}', flush=True)
        """)

        let session = try CliSession(executable: agent, arguments: [],
                                     environment: ["PATH": "/usr/bin:/bin"],
                                     turnTimeout: 5)
        _ = session.turn("hi")
        #expect(session.workerAlive)
        session.close()
        #expect(!session.workerAlive, "a dispatch that ends must leave no worker behind")
    }
}

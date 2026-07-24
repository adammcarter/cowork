import Foundation
import Testing

@testable import CoworkCore

/// The seam: `InteractiveSession` driven by a real live worker.
///
/// This is the pairing item 0 is actually about, and the one nothing tested. The
/// unit tests either drove `InteractiveSession` with a closure that was not a
/// worker, or drove `StreamJsonSession` with no dispatch around it — so a dispatch that
/// never reached `awaiting_input` passed both.
///
/// Written before the code that makes it pass, from the interactive-dispatch requirement:
/// an interactive dispatch parks in `awaiting_input`, a `send` resumes it, the
/// worker demonstrably remembers the earlier turn, `finish` concludes it, and an
/// abandoned one times out.
/// Somewhere for a concurrently-produced conclusion to land. The session runs on
/// its own thread so the test can watch the record while it is parked; a plain
/// captured `var` cannot cross that boundary.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

@Suite("Interactive seam", .serialized)
struct InteractiveSeamTests {
    private func withHome(_ body: () throws -> Void) throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-seam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try Store.$rootOverride.withValue(home) { try body() }
    }

    /// A worker with a memory. It echoes every prompt it has been given, so a test
    /// can tell a continued conversation from a restarted one — the exact
    /// distinction between `send` and `follow_up`.
    private func makeRememberingAgent(_ dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("agent.py")
        try """
        #!/usr/bin/env python3
        import sys, json
        seen = []
        for line in sys.stdin:
            try:
                msg = json.loads(line)
                text = msg["message"]["content"][0]["text"]
            except Exception:
                continue
            seen.append(text)
            print(json.dumps({
                "type": "result", "session_id": "seam-1", "subtype": "success",
                "is_error": False, "result": "heard: " + " | ".join(seen),
            }), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        return script
    }

    private func record(_ id: String, task: String) -> DispatchRecord {
        DispatchRecord(id: id, parent: "s_seam", root: "s_seam", backend: "claude",
                       task: task, workspace: nil, state: .running, diagnostics: [],
                       result: nil, interactive: true)
    }

    /// The headline requirement. A dispatch with a live worker must not run to
    /// completion — it must stop and wait, and say so.
    @Test("an interactive dispatch parks in awaiting_input rather than completing")
    func parksInAwaitingInput() throws {
        try withHome {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("seam-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let agent = try makeRememberingAgent(dir)

            let rec = record("j_park", task: "start work")
            try rec.save()
            try Mailbox.create(rec.id)

            let session = try StreamJsonSession(
                                         pipe: ContainedPipe(executable: agent, arguments: [],
                                                            environment: ["PATH": "/usr/bin:/bin"]),
                                         turnTimeout: 5)
            let root = Store.root

            // Nobody ever sends: the dispatch must park, then time out. A dispatch
            // that completes instead has not implemented interactivity at all.
            let done = DispatchSemaphore(value: 0)
            let conclusion = Box<InteractiveSession.Conclusion>()
            Thread {
                Store.$rootOverride.withValue(root) {
                    let sem = DispatchSemaphore(value: 0)
                    Task {
                        conclusion.value = await InteractiveSession(record: rec, idleTimeout: 2)
                            .run { session.turn($0) }
                        sem.signal()
                    }
                    sem.wait()
                }
                done.signal()
            }.start()

            // While it is parked, the record must SAY it is parked. This is the
            // fact a caller polls, and the one that was never reachable.
            var sawAwaitingInput = false
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if DispatchRecord.load(rec.id)?.state == .awaitingInput {
                    sawAwaitingInput = true
                    break
                }
                usleep(50_000)
            }

            _ = done.wait(timeout: .now() + 15)
            session.close()

            #expect(sawAwaitingInput, "a dispatch with a live worker must park and publish awaiting_input")
            #expect(conclusion.value?.state == .timedOut, "abandoned means timed out, never succeeded")
        }
    }

    /// `send` is only real if the worker on the other end is the same one. A
    /// restarted worker would have forgotten the first turn.
    @Test("send resumes the dispatch and the worker remembers the earlier turn")
    func sendResumesAndRemembers() throws {
        try withHome {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("seam-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let agent = try makeRememberingAgent(dir)

            let rec = record("j_send", task: "first")
            try rec.save()
            try Mailbox.create(rec.id)

            let session = try StreamJsonSession(
                                         pipe: ContainedPipe(executable: agent, arguments: [],
                                                            environment: ["PATH": "/usr/bin:/bin"]),
                                         turnTimeout: 5)
            let root = Store.root

            let done = DispatchSemaphore(value: 0)
            let conclusion = Box<InteractiveSession.Conclusion>()
            Thread {
                Store.$rootOverride.withValue(root) {
                    let sem = DispatchSemaphore(value: 0)
                    Task {
                        conclusion.value = await InteractiveSession(record: rec, idleTimeout: 10)
                            .run { session.turn($0) }
                        sem.signal()
                    }
                    sem.wait()
                }
                done.signal()
            }.start()

            // Wait until it is genuinely parked before sending, so this tests the
            // resume path rather than a race.
            let parked = Date().addingTimeInterval(5)
            while Date() < parked, DispatchRecord.load(rec.id)?.state != .awaitingInput {
                usleep(50_000)
            }

            try Mailbox.post(rec.id, .init(kind: .message, text: "second"), timeout: 5)
            usleep(300_000)
            try Mailbox.post(rec.id, .init(kind: .finish, text: ""), timeout: 5)

            _ = done.wait(timeout: .now() + 15)
            session.close()

            // The proof that it is one worker and not two: the reply carries BOTH
            // turns. A respawned worker would answer "heard: second".
            #expect(conclusion.value?.result == "heard: first | second",
                    "the worker must remember the earlier turn, or this is follow_up wearing send's name")
            #expect(conclusion.value?.diagnostics.contains("interaction.finished") == true)
        }
    }

    /// `finish` ends the dispatch on the worker's own last verdict — it never
    /// invents an outcome of its own.
    @Test("finish concludes the dispatch without inventing a verdict")
    func finishConcludes() throws {
        try withHome {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("seam-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let agent = try makeRememberingAgent(dir)

            let rec = record("j_fin", task: "only turn")
            try rec.save()
            try Mailbox.create(rec.id)

            let session = try StreamJsonSession(
                                         pipe: ContainedPipe(executable: agent, arguments: [],
                                                            environment: ["PATH": "/usr/bin:/bin"]),
                                         turnTimeout: 5)
            let root = Store.root

            let done = DispatchSemaphore(value: 0)
            let conclusion = Box<InteractiveSession.Conclusion>()
            Thread {
                Store.$rootOverride.withValue(root) {
                    let sem = DispatchSemaphore(value: 0)
                    Task {
                        conclusion.value = await InteractiveSession(record: rec, idleTimeout: 10)
                            .run { session.turn($0) }
                        sem.signal()
                    }
                    sem.wait()
                }
                done.signal()
            }.start()

            let parked = Date().addingTimeInterval(5)
            while Date() < parked, DispatchRecord.load(rec.id)?.state != .awaitingInput {
                usleep(50_000)
            }
            try Mailbox.post(rec.id, .init(kind: .finish, text: ""), timeout: 5)

            _ = done.wait(timeout: .now() + 15)
            session.close()

            #expect(conclusion.value?.state == .succeeded, "the worker declared success; finish must not overrule it")
            #expect(conclusion.value?.result == "heard: only turn")
            #expect(DispatchRecord.load(rec.id)?.state.isTerminal == true)
        }
    }

    /// The race the mailbox exists to survive: a caller gets an id and sends
    /// immediately, before the first turn is even finished. The receiver is opened
    /// before the first turn precisely so the kernel buffers this — if it were
    /// opened at park time, exactly these messages would be dropped.
    @Test("a message sent before the dispatch parks is not lost")
    func earlySendIsBuffered() throws {
        try withHome {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("seam-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let agent = try makeRememberingAgent(dir)

            let rec = record("j_early", task: "first")
            try rec.save()
            try Mailbox.create(rec.id)

            let session = try StreamJsonSession(
                                         pipe: ContainedPipe(executable: agent, arguments: [],
                                                            environment: ["PATH": "/usr/bin:/bin"]),
                                         turnTimeout: 5)
            let root = Store.root

            // Posted before the session is even started. A dropped message here
            // means a caller who acts the instant they get an id loses their turn.
            let poster = Thread {
                Store.$rootOverride.withValue(root) {
                    try? Mailbox.post(rec.id, .init(kind: .message, text: "second"), timeout: 5)
                    usleep(200_000)
                    try? Mailbox.post(rec.id, .init(kind: .finish, text: ""), timeout: 5)
                }
            }

            let done = DispatchSemaphore(value: 0)
            let conclusion = Box<InteractiveSession.Conclusion>()
            Thread {
                Store.$rootOverride.withValue(root) {
                    let sem = DispatchSemaphore(value: 0)
                    Task {
                        conclusion.value = await InteractiveSession(record: rec, idleTimeout: 10)
                            .run { session.turn($0) }
                        sem.signal()
                    }
                    sem.wait()
                }
                done.signal()
            }.start()
            poster.start()

            _ = done.wait(timeout: .now() + 20)
            session.close()

            #expect(conclusion.value?.result == "heard: first | second",
                    "a message sent before parking must still be delivered")
        }
    }

    /// A worker that dies while the dispatch is parked must end the dispatch, not
    /// leave it waiting for a turn that can never be taken.
    @Test("a worker that dies while parked ends the dispatch rather than hanging")
    func workerDiesWhileParked() throws {
        try withHome {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("seam-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            // Answers once, then exits: the dispatch parks with a dead worker.
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let agent = dir.appendingPathComponent("agent.py")
            try """
            #!/usr/bin/env python3
            import sys, json
            sys.stdin.readline()
            print(json.dumps({"type": "result", "subtype": "success",
                              "is_error": False, "result": "done then gone"}), flush=True)
            """.write(to: agent, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: agent.path)

            let rec = record("j_died", task: "one turn")
            try rec.save()
            try Mailbox.create(rec.id)

            let session = try StreamJsonSession(
                                         pipe: ContainedPipe(executable: agent, arguments: [],
                                                            environment: ["PATH": "/usr/bin:/bin"]),
                                         turnTimeout: 5)
            let root = Store.root

            let done = DispatchSemaphore(value: 0)
            let conclusion = Box<InteractiveSession.Conclusion>()
            Thread {
                Store.$rootOverride.withValue(root) {
                    let sem = DispatchSemaphore(value: 0)
                    Task {
                        // A long idle timeout: if the dispatch waits it out rather
                        // than noticing the death, this test hangs and says so.
                        conclusion.value = await InteractiveSession(record: rec, idleTimeout: 60)
                            .run(isWorkerAlive: { session.isAlive }) { session.turn($0) }
                        sem.signal()
                    }
                    sem.wait()
                }
                done.signal()
            }.start()

            let began = Date()
            let finished = done.wait(timeout: .now() + 20)
            let elapsed = Date().timeIntervalSince(began)
            session.close()

            #expect(finished == .success, "a dead worker must end the dispatch, not park forever")
            // Promptly, not merely eventually. The idle timeout here is 60s; ending
            // "before that" is a low bar, and a caller staring at a dispatch that is
            // already over does not care that it will resolve in a minute.
            #expect(elapsed < 3, "a dead worker should end the dispatch in about a slice, not \(Int(elapsed))s")
            #expect(conclusion.value?.diagnostics.contains("interaction.worker-exited") == true)
        }
    }

    /// Two turns proves reuse; more than two proves it keeps working. A worker that
    /// survives one send but not three is still broken.
    @Test("a conversation of several turns keeps one worker throughout")
    func manyTurnsOneWorker() throws {
        try withHome {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("seam-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let agent = try makeRememberingAgent(dir)

            let rec = record("j_many", task: "a")
            try rec.save()
            try Mailbox.create(rec.id)

            let session = try StreamJsonSession(
                                         pipe: ContainedPipe(executable: agent, arguments: [],
                                                            environment: ["PATH": "/usr/bin:/bin"]),
                                         turnTimeout: 5)
            let root = Store.root

            let done = DispatchSemaphore(value: 0)
            let conclusion = Box<InteractiveSession.Conclusion>()
            Thread {
                Store.$rootOverride.withValue(root) {
                    let sem = DispatchSemaphore(value: 0)
                    Task {
                        conclusion.value = await InteractiveSession(record: rec, idleTimeout: 10)
                            .run { session.turn($0) }
                        sem.signal()
                    }
                    sem.wait()
                }
                done.signal()
            }.start()

            for text in ["b", "c", "d"] {
                let parked = Date().addingTimeInterval(5)
                while Date() < parked, DispatchRecord.load(rec.id)?.state != .awaitingInput {
                    usleep(50_000)
                }
                try Mailbox.post(rec.id, .init(kind: .message, text: text), timeout: 5)
            }
            let parked = Date().addingTimeInterval(5)
            while Date() < parked, DispatchRecord.load(rec.id)?.state != .awaitingInput {
                usleep(50_000)
            }
            try Mailbox.post(rec.id, .init(kind: .finish, text: ""), timeout: 5)

            _ = done.wait(timeout: .now() + 25)
            session.close()

            #expect(conclusion.value?.result == "heard: a | b | c | d",
                    "every turn must reach the same worker, not just the second one")
        }
    }
}

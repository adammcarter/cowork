import Foundation
import Testing

@testable import CoworkCore

/// The event stream is a public contract with no API (ADR 001): anything may tail
/// it. Its atomicity rests on POSIX guaranteeing `O_APPEND` writes below
/// `PIPE_BUF` (4096) are atomic — which is what lets many orchestrators share one
/// file with no lock, no writer epoch, no arbitration (ADR 003 rule 9).
///
/// So an over-long line is not cosmetic: it can interleave with another
/// dispatch's line and corrupt a record cowork promised to keep.
@Suite("Event stream", .serialized)
struct EventsTests {
    private func withTemporaryHome(_ body: (URL) throws -> Void) rethrows {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try Store.$rootOverride.withValue(home) { try body(home) }
    }

    @Test("an event is one line of JSON carrying its lineage")
    func emitsOneAttributedLine() throws {
        try withTemporaryHome { home in
            Events.emit(id: "j_1", parent: "s_a", root: "s_a", backend: "omlx", event: "started")
            let text = try String(contentsOf: home.appendingPathComponent("events.ndjson"), encoding: .utf8)
            let lines = text.split(separator: "\n")
            #expect(lines.count == 1)

            let obj = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
            #expect(obj?["id"] as? String == "j_1")
            #expect(obj?["parent"] as? String == "s_a")   // "who fired this"
            #expect(obj?["root"] as? String == "s_a")     // "whose work is this"
            #expect(obj?["event"] as? String == "started")
            #expect(obj?["v"] as? Int == 1)               // schema is versioned
        }
    }

    @Test("a huge detail is truncated rather than risking an interleaved line")
    func staysUnderPipeBuf() throws {
        try withTemporaryHome { home in
            Events.emit(id: "j_2", parent: "s_a", root: "s_a", backend: "omlx",
                        event: "failed", detail: String(repeating: "x", count: 20_000))
            let data = try Data(contentsOf: home.appendingPathComponent("events.ndjson"))
            #expect(data.count <= 4096,
                    "an event line over PIPE_BUF loses its atomicity guarantee and can corrupt another writer's line")
            let obj = try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any]
            #expect(obj?["event"] as? String == "failed", "the event survives; only the detail is sacrificed")
            #expect((obj?["detail"] as? String)?.contains("omitted") == true)
        }
    }

    @Test("concurrent writers do not interleave")
    func concurrentAppendsStayWhole() throws {
        try withTemporaryHome { home in
            let root = Store.root
            DispatchQueue.concurrentPerform(iterations: 50) { i in
                // concurrentPerform runs on GCD threads, which inherit no task-local:
                // the scope is re-entered so every writer targets the same stream.
                Store.$rootOverride.withValue(root) {
                    Events.emit(id: "j_\(i)", parent: "s_a", root: "s_a", backend: "omlx", event: "started")
                }
            }
            let text = try String(contentsOf: home.appendingPathComponent("events.ndjson"), encoding: .utf8)
            let lines = text.split(separator: "\n")
            #expect(lines.count == 50)
            for line in lines {
                #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil,
                        "every line must parse: a torn line means the atomicity assumption is wrong")
            }
        }
    }
}

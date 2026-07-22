import Darwin
import Foundation
import Testing

@testable import CoworkCore

/// Where an interactive dispatch begins (ADR 001 rule 4, ADR 003 rule 0).
///
/// `interactive` is opt-in, and the mailbox is written ahead of the process for
/// the same reason the record is: a caller handed an id may `send` on the next
/// line, and a mailbox created after the spawn has a window in which that message
/// is refused as though the worker were dead.
@Suite("InteractiveDispatch", .serialized)
struct InteractiveDispatchTests {
    private func withHome(_ body: (Dispatcher) throws -> Void) throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-idisp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let script = home.appendingPathComponent("stand-in-supervisor")
        try "#!/bin/sh\nsleep 300\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try Store.$rootOverride.withValue(home) { try body(Dispatcher(executable: script)) }
    }

    /// The common case must be untouched by any of this: no mailbox, no warm
    /// worker, no cost. A caller opts in to the cost or does not pay it.
    @Test("interactive defaults to false: an ordinary dispatch gets no mailbox")
    func defaultsToOneShot() throws {
        try withHome { dispatcher in
            let started = try dispatcher.start(task: "t", backend: "fixture", workspace: nil,
                                               parent: "s_t", root: "s_t")
            defer { close(started.deathPipeWriteEnd); dispatcher.cancel(id: started.id, grace: 0.2) }
            #expect(DispatchRecord.load(started.id)?.interactive != true)
            #expect(!FileManager.default.fileExists(atPath: Mailbox.url(started.id).path))
        }
    }

    @Test("an interactive dispatch records the opt-in and has a mailbox before it returns")
    func interactiveOptIn() throws {
        try withHome { dispatcher in
            let started = try dispatcher.start(task: "t", backend: "fixture", workspace: nil,
                                               parent: "s_t", root: "s_t", interactive: true)
            defer { close(started.deathPipeWriteEnd); dispatcher.cancel(id: started.id, grace: 0.2) }
            #expect(DispatchRecord.load(started.id)?.interactive == true)
            // Present the moment the id is in the caller's hands, not eventually.
            #expect(FileManager.default.fileExists(atPath: Mailbox.url(started.id).path))
        }
    }

    /// A record written before this change has no `interactive` key at all. Decoding
    /// must treat its absence as false rather than failing — a store that cannot be
    /// read is a store whose dispatches can never reach a terminal event.
    @Test("a record predating interactivity still decodes, as non-interactive")
    func olderRecordsDecode() throws {
        try withHome { _ in
            let legacy = """
                {"id":"j_old","parent":"s_t","root":"s_t","backend":"fixture","task":"t",\
                "state":"running","diagnostics":[]}
                """
            try Store.writeAtomically(Data(legacy.utf8),
                                      to: Store.dispatchDir("j_old").appendingPathComponent("job.json"))
            let r = try #require(DispatchRecord.load("j_old"))
            #expect(r.interactive != true)
        }
    }
}

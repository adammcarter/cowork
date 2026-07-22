import Foundation
import Testing

@testable import CoworkCore

/// The mailbox is the one thing cowork stores that is not a fact for a later
/// reader: a message must reach a process running *now*. Everything else can be
/// written down and read whenever.
///
/// It had no direct tests — `send`'s refusals were covered, but not the transport
/// underneath them.
@Suite("Mailbox", .serialized)
struct MailboxTests {
    private func withHome(_ body: () throws -> Void) throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-mbx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try Store.$rootOverride.withValue(home) { try body() }
    }

    @Test("a message posted to a live receiver arrives")
    func messageArrives() throws {
        try withHome {
            try Mailbox.create("j_1")
            let receiver = try Mailbox.receive("j_1")
            defer { receiver.close() }

            // A task-local does not cross into a GCD thread, so the sender must
            // re-enter the store's scope. Without this it posts into a different
            // store entirely and `try?` hides the mistake — which is exactly how
            // this test first accused the mailbox of a bug it did not have.
            let root = Store.root
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                Store.$rootOverride.withValue(root) {
                    try? Mailbox.post("j_1", .init(kind: .message, text: "pivot"), timeout: 2)
                }
            }
            let got = try receiver.next(timeout: 5)
            #expect(got?.kind == .message)
            #expect(got?.text == "pivot")
        }
    }

    @Test("finish is a distinct message, not a magic string in a message")
    func finishIsItsOwnKind() throws {
        try withHome {
            try Mailbox.create("j_2")
            let receiver = try Mailbox.receive("j_2")
            defer { receiver.close() }

            let root = Store.root
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                Store.$rootOverride.withValue(root) {
                    try? Mailbox.post("j_2", .init(kind: .finish, text: ""), timeout: 2)
                }
            }
            #expect(try receiver.next(timeout: 5)?.kind == .finish)
        }
    }

    /// The bound on the leak cowork accepts by design. Nobody can be relied on to
    /// call `finish` — an orchestrator can simply lose interest — so a warm worker
    /// must not wait forever.
    @Test("a receiver with nobody speaking to it gives up rather than waiting forever")
    func idleReturnsNothing() throws {
        try withHome {
            try Mailbox.create("j_3")
            let receiver = try Mailbox.receive("j_3")
            defer { receiver.close() }

            let began = Date()
            #expect(try receiver.next(timeout: 0.5) == nil, "silence is an answer")
            #expect(Date().timeIntervalSince(began) < 3)
        }
    }

    /// A message to a dispatch with no mailbox must fail loudly. Filing it
    /// somewhere hopeful would leave a caller believing they had steered a worker
    /// that never heard them.
    @Test("posting to a dispatch that has no mailbox is an error, not a quiet success")
    func postWithoutMailboxFails() throws {
        try withHome {
            #expect(throws: (any Error).self) {
                try Mailbox.post("j_absent", .init(kind: .message, text: "hi"), timeout: 1)
            }
        }
    }

    /// The reason `send` cannot simply write and walk away: a FIFO with no reader
    /// blocks on open. A timeout turns "nobody is listening" into an answer rather
    /// than a hang.
    @Test("posting with no reader times out rather than blocking forever")
    func postWithNoReaderTimesOut() throws {
        try withHome {
            try Mailbox.create("j_4")
            let began = Date()
            #expect(throws: (any Error).self) {
                try Mailbox.post("j_4", .init(kind: .message, text: "hi"), timeout: 0.5)
            }
            #expect(Date().timeIntervalSince(began) < 3, "a hang here would wedge the caller")
        }
    }

    @Test("messages keep their order")
    func ordered() throws {
        try withHome {
            try Mailbox.create("j_5")
            let receiver = try Mailbox.receive("j_5")
            defer { receiver.close() }

            let root = Store.root
            DispatchQueue.global().async {
                Store.$rootOverride.withValue(root) {
                    for word in ["first", "second", "third"] {
                        try? Mailbox.post("j_5", .init(kind: .message, text: word), timeout: 2)
                    }
                }
            }
            var seen: [String] = []
            for _ in 0..<3 {
                if let m = try receiver.next(timeout: 5) { seen.append(m.text) }
            }
            #expect(seen == ["first", "second", "third"])
        }
    }
}

import Foundation
import Testing
@testable import CoworkCore

@Suite("wait progress")
struct WaitProgressTests {
    private func record(_ id: String, _ state: DispatchRecord.State) -> DispatchRecord {
        DispatchRecord(id: id, parent: "s", root: "s", backend: "fixture",
                       task: "t", workspace: nil, state: state, diagnostics: [], result: nil)
    }

    @Test("one progress update per poll, monotonic, stopping at the terminal state")
    func streamsUntilTerminal() async {
        let states: [DispatchRecord.State] = [.queued, .running, .succeeded]
        let calls = LockedBox(0)
        let emissions = LockedBox<[WaitProgress.Emission]>([])

        let final = await WaitProgress.run(
            id: "j1", timeout: 60,
            load: { _ in
                let i = calls.withLock { v -> Int in let c = v; v += 1; return c }
                return self.record("j1", states[min(i, states.count - 1)])
            },
            emit: { e in emissions.withLock { $0.append(e) } },
            sleep: {},
            now: { Date(timeIntervalSince1970: 0) })   // deadline far off; termination ends it

        #expect(final?.state == .succeeded)
        let got = emissions.withLock { $0 }
        #expect(got.count == 3, "one emission per poll until terminal")
        #expect(got.map(\.progress) == [1, 2, 3], "progress increases monotonically")
        #expect(got.map(\.message) == ["queued", "running", "succeeded"], "message is the live state")
    }

    @Test("a caller with no terminal state gets the last record when the deadline passes")
    func stopsAtDeadline() async {
        // The clock only advances when the loop sleeps, so the deadline is reached
        // deterministically with no real time and no risk of an infinite loop.
        let clock = LockedBox(Date(timeIntervalSince1970: 0))
        let emissions = LockedBox<[WaitProgress.Emission]>([])

        let final = await WaitProgress.run(
            id: "j2", timeout: 3,                          // 3s budget
            load: { _ in self.record("j2", .running) },    // never terminal
            emit: { e in emissions.withLock { $0.append(e) } },
            sleep: { clock.withLock { $0 = $0.addingTimeInterval(1) } },   // 1s per poll
            now: { clock.withLock { $0 } })

        #expect(final?.state == .running, "the freshest non-terminal record is returned on timeout")
        let n = emissions.withLock { $0.count }
        #expect(n >= 1 && n <= 4, "emits a bounded heartbeat within the 3s budget; got \(n)")
    }

    @Test("a vanished record ends the wait without inventing progress")
    func vanishedRecord() async {
        let emissions = LockedBox<[WaitProgress.Emission]>([])
        let final = await WaitProgress.run(
            id: "gone", timeout: 60,
            load: { _ in nil },
            emit: { e in emissions.withLock { $0.append(e) } },
            sleep: {},
            now: { Date(timeIntervalSince1970: 0) })
        #expect(final == nil)
        #expect(emissions.withLock { $0.isEmpty }, "no progress for a record that does not exist")
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }; return body(&value)
    }
}

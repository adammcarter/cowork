import Foundation
import Testing

@testable import CoworkCore

/// A live session behind one named protocol, and the `LiveSession` adapter that
/// wraps it. The four closures `LiveSession` carried by hand become a conformance;
/// the adapter must delegate each one faithfully.
@Suite("SessionTransport")
struct SessionTransportTests {
    final class FakeTransport: SessionTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _closed = false
        var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }

        func turn(_ prompt: String) async -> InteractiveSession.Turn {
            .init(state: .succeeded, text: "echo:\(prompt)", diagnostics: [])
        }
        var isAlive: Bool { !closed }
        var continuation: String? { "cont-1" }
        func close() { lock.lock(); _closed = true; lock.unlock() }
    }

    @Test("LiveSession(_:) delegates turn, isAlive, continuation and close to the transport")
    func adapterDelegates() async {
        let transport = FakeTransport()
        let live = LiveSession(transport)

        let turn = await live.turn("hi")
        #expect(turn.text == "echo:hi")
        #expect(live.isAlive() == true)
        #expect(live.continuation() == "cont-1")

        live.close()
        #expect(transport.closed)
        #expect(live.isAlive() == false, "the adapter reads the transport live, not a snapshot")
    }
}

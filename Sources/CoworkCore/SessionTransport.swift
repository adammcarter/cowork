import Foundation

/// A live worker the supervisor can take turns with — whatever it is underneath.
///
/// This is the interactive axis, orthogonal to the one-shot one: a dialect vends a
/// session by conforming, and a dialect that cannot hold a conversation simply does
/// not. `CliSession` (a warm claude process) is the first conformer; grok-ACP and
/// codex-reply sessions will be others.
///
/// `turn` is `async` so an endpoint's re-POST loop fits the same shape; a
/// synchronous driver like `CliSession` satisfies it directly.
public protocol SessionTransport: AnyObject, Sendable {
    func turn(_ prompt: String) async -> InteractiveSession.Turn
    /// False once the worker's process is gone; read live while parked, never a
    /// snapshot.
    var isAlive: Bool { get }
    /// The worker's own handle for continuing this context after it concludes.
    var continuation: String? { get }
    func close()
}

/// `CliSession` is already a live session; it just had the four accessors under
/// different names. Conforming makes it a `SessionTransport` without changing a
/// line of its behaviour (its `turn` is synchronous and satisfies the async
/// requirement directly).
extension CliSession: SessionTransport {
    public var isAlive: Bool { workerAlive }
    public var continuation: String? { lastSessionID }
}

extension LiveSession {
    /// Wrap any `SessionTransport` in the closure bundle the supervisor drives. The
    /// closures read the transport live, so `isAlive` and `continuation` reflect the
    /// worker's current state rather than a captured value.
    public init(_ transport: SessionTransport) {
        self.init(turn: { await transport.turn($0) },
                  isAlive: { transport.isAlive },
                  continuation: { transport.continuation },
                  close: { transport.close() })
    }
}

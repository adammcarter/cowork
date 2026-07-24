import Foundation

/// A live worker the supervisor can take turns with — whatever it is underneath.
///
/// This is the interactive axis, orthogonal to the one-shot one. Three CLI wires
/// conform (`StreamJsonSession`, `AcpSession`, `McpSession`) plus the endpoint's own;
/// a backend that cannot hold a conversation simply has none of them.
///
/// `turn` is `async` so an endpoint's re-POST loop fits the same shape; a
/// synchronous pipe-driven session satisfies it directly.
public protocol SessionTransport: AnyObject, Sendable {
    func turn(_ prompt: String) async -> InteractiveSession.Turn
    /// False once the worker's process is gone; read live while parked, never a
    /// snapshot.
    var isAlive: Bool { get }
    /// The worker's own handle for continuing this context after it concludes.
    var continuation: String? { get }
    func close()
}

/// Why a live session could not be opened, named by mechanism rather than by whose
/// binary it was — the backend id already carries that.
public enum CliSessionError: Error, Equatable {
    /// The spawn itself failed; the child's return code, for the record.
    case spawnFailed(Int32)
    /// The row declares no `[session]` block, so cowork has no wire to speak. Refused,
    /// never silently degraded to a one-shot (ADR 006).
    case notSessionCapable
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

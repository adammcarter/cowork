import Foundation

/// A live worker the supervisor can take turns with, whatever it is underneath.
///
/// Two things can hold a conversation open: a CLI worker (a warm process) and an
/// endpoint (a persisted message list cowork owns). They are wired differently —
/// one reads a pipe, the other re-POSTs a list — but the supervisor should not
/// care which. It parks, sends, finishes; the rest is the session's business.
///
/// A closure bundle rather than a protocol on purpose: `CliSession.turn` is
/// synchronous and `EndpointSession.turn` is `async`, and wrapping each into one
/// `async` shape here is simpler and less invasive than forcing both behind a
/// protocol with a single signature.
public struct LiveSession {
    public let turn: (String) async -> InteractiveSession.Turn
    public let isAlive: () -> Bool
    public let continuation: () -> String?
    public let close: () -> Void

    public init(turn: @escaping (String) async -> InteractiveSession.Turn,
                isAlive: @escaping () -> Bool,
                continuation: @escaping () -> String?,
                close: @escaping () -> Void) {
        self.turn = turn
        self.isAlive = isAlive
        self.continuation = continuation
        self.close = close
    }
}

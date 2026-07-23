import Foundation

/// The poll-and-report loop behind `wait` when the caller asked for progress by
/// sending a `progressToken`. It is deliberately free of any MCP type so it can be
/// unit-tested: the handler injects how to load a record, how to emit one progress
/// update, how to wait between polls, and the clock.
///
/// Progress is a *visibility* layer over a live `wait`, never a replacement for the
/// durable store — the record it polls is the same one `status`/`output` read, and
/// a caller that ignores progress entirely still gets the identical terminal
/// result. The total is unknown (a dispatch has no measurable percentage), so each
/// poll emits a monotonically increasing tick with the current lifecycle state as
/// its message: a heartbeat that proves the worker is alive and shows what it is
/// doing, which is exactly what a host renders as "running… N".
public enum WaitProgress {
    public struct Emission: Sendable, Equatable {
        public let progress: Double
        public let message: String
        public init(progress: Double, message: String) {
            self.progress = progress
            self.message = message
        }
    }

    /// Poll `load(id)` until the record is terminal or `now()` passes the deadline,
    /// emitting one progress update per poll. Returns the final record: terminal if
    /// it concluded, the last-seen record on timeout, or nil if the record vanished.
//: @use-case:contract.tools.wait_streams_progress_when_asked
    public static func run(
        id: String,
        timeout: TimeInterval,
        load: @Sendable (String) -> DispatchRecord?,
        emit: @Sendable (Emission) async -> Void,
        sleep: @Sendable () async -> Void,
        now: @Sendable () -> Date
    ) async -> DispatchRecord? {
        let deadline = now().addingTimeInterval(min(timeout, 300))
        var tick = 0.0
        var last: DispatchRecord?
        while now() < deadline {
            guard let record = load(id) else { return nil }
            last = record
            tick += 1
            await emit(Emission(progress: tick, message: record.state.rawValue))
            if record.state.isTerminal { return record }
            await sleep()
        }
        // Deadline reached without a terminal state: report the freshest record.
        return load(id) ?? last
    }
}

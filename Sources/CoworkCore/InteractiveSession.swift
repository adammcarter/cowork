import Foundation

/// The supervisor's half of an interactive dispatch (ADR 001 lifecycle, rule 2).
///
/// A one-shot dispatch is a straight line: run the task, publish the outcome, exit.
/// An interactive one is a loop, and the whole difficulty is that **a turn ending
/// is not a dispatch ending**. The worker declares what happened in its turn; it is
/// never asked whether more is coming, because it cannot know. So `awaiting_input`
/// is a real state with a live process behind it, and only three things end the
/// dispatch: `finish`, the idle timeout, or the worker exiting.
///
/// This lives in the core rather than in the supervisor's own file because it is
/// the lifecycle, not a backend detail: whatever drives the worker — a stdin turn
/// wire, an MCP reply tool, or an in-process endpoint loop — the states, the
/// events and the bound on a warm worker's life are the same.
public struct InteractiveSession: Sendable {
    /// What one turn declared. Mirrors a backend's outcome, plus the one fact only
    /// the driver knows: whether the worker is still there to take another message.
    public struct Turn: Sendable {
        public let state: DispatchRecord.State
        public let text: String
        public let diagnostics: [String]
        public let transcript: String
        /// False once the worker's process is gone. Parking in `awaiting_input`
        /// then would advertise a `send` that could only ever be refused.
        public let workerAlive: Bool

        public init(state: DispatchRecord.State, text: String, diagnostics: [String],
                    transcript: String = "", workerAlive: Bool = true) {
            self.state = state
            self.text = text
            self.diagnostics = diagnostics
            self.transcript = transcript
            self.workerAlive = workerAlive
        }
    }

    public struct Conclusion: Sendable {
        public let state: DispatchRecord.State
        public let result: String
        public let diagnostics: [String]
        public let transcript: String
    }

    public let record: DispatchRecord
    /// How long a worker may sit warm with nobody speaking to it.
    ///
    /// This is not politeness, it is the bound on a leak cowork accepts by design:
    /// a warm worker holds a live process *and* its context, and nobody can be
    /// relied on to call `finish` — an orchestrator can simply lose interest. It is
    /// a parameter because it is policy, not physics: a caller thinking for five
    /// minutes is normal, and a deadline is honest but wrong if it is too short.
    public let idleTimeout: TimeInterval

    public init(record: DispatchRecord, idleTimeout: TimeInterval = 300) {
        self.record = record
        self.idleTimeout = idleTimeout
    }

    /// Run the dispatch to a terminal outcome, taking turns as messages arrive.
    ///
    /// `turn` is given a prompt — the original task first, then each message — and
    /// returns what the worker declared. It is expected to reuse the same live
    /// worker across calls; that reuse is the entire point of an interactive
    /// dispatch, and a driver that restarts its worker per call has implemented
    /// `follow_up`, not `send`.
/// `isWorkerAlive` is asked *while parked*, which `Turn.workerAlive` cannot
    /// answer: that is a snapshot taken when the turn ended, and a worker can die
    /// in the silence afterwards. Without a live check such a dispatch waits out
    /// its whole idle timeout — five minutes, in production — before admitting
    /// that the thing it was waiting for can never take another turn. The default
    /// keeps closure-driven callers, which have no process to ask about, unchanged.
//: @use-case:contract.tools.interactive_parks_in_awaiting_input#interactive_parks_in_awa
    public func run(isWorkerAlive: @escaping () -> Bool = { true },
                    turn: (String) async -> Turn) async -> Conclusion {
        let receiver: Mailbox.Receiver
        do {
            // Opened before the first turn, not after it. The kernel buffers the
            // mailbox, so a message that lands mid-turn waits in the pipe — but only
            // if this end is already open. Opening later would drop exactly the
            // messages a caller sends the instant they get an id.
            receiver = try Mailbox.receive(record.id)
        } catch {
            return conclude(state: .failed, result: "",
                            diagnostics: ["interaction.mailbox-unavailable", "\(error)"],
                            transcript: "")
        }
        defer { receiver.close() }

        var transcript = ""
        var last = await turn(record.task)
        transcript += last.transcript

        while true {
            if !last.workerAlive {
                // The third way a dispatch ends. The worker's own declaration stands
                // as the verdict (ADR 001 rule 1); its exit is the diagnostic beside it.
                return conclude(state: last.state, result: last.text,
                                diagnostics: last.diagnostics + ["interaction.worker-exited"],
                                transcript: transcript)
            }

            park(after: last)

            // Waited in slices rather than one long block, so a worker dying in the
            // silence is noticed now instead of at the idle timeout. The receiver
            // drains into its own queue in the background, so slicing the wait
            // cannot drop a message that arrives between slices.
            let message: Mailbox.Message?
            do {
                let deadline = Date().addingTimeInterval(idleTimeout)
                var found: Mailbox.Message?
                while found == nil, Date() < deadline {
                    let slice = min(0.25, max(0, deadline.timeIntervalSinceNow))
                    found = try receiver.next(timeout: slice)
                    if found == nil, !isWorkerAlive() {
                        return conclude(state: last.state, result: last.text,
                                        diagnostics: last.diagnostics + ["interaction.worker-exited"],
                                        transcript: transcript)
                    }
                }
                message = found
            } catch {
                return conclude(state: .failed, result: last.text,
                                diagnostics: last.diagnostics + ["interaction.mailbox-failed", "\(error)"],
                                transcript: transcript)
            }

            guard let message else {
                // Nobody came back. Not a success — the last turn's outcome describes
                // a turn, and this dispatch was abandoned rather than concluded.
                return conclude(state: .timedOut, result: last.text,
                                diagnostics: last.diagnostics
                                    + ["interaction.idle-timeout", "idle=\(Int(idleTimeout))s"],
                                transcript: transcript)
            }

            switch message.kind {
            case .finish:
                // The caller ends it; the worker's last declaration is still the
                // verdict. `finish` never invents an outcome of its own.
                return conclude(state: last.state, result: last.text,
                                diagnostics: last.diagnostics + ["interaction.finished"],
                                transcript: transcript)
            case .message:
                resume()
                last = await turn(message.text)
                transcript += last.transcript
            }
        }
    }

    /// Publish the turn's outcome and go idle. The record carries the turn's result
    /// while parked, so `output` on an `awaiting_input` dispatch returns what the
    /// worker actually said rather than an empty string — a parked dispatch has
    /// produced something, it simply is not over.
    private func park(after turn: Turn) {
        var parked = record
        parked.state = .awaitingInput
        parked.result = turn.text
        parked.diagnostics = turn.diagnostics
        try? parked.save()
        Events.emit(id: record.id, parent: record.parent, root: record.root,
                    backend: record.backend, event: "awaiting_input",
                    detail: "turn=\(turn.state.rawValue)")
    }

    private func resume() {
        var running = record
        running.state = .running
        try? running.save()
        Events.emit(id: record.id, parent: record.parent, root: record.root,
                    backend: record.backend, event: "running",
                    detail: "interaction.message-received")
    }

    /// Every dispatch reaches a terminal event. No exceptions (ADR 003 rule 5) —
    /// and an interactive one has more ways to end, which is more ways to forget.
    private func conclude(state: DispatchRecord.State, result: String,
                          diagnostics: [String], transcript: String) -> Conclusion {
        var closing = record
        closing.state = state
        closing.result = result
        closing.diagnostics = diagnostics
        try? closing.save()
        Events.emit(id: record.id, parent: record.parent, root: record.root,
                    backend: record.backend, event: state.rawValue,
                    detail: diagnostics.isEmpty ? nil : diagnostics.joined(separator: ","))
        return Conclusion(state: state, result: result, diagnostics: diagnostics,
                          transcript: transcript)
    }
}

import Foundation

/// `send` and `finish` — the orchestrator's half of an interactive dispatch
/// (ADR 001).
///
/// These two tools exist because the alternative, when a running worker needs one
/// extra detail or a change of direction, is to stop it and start again — throwing
/// away its context and its work. The proven mechanism beneath them is real: a
/// live Claude worker accepts further user messages on stdin, two messages eight
/// seconds apart each producing their own declared result.
///
/// Almost all of this file is refusals, deliberately. A `send` that cannot be
/// delivered has exactly three honest endings — refuse it, or report the transport
/// failed — and none of them is "accept it and say nothing". A message quietly
/// dropped leaves the caller building on a pivot that never happened, which is the
/// silent-error failure ADR 000 calls worse than having no tool at all.
public enum Interaction {
    /// Whether a backend can honestly be messaged (ADR 001 rule 3). A closure
    /// rather than a type, so this stays a question `capabilities` answers and not
    /// a second, competing opinion held here.
    public typealias SupportsMessage = @Sendable (String) -> Bool

    public enum Failure: Error, CustomStringConvertible {
        case unknownDispatch(id: String)
        case unreadableRecord(id: String)
        /// The backend cannot do this at all. Not a temporary condition and not
        /// something a retry fixes: the caller must branch.
        case backendCannotBeMessaged(id: String, backend: String)
        case notInteractive(id: String)
        case alreadyTerminal(id: String, state: DispatchRecord.State)
        case workerGone(id: String)
        /// The record says the worker is alive; its mailbox says otherwise. Both
        /// facts are reported because cowork does not know which is wrong, and
        /// picking one would be a guess presented as knowledge.
        case workerUnreachable(id: String, why: String)

        public var description: String {
            switch self {
            case let .unknownDispatch(id):
                return "interaction.unknown-dispatch,id=\(id)"
            case let .unreadableRecord(id):
                return "interaction.unreadable-record,id=\(id)"
            case let .backendCannotBeMessaged(id, backend):
                return """
                    interaction.backend-cannot-be-messaged,id=\(id),backend=\(backend): this \
                    backend reports supports_message=false, so the message was refused rather \
                    than queued for a worker that will never read it.
                    """
            case let .notInteractive(id):
                return """
                    interaction.not-interactive,id=\(id): this dispatch was not started with \
                    interactive=true, so its worker's input was closed at dispatch. Use cancel \
                    to stop it, or start an interactive dispatch to message one.
                    """
            case let .alreadyTerminal(id, state):
                return "interaction.dispatch-terminal,id=\(id),state=\(state.rawValue)"
            case let .workerGone(id):
                return "interaction.worker-gone,id=\(id)"
            case let .workerUnreachable(id, why):
                return "interaction.worker-unreachable,id=\(id),\(why)"
            }
        }
    }

    /// Send a message to a live worker.
    ///
    /// The order of the checks is the order of the truths: what the backend can do
    /// at all, then whether this dispatch is over, then whether it ever offered to
    /// be messaged, and only then the transport. Each answers a different mistake,
    /// and a caller told the most specific one can act on it.
//: @use-case:contract.tools.send_messages_a_live_worker#send_messages_a_live_wor
    public static func send(id: String, message: String,
                            supportsMessage: SupportsMessage,
                            timeout: TimeInterval = 5) throws {
        let record = try load(id)

        guard supportsMessage(record.backend) else {
            throw Failure.backendCannotBeMessaged(id: id, backend: record.backend)
        }
        guard !record.state.isTerminal else {
            throw Failure.alreadyTerminal(id: id, state: record.state)
        }
        guard record.interactive == true else { throw Failure.notInteractive(id: id) }

        try post(.init(kind: .message, text: message), to: record, timeout: timeout)
    }

    /// End an interactive dispatch and release its worker.
    ///
    /// The returned state is **observed, never assumed**. Terminating is the
    /// supervisor's to do — it owns the worker (ADR 003 rule 1) — so this posts the
    /// end, waits `settle` for the terminal state to land, and reports whatever is
    /// true at that moment, including a state that is not yet terminal. Claiming
    /// the dispatch had ended because we asked would be the small lie that makes
    /// every other report untrustworthy.
//: @use-case:contract.tools.finish_ends_an_interactive_dispatch#finish_ends_an_interacti
    @discardableResult
    public static func finish(id: String, settle: TimeInterval = 5) throws -> DispatchRecord.State {
        let record = try load(id)
        guard record.interactive == true else { throw Failure.notInteractive(id: id) }

        // Unlike `send`, finishing a terminal dispatch pretends nothing: the
        // postcondition — this dispatch is over, its worker released — already
        // holds. The caller is told the state rather than handed an error for
        // asking for something that is already true.
        guard !record.state.isTerminal else { return record.state }

        try post(.init(kind: .finish), to: record, timeout: settle)

        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline {
            switch DispatchRecord.loadResult(id) {
            case let .loaded(latest) where latest.state.isTerminal:
                return latest.state
            case .loaded, .missing:
                break
            case .unreadable:
                throw Failure.unreadableRecord(id: id)
            }
            usleep(50_000)
        }
        switch DispatchRecord.loadResult(id) {
        case let .loaded(latest):
            return latest.state
        case .missing:
            return record.state
        case .unreadable:
            throw Failure.unreadableRecord(id: id)
        }
    }

    private static func load(_ id: String) throws -> DispatchRecord {
        switch DispatchRecord.loadResult(id) {
        case let .loaded(record):
            return record
        case .missing:
            throw Failure.unknownDispatch(id: id)
        case .unreadable:
            throw Failure.unreadableRecord(id: id)
        }
    }

    /// Translate a transport failure into the truth about *this dispatch*.
    ///
    /// The mailbox only knows whether anyone is reading it. Whether that means the
    /// worker died or that it is alive and wedged is a question only the record can
    /// answer, and the two deserve different words: one is an ordinary end, the
    /// other is a fault worth someone's attention.
    private static func post(_ message: Mailbox.Message, to record: DispatchRecord,
                             timeout: TimeInterval) throws {
        do {
            try Mailbox.post(record.id, message, timeout: timeout)
        } catch Mailbox.MailboxError.absent {
            // The record claims interactive but no mailbox was ever made. That is
            // cowork's own bookkeeping contradicting itself, not the caller's error.
            throw Failure.workerUnreachable(id: record.id, why: "mailbox-absent")
        } catch Mailbox.MailboxError.noLiveWorker {
            guard let pid = record.ownerPID, let start = record.ownerStart,
                  Liveness.isAlive(pid: pid, start: start)
            else { throw Failure.workerGone(id: record.id) }
            throw Failure.workerUnreachable(id: record.id, why: "owner-alive-but-not-reading")
        } catch {
            throw Failure.workerUnreachable(id: record.id, why: "\(error)")
        }
    }
}

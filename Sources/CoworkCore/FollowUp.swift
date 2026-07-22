import Foundation

/// `follow_up(id, task) -> id` (ADR 001): a new dispatch carrying a finished
/// dispatch's context.
///
/// It looks like `send` and is not. `send` speaks to a worker that is **alive**;
/// `follow_up` starts a **fresh** worker that remembers. They map to different
/// mechanisms — stdin versus `--resume` — and they fail in different ways, so
/// collapsing them would mean lying about one of them.
///
/// Everything here rests on one proven fact: `claude -p --resume <session_id>`
/// genuinely carries context. A second dispatch recalled a codeword given only to
/// the first. Without a handle like that, a follow-up is impossible — and cowork
/// refuses rather than quietly starting fresh.
public enum FollowUp {
    public enum Failure: Error, CustomStringConvertible {
        case unknownDispatch(id: String)
        case unreadableRecord(id: String)
        case notFinished(id: String, state: DispatchRecord.State)
        case noContinuation(id: String, backend: String)

        public var description: String {
            switch self {
            case let .unknownDispatch(id):
                return "followup.unknown-dispatch,id=\(id)"
            case let .unreadableRecord(id):
                return "followup.unreadable-record,id=\(id)"
            case let .notFinished(id, state):
                return """
                    followup.not-finished,id=\(id),state=\(state.rawValue): a dispatch that \
                    has not finished has not produced the context a follow-up would continue. \
                    To steer the live worker instead, use send.
                    """
            case let .noContinuation(id, backend):
                return """
                    followup.no-continuation,id=\(id),backend=\(backend): this dispatch left no \
                    continuation handle, so its context cannot be carried. Starting a new \
                    dispatch would forget everything it knew, and reporting that as a \
                    follow-up would be a lie.
                    """
            }
        }
    }

    /// What a follow-up will be, derived entirely from the dispatch it continues.
    public struct Plan: Sendable, Equatable {
        public let task: String
        public let backend: String
        public let workspace: String?
        public let continuation: String
        public let parent: String
        public let root: String
    }

    /// Derive a follow-up from a finished dispatch.
    ///
    /// A follow-up inherits backend and workspace rather than accepting them: a
    /// caller who could re-supply them could differ, and a follow-up whose
    /// workspace differs from the work it continues is not a follow-up.
    ///
    /// Its `parent` is the dispatch it continues, so the tree shows the thread
    /// (ADR 001 attribution); its `root` is unchanged, because whose work it is
    /// has not changed.
    public static func plan(from id: String, task: String) throws -> Plan {
        let record: DispatchRecord
        switch DispatchRecord.loadResult(id) {
        case let .loaded(loaded):
            record = loaded
        case .missing:
            throw Failure.unknownDispatch(id: id)
        case .unreadable:
            throw Failure.unreadableRecord(id: id)
        }
        guard record.state.isTerminal else {
            throw Failure.notFinished(id: id, state: record.state)
        }
//: @use-case:contract.tools.follow_up_refused_when_no_continuation#follow_up_refused_when_n
        guard let continuation = record.continuation, !continuation.isEmpty else {
            throw Failure.noContinuation(id: id, backend: record.backend)
        }
//: @use-case:end contract.tools.follow_up_refused_when_no_continuation#follow_up_refused_when_n
//: @use-case:contract.tools.follow_up_carries_context#follow_up_carries_contex
        return Plan(task: task, backend: record.backend, workspace: record.workspace,
                    continuation: continuation, parent: record.id, root: record.root)
    }
//: @use-case:end contract.tools.follow_up_carries_context#follow_up_carries_contex
}

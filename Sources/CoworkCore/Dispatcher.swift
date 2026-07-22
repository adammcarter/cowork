import Darwin
import Foundation

/// The dispatcher: the orchestrator's half of a dispatch.
///
/// It writes the record, spawns the supervisor, and returns. It does **not** run
/// the work — that is the supervisor's job (ADR 003 rule 1), and it is what makes
/// `dispatch` return an id immediately as the contract promises
/// ([ADR 001](001)), so `status`, `wait`, `send` and `cancel` have something live
/// to talk about.
public struct Dispatcher: Sendable {
    public let executable: URL
    /// Variables the supervisor must be handed, because it is a fresh process that
    /// inherits nothing. A provider's `credential = "env:NAME"` names one of these,
    /// and without it the supervisor reports credential-absent for a key the user
    /// correctly exported.
    public let supervisorEnvironment: [String: String]

    public init(executable: URL, supervisorEnvironment: [String: String] = [:]) {
        self.executable = executable
        self.supervisorEnvironment = supervisorEnvironment
    }

    public struct Started {
        public let id: String
        /// Held for the dispatch's lifetime. When this closes — deliberately or
        /// because the orchestrator died — the supervisor terminates.
        public let deathPipeWriteEnd: Int32
    }

    public enum DispatchError: Error {
        case launchFailed(String)
    }

    /// Start a dispatch and return at once.
    ///
    /// `interactive` defaults to false (ADR 001 rule 4): the common case closes the
    /// worker's input immediately and is fire-and-forget. A caller opts in to a
    /// warm worker — and thereby to a live process and its context being held —
    /// rather than paying for one it never asked for.
    public func start(task: String, backend: String, workspace: String?,
                      parent: String, root: String, interactive: Bool = false,
                      continues: String? = nil, onTerminal: String? = nil) throws -> Started {
        let id = Lineage.mintID()

        // ADR 003 rule 0: the record is written and published BEFORE the process
        // exists. Spawn-then-record leaves a window in which a crash produces a
        // running worker nothing knows about — a leak with no name that no later
        // reconciliation can recover, because it was never written down.
//: @use-case:containment.record_precedes_process#record_precedes_process
        var record = DispatchRecord(id: id, parent: parent, root: root, backend: backend,
                                    task: task, workspace: workspace, state: .queued,
                                    diagnostics: [], result: nil, interactive: interactive)
        // A follow-up's supervisor needs the handle to resume from; it is the
        // predecessor's, not this dispatch's own, which it will earn when it ends.
        record.continues = continues
        // The teardown hook rides the record because the supervisor is a fresh
        // process: a hook that does not persist is a hook that never runs.
        record.onTerminal = onTerminal
        try Store.prepare()
        try record.save()
        // The mailbox is written ahead of the process for the same reason the record
//: @use-case:end containment.record_precedes_process#record_precedes_process
        // is (rule 0): this call hands the caller an id, and they may `send` on the
        // next line. A mailbox created inside the supervisor would leave a window in
        // which that message is refused as though the worker were dead.
        if interactive { try Mailbox.create(id) }
        Events.emit(id: id, parent: parent, root: root, backend: backend,
//: @use-case:contract.workspace.unconfined_is_recorded_as_unconfined#unconfined_is_recorded_a
                    event: "queued", workspace: workspace ?? "unconfined")

//: @use-case:end contract.workspace.unconfined_is_recorded_as_unconfined#unconfined_is_recorded_a
        do {
//: @use-case:contract.tools.dispatch_returns_id_while_work_runs_elsewhere#dispatch_returns_id_whil
            let launch = try Supervisor.launch(executable: executable, dispatchID: id,
                                               environment: supervisorEnvironment)
            // The owner is recorded only once it exists, and identity is
            // (pid, start) so a recycled pid cannot masquerade as a live owner.
            record.ownerPID = launch.pid
            record.ownerStart = launch.start
            record.state = .running
            try record.save()
            Events.emit(id: id, parent: parent, root: root, backend: backend, event: "started")
            return Started(id: id, deathPipeWriteEnd: launch.deathPipeWriteEnd)
        } catch {
//: @use-case:end contract.tools.dispatch_returns_id_while_work_runs_elsewhere#dispatch_returns_id_whil
            // A dispatch that could not start still reaches a terminal event: the
            // record already exists, so silence here would be the one outcome rule 5
            // forbids.
            record.state = .failed
            record.diagnostics = ["dispatch.supervisor-launch-failed", "\(error)"]
            try? record.save()
            Events.emit(id: id, parent: parent, root: root, backend: backend,
                        event: "failed", detail: "dispatch.supervisor-launch-failed")
            throw DispatchError.launchFailed("\(error)")
        }
    }

    /// Stop a dispatch and its worker, and record the outcome.
    ///
    /// The terminal event is posted by whoever gets there first: normally the
    /// supervisor within its grace period, but the orchestrator reports on its
    /// behalf if it died without doing so (ADR 003 rule 5).
    /// `grace` is how long a worker gets to post its terminal event and run
    /// teardown before `SIGKILL` (ADR 003 rule 4). It is a parameter because it is
    /// policy, not physics: a stubborn worker that ignores `SIGTERM` costs the full
    /// grace, which is correct in production and pure waiting in a test.
//: @use-case:contract.tools.cancel_stops_a_running_dispatch#cancel_stops_a_running_d
    @discardableResult
    public func cancel(id: String, grace: TimeInterval = 5) -> Bool {
        guard var record = DispatchRecord.load(id) else { return false }
        guard !record.state.isTerminal else { return true }

        if let pid = record.ownerPID, let start = record.ownerStart {
            _ = Supervisor.terminate(pid: pid, start: start, grace: grace)
        }

        // Re-read: the supervisor may have posted its own terminal state inside the
        // grace period, and that is the worker's declaration, which outranks ours.
        if let latest = DispatchRecord.load(id), latest.state.isTerminal { return true }

        record.state = .cancelled
        record.diagnostics.append("dispatch.cancelled")
        try? record.save()
        Events.emit(id: record.id, parent: record.parent, root: record.root,
                    backend: record.backend, event: "cancelled", detail: "dispatch.cancelled")
        return true
    }

    /// Block until terminal or the cap expires, then report the truth either way.
    /// Never blocks indefinitely: "still running" is an honest answer
    /// ([ADR 001](001) `wait`).
//: @use-case:contract.tools.wait_is_hard_capped_and_returns_still_running#wait_is_hard_capped_and_
    public func wait(id: String, timeout: TimeInterval) -> DispatchRecord? {
        let deadline = Date().addingTimeInterval(min(timeout, 300))
        while Date() < deadline {
            guard let record = DispatchRecord.load(id) else { return nil }
            if record.state.isTerminal { return record }
            usleep(200_000)
        }
        return DispatchRecord.load(id)
    }
}

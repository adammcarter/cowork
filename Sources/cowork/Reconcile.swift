import CoworkCore
import Foundation

/// Reconciliation closes ADR 003 rule 5: **every dispatch reaches a terminal
/// event, no exceptions.**
///
/// A supervisor that dies without reporting — killed with its orchestrator, or
/// `SIGKILL`ed outright — leaves a record that says `running` forever. Silence is
/// the one outcome cowork must never produce, because a caller cannot tell it
/// apart from work still in progress. Nobody is watching to fix that: with no
/// daemon there is no background sweeper, so the sweep happens on any invocation.
/// The record precedes the process (rule 0), so every abandoned dispatch is
/// always findable — which is precisely why write-ahead is worth its cost.
enum Reconcile {
//: @use-case:containment.every_dispatch_reaches_a_terminal_event#every_dispatch_reaches_a
    @discardableResult
    static func sweep() -> [String] {
        let jobs = Store.root.appendingPathComponent("jobs")
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: jobs.path) else {
            return []
        }

        var reconciled: [String] = []
        for id in ids {
            guard var record = DispatchRecord.load(id), !record.state.isTerminal else { continue }
            // No owner recorded, or the owner is gone: this dispatch is abandoned.
            if let pid = record.ownerPID, let start = record.ownerStart,
               Liveness.isAlive(pid: pid, start: start) {
                continue    // genuinely still running, under a live owner
            }

            // The no-orphans rule (ADR 003) means a worker does not outlive its
            // orchestrator: if the owner is gone, so is the work. That is a
            // cancellation by cowork's own design, not a failure of the worker,
            // and it is named as such rather than blamed on the backend.
            record.state = .cancelled
            record.diagnostics.append("reconciled.owner-gone")
            try? record.save()
            Events.emit(id: record.id, parent: record.parent, root: record.root,
                        backend: record.backend, event: record.state.rawValue,
                        detail: "reconciled.owner-gone")
            reconciled.append(record.id)
        }
        return reconciled
    }
}

import Foundation
import Testing

@testable import CoworkCore

/// What the supervisor decides, separated from its exiting.
///
/// `SuperviseMode` could not be tested at all: it returns `Never` and lives in the
/// executable target, so every decision it makes — which is most of what it does —
/// was reachable only by running the real binary. That is exactly the shape that
/// let `send` and `finish` ship dead: the wiring nothing could test was the wiring
/// that was wrong.
///
/// So the decision is a value now, and this is the exhaustive table of it.
@Suite("Supervision plan")
struct SupervisionPlanTests {
    private func record(interactive: Bool, backend: String = "claude") -> DispatchRecord {
        DispatchRecord(id: "j_plan", parent: "s_p", root: "s_p", backend: backend,
                       task: "work", workspace: nil, state: .running, diagnostics: [],
                       result: nil, interactive: interactive)
    }

    @Test("an interactive dispatch with a live session runs interactively")
    func interactiveWithSession() {
        let plan = SupervisionPlan.decide(record: record(interactive: true),
                                          hasInteractiveSession: true, hasRunner: true)
        #expect(plan == .runInteractive)
    }

    /// The refusal that matters. Running an interactive request one-shot would
    /// report a dispatch that can never be messaged as though it could — the exact
    /// dishonesty ADR 001 rule 3 exists to prevent. Both CLI and endpoint backends
    /// can hold a session now, so this is the branch for any future backend that
    /// genuinely cannot — the plan refuses on the fact of no session, not on a guess
    /// about the backend's type.
    @Test("an interactive dispatch on a backend that cannot hold a worker is refused, not downgraded")
    func interactiveWithoutSessionIsRefused() {
        let plan = SupervisionPlan.decide(record: record(interactive: true, backend: "sessionless"),
                                          hasInteractiveSession: false, hasRunner: true)
        #expect(plan == .refuse(["supervise.interactive-unsupported", "backend=sessionless"]))
    }

    /// Ordering matters: a backend nobody can resolve is a different, more basic
    /// failure than one that merely cannot hold a warm worker, and the caller
    /// deserves the accurate one.
    @Test("an unresolvable backend is refused as unresolved, whether or not it was interactive")
    func unresolvableBackend() {
        for interactive in [true, false] {
            let plan = SupervisionPlan.decide(record: record(interactive: interactive, backend: "nope"),
                                              hasInteractiveSession: false, hasRunner: false)
            #expect(plan == .refuse(["supervise.backend-unresolved", "backend=nope"]),
                    "interactive=\(interactive) must still name the unresolved backend")
        }
    }

    @Test("an ordinary dispatch runs one-shot")
    func ordinaryRunsOneShot() {
        let plan = SupervisionPlan.decide(record: record(interactive: false),
                                          hasInteractiveSession: false, hasRunner: true)
        #expect(plan == .runOneShot)
    }

    /// A session offered for a dispatch that never asked for one must not quietly
    /// turn it interactive — a dispatch that parks when the caller expected a
    /// result would hang them for the full idle timeout.
    @Test("a non-interactive dispatch stays one-shot even when a session is available")
    func sessionAvailableButNotRequested() {
        let plan = SupervisionPlan.decide(record: record(interactive: false),
                                          hasInteractiveSession: true, hasRunner: true)
        #expect(plan == .runOneShot)
    }

    /// An interactive dispatch never falls back to a runner it happens to have.
    /// This is the case that decides whether `interactive` is a promise or a hint.
    @Test("interactive never silently degrades to one-shot when a runner exists")
    func interactiveNeverDegrades() {
        let plan = SupervisionPlan.decide(record: record(interactive: true),
                                          hasInteractiveSession: false, hasRunner: true)
        #expect(plan != .runOneShot, "degrading here is how send became a lie")
    }
}

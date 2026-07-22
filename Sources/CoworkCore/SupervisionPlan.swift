import Foundation

/// What the supervisor should do with a dispatch — decided as a value, before
/// anything is run and before anything exits.
///
/// The supervisor's decisions used to be inseparable from its exiting: it returned
/// `Never` from the executable target, so the only way to observe a choice was to
/// run the real binary and read the events afterwards. Nothing did, and the
/// dispatch path that never read `record.interactive` passed a full green suite
/// while `send` and `finish` were dead beneath it.
///
/// Separating the choice from the act is what makes the choice testable. The
/// supervisor keeps the exiting; this keeps the reasoning.
public enum SupervisionPlan: Equatable {
    /// Hold a live worker and take turns until the caller ends it.
    case runInteractive
    /// Run the task once and report what the worker declared.
    case runOneShot
    /// Do neither, and say why. A refusal is an outcome, not an absence of one.
    case refuse([String])

    /// - Parameters:
    ///   - hasInteractiveSession: whether a live worker can actually be held for
    ///     this backend. Only a CLI agent can today; an endpoint's "session" is
    ///     cowork's own message list, which is a different mechanism.
    ///   - hasRunner: whether the backend resolves to anything at all.
    public static func decide(record: DispatchRecord,
                              hasInteractiveSession: Bool,
                              hasRunner: Bool) -> SupervisionPlan {
        let wantsInteractive = record.interactive == true

        if wantsInteractive, hasInteractiveSession { return .runInteractive }

        // Checked before the interactive refusal so the caller hears the more basic
        // truth first: a backend nobody can resolve is not merely one that cannot
        // hold a warm worker, and naming the wrong cause sends them looking in the
        // wrong place.
        guard hasRunner else {
            return .refuse(["supervise.backend-unresolved", "backend=\(record.backend)"])
        }

        if wantsInteractive {
            // Never downgraded to one-shot. Running it anyway would report a
            // dispatch that can never be messaged as though it could, which is
            // precisely the dishonesty ADR 001 rule 3 forbids — and precisely how
            // `send` came to be wired to something that could not serve it.
            return .refuse(["supervise.interactive-unsupported", "backend=\(record.backend)"])
        }

        return .runOneShot
    }
}

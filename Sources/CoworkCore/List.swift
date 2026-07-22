import Foundation

/// Which dispatches a caller is asking about (ADR 001, `list(scope?)`).
public enum ListScope: Sendable, Equatable {
    /// Everything descended from one orchestrator, however deeply nested.
    case lineage(root: String)
    /// Every dispatch on the machine, whoever fired it.
    case all

    /// Parse the contract's optional `scope` argument.
    ///
    /// Absent means the caller's own lineage, which is the default the contract
    /// promises. An unrecognised value is `nil` — refused — rather than being
    /// quietly treated as one of the two real scopes: answering a question the
    /// caller did not ask, and labelling it as their answer, is the small lie this
    /// whole product exists to avoid. The caller reports the refusal.
//: @use-case:contract.tools.list_scopes_to_lineage_and_refuses_unknown_scope#list_scopes_to_lineage_a
    public static func parse(_ raw: String?) -> ListScope? {
        switch raw {
        case nil, "": return .lineage(root: Lineage.root)
        case "all": return .all
        default: return nil
        }
    }
}

/// A record that exists in the store and cannot be described.
///
/// It is deliberately *not* a `DispatchRecord`: cowork knows it started this
/// dispatch (the record precedes the process, ADR 003 rule 0) but cannot say what
/// state it is in, and synthesising one would be inventing a fact.
public struct UnreadableDispatch: Sendable, Equatable {
    public let id: String
    /// Why it could not be read, in the diagnostic style the rest of the contract
    /// uses: a stable code plus the underlying cause, never a guess.
    public let diagnostic: String
}

/// The answer to `list`: the dispatches, and the records that could not be turned
/// into one.
public struct DispatchListing: Sendable {
    public let dispatches: [DispatchRecord]
    public let unreadable: [UnreadableDispatch]

    public var isEmpty: Bool { dispatches.isEmpty && unreadable.isEmpty }
}

/// `list(scope?) -> dispatch[]` (ADR 001).
///
/// One pass over the jobs dir. There is no index and no daemon holding one: the
/// filesystem is the store (ADR 003 rule 8), so a listing is a directory read plus
/// a filter on a single field of each record. That is also why every host — and a
/// shell one-liner — can do this without cowork's cooperation.
public enum DispatchList {
    /// The caller's own lineage: the contract's default scope.
    public static func list() -> DispatchListing {
        list(scope: .lineage(root: Lineage.root))
    }

    public static func list(scope: ListScope) -> DispatchListing {
        let jobs = Store.root.appendingPathComponent("jobs")
        // A store that does not exist yet holds no dispatches. That is an empty
        // list, not an error: nothing has been dispatched on this machine.
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: jobs.path) else {
            return DispatchListing(dispatches: [], unreadable: [])
        }

        var dispatches: [DispatchRecord] = []
        var unreadable: [UnreadableDispatch] = []

        for id in entries.sorted() {
            // Atomic-by-rename (ADR 003 rule 10) leaves `.tmp-*` files in the store
            // while a write is in flight, and a crash can strand one. Those — and
            // any other hidden entry the OS drops in, `.DS_Store` being the usual
            // one — were never dispatch ids and must not be read as such.
            if id.hasPrefix(".") { continue }

            let file = jobs.appendingPathComponent(id).appendingPathComponent("job.json")

            // The jobs dir is written concurrently by supervisors, and a reader can
            // catch a dispatch dir between its creation and the rename that lands
            // its record. That dir is not a half-written dispatch — it is one that
            // does not exist yet. Rule 0 makes this safe to skip rather than to
            // guess about: the record precedes the process, so nothing is running
            // under a dir that has no record. The rename is what makes the
            // alternative — a torn, partly-written record — unobservable.
            guard FileManager.default.fileExists(atPath: file.path) else { continue }

            // Past this point the record exists, so anything short of a decoded
            // record is a fact worth reporting rather than an entry to skip. A
            // record cowork wrote and can no longer read is a dispatch whose state
            // is unknown; dropping it from the list is silence, and silence is the
            // one outcome the contract forbids (ADR 003 rule 5), because a caller
            // cannot tell it apart from work that was never started.
            do {
                let data = try Data(contentsOf: file)
                dispatches.append(try JSONDecoder().decode(DispatchRecord.self, from: data))
            } catch {
                unreadable.append(UnreadableDispatch(
                    id: id, diagnostic: "list.record-unreadable: \(error)"))
            }
        }

        // Scope filters on `root`, never on `parent`: `root` answers "whose work is
        // this", so a monitor sees its own session's tree including the dispatches
        // its workers fired. Filtering on `parent` would show only direct children
        // and hide nested work being done in the caller's name.
        //
        // An orphan carries its own id as its root, so it matches only a scope
        // that names it — it is never guessed into another orchestrator's tree, and
        // it is never missing from `all`.
        if case let .lineage(root) = scope {
            dispatches = dispatches.filter { $0.root == root }
        }

        // Unreadable records survive every scope, deliberately. Their lineage is
        // exactly what could not be read, so filtering them by it is impossible;
        // the two honest options are to show them to every caller or to no caller,
        // and showing them to nobody is silence. They ride in a separate field, so
        // reporting them makes no claim that they belong to the caller's tree —
        // "this record exists and cannot be read" is the whole of the assertion.

        // Ordering. Ids are opaque (ADR 001 rule 6) — unique, with no other meaning
        // — so sorting by id cannot claim to order by time, and mtime is a fact
        // about the last write rather than about the dispatch, and would reshuffle
        // the list under a reader as supervisors write. What a caller can act on is
        // live work, so live sorts first; the id tiebreak is arbitrary but total,
        // and ids are unique, so the order is identical for two callers reading the
        // same store and stable across repeated calls.
        dispatches.sort { a, b in
            if a.state.isTerminal != b.state.isTerminal { return !a.state.isTerminal }
            return a.id < b.id
        }

        return DispatchListing(dispatches: dispatches, unreadable: unreadable)
    }
}

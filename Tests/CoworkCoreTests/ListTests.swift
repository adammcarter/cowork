import Foundation
import Testing

@testable import CoworkCore

/// `list(scope?)` from the public contract (ADR 001).
///
/// The interesting half of this tool is not "return the records" — it is what it
/// does with the records it cannot honestly place: an orphan with no attributable
/// parent, a record it cannot decode, and a dispatch dir caught mid-creation while
/// a supervisor writes it. Those are what these tests pin.
///
/// NOTE: the store root is a task-local, so these tests scope it rather than
/// touching `COWORK_HOME`. `.serialized` matches the rest of the target.
@Suite("List", .serialized)
struct ListTests {
    private func withHome(_ body: () throws -> Void) throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-list-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try Store.$rootOverride.withValue(home) {
            try Store.prepare()
            try body()
        }
    }

    @discardableResult
    private func put(_ id: String, parent: String, root: String,
                     state: DispatchRecord.State = .running) throws -> DispatchRecord {
        let record = DispatchRecord(id: id, parent: parent, root: root, backend: "fixture",
                                    task: "t", workspace: nil, state: state,
                                    diagnostics: [], result: nil)
        try record.save()
        return record
    }

    /// The default scope is the caller's own work, which is *its whole tree* —
    /// including dispatches its workers fired. Filtering on `parent` would show a
    /// monitor only its direct children and hide the nested work being done in its
    /// name, so the filter is `root` (ADR 001, "Attribution and filtering").
    @Test("the default scope is the caller's lineage, nested dispatches included")
    func defaultScopeFiltersOnRoot() throws {
        try withHome {
            try put("j_7f3a", parent: "s_claude_a91c", root: "s_claude_a91c")
            try put("j_2b19", parent: "j_7f3a", root: "s_claude_a91c")       // fired by a worker
            try put("j_c40d", parent: "s_claude_a91c", root: "s_claude_a91c")
            try put("j_other", parent: "s_codex_beef", root: "s_codex_beef") // someone else's

            let mine = DispatchList.list(scope: .lineage(root: "s_claude_a91c"))
            #expect(Set(mine.dispatches.map(\.id)) == ["j_7f3a", "j_2b19", "j_c40d"])
        }
    }

    @Test("scope 'all' returns every dispatch on the machine, whoever fired it")
    func allScopeReturnsEverything() throws {
        try withHome {
            try put("j_mine", parent: "s_a", root: "s_a")
            try put("j_theirs", parent: "s_b", root: "s_b")

            #expect(Set(DispatchList.list(scope: .all).dispatches.map(\.id)) == ["j_mine", "j_theirs"])
        }
    }

    /// An orphan is reported as its own root — never guessed into somebody's tree,
    /// and never dropped from `all`. Both halves matter: guessing invents a lie,
    /// dropping produces silence.
    @Test("an orphan is its own root: visible to itself and in 'all', invisible to others")
    func orphanIsItsOwnRoot() throws {
        try withHome {
            try put("j_orphan", parent: "j_orphan", root: "j_orphan")
            try put("j_mine", parent: "s_a", root: "s_a")

            #expect(DispatchList.list(scope: .lineage(root: "j_orphan")).dispatches.map(\.id) == ["j_orphan"])
            #expect(DispatchList.list(scope: .lineage(root: "s_a")).dispatches.map(\.id) == ["j_mine"],
                    "an orphan must not be guessed into another orchestrator's tree")
            #expect(Set(DispatchList.list(scope: .all).dispatches.map(\.id)) == ["j_orphan", "j_mine"])
        }
    }

    /// A record that cannot be decoded is a dispatch cowork knows it started and
    /// can no longer describe. Dropping it is silence; reporting it as a dispatch
    /// would be inventing a state nobody declared. It is therefore reported
    /// separately, in every scope, as a record that exists and cannot be read.
    @Test("an undecodable record is reported, not silently dropped")
    func undecodableRecordIsReported() throws {
        try withHome {
            try put("j_good", parent: "s_a", root: "s_a")
            let broken = Store.dispatchDir("j_broken")
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
            try "{not json".write(to: broken.appendingPathComponent("job.json"),
                                  atomically: true, encoding: .utf8)

            for scope in [ListScope.all, .lineage(root: "s_a")] {
                let listed = DispatchList.list(scope: scope)
                #expect(listed.dispatches.map(\.id) == ["j_good"],
                        "an unreadable record must not be reported as a real dispatch")
                #expect(listed.unreadable.map(\.id) == ["j_broken"],
                        "nor may it vanish: silence is the one forbidden outcome")
            }
        }
    }

    /// The jobs dir is written concurrently by supervisors. `writeAtomically`
    /// creates the dispatch dir, writes a temp file, and renames — so a reader can
    /// catch a dir whose record has not landed yet. That is not a dispatch: rule 0
    /// says the record precedes the process, so nothing is running under it.
    @Test("a dispatch dir with no record yet is neither reported nor a crash")
    func halfWrittenDispatchIsNotReal() throws {
        try withHome {
            try put("j_real", parent: "s_a", root: "s_a")
            try FileManager.default.createDirectory(at: Store.dispatchDir("j_landing"),
                                                    withIntermediateDirectories: true)

            let listed = DispatchList.list(scope: .all)
            #expect(listed.dispatches.map(\.id) == ["j_real"])
            #expect(listed.unreadable.isEmpty,
                    "a record that was never published is not a record that broke")
        }
    }

    /// Ids are opaque (ADR 001 rule 6), so they cannot be ordered by time without
    /// inventing a meaning they do not have. What a caller acts on is live work, so
    /// live sorts first; the id tiebreak makes the order total and repeatable.
    @Test("live dispatches sort before terminal ones, and the order is stable")
    func orderingIsStableAndUseful() throws {
        try withHome {
            try put("j_a_done", parent: "s_a", root: "s_a", state: .succeeded)
            try put("j_b_live", parent: "s_a", root: "s_a", state: .running)
            try put("j_c_done", parent: "s_a", root: "s_a", state: .failed)
            try put("j_d_live", parent: "s_a", root: "s_a", state: .awaitingInput)

            let ids = DispatchList.list(scope: .all).dispatches.map(\.id)
            #expect(ids == ["j_b_live", "j_d_live", "j_a_done", "j_c_done"])
            #expect(DispatchList.list(scope: .all).dispatches.map(\.id) == ids,
                    "two identical calls must not disagree about order")
        }
    }

    @Test("an empty or absent store lists nothing rather than failing")
    func emptyStoreIsEmpty() throws {
        try withHome {
            #expect(DispatchList.list(scope: .all).isEmpty)
        }
        let absent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-list-absent-\(UUID().uuidString)")
        Store.$rootOverride.withValue(absent) {
            #expect(DispatchList.list(scope: .all).isEmpty)
        }
    }

    /// Atomic-by-rename leaves `.tmp-*` files behind in the store while a write is
    /// in flight, and a crash can strand one. They are never dispatches.
    @Test("temp and hidden entries in the jobs dir are not dispatches")
    func tempFilesAreIgnored() throws {
        try withHome {
            try put("j_real", parent: "s_a", root: "s_a")
            let jobs = Store.root.appendingPathComponent("jobs")
            try "half".write(to: jobs.appendingPathComponent(".tmp-\(UUID().uuidString)"),
                             atomically: true, encoding: .utf8)
            try "".write(to: jobs.appendingPathComponent(".DS_Store"),
                         atomically: true, encoding: .utf8)

            let listed = DispatchList.list(scope: .all)
            #expect(listed.dispatches.map(\.id) == ["j_real"])
            #expect(listed.unreadable.isEmpty)
        }
    }

    @Test("scope parses to the caller's lineage by default and rejects what it cannot honour")
    func scopeParsing() throws {
        #expect(ListScope.parse("all") == .all)
        #expect(ListScope.parse(nil) == .lineage(root: Lineage.root))
        #expect(ListScope.parse("everything") == nil,
                "an unrecognised scope must be refused, not quietly turned into a different one")
    }
}

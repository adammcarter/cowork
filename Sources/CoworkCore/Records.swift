import Foundation

/// The one noun (ADR 000). A dispatch targets one agent and has one lifecycle.
public struct DispatchRecord: Codable, Sendable {
    public enum LoadResult: Sendable {
        case loaded(DispatchRecord)
        case missing
        case unreadable(diagnostic: String)
    }

    private static let schemaVersion = 1

    /// The lifecycle is part of the public contract (ADR 001).
    public enum State: String, Codable, Sendable {
        case queued, running, awaitingInput = "awaiting_input"
        case succeeded, failed, cancelled, timedOut = "timed_out"

        public var isTerminal: Bool {
            switch self {
            case .succeeded, .failed, .cancelled, .timedOut: return true
            case .queued, .running, .awaitingInput: return false
            }
        }
    }

    public let id: String
    public let parent: String
    public let root: String
    public let backend: String
    public let task: String
    public let workspace: String?
    public var state: State
    public var diagnostics: [String]
    public var result: String?
    /// The process that owns this dispatch, identified by (pid, start time) so a
    /// recycled pid cannot masquerade as a live owner. Written before the work
    /// starts, so reconciliation can always tell abandoned from running.
    public var ownerPID: pid_t?
    public var ownerStart: Int64?
    /// The backend's own handle for continuing THIS dispatch's context — the
    /// session id, for instance. Earned when the dispatch ends. Captured because
    /// `follow_up` is impossible without it, and faking a follow-up that silently
    /// forgot everything would be the exact lie ADR 000 forbids. Absent means this
    /// backend offered none.
    public var continuation: String?
    /// The handle this dispatch RESUMES, if it is itself a follow-up. Distinct
    /// from `continuation`: one is inherited on the way in, the other is earned on
    /// the way out, and conflating them would make a follow-up's own handle its
    /// predecessor's.
    public var continues: String?
    /// Did this dispatch opt in to a warm worker (ADR 001 rule 4)?
    ///
    /// Optional rather than a plain `Bool` because Swift's synthesized decoding
    /// ignores property defaults and would reject every record written before this
    /// existed — and a record that cannot be read is a dispatch that can never
    /// reach a terminal event, which is the one outcome ADR 003 rule 5 forbids.
    /// Absent means false: the common case is fire-and-forget, and a caller opts
    /// in to a warm worker's cost rather than inheriting it.
    public var interactive: Bool?

    /// A command the supervisor runs when the dispatch SUCCEEDS (ADR 002 rules 9–10).
    /// The core runs it without knowing what it is for — sugar passes `git worktree
    /// remove`. Failed, cancelled and timed-out dispatches skip it: they keep their
    /// workspace, because the evidence is the point. Absent means no hook.
    public var onTerminal: String?

    public init(id: String, parent: String, root: String, backend: String, task: String,
                workspace: String?, state: State, diagnostics: [String], result: String?,
                ownerPID: pid_t? = nil, ownerStart: Int64? = nil, interactive: Bool = false) {
        self.id = id; self.parent = parent; self.root = root; self.backend = backend
        self.task = task; self.workspace = workspace; self.state = state
        self.diagnostics = diagnostics; self.result = result
        self.ownerPID = ownerPID; self.ownerStart = ownerStart
        self.interactive = interactive ? true : nil
    }

    public var file: URL { Store.dispatchDir(id).appendingPathComponent("job.json") }

    public func save() throws {
        let encoded = try JSONEncoder().encode(self)
        guard var envelope = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw EncodingError.invalidValue(self, .init(codingPath: [],
                debugDescription: "record.unreadable"))
        }
        envelope["schemaVersion"] = Self.schemaVersion
        try Store.writeAtomically(try JSONSerialization.data(withJSONObject: envelope), to: file)
    }

//: @use-case:contract.tools.status_and_output_report_declared_result#status_and_output_report
    public static func load(_ id: String) -> DispatchRecord? {
        guard case let .loaded(record) = loadResult(id) else { return nil }
        return record
    }

    public static func loadResult(_ id: String) -> LoadResult {
        let file = Store.dispatchDir(id).appendingPathComponent("job.json")
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return .missing
        } catch {
            return .unreadable(diagnostic: "record.unreadable")
        }

        do {
            guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .unreadable(diagnostic: "record.unreadable") }
            let version: Int
            if let encodedVersion = envelope["schemaVersion"] {
                guard let parsedVersion = encodedVersion as? Int else {
                    return .unreadable(diagnostic: "record.unreadable")
                }
                version = parsedVersion
            } else {
                version = schemaVersion
            }
            guard version == schemaVersion else {
                return .unreadable(
                    diagnostic: "record.unsupported-schema-version version=\(version)")
            }
            return .loaded(try JSONDecoder().decode(DispatchRecord.self, from: data))
        } catch {
            return .unreadable(diagnostic: "record.unreadable")
        }
    }
}

/// Lineage is derived, not asserted (ADR 001). Cowork reads its orchestrator from
/// the host session it runs under, and injects the current dispatch's identity
/// into each worker's environment — so a worker that itself calls cowork is
/// attributed automatically, with nothing for a caller to supply or spoof.
///
/// An orphan is reported as its own root rather than guessed into a tree.
public enum Lineage {
    public static var parent: String {
        let env = ProcessInfo.processInfo.environment
        if let d = env["COWORK_DISPATCH_ID"] { return d }          // nested: a worker dispatching
        // NAME EXEMPTION, deliberate and narrow. These two name the HOSTS cowork can
        // be running inside, not backends it dispatches — which variable a host
        // exports is a fact about the world, not a preference, and moving it into
        // config would silently lose lineage whenever the guess was wrong. No other
        // agent name belongs anywhere in Sources/.
        if let s = env["CLAUDE_SESSION_ID"] { return "s_claude_\(String(s.prefix(8)))" }
        if let s = env["CODEX_SESSION_ID"] { return "s_codex_\(String(s.prefix(8)))" }
        return "s_unknown"
    }

    public static var root: String {
        ProcessInfo.processInfo.environment["COWORK_ROOT"] ?? parent
    }

    public static func mintID() -> String {
        "j_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
    }
}

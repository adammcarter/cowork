import Foundation

/// Where cowork keeps its records. The filesystem is the store (ADR 003): every
/// host reads the same directory, so no protocol, server, or client library exists.
public enum Store {
    /// A task-scoped store root.
    ///
    /// The store location was read from a process-global environment variable,
    /// which is fine for a process and wrong for anything running concurrently
    /// inside one: two tasks pointing the store at different places clobber each
    /// other, and the failure looks like a real bug rather than a shared global.
    /// A task-local is scoped to the work that set it.
    @TaskLocal public static var rootOverride: URL?

    public static var root: URL {
        if let scoped = rootOverride { return scoped }
        if let env = ProcessInfo.processInfo.environment["COWORK_HOME"] {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cowork")
    }

    public static var eventStream: URL { root.appendingPathComponent("events.ndjson") }
    public static func dispatchDir(_ id: String) -> URL { root.appendingPathComponent("jobs/\(id)") }

    public static func prepare() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("jobs"),
                                                withIntermediateDirectories: true)
    }

    /// Atomic by rename (ADR 003 rule 9): write a temporary file, rename over the
    /// target. That is the whole durability mechanism — no transactions, no WAL.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    public static func read(_ url: URL) -> Data? { try? Data(contentsOf: url) }
}

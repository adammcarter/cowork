import Foundation
import Testing

@testable import CoworkCore

/// ADR 002 grants a worker a workspace and confines it there. For an endpoint
/// backend cowork executes the tools itself, so that grant is only as good as
/// this code — and until now it was reasoned about rather than demonstrated.
@Suite("Workspace confinement")
struct WorkspaceTests {
    private func makeWorkspace(writable: Bool = true) throws -> (Workspace, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (Workspace(root: root, writable: writable), root)
    }

    @Test("a path inside the grant resolves")
    func insideResolves() throws {
        let (ws, root) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolved = try ws.resolve("notes/today.md")
        #expect(resolved.path.hasPrefix(root.resolvingSymlinksInPath().path)
                || resolved.path.hasPrefix(root.path))
    }

    @Test("an absolute path outside the grant is refused")
    func absoluteEscapeRefused() throws {
        let (ws, root) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ToolError.self) { try ws.resolve("/etc/passwd") }
    }

    /// The escape a model is most likely to attempt, deliberately or by accident.
    @Test("a relative path climbing out with ../ is refused")
    func traversalRefused() throws {
        let (ws, root) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ToolError.self) { try ws.resolve("../../../etc/passwd") }
        #expect(throws: ToolError.self) { try ws.resolve("subdir/../../escape.txt") }
    }

    /// A sibling whose path *begins* with the grant's path is not inside it.
    /// Prefix comparison without a separator would wrongly admit `/tmp/ws-evil`
    /// for a grant of `/tmp/ws`.
    @Test("a sibling directory sharing a name prefix is refused")
    func siblingPrefixRefused() throws {
        let (ws, root) = try makeWorkspace()
        let evilTwin = root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + "-evil")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ToolError.self) { try ws.resolve(evilTwin.path + "/secret.txt") }
    }

    @Test("a read-only grant refuses a write and says why")
    func readOnlyRefusesWrite() throws {
        let (ws, root) = try makeWorkspace(writable: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = Tools.execute(name: "write_file",
                                   arguments: #"{"path":"x.txt","content":"hi"}"#,
                                   workspace: ws)
        #expect(result.contains("denied"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("x.txt").path))
    }

    /// The refusal is returned to the model as a tool result rather than thrown
    /// away: the model learns it may not go there, instead of cowork silently
    /// doing something else (ADR 002).
    @Test("an escape attempt is reported back to the model, not silently clamped")
    func escapeIsReportedToModel() throws {
        let (ws, root) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = Tools.execute(name: "read_file",
                                   arguments: #"{"path":"/etc/passwd"}"#,
                                   workspace: ws)
        #expect(result.contains("denied"))
        #expect(result.contains("outside the workspace"))
        #expect(!result.contains("root:"))   // no /etc/passwd content leaked
    }

    @Test("no workspace grant means file tools are unavailable, not unrestricted")
    func absentGrantRefuses() {
        let result = Tools.execute(name: "read_file",
                                   arguments: #"{"path":"/etc/passwd"}"#,
                                   workspace: nil)
        #expect(result.contains("denied"))
        #expect(!result.contains("root:"))
    }
}

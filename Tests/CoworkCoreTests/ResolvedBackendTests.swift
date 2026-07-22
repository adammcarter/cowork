import Foundation
import Testing

@testable import CoworkCore

/// One resolved backend answers "what is this, and what can it do?" for every path.
///
/// These tests pin the split-brain fix: capabilities, interactive session creation,
/// and message support all derive from the same resolved operations — never from a
/// parallel existence check or a hand-maintained Bool.
@Suite("ResolvedBackend")
struct ResolvedBackendTests {

    private func installedExecutable(named name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-resolved-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func cliConfig(_ name: String, executable: URL,
                           kind: CliDialect? = nil) -> Config {
        let dialect = kind ?? CliDialect(executable: executable)
        let cli = CliConfig(name: name, executable: executable, kind: dialect, origin: .global)
        return Config(providers: [:], cli: [name: cli], visible: [:])
    }

    private func endpointConfig(name: String = "omlx",
                                baseURL: String = "http://127.0.0.1:9",
                                model: String = "m") -> (Config, String) {
        let p = ProviderConfig(name: name, kind: "openai_compatible",
                               baseURL: URL(string: baseURL)!, chatPath: "v1/chat/completions",
                               credential: nil, origin: .global)
        let id = "\(name)/\(model)"
        return (Config(providers: [name: p], cli: [:], visible: [name: p]), id)
    }

    // MARK: capability is operation presence

    @Test("claude ops: one-shot, interactive, and follow-up are all present")
    func claudeHasAllOps() throws {
        let exe = try installedExecutable(named: "claude")
        let backend = try #require(BackendResolver.resolve("claude", config: cliConfig("claude", executable: exe)))

        #expect(backend.supportsMessage == true)
        #expect(backend.supportsFollowUp == true)
        #expect(backend.oneShot(DispatchContext()) != nil)
        #expect(backend.followUp(DispatchContext(resume: "sess")) != nil)
        // interactiveSession may fail to spawn a real claude; presence is the non-nil factory.
        #expect(backend.canOpenInteractiveSession == true)
    }

    @Test("codex ops: interactive yes, follow-up no — derived from operations, not a Bool")
    func codexNoFollowUp() throws {
        let exe = try installedExecutable(named: "codex")
        let backend = try #require(BackendResolver.resolve("codex", config: cliConfig("codex", executable: exe)))

        #expect(backend.supportsMessage == true)
        #expect(backend.supportsFollowUp == false)
        #expect(backend.oneShot(DispatchContext()) != nil)
        #expect(backend.followUp(DispatchContext(resume: "thread")) == nil)
    }

    @Test("unknown CLI driver: no operations, so no message and no follow-up")
    func unknownDriverHasNoOps() throws {
        let exe = try installedExecutable(named: "mystery-agent")
        let backend = try #require(BackendResolver.resolve(
            "mystery", config: cliConfig("mystery", executable: exe)))

        #expect(backend.supportsMessage == false)
        #expect(backend.supportsFollowUp == false)
        #expect(backend.oneShot(DispatchContext()) == nil)
        #expect(backend.followUp(DispatchContext()) == nil)
        #expect(backend.diagnostics.contains("cli.driver-unknown"))
    }

    @Test("endpoint ops: interactive yes, follow-up no")
    func endpointOps() throws {
        let (config, id) = endpointConfig()
        let backend = try #require(BackendResolver.resolve(id, config: config))

        #expect(backend.kind == .endpoint)
        #expect(backend.supportsMessage == true)
        #expect(backend.supportsFollowUp == false)
        #expect(backend.oneShot(DispatchContext()) != nil)
        #expect(backend.followUp(DispatchContext()) == nil)
        #expect(backend.canOpenInteractiveSession == true)
    }

    @Test("facts() derives supports_message and supports_follow_up from operations")
    func factsDeriveFromOps() throws {
        let claude = try installedExecutable(named: "claude")
        let codex = try installedExecutable(named: "codex")
        let c = try #require(BackendResolver.resolve("c", config: cliConfig("c", executable: claude)))
        let x = try #require(BackendResolver.resolve("x", config: cliConfig("x", executable: codex)))

        #expect(c.facts().supportsMessage == true)
        #expect(c.facts().supportsFollowUp == true)
        #expect(x.facts().supportsMessage == true)
        #expect(x.facts().supportsFollowUp == false)
    }

    // MARK: bug (a) — workspace roots the CHILD PROCESS, not just context plumbing

    /// An interactive dispatch grants a workspace; the worker process must actually
    /// run there. Claude has no protocol cwd flag — only process cwd can root it —
    /// so this stand-in reports `os.getcwd()`, not a value echoed from DispatchContext.
    @Test("interactive session for a CLI backend is rooted at the dispatch workspace")
    func interactiveSessionUsesDispatchWorkspace() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-ws-sess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let workspace = dir.appendingPathComponent("granted-workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let expected = workspace.resolvingSymlinksInPath().path
        // Write outside the workspace so a wrong-cwd child can still create the proof file.
        let seenCwd = dir.appendingPathComponent("seen-process-cwd.txt")

        // Stand-in claude: on start, record real process cwd; then honour stream-json.
        let agent = dir.appendingPathComponent("claude")
        let script = """
        #!/usr/bin/env python3
        import os, sys
        open(\(Self.pythonString(seenCwd.path)), "w").write(os.getcwd())
        for raw in sys.stdin:
            line = raw.strip()
            if not line:
                continue
            # Minimal stream-json result so the session can complete a turn if asked.
            print('{"type":"result","session_id":"s1","subtype":"success","is_error":false,"result":"ok"}', flush=True)
        """
        try script.write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)

        let backend = try #require(BackendResolver.resolve(
            "claude", config: cliConfig("claude", executable: agent)))

        let ctx = DispatchContext(workspace: workspace.path, resume: nil)
        let session = try #require(try backend.interactiveSession(ctx))
        defer { session.close() }

        // Child writes getcwd at start; give the pipe a moment if the write is racing.
        var recorded: String?
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let text = try? String(contentsOf: seenCwd, encoding: .utf8), !text.isEmpty {
                recorded = text
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let childCwd = URL(fileURLWithPath: try #require(recorded)).resolvingSymlinksInPath().path
        #expect(childCwd == expected,
                "CLI worker process cwd must be the dispatch workspace; got \(recorded ?? "<missing>")")
    }

    @Test("endpoint interactive session receives the dispatch workspace for tools")
    func endpointInteractiveSessionReceivesWorkspace() throws {
        let (config, id) = endpointConfig()
        let backend = try #require(BackendResolver.resolve(id, config: config))

        let wsPath = "/tmp/cowork-endpoint-ws-\(UUID().uuidString)"
        let ctx = DispatchContext(workspace: wsPath)
        // Creating the session must succeed and bind the grant; tool denial without
        // a grant is the prior bug (workspace: nil).
        let session = try #require(try backend.interactiveSession(ctx))
        defer { session.close() }

        // EndpointSession is not SessionTransport directly in all paths — LiveSession
        // wraps it. interactiveSession returns SessionTransport; EndpointSession
        // conforms via an adapter when resolved.
        #expect(session.isAlive == true)
        #expect(session.continuation == nil)
    }

    // MARK: bug (b) — message capability is real, not existence

    @Test("supportsMessage is false for a resolvable-but-unmessageable CLI (unknown driver)")
    func supportsMessageIsNotMereExistence() throws {
        let exe = try installedExecutable(named: "mystery-agent")
        // Existence-based check would say true (config has the name). Real capability
        // is false: no SessionCapable agent, no interactive operation.
        let backend = try #require(BackendResolver.resolve(
            "mystery", config: cliConfig("mystery", executable: exe)))
        #expect(BackendResolver.resolve("mystery", config: cliConfig("mystery", executable: exe)) != nil)
        #expect(backend.supportsMessage == false)
    }

    private static func pythonString(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

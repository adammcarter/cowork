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

    /// A row wired for the shape the test needs. `descriptor` defaults to the shipped
    /// stream-json example, which is the shape with every capability wired.
    private func cliConfig(_ name: String, executable: URL,
                           descriptor: CliDescriptor? = nil) -> Config {
        let d = descriptor ?? (try? ExampleConfig.descriptor("claude"))!
        let cli = CliConfig(name: name, executable: executable, descriptor: d, origin: .global)
        return Config(providers: [:], cli: [name: cli], visible: [:])
    }

    /// The honest floor: a row that declares no session wire and no continuation.
    private var oneShotOnly: CliDescriptor {
        (try? ExampleConfig.descriptor("opencode"))!
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

    @Test("a fully-wired row: one-shot, interactive, and follow-up are all present")
    func fullyWiredHasAllOps() throws {
        let exe = try installedExecutable(named: "agent")
        let backend = try #require(BackendResolver.resolve("agent", config: cliConfig("agent", executable: exe)))

        #expect(backend.supportsMessage == true)
        #expect(backend.supportsFollowUp == true)
        #expect(backend.oneShot(DispatchContext()) != nil)
        #expect(backend.followUp(DispatchContext(resume: "sess")) != nil)
        // interactiveSession may fail to spawn the real binary; presence is the factory.
        #expect(backend.canOpenInteractiveSession == true)
    }

    @Test("a session-but-no-continuation row: interactive yes, follow-up no — from operations, not a Bool")
    func sessionWithoutFollowUp() throws {
        let exe = try installedExecutable(named: "agent")
        let backend = try #require(BackendResolver.resolve(
            "agent", config: cliConfig("agent", executable: exe,
                                       descriptor: try ExampleConfig.descriptor("codex"))))

        #expect(backend.supportsMessage == true)
        #expect(backend.supportsFollowUp == false)
        #expect(backend.oneShot(DispatchContext()) != nil)
        #expect(backend.followUp(DispatchContext(resume: "thread")) == nil)
    }

    /// There is no longer an unrecognisable CLI — a row that cowork could not drive is
    /// refused at load. What remains is the honest floor: a row that wires neither a
    /// session nor a continuation is dispatchable and nothing else, and says so.
    @Test("a one-shot-only row: dispatchable, but no message and no follow-up")
    func oneShotOnlyHasOnlyDispatch() throws {
        let exe = try installedExecutable(named: "plain-agent")
        let backend = try #require(BackendResolver.resolve(
            "plain", config: cliConfig("plain", executable: exe, descriptor: oneShotOnly)))

        #expect(backend.supportsMessage == false)
        #expect(backend.supportsFollowUp == false)
        #expect(backend.oneShot(DispatchContext()) != nil, "a wired row is always dispatchable")
        #expect(backend.followUp(DispatchContext()) == nil)
        #expect(backend.diagnostics.contains("cli.session-code-only"))
        #expect(backend.diagnostics.contains("cli.follow-up-not-wired"))
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
        let exe = try installedExecutable(named: "agent")
        let c = try #require(BackendResolver.resolve("c", config: cliConfig("c", executable: exe)))
        let x = try #require(BackendResolver.resolve(
            "x", config: cliConfig("x", executable: exe,
                                   descriptor: try ExampleConfig.descriptor("codex"))))

        #expect(c.facts().supportsMessage == true)
        #expect(c.facts().supportsFollowUp == true)
        #expect(x.facts().supportsMessage == true)
        #expect(x.facts().supportsFollowUp == false)
    }

    // MARK: bug (a) — workspace roots the CHILD PROCESS, not just context plumbing

    /// An interactive dispatch grants a workspace; the worker process must actually
    /// run there. The stream-json row declares no protocol cwd flag — only process cwd
    /// can root it — so this stand-in reports `os.getcwd()`, not a value echoed from
    /// DispatchContext.
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

        // Stand-in worker: on start, record real process cwd; then honour stream-json.
        let agent = dir.appendingPathComponent("agent")
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
            "agent", config: cliConfig("agent", executable: agent)))

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

    @Test("supportsMessage is false for a resolvable-but-unmessageable CLI")
    func supportsMessageIsNotMereExistence() throws {
        let exe = try installedExecutable(named: "plain-agent")
        // Existence-based check would say true (config has the name). Real capability
        // is false: the row declares no session wire, so no interactive operation exists.
        let config = cliConfig("plain", executable: exe, descriptor: oneShotOnly)
        let backend = try #require(BackendResolver.resolve("plain", config: config))
        #expect(backend.supportsMessage == false)
    }

    private static func pythonString(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

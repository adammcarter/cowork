import Foundation
import Testing

@testable import CoworkCore

/// The `[cli.*.session]` block: the only way a row can claim to hold a conversation,
/// and the guardrails that keep that claim from being a quiet lie.
@Suite("CLI session config")
struct SessionConfigTests {
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func load(_ body: String) throws -> Config {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-session-cfg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let global = base.appendingPathComponent("config.toml")
        try write("""
        [cli.x]
        executable = "/opt/x/bin/x"
        args = ["run", "{task}"]
        output = "raw"
        verdict = "exit_code"
        \(body)
        """, to: global)
        return try Config.load(global: global, project: nil)
    }

    @Test("each protocol value selects its own wire", arguments: [
        ("stream_json", CliDescriptor.SessionSpec.Wire.streamJSON),
        ("acp", .acp),
    ])
    func protocolSelectsAWire(value: String, expected: CliDescriptor.SessionSpec.Wire) throws {
        let config = try load("""

        [cli.x.session]
        protocol = "\(value)"
        args = ["serve"]
        """)
        #expect(config.cli["x"]?.descriptor.session?.wire == expected)
        #expect(config.cli["x"]?.descriptor.session?.arguments == ["serve"])
    }

    /// MCP fixes the envelope but not which tool answers a prompt, so the two names
    /// are the one genuinely per-agent value a session row supplies.
    @Test("an mcp row carries its two tool names and its static tool arguments")
    func mcpCarriesToolNames() throws {
        let config = try load("""

        [cli.x.session]
        protocol = "mcp"
        args = ["mcp-server"]
        tool = "ask"
        reply_tool = "ask-again"
        tool_args = { mode = "fast" }
        """)
        let spec = try #require(config.cli["x"]?.descriptor.session)
        #expect(spec.wire == .mcp)
        #expect(spec.tool == "ask")
        #expect(spec.replyTool == "ask-again")
        #expect(spec.toolArguments == ["mode": "fast"])
    }

    /// An unknown protocol cannot fall back: speaking the wrong stateful wire at a
    /// worker produces a hang, not an error the user could act on.
    @Test("an unknown protocol is a load error, not a fallback")
    func unknownProtocolIsRefused() {
        #expect(throws: ConfigError.self) {
            try load("""

            [cli.x.session]
            protocol = "telepathy"
            args = ["serve"]
            """)
        }
    }

    @Test("a session block with no protocol, or no args, is a load error")
    func incompleteSessionIsRefused() {
        #expect(throws: ConfigError.self) {
            try load("""

            [cli.x.session]
            args = ["serve"]
            """)
        }
        #expect(throws: ConfigError.self) {
            try load("""

            [cli.x.session]
            protocol = "acp"
            """)
        }
    }

    /// A key that does not apply to the chosen wire is refused rather than ignored: a
    /// user who writes `tool` on an ACP row believes they configured something, and a
    /// silently-dropped key is the quietest possible way to be wrong.
    @Test("a key belonging to another protocol is refused, never silently ignored")
    func crossProtocolKeysAreRefused() {
        #expect(throws: ConfigError.self, "tool is mcp's") {
            try load("""

            [cli.x.session]
            protocol = "acp"
            args = ["stdio"]
            tool = "ask"
            """)
        }
        #expect(throws: ConfigError.self, "mcp continues by thread, not by argv") {
            try load("""

            [cli.x.session]
            protocol = "mcp"
            args = ["mcp-server"]
            tool = "ask"
            reply_tool = "ask-again"
            resume_args = ["--resume", "{resume}"]
            """)
        }
        #expect(throws: ConfigError.self, "mcp without its tool names cannot call anything") {
            try load("""

            [cli.x.session]
            protocol = "mcp"
            args = ["mcp-server"]
            """)
        }
    }

    /// `isolate` sets an environment variable by another door, and the runner applies
    /// it last — so without the same denylist `[cli.*.env]` enforces, it would win a
    /// key `env` is not allowed to touch at all.
    @Test("isolate may not point at a protected environment key",
          arguments: ["PATH", "HOME", "USER", "LANG", "DYLD_INSERT_LIBRARIES", "COWORK_ROOT"])
    func isolateRespectsTheDenylist(key: String) {
        #expect(throws: ConfigError.self) {
            try load("""

            [cli.x.isolate]
            var = "\(key)"
            """)
        }
    }

    @Test("an ordinary isolate variable is accepted")
    func isolateOrdinaryKeyIsAccepted() throws {
        let config = try load("""

        [cli.x.isolate]
        var = "XDG_CONFIG_HOME"
        """)
        #expect(config.cli["x"]?.descriptor.isolate?.variable == "XDG_CONFIG_HOME")
    }
}

/// The isolation directory: what it contains, and that it never outlives its worker.
@Suite("Isolation handle")
struct IsolationHandleTests {
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-isolate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The declarative replacement for cowork copying an agent's auth on its own
    /// initiative because it recognised the agent's name. A file seed has to work, or
    /// the property the implicit copy provided is silently lost: the dir would be
    /// created empty and the worker would run unauthenticated with no diagnostic.
    @Test("a single-file seed lands in the fresh dir, owner-read-only")
    func fileSeedIsCopied() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = dir.appendingPathComponent("auth.json")
        try "{\"token\":\"s\"}".write(to: secret, atomically: true, encoding: .utf8)

        let handle = try #require(IsolationHandle.make(variable: "AGENT_HOME", seed: secret))
        defer { handle.remove() }

        let copied = handle.directory.appendingPathComponent("auth.json")
        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(try String(contentsOf: copied, encoding: .utf8) == "{\"token\":\"s\"}")
        let perms = try FileManager.default
            .attributesOfItem(atPath: copied.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600, "it is a secret, and it is treated as one")
        #expect(handle.environmentEntry == "AGENT_HOME=\(handle.directory.path)")
    }

    /// A directory seed copies its CONTENTS, so the variable points at a directory
    /// shaped like the original rather than at one containing it.
    @Test("a directory seed contributes its contents, not itself")
    func directorySeedCopiesContents() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seed = dir.appendingPathComponent("seed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try "a".write(to: seed.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: seed.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)

        let handle = try #require(IsolationHandle.make(variable: "AGENT_HOME", seed: seed))
        defer { handle.remove() }

        let entries = try FileManager.default.contentsOfDirectory(atPath: handle.directory.path)
        #expect(Set(entries) == ["one.txt", "two.txt"])
        #expect(entries.contains("seed") == false, "the seed dir itself is not nested inside")
    }

    @Test("no seed means an empty 0700 dir, and remove really removes it")
    func noSeedAndRemoval() throws {
        let handle = try #require(IsolationHandle.make(variable: "AGENT_HOME", seed: nil))
        let perms = try FileManager.default
            .attributesOfItem(atPath: handle.directory.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o700, "an isolation dir may hold secrets: owner-only")
        #expect(try FileManager.default.contentsOfDirectory(atPath: handle.directory.path).isEmpty)

        handle.remove()
        #expect(FileManager.default.fileExists(atPath: handle.directory.path) == false)
    }
}

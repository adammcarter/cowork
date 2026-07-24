import Foundation
import Testing

@testable import CoworkCore

/// The generic `kind = "generic"` CLI descriptor: parsing every field, and the
/// security + coherence guardrails an arbitrary-executable backend demands
/// (origin gate, protected env keys, verdict/output coherence, built-in immutability).
@Suite("Generic CLI descriptor config")
struct CliDescriptorConfigTests {
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func inTemporaryTree(_ body: (URL, URL) throws -> Void) throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-gencfg-\(UUID().uuidString)")
        let global = base.appendingPathComponent("home/config.toml")
        let project = base.appendingPathComponent("project/cowork.toml")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try body(global, project)
    }

    // Test 1
    @Test("a generic row parses every descriptor field into a CliDescriptor")
    func genericRowParsesAllFields() throws {
        try inTemporaryTree { global, _ in
            try write("""
            [cli.opencode]
            executable = "~/.opencode/bin/opencode"
            kind = "generic"
            task_delivery = "argv"
            args = ["run", "{task}"]
            workspace_args = ["--cwd", "{workspace}"]
            resume_args = ["--session", "{resume}"]
            output = "json_field"
            output_field = "result"
            continuation_field = "sessionID"
            verdict = "stop_reason"

            [cli.opencode.env]
            OPENCODE_MODEL = "ollama/qwen2.5-coder:7b"
            SOME_TOKEN = "env:MY_TOKEN"

            [cli.opencode.isolate]
            var = "XDG_CONFIG_HOME"
            """, to: global)

            let config = try Config.load(global: global, project: nil)
            let d = try #require(config.cli["opencode"]?.descriptor)
            #expect(d.taskDelivery == .argv)
            #expect(d.baseArguments == ["run", "{task}"])
            #expect(d.workspaceArguments == ["--cwd", "{workspace}"])
            #expect(d.resumeArguments == ["--session", "{resume}"])
            #expect(d.output == .jsonField("result"))
            #expect(d.continuationField == "sessionID")
            #expect(d.verdict == .stopReason)
            #expect(d.isolate?.variable == "XDG_CONFIG_HOME")
            #expect(d.env.contains(.init(key: "OPENCODE_MODEL", value: .literal("ollama/qwen2.5-coder:7b"))))
            #expect(d.env.contains(.init(key: "SOME_TOKEN", value: .reference("MY_TOKEN"))))
        }
    }

    @Test("an unknown task_delivery/output/verdict value is a load error, not a fallback")
    func unknownEnumValueIsRefused() throws {
        for (field, value) in [("task_delivery", "telepathy"), ("output", "runes"), ("verdict", "vibes")] {
            try inTemporaryTree { global, _ in
                try write("""
                [cli.x]
                executable = "/opt/x/bin/x"
                kind = "generic"
                \(field) = "\(value)"
                """, to: global)
                #expect(throws: ConfigError.self) { try Config.load(global: global, project: nil) }
            }
        }
    }

    // Test 2 — origin gate (RCE fix)
    @Test("a project config may NOT declare a generic CLI (RCE origin gate)")
    func projectGenericCliIsRefused() throws {
        try inTemporaryTree { global, project in
            try write("[provider.omlx]\nbase_url = \"http://x\"", to: global)
            try write("""
            [cli.evil]
            executable = "/bin/sh"
            kind = "generic"
            task_delivery = "argv"
            args = ["-c", "{task}"]
            """, to: project)
            #expect(throws: ConfigError.self) { try Config.load(global: global, project: project) }
        }
    }

    @Test("a project config may still SELECT a built-in dialect")
    func projectBuiltinIsAllowed() throws {
        try inTemporaryTree { global, project in
            try write("[provider.omlx]\nbase_url = \"http://x\"", to: global)
            try write("""
            [cli.claude]
            executable = "/usr/bin/claude"
            kind = "claude"
            """, to: project)
            let config = try Config.load(global: global, project: project)
            #expect(config.cli["claude"]?.kind == .claude)
            #expect(config.cli["claude"]?.descriptor == nil)
        }
    }

    // Test 3 — protected env keys
    @Test("generic env may not set a protected key, but may set a literal or env:ref")
    func protectedEnvKeysAreRefused() throws {
        for key in ["PATH", "HOME", "DYLD_INSERT_LIBRARIES", "LD_PRELOAD", "COWORK_SECRET"] {
            try inTemporaryTree { global, _ in
                try write("""
                [cli.x]
                executable = "/opt/x/bin/x"
                kind = "generic"
                output = "raw"
                verdict = "exit_code"

                [cli.x.env]
                \(key) = "anything"
                """, to: global)
                #expect(throws: ConfigError.self,
                        "\(key) must be refused") { try Config.load(global: global, project: nil) }
            }
        }
        try inTemporaryTree { global, _ in
            try write("""
            [cli.x]
            executable = "/opt/x/bin/x"
            kind = "generic"
            output = "raw"
            verdict = "exit_code"

            [cli.x.env]
            MY_MODEL = "llama"
            MY_TOKEN = "env:REAL_TOKEN"
            """, to: global)
            let d = try #require(try Config.load(global: global, project: nil).cli["x"]?.descriptor)
            #expect(d.env.contains(.init(key: "MY_MODEL", value: .literal("llama"))))
            #expect(d.env.contains(.init(key: "MY_TOKEN", value: .reference("REAL_TOKEN"))))
        }
    }

    // Test 4 — coherence validation
    @Test("incoherent verdict/output (and {task} misuse) pairs are load errors")
    func incoherentPairsAreRefused() throws {
        let bad = [
            "verdict = \"declared_result\"\noutput = \"raw\"",
            "verdict = \"stop_reason\"\noutput = \"raw\"",
            "verdict = \"exit_code\"\noutput = \"stream_json_result\"",
            "task_delivery = \"stdin_raw\"\nargs = [\"exec\", \"{task}\"]",
            "output = \"json_field\"",   // json_field without output_field
        ]
        for body in bad {
            try inTemporaryTree { global, _ in
                try write("""
                [cli.x]
                executable = "/opt/x/bin/x"
                kind = "generic"
                \(body)
                """, to: global)
                #expect(throws: ConfigError.self,
                        "incoherent: \(body)") { try Config.load(global: global, project: nil) }
            }
        }
    }

    @Test("a coherent declared_result + stream_json_result generic row is accepted")
    func coherentPairIsAccepted() throws {
        try inTemporaryTree { global, _ in
            try write("""
            [cli.x]
            executable = "/opt/x/bin/x"
            kind = "generic"
            output = "stream_json_result"
            verdict = "declared_result"
            """, to: global)
            let d = try #require(try Config.load(global: global, project: nil).cli["x"]?.descriptor)
            #expect(d.verdict == .declaredResult)
            #expect(d.output == .streamJSONResult)
        }
    }

    /// The `stop_reason` strategy is named for the SHAPE — "a field declaring why
    /// generation stopped" — so the field's SPELLING has to be configurable. Welding
    /// one agent's spelling into code would make every other agent's dispatch fail as
    /// `cli.stop-reason.absent` while the vocabulary claimed to be generic. It selects
    /// WHERE to read, never WHAT the reading means: the closed set of tokens and the
    /// verdict they produce stay in reviewed Swift.
    @Test("stop_reason_field selects which key the declaration is read from, defaulting to stopReason")
    func stopReasonFieldIsConfigurable() throws {
        try inTemporaryTree { global, _ in
            try write("""
            [cli.x]
            executable = "/opt/x/bin/x"
            kind = "generic"
            output = "json_field"
            output_field = "text"
            verdict = "stop_reason"
            """, to: global)
            let d = try #require(try Config.load(global: global, project: nil).cli["x"]?.descriptor)
            #expect(d.stopReasonField == "stopReason")
        }
        try inTemporaryTree { global, _ in
            try write("""
            [cli.x]
            executable = "/opt/x/bin/x"
            kind = "generic"
            output = "json_field"
            output_field = "text"
            verdict = "stop_reason"
            stop_reason_field = "finish_reason"
            """, to: global)
            let d = try #require(try Config.load(global: global, project: nil).cli["x"]?.descriptor)
            #expect(d.stopReasonField == "finish_reason")

            // and the driver really reads THAT key: an agent spelling it differently
            // must not silently fail as a missing declaration.
            let driver = ConfiguredDriver(name: "x", executable: URL(fileURLWithPath: "/opt/x/bin/x"),
                                          descriptor: d)
            let out = driver.parse(output: Data("{\"text\":\"a\",\"finish_reason\":\"EndTurn\"}".utf8),
                                   exitStatus: 0)
            #expect(out.state == .succeeded)
            #expect(out.diagnostics.isEmpty)

            let wrongKey = driver.parse(output: Data("{\"text\":\"a\",\"stopReason\":\"EndTurn\"}".utf8),
                                        exitStatus: 0)
            #expect(wrongKey.state == .failed)
            #expect(wrongKey.diagnostics.contains("cli.stop-reason.absent"))
        }
    }

    // Test 5 — built-in immutability
    @Test("a built-in row carrying a generic field is a load error")
    func builtinCarryingGenericFieldIsRefused() throws {
        try inTemporaryTree { global, _ in
            try write("""
            [cli.claude]
            executable = "/usr/bin/claude"
            kind = "claude"
            args = ["--hacked"]
            """, to: global)
            #expect(throws: ConfigError.self) { try Config.load(global: global, project: nil) }
        }
    }

    @Test("a generic row may not point at a built-in executable name")
    func genericAtBuiltinExecutableIsRefused() throws {
        try inTemporaryTree { global, _ in
            try write("""
            [cli.sneaky]
            executable = "/somewhere/claude"
            kind = "generic"
            output = "raw"
            verdict = "exit_code"
            """, to: global)
            #expect(throws: ConfigError.self) { try Config.load(global: global, project: nil) }
        }
    }

    @Test("a plain built-in row (no generic fields) still resolves as today")
    func builtinRowUnchanged() throws {
        try inTemporaryTree { global, _ in
            try write("""
            [cli.grok]
            executable = "/usr/local/bin/grok"
            """, to: global)
            let config = try Config.load(global: global, project: nil)
            #expect(config.cli["grok"]?.kind == .grok)
            #expect(config.cli["grok"]?.descriptor == nil)
        }
    }

    // A CLI descriptor's env:NAME must survive the hop into the supervisor process.
    // Without this the reference resolves to empty in the worker, and the user who
    // exported their variable exactly as the config says gets a silently unset var.
    @Test("a generic CLI's env:NAME reference is named in the environment the supervisor needs")
    func genericEnvReferenceIsForwarded() throws {
        try inTemporaryTree { global, _ in
            try write("""
            [provider.omlx]
            base_url = "http://x"
            credential = "env:OMLX_KEY"

            [cli.x]
            executable = "/opt/x/bin/x"
            kind = "generic"
            output = "raw"
            verdict = "exit_code"

            [cli.x.env]
            TOOL_TOKEN = "env:MY_TOOL_TOKEN"
            PLAIN = "not-a-reference"
            """, to: global)

            let config = try Config.load(global: global, project: nil)
            let names = config.referencedEnvironmentNames
            #expect(names.contains("OMLX_KEY"), "a provider credential reference is still forwarded")
            #expect(names.contains("MY_TOOL_TOKEN"),
                    "a CLI descriptor's env:NAME must be forwarded too, or it resolves to empty")
            #expect(!names.contains("PLAIN"), "a literal is not an environment reference")
            #expect(!names.contains("not-a-reference"))
        }
    }
}

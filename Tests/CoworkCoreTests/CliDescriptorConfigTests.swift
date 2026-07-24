import Foundation
import Testing

@testable import CoworkCore

/// The CLI descriptor: parsing every field, and the security + coherence guardrails
/// an arbitrary-executable backend demands (origin gate, protected env keys,
/// verdict/output coherence, an argv that really delivers the task).
///
/// There is no longer a privileged kind of row to contrast these against — every
/// `[cli.*]` row is a descriptor, so every row is held to all of it.
@Suite("CLI descriptor config")
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
    @Test("a row parses every descriptor field into a CliDescriptor")
    func genericRowParsesAllFields() throws {
        try inTemporaryTree { global, _ in
            try write("""
            [cli.opencode]
            executable = "~/.opencode/bin/opencode"
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
                args = ["run", "{task}"]
                \(field) = "\(value)"
                """, to: global)
                #expect(throws: ConfigError.self) { try Config.load(global: global, project: nil) }
            }
        }
    }

    // Test 2 — origin gate (RCE fix)
    /// A CLI row authors argv and environment for an arbitrary executable — strictly
    /// worse than the project-credential attack ADR 005 already refuses. With no
    /// built-ins left there is no weaker "select a sealed dialect" row that could
    /// safely be allowed, so the whole table kind is global-only. A project loses
    /// nothing: it may still DISPATCH any globally-declared CLI by name.
    @Test("a project config may NOT declare a CLI at all (RCE origin gate)")
    func projectCliIsRefused() throws {
        try inTemporaryTree { global, project in
            try write("[provider.omlx]\nbase_url = \"http://x\"", to: global)
            try write("""
            [cli.evil]
            executable = "/bin/sh"
            task_delivery = "argv"
            args = ["-c", "{task}"]
            """, to: project)
            #expect(throws: ConfigError.self) { try Config.load(global: global, project: project) }
        }
    }

    /// The minimal row too: refusal is about WHERE the row is, not how elaborate it
    /// is, so a project cannot slip one past by declaring almost nothing.
    @Test("even a bare project CLI row is refused")
    func bareProjectCliIsRefused() throws {
        try inTemporaryTree { global, project in
            try write("[provider.omlx]\nbase_url = \"http://x\"", to: global)
            try write("""
            [cli.mine]
            executable = "/usr/bin/mine"
            """, to: project)
            #expect(throws: ConfigError.self) { try Config.load(global: global, project: project) }
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
                args = ["run", "{task}"]
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
            args = ["run", "{task}"]
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
        // Each body is INCOHERENT and nothing else: every row below carries a valid
        // argv, so a refusal can only be the coherence rule under test.
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
                args = ["run", "{task}"]
                \(body)
                """, to: global)
                #expect(throws: ConfigError.self,
                        "incoherent: \(body)") { try Config.load(global: global, project: nil) }
            }
        }
    }

    @Test("a coherent declared_result + stream_json_result row is accepted")
    func coherentPairIsAccepted() throws {
        try inTemporaryTree { global, _ in
            try write("""
            [cli.x]
            executable = "/opt/x/bin/x"
            args = ["run", "{task}"]
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
            args = ["run", "{task}"]
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
            args = ["run", "{task}"]
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

    // Test 5 — a row must actually be able to run
    /// A row that describes no invocation used to fall back to a compiled-in wire.
    /// With none left, an empty argv launches an interactive agent on a pipe that
    /// never answers: the dispatch hangs to its deadline and reports a timeout. A
    /// load error naming the missing key is the actionable version of that.
    @Test("a row with no args is a load error, not an empty invocation")
    func emptyArgsIsRefused() throws {
        try inTemporaryTree { global, _ in
            try write("""
            [cli.bare]
            executable = "/usr/bin/bare"
            """, to: global)
            #expect(throws: ConfigError.self) { try Config.load(global: global, project: nil) }
        }
    }

    /// The other half of the same hole: argv delivery with no `{task}` anywhere runs
    /// the worker without ever telling it what to do. It exits 0, and an exit-code
    /// verdict calls that a success — work reported done that was never asked for.
    @Test("argv delivery with no {task} argument is a load error")
    func argvWithoutTaskIsRefused() throws {
        try inTemporaryTree { global, _ in
            try write("""
            [cli.silent]
            executable = "/usr/bin/silent"
            args = ["run", "--quiet"]
            output = "raw"
            verdict = "exit_code"
            """, to: global)
            #expect(throws: ConfigError.self) { try Config.load(global: global, project: nil) }
        }
    }

    /// The executable's name says nothing about the wire any more, so a row may point
    /// at any binary it likes — including one sharing a name with someone else's
    /// agent. What it gets is exactly what it declared.
    @Test("a row may point at any executable: the name carries no wire")
    func anyExecutableIsAllowed() throws {
        try inTemporaryTree { global, _ in
            try write("""
            [cli.sneaky]
            executable = "/somewhere/claude"
            args = ["run", "{task}"]
            output = "raw"
            verdict = "exit_code"
            """, to: global)
            let config = try Config.load(global: global, project: nil)
            #expect(config.cli["sneaky"]?.descriptor.baseArguments == ["run", "{task}"])
            #expect(config.cli["sneaky"]?.descriptor.verdict == .exitCode)
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
            args = ["run", "{task}"]
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

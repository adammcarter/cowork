import Darwin
import Foundation
import Testing

@testable import CoworkCore

/// A config-wired CLI actually dispatching: the isolation directory's lifecycle, the
/// safety of argument substitution, and the flagship opencode row working end to end
/// from configuration with no new Swift.
@Suite("Generic CLI dispatch")
struct GenericCliDispatchTests {
    /// Records the environment/argv it was handed and returns a scripted result.
    final class FakeSpawner: CliProcessSpawning, @unchecked Sendable {
        private let lock = NSLock()
        private var _environment: [String] = []
        private var _arguments: [String] = []
        private var _stdin: Data?
        var environment: [String] { lock.lock(); defer { lock.unlock() }; return _environment }
        var arguments: [String] { lock.lock(); defer { lock.unlock() }; return _arguments }
        var stdin: Data? { lock.lock(); defer { lock.unlock() }; return _stdin }
        /// Observed while the worker was "running" — proves the dir existed during the
        /// dispatch and not merely that it was cleaned up afterwards.
        private var _isolationDirExisted = false
        var isolationDirExisted: Bool { lock.lock(); defer { lock.unlock() }; return _isolationDirExisted }

        let result: CliProcessResult
        init(result: CliProcessResult) { self.result = result }

        func run(executable: URL, arguments: [String], environment: [String],
                 stdin: Data?, workingDirectory: String?,
                 cpuSecondsLimit: rlim_t, timeout: TimeInterval) -> CliProcessResult {
            lock.lock()
            _environment = environment
            _arguments = arguments
            _stdin = stdin
            if let entry = environment.first(where: { $0.hasPrefix("XDG_CONFIG_HOME=") }) {
                let path = String(entry.dropFirst("XDG_CONFIG_HOME=".count))
                _isolationDirExisted = FileManager.default.fileExists(atPath: path)
            }
            lock.unlock()
            return result
        }
    }

    private func opencodeDescriptor(isolate: CliDescriptor.Isolation? = nil,
                                    seedSetting: String? = nil) -> CliDescriptor {
        CliDescriptor(
            taskDelivery: .argv,
            baseArguments: ["run", "{task}"],
            workspaceArguments: ["--cwd", "{workspace}"],
            env: [.init(key: "OPENCODE_MODEL", value: .literal("ollama/qwen2.5-coder:7b")),
                  .init(key: "OPENCODE_PERMISSION", value: .literal("allow"))],
            output: .raw,
            verdict: .exitCode,
            isolate: isolate)
    }

    // Test 16 — the flagship row works end to end from config
    @Test("the opencode row dispatches one-shot from config alone and reports its answer")
    func opencodeDispatchesEndToEnd() {
        let spawner = FakeSpawner(result: .init(output: Data("HARNESS_DONE\n".utf8),
                                                exitStatus: 0, timedOut: false))
        let driver = ConfiguredDriver(name: "opencode",
                                      executable: URL(fileURLWithPath: "/o/bin/opencode"),
                                      descriptor: opencodeDescriptor())
        let runner = CliRunner(executable: URL(fileURLWithPath: "/o/bin/opencode"),
                               driver: driver, spawn: spawner)
        let ws = Workspace(root: URL(fileURLWithPath: "/tmp/ws"), writable: true)
        let outcome = runner.run(task: "write result.txt", workspace: ws)

        #expect(outcome.state == .succeeded)
        #expect(outcome.text == "HARNESS_DONE\n")
        #expect(spawner.arguments == ["run", "write result.txt", "--cwd", "/tmp/ws"])
        #expect(spawner.environment.contains("OPENCODE_MODEL=ollama/qwen2.5-coder:7b"))
        #expect(spawner.environment.contains("OPENCODE_PERMISSION=allow"))
    }

    @Test("a nonzero exit from a config-wired CLI is a named failure, never a quiet success")
    func opencodeFailureIsNamed() {
        let spawner = FakeSpawner(result: .init(output: Data("boom".utf8), exitStatus: 2 << 8, timedOut: false))
        let driver = ConfiguredDriver(name: "opencode",
                                      executable: URL(fileURLWithPath: "/o/bin/opencode"),
                                      descriptor: opencodeDescriptor())
        let outcome = CliRunner(executable: URL(fileURLWithPath: "/o/bin/opencode"),
                                driver: driver, spawn: spawner).run(task: "t", workspace: nil)
        #expect(outcome.state == .failed)
        #expect(outcome.diagnostics == ["cli.exit", "exit=2"])
    }

    // Test 13 — isolation lifecycle
    @Test("the isolation dir exists during the dispatch and is removed on every exit path",
          arguments: [false, true])
    func isolationDirIsCreatedAndRemoved(timedOut: Bool) {
        let spawner = FakeSpawner(result: .init(output: Data("out".utf8),
                                                exitStatus: 0, timedOut: timedOut))
        let driver = ConfiguredDriver(
            name: "opencode", executable: URL(fileURLWithPath: "/o/bin/opencode"),
            descriptor: opencodeDescriptor(isolate: .init(variable: "XDG_CONFIG_HOME", seed: nil)))
        let outcome = CliRunner(executable: URL(fileURLWithPath: "/o/bin/opencode"),
                                driver: driver, spawn: spawner).run(task: "t", workspace: nil)

        #expect(spawner.isolationDirExisted, "the worker ran with a real isolated config dir")
        let entry = spawner.environment.first { $0.hasPrefix("XDG_CONFIG_HOME=") }
        let path = entry.map { String($0.dropFirst("XDG_CONFIG_HOME=".count)) }
        #expect(path != nil)
        #expect(FileManager.default.fileExists(atPath: path ?? "") == false,
                "leak-on-\(timedOut ? "timeout" : "completion"): the dir must not outlive the dispatch")
        #expect(outcome.state == (timedOut ? .timedOut : .succeeded))
    }

    @Test("a seeded isolation dir is 0700 and carries the seed's contents")
    func seededIsolationIsPrivate() throws {
        let fm = FileManager.default
        let seed = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-seed-\(UUID().uuidString)")
        try fm.createDirectory(at: seed, withIntermediateDirectories: true)
        try "settings".write(to: seed.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: seed) }

        let handle = try #require(IsolationHandle.make(variable: "XDG_CONFIG_HOME", seed: seed))
        defer { handle.remove() }
        #expect(fm.fileExists(atPath: handle.directory.appendingPathComponent("config.json").path),
                "the seed's contents are copied in")
        let perms = try fm.attributesOfItem(atPath: handle.directory.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o700, "an isolation dir may hold secrets: owner-only")
    }

    // Test 14 — substitution safety
    @Test("substitution is whole-arg: a task containing a placeholder cannot inject one")
    func substitutionIsWholeArgOnly() {
        let driver = ConfiguredDriver(
            name: "x", executable: URL(fileURLWithPath: "/x/bin/x"),
            descriptor: CliDescriptor(taskDelivery: .argv, baseArguments: ["run", "{task}"],
                                      workspaceArguments: ["--cwd", "{workspace}"],
                                      output: .raw, verdict: .exitCode))
        // The task is itself a placeholder string, and contains shell metacharacters.
        let hostile = "{workspace} ; rm -rf / && echo $(whoami)"
        let inv = driver.invocation(task: hostile, workspace: nil, resume: nil)
        #expect(inv.arguments == ["run", hostile],
                "the value lands as ONE argument, verbatim — no re-expansion, no split")
        #expect(inv.arguments.count == 2, "no extra arguments were injected")
    }

    @Test("an argument that merely contains a token is left verbatim")
    func partialTokenIsInert() {
        let driver = ConfiguredDriver(
            name: "x", executable: URL(fileURLWithPath: "/x/bin/x"),
            descriptor: CliDescriptor(taskDelivery: .argv,
                                      baseArguments: ["--label=pre{task}post", "{task}"],
                                      output: .raw, verdict: .exitCode))
        let inv = driver.invocation(task: "T", workspace: nil, resume: nil)
        #expect(inv.arguments == ["--label=pre{task}post", "T"],
                "only an argument that IS the token is substituted")
    }

    @Test("an unsupplied workspace/resume leaves its optional segment off entirely")
    func absentValuesDropTheirSegments() {
        let driver = ConfiguredDriver(
            name: "x", executable: URL(fileURLWithPath: "/x/bin/x"),
            descriptor: CliDescriptor(taskDelivery: .argv, baseArguments: ["run", "{task}"],
                                      workspaceArguments: ["--cwd", "{workspace}"],
                                      resumeArguments: ["--session", "{resume}"],
                                      output: .raw, verdict: .exitCode))
        let inv = driver.invocation(task: "T", workspace: nil, resume: nil)
        #expect(inv.arguments == ["run", "T"], "no dangling flags with empty values")
    }

    // Test 15 — the resolution gate still derives operations from the descriptor
    @Test("a resolved generic backend is dispatchable but not messageable, and says why")
    func resolvedGenericBackendGate() {
        let cli = CliConfig(name: "opencode", executable: URL(fileURLWithPath: "/o/bin/opencode"),
                            descriptor: opencodeDescriptor(), origin: .global)
        let backend = BackendResolver.resolveCli(cli)
        #expect(backend.oneShot(DispatchContext()) != nil, "it can be dispatched")
        #expect(backend.supportsMessage == false, "this row declares no session wire")
        #expect(backend.supportsFollowUp == false, "this row wires no continuation handle")
        #expect(backend.diagnostics.contains("cli.session-code-only"))
        #expect(backend.diagnostics.contains("cli.verdict-unverified"),
                "an exit-code verdict is asserted by config, never proven by it")
    }
}

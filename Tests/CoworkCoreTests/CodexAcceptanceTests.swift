import Darwin
import Foundation
import Testing

@testable import CoworkCore

/// The payoff: codex became a full one-shot backend — reported by capabilities and
/// assembled for dispatch — by adding a rule (`Verdict.exitCode`), a driver
/// (`CodexOneShotDriver`), and an agent plus one registry line. No edit to the
/// engine (`CliRunner`, `InteractiveSession`, `LiveSession`, `Runner`,
/// `SuperviseMode`, `ContainedProcess`) and none to `Capabilities`.
@Suite("codex-exec acceptance")
struct CodexAcceptanceTests {
    struct NoProbe: EndpointProbe {
        func get(url: URL, headers: [String: String]) async throws -> ProbeResponse {
            ProbeResponse(status: 200, body: Data())
        }
    }

    /// Records what it was asked to run and returns a scripted result.
    final class FakeSpawner: CliProcessSpawning, @unchecked Sendable {
        struct Call { let arguments: [String]; let stdin: Data? }
        private let lock = NSLock()
        private var _call: Call?
        var call: Call? { lock.lock(); defer { lock.unlock() }; return _call }
        let result: CliProcessResult
        init(result: CliProcessResult) { self.result = result }
        func run(executable: URL, arguments: [String], environment: [String],
                 stdin: Data?, workingDirectory: String?,
                 cpuSecondsLimit: rlim_t, timeout: TimeInterval) -> CliProcessResult {
            lock.lock(); _call = Call(arguments: arguments, stdin: stdin); lock.unlock()
            return result
        }
    }

    private func installedCodex() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("codex")
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Capabilities reports codex with no edit to Capabilities: the registry line is
    /// the whole change, and the facts fall out of `agent is SessionCapable`.
    @Test("capabilities reports a configured codex as available and messageable")
    func capabilitiesReportsCodex() async throws {
        let codex = try installedCodex()
        let cli = CliConfig(name: "codex", executable: codex, kind: .codex, origin: .global)
        let config = Config(providers: [:], cli: ["codex": cli], visible: [:])

        let facts = try await Capabilities.facts(backend: "codex", config: config,
                                                 probe: NoProbe(), secrets: { _ in nil })

        #expect(facts[0].available == true)
        #expect(facts[0].supportsMessage == true, "codex's MCP session is built — backed by SessionCapable")
        #expect(facts[0].diagnostics.contains("cli.one-shot") == false, "codex is no longer one-shot only")
        #expect(facts[0].diagnostics.contains("cli.kind-mismatch") == false, "kind matches the executable")
    }

    /// The dispatch path, assembled from the registry with no engine edit: the codex
    /// agent's one-shot, run through the generic `CliRunner`, invokes `codex exec`
    /// with the raw task on stdin.
    @Test("dispatch assembles `codex exec` with the task on stdin and returns the driver's verdict")
    func dispatchAssemblesCodexExec() throws {
        let codex = URL(fileURLWithPath: "/usr/local/bin/codex")
        let cli = CliConfig(name: "codex", executable: codex,
                            kind: CliDialect(executable: codex), origin: .global)
        let agent = try #require(CliRegistry.agent(for: cli))
        let spawner = FakeSpawner(result: CliProcessResult(output: Data("done".utf8),
                                                           exitStatus: 0, timedOut: false))
        let runner = CliRunner(executable: codex, driver: agent.oneShot(), spawn: spawner)

        let outcome = runner.run(task: "port the parser", workspace: nil)

        #expect(spawner.call?.arguments == ["exec", "--ignore-user-config",
                                            "--dangerously-bypass-approvals-and-sandbox",
                                            "--skip-git-repo-check"])
        #expect(spawner.call?.stdin == Data("port the parser".utf8))
        #expect(outcome.state == .succeeded)
        #expect(outcome.text == "done")
    }
}

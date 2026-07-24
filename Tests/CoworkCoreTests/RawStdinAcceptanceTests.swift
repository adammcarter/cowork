import Darwin
import Foundation
import Testing

@testable import CoworkCore

/// The payoff, now complete: a raw-stdin agent with an MCP session becomes a full
/// backend — reported by capabilities and assembled for dispatch — from a config row
/// and nothing else. Adding it once cost a verdict rule, a driver and a registry
/// line; it now costs a paragraph of TOML. No edit to the engine (`CliRunner`,
/// `InteractiveSession`, `LiveSession`, `Runner`, `SuperviseMode`,
/// `ContainedProcess`) and none to `Capabilities`.
@Suite("raw-stdin backend acceptance")
struct RawStdinAcceptanceTests {
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

    private func installedAgent() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-rawstdin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("agent")
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Capabilities reports the row with no edit to Capabilities: the config row is
    /// the whole change, and the facts fall out of the descriptor's session wire.
    @Test("capabilities reports a configured raw-stdin agent as available and messageable")
    func capabilitiesReportsTheRow() async throws {
        let executable = try installedAgent()
        let cli = CliConfig(name: "agent", executable: executable,
                            descriptor: try ExampleConfig.descriptor("codex"), origin: .global)
        let config = Config(providers: [:], cli: ["agent": cli], visible: [:])

        let facts = try await Capabilities.facts(backend: "agent", config: config,
                                                 probe: NoProbe(), secrets: { _ in nil })

        #expect(facts[0].available == true)
        #expect(facts[0].supportsMessage == true, "the row declares an MCP session wire")
        #expect(facts[0].diagnostics.contains("cli.session-code-only") == false)
        #expect(facts[0].diagnostics.contains("cli.session-unverified") == true,
                "config ASSERTS the wire; nothing here has proven the binary answers on it")
    }

    /// The dispatch path, assembled from the config row with no engine edit: the
    /// agent's one-shot, run through the generic `CliRunner`, invokes the declared
    /// argv with the raw task on stdin.
    @Test("dispatch assembles the declared argv with the task on stdin and returns the driver's verdict")
    func dispatchAssemblesTheDeclaredArgv() throws {
        let executable = URL(fileURLWithPath: "/usr/local/bin/agent")
        let cli = CliConfig(name: "agent", executable: executable,
                            descriptor: try ExampleConfig.descriptor("codex"), origin: .global)
        let agent = ConfiguredAgent(cli)
        let spawner = FakeSpawner(result: CliProcessResult(output: Data("done".utf8),
                                                           exitStatus: 0, timedOut: false))
        let runner = CliRunner(executable: executable, driver: agent.oneShot(), spawn: spawner)

        let outcome = runner.run(task: "port the parser", workspace: nil)

        #expect(spawner.call?.arguments == ["exec", "--ignore-user-config",
                                            "--dangerously-bypass-approvals-and-sandbox",
                                            "--skip-git-repo-check"])
        #expect(spawner.call?.stdin == Data("port the parser".utf8))
        #expect(outcome.state == .succeeded)
        #expect(outcome.text == "done")
    }
}

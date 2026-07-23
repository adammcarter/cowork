import Darwin
import Foundation
import Testing

@testable import CoworkCore

/// The generic runner that owns the duplicated 80%: the environment allowlist, the
/// contained spawn, and the timeout short-circuit. The process boundary is
/// injected, so this unit-tests without spawning anything — the containment itself
/// is `ContainedProcess`'s concern and is not re-tested here.
@Suite("CliRunner")
struct CliRunnerTests {
    /// Records what it was asked to run and returns a scripted result.
    final class FakeSpawner: CliProcessSpawning, @unchecked Sendable {
        struct Call { let executable: URL; let arguments: [String]
                      let environment: [String]; let stdin: Data?
                      let workingDirectory: String? }
        private let lock = NSLock()
        private var _call: Call?
        var call: Call? { lock.lock(); defer { lock.unlock() }; return _call }
        let result: CliProcessResult
        init(result: CliProcessResult) { self.result = result }

        func run(executable: URL, arguments: [String], environment: [String],
                 stdin: Data?, workingDirectory: String?,
                 cpuSecondsLimit: rlim_t, timeout: TimeInterval) -> CliProcessResult {
            lock.lock()
            _call = Call(executable: executable, arguments: arguments,
                         environment: environment, stdin: stdin,
                         workingDirectory: workingDirectory)
            lock.unlock()
            return result
        }
    }

    /// A driver that records the resume it was handed and returns fixed values.
    struct RecordingDriver: OneShotDriver {
        let invocationToReturn: Invocation
        let outcomeToReturn: CliOutcome
        let seenResume: Box<String?> = Box()
        var deadlineDiagnostic: String { "stub.deadline" }
        func invocation(task: String, workspace: Workspace?, resume: String?) -> Invocation {
            seenResume.value = .some(resume)
            return invocationToReturn
        }
        func parse(output: Data, exitStatus: Int32) -> CliOutcome { outcomeToReturn }
    }

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock(); private var stored: T?
        var value: T? { get { lock.lock(); defer { lock.unlock() }; return stored }
                        set { lock.lock(); stored = newValue; lock.unlock() } }
    }

    private let ok = CliProcessResult(output: Data("out".utf8), exitStatus: 0, timedOut: false)

    @Test("the workspace grant reaches the spawner as the child's working directory — for every dialect")
    func workspaceGrantReachesSpawner() throws {
        let ws = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-runner-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }

        let spawner = FakeSpawner(result: ok)
        let driver = RecordingDriver(
            invocationToReturn: Invocation(arguments: []),
            outcomeToReturn: CliOutcome(state: .succeeded, text: "", diagnostics: []))
        let runner = CliRunner(executable: URL(fileURLWithPath: "/bin/agent"),
                               driver: driver, spawn: spawner)
        _ = runner.run(task: "t", workspace: Workspace(root: ws, writable: true))
        #expect(spawner.call?.workingDirectory == ws.path,
                "the grant must become the spawned child's working directory")
    }

    @Test("no workspace means no working directory — the child inherits cowork's cwd")
    func noWorkspaceMeansNoWorkingDirectory() {
        let spawner = FakeSpawner(result: ok)
        let driver = RecordingDriver(
            invocationToReturn: Invocation(arguments: []),
            outcomeToReturn: CliOutcome(state: .succeeded, text: "", diagnostics: []))
        let runner = CliRunner(executable: URL(fileURLWithPath: "/bin/agent"),
                               driver: driver, spawn: spawner)
        _ = runner.run(task: "t", workspace: nil)
        #expect(spawner.call?.workingDirectory == nil)
    }

    @Test("run hands the driver's arguments and stdin to the spawner and returns the driver's parse")
    func passesInvocationAndReturnsParse() {
        let spawner = FakeSpawner(result: ok)
        let driver = RecordingDriver(
            invocationToReturn: Invocation(arguments: ["-p", "hi"], stdin: Data("in".utf8)),
            outcomeToReturn: CliOutcome(state: .succeeded, text: "done", diagnostics: []))
        let runner = CliRunner(executable: URL(fileURLWithPath: "/bin/agent"),
                               driver: driver, spawn: spawner)

        let outcome = runner.run(task: "hi", workspace: nil)
        #expect(outcome.state == .succeeded)
        #expect(outcome.text == "done")
        #expect(spawner.call?.arguments == ["-p", "hi"])
        #expect(spawner.call?.stdin == Data("in".utf8))
        #expect(spawner.call?.executable.path == "/bin/agent")
    }

    @Test("the environment is the shared allowlist, and a dialect's extra entry overrides by key")
    func environmentAllowlistAndOverride() {
        let spawner = FakeSpawner(result: ok)
        let driver = RecordingDriver(
            invocationToReturn: Invocation(arguments: [], stdin: nil,
                                           extraEnvironment: ["PATH=/opt/grok/bin:/usr/bin"]),
            outcomeToReturn: CliOutcome(state: .succeeded, text: "", diagnostics: []))
        let runner = CliRunner(executable: URL(fileURLWithPath: "/bin/agent"),
                               driver: driver, spawn: spawner)

        _ = runner.run(task: "t", workspace: nil)
        let env = spawner.call?.environment ?? []
        #expect(env.contains("PATH=/opt/grok/bin:/usr/bin"), "the dialect's PATH overrides the base one")
        #expect(env.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin") == false, "not two PATH entries")
        #expect(env.contains("HOME=\(NSHomeDirectory())"))
        #expect(env.contains("USER=\(NSUserName())"))
        #expect(env.contains("LANG=en_US.UTF-8"))
    }

    @Test("a timed-out spawn short-circuits to a timedOut outcome carrying the driver's deadline diagnostic")
    func timeoutShortCircuits() {
        let spawner = FakeSpawner(result: CliProcessResult(output: Data("partial".utf8),
                                                           exitStatus: 0, timedOut: true))
        let driver = RecordingDriver(
            invocationToReturn: Invocation(arguments: []),
            // parse must NOT be consulted on timeout; return a distinct outcome to prove it.
            outcomeToReturn: CliOutcome(state: .succeeded, text: "should-not-appear", diagnostics: []))
        let runner = CliRunner(executable: URL(fileURLWithPath: "/bin/agent"),
                               driver: driver, spawn: spawner, timeout: 42)

        let outcome = runner.run(task: "t", workspace: nil)
        #expect(outcome.state == .timedOut)
        #expect(outcome.text == "")
        #expect(outcome.diagnostics == ["stub.deadline", "timeout=42s"])
        #expect(outcome.transcript == "partial")
    }

    @Test("resume is threaded through to the driver's invocation")
    func resumeIsThreaded() {
        let spawner = FakeSpawner(result: ok)
        let driver = RecordingDriver(
            invocationToReturn: Invocation(arguments: []),
            outcomeToReturn: CliOutcome(state: .succeeded, text: "", diagnostics: []))
        let runner = CliRunner(executable: URL(fileURLWithPath: "/bin/agent"),
                               driver: driver, spawn: spawner, resume: "sess-7")
        _ = runner.run(task: "t", workspace: nil)
        #expect(driver.seenResume.value == .some("sess-7"))
    }
}

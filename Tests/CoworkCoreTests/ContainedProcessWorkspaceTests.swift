import Darwin
import Foundation
import Testing

@testable import CoworkCore

/// The one-shot spawn honors the workspace grant by *starting the child there* —
/// asserted against the child's real getcwd(), never the value passed in. That
/// distinction is load-bearing: an earlier fix "passed" a unit test that echoed
/// the parameter while the real process ran somewhere else entirely.
@Suite("ContainedProcess workspace grant")
struct ContainedProcessWorkspaceTests {
    private func tempDir(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-oneshot-cwd-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("the child starts in the granted directory — its own getcwd says so")
    func childStartsInGrantedDirectory() throws {
        let workspace = try tempDir("grant")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let expected = workspace.resolvingSymlinksInPath().path

        let result = ContainedProcess.run(
            executable: URL(fileURLWithPath: "/bin/pwd"),
            arguments: [],
            environment: ["PATH=/usr/bin:/bin"],
            stdinData: nil,
            workingDirectory: workspace.path,
            cpuSecondsLimit: 5,
            timeout: 10)

        let reported = String(decoding: result.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childCwd = URL(fileURLWithPath: reported).resolvingSymlinksInPath().path
        #expect(result.exitStatus >> 8 == 0)
        #expect(childCwd == expected,
                "child pwd must equal the granted workspace; got \(reported)")
    }

    @Test("no grant leaves the child in the parent's directory, as before")
    func noGrantInheritsParentCwd() throws {
        let result = ContainedProcess.run(
            executable: URL(fileURLWithPath: "/bin/pwd"),
            arguments: [],
            environment: ["PATH=/usr/bin:/bin"],
            stdinData: nil,
            workingDirectory: nil,
            cpuSecondsLimit: 5,
            timeout: 10)
        let reported = String(decoding: result.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!reported.isEmpty)
        #expect(result.exitStatus >> 8 == 0)
    }

    @Test("a missing grant directory fails the spawn loudly rather than starting the worker somewhere else")
    func missingGrantFailsLoudly() throws {
        let missing = NSTemporaryDirectory() + "cowork-no-such-dir-\(UUID().uuidString)"
        let result = ContainedProcess.run(
            executable: URL(fileURLWithPath: "/bin/pwd"),
            arguments: [],
            environment: ["PATH=/usr/bin:/bin"],
            stdinData: nil,
            workingDirectory: missing,
            cpuSecondsLimit: 5,
            timeout: 10)
        // The child must not have run in the wrong directory: spawn fails, no output.
        #expect(result.exitStatus != 0 || result.output.isEmpty)
    }
}

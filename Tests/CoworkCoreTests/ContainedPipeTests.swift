import Foundation
import Testing

@testable import CoworkCore

/// ContainedPipe is the process boundary for interactive CLI sessions. These tests
/// observe a *real child process* — not the value we passed in — so a silent cwd
/// miss cannot hide behind green plumbing assertions.
@Suite("ContainedPipe", .serialized)
struct ContainedPipeTests {

    private func tempDir(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-pipe-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFlushingPython(at dir: URL, body: String) throws -> URL {
        let script = dir.appendingPathComponent("agent.py")
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// Load-bearing: the child must actually run in the directory we grant.
    /// Asserting the parameter we passed is the bug this suite exists to catch.
    @Test("child process working directory is the path given at spawn")
    func childRunsInWorkingDirectory() throws {
        let root = try tempDir("cwd")
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = root.appendingPathComponent("granted-ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let expected = workspace.resolvingSymlinksInPath().path

        // Tiny flushing stand-in: report real process cwd, then exit.
        let agent = try makeFlushingPython(at: root, body: """
        #!/usr/bin/env python3
        import os, sys
        print(os.getcwd(), flush=True)
        """)

        let pipe = try ContainedPipe(
            executable: agent,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin",
                          "HOME": NSHomeDirectory()],
            workingDirectory: workspace.path)
        defer { pipe.close() }

        let reported = try #require(pipe.readLine(deadline: Date().addingTimeInterval(5)))
        let childCwd = URL(fileURLWithPath: reported).resolvingSymlinksInPath().path
        #expect(childCwd == expected,
                "child os.getcwd() must equal the granted workspace; got \(reported)")
    }

    @Test("no working directory leaves the child able to start as before")
    func noWorkingDirectoryStillStarts() throws {
        let root = try tempDir("nocwd")
        defer { try? FileManager.default.removeItem(at: root) }

        let agent = try makeFlushingPython(at: root, body: """
        #!/usr/bin/env python3
        import sys
        print("alive", flush=True)
        """)

        let pipe = try ContainedPipe(
            executable: agent,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin",
                          "HOME": NSHomeDirectory()])
        defer { pipe.close() }

        let line = try #require(pipe.readLine(deadline: Date().addingTimeInterval(5)))
        #expect(line == "alive")
    }

    @Test("nonexistent working directory fails spawn loudly")
    func missingWorkingDirectoryFailsSpawn() throws {
        let root = try tempDir("missing")
        defer { try? FileManager.default.removeItem(at: root) }

        let agent = try makeFlushingPython(at: root, body: """
        #!/usr/bin/env python3
        print("should-not-run", flush=True)
        """)
        let missing = root.appendingPathComponent("does-not-exist").path

        #expect(throws: ContainedPipe.Error.self) {
            _ = try ContainedPipe(
                executable: agent,
                arguments: [],
                environment: ["PATH": "/usr/bin:/bin"],
                workingDirectory: missing)
        }
    }
}

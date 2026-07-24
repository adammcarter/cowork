import Foundation
import Testing

@testable import CoworkCore

/// The environment a worker is given must not depend on WHICH way cowork launched it.
///
/// Both halves of this were real asymmetries: the session spawn built its own little
/// base environment that omitted the derived lineage vars (ADR 001), so a worker
/// running in a live session that itself called cowork reported as its own root; and
/// it never applied the row's `prepend_exe_dir_to_path`, so a CLI that needs its bin
/// dir on PATH worked one-shot and got a bare PATH in a session. Both paths now read
/// one definition, and these tests are what keeps them reading it.
@Suite("Child environment is the same on both spawn paths")
struct ChildEnvironmentTests {
    private let exe = URL(fileURLWithPath: "/opt/vendor/bin/tool")

    private func descriptor(env: [CliDescriptor.EnvEntry] = [], prependPath: Bool = false) -> CliDescriptor {
        CliDescriptor(taskDelivery: .argv, baseArguments: ["-p", "{task}"],
                      env: env, prependExeDirToPath: prependPath,
                      output: .raw, verdict: .exitCode)
    }

    @Test("the allowlist is exactly the four basics when a row contributes nothing")
    func allowlistBasics() {
        let entries = ChildEnvironment.allowlist(extra: [])
        #expect(entries.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
        #expect(entries.contains("HOME=\(NSHomeDirectory())"))
        #expect(entries.contains("USER=\(NSUserName())"))
        #expect(entries.contains("LANG=en_US.UTF-8"))
    }

    @Test("an extra entry overrides an allowlist entry by key rather than duplicating it")
    func extraOverridesByKey() {
        let entries = ChildEnvironment.allowlist(extra: ["PATH=/opt/vendor/bin:/usr/bin"])
        #expect(entries.filter { $0.hasPrefix("PATH=") } == ["PATH=/opt/vendor/bin:/usr/bin"])
    }

    @Test("the keyed form carries the same content as the KEY=VALUE form")
    func dictionaryMatchesAllowlist() {
        let extra = ["FOO=bar", "PATH=/opt/vendor/bin:/usr/bin"]
        let dict = ChildEnvironment.dictionary(extra: extra)
        for entry in ChildEnvironment.allowlist(extra: extra) {
            let parts = entry.split(separator: "=", maxSplits: 1)
            #expect(dict[String(parts[0])] == String(parts[1]))
        }
        #expect(dict["FOO"] == "bar")
    }

    @Test("derived lineage reaches a worker on both paths, not just the one-shot")
    func lineageIsForwarded() {
        setenv("COWORK_DISPATCH_ID", "d_lineage_probe", 1)
        setenv("COWORK_ROOT", "d_root_probe", 1)
        defer {
            unsetenv("COWORK_DISPATCH_ID")
            unsetenv("COWORK_ROOT")
        }
        #expect(ChildEnvironment.allowlist(extra: []).contains("COWORK_DISPATCH_ID=d_lineage_probe"))
        // The session spawn takes the keyed form; it must carry the same attribution,
        // otherwise a nested dispatch from inside a live session loses its parent.
        let dict = ChildEnvironment.dictionary(extra: [])
        #expect(dict["COWORK_DISPATCH_ID"] == "d_lineage_probe")
        #expect(dict["COWORK_ROOT"] == "d_root_probe")
    }

    @Test("a row's own entries are computed once and shared by both spawn paths")
    func rowEntriesAreShared() {
        setenv("COWORK_TEST_TOKEN", "s3cret", 1)
        defer { unsetenv("COWORK_TEST_TOKEN") }
        let d = descriptor(env: [.init(key: "LITERAL", value: .literal("v")),
                                 .init(key: "TOKEN", value: .reference("COWORK_TEST_TOKEN"))],
                           prependPath: true)
        let entries = d.environmentEntries(executable: exe)
        #expect(entries.contains("LITERAL=v"))
        #expect(entries.contains("TOKEN=s3cret"), "an env:NAME pointer resolves at dispatch")
        #expect(entries.contains("PATH=/opt/vendor/bin:/usr/bin:/bin:/usr/sbin:/sbin"))

        // The one-shot driver must not have its own second copy of this logic.
        let driver = ConfiguredDriver(name: "tool", executable: exe, descriptor: d)
        let invocation = driver.invocation(task: "hi", workspace: nil, resume: nil)
        #expect(invocation.extraEnvironment == entries)
    }

    @Test("an unset pointer becomes empty rather than leaking the variable's name")
    func unsetReferenceIsEmpty() {
        unsetenv("COWORK_TEST_ABSENT")
        let d = descriptor(env: [.init(key: "TOKEN", value: .reference("COWORK_TEST_ABSENT"))])
        #expect(d.environmentEntries(executable: exe) == ["TOKEN="])
    }
}

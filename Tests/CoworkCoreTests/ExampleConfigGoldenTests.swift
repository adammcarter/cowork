import Foundation
import Testing

@testable import CoworkCore

/// The regression gate on the shipped wires, across the workspace×resume matrix and
/// the verdict surface.
///
/// History matters here: these expectations were first written as a live comparison
/// against three hand-written drivers and passed against them, which is what licensed
/// deleting those drivers. Then the descriptors they pinned were Swift constants.
/// Now they are rows in `examples/config.toml`, so the same frozen values also prove
/// the file a user is told to copy really produces the wire it claims to.
@Suite("Example config wire pins")
struct ExampleConfigGoldenTests {
    private let ws = Workspace(root: URL(fileURLWithPath: "/tmp/ws"), writable: true)

    @Test("stream-json: no workspace flag, resume appends --resume")
    func streamJSONMatrix() throws {
        let d = try ExampleConfig.driver("claude")
        let base = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--verbose", "--permission-mode", "dontAsk",
                    "--allowed-tools", "Read", "Write", "--strict-mcp-config"]
        #expect(d.invocation(task: "t", workspace: nil, resume: nil).arguments == base)
        #expect(d.invocation(task: "t", workspace: ws, resume: nil).arguments == base,
                "this row declares no workspace flag: process cwd is the only root")
        #expect(d.invocation(task: "t", workspace: ws, resume: "R").arguments == base + ["--resume", "R"])
    }

    @Test("argv + json-field: --cwd then -r, in that order, and the exe dir leads PATH")
    func jsonFieldMatrix() throws {
        let d = try ExampleConfig.driver("grok")
        let base = ["-p", "t", "--output-format", "json", "--no-auto-update", "--always-approve"]
        #expect(d.invocation(task: "t", workspace: nil, resume: nil).arguments == base)
        #expect(d.invocation(task: "t", workspace: ws, resume: "R").arguments
                == base + ["--cwd", "/tmp/ws", "-r", "R"])
        let path = try #require(d.invocation(task: "t", workspace: nil, resume: nil)
            .extraEnvironment.first { $0.hasPrefix("PATH=") })
        #expect(path.hasSuffix(":/usr/bin:/bin:/usr/sbin:/sbin"))
    }

    @Test("raw stdin: -C carries the workspace and a resume handle is dropped, never faked")
    func rawStdinMatrix() throws {
        let d = try ExampleConfig.driver("codex")
        let base = ["exec", "--ignore-user-config",
                    "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check"]
        #expect(d.invocation(task: "t", workspace: nil, resume: nil).arguments == base)
        #expect(d.invocation(task: "t", workspace: ws, resume: "R").arguments == base + ["-C", "/tmp/ws"],
                "this row wires no resume: the handle is dropped rather than invented")
        #expect(d.invocation(task: "t", workspace: nil, resume: nil).stdin == Data("t".utf8))
    }

    /// The label carries the MECHANISM, never the backend. Which CLI produced an
    /// outcome already lives in the dispatch record's backend id, so two CLIs that
    /// failed the identical way must be indistinguishable here — otherwise nothing
    /// about them can ever be compared.
    @Test("the exit-code strategy names the mechanism only — two different clis emit identical bytes")
    func exitCodeLabelIsBackendAgnostic() throws {
        #expect(Verdict.exitCode(1).diagnostics == ["cli.exit", "exit=1"])

        let descriptor = try ExampleConfig.descriptor("codex")
        let one = ConfiguredDriver(name: "opencode", executable: URL(fileURLWithPath: "/o/opencode"),
                                   descriptor: descriptor)
        let two = ConfiguredDriver(name: "somethingelse", executable: URL(fileURLWithPath: "/s/x"),
                                   descriptor: descriptor)
        let outOne = one.parse(output: Data("x".utf8), exitStatus: 1 << 8)
        let outTwo = two.parse(output: Data("x".utf8), exitStatus: 1 << 8)
        #expect(outOne.diagnostics == ["cli.exit", "exit=1"])
        #expect(outOne.diagnostics == outTwo.diagnostics,
                "the backend name belongs to the record, never to the diagnostic")
        #expect(outOne.state == .failed)
    }

    /// The branches the shape spike got wrong: a declared success with a nonzero exit
    /// is still a success (with the disagreement recorded), and a missing declaration
    /// is a failure however the process exited.
    @Test("verdict strategies delegate verbatim on the honest-disagreement branches")
    func verdictDelegationBranches() throws {
        let declaring = try ExampleConfig.driver("claude")
        let ok = "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"OK\"}"
        let declaredSuccessNonzero = declaring.parse(output: Data(ok.utf8), exitStatus: 1 << 8)
        #expect(declaredSuccessNonzero.state == .succeeded)
        #expect(declaredSuccessNonzero.diagnostics == ["cli.nonzero-exit-despite-declared-success", "exit=1"])

        let silent = declaring.parse(output: Data("{\"type\":\"assistant\"}".utf8), exitStatus: 0)
        #expect(silent.state == .failed)
        #expect(silent.diagnostics == ["cli.no-declared-result", "exit=0"])

        let stopping = try ExampleConfig.driver("grok")
        let endTurnNonzero = stopping.parse(
            output: Data("{\"text\":\"a\",\"stopReason\":\"EndTurn\"}".utf8), exitStatus: 5 << 8)
        #expect(endTurnNonzero.state == .succeeded)
        #expect(endTurnNonzero.diagnostics == ["cli.nonzero-exit-despite-declared-success", "exit=5"])

        let noDeclaration = stopping.parse(output: Data("{\"text\":\"a\"}".utf8), exitStatus: 0)
        #expect(noDeclaration.state == .failed)
        #expect(noDeclaration.diagnostics == ["cli.stop-reason.absent", "exit=0"])
    }

    /// The example config is the product's only documentation of a working wire, so a
    /// row that no longer parses is a shipped bug, not a stale sample.
    @Test("every shipped example row loads, and each declares a distinct shape")
    func shippedRowsLoad() throws {
        #expect(Set(ExampleConfig.config.cli.keys) == ["claude", "grok", "codex", "opencode"])
        #expect(try ExampleConfig.descriptor("claude").verdict == .declaredResult)
        #expect(try ExampleConfig.descriptor("grok").verdict == .stopReason)
        #expect(try ExampleConfig.descriptor("codex").verdict == .exitCode)
        #expect(try ExampleConfig.descriptor("opencode").session == nil,
                "the one-shot-only row must stay one-shot-only: it is the honest-refusal example")
    }

    /// The stream extractor reads the key the row NAMED. Reading a fixed one instead
    /// would advertise follow-up and then resume with the wrong handle, or with none —
    /// a silently-ignored config value, which is the class of defect this design
    /// load-errors on everywhere else.
    @Test("the stream-json continuation comes from the descriptor's key, not a fixed one")
    func streamContinuationUsesTheDeclaredKey() throws {
        let declared = try ExampleConfig.descriptor("claude")
        #expect(declared.continuationField == "session_id")

        var renamed = CliDescriptor(
            taskDelivery: declared.taskDelivery, baseArguments: declared.baseArguments,
            resumeArguments: declared.resumeArguments, output: .streamJSONResult,
            continuationField: "conversation_id", verdict: .declaredResult)
        let driver = ConfiguredDriver(name: "x", executable: URL(fileURLWithPath: "/x"),
                                      descriptor: renamed)
        let stream = """
        {"type":"result","session_id":"WRONG","conversation_id":"c-9","subtype":"success","is_error":false,"result":"ok"}
        """
        let outcome = driver.parse(output: Data(stream.utf8), exitStatus: 0)
        #expect(outcome.continuation == "c-9", "the row's own key wins")

        // And a row that names no key captures nothing rather than guessing one.
        renamed = CliDescriptor(taskDelivery: .stdinJSONStreamUser, baseArguments: ["-p"],
                                output: .streamJSONResult, verdict: .declaredResult)
        let anonymous = ConfiguredDriver(name: "x", executable: URL(fileURLWithPath: "/x"),
                                         descriptor: renamed)
        #expect(anonymous.parse(output: Data(stream.utf8), exitStatus: 0).continuation == nil)
    }

    /// The three session wires, each declared by exactly one shipped row — and the
    /// MCP tool names living in config, which is the whole reason MCP is expressible
    /// without a vendor branch in code.
    @Test("each session wire is reachable from config alone")
    func sessionWiresAreConfigured() throws {
        #expect(try ExampleConfig.descriptor("claude").session?.wire == .streamJSON)
        #expect(try ExampleConfig.descriptor("grok").session?.wire == .acp)

        let mcp = try #require(try ExampleConfig.descriptor("codex").session)
        #expect(mcp.wire == .mcp)
        #expect(mcp.tool == "codex")
        #expect(mcp.replyTool == "codex-reply")
        #expect(mcp.toolArguments["approval-policy"] == "never")
        #expect(mcp.toolArguments["sandbox"] == "danger-full-access")
    }

    /// The credential copy is now the user's explicit instruction, not something
    /// cowork does on its own because it recognised a name.
    @Test("a credential seed is declared, never implied")
    func credentialSeedIsDeclared() throws {
        let isolate = try #require(try ExampleConfig.descriptor("codex").isolate)
        #expect(isolate.variable == "CODEX_HOME")
        #expect(isolate.seed?.lastPathComponent == "auth.json")
        #expect(try ExampleConfig.descriptor("claude").isolate == nil,
                "no row gets isolation it did not ask for")

        // The same knob, carrying settings rather than a secret: a worker gets a
        // known-good config of the user's choosing instead of inheriting whatever
        // the host happens to have. Both are the user's explicit instruction —
        // cowork copies what the row names and nothing else.
        let settings = try #require(try ExampleConfig.descriptor("opencode").isolate)
        #expect(settings.variable == "XDG_CONFIG_HOME")
        #expect(settings.seed?.lastPathComponent == "opencode-seed",
                "a small-window model needs its agent configured, not defaulted")
    }
}

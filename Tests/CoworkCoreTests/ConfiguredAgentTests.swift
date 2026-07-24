import Foundation
import Testing

@testable import CoworkCore

/// An agent's interactive and follow-up capabilities are derived from its wiring,
/// never declared as Bools.
///
/// These were originally written against the `SessionCapable` / `FollowUpCapable`
/// marker protocols, then against a registry of three built-in dialects. Both were
/// *static*: they could only describe an agent known at compile time. Every row is
/// config-authored now, so the same behavioural truths are asserted against the
/// descriptor the row actually carries — msg✓/fu✓ for the stream-json shape, msg✓/fu✗
/// for the raw-stdin one with its exact blocker token, and a row with no `[session]`
/// block honestly refusing to be messaged.
@Suite("ConfiguredAgent capabilities")
struct ConfiguredAgentTests {
    private func agent(_ name: String, _ descriptor: CliDescriptor) -> ConfiguredAgent {
        ConfiguredAgent(name: name, executable: URL(fileURLWithPath: "/opt/\(name)/bin/\(name)"),
                        descriptor: descriptor)
    }

    @Test("the stream-json shape can be messaged and followed up")
    func streamJSONShape() throws {
        let a = try ExampleConfig.agent("claude")
        #expect(a.isSessionCapable == true, "a [session] block is present, so a session can be opened")
        #expect(a.isFollowUpCapable == true,
                "this row captures session_id and passes --resume: both halves are wired")
        #expect(a.messageBlocker.isEmpty)
        #expect(a.followUpBlocker.isEmpty, "a follow-up-capable agent has nothing to explain")
    }

    @Test("the ACP shape can be messaged and followed up")
    func acpShape() throws {
        let a = try ExampleConfig.agent("grok")
        #expect(a.isSessionCapable == true)
        #expect(a.isFollowUpCapable == true, "this row captures sessionId and passes -r")
        #expect(a.messageBlocker.isEmpty)
        #expect(a.followUpBlocker.isEmpty)
    }

    @Test("the MCP shape can be messaged but not followed up: its one-shot leaves no handle")
    func mcpShape() throws {
        let a = try ExampleConfig.agent("codex")
        #expect(a.isSessionCapable == true)
        #expect(a.isFollowUpCapable == false,
                "this row's one-shot produces no continuation and wires no resume argument")
        #expect(a.messageBlocker.isEmpty)
        #expect(a.followUpBlocker == ["cli.follow-up-not-wired"], "not follow-up capable: must name why")
    }

    /// Capability is the presence of the operation. A row that declares no session
    /// wire is refused rather than quietly answered by a fresh one-shot that would
    /// remember nothing of the conversation (ADR 006).
    @Test("a row with no [session] block is one-shot only, and says so")
    func noSessionBlockIsOneShotOnly() throws {
        let a = try ExampleConfig.agent("opencode")
        #expect(a.isSessionCapable == false)
        #expect(a.messageBlocker == ["cli.session-code-only"])
        #expect(throws: CliSessionError.notSessionCapable) { try a.makeSession(DispatchContext()) }
    }

    /// Every row is config-authored now, so there is no privileged provenance left to
    /// compare against: each marker names a claim cowork made on the user's word and
    /// has not yet watched come true. A performed journey is what clears them.
    @Test("asserted capabilities carry an unverified marker, one per claim")
    func provenanceMarksEveryAssertedCapability() throws {
        let followUpOnly = agent("wired", CliDescriptor(
            taskDelivery: .argv, baseArguments: ["run", "{task}"],
            resumeArguments: ["--session", "{resume}"],
            output: .jsonField("result"), continuationField: "sessionID",
            verdict: .stopReason))
        #expect(followUpOnly.provenanceDiagnostics == ["cli.follow-up-unverified"],
                "cowork captures and passes a handle; nothing has proven the worker HONORS it")

        let exitOnly = agent("plain", CliDescriptor(
            taskDelivery: .argv, baseArguments: ["{task}"],
            output: .raw, verdict: .exitCode))
        #expect(exitOnly.provenanceDiagnostics == ["cli.verdict-unverified"],
                "exit-code honesty depends on this CLI's failures really surfacing as a nonzero exit")
        #expect(exitOnly.followUpBlocker == ["cli.follow-up-not-wired"])

        let sessioned = agent("chatty", CliDescriptor(
            taskDelivery: .argv, baseArguments: ["run", "{task}"],
            output: .raw, verdict: .exitCode,
            session: .init(wire: .acp, arguments: ["stdio"])))
        #expect(sessioned.provenanceDiagnostics == ["cli.session-unverified", "cli.verdict-unverified"],
                "a [session] block ASSERTS the binary speaks that wire; nothing has proven it answers")
    }

    /// The markers name the mechanism, never the row. Two rows wired the same way
    /// must be indistinguishable here, or nothing about them can be compared.
    @Test("provenance markers carry no backend name")
    func provenanceIsBackendAgnostic() {
        let descriptor = CliDescriptor(taskDelivery: .argv, baseArguments: ["{task}"],
                                       output: .raw, verdict: .exitCode)
        #expect(agent("one", descriptor).provenanceDiagnostics
                == agent("two", descriptor).provenanceDiagnostics)
        #expect(agent("one", descriptor).followUpBlocker == agent("two", descriptor).followUpBlocker)
    }
}

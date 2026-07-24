import Foundation
import Testing

@testable import CoworkCore

/// Identity is one type derived from the executable, and an agent's interactive and
/// follow-up capabilities are derived from its wiring, never declared as Bools.
///
/// These were originally written against the `SessionCapable` / `FollowUpCapable`
/// marker protocols. Those markers were *static* conformances, so they could only
/// describe a dialect known at compile time — a config-wired CLI needs the same facts
/// derived from the descriptor it was actually given. The assertions below pin the
/// identical behavioural truths (claude msg✓/fu✓, grok msg✓/fu✓, codex msg✓/fu✗ with
/// its exact blocker token, unknown ⇒ registry-nil) against the instance properties.
@Suite("CliAgent registry")
struct CliAgentTests {
    /// A config for a binary whose `kind` is derived from its executable — the
    /// normal case (the parser does this when `kind` is omitted).
    private func cfg(_ path: String) -> CliConfig {
        let url = URL(fileURLWithPath: path)
        return CliConfig(name: "t", executable: url, kind: CliDialect(executable: url), origin: .global)
    }

    @Test("the dialect is derived from the executable name",
          arguments: [("/usr/bin/claude", CliDialect.claude),
                      ("/opt/grok/bin/grok", .grok),
                      ("/usr/local/bin/codex", .codex),
                      ("/somewhere/mystery-agent", .unknown("mystery-agent"))])
    func dialectFromExecutable(path: String, expected: CliDialect) {
        #expect(CliDialect(executable: URL(fileURLWithPath: path)) == expected)
    }

    @Test("claude can be messaged and followed up, on the claude built-in wire")
    func claudeAgent() {
        let agent = CliRegistry.agent(for: cfg("/usr/bin/claude"))
        #expect(agent?.isSessionCapable == true, "claude vends a live session")
        #expect(agent?.isFollowUpCapable == true,
                "claude's one-shot captures session_id and accepts --resume")
        #expect(agent?.descriptor == BuiltinDescriptors.claude)
        #expect(agent?.messageBlocker.isEmpty == true)
        #expect(agent?.followUpBlocker.isEmpty == true, "a follow-up-capable agent has nothing to explain")
        #expect(agent?.provenanceDiagnostics.isEmpty == true, "a built-in's capabilities were proven, not asserted")
    }

    @Test("grok can be messaged — its ACP transport is built — and followed up")
    func grokAgent() {
        let agent = CliRegistry.agent(for: cfg("/opt/grok/bin/grok"))
        #expect(agent != nil)
        #expect(agent?.isSessionCapable == true, "grok vends a live ACP session")
        #expect(agent?.isFollowUpCapable == true, "grok's one-shot captures sessionId and accepts -r")
        #expect(agent?.descriptor == BuiltinDescriptors.grok)
        #expect(agent?.messageBlocker.isEmpty == true)
        #expect(agent?.followUpBlocker.isEmpty == true)
    }

    @Test("codex can be messaged — its MCP transport is built — but not followed up")
    func codexAgent() {
        let agent = CliRegistry.agent(for: cfg("/usr/local/bin/codex"))
        #expect(agent != nil)
        #expect(agent?.isSessionCapable == true, "codex vends a live MCP session")
        #expect(agent?.isFollowUpCapable == false,
                "codex exec produces no continuation handle and ignores resume")
        #expect(agent?.descriptor == BuiltinDescriptors.codex)
        #expect(agent?.messageBlocker.isEmpty == true)
        #expect(agent?.followUpBlocker == ["cli.follow-up-unproven"], "not follow-up capable: must name why")
    }

    @Test("an unrecognised executable has no agent: registry-nil")
    func unknownIsNil() {
        #expect(CliRegistry.agent(for: cfg("/x/some-other-agent")) == nil)
    }

    // MARK: config-wired agents

    private func generic(_ name: String, _ descriptor: CliDescriptor) -> ConfiguredAgent? {
        CliRegistry.agent(for: CliConfig(
            name: name, executable: URL(fileURLWithPath: "/opt/\(name)/bin/\(name)"),
            kind: .unknown(name), descriptor: descriptor, origin: .global))
    }

    @Test("a config-wired CLI is one-shot only: a session cannot be forged from config")
    func genericIsOneShotOnly() throws {
        let agent = try #require(generic("opencode", CliDescriptor(
            taskDelivery: .argv, baseArguments: ["run", "{task}"],
            output: .raw, verdict: .exitCode, deadlineDiagnostic: "cli.opencode.deadline")))
        #expect(agent.isSessionCapable == false)
        #expect(agent.messageBlocker == ["cli.session-code-only"])
        #expect(throws: Error.self) { try agent.makeSession(DispatchContext()) }
    }

    @Test("a config-wired follow-up is reported as asserted, distinctly from proven")
    func genericFollowUpProvenance() throws {
        let wired = try #require(generic("opencode", CliDescriptor(
            taskDelivery: .argv, baseArguments: ["run", "{task}"],
            resumeArguments: ["--session", "{resume}"],
            output: .jsonField("result"), continuationField: "sessionID",
            verdict: .stopReason, deadlineDiagnostic: "cli.opencode.deadline")))
        #expect(wired.isFollowUpCapable == true, "both halves of the mechanism are wired")
        #expect(wired.provenanceDiagnostics.contains("cli.opencode.follow-up-configured-unverified"),
                "cowork captures and passes a handle; nothing has proven the worker HONORS it")

        let unwired = try #require(generic("plaincli", CliDescriptor(
            taskDelivery: .argv, baseArguments: ["{task}"],
            output: .raw, verdict: .exitCode, deadlineDiagnostic: "cli.plaincli.deadline")))
        #expect(unwired.isFollowUpCapable == false)
        #expect(unwired.followUpBlocker == ["cli.plaincli.follow-up-not-wired"])
    }

    @Test("a config-wired exit-code verdict is marked unverified until a journey proves it")
    func genericExitVerdictIsMarkedUnverified() throws {
        let agent = try #require(generic("opencode", CliDescriptor(
            taskDelivery: .argv, baseArguments: ["run", "{task}"],
            output: .raw, verdict: .exitCode, deadlineDiagnostic: "cli.opencode.deadline")))
        #expect(agent.provenanceDiagnostics.contains("cli.opencode.verdict-unverified"),
                "exit-code honesty depends on this CLI's failures really surfacing as a nonzero exit")

        let codex = CliRegistry.agent(for: cfg("/usr/local/bin/codex"))
        #expect(codex?.provenanceDiagnostics.isEmpty == true,
                "codex's exit-only verdict is proven, so it carries no unverified marker")
    }
}

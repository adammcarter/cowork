import Foundation
import Testing

@testable import CoworkCore

/// Identity is one type derived from the executable, and an agent's interactive
/// and follow-up capabilities are conformances, never Bools. The registry hands
/// back the agent for a binary; `SessionCapable` / `FollowUpCapable` are the same
/// facts capabilities and dispatch both read.
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

    @Test("claude is a SessionCapable agent whose one-shot is the claude driver")
    func claudeAgent() {
        let agent = CliRegistry.agent(for: cfg("/usr/bin/claude"))
        #expect(agent is SessionCapable, "claude vends a live session")
        #expect(agent is FollowUpCapable,
                "claude's one-shot captures session_id and accepts --resume")
        #expect(type(of: agent!).dialect == .claude)
        #expect(agent?.oneShot() is ClaudeOneShotDriver)
        #expect(agent?.messageBlocker.isEmpty == true)
        #expect(agent?.followUpBlocker.isEmpty == true, "a FollowUpCapable agent has nothing to explain")
    }

    @Test("grok is a SessionCapable agent — its ACP transport is built — whose one-shot is the grok driver")
    func grokAgent() {
        let agent = CliRegistry.agent(for: cfg("/opt/grok/bin/grok"))
        #expect(agent != nil)
        #expect(agent is SessionCapable, "grok now vends a live ACP session")
        #expect(agent is FollowUpCapable,
                "grok's one-shot captures sessionId and accepts -r")
        #expect(agent?.oneShot() is GrokOneShotDriver)
        #expect(agent?.messageBlocker.isEmpty == true, "a SessionCapable agent has nothing to explain")
        #expect(agent?.followUpBlocker.isEmpty == true, "a FollowUpCapable agent has nothing to explain")
    }

    @Test("codex is a SessionCapable agent — its MCP transport is built — whose one-shot is the codex driver")
    func codexAgent() {
        let agent = CliRegistry.agent(for: cfg("/usr/local/bin/codex"))
        #expect(agent != nil)
        #expect(agent is SessionCapable, "codex now vends a live MCP session")
        #expect(!(agent is FollowUpCapable),
                "codex exec produces no continuation handle and ignores resume")
        #expect(agent?.oneShot() is CodexOneShotDriver)
        #expect(agent?.messageBlocker.isEmpty == true, "a SessionCapable agent has nothing to explain")
        #expect(agent?.followUpBlocker.isEmpty == false, "not FollowUpCapable: must name why")
    }

    @Test("an unrecognised executable has no agent: registry-nil")
    func unknownIsNil() {
        #expect(CliRegistry.agent(for: cfg("/x/some-other-agent")) == nil)
    }
}

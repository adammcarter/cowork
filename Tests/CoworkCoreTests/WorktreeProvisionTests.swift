import CoworkSugar
import Foundation
import Testing

/// Worktree provisioning is SUGAR (ADR 002 rule 8): the core owns *where* work
/// happens — it receives a path — and never learns what git is. This module plans
/// the provisioning; the role dispatcher performs it and hands the core a plain
/// path plus an `on_terminal` teardown the core runs without understanding.
@Suite("Worktree provisioning (sugar)")
struct WorktreeProvisionTests {
    private let repo = URL(fileURLWithPath: "/Users/x/code/myapp")

    /// Sibling of the repo, never nested inside it — a nested worktree gets swept
    /// into installs and archives of the repo it lives in.
    @Test("the worktree is a SIBLING of the repo, named after it")
    func siblingPath() {
        let plan = WorktreeProvision.plan(repoRoot: repo, suffix: "a1b2c3")
        #expect(plan.path == "/Users/x/code/myapp-role-a1b2c3")
    }

    @Test("create is a detached git worktree add rooted at the repo")
    func createCommand() {
        let plan = WorktreeProvision.plan(repoRoot: repo, suffix: "a1b2c3")
        #expect(plan.createCommand
                == "git -C '/Users/x/code/myapp' worktree add --detach '/Users/x/code/myapp-role-a1b2c3'")
    }

    /// Teardown is the `on_terminal` command handed to the core, which runs it on
    /// success only (rule 10) — so a failed dispatch's worktree survives for free.
    @Test("teardown removes the worktree through git, forcefully, from the repo")
    func teardownCommand() {
        let plan = WorktreeProvision.plan(repoRoot: repo, suffix: "a1b2c3")
        #expect(plan.teardownCommand
                == "git -C '/Users/x/code/myapp' worktree remove --force '/Users/x/code/myapp-role-a1b2c3'")
    }
}

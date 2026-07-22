import Foundation

/// The plan for giving one role dispatch its own git worktree (ADR 002 rule 8).
///
/// Provisioning is a sugar concern: the core receives a path and confines the
/// worker to it, and must never learn what git is — which is why this type lives
/// in the sugar module, not `CoworkCore`. The role dispatcher runs
/// `createCommand`, hands the core `path` as a plain workspace, and passes
/// `teardownCommand` as the dispatch's `on_terminal` — which the core runs on
/// success only (rule 10), so a failed dispatch's worktree is kept as evidence
/// with no extra machinery.
public struct WorktreeProvision: Equatable, Sendable {
    /// A SIBLING of the repo (`<parent>/<repo>-role-<suffix>`), never nested
    /// inside it: a nested worktree gets swept into installs and archives of the
    /// repo it lives in.
    public let path: String
    public let createCommand: String
    public let teardownCommand: String

    public static func plan(repoRoot: URL, suffix: String) -> WorktreeProvision {
        let name = repoRoot.lastPathComponent + "-role-" + suffix
        let path = repoRoot.deletingLastPathComponent().appendingPathComponent(name).path
        return WorktreeProvision(
            path: path,
            // Detached: a role dispatch reviews or builds against the current HEAD;
            // it does not own a branch, and leaving branches behind is litter.
            createCommand: "git -C '\(repoRoot.path)' worktree add --detach '\(path)'",
            teardownCommand: "git -C '\(repoRoot.path)' worktree remove --force '\(path)'")
    }
}

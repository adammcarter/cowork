# Audit Brief Template

Fill this in to scope a cowork AUDIT-mode dispatch. Keep it minimal — the auditor's only context is what's in this brief. Anything not included does not exist from the auditor's perspective.

## When to use AUDIT mode

Use AUDIT when you want an independent, fresh-eyes review of an artifact — typically before committing to a plan, after completing a major milestone, or when you want a second opinion uncontaminated by the discussion that produced the artifact. Examples:

- "We've drafted a multi-step plan; audit it before we start."
- "Codex implemented this PR; audit it for assumptions/gaps before merge."
- "Three V-rows just landed; audit them for inter-row consistency."
- "Post-mortem: audit the timeline + current state for what we missed."

If you want the artifact *changed*, use DELEGATE / DELEGATE WITH REVIEW instead — AUDIT only reports, it does not act.

## Template

```markdown
# Audit Brief — <topic>

## Topic
<one line — what's being audited>

## Scope

- **In-scope:** <repo / dirs / files / commit ranges / doc sections — concrete paths, no hand-waving>
- **Out-of-scope:** <areas to skip; auditor flags but does not investigate>

## What you're auditing

<numbered list of explicit questions or concerns. What would make you write BLOCKER vs CONCERN vs PASS? Be specific. Example:>

1. Are the assumptions in `<spec.md>` consistent with current code in `<src/foo/>`?
2. Does the proposed approach break any prior locked V-rows or invariants?
3. Is there a known failure mode the spec hasn't anticipated?
4. Are the cited evidence files at the cited offsets — or has the underlying data drifted?
5. Is the rollout/staging plan sound for the blast radius?

## Materials

The auditor sees ONLY what is listed here. Be explicit; cite paths.

- **Originating brief / plan / spec:** `<path>`
- **Artifact under audit:** `<path or commit range>`
- **Reference docs / catalogues / V-rows the brief depends on:** `<paths>`
- **Validation targets / oracle fixtures / tests (if applicable):** `<paths>`

## Custom project notes (optional — inlined by Step 1g if provided)

Project-specific verification model / conventions / contributing rules that the auditor MUST read before grading. Generic kinds of content that typically belong here:

- The project's verification model (whatever scaffold the project uses for locked claims)
- Evidence-tier hierarchy (which sources count as primary vs derived; what's citable where)
- Annotation block / docstring requirements
- Language / framework / API-version constraints
- Independent-derivation rules (e.g. two reviewers required, peer cross-check, etc.)
- Sampling discipline (e.g. N≥3 before structural claims lock)
- "Source-of-truth" doctrines (e.g. "bytes win", "spec wins", "tests win")
- Project-specific delete/keep/archive policies

The plugin holds no project examples — keep this section generic. **For repeatability across audits in the same project: keep your project-specific notes in a single committed MD file in your repo (e.g. `<repo>/.audit-context.md`) and pass that path on every audit invocation.** One file in the project = one source of truth for grading. The plugin's job is to inline whatever you point at; the contents are entirely the project's concern.

## Output format (required)

The full output-format specification (severity definitions, verdict definitions, style rules, examples) is **inlined into the composed brief by Step 1g** at composition time — under the `## Output format (full spec — inlined)` section. Do NOT reference `references/audit-output-format.md` by relative path in the composed brief; that path won't resolve from the auditor's working dir (which is the audit scope root, not the cowork plugin path).

For human reference when reading this template: the inlined spec requires the auditor's output to contain, in this order:

1. `## Verdict` — one of `PASS | PASS-WITH-NOTES | BLOCK | NEEDS-MORE-CONTEXT`
2. `## Confidence` — three sub-lists (Verified hands-on / Inferred / Could not access)
3. `## Findings` — severity-classified findings, each with Location + Evidence + Why-it-matters + Suggested-action; or "No findings." if there are none
4. `## Out-of-scope observations` — bullets only, may be empty
5. `## Sign-off` — one-line summary

Deviation from this format is a malformation. The parent agent will reject and re-dispatch. See `references/audit-output-format.md` for the canonical spec (when reading this template manually); when COMPOSING a brief, inline that file's full content into the brief instead.

## Audit invariants (you MUST follow)

- **No file writes.** No `Write`, no `Edit`, no `mkdir`, no `>` redirects, no `tee`, no `touch`. If a tool would write, refuse.
- **No git mutations.** No `commit`, `branch`, `push`, `reset`, `checkout`, `merge`, `rebase`, `stash`, `cherry-pick`, `clean`, `tag`, `restore`. Read-only git is fine (`status`, `log`, `diff`, `show`, `blame`).
- **No shell side effects.** Read, grep, list, query, sha-check, diff. No state mutations. No background processes you don't kill.
- **Stay in scope.** Flag out-of-scope concerns in the dedicated section. Do not investigate them. Do not "while I'm here, also check…"
- **Be specific.** Every finding cites a file:line, commit, byte range, or section reference. No "I would do this differently" without evidence.
- **Confidence discipline.** Separate what you verified hands-on from what you inferred or couldn't access. A BLOCKER must reference verified-hands-on evidence; if the strongest evidence is "inferred," downgrade to CONCERN or list it under "Could not access."
- **No invented findings.** If you find nothing wrong, write `Verdict: PASS` plainly. Don't manufacture findings for symmetry. An audit that genuinely passes is more valuable than one with manufactured concerns.
- **No fixes.** Suggest pointers ("consider X", "verify Y"), not patches ("here's the diff to apply"). The user/parent decides what to act on.
- **No prior-context contamination.** You have only this brief. Do not speculate about what the originating session said, what the user "probably meant," or what came before. If the brief is unclear, list it under "Could not access" and verdict NEEDS-MORE-CONTEXT.
```

## How to fill it in

1. **Topic** — short, descriptive, becomes the slug. "record envelope audit" → `record-envelope-audit`.
2. **Scope** — be ruthless. If the artifact is a 10-file PR, list those 10 files. If the artifact is one V-row, list that one V-row. The narrower the scope, the sharper the audit.
3. **Audit questions** — these are the *prompts* for the auditor. Bad: "is this good?" Good: "does this approach handle the failure mode where X simultaneously with Y?" Specific questions produce specific findings.
4. **Materials** — over-include slightly. If you're unsure whether a file is needed, include it. The auditor will only read what's relevant.
5. **Output format / invariants** — keep verbatim. These are non-negotiable.

## Anti-patterns

- **Don't leak prior context.** "We tried X and it didn't work because Y, so we're now trying Z; audit Z." → Bad. The auditor will be biased by the X→Y→Z framing. Just say "audit the Z approach for soundness given <materials>."
- **Don't ask for an opinion poll.** "Do you think this is a good plan?" → Useless. AUDIT produces findings against criteria; if your criteria are vague, your findings will be vague.
- **Don't include the conclusion in the brief.** "We've decided to ship X; audit it for any blockers" → ok. "We've decided to ship X; please confirm there are no blockers" → bad. Don't tell the auditor what answer you want.
- **Don't use AUDIT for decision-making.** AUDIT reports findings; it does not decide. If you want a recommendation, use COLLAB.

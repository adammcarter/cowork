---
name: review
description: Specialist-fleet review of any artifact — code diffs, plans, specs, designs, proposals, or pre-implementation approaches. The orchestrating agent picks all-that-apply specialists from the selection reference + 1 always-on senior closure reviewer (plus optional bespoke B<N> specialists per session); dispatches them in parallel as role_review_* tools; folds in valuable findings; re-dispatches gatekeepers on changes-in-domain; stops on diminishing returns (max 4 rounds). Triggers on "review this", "fleet review", "specialist review", "/cowork:review".
allowed-tools: [Bash, Read, Write, Edit, AskUserQuestion]
---

# Cowork Review

A specialist-fleet review of **any artifact** — code diffs, plans, specs,
designs, proposals, or pre-implementation approaches. Each round dispatches
multiple specialists in parallel — each a `role_review_*` tool with a sharp,
file-defined POV — plus an always-on senior "PR approver" closure reviewer.
Findings are folded in by the orchestrating agent between rounds. Gatekeeper
specialists re-dispatch when their domain changed; advisory specialists run
once; the senior reviewer re-runs at final closure. Stops when no specialist
would be re-dispatched, or after 4 rounds.

> **Transport rule:** every specialist is dispatched through cowork's own
> tools — a `role_review_*` tool per catalog specialist, the core `dispatch`
> tool for bespoke specialists — and collected with `wait` + `output`. The
> specialist's POV and stay-in-lane live in its role file; this skill holds
> only the judgment: which specialists, which backend, when to re-dispatch,
> how to fold in, when to stop. If the cowork tools are unavailable, surface
> the error; never fall back to shelling out to an agent CLI directly.

## Core invariants

- **Toolkit-of-specialists.** The orchestrating agent picks **all-that-apply**
  from `references/selection.md` — generously, not parsimoniously. Every entry
  has explicit `Pick when` and `Do not pick merely because` triggers.
- **The senior reviewer is always on.** `role_review_senior` is picked
  automatically in every run (class: closure).
- **Fresh eyes per specialist.** Each specialist runs as its own dispatch.
  Never resume, never `follow_up` — every dispatch is cold.
- **Read-only for specialists.** Specialists produce reports. Only the
  orchestrating agent edits files when folding in findings. Dispatch
  specialists **without** a writable workspace grant on the reviewed tree.
- **Classification controls re-dispatch** (classes per `references/selection.md`):
  gatekeepers re-run on changes-in-domain; advisory run once; closure re-runs
  at the end.
- **Max 4 rounds** (1 initial + 3 re-runs). Stop earlier on diminishing returns.
- **Stay-in-lane discipline.** Baked into every role's template; the shared
  brief re-states it as a hard rule.
- **Quality over quantity.** A finding earns its place only if a real engineer
  would act on it. Honest PASS verdicts are correct and valued. Filing
  low-confidence noise or borderline nits is a defect — it dilutes signal and
  wastes fold-in effort.

## Step 1 — Gather scope

Use **one** `AskUserQuestion` call where possible; otherwise sequential prompts.

Determine the target. In order:

1. If `$ARGUMENTS` is a path / PR number / SHA range → use that.
2. If the worktree has uncommitted staged changes → propose "review the stage"
   with one confirmation question.
3. If the branch is ahead of `main` → propose "review `main..HEAD`" with one
   confirmation question.
4. Otherwise ask the user what they want reviewed.

Check git state silently. Do not narrate tool output or scope reasoning.
Produce the scope table directly — it is the only output this step emits.

Capture: **Topic** (one-line title), **Slug** (`[a-z0-9-]+`), **Target**
(concrete scope: globs, commit range, PR, spec path, or described proposal),
**Review mode** (`post-implementation` default, or `pre-implementation` for a
proposed approach with an intentionally clean worktree), **Notes** (optional
picking weights from the user).

Echo the resolved scope as a markdown table:

| **Field** | **Value** |
|-----------|-----------|
| Slug | `{slug}` |
| Mode | `{mode}` |
| Target | {one-line description} |
| Notes | {user notes, or "none"} |

## Step 2 — Pick specialists

### Pre-pick: project layer

The project can extend or override the specialist set in two ways — check both:

```bash
ls .cowork/review/*.md 2>/dev/null      # written project contracts (brief context)
ls .cowork/roles/*.role 2>/dev/null     # project-defined specialist roles
```

- **`.cowork/review/*.md` contract files** (e.g. `architecture.md`,
  `project.md`): absorbed **verbatim** into the shared brief so every
  specialist reads them, and `role_review_architecture` is auto-included
  whenever any such file exists. If the project also defines a dedicated
  enforcement role for a contract file, that role is **mandatory this run**.
- **Project roles**: any project-layer `role_review_*` tool (the tool list
  tags these `[project]`) is a project specialist. A project role that
  *overrides* a shipped one (the description says so) simply IS that
  specialist for this run — same tool name, the project's customisation.
  A project role that adds a NEW specialist is treated as a catalog entry
  with class **gatekeeper** unless its description says otherwise.

### Pre-pick: language preferences

If the plugin or user config ships language-preference files (e.g.
`languages/swift.md`), and that language appears in the scope by file
extension, absorb the file **verbatim** into the shared brief. No new
specialist is created — language files are context, not contracts. Project
contracts take precedence where both cover the same language.

### Pick from the selection reference

Read `references/selection.md`. For each entry:

1. Match `Pick when` triggers against the target's files / diff / changed
   areas. If any trigger matches AND no `Do not pick merely because`
   anti-trigger applies → include.
2. Be generous. Over-pick is cheaper than under-pick — specialists run in
   parallel.
3. `role_review_senior` is **always** picked.

Do not narrate the matching process. Write picks.md directly, then surface
the pipe table — that is the only output this step emits.

Write the picking decision to `/tmp/cowork-review-${SLUG}/round-1/picks.md`.
It is the **canonical source** for every specialist's display name and scope;
later tables copy Name and Scope verbatim from here. On rounds N>1, append new
rows under a `## Round {N} additions` heading — never rewrite round-1 rows.

```
# Round 1 specialist picks — {TOPIC}

Target: {one-line description}
Scope: {file list or diff summary}

| **Tool** | **Name** | **Scope** | **Class** |
|----------|----------|-----------|-----------|
| role_review_security | Security & abuse paths | shell execution, untrusted paths | gatekeeper |
| role_review_test_oracle | Test oracle | changed behaviour + new tests | gatekeeper |
| role_review_senior | Senior engineer | holistic PR approval — always-on | closure |

Not picked:
- role_review_ux — {one-line reason}
...
```

**Always surface the picks table to the user after writing picks.md** — copy
it verbatim, no narration.

## Step 2.5 — Bespoke specialists

If the target has a domain no shipped or project role covers well, compose
1–3 bespoke specialists (`B1`–`B3`). A bespoke has no role file — it is
dispatched through the core `dispatch` tool with a manually composed brief
(the same structure a role's template provides: POV, stay-in-lane, then the
shared brief + target). Always one-shot unless fold-in explicitly hits its
domain.

Do not narrate the assessment: either add bespoke rows to picks.md (class
`bespoke`, Scope = what it evaluates on THIS target) plus a POV +
stay-in-lane definition below the table, or proceed without comment.

**Compose a bespoke for:** a genuine domain outside every role — a niche
SDK, a specific protocol or file format, domain vocabulary no specialist
owns.
**Do NOT compose one for:** extra rigor on an existing domain (tighten that
role's evaluate bullets instead), a symptom hit-list, something too narrow
to produce a report, or a restatement of the senior reviewer's holistic
read.
**Promotion rule:** a bespoke that appears in 3+ runs earns a real role file
(shipped or project) with proper pick-when/anti-trigger entries in
`references/selection.md`.

## Step 2.9 — User approval gate

After completing picks, **always** ask before dispatching anything. This is
the single explicit user gate before work runs:

```
AskUserQuestion(
  question: "Ready to dispatch {N} specialists for '{TOPIC}'? ({tool list})",
  header:   "Dispatch gate",
  options: [
    { label: "Approve — run as picked", description: "Dispatch all {N} specialists now." },
    { label: "Deny — stop here", description: "Cancel the run. No agents dispatched." },
    { label: "Modify picks", description: "Describe changes via Other — add or remove specialists or a bespoke; the picks table is updated and re-surfaced before asking again." }
  ]
)
```

Never skip this gate or infer approval from context. Silence is not approval.

## Step 3 — Compose the shared brief

One shared brief per round carries everything common (~70% of every
specialist's context); each dispatch adds only its per-specialist emphasis.
Write to `/tmp/cowork-review-${SLUG}/round-${ROUND}/shared-brief.md`:

```
# Shared brief — {TOPIC} — round {ROUND}

## Target
- Topic / Slug / Scope / Worktree path / Round
- Review mode: post-implementation | **PRE-IMPLEMENTATION**

> PRE-IMPLEMENTATION NOTE (verbatim, when applicable): This is a
> pre-implementation review; the worktree is intentionally clean — no diff
> exists yet. Evaluate the proposed approach in §Background. Do NOT file
> "code not written" findings — identify risks, design gaps, and test
> requirements so implementation can proceed correctly.

## Supporting context
{paths reviewers may read — include every .cowork/review/*.md verbatim}

## Language preferences
{verbatim matched language files, or omit the section}

## Background
{what the target IS — change summary / spec proposal / PR description}

## Prior rounds (round > 1 only)
{each prior round's synthesis.md verbatim, separated by ---, then one line:
 Current state: what changed since round 1}

## Required output format
{inline references/report-format.md verbatim}

## Hard rules
- Read-only. No file modifications, no git mutations.
- Cite specifically — paths + line numbers + quoted evidence.
- Stay in your POV. Lateral findings go in §5, brief, no investigation.
- Quality over quantity. PASS is a correct and valued verdict.

## Specialists in this round
{tool list}
```

Write brief files silently; the only user-facing output before Step 5's
dispatch table is nothing at all.

## Step 4 — Choose the backend

Call `capabilities` and pick the strongest available backend for review work
(prefer a frontier CLI agent — it brings its own tools for reading the
worktree; a hosted endpoint works for spec/plan reviews where the full text
travels in the brief). One backend for the whole round unless the user says
otherwise. Do not narrate; the choice appears as a column in the dispatch
table.

## Step 5 — Dispatch specialists in parallel

For each picked **catalog or project specialist**, call its `role_review_*`
tool — all calls issued together so the fleet runs in parallel:

```
role_review_{name}(
  backend: {chosen backend},
  brief:   {shared brief text}
           + "\n\n## Specifically evaluate\n" + {2–6 bullets naming concrete
             questions THIS specialist should answer about THIS target}
           + {class addendum — advisory: findings without patches are the
              deliverable; closure: read holistically as a PR approver and
              flag picking gaps as lateral findings; bespoke: you are the
              domain expert this review was missing},
  target:  {the concrete scope — diff summary + file list, or spec path}
)
```

For each **bespoke**, call `dispatch` with the equivalent manually composed
task. Record every returned dispatch id against its specialist in picks.md.

**HARD MUST — after dispatching, output the dispatch table** (one table per
class present; Name and Scope verbatim from picks.md; include the id):

```
{N} specialists dispatched — round {ROUND} on {backend}:

**Gatekeepers ({count})**
| **Tool** | **Name** | **Scope** | **Dispatch** |
| --- | --- | --- | --- |
| role_review_security | Security & abuse paths | shell execution, untrusted paths | j_1A2B3C4D |
...
```

## Step 6 — Collect reports

`wait` on each dispatch (bounded; re-issue while still running — silence
means work is in progress), then `output` to fetch each report. Validate the
structure against `references/report-format.md`:

- Malformed report → surface to the user; do NOT silently fix.
- `failed` / `timed_out` / `cancelled` dispatch → surface the diagnostics;
  ask the user whether to retry or skip that specialist this round.

Save each report verbatim to
`/tmp/cowork-review-${SLUG}/round-${ROUND}/{tool}-report.md`. Wait for ALL
dispatches in the round before synthesising.

## Synthesis format

Round summaries (Step 7) and transition announcements (Step 9) use this
format; the final synthesis (Step 11) has its own richer format. Glanceable —
scannable in under 10 seconds.

```
# Synthesis — {TOPIC} — {LABEL}

**Overall: {summary line}**

---

## {Primary section}          ← one table per reviewer class with entries

| **Tool** | **Name** | **Summary** |
|----------|----------|-------------|
| {tool}   | {name}   | {one sentence} |

---

## {Secondary section}        ← bullets, one short phrase each

---

Full reports: /tmp/cowork-review-${SLUG}/round-${ROUND}/
```

## Step 7 — Synthesise round + fold-in gate

Read all reports silently; write
`/tmp/cowork-review-${SLUG}/round-${ROUND}/synthesis.md` using the format
above (`{summary line}` → `{N} blockers · {N} concerns · {N} passes`;
primary section `BLOCKERs`; secondary `Convergent themes` and `Fold-in
priorities`, ≤5 phrases each). Surface it verbatim, then ask:

```
AskUserQuestion(
  question: "Approve fold-in for round {ROUND} of '{TOPIC}'?",
  header:   "Fold-in gate",
  options: [
    { label: "Approve — apply fold-in now", description: "Proceed with the listed priorities." },
    { label: "Modify fold-in", description: "Add, remove, or reorder items via Other." },
    { label: "Stop without fold-in", description: "End the review here. No files changed." }
  ]
)
```

## Step 8 — Fold in valuable findings

The orchestrating agent does the edits. Track changed files → that is
`diff_${ROUND}`, the input to Step 9.

Fold in: concrete bugs and correctness issues (always — BLOCKERs
non-negotiably); architectural risks the user agrees to address now;
advisory findings worth recording in specs/docs even without patches.
Do NOT: manufacture patches for advisory findings; implement findings a
report itself defers; make changes the user objected to at the gate.
Commit per logical step; run the smallest relevant test set after fold-ins
before dispatching the next round.

## Step 9 — Decide round N+1

Evaluate silently, produce only the transition table or stop announcement.

Per specialist from the prior round, using each report's **§4 Domain reach**:
- **Gatekeeper** — re-dispatch if `diff_${ROUND}` touched their domain
  (whether or not they found anything last round).
- **Advisory** — only if the architecture/assumptions their finding
  referenced materially changed.
- **Bespoke** — only if `diff_${ROUND}` explicitly touched their composed
  domain.
- **Closure** — never here; `role_review_senior` re-runs at Step 10.
- **Project specialists** — gatekeeper rules; always eligible while their
  contract file or role exists.

Additionally: if `diff_${ROUND}` entered the domain of a specialist not yet
picked, add it now (append to picks.md).

**Stop when:** no specialist qualifies; or round 4 is done; or the user says
stop. Announce either the stop (`{Primary}` → `Remaining open items`,
`{Secondary}` → `Addressed this run`) or the transition (`{Primary}` →
`Re-dispatching` with reasons, `{Secondary}` → `Not re-dispatching`) using
the Synthesis format, then loop to Step 3 or proceed to Step 10.

## Step 10 — Final closure

Announce: `Final closure — dispatching the senior reviewer on post-fold-in
state.` Dispatch `role_review_senior` once more; its brief carries the
original target (with all fold-ins applied), the verdict matrix from every
round, a summary of every fold-in action, and the PR-approver framing:
*would you approve this PR now — and what would change your verdict?*

## Step 11 — Final synthesis

Write `/tmp/cowork-review-${SLUG}/final-synthesis.md` and surface:

```
────────────────────────────────────────────────────────
  /cowork:review Final Synthesis — {TOPIC}
────────────────────────────────────────────────────────
Rounds: {N}  ·  Specialists: {total dispatches}

| **Priority** | **Found** | **Addressed** | **Open** |
| --- | --- | --- | --- |
| Blockers | … | … | … |
| Concerns | … | … | … |
| Nits | … | deferred | — |

Senior verdict: {verdict}
{one paragraph reasoning}

Open items ({count})
| **Specialist** | **Scope** | **Finding** | **Status** |

Lateral findings: {bullets}
Files modified: {path — one-line summary}

Reports: /tmp/cowork-review-${SLUG}/
────────────────────────────────────────────────────────
```

Then one line:
> `/cowork:review {verdict}. {N} rounds, {S} specialists, {B}/{C}/{nits} findings, {files} files modified.`

## Step 12 — Terminate

Do NOT auto-loop, auto-merge, or auto-push. More rounds = a fresh
`/cowork:review` on the post-fold-in state. Deeper implementation of open
findings = a delegation session, not this skill.

## What /cowork:review is NOT

- **Not a single-shot pre-merge gate** — that's `/cowork:audit` (one round,
  fresh eyes, no fold-in).
- **Not a PR comment generator** — reports + fold-in edits; no GitHub
  integration.
- **Not authoritative on style/preference** — findings, not opinions; the
  senior verdict is its own, and the user decides.
- **Not gating** — it produces a verdict and an open-items list; merging is
  the user's call.

---
name: qa
description: Per-feature QA fleet — dispatches one QA agent per approved subject in parallel via the qa roles. Post mode audits existing features for coverage gaps; pre mode designs and writes test scaffolding for a locked plan before production code exists. One-shot (no re-dispatch). Triggers on "qa this", "qa review", "/cowork:qa".
allowed-tools: [Bash, Read, Write, Edit, AskUserQuestion]
---

# Cowork QA

A parallel fleet of QA agents — one per approved subject — with two modes:

- **post mode** (default): per-feature audit of existing code and coverage gaps,
  dispatched as `role_qa_post` (slots: `subject`, `scope`).
- **pre mode**: per-task test scaffolding design/build for a locked plan before
  production code exists, dispatched as `role_qa_pre` (slots: `task`, `scope`).

> **Transport rule:** every QA agent is one `role_qa_post` / `role_qa_pre`
> dispatch, collected with `wait` + `output`. The agent's remit, access rules,
> and required report format are baked into the role's template — this skill
> holds only the judgment: mode, subject discovery and approval, backend
> choice, and synthesis. If the cowork tools are unavailable, surface the
> error; never shell out to an agent CLI directly.

## Core invariants

- **One agent per subject.** Each approved feature/task gets one dedicated
  dispatch — fresh eyes, never resumed.
- **One-shot.** No re-dispatch, no fold-in. QA reports gaps; fixing them is a
  separate delegation session, not this skill.
- **Mode-specific access** (enforced by the role prompts): post is read-only
  with respect to project files; pre may write scaffolding under test paths
  only (`tests/`, `__tests__/`, `*-test.*`, `fixtures/`, `harness/`), never
  production code.
- **The report contracts are the roles'.** Each role template carries its
  exact required report sections; the orchestrating agent validates each
  returned report against them and surfaces malformed ones rather than
  silently fixing.

## Step 0 — Select mode

Auto-detect first:
- Invocation args include a plan path → **pre**.
- Args include `--mode pre` / `--mode post` → use that.
- Neither, and the cwd has uncommitted changes or recent commits → infer **post**.
- Otherwise ask:

```
AskUserQuestion(
  question: "Pre or post implementation?",
  header: "/qa mode",
  options: [
    { label: "Post — audit gaps in existing code",
      description: "Default. Discovers features from recent changes and dispatches one read-only QA agent per feature to exercise it and report coverage gaps." },
    { label: "Pre — design + build test scaffolding for a plan",
      description: "Dispatches one agent per plan task to design and write the test infrastructure (fakes, harnesses, fixtures) that TDD implementers will consume." }
  ]
)
```

## Step 1 — Discover subjects and get approval

### Post mode

Read repository state silently (staged, unstaged, and the last ~5 commits) and
derive candidate features: group the changed files into user-facing feature
areas, one row per feature with a scope hint (the files/entry points it
covers). Offer manual entry if the user prefers to name features directly.

### Pre mode

Read the plan document (from args, or ask for its path) and derive one row per
plan task: `T<ID> — title`, with a scope hint from the task's own text.

### Approval gate (both modes)

Surface the candidate table (`subject | scope hint`) and ask the user to
approve, remove, rename, or add rows before anything is dispatched. Persist
the approved set to `/tmp/cowork-qa-${SLUG}/subjects.md` — it is the canonical
list for every later table. Never dispatch without this approval.

## Step 2 — Choose the backend

Call `capabilities` and pick a strong available backend. Post mode exercises
real code and runs tests, so prefer a frontier CLI agent (it brings its own
shell and tools); pre mode writes scaffolding and needs the same. One backend
for the fleet unless the user says otherwise.

## Step 3 — Dispatch the fleet in parallel

One role call per approved subject, all issued together. Pass the dispatch a
writable `workspace` only in pre mode (the role's prompt confines writes to
test paths); post mode dispatches without a writable grant on the project.

```
# post
role_qa_post(backend: {backend}, subject: "{feature name}", scope: "{scope hint}")

# pre
role_qa_pre(backend: {backend}, task: "T{ID} — {title}", scope: "{scope hint}",
            workspace: "{repo path}")
```

Record each dispatch id against its subject, then output the fleet table:

```
{N} QA agents dispatched ({mode} mode, {backend}):

| **Subject** | **Scope** | **Dispatch** |
| --- | --- | --- |
| Auth flow | src/auth/*, LoginView | j_1A2B3C4D |
...
```

## Step 4 — Collect reports

`wait` on each dispatch (re-issue while still running), then `output` each
report. Validate against the role's required sections (post: Dev testing /
Unit tests / UI tests / Suggested next actions; pre: Scaffolding written /
Coverage checklist / Implementer hand-off / GAPs). Malformed → surface, don't
fix. Failed/timed-out → surface diagnostics; ask whether to retry or skip that
subject. Save each report to `/tmp/cowork-qa-${SLUG}/{subject-id}-report.md`.

## Step 5 — Synthesise (one-shot; then stop)

### Post mode

One table, one row per feature — glanceable:

```
# QA synthesis — {TOPIC}

**Overall: {N} features · {N} clean · {N} with gaps**

| **Feature** | **Verdict** | **Gaps** |
| --- | --- | --- |
| Auth flow | gaps | login error path untested; no UI test for lockout |
| Export | clean | — |

Full reports: /tmp/cowork-qa-${SLUG}/
```

### Pre mode

Task-by-task: scaffolding inventory (paths written), coverage categories
APPLICABLE / N/A / GAP, and an explicit **blockers** list of unresolved GAPs
that still block the gate.

Surface the synthesis, recommend a delegation session for high-priority gaps,
and terminate. No re-dispatch, no auto-fix — the user decides what happens
next.

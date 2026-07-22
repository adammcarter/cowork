---
name: superreview
description: >-
  Surface-driven exhaustive test audit. Enumerates every public API item from
  source (classes, methods, functions, CLI commands, MCP tools, exported types
  — whatever the target is), dispatches parallel frontier batch agents to write
  missing unit + dev/integration tests for every parameter, and exits with
  COMPLETE when a coverage table shows non-zero passing counts for every row —
  or returns BLOCKED (terminal, not a failure mode) when two targeted batches
  fail to resolve the same row. Works on any codebase, language, framework, or
  mix: a single class, a whole package, an MCP server, a CLI binary, a React
  component tree, a Swift framework, a Python module — the surface enumeration
  strategy adapts to the target. Triggers on "/cowork:superreview",
  "superreview", "exhaustive test audit", "full coverage audit".
allowed-tools: [Bash, Read, Write, Edit, AskUserQuestion]
---

# /cowork:superreview — Exhaustive Surface-Driven Test Audit

> **Transport rule:** every batch agent is one cowork `dispatch` (a strong
> backend chosen via `capabilities` — batch agents write and run tests, so a
> frontier CLI agent is required), tracked by dispatch id and collected with
> `wait` + `output`. If the cowork tools are unavailable, surface the error;
> never shell out to an agent CLI directly.

Unlike `/cowork:review` (read-only specialist opinions), superreview is
**read+write**: the **orchestrator** (Steps 2–3) enumerates and locks the
full API surface from source before any test is written, then dispatches
parallel batch agents to write exhaustive tests and run gates. The skill
exits with COMPLETE when every surface row has non-zero passing unit AND
dev/integration test counts. **BLOCKED is a terminal exit — not a failure
to complete the loop.** See Step 7 for bounded escalation. Batch agents
do not discover or redefine the surface — they implement against the
locked inventory only.

---

## Core invariants

- **Surface-first, always.** Enumerate every public API item mechanically
  from source BEFORE writing a single test. Never assume the surface is
  known from prior context.
- **Two-tier testing, required for every item:**
  - **Unit** — isolated, fake/mock dependencies, no real system. Covers
    valid input, every invalid input (per-param), boundary values, error
    paths, output shape.
  - **Dev/integration** — exercises the real system (live process, real
    socket, real filesystem). Guarded by an env var (`RUN_DEV_TESTS=1`)
    so CI stays green without a running service. At minimum one happy-path
    call per surface item.
- **Coverage table is the exit gate.** The skill does not complete until
  BOTH tables (see Step 7) have zero empty cells, zero zeros in all four
  Unit/Dev columns, Unit Passing = Unit Tests, and Dev Passing = Dev Tests
  for every row.
- **Batch agents write tests; orchestrator verifies.** Batch agents (a
  frontier CLI backend via cowork `dispatch`) add tests and fix production
  code when gaps expose bugs. The orchestrating agent runs all gates
  independently after each batch lands and verifies changed files before
  recording coverage.
- **Never trust summaries.** After every batch, read the actual changed
  files and run the full test suite locally — not just the batch's
  self-reported result.
- **Isolated branch or worktree, always.** All test writes happen on a
  dedicated `superreview-<SLUG>` worktree (for worktree-based projects)
  or branch (for standard git repos), never on `main` or the caller's
  working branch. The skill does not merge. Return presents the ready
  branch/worktree; the user merges explicitly after all gates are met.
  The worktree/branch must be a **named** branch (`-b superreview-<SLUG>`),
  never a detached HEAD.
- **Dispatch-ID allowlist, always.** Record every dispatch id returned by
  `dispatch` in `/tmp/superreview-<SLUG>/run-state.json`. Step 6 waits on and
  collects only ids in that allowlist — dispatches from other concurrent runs
  are ignored. This prevents cross-run contamination (one run's completion
  mistaken for another's).

---

## Prerequisites / Preflight

Before scope gathering, verify the following. Stop with an unsupported/blocked
result if any required capability is missing.

| Requirement | Check |
|-------------|-------|
| Cowork tools available | `dispatch` / `wait` / `output` / `status` / `list` respond |
| A capable backend | `capabilities` reports an available frontier CLI backend (batch agents must run tests, so a hosted endpoint's file-only tools are insufficient) |
| Isolated worktree/branch possible | `git worktree` works, tree is clean or user approves handling uncommitted changes |

---

## Step 1 — Scope the target

Use one `AskUserQuestion` if needed. Determine:

- **Target** — what to audit: a class, a file, a package, a framework, a
  CLI binary, an MCP server, a wire protocol, an entire app — or any mix.
  Be specific about scope boundaries (e.g. "all public methods in
  `ServiceHost.ts`", "the full CLI surface of `capture`", "every exported
  function in the `auth` module").
- **Worktree path** — absolute path of the project root. All work stays there.
- **Slug** — kebab-case `[a-z0-9-]+` identifier derived from the target
  name. Used in branch/worktree names and all `/tmp/superreview-<SLUG>/`
  paths. Derive from the topic; no spaces or special characters.
- **Unit test definition** — what counts as "isolated"? (e.g. fake
  bridge, in-memory DB, stubbed filesystem). Ask if ambiguous.
- **Dev/integration test definition** — what real system must be
  reachable? (e.g. live ServiceHost socket, real target-process session, real DB).
  **Env-var guard name** (default `RUN_DEV_TESTS=1`). Ask if ambiguous.
- **Existing test locations** — where do tests currently live?

Echo resolved scope back as a **Resolved Run Contract** before proceeding:

| Field | Value |
|-------|-------|
| Slug | `<SLUG>` |
| Isolated branch/worktree | `superreview-<SLUG>` at `<absolute-path>` |
| Target layers | `<describe: e.g. TypeScript MCP server, Swift CLI, Python module, Go package...>` |
| Root path per layer | `<path per layer>` |
| Unit test command(s) | `<command per layer>` |
| Dev test command(s) | `<DEV_GUARD>=1 <command per layer>` |
| Dev-test env guard | `<guard name>` (used verbatim in all batch briefs and gate commands) |
| Suite filter(s) | `<filter strings>` |
| Typecheck command | `<command or N/A>` |

**Worktree / branch setup (before enumeration starts):**

```bash
# Require a clean tree before creating isolation
git status --porcelain
# Stop here if dirty — ask user how to handle uncommitted changes

# Check if project uses git worktrees
git worktree list
```

- If yes (multiple worktrees):
  ```bash
  git worktree add -b superreview-<SLUG> <sibling-path>/superreview-<SLUG> HEAD
  ```
  Set `cwd` to the new worktree path for all batch dispatches and gate commands.
- If no (standard repo):
  ```bash
  git checkout -b superreview-<SLUG>
  ```
  All work stays on this branch. Never touch `main` or the caller's branch.

Record the isolated path/branch name in `/tmp/superreview-<SLUG>/run-state.json`:
```json
{
  "slug": "<SLUG>",
  "baseline_sha": "<to-be-filled>",
  "branch": "superreview-<SLUG>",
  "job_ids": [],
  "batches": [],
  "targeted_attempts": {}
}
```
Schema:
- `job_ids` — flat list of all dispatch ids (the collection allowlist)
- `batches` — list of `{ "batch_id": "<ID>", "job_id": "<dispatch id>", "status": "dispatching|running|done|failed", "report_path": "<path>" }` entries. Write `"status": "dispatching"` **before** calling `dispatch`; update atomically on return.
- `targeted_attempts` — map of `"<ItemID>": <attempt_count>` for rows undergoing targeted re-dispatch. Step 7 uses this to decide BLOCKED.

Every batch dispatch:
1. Pre-write a `"dispatching"` entry in `batches` **before** calling `dispatch`
2. Append the returned dispatch id to `job_ids` and update the `batches` entry atomically on return

---

## Step 2 — Enumerate the full API surface

**(Orchestrator-only. Batch agents do not enumerate; they implement against this locked surface.)**

**This step is mandatory and must complete before any test is written.**

First, record the baseline SHA and update `run-state.json`:
```bash
BASELINE_SHA=$(git rev-parse HEAD)
# Update run-state.json: { ..., "baseline_sha": "$BASELINE_SHA" }
```

**Choose the enumeration strategy that fits the target.** There is no
fixed language list — adapt to what you are given. The guiding question
is: *what are all the things a caller can invoke, and with what inputs?*

### General principle

For each target, ask:
1. What are the entry points? (exported functions, public methods,
   CLI commands/subcommands, API routes, MCP tools, protocol messages…)
2. For each entry point, what are the inputs? (parameters, flags,
   arguments, fields, enum values, optional vs required…)
3. What does it return or produce? (output shape, side effects, errors…)

Then enumerate mechanically using the most appropriate tool for the language.

### Example strategies by target type

**TypeScript / MCP server tools:**
```bash
grep -rn "server\.tool\|export function\|export class\|export const" <src> \
  | grep -v "node_modules\|\.test\." | sort
```
Extract each `server.tool()` name + full Zod schema (every field, type,
`.optional()`, `.min()`, `.max()`, `.enum()`).

**Swift CLI / ArgumentParser:**
```bash
grep -rn "func \|@Argument\|@Option\|@Flag\|ParsableCommand" <src> \
  | grep -v "\.build\|Tests/"
```
Extract flag names, types, required/optional, valid values, defaults.
For `public func`: extract all parameters and return types.

**Python class/module:**
```bash
grep -rn "^def \|^    def \|^class " <src> | grep -v "__pycache__\|test_"
```
Extract public functions/methods (not `_private`). Note parameter names,
types (from annotations or docstrings), defaults.

**Go package:**
```bash
grep -rn "^func " <src> | grep -v "_test\.go"
```
Extract exported functions (capital first letter) with parameter lists.

**Ruby gem / Rails controller:**
```bash
grep -rn "def \|attr_accessor\|attr_reader" <src> | grep -v "spec/"
```

**React component / UI surface:**
List all exported components; extract their Props type definitions.

**Wire protocol / JSON schema:**
Enumerate the message types and their required/optional fields from the
schema or type definitions.

**When in doubt:** read the public-facing interface file (index, exports,
header, or interface file) first — it's usually the canonical surface.

### Mixed surfaces
Enumerate each layer separately and combine into a single inventory.

Write the full inventory to `/tmp/superreview-<SLUG>/inventory.md` with
this structure per item:

```
### <ItemID>: <tool/func/command name>
- Layer: <ts-mcp | swift-cli | swift-func | ...>
- File: <path:line>
- Parameters:
  | Name | Type | Required | Constraints | Notes |
  |------|------|----------|-------------|-------|
  | ...  |      |          |             |       |
- Wire/output contract: <what it sends or returns>
- Error paths: <known error conditions>
```

Surface is LOCKED once written. Do not add items mid-run without
re-running the enumeration command to justify the addition.

**Batch agents may not add, remove, or redefine surface rows.** If a
batch agent discovers a suspected inventory mismatch, it reports it in
the batch report under "Suspected inventory gaps" — the orchestrator
re-runs enumeration and decides whether to add rows before the next
dispatch cycle.

---

## Step 3 — Gap analysis

**(Orchestrator-only.)**

For each item in the inventory, check existing tests:

```bash
grep -rn "<item_name>\|<func_name>" <test_dirs> | sort
```

For each gap record in `/tmp/superreview-<SLUG>/gaps.md`:
```
### <ItemID> — <gap type>
- Missing unit tests: <list of parameter combinations not covered>
- Missing dev tests: <yes/no + what's missing>
- Pre-existing tests: <file:line refs>
```

Gaps drive the batch dispatch plan in Step 4.

---

## Step 4 — Choose the batch backend

Call `capabilities` and pick the strongest available **frontier CLI** backend —
batch agents must read code, write tests, and run the suite, which needs a
worker with its own shell and tools. One backend for every batch unless the
user says otherwise.

---

## Step 5 — Dispatch parallel batch agents

Group surface items into logical batches (8–15 items each, same layer
and same backing subsystem first, then same source module). Dispatch ALL
batches in a single message so they run truly in parallel.

**Dispatch template** (one call per batch, all in the same message):

```
dispatch(task: <the batch brief below, fully composed>,
         backend: <the Step 4 backend>,
         workspace: <isolated worktree absolute path>)
```

Record the returned dispatch id in `run-state.json` immediately.

### Batch brief template

Include ALL headings exactly as shown below. Replace every `<...>`
placeholder with the resolved value before dispatch — do not leave any
`<...>` token in the final brief. Headings are fixed; content is filled in.

```markdown
## Superreview batch: <BATCH_ID> — <short description>

### Resolved run values
*(Pre-filled by orchestrator from the Resolved Run Contract — no `<...>` tokens below)*

| Field | Resolved value |
|-------|---------------|
| Slug | `<SLUG>` |
| Language / framework | `<e.g. Swift, TypeScript, Python, Go, Ruby…>` |
| Unit test command | `<exact command>` |
| Unit fake / mock boundary | `<e.g. FakeBridgeSocket, in-memory DB, stubbed filesystem>` |
| Real system under dev test | `<e.g. live ServiceHost socket, real PostgreSQL, running gRPC service>` |
| Dev guard var | `<DEV_GUARD>` (e.g. `RUN_DEV_TESTS`) |
| Dev test command | `<DEV_GUARD>=1 <exact command>` |
| Dev test path | `<path where dev tests live>` |
| Suite filter | `<filter string>` |
| Typecheck command | `<command or N/A>` |
| Available language skills | `<comma-separated list, or "none found">` |

### Pre-flight: compile gate (MUST run before writing any tests)

```bash
# Run the resolved typecheck / compile command from Resolved run values above.
# If this fails: write COMPILE-BLOCKED to all your batch report rows and exit.
# Do NOT write tests against code that doesn't compile — tests will be meaningless.
<typecheck command from Resolved run values>
```

If the compile gate fails, write the batch report with every row set to:
`| <ItemID> | all | COMPILE-BLOCKED | 0 | FAIL | — | compile gate failed: <error> |`
then exit.

### Your surface items
*(Layer-prefixed ItemIDs required — e.g. `ts-capture`, `swift-build`, `py-resolve` — to prevent collisions on mixed-surface runs)*

<paste the inventory entries for this batch's items, verbatim from inventory.md>

### Framework & test-skill context

Before writing a single test:
1. **Check the available language skills listed in Resolved run values above.** If one matches
   (e.g. `swift-testing`, `jest`, `pytest`, `rspec`), read its SKILL.md for best-practice
   idioms — parametrized tests, fixture patterns, async handling, assertion style, teardown.
2. **If no skill is listed, look at the existing test files first.** Identify the framework
   in use (check config files, imports, existing test structure). Write in the same style.
3. **Apply the latest idioms, not legacy ones:**
   - Swift: prefer `swift-testing` (`@Test`, `#expect`, `@Suite`) over XCTest for new tests
   - TypeScript: `describe`/`it`/`expect` with the project runner; `vi.fn()` or `jest.fn()`
   - Python: `pytest` with `@pytest.mark.parametrize` for data-driven cases
   - Go: table-driven tests (`t.Run`) with subtests
   - Ruby: RSpec `it`/`expect` with `let`/`subject`

❌ Bad: writing XCTest when the project uses Swift Testing
❌ Bad: `unittest.TestCase` when the project uses pytest
❌ Bad: `assert x == y` in TypeScript when `expect(x).toBe(y)` is the idiom
✅ Good: checking `Package.swift` / `package.json` / `pyproject.toml` FIRST

### Unit test definition (non-negotiable)
Isolated — no real **<real system from Resolved run values>**. Use **<unit fake/mock from Resolved run values>**.

### Unit test quality checklist

**Definitions (apply throughout):**
- *"realistic inputs"* — representative values from the documented contract or actual production data; not toy examples like `"test"` or `0`
- *"caller actually cares about"* — what would change in the caller's behavior if the implementation were wrong; do not assert internal state or implementation details
- *"meaningful about the error"* — enough to distinguish this specific failure mode from any other; assert the error code, message prefix, or shape — not just "throws"

**Checklist scope:** Items marked with a parameter type (Wrong type, Out of range, etc.) apply once **per individual parameter**. Items without a parameter qualifier (Happy path, Zero/one/many, Test hygiene) apply once **per surface item**.

Work through this checklist for every surface item in your batch. Cross off each box as done. If a box genuinely cannot apply, write `N/A` + one-line reason inline. If an entire surface item has no testable behaviour (e.g. a pure data class with no logic, an abstract base with no implementation), mark the item `UNTESTABLE` with a one-line reason — skip the checklist for that item and record it in the batch report.

**`<ItemID> — <item name>`**

**Existing tests — audit these first**
- [ ] Read all existing tests for this item before writing anything new
- [ ] Any existing test that passes trivially regardless of implementation was fixed or deleted

**Happy path — does it work?**
- [ ] At least one test calls the item with valid, realistic inputs
- [ ] The result is asserted on the observable value, side effect, or specific behaviour that would change if the implementation were wrong — a test that only verifies no crash / no throw does not satisfy this box

**Zero / one / many**
- [ ] **Zero** — empty string, null, missing field, count=0, or empty array: item handles or rejects it correctly; assert the specific return value or rejection, not just "no crash"
- [ ] **One** — the minimal non-trivial valid input works correctly
- [ ] **Many** — a realistic volume (list of 3+, large value, repeated call) doesn't break it
  *(N/A only if the param has no concept of quantity — requires a reason)*

**Invalid inputs — one test per constraint, never bundled**
- [ ] Wrong type → one dedicated test; assert the specific error shape/code/message
- [ ] Out of range (below min, above max) → one test each; assert the specific rejection
- [ ] Missing required field → one test per required field; assert the specific error
- [ ] Invalid enum value → one test per enum *(if applicable)*; assert the specific error

**Failure modes — only real, observable ones**
- [ ] Each documented failure that can actually be triggered in tests has a test
  that triggers it AND asserts the exact error shape, code, or message that would
  distinguish this failure from any other. Flag `ORACLE-GAP` when no contract source
  exists for the expected output.
  *(Don't invent error paths not in the contract)*

**Test hygiene**
- [ ] No test calls private/internal methods or asserts internal state — internals-coupled tests fail on harmless refactors
- [ ] No test mocks the thing under test itself
- [ ] Each test sets up its own known state; no test depends on mutable state left by another test
- [ ] Each test cleans up any state it mutates (DB rows, files, sockets, env vars) regardless of pass/fail
- [ ] Where 3+ tests share the same input→output shape: parametrized/data-driven, not copy-paste

*(Repeat for every item in the batch)*

### Dev/integration test definition (non-negotiable)
Calls the **real <real system from Resolved run values>**. Guarded by `<DEV_GUARD>=1` env var.
At minimum: **one happy-path call per surface item** that confirms:
- No error returned
- Response shape matches documented contract

Dev coverage is tracked **per surface item** (not per individual parameter). One passing dev test per item satisfies this tier.
Dev tests live in: **<dev test path from Resolved run values>**

Stubs guarded by the env var do NOT count as dev tests. A dev test must
execute against the real system with `<DEV_GUARD>=1` set. If the real
system is unreachable, mark those rows `BLOCKED-DEV` in the report.

### Hard rules
- Commit per logical group (all tests for one item = one commit)
- Include commit SHA in batch report (see schema below)
- Run the full test suite (with suite filter from Resolved run values) after every commit, not just new files
- **Production fix protocol:** if a new test reveals a production bug, capture the failing run FIRST (record the exact command + output excerpt), then fix and verify green — all in the SAME commit. The Red command and output are required fields in the batch report.
- Do NOT write trivially true tests ("it exists", "it is defined")
- Do NOT mock away the thing under test
- Do NOT call private/internal methods from tests — test only the public surface
- Do NOT add or remove surface rows; report suspected gaps instead
- Conventional Commits style. No `--no-verify`. No push. No amend.

### Batch report (write before exiting)
Write `/tmp/superreview-<SLUG>/batch-<BATCH_ID>-report.md`:

#### Coverage rows
| ItemID | Param/Path | Unit Tests Added | Dev Tests Added | All Pass? | Commit SHA | Notes |
|--------|-----------|-----------------|-----------------|-----------|------------|-------|

*(For UNTESTABLE items, set Unit Tests Added = 0, Dev Tests Added = 0, All Pass? = N/A, Notes = "UNTESTABLE: <reason>". For COMPILE-BLOCKED items, set All Pass? = FAIL, Notes = "COMPILE-BLOCKED: <error>")*

#### Unit checklist evidence
| ItemID | CriterionID | Status | Test file:line or test name | N/A reason |
|--------|-------------|--------|-----------------------------|------------|

*(CriterionID = short label: `happy-path`, `zero`, `one`, `many`, `wrong-type`, `out-of-range`, `missing-required`, `invalid-enum`, `failure-mode`, `hygiene-private`, `hygiene-isolation`, `hygiene-parametrize`. Every item in your batch must have at least one row per criterion — or an explicit N/A with reason. Rows with blank Status or missing N/A reason will cause Step 6 to reject this batch.)*

#### Production fixes (if any)
| ItemID | Red command | Red output (excerpt) | Fix commit SHA | Green command |
|--------|-------------|---------------------|----------------|---------------|

Include a `### Suspected inventory gaps` section if any new surface items were found that are not in the locked inventory.

### Exit gate (must pass before committing batch report)
- [ ] Compile / typecheck gate: 0 errors (from Pre-flight above)
- [ ] Full test suite (filtered per Resolved run values): 0 failures
- [ ] `git status --porcelain` clean
- [ ] All `<...>` placeholders from Resolved run values filled in (self-check)
- [ ] Unit checklist evidence table: every item has a row per criterion (or explicit N/A with reason)
```

---

## Step 6 — Collect batch results

`wait` on each dispatch id in the `run-state.json` allowlist (re-issue while
still running — a `wait` returning "still running" is progress information,
not an error). Act only on ids in the allowlist; ignore anything else `list`
may show — it belongs to a different run.

**Watchdog:** if a dispatch shows no state change across repeated waits for
20+ minutes, check `status` for its diagnostics and `list` for supervisor
health. A dispatch that died reports a terminal state — cowork guarantees a
terminal event, so silence means running, and a stuck-forever job should be
`cancel`led and treated as a failed attempt. Do not silently stall.

For each dispatch reaching `succeeded`:
1. Call `output` — the batch's declared result
2. Compute changed files: `git diff --name-only <baseline_sha>..HEAD`
   and `git show --name-only <batch_commit_sha>` (from batch report)
3. Read every changed file — never trust the batch's summary alone
4. Run the full test suite (with suite filter from Run Contract) and confirm 0 failures
5. Read the batch report at `/tmp/superreview-<SLUG>/batch-<BATCH_ID>-report.md`
6. Verify batch-reported counts against your own grep counts. If they
   differ, mark the batch as **incomplete**, record the mismatch in
   `gaps.md`, and redispatch before using those counts.
7. **Validate checklist evidence:** every item in the batch must have a `### Unit checklist evidence` row per criterion (or explicit N/A with reason). Reject the batch (mark incomplete, redispatch) if any item has blank Status or a reasonless N/A.
8. **Handle BLOCKED-DEV rows:** for any row marked `BLOCKED-DEV` in the batch report, surface to the user immediately — which items are blocked and why. Do not pass `BLOCKED-DEV` through to the coverage gate silently. Decide: retry with dev system reachable, accept N/A with justification, or declare those rows BLOCKED.
9. **Handle COMPILE-BLOCKED rows:** surface the compile error to the user immediately. Fix the production code compile error before retargeting this batch — do not count COMPILE-BLOCKED rows as coverage.
10. **Handle UNTESTABLE rows:** verify the UNTESTABLE claim is legitimate (no behaviour to test). Accept with reason, or reject and redispatch if the item clearly does have testable logic.

For dispatches reaching `failed` / `timed_out` / `cancelled`: surface the
diagnostics to the user, do not silently skip. Redispatch or explicitly mark those
rows as unresolved in `gaps.md` — do not silently drop rows from the coverage count.

Final table counts are **orchestrator-derived only** (your grep, not the
batch self-report). Batch reports are hints for locating tests.

---

## Step 7 — Coverage table assembly

Build the two sign-off tables from the batch reports + your own test
counts (grep, not trusting batch self-reports):

### Table 1: API Items (MCP tools / public functions / CLI commands)

| Item | Layer | Parameters | Unit Tests | Dev Tests | Unit Passing | Dev Passing |
|------|-------|-----------|-----------|-----------|-------------|-------------|

One row per (item, logical parameter group). If an item has independent
parameter groups (e.g. mesh flags vs trace flags), one row per group.

### Table 2: Parameter Detail

| Item | Param | Type | Valid Values | Unit Tests | Unit Passing |
|------|-------|------|-------------|-----------|-------------|

One row per individual parameter. Dev coverage is tracked per item in Table 1 only — not per individual parameter.

**"Full test suite"** for gate purposes = all tests in the project covered by the Run Contract's suite filter for this layer. For Swift: always use `--filter`; for other languages: use whatever filter the Run Contract specifies. Never run a layer's test binary with no filter on a project where that would include long-running or destructive tests.

**Validation script** — run after each batch lands to verify the gate mechanically:

```bash
# Orchestrator runs this — not the batch agent
SLUG="<SLUG>"
FILTER="<suite filter from Run Contract>"
UNIT_CMD="<unit test command with filter>"

# 1. Run unit tests and capture pass count
$UNIT_CMD 2>&1 | tee /tmp/superreview-${SLUG}/gate-unit-$(date +%s).log
UNIT_PASS=$(grep -oE '[0-9]+ passed' /tmp/superreview-${SLUG}/gate-unit-*.log | tail -1 | grep -oE '[0-9]+')
UNIT_FAIL=$(grep -oE '[0-9]+ failed' /tmp/superreview-${SLUG}/gate-unit-*.log | tail -1 | grep -oE '[0-9]+' || echo 0)

# 2. Count tests covering each surface item
for ITEM in <ItemID list from inventory.md>; do
  COUNT=$(grep -rn "${ITEM}\|$(echo $ITEM | sed 's/-/_/g')" <test_dirs> | grep -v "\.md" | wc -l | tr -d ' ')
  echo "  $ITEM: $COUNT test references"
done

# 3. Gate check
if [ "$UNIT_FAIL" != "0" ] || [ "$UNIT_FAIL" = "" ]; then
  echo "GATE FAIL: unit failures = ${UNIT_FAIL}"
else
  echo "GATE PASS: ${UNIT_PASS} passing, 0 failing"
fi
```

Replace `<...>` placeholders with resolved Run Contract values before running.

**Acceptance criteria — ALL must hold before you exit:**
- Zero empty cells in either table
- Zero `0`s in Unit Tests or Unit Passing in Table 2 (per-parameter rows) — except rows marked UNTESTABLE
- Zero `0`s in Unit Tests, Unit Passing, Dev Tests, or Dev Passing in Table 1 (per-item rows) — stubs and guarded no-ops do **not** count; `Dev Tests` counts only tests executed with `<DEV_GUARD>=1` against the real system
- Unit Passing = Unit Tests for every row in both tables
- Dev Passing = Dev Tests for every item row in Table 1

If any criterion fails → identify the gap → dispatch a targeted batch (same backend) → collect → rebuild tables → recheck.

**Outcome taxonomy for BLOCKED escalation.** A targeted batch attempt counts as failed for escalation purposes when its outcome is any of:
- a dispatch reaching `failed` / `timed_out` / `cancelled`
- Batch report missing or malformed after completion
- Gate failed (test suite non-zero after the batch landed)
- Zero relevant rows (the batch produced no new coverage for the targeted row)

`BLOCKED-DEV` is NOT a failed attempt — it escalates immediately (Step 6) without waiting for two attempts. `COMPILE-BLOCKED` counts as one failed attempt; the second attempt should target the compile fix, not test writing.

**Bounded escalation (BLOCKED state):** after two failed targeted batches (per the taxonomy above) for the same row, stop and return a `BLOCKED` report:
- Which rows are still failing + why
- Attempts made (job IDs, output paths, outcome taxonomy label per attempt)
- `git diff --name-only <baseline_sha>..HEAD` from the isolated branch
- The exact failing gate output

This is NOT completion. Step 9's success return is not available until all BLOCKED rows are resolved.

---

## Step 8 — Final gate commands (run all resolved gates yourself)

Run every command resolved in Step 1's Run Contract. Replace `<...>`
with the resolved values — no "if applicable" guessing.

```bash
# Unit gate (per layer from resolved contract)
<unit test command(s)>

# Dev/integration gate — run with the guard ENABLED
<DEV_GUARD>=1 <dev test command(s)>

# Typecheck (if resolved)
<typecheck command>

# Isolation check — confirm work is on the right branch
git branch --show-current   # must print superreview-<SLUG>
git worktree list --porcelain  # must show isolated worktree (if applicable)

# Clean tree
git status --porcelain  # must be empty
```

All gates must show 0 failures. If Step 8 reveals any gap that requires
a code or test change, that change invalidates the Step 7 coverage tables
— return to Step 7, rebuild, and re-run Step 8 before proceeding.

Surface any gate failures to the user with the exact output before
claiming completion.

---

## Step 9 — Return to user

Return ONLY when ALL of the following are confirmed with evidence:

1. **All resolved gate commands pass** — unit, dev/integration (with
   `<DEV_GUARD>=1`), typecheck. 0 failures.
2. **Both tables fully populated** — all acceptance criteria met per Step 7.
   Tables were rebuilt AFTER the last Step 8 gate run (not stale).
3. **Work is isolated and not merged:**
   ```bash
   git branch --show-current   # must print: superreview-<SLUG>
   git status --porcelain       # must be empty
   ```
   Do not self-merge, force-push, or squash.

Your response must contain:
- **Table 1** (API items) — full, inline
- **Table 2** (parameter detail) — full, inline
- **Gate command outputs** verbatim (collapsed if long, full on failure)
- **Bugs found and fixed** — one line per production fix made
- **Run contract used** — the Resolved Run Contract from Step 1 echoed back

---

## Anti-patterns (never do these)

- Starting test writing before the inventory is complete
- Writing tests against code that doesn't compile — run the compile gate first
- Trusting batch self-reports without reading changed files
- Writing tests that always pass regardless of implementation
- Skipping the dev test tier because "unit tests are sufficient"
- Counting env-var-guarded stubs as dev/integration test coverage
- Accepting UNTESTABLE claims without verifying there truly is no testable behaviour
- Returning before both tables are fully populated
- Shelling out to an agent CLI directly instead of cowork `dispatch`
- Merging or pushing the audit branch before the user explicitly approves
- Running `swift test` without `--filter` on Swift targets (always required; for other languages use the Run Contract filter when defined)
- Letting a failing batch be silently absorbed into the coverage count
- Silently dropping `BLOCKED-DEV`, `COMPILE-BLOCKED`, or `UNTESTABLE` rows from coverage counts without surfacing them to the user
- Acting on `complete` events for job IDs not in the run-state allowlist
- Creating a detached-HEAD worktree — always use `-b superreview-<SLUG>`
- Leaving `<...>` placeholder tokens in a batch brief before dispatch
- Writing tests in a legacy style when the project already uses a modern
  framework (e.g. XCTest when the project uses Swift Testing; `unittest`
  when the project uses pytest; raw `assert` when `expect(...).toBe(...)`
  is the idiom) — always check existing tests and config files first
- Running Step 8 gates and then making further test/code changes without
  returning to Step 7 to rebuild the coverage tables
- Silently skipping the checklist evidence table — Step 6 rejects batches with missing or reasonless-N/A rows

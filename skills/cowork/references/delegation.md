# Delegation Protocol

The orchestrating agent is the **brain**: reads code, understands architecture, makes decisions, writes specs, reviews results.
The peer agent is the **hands**: implements, edits files, runs commands, executes tasks.

---

## Choosing a mode

| Mode | When to use |
|---|---|
| **COLLAB** | Architecture uncertain, need a second opinion, exploring tradeoffs |
| **DELEGATE** | Task is clear and well-understood, boilerplate, simple refactor, parallel independent tasks |
| **DELEGATE WITH REVIEW** | Complex implementation, non-trivial refactor, anything touching multiple systems, first time doing something new in this codebase |

**Default for non-trivial tasks: DELEGATE WITH REVIEW.** Codex catching a wrong assumption before writing 200 lines saves everyone time.

---

## Dispatching — the cowork tools

Every peer turn goes through cowork's own tools. There is no separate same-host
vs cross-host transport any more — cowork picks the transport for the chosen
backend (a CLI process or an HTTP endpoint) internally; the skill just calls the
tools.

| Need | Tool |
|---|---|
| Hand a task to a peer | `dispatch` (add `interactive:"true"` to keep it warm for a multi-turn session) |
| Wait for it to finish | `wait` — silence means working; re-issue while it returns "still running". Never shell-sleep to poll. |
| Read the result | `output` |
| Speak to a warm worker again (keeps context) | `send` |
| End a warm session | `finish` |
| Continue a *finished* dispatch's context in a fresh run (where the backend supports it) | `follow_up` |
| See backends + current availability | `capabilities` |

Never shell out to an agent CLI (`codex exec`, `grok`, `claude -p`) by hand —
that bypasses containment, verdict, and lineage.

### Workspace grant

A dispatch's `workspace` is the directory the worker is started in (a cwd grant,
**not** confinement — there is no read-only mode and the worker is not restricted
to it). Grant a writable workspace for implementation; omit it for read-only
review (the worker simply is not pointed at a repository), or grant a
scratch/worktree via a role tool's `workspace:"worktree"`.

### Single task dispatch

```
1. jid = dispatch(task: <full spec text>, backend: <chosen backend>,
                  workspace: <writable path, or omit for read-only>)
2. wait(jid)   # returns the state; re-issue while "still running". Silence = working.
3. On a terminal state:
   - succeeded → output(jid), then READ the actual modified files
   - failed / timed_out / cancelled → status(jid) for diagnostics; fix the spec and re-dispatch
```

A dispatch id is minted by cowork and is the stable handle for `wait` / `output`
/ `status` / `send` / `finish`. Do not sleep-poll — `wait` is the completion
mechanism.

### Parallel tasks

Issue several `dispatch` calls together (each gets its own contained worker),
then `wait` + `output` each:

```
job_a = dispatch(task=spec_a, backend=..., workspace=...)
job_b = dispatch(task=spec_b, backend=..., workspace=...)
wait(job_a); output(job_a) → read files A
wait(job_b); output(job_b) → read files B
```

---

## DELEGATE (silent) workflow

> **DELEGATE means Codex does all the lifting.** Write a spec with enough context for Codex to execute — file paths, background, acceptance criteria — then hand it over and do nothing else. Codex reads the codebase, makes the changes, runs the commands. Do not read files or research before delegating.

### Step 1: Write a precise task spec

A good spec includes:

```
## Task: <title>

You are doing all the work here — read the relevant files, understand the patterns,
make the changes, run the commands, commit. Do not ask for clarification.

### Context
<why this exists, what it connects to>

### Files to create/modify
- `Sources/Foo/Bar.swift` — add X, following the pattern in Baz.swift
- `Tests/FooTests/BarTests.swift` — add tests for Y and Z

### Acceptance criteria
- [ ] <specific, verifiable outcome>
- [ ] <specific, verifiable outcome>

### Constraints
- Follow existing patterns in <file>
- Do not touch <other file>
- Use <specific API> not <other API>

### Reference files (read these)
- `Sources/Foo/Baz.swift` — pattern to follow
- `docs/plan/...` — background

### Completion checklist (mandatory — fill in before your final message)

| # | Item | Status | Actual / note |
|---|------|--------|---------------|
| 1 | <verifiable outcome 1> | ✓ / ✗ / n.a. | <e.g. commit SHA, count, filename> |
| 2 | <verifiable outcome 2> | ✓ / ✗ / n.a. | |
```

**The completion checklist is mandatory in every spec.** It forces structured output, gives Claude a deterministic acceptance gate, and surfaces gaps (✗ rows must have a note). Mirror the acceptance criteria rows 1:1. Claude reads the filled-in table before deciding whether to approve or re-dispatch.

The spec should be complete enough that Codex can execute without asking questions.

### Step 2: Choose the right model

Pick the cheapest backend that fits. Availability and ranking come from
`capabilities` at dispatch time — never a cached model file or a
hardcoded slug. Escalate to a stronger backend only for novel, ambiguous, or
high-risk work; otherwise stay on the cheapest tier that meets the acceptance
criteria.

### Step 3: Dispatch

`dispatch` the spec to the chosen backend with a writable workspace, then `wait`
until terminal and `output`. Silence during `wait` means the peer is working.

### Step 4: Review

After the dispatch reaches a terminal state:
1. Read the peer's declared result (`output`)
2. Read the actual modified files — do NOT trust the summary alone
3. Check: does it follow existing patterns? Are types correct? Any regressions?
4. If wrong: refine the spec and re-dispatch
5. If right: continue

### Step 5: Iterate or proceed

- Wrong output → rewrite the spec more precisely, re-dispatch
- Partial output → break into smaller tasks, re-dispatch each
- Correct output → move to next task or report to user

---

## DELEGATE WITH REVIEW workflow

Same spec format as DELEGATE, but split into two phases.

### Phase 1: Spec review

**⛔ DISPATCH PROMPT DISCIPLINE — Phase 1 breaks if you get this wrong.**

The dispatched spec must open with a hard stop line BEFORE any other content:

```
⛔ PHASE 1 ONLY — do NOT write any code or make any file changes.
Read all listed source files, answer the review questions below, then STOP.
```

And the dispatch prompt (separate from the spec, when the selected transport has one) must say exactly:

```
Read [file]. Perform Phase 1 review only: read all listed source files, answer the Phase 1 questions. Do NOT write any code or make any file changes. Stop after your assessment.
```

**Never use "execute end-to-end", "execute it", or "implement" in a Phase 1 dispatch prompt.** Those phrases override the stop instruction in the spec body regardless of where it appears.

The full review block to append at the end of the spec (after the hard stop header above):

```
---

## ⛔ PHASE 1 ONLY — review before implementing

Read all the files listed above. Then answer:

1. [your review questions here]

Do NOT implement yet. Do NOT write any code or modify any files. Reply with your assessment only.
```

Dispatch the spec with `interactive:"true"` (Phase 2 will `send` to the same warm worker), then `wait` until terminal and read the review with `output`.

**Phase 2 must reach the SAME warm worker** — `send` to the interactive dispatch
from Phase 1, which keeps the whole Phase 1 context. Dispatch Phase 1 with
`interactive:"true"` for exactly this reason. A fresh `dispatch` would lose
Phase 1 and force a cold re-read.

### Phase 2: Claude addresses feedback

Read Codex's questions/concerns. For each:
- If it reveals a genuine gap: update the spec to fix it
- If it's a misunderstanding: add clarification to the spec
- If it's a valid alternative: decide and document the choice
- If it's noise: note it and proceed

### Phase 3: Execute

Send the go-ahead through the selected transport's resume/send-input primitive.

```
send(jid=<phase-1 dispatch id>,
     message="<decisions on each finding>\n\nGo ahead with implementation.")
wait(jid); output(jid)   # read the result AND the actual files
finish(jid)
```

### Phase 4: Review output

Same as DELEGATE — read the actual files, not just the summary.

---

## Anti-patterns to avoid

- **Shelling out to an agent CLI by hand** (`codex exec`, raw `grok`/`claude -p`): bypasses containment, verdict, and lineage — always use the cowork tools.
- **Sleep-polling instead of `wait`**: `wait` is the completion mechanism; silence means the peer is working.
- **Vague specs**: "improve the auth code" — Codex needs precise instructions
- **Trusting output without reading files**: always verify actual file state
- **Over-delegating**: keep architecture decisions with Claude
- **Under-specifying patterns**: always point to a reference file to follow
- **Single giant task**: break complex work into focused, independent subtasks

---

## Parallel delegation strategy

**Let Codex decide.** Include this line in every spec:

> Where tasks are independent, run them in parallel. You decide what can safely run concurrently.

Codex has full visibility into what it's doing and can make better parallelism decisions than Claude can from the outside. Claude's job is to describe the full scope clearly — not to pre-split it.

Example breakdown for "add pagination to a list view":
- Task A: `PaginationState` model + logic (no UI deps)
- Task B: Unit tests for Task A (depends on A)
- Task C: View layer pagination controls (no logic deps)
- Task D: Integration (depends on A + C)

A runs alone → B and C run in parallel → D runs last.

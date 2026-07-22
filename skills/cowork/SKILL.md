---
name: cowork
description: Collaborate with or delegate to a peer coding agent. Three modes — COLLAB (orchestrating agent + peer, back-and-forth planning/architecture discussion), DELEGATE WITH REVIEW (the orchestrating agent writes a precise spec, the peer reviews then implements, the orchestrating agent reviews), and DELEGATE (the orchestrating agent hands off lean, the peer explores and implements). Use when the user wants to discuss with a peer agent, get a second opinion, hand off implementation work, or have a peer implement. Triggers on "ask the peer", "plan with codex/grok", "delegate this", "get it implemented", "hand it off".
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion]
---

# Peer Collaboration & Delegation

> **Transport rule:** every peer turn goes through cowork's own tools — no
> other dispatch path, no agent CLI shelled out directly. The mapping:
>
> | Old transport concept | New cowork tool |
> |---|---|
> | dispatch a peer / spawn a sub-agent | `dispatch` (interactive:"true" for a multi-turn session) |
> | wait for completion (monitor / watcher) | `wait` (silence = working; re-issue while "still running") |
> | read the peer's result | `output` |
> | **resume the same peer with context** (Phase 1 → Phase 2) | `send` to the warm interactive worker |
> | end a warm session | `finish` |
> | continue a *finished* dispatch's context in a fresh run | `follow_up` |
> | pick the model / tier | `capabilities` (live availability + what each backend can do) |
>
> If the cowork tools are unavailable, surface the error to the user; never
> fall back to running an agent CLI by hand.

Three modes. Pick based on task — see `references/delegation.md` for the
decision table.

- **COLLAB** — the orchestrating agent + a peer as equals. In plan mode: a pure
  design conversation, no implementation. Out of plan mode: live pairing —
  discuss and build, the orchestrating agent reviews inline.
- **DELEGATE WITH REVIEW** — the orchestrating agent writes the spec, the peer
  reviews it (Phase 1), the orchestrating agent addresses the review, the peer
  implements (Phase 2), the orchestrating agent reviews the result. Default for
  non-trivial work.
- **DELEGATE** — the orchestrating agent writes a complete spec and hands off;
  the peer reads the codebase, implements, and runs commands. Supports parallel
  independent tasks.
- **AUDIT** — use `/cowork:audit` for a fresh-eyes one-shot audit.

## Step 1 — Mode + backend selection

Use a **single** `AskUserQuestion` with two questions — involvement and backend
— so the user picks at once. Infer involvement from context first; if the task
clearly maps to one mode, pre-select it.

**Involvement → mode:** Total collab → COLLAB · The peer does the graft →
DELEGATE WITH REVIEW · Full handover → DELEGATE.

**Backend picker — resolve live, never hardcode a model slug.** Call
`capabilities` and present the strongest available options (a frontier CLI agent
for implementation work; a hosted model for lighter reasoning). Routing is
simple: pick the cheapest capable backend that `capabilities` reports
— there is no external routing matrix to consult.

```
questions:
  - question: "How do you want to work on this?"
    header: "Involvement"
    options:
      - { label: "Total collab", description: "Go back and forth as peers — discuss, explore, plan together" }
      - { label: "The peer does the graft", description: "You set it up and review; the peer questions the spec then implements" }
      - { label: "Full handover", description: "Hand the task to the peer to implement, then review the result" }
  - question: "Which backend?"
    header: "Backend"
    options: { from capabilities — strongest CLI agent first, then a hosted option }
```

## Step 2 — Session state

Cowork now carries the peer's conversation itself, so the old `.job`/`.thread`
sidecars and transcript snapshots are gone. Track the session with the dispatch
id:

- A **COLLAB** or **DELEGATE WITH REVIEW** session is one **interactive** dispatch
  (`interactive:"true"`) kept warm across turns with `send`. Record its dispatch
  id for the whole session; that id IS the session.
- A **DELEGATE** (silent, single-shot) task is one non-interactive `dispatch`.
- **Resuming across cowork invocations:** a warm session cannot outlive the
  orchestrator, so a genuinely new invocation that wants prior context uses
  `follow_up` on the previous (finished) dispatch id — the peer starts a fresh
  run that inherits the finished dispatch's context. `follow_up` needs backend
  support (`capabilities.supports_follow_up`): Claude and Grok allow it;
  endpoints and Codex refuse it.

**Plan-mode inheritance (COLLAB):** if the orchestrating agent is in plan mode,
append to the peer's brief: *"⚠️ PLAN MODE: produce a written plan only — no file
edits, no implementation."*

## Step 3 — Run the mode

Compute the workspace grant once: a writable workspace for implementation, or
none for read-only review (omit the workspace — there is no read-only grant; an
unconfined worker simply is not pointed at a repository). Include
any project conventions once at the top of the first brief rather than repeating
them every turn.

### COLLAB

Open an interactive session and converse turn by turn. Show every turn to the
user verbatim (they read the bubbles as the conversation) — this is the only
place a turn appears:

```
# turn 1
jid = dispatch(task: <the orchestrating agent's opening message + context + a focused
               question or proposal>, backend: {backend}, interactive: "true",
               workspace: {grant})
wait(jid) → output(jid)     # the peer's reply — relay it verbatim
# turn 2+
send(jid, message: <the next turn>) ; wait(jid) ; output(jid)
...
finish(jid)                  # when the conversation concludes
```

Read every file the peer changed — never trust its summary. In plan mode neither
side writes files.

### DELEGATE (silent)

Write a precise, complete spec (see `references/delegation.md` for the spec
template + the mandatory completion checklist), then one non-interactive
dispatch and review:

```
jid = dispatch(task: <full spec>, backend: {backend}, workspace: {writable grant})
wait(jid) → output(jid)     # read the peer's declared result AND the actual files
```

Parallel independent tasks: issue several `dispatch` calls together, `wait` each,
review each. Tell the peer in the spec that it may parallelise independent
sub-work itself.

### DELEGATE WITH REVIEW

The Phase 1 → Phase 2 handoff that used to need "resume the same peer" is now a
plain interactive `send` — the warm worker keeps Phase 1's context:

```
# Phase 1 — spec review, NO implementation
jid = dispatch(
    task: <spec, opening with:
           "⛔ PHASE 1 ONLY — do NOT write code or change files. Read the listed
            source files, answer the review questions, then STOP.">,
    backend: {backend}, interactive: "true")   # no workspace grant for read-only review
wait(jid) → output(jid)     # the peer's review

# Phase 2 — the orchestrating agent addresses each finding, then the go-ahead on the SAME warm worker
send(jid, message: <decisions on each finding> + "\n\nGo ahead with implementation.")
wait(jid) → output(jid)     # read the result AND the actual files
finish(jid)
```

Never put "implement" or "execute end to end" in the Phase 1 task — it overrides
the stop. Address the peer's review honestly (genuine gap → fix the spec;
misunderstanding → clarify; valid alternative → decide and document; noise →
note and proceed).

## Step 4 — Review and close

Every mode ends the same way: read the peer's declared result, **read the actual
changed files** (cowork's verdict tells you the peer's own truth; it does not
grade the work), verify against the spec/acceptance criteria, and either
re-dispatch a sharper spec or proceed. Do NOT auto-merge, auto-push, or
auto-loop — the user decides next steps. `finish` any warm session so no worker
is left running.

## What this skill is NOT

- **Not a fresh-eyes audit** — that's `/cowork:audit` (one-shot, read-only).
- **Not a specialist review** — that's `/cowork:review` (fleet + fold-in).
- **Not a truth oracle** — cowork reports the peer's declared outcome; grading
  the work is the orchestrating agent's and the user's job.

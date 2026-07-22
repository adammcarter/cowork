---
name: audit
description: Fresh-eyes one-shot audit of an artifact (spec, plan, code change, decision, process). Read-only, no git mutations, structured report output. The auditor never sees the originating session transcript. Triggers on phrases like "audit this", "fresh eyes on this", "independent review", "/cowork:audit".
allowed-tools: [Bash, Read, Write, AskUserQuestion]
---

# Cowork Audit

Fresh-eyes, one-shot audit of an artifact by an agent with no prior context.
Output is a structured report. The auditor never sees the originating session's
transcript or any context beyond what the brief provides.

> **Transport rule:** the audit is one cowork `dispatch`, collected with
> `wait` + `output`. If the cowork tools are unavailable, surface the error;
> never shell out to an agent CLI directly.

## Core invariants

- **Fresh eyes.** Every audit is a cold dispatch. Never `send` to it, never
  `follow_up` from it — resume is off the table by design.
- **Read-only intent.** No file writes, no git mutations. Dispatch the auditor
  **without** a writable workspace grant; the brief's invariants restate the
  rule for the auditor itself.
- **Explicit scope.** The brief lists IN-SCOPE and OUT-OF-SCOPE. The auditor
  flags out-of-scope concerns in a dedicated section but does NOT investigate
  them.
- **Strict output format.** See `references/audit-output-format.md` — Verdict +
  Confidence + Findings + Out-of-scope observations + Sign-off, in that order.
  The auditor refuses to deviate; the orchestrating agent validates and
  surfaces malformed output rather than silently fixing it.
- **One-shot by default.** Audit fires, returns a report, terminates.
  Follow-ups are clarifying questions to a NEW fresh dispatch — never "now go
  fix it".

## Step 1 — Gather scope, materials, and questions

Use **one** `AskUserQuestion` call where possible; otherwise sequential prompts.

Required inputs:

1. **Topic** — one-line title (becomes the slug + report title).
2. **Scope** — concrete `In-scope` and `Out-of-scope` lists (paths, dirs,
   files, commit ranges, doc sections).
3. **Audit questions** — what are you trying to find out? What would make the
   verdict BLOCK vs CONCERN vs PASS?
4. **Materials** — paths to the artifact under audit AND its originating
   brief/spec/plan. The auditor sees only these.

Optional:

5. **Custom project notes** — a markdown file path or freeform string with the
   project's verification model / grading rules, inlined verbatim into the
   brief. For repeatability keep one committed file (e.g.
   `<repo>/.audit-context.md`) and pass its path on every audit.

**Compose the brief** from `references/audit-brief-template.md`: fill in the
answers, inline the full content of `references/audit-output-format.md` as a
`## Output format (full spec — inlined)` section, and inline custom project
notes (if provided) between Materials and Output format. The brief must be
fully self-contained — the auditor cannot resolve this skill's reference paths
from its own working directory. Write it to `/tmp/audit-brief-<slug>.md`.

**Slug rule:** sanitise the topic to `[a-zA-Z0-9_-]+`. Echo the resolved slug
and brief path to the user before dispatching.

## Step 2 — Choose the backend

Call `capabilities` and pick the strongest available backend (a frontier CLI
agent by preference — the auditor must read real files hands-on). The user may
name a backend at Step 1; honour it.

## Step 3 — Dispatch

One fresh dispatch, the brief as the task, started in the audit scope root (a cwd
grant so the auditor can read the code; a review worker is not asked to write):

```
dispatch(task: <full content of /tmp/audit-brief-<slug>.md>,
         backend: {chosen backend},
         workspace: {scope root — omit if the materials travel in the brief})
```

`wait` until terminal (re-issue while still running — silence means work in
progress). On `failed` / `timed_out` / `cancelled`, surface the diagnostics
and ask the user whether to re-dispatch.

## Step 4 — Receive and surface the report

1. `output` the dispatch — that is the verbatim audit report.
2. **Validate format.** Required sections in order: `## Verdict`,
   `## Confidence`, `## Findings`, `## Out-of-scope observations`,
   `## Sign-off`. Missing section → malformed → surface it; do NOT silently
   fix.
3. **Save the verbatim report** to `./reports/audit-<slug>-<timestamp>.md`
   (create the directory if needed) and give the user the path.
4. **Surface the report** in a plain wrapper:

```
────────────────────────────────────────────────────
  Audit Report — {topic}
────────────────────────────────────────────────────
<exact report text>
────────────────────────────────────────────────────
```

5. **Emit one line:** `Audit verdict: <VERDICT>. <N> findings (<X> blocker,
   <Y> concern, <Z> nit). Report saved to <path>.`

## Step 5 — Terminate

Do NOT auto-loop. Do NOT auto-implement findings. The user decides next steps.

- **Clarifications wanted?** Dispatch a NEW fresh audit (never resume) whose
  brief is: the original brief + the report + the specific question.
- **Findings to implement?** That is a delegation session, not this skill.

## What AUDIT is NOT

- Not a code reviewer in the GitHub sense (no inline comments, no PR
  integration).
- Not a continuous monitor — re-run for re-audit.
- Not iterative — that's `/cowork:review` (specialist fleet with fold-in).
- Not authoritative on style/preference — findings, not opinions.
- Not gating — produces a report; the user decides what to act on.

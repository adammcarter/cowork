---
description: Run an adversarial claim jury to decide whether a specific claim has grounds and produce a durable reasoning document.
---

# /cowork:jury - put one claim to an evidence jury

Use this when an agent wants to put a claim to a jury to decide whether the
claim has grounds. The jury decides whether the claim is supported enough to
rely on for the stated scope, not whether it is absolutely true in every
possible world.

The command is intentionally narrow: one run adjudicates one single claim.
Do not broaden the claim into a general audit, code review, QA run, or product
brainstorm. If the claim hides multiple claims, split them and ask which one
the user wants judged first.

Examples:

```text
/cowork:jury "Claim: The local backend path is provider-agnostic and no longer ollama-specific."
/cowork:jury "Claim: This migration is safe to run twice against production input."
/cowork:jury "Claim: The failing CI job is unrelated to this PR."
```

Default deliverable: `JURY-VERDICT.md`, a full reasoning document with the
verdict, evidence, rejected evidence, reasoning for and against the claim,
minority opinion, assumptions, unresolved questions, and what evidence would change the verdict.

---

## Pre-dispatch state machine

Do not launch a single agent until each state is complete. If the user
explicitly asks for an autonomous run, make the smallest reasonable choices,
state them compactly, and proceed.

- [ ] **claim locked** - the exact claim text is written down.
- [ ] **scope locked** - in-scope, out-of-scope, and decision use are clear.
- [ ] **evidence plan accepted** - sources, commands, files, and web policy are named.
- [ ] **panel selected** - roles and juror count fit the claim.
- [ ] **output dir named** - the user can browse the directory after the run.
- [ ] **shared brief ready** - the brief is self-contained.
- [ ] **dispatch cards ready** - each agent has a role, evidence job, and output path.

## Step 1 - Lock the claim

`$ARGUMENTS` is the claim. If empty, ask for a single claim. If it contains
multiple claims, extract the candidate claims and ask which one to adjudicate
first.

Write the locked claim in this shape:

```text
Claim under jury review:
<one sentence>

Decision use:
<what the caller wants to rely on this claim to do>

Scope:
In scope: <paths, commits, docs, runtime, current facts, or decisions>
Out of scope: <nearby claims the jury will not decide>
```

The decision use matters. A claim can have enough grounds for a local refactor
and not enough grounds for a release gate. If the decision use is unclear, ask
once; if the user does not answer in an autonomous run, choose the narrower
decision use.

## Step 2 - Plan evidence

Build an evidence plan before dispatch. Include:

- **Materials:** files, diffs, commits, docs, logs, issue links, reports, test
  output, screenshots, or user statements the jury may inspect.
- **Commands:** local commands that can test or falsify the claim.
- **Web policy:** whether web search is required, allowed, or unavailable.
- **Evidence gaps:** facts the jury probably needs but may not be able to prove.
- **High-stakes/current flag:** whether the claim is current, legal, financial,
  medical, security-sensitive, release-blocking, or otherwise high-stakes.

Current or high-stakes claims require sources. If sources cannot be obtained,
the verdict must usually be `unproven` or `partially_grounded`, not `grounded`.

## Evidence ladder

Every material point in the verdict must carry one label:

- **repo-grounded:** inspected files, tests, docs, commits, logs, or runtime output.
- **run-grounded:** based on this jury run's shared context or panel outputs.
- **user-grounded:** based on user-stated goals, constraints, or approvals.
- **web-grounded:** based on live web search, linked sources, current projects,
  standards, policies, or release notes.
- **domain analogy:** based on a named pattern from a similar domain.
- **speculative:** plausible but not established; never enough on its own for
  a `grounded` verdict.

Evidence discipline:

- Separate observation from inference.
- Never count consensus as evidence.
- Label missing evidence explicitly.
- Prefer direct primary evidence over summaries.
- If a source says only part of the claim, do not stretch it to the whole claim.
- If the panel cannot inspect a source, say so.

## Step 3 - Name the output dir

Use a browseable directory:

```text
./<slug>-jury/
```

Inside it, create:

```text
SHARED-BRIEF.md
panel/
  01-claim-advocate.md
  02-skeptic-prosecutor.md
  03-evidence-clerk.md
  04-domain-juror-*.md
JURY-VERDICT.md
```

Use a slug derived from the claim, lower-kebab-case, with enough specificity to
avoid collisions.

## Step 4 - Select the panel

Use the smallest panel that can fairly test the claim.

### Quick jury

Use for narrow, local, low-risk claims.

| Role | Job |
|---|---|
| Claim advocate | Build the strongest case that the claim has grounds. |
| Skeptic / prosecutor | Build the strongest case that the claim is unsupported, overstated, or false. |
| Evidence clerk | Separate observation from inference, grade evidence quality, and identify missing proof. |
| Foreperson | Synthesize reports and write `JURY-VERDICT.md`. |

### Standard jury

Use for claims that affect implementation choices, release confidence, user
workflow, safety, or architecture. Add 3 domain jurors.

| Role | Job |
|---|---|
| Domain jurors | Independently inspect the claim from relevant domains: implementation, tests, operations, security, docs, product, data, or UX. |

### Heavy jury

Use for high-stakes, current-market, production, security, legal/compliance, or
irreversible decisions. Add 5-7 domain jurors and require web-grounded or
primary-source evidence where current external facts matter.

## Step 5 - Write the shared brief

`SHARED-BRIEF.md` must include:

- Claim under jury review.
- Decision use.
- Scope and non-scope.
- Evidence plan.
- Materials and commands already inspected.
- Source policy and web policy.
- Verdict taxonomy.
- Evidence ladder.
- Panel roster.
- Per-agent output schema.

Do not include the originating session transcript. The jury should see the
claim, scope, and evidence materials, not the caller's private chain of
conversation.

## Step 6 - Dispatch cards

Each panel member gets a compact card:

```text
Role: <Claim advocate | Skeptic / prosecutor | Evidence clerk | Domain juror | Foreperson>
Unique job: <what this agent must decide or inspect>
File: panel/<nn-role>.md
Evidence mode: <primary expected evidence ladder label>
Required move: <try to falsify, cite primary evidence, run command, inspect diff, etc.>
Web policy: required | allowed | unavailable fallback
Final line: "Verdict recommendation: <taxonomy value> (<confidence>)"
```

The Foreperson does not write a verdict until the other panel reports exist.

## Dispatch transport

Every panel member is one cowork `dispatch` — pick a strong backend via
`capabilities` (one backend for the whole panel unless the user says
otherwise), dispatch the non-Foreperson jurors in parallel with their card +
the shared brief as the task, and collect with `wait` + `output`. The
Foreperson is dispatched last, with every panel report in its brief. Do not
resume or `follow_up` any juror — each starts fresh from `SHARED-BRIEF.md`.
If the cowork tools are unavailable, stop and report that the jury cannot run
because it has no independent panel transport; never shell out to an agent CLI
directly.

## Per-panel output format

Every non-Foreperson panel report must use:

```text
# <Role> - claim jury report

## Recommended verdict
<grounded | partially_grounded | not_grounded | unproven | hung_jury>

## Confidence
<high | medium | low> - <one sentence>

## Best case for the claim
- <point> [evidence label]

## Best case against the claim
- <point> [evidence label]

## Evidence admitted
| Evidence | Label | Supports | Limits |
|---|---|---|---|

## Evidence rejected
| Evidence | Why rejected or weak |
|---|---|

## Reasoning
<concise reasoning>

## Open questions
- <question or "none">

Verdict recommendation: <verdict> (<confidence>)
```

The Evidence clerk must additionally include:

```text
## Observation vs inference ledger
| Statement | Observation or inference | Evidence label | Notes |
|---|---|---|---|
```

## Verdict taxonomy

Use exactly one verdict:

| Verdict | Meaning |
|---|---|
| `grounded` | The claim is sufficiently supported for the stated decision use and scope. Meaningful caveats are known and do not overturn the claim. |
| `partially_grounded` | Material parts are supported, but the claim is too broad, has important caveats, or lacks proof for part of the decision use. |
| `not_grounded` | The available evidence contradicts the claim or fails to support an essential part of it. |
| `unproven` | The claim may be plausible, but the run lacks enough evidence to rely on it. |
| `hung_jury` | Credible evidence or panel reasoning remains split and the Foreperson cannot fairly collapse it to another verdict. |

Confidence is separate from verdict: `high`, `medium`, or `low`.

## Foreperson synthesis

The Foreperson reads every panel report and writes `JURY-VERDICT.md`.

`JURY-VERDICT.md` must use this format:

```text
# /cowork:jury - verdict

## Claim
<Claim under jury review>

## Verdict
<grounded | partially_grounded | not_grounded | unproven | hung_jury>

## Confidence
<high | medium | low> - <why>

## Decision use
<what this verdict permits or does not permit>

## Reasoning summary
<short answer>

## Reasoning for the claim
<strongest support, with evidence labels>

## Reasoning against the claim
<strongest objections, with evidence labels>

## Evidence admitted
| Evidence | Label | What it proves | Limits |
|---|---|---|---|

## Evidence rejected
| Evidence | Why rejected or weak |
|---|---|

## Observation vs inference
| Statement | Observation or inference | Evidence label |
|---|---|---|

## Minority opinion
<best dissent, or "none">

## Assumptions
- <assumption or "none">

## Unresolved questions
- <question or "none">

## What evidence would change the verdict
- <specific missing evidence, test, source, or runtime proof>

## Panel map
| Role | Report | Recommended verdict | Confidence |
|---|---|---|---|
```

If the Foreperson changes the verdict away from the panel majority, they must
explain why. Consensus is useful signal about interpretation, but not evidence.

## Closure

Surface the verdict and path:

```text
Jury verdict: <verdict> (<confidence>). Report: <output-dir>/JURY-VERDICT.md
```

Do not auto-implement, revert, merge, close, or mark another task complete based
only on a jury verdict. The caller decides how to use the verdict.

## What /cowork:jury is NOT

- Not a general code review. Use `/cowork:review`.
- Not a feature exercise or coverage audit. Use `/cowork:qa`.
- Not a broad idea sweep. Use `/cowork:visionaries`.
- Not a fresh-eyes audit of an artifact. Use `/cowork:audit`.
- Not a truth oracle. It decides whether the claim has grounds for a stated use.

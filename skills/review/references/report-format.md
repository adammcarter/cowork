# Specialist report — required output format

Every dispatched specialist MUST produce a report with these sections in this
order. The orchestrating agent validates the structure and surfaces a malformed
report to the user rather than silently fixing it. Inline this file verbatim
into the shared brief so every specialist carries the contract.

```
# {role tool name} — review report

## 1. Verdict
One of:

- **PASS** — no findings in my POV; the work is sound from my perspective.
- **CONCERN** — findings exist but none are blockers; ship if you accept them.
- **BLOCKER** — at least one finding I would not approve a PR over.

One-paragraph justification.

## 2. Findings
For each finding, cite specifically. Generic prose without concrete file
paths / line numbers / byte offsets is insufficient.

Each finding:

### {Finding short title}
- **Severity:** blocker | concern | nit
- **Where:** `path/to/file.swift:NNN` (or byte offset, or commit SHA, or doc path + section)
- **What:** one to two sentences describing the issue.
- **Why it matters (in my POV):** one to two sentences anchoring the finding to this specialist's perspective.
- **Recommended fix:** concrete proposal — code sketch, byte rule, missing test, doc rewrite, etc. If no fix in mind, say so explicitly.
- **Out-of-lane checks (if any):** if the finding overlaps another reviewer's POV, name the other reviewer and limit your claim to the lane-specific aspect.

If no findings, write:

> No findings in my POV — the work is sound from this perspective.

## 3. What would change my verdict
One paragraph: what would the next round need to land for your verdict to
flip (PASS → CONCERN, CONCERN → BLOCKER, or vice versa)? This drives the
iteration loop — if the answer is "nothing realistic in this scope", say
that too.

## 4. Domain reach
List the files / directories / topic areas that fall inside your POV for
this target. The iteration loop uses this to decide whether to re-dispatch
you in round 2+ when later edits touch your domain even if you found
nothing in round 1.

## 5. Lateral findings (optional)
Things that don't fit your POV but you'd flag anyway. Brief, one bullet
each, no investigation. If nothing, omit this section.

## 6. Sign-off
```
Reviewer: {role tool name}
Class: gatekeeper | advisory | closure | bespoke
Round: {1 | 2 | 3 | 4}
```
```

## Hard rules for specialists

1. **Read-only.** No file modifications, no git mutations, no test recording.
2. **Cite specifically.** File paths + line numbers + byte offsets. Vague
   prose ("the code is fragile") without concrete cites is insufficient.
3. **Stay in lane.** If a finding overlaps another reviewer's POV, limit
   your claim to your lane and name the other reviewer. Do not re-report
   another domain's obvious concern.
4. **Honest verdicts.** If nothing's wrong from your POV, say PASS. Do
   not manufacture findings to justify the dispatch cost.
5. **Class affects re-dispatch:**
   - **Gatekeeper:** expected to be re-dispatched if your findings led to
     changes in your domain, or if later edits touched your domain.
   - **Advisory:** usually one-shot. Findings are valuable even without
     patches. Do NOT manufacture patchable issues to justify re-runs.
   - **Closure (`role_review_senior`):** runs round 1 + final closure. At
     final closure, re-evaluate the PR-approval verdict given all fold-ins.

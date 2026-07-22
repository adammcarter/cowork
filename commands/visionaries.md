---
description: Run a high-variance visionary persona fleet to brainstorm and rank product, tooling, and workflow ideas.
---

# /cowork:visionaries - fire a matrix of persona visionaries to brainstorm killer features

Spin up a fleet of **visionary subagents**, each a distinct persona x point-of-view,
to brainstorm killer features/tooling/ideas for whatever you point them at. The fleet
ranges from top-end-amazing (the 10x, the magical) down to solid everyday wins, and
it must also critique where the target is weakest and most improvable.

Use this when you want a broad, high-variance idea-sweep before committing to a build:
a product/tooling brainstorm with deliberate diversity of perspective, deliberate
research, and a hard synthesis pass that turns many opinions into ranked decisions.

The **highest-variance named personas are the feature**. Keep them central, keep them
distinct, and build around them rather than flattening the fleet into generic roles.
The point is contrast: weirdness next to taste, optimism next to scar tissue, research
next to lived workflow, and UI magic next to brutal feasibility.

`$ARGUMENTS` = the brainstorm target (e.g. `/cowork:visionaries the acme-symbols-mcp
feature set` or `/cowork:visionaries our whole 24/7 tooling backbone`). If empty, ask
the user what they want the fleet to brainstorm and how wide the scope is
(one narrow artefact vs the whole project).

---

## Pre-dispatch state machine

Do not launch a single agent until each state is complete. If the user explicitly asks
for an autonomous overnight run, make the smallest reasonable choices, show the compact
plan, and proceed without waiting on non-critical polish.

- [ ] **backend selected** - user chose the agent backend.
- [ ] **project profile accepted** - user accepted or the autonomous run has a compact,
  stated profile.
- [ ] **run size selected** - Quick run, Standard run, or Summit run.
- [ ] **roster diff accepted** - final roster is shown as a roster diff against the core.
- [ ] **output dir named** - the user can browse the directory after the run.
- [ ] **shared context ready** - the shared brief passes the checklist below.
- [ ] **dispatch cards ready** - every agent has a clear persona, unique job,
  evidence mode, and web policy.

### 1. Which backend - ALWAYS ASK, NEVER ASSUME

The fleet can be built from different agent backends, and the right choice is the
user's call every time. Call cowork's `capabilities` for the live options, then ask
with `AskUserQuestion`. Offer:

- **A host-native subagent tool** (if the current host provides one) - one subagent
  per persona, run in parallel. Best for pure ideation on the host's own strongest
  model.
- **Cowork dispatch to a CLI agent backend** - one `dispatch` per persona on a
  frontier CLI agent. Best when ideas should be grounded in deep repo inspection
  (the worker brings its own tools).
- **Cowork dispatch to a hosted model backend** - cheaper/faster fleets for pure
  brainstorming where the shared context travels in the brief.
- **A mix** - some personas on one backend, some on another.

Whatever they pick, honour it for the whole fleet unless the user explicitly chooses a
mixed fleet. Never silently default. Cowork-dispatched personas are collected with
`wait` + `output`; never resumed.

### 2. Build a project profile before proposing the roster

Tailoring the fleet to the project is mandatory. Before proposing personas, quickly
inspect or ask enough to write a compact project profile:

- **Project type / domain:** product, internal tooling, UI, infrastructure, research,
  reverse engineering, data pipeline, agent workflow, library, game, docs, or another
  concrete category.
- **Current maturity:** sketch, prototype, active production tool, mature product,
  brittle legacy surface, or unknown.
- **Primary users / beneficiaries:** who uses it, who maintains it, who is blocked by
  it, and who would care if it became dramatically better.
- **Constraints and culture:** speed, reliability, correctness, cost, compliance,
  aesthetics, compatibility, local-first, privacy, developer ergonomics, or anything
  else that shapes good ideas.
- **Likely weak zones:** where the project may be underpowered before the fleet starts:
  onboarding, feedback loops, trust/provenance, observability, performance, polish,
  interoperability, research grounding, operability, or maintainability.

Show this profile to the user in 5-8 bullets. Ask whether anything is wrong or missing.
Do not proceed to the roster until the profile is acceptable, unless the user has
explicitly asked for an autonomous run.

### 3. Run size and roster budget

Use **core + packs** instead of "more is always better." More personas are useful only
when they add genuinely different pressure. Every added persona must have a distinct job,
a distinct output file, and a reason to exist in this target.

- **Quick run:** 10 agents. Use the named core, then add only the most relevant
  project-specific voice.
- **Standard run:** 12-16 agents. Use the named core plus 1-3 Persona packs that match
  the project profile.
- **Summit run:** 18-24 agents. Use the full starting roster plus selected Persona
  packs and candidates. This is for broad overhauls, roadmap work, or "all of them go"
  requests.

For every run, present a **roster diff against the core**:

```text
Core kept: the brutal visionary, the wildcard, daily power-user, skeptic, ...
Added for this target: Command Designer (Command UX), Maintenance Economist (operability)
Cut or merged: visual/spatial thinker -> merged into Demo Director
Why this shape: <one paragraph tied to the project profile>
```

If the user says "all of them," use Summit run, but still merge obvious duplicates and
write down why every added voice is worth the extra attention.

### 4. The persona matrix - propose it, tailor it, then agree it

Write out the proposed persona table and explicitly ask the user: *which personas to
keep, cut, change, or add?* Use the project profile to **Tailor the fleet**: rename
lenses, add one project-specific persona, and adjust which agents search, inspect code,
challenge assumptions, or focus on user experience. Only dispatch once the user has
signed off on the final roster, unless they explicitly asked for autonomous execution.

The matrix should span: **product taste, the daily user, adjacent stakeholders,
adversarial/red-team pressure, deliberately left-field thinking, deliberately
contrarian/minimalist pressure, expert knowledge, deep experience, young idealism,
internet-grounded comparison, clean intuitive UI taste, and maintainability.**
Diversity of POV is the whole point; a roster of ten similar optimists is worthless.

#### Named core

Always include these unless the user explicitly cuts one after seeing the roster.
The Quick run adds one project-specific or pack persona to reach at least 10 agents.

| # | Persona | Lens |
|---|---|---|
| 1 | **The brutal visionary** | Product taste - strip to the essential, make it magical; kill the mediocre |
| 2 | **The wildcard** | Pure left-field - synesthetic, playful, frame-breaking; the weird idea that's secretly genius |
| 3 | **The daily power-user** | The everyday grind - what kills 100 manual steps a day |
| 4 | **The skeptic / red-team** | Adversarial - where it lies, rots, misleads; the guardrails that stop it |
| 5 | **The contrarian/minimalist** | Fewer, sharper primitives; attack bloat; what lets you DELETE code |
| 6 | **The young idealist** | Fresh ambition - assumes the project can become 10x better and is not yet trained to accept the boring compromise |
| 7 | **The old timer** | Many years experience - remembers which ideas fail in practice, what lasts, and what future maintainers will curse |
| 8 | **The bookworm** | Exhaustive topic knowledge - has read all the books, patterns, docs, case studies, and prior art on the subject |
| 9 | **The internet researcher** | Searches for existing related topics/projects/features, competitor patterns, open-source analogues, and current best-in-class examples |
| 10 | **The UI guy** | A clean, simple, magical feeling UI - intuitive flows, invisible complexity, and delightful polish without clutter |

#### Starting roster (adapt per target - this is a default, not a fixed list)

Use this roster for Standard and Summit runs, then tune it with the project profile.

| # | Persona | Lens |
|---|---|---|
| 1 | **The brutal visionary** | Product taste - strip to the essential, make it magical; kill the mediocre |
| 2 | **The wildcard** | Pure left-field - synesthetic, playful, frame-breaking; the weird idea that's secretly genius |
| 3 | **The daily power-user** | The everyday grind - what kills 100 manual steps a day |
| 4 | **The shipping engineer** | The bridge from idea -> shipped, tested, working code |
| 5 | **The systems/fusion architect** | Make the parts behave like one coherent whole |
| 6 | **The skeptic / red-team** | Adversarial - where it lies, rots, misleads; the guardrails that stop it |
| 7 | **The ops/SRE** | Reliability & scale - uptime, latency, drift-detection, observability |
| 8 | **The newcomer / onboarding** | First-hour experience - orient a cold user/agent in 5 minutes |
| 9 | **The automation maximalist** | Self-driving loops that make progress 24/7 |
| 10 | **The visual/spatial thinker** | Making the invisible visible - maps, graphs, heatmaps |
| 11 | **The performance fanatic** | Instant everything - zero-wait, never recompute |
| 12 | **The provenance/trust lens** | Verifiable chains - prove every claim, reproducibility, tamper-evidence |
| 13 | **The contrarian/minimalist** | Fewer, sharper primitives; attack bloat; what lets you DELETE code |
| 14 | **The domain stakeholder** | Whoever the work ultimately serves (end user, community, preservation...) - tailor to target |
| 15 | **The young idealist** | Fresh ambition - assumes the project can become 10x better and is not yet trained to accept the boring compromise |
| 16 | **The old timer** | Many years experience - remembers which ideas fail in practice, what lasts, and what future maintainers will curse |
| 17 | **The bookworm** | Exhaustive topic knowledge - has read all the books, patterns, docs, case studies, and prior art on the subject |
| 18 | **The internet researcher** | Searches for existing related topics/projects/features, competitor patterns, open-source analogues, and current best-in-class examples |
| 19 | **The UI guy** | A clean, simple, magical feeling UI - intuitive flows, invisible complexity, and delightful polish without clutter |

### Persona packs

Use packs to tailor the run without turning the command into an unbounded crowd.
Candidates are optional pack members, not automatic additions.

| Pack | When to use | Candidate voices |
|---|---|---|
| **Evidence & Research** | Claims need grounding, prior art, competitors, standards, or reproducibility | **Evidence Prosecutor**, the bookworm, internet researcher, provenance/trust lens |
| **User Reality / Product** | The workflow may be too agent-centric, too abstract, or detached from actual users | **Field Anthropologist**, daily power-user, domain stakeholder, **Decision Scientist** |
| **Command UX** | The command, CLI flow, UI, or prompt surface needs to feel obvious and magical | **Command Designer**, **The UI guy**, **Accessibility Advocate**, **Demo Director** |
| **Maintenance / Operability** | The ideas must survive real ownership, support, release, and debugging pressure | **Maintenance Economist**, old timer, ops/SRE, shipping engineer |
| **Risk / Failure** | The target has trust, safety, correctness, or regression risk | **Failure Historian**, skeptic/red-team, Evidence Prosecutor, provenance/trust lens |
| **Weirdness / Bets** | The user asked for high variance, big swings, or new categories | the wildcard, young idealist, visual/spatial thinker, Demo Director |
| **Adoption / Communication** | The project needs onboarding, demos, migration, or stakeholder clarity | newcomer/onboarding, **Budget / Attention Accountant**, Demo Director, Field Anthropologist |

### Candidate library

Use this library when building the roster diff. A candidate can be promoted into the
default roster only after repeated runs prove that it adds non-overlapping value.

- **Evidence Prosecutor** - audits claims, demands proof, separates observation from
  inference, and attacks vague "best practice" language.
- **Field Anthropologist** - watches actual behavior and asks what users do under
  pressure, not what the tool designer imagines they do.
- **Command Designer** - specializes in command affordances, option shape, defaults,
  failure messages, and the feel of a CLI/API surface.
- **Synthesis Editor / disagreement arbiter** - turns many agent files into one clear
  board, naming tradeoffs without sanding them down.
- **Maintenance Economist** - prices ideas in future support cost, ownership load,
  migration risk, and deletion opportunity.
- **Accessibility Advocate** - checks whether the idea works for varied users,
  modalities, devices, cognitive load, and assistive tooling.
- **Budget / Attention Accountant** - protects token budget, user time, cognitive load,
  and dispatch count; asks what the workflow can skip.
- **Failure Historian** - writes the postmortem before the idea ships; finds how it
  will break, drift, be misread, or become unmaintained.
- **Demo Director** - asks what would make the capability instantly visible,
  memorable, and easy to sell or teach.
- **Decision Scientist** - designs scoring, experiments, choice architecture, and
  tie-breakers so the brainstorm leads to action.

---

## Evidence ladder

Every idea and weakness needs evidence or rationale, but not all evidence is equal.
Agents must label their support with one of these modes:

- **repo-grounded:** inspected files, tests, docs, issues, commands, or runtime output.
- **run-grounded:** based on this fleet's shared context, profiles, or observed agent
  outputs.
- **user-grounded:** based on user-stated goals, constraints, complaints, or approvals.
- **web-grounded:** based on live web search, linked sources, current projects,
  competitors, or standards.
- **domain analogy:** based on a named pattern from a similar domain.
- **speculative:** plausible but not yet evidenced; useful only if labeled honestly.

For current-market or best-in-class claims, require a source or label as inference. If live
web access is unavailable, the internet researcher must say so and fall back to repo,
docs, issues, and prior-art inspection without pretending the search was current.

### Evidence cards

Put reusable evidence in the shared context or a short `EVIDENCE-CARDS.md` note when a
run has enough concrete findings to reuse across agents. Each card should include:

- **Claim:** one sentence.
- **Support:** source, file, command output, user statement, or reasoned analogy.
- **Evidence mode:** repo-grounded, run-grounded, user-grounded, web-grounded, domain
  analogy, or speculative.
- **Use in synthesis:** idea support, weakness support, conflict, or open question.

---

## How to run the fleet

1. **Pick an output dir** the user can browse - e.g.
   `./<topic>-visionary-fleet/` with an `ideas/` subdir. State the path.
2. **Write one shared-context file** (`SHARED-CONTEXT.md`) every agent reads, so you do
   not repeat the brief N times.
3. **Write dispatch cards** before launching agents.
4. **Dispatch all agents in parallel** (one message, multiple tool calls; or background
   dispatch). Each agent reads `SHARED-CONTEXT.md`, adopts persona + lens, then writes
   its own `ideas/NN-persona.md`.
5. **Stay in character** is a real instruction. Wild personas must lean in, but every
   idea and critique must carry a real value hook and be concrete enough to build or
   investigate.
6. **Let the internet researcher search when tools allow it.** Internet research
   findings feed shared Evidence cards; they must not stay isolated in one agent file.

### Shared context quality checklist

`SHARED-CONTEXT.md` must cover:

- Target boundaries: what the project/target IS and what is out of scope.
- Project profile: domain, maturity, users, constraints, culture, and likely weak zones.
- Non-goals: what the fleet should avoid optimizing for.
- Evidence inspected: repo files, docs, commands, screenshots, links, user notes, or
  explicit "not inspected" gaps.
- Assumptions: what the orchestrating agent is inferring.
- Per-agent differentiators: how this roster avoids twelve copies of the same voice.
- Open questions: known unknowns that should shape the synthesis.
- Source policy: when agents may browse, when they must cite, and when they must label
  claims as speculative.
- Output schema: the exact per-agent format below.

### Per-agent dispatch card

Before dispatch, each persona gets a compact card:

```text
Persona: <name>
Pack/source: named core | starting roster | optional pack | project-specific
Unique job: <what this agent must do that no other agent is doing>
File: ideas/NN-persona.md
Required move: <e.g. propose one deletion, cite prior art, name one failure mode>
Evidence mode: <primary expected ladder label>
Web policy: allowed | required | unavailable fallback
Final summary: two sentences: best idea + sharpest weakness callout
```

### Per-agent output format (put this in `SHARED-CONTEXT.md`)

```text
# <persona> - visionary ideas
**Lens:** <one line>
**Pack/source:** <named core | starting roster | optional pack | project-specific>
**Unique job:** <one sentence>

## Killer ideas (the 10x, the magical)
### <title>
- **What:** <concrete - what tool/feature, what it does>
- **Why it's killer:** <value - what it unlocks / saves / makes possible>
- **Rough effort:** <S/M/L/XL + one-line why>
- **Depends on:** <prerequisites, if any>
- **Evidence or rationale / Evidence ladder:** <label + repo evidence, user pain,
  domain pattern, web finding, or reasoned argument>

## Solid everyday wins (the grind-killers)
### <title>
... same shape ...

## Where this project is weakest
### <weak area>
- **What is weak:** <specific gap, friction, risk, or missed opportunity>
- **Why it matters:** <cost, user pain, reliability risk, strategic downside>
- **Severity:** <high | medium | low + why>
- **Improvement opportunities:** <concrete ways to make it better>
- **Evidence or rationale / Evidence ladder:** <label + support>

## Wildcard / left-field (optional, encouraged for the wild personas)
### <title>
... same shape ...
```

Aim for 6-12 ideas per agent plus 2-5 weakness/improvement notes. Quantity matters,
but generic filler is worse than a smaller set of sharp ideas.

---

## After the fleet returns - synthesis contract

Default deliverable: **one ranked master board plus a weakness map** across all agents.
For mature or self-improving runs, also write `PERSONA-CANDIDATES.md`.

### Extraction pass

Before ranking, do a mechanical extraction pass:

- Give every idea an ID (`I-001`, `I-002`, ...).
- Give every weakness an ID (`W-001`, `W-002`, ...).
- De-duplicate obvious repeats and keep the strongest phrasing.
- Build a **convergence ledger**: which ideas/weaknesses appeared across multiple
  personas, and whether they agreed for the same reason.
- Build a **conflict docket**: where maximalist vs minimalist, speed vs rigor, or
  UI polish vs implementation cost disagree.
- Name a **disagreement arbiter** for each serious conflict: the deciding criterion,
  experiment, user preference, or owner needed to settle it.
- Label every item with a disposition: **build-now**, high-value, strategic,
  nice-to-have, trial, watch, reject, or left-field.
- Include one explicit **what not to build** section and one
  **weird-but-worth-prototyping** item if the fleet produced a plausible wild bet.

### `RANKED-BOARD.md`

- Rank by value x feasibility. Group into tiers such as **Build-now**, **High-value**,
  **Nice-to-have**, and **Left-field-but-watch**.
- For each ranked idea: ID, one-line what, value, rough effort, personas, convergence,
  dependency, evidence ladder label, and the evidence or rationale.
- Call out disagreements explicitly. The tension is where the real decision lives.
- Include the conflict docket and the disagreement arbiter notes.
- Include `what not to build` so deletion and restraint get equal status with additions.
- End with **"my recommended top N to build first"** plus why.

### `WEAKEST-AREAS.md`

- Group weakness notes into themes: product clarity, user workflow, reliability,
  research grounding, feedback loops, polish, trust/provenance, performance, project
  tailoring, maintainability, or whatever the fleet actually found.
- For each weak area: ID, problem, why it matters, **severity**, personas, evidence
  ladder label, and best improvement opportunities.
- Separate **fix-now weaknesses** from **strategic opportunities** and **watch** items.
- Include evidence or rationale for every major claim. If the claim came from web
  research, include the source summary or link when available.
- End with **"the 3 sharpest improvements"**: concrete, buildable changes that would
  most improve the target.

### `PERSONA-CANDIDATES.md`

Write this when the run surfaces better personas, duplicate personas, or future packs.
It is the fold-back lane for improving `/visionaries` itself without bloating every run.

For each candidate:

- **Candidate disposition:** promote to default roster, add to optional pack, keep
  project-specific, trial, merge, reject, or retire.
- **Why:** what unique pressure it adds.
- **Evidence:** which idea IDs, weakness IDs, conflicts, or user reactions prove value.
- **Overlap:** which existing persona it might replace or merge with.
- **distinct-job test:** the one job this persona does better than the existing fleet.

Promotion bar:

- **promote** only when the candidate repeatedly creates top-ranked ideas, sharp
  weakness calls, or important conflicts that the existing personas missed.
- **merge** when two personas produce the same pressure but one name is clearer.
- **retire** when a persona routinely creates filler, duplicates another voice, or has
  no stable output contract.
- Keep some candidates as **optional pack** or **project-specific** voices instead of
  growing the **default roster** forever.
- **trial** weird voices before promoting them. **reject** candidates that are vivid but
  do not improve decisions.

Then present the board, weakness map, and candidate notes to the user. Do not start
building off the board without the user's go; this command produces ideas and
improvement feedback to rank, not a mandate.

## Notes

- This command is idea-generation and critique, not execution. It pairs naturally with
  `/cowork` (DELEGATE/COLLAB) once the user picks what to build.
- Re-runnable: point it at any target, agree a fresh roster, get a fresh board,
  weakness map, and optionally persona-candidate fold-back.
- The persona files plus `RANKED-BOARD.md`, `WEAKEST-AREAS.md`, and
  `PERSONA-CANDIDATES.md` are the artefacts. Keep them; they are a record of the
  design thinking and the improvement pressure.

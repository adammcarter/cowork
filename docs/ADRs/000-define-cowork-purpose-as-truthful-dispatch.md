# ADR 000: Define cowork's purpose as truthful dispatch

## Status

Accepted - 2026-07-16

## Context

Cowork exists so that an orchestrating agent can run other agents — CLI agents
such as Codex and Claude, or model endpoints, whether locally hosted or remote —
and find out what actually happened.

Two forces shape this decision.

**A tool like this attracts scope without limit.** Once something can run
agents, every adjacent capability has a plausible claim on it: choosing the best
worker, ranking models, budgets and quotas, workflow languages, adapter
marketplaces, remote workers, node identity. Each is defensible in isolation.
Together they replace a small tool with a distributed platform, and the thing
callers actually needed — run an agent, find out what happened — becomes a
detail inside it. Without a purpose narrow enough to *refuse* work, there is no
principled way to say no to any of it.

**A delegation tool's whole value is truth.** If cowork says a subagent
succeeded when it failed, the error is silent: the orchestrator builds on a
result that does not exist. That failure mode is worse than having no tool,
because a missing tool is obvious and a lying one is not. Truthfulness is
therefore not a quality attribute to be traded against convenience — it is the
product.

Constraints that hold regardless of implementation:

- Four host CLIs (Claude Code, Codex, Copilot, OpenCode) consume cowork on macOS.
- Locally hosted models are a first-class target, not a variant of hosted ones.
- Backends genuinely differ in what they can do. Those differences are real and
  cannot be abstracted away without lying about one of them.

Non-goals for this record: it does not choose a language, transport, storage
engine, or process model. Those follow from the purpose and are recorded
separately.

## Decision

**Cowork dispatches work to an agent and manages that dispatch. Truthfully.
That is all.**

Binding consequences of that sentence:

1. **The noun is a dispatch.** A dispatch targets one agent — a CLI agent or a
   model endpoint, local or hosted — and has one lifecycle.
2. **Truth beats convenience.** A dispatch's terminal state is the **worker's own
   declared outcome**. Process exit codes are diagnostics, never the verdict. A
   worker that exits 0 having declared an error is failed.
3. **Cowork holds no opinions.** It does not choose workers, rank models, price
   work, or model workflows. It reports facts — including capabilities and live
   availability — and lets the caller decide.
4. **Capability differences are reported, never papered over.** Where backends
   genuinely differ, cowork reports the difference rather than inventing a
   uniform abstraction that lies about one of them.
5. **"Delegate" and "collab" are caller patterns, not runtime concepts.** The
   runtime never learns those words. One dispatch reads as delegation; several
   threading context read as collaboration. Cowork cannot tell and must not care.
6. **Skills are callers, not the runtime.** Orchestration patterns — specialist
   review fleets, juries, brainstorms, audits — are expressed in prose and
   consume the dispatch runtime. They would work over any honest one. The
   runtime does not know they exist.

This applies to every future change to the cowork runtime. A proposed capability
must be expressible as *dispatching work* or *managing a dispatch*. If it is
not, it does not belong in cowork without a new ADR that supersedes this one.

## Consequences

**Positive**

- There is a refusal criterion. Marketplaces, fleets, budgets, enrollment, and
  ranking are out by construction rather than by argument.
- The runtime stays small enough to hold in one head, which is what makes it
  auditable and therefore trustworthy.
- The skills layer evolves independently of the runtime, and vice versa.
- Locally hosted models are served by the same path as everything else.

**Negative and accepted costs**

- **Callers carry more.** Choosing a backend is the caller's job. That is
  deliberate, and it is real work pushed outward.
- **Honest capabilities are harder to consume than a uniform lie.** Callers must
  handle backends that differ. A tidier abstraction would be more comfortable
  and would be false.
- **Truthfulness is per-backend work.** Every driver must parse its worker's own
  declared outcome rather than reading an exit code. That is the expensive part
  of the product, and it cannot be shared between drivers.
- **Narrowness will feel wrong periodically.** Useful ideas will be refused
  because they are not dispatch. The cost of that discipline is real; the cost of
  abandoning it is a platform nobody asked for.

**Follow-up**

- ADR 001 records the tool contract that expresses this purpose.
- Automatic worker selection is deferred, not rejected: a future ADR may add it
  as a supplementary layer over truthful capability facts, never as a hidden
  router.

## Validation and evidence

The truthfulness rule was proven by performed journey against a real locally
hosted endpoint on 2026-07-16, not by a unit test:

```text
  succeeded  j_23C17A68  local-fast        parent=j_parent01  root=s_claude_a91c
  failed     j_69208241  local-truncating  endpoint.truncated,finish_reason=length
  failed     j_30D5AE08  local-dead        endpoint.unreachable,code=-1004
```

The middle line is the decision made real. The endpoint returned **HTTP 200 with
genuine content**, and cowork reported `failed`, because the worker declared
`finish_reason: length`. A seam that reads the transport instead of the worker
calls that success and hands back a truncated answer. HTTP 200 is an endpoint
backend's "exit code" — a diagnostic, never the verdict.

The complementary proof, from the same runs: cowork does **not** grade work. Two
models were given the same task; one answered correctly, one answered wrongly,
and both were reported `succeeded` because both workers declared they were done.
Cowork reports what happened. Judging the result belongs to the caller.

## Confirmation

The decision is being followed when every tool in the public contract is
recognisably *dispatch* or *manage a dispatch*, and when no runtime code
contains the words delegate, collab, fleet, rank, or budget.

It is working when a dispatch that fails is reported as failed — verified by a
performed journey against a real backend, not by a unit test.

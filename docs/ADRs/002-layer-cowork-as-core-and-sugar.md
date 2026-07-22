# ADR 002: Layer cowork as core and sugar

## Status

Accepted - 2026-07-16
Amended - 2026-07-22 (rule 4: the surface is 10 core + N role tools, additive and namespaced)

Depends on: [ADR 000](000-define-cowork-purpose-as-truthful-dispatch.md),
[ADR 001](001-fix-the-tool-list-as-cowork-public-contract.md),
[ADR 003](003-bound-workers-to-their-orchestrator-without-a-daemon.md).

## Context

[ADR 000](000-define-cowork-purpose-as-truthful-dispatch.md) makes cowork's core
deliberately opinionless: dispatch work, manage the dispatch, tell the truth.
That is correct for the core and insufficient as a product. `dispatch` is a
swiss army knife — powerful, and it leaves every caller to re-derive how to run
a reviewer, a QA pass, a planner, or a plan implementer, every time.

The value users actually reach for lives one level up: structured helpers that
already know how to do a job well. Those helpers are opinionated by nature — a
plan implementer holds views about working through steps, marking progress, and
proving completion. They must also be **customisable**: the opinions are the
user's, not cowork's, and they change per project.

This creates an apparent conflict with ADR 000's "cowork holds no opinions". It
is resolved by layering rather than by compromise.

## Decision

Cowork is **two layers**.

```text
  Layer 2 — sugar        opinionated, customisable, high value
  reviewers · fleets · qa · planners · plan implementers · ...
        │ composes a task, then calls ↓
  Layer 1 — core         no opinions: dispatch, manage, tell the truth
```

1. **ADR 000's "no opinions" governs the core only.** The sugar layer exists to
   have opinions. That is its purpose, not a violation.
2. **Sugar may only use the core's public tools** ([ADR 001](001-fix-the-tool-list-as-cowork-public-contract.md)).
   It gets no private hooks. If a helper cannot be expressed over the public
   contract, the contract is wrong and is fixed in the open — the helper does not
   reach inside.
3. **A role is data, not code.** A helper is defined by a file — prompt template
   plus declared injection slots — so users add and customise roles by editing
   files, with no code change and no release.
4. **Each role becomes its own tool, additive on top of the core ten.** The
   exposed surface is **the 10 core tools ([ADR 001](001-fix-the-tool-list-as-cowork-public-contract.md))
   plus N role tools** — one dynamically-surfaced tool per role file, loaded at
   runtime and each individually named and described. A caller finds
   `role_plan_implementer` by its description; it would never guess a generic
   `dispatch_as(role: ...)`. Role tools are **strictly additive and namespaced**
   (a `role_` prefix), so a role can never remove, rename, reshape, or shadow a core
   tool — the 10 core tools remain present and unchanged whatever roles exist, and
   deleting every role file leaves exactly the 10-core contract. The dynamic
   file-driven list is feasible against the Swift MCP SDK, proven live 2026-07-22
   (`tools/list` = 10 core + file-derived `role_*` tools; the role set is re-read on
   every `tools/list`, so a new or edited `.role` file takes effect with no restart).
5. **Slots are hard edges.** A role declares named injection points; callers fill
   them. The caller supplies specifics, the role owns structure. Roles do not
   accept an unbounded free-text slot, because a slot that accepts anything
   guarantees nothing.
6. **The composed task is inspectable.** Whatever prompt a helper builds is
   observable by the caller. A layer that silently rewrites a task lies in the
   same way a layer that misreports an outcome lies, and ADR 000 forbids both.
7. **Fleets introduce no new concept.** A fleet is N dispatches sharing a parent.
   Attribution ([ADR 001](001-fix-the-tool-list-as-cowork-public-contract.md))
   already groups them: `list` scoped to that parent *is* the fleet. There is no
   fleet object, no fleet state, and no workflow compiler.
8. **The core owns *where* work happens; sugar owns *provisioning* it.** The core
   receives a workspace path and starts the worker in it — a cwd grant, **not**
   filesystem confinement (see ADR 003). It never creates or destroys one, and it never learns what git is — a core that
   knows `git worktree add` is a git tool, and it would be dead weight for every
   endpoint dispatch that has no repository. Creating a worktree for a dispatch
   and tearing it down after is therefore a sugar concern: a role dispatcher takes
   `workspace: "worktree"`, creates it, and passes the path.
9. **Teardown is a core hook, not a core opinion.** A dispatch may carry an
   `on_terminal` command, run by its supervisor
   ([ADR 003](003-bound-workers-to-their-orchestrator-without-a-daemon.md)) when
   the dispatch reaches a terminal state. Sugar passes `git worktree remove`; the
   core runs a command and does not know what it is for. This is what keeps
   provisioning in sugar while making teardown mechanical: the caller cannot be
   relied on to clean up (it drifts, per rule 2's reasoning), and the worker
   cannot remove the ground it stands on — least of all if it crashed.
10. **Teardown is conditional on outcome, and failures are kept.**

    ```text
    succeeded  -> tear down    nothing to inspect; do not litter
    failed     -> KEEP         the evidence is the point
    cancelled  -> KEEP
    ```

    The path of a kept workspace is reported. Unconditional cleanup destroys the
    evidence a failure exists to provide, which is a truthfulness failure wearing
    the costume of tidiness. A ten-worker fleet leaves nine clean and the one you
    need to look at.

## Why sugar is tools, not skills

The alternative was to ship the sugar as skills: prose an agent reads, then
composes core tools itself each time it wants a plan implementer or a QA pass.
Rejected, because a skill is an instruction an agent may drift from, and a tool
is executed rather than interpreted:

- **Determinism.** The same role produces the same composed task every time. A
  skill produces whatever the agent remembered, paraphrased, under whatever
  context pressure it was under.
- **Non-forgettable application.** Skills degrade exactly when they matter most —
  a long, loaded session is when standards get skipped, and it is also when a
  subagent most needs them. A tool applies them whether or not the caller
  remembers they exist.
- **Cost.** A skill spends the orchestrator's context on every use. A tool spends
  none.
- **Enforceable shape.** Declared slots are checked. Prose asking an agent to
  include four things guarantees none of them.

The prose does not disappear — it moves into the role file. The distinction is
that its *application* is mechanical. Skills remain the right form for genuine
judgement loops (deciding which specialists a review needs, folding findings
back in, knowing when to stop), and those skills call these tools.

## Validation and evidence

Rule 8's split — the core owns *where*, sugar owns *provisioning* — was exercised
on 2026-07-16 by a real agentic dispatch into a granted workspace. A local model
read and wrote files through cowork-executed tools confined to that directory, and
a path outside the grant is refused with the refusal returned to the model as a
tool result, so the model learns it may not go there rather than cowork silently
doing something else.

The confinement mechanism differs by backend family, and the difference is real:

| Backend | Who enforces the workspace |
|---|---|
| CLI agent | Not confined in the current build — cowork starts the worker in the workspace directory (a cwd grant) but does not sandbox it. Seatbelt confinement was proven feasible in a spike ([ADR 003](003-bound-workers-to-their-orchestrator-without-a-daemon.md)) but is not shipped. |
| Endpoint | Cowork's own code. The model runs elsewhere; cowork executes the tools, so the grant is enforced by refusing the call. |

**Not proven.** No model has yet *attempted* to escape an endpoint workspace
grant, so the refusal path is implemented and reasoned about but not
demonstrated under adversarial pressure. Roles-as-data and one-tool-per-role
(rules 3 and 4) are **built**: a feasibility check proved the Swift MCP SDK serves a dynamic,
file-driven tool list (`tools/list` returned the 10 core tools plus a `role_*`
tool per `.role` file, each described from its file), with live reload by
re-reading the role set on every `tools/list`. The production roles layer —
the template + declared-slot format, slot enforcement, the inspectable composed
task, and `on_terminal` teardown — ships today (see `Sources/CoworkCore/Role.swift`
and the `roles/*.role` files surfaced as `role_*` tools).

## Consequences

**Positive**

- The core stays small and auditable while the product stays useful.
- Users' working standards live in role files instead of being re-explained to
  every subagent by hand.
- Roles ship, fork, and evolve without touching the runtime; a bad role is a bad
  file, not a bad release.
- The layering is testable: sugar calling only public tools means the core can be
  replaced wholesale without breaking a single helper.

**Negative and accepted costs**

- **Two layers is a boundary to police.** The pressure to give one helper "just
  one hook" into the core will be constant and reasonable-sounding. Every such
  hook dissolves the layering, and the discipline has no enforcement beyond
  review.
- **Roles as data means roles can rot.** Prompt templates drift from the CLIs and
  models they target, and a stale role fails in ways a type system cannot catch.
- **Named slots constrain callers.** A caller with a need no slot expresses must
  edit the role or fall back to raw `dispatch`. That friction is deliberate and
  it is still friction.
- **One tool per role grows the tool surface.** Many roles means many tools in
  every host's tool list, competing for a caller's attention with the core ten.
- **`on_terminal` is an escape hatch.** It runs a command with the dispatch's
  authority. Not a new risk class — cowork's purpose is running other agents'
  executables — but a general-purpose hook, and those attract uses nobody
  designed for.
- **Kept workspaces accumulate.** Keeping failures means failed worktrees pile up
  until someone removes them: the deliberate trade against destroying evidence,
  and a chore the user inherits.
- **Two layers own one concept.** "Where does this work happen" is split between a
  core that receives a path and sugar that creates one. Anyone debugging a
  worktree that was not cleaned up must look in both.

## Confirmation

The layering holds when the sugar layer's implementation contains no call that a
third-party caller could not also make, when deleting every role leaves a
complete, working core, and while no core code references git.

It is working when a user changes how their plan implementers behave by editing
a file, and ships nothing.

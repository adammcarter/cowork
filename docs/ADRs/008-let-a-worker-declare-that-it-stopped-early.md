# ADR 008: Let a worker declare that it stopped early

## Status

Accepted (design only — NOT IMPLEMENTED) - 2026-07-24

> The decision below is agreed; the code does not yet emit these states.
> `DispatchRecord.State` is still `queued, running, awaiting_input, succeeded,
> failed, cancelled, timed_out`. An orchestrator must not route on
> `needs_input` or `blocked` until this is built — they will never fire.

Depends on: [ADR 000](000-define-cowork-purpose-as-truthful-dispatch.md),
[ADR 001](001-fix-the-tool-list-as-cowork-public-contract.md),
[ADR 003](003-bound-workers-to-their-orchestrator-without-a-daemon.md).

Extends [ADR 001](001-fix-the-tool-list-as-cowork-public-contract.md)'s terminal
state vocabulary.

## Context

Two live runs exposed the same hole, from opposite directions.

A worker was denied a tool it needed (a read outside its granted workspace — ADR 003
containment working correctly). It gave up, exited 0, and cowork reported
**succeeded**. Separately, a different worker read its task, decided it needed a
decision from the caller, asked a clarifying question, and ended its turn normally.
It declared `subtype: success`, `is_error: false`. Cowork reported **succeeded**.

Neither worker lied. The second one genuinely *did* succeed — at its turn. It
answered the only way it could: by asking. Cowork relayed that declaration
faithfully, which is exactly what
[ADR 000](000-define-cowork-purpose-as-truthful-dispatch.md) requires.

The gap is in the vocabulary, not the plumbing. **"The worker finished its turn" and
"the task is done" are different facts, and cowork's terminal states cannot tell them
apart.** An orchestrating agent routes on the state; it sees `succeeded` and moves on.
The run that did nothing and the run that did everything are indistinguishable.

Worse, the honest-looking response — inferring "no files changed, so it probably did
not really finish" — is precisely the judgement cowork must not make. Inference would
trade a wrong answer for a guess.

The remaining move is the one this project always takes: **widen what a worker can
declare, and keep reporting exactly what it declared.**

## Decision

A dispatch's terminal state gains two members, and a worker gets a way to declare
them.

```text
  terminal states
  ├─ succeeded    the worker declared the work done
  ├─ failed       the worker declared it could not do the work
  ├─ needs_input  the worker stopped because it needs a decision or a fact
  └─ blocked      the worker stopped because it lacked access or a capability
```

0. **These are terminal states, and they are not `awaiting_input`.**
   [ADR 001](001-fix-the-tool-list-as-cowork-public-contract.md) already has
   `awaiting_input`: a live interactive worker that declared a turn's outcome and is
   *still running*, warm, waiting for a `send`. That worker is alive and the dispatch
   has not ended. `needs_input` and `blocked` are the opposite situation — the worker
   is **gone**. It stopped, the process ended, and it told us why on the way out.
   Answering an `awaiting_input` worker is `send`; answering a `needs_input` one is
   `follow_up`, which starts a fresh worker carrying the old context. Same question
   from the caller's point of view, different mechanics, so different states.

1. **A declared state is never an inferred one.** Cowork reports `needs_input` or
   `blocked` only when the worker said so. Silence still means the old vocabulary:
   absent any declaration, a clean finish is `succeeded` and a dirty one is `failed`,
   exactly as today. No existing behaviour changes, and no dispatch is
   retro-classified by a heuristic.

2. **The declaration channel is a tool call, not prose.** Cowork is already an MCP
   server the worker can reach — lineage attribution proves the channel — so a worker
   declares by *calling a tool* with its reason and, for `needs_input`, its question.
   A structured call is unambiguous, and it is the interaction shape agents are most
   reliable at. This is deliberately not a formatting convention in the reply text: a
   marker the model must remember through a long run fails silently late in exactly
   the runs that need it most, and silent failure is the one outcome
   [ADR 000](000-define-cowork-purpose-as-truthful-dispatch.md) forbids.

3. **Native declarations map where they already exist.** Some wires already carry a
   richer stop reason than cowork currently keeps (a protocol-level refusal, a
   declared error subtype). Where a wire declares one, it maps to these states through
   the same closed, tested verdict rules
   ([ADR 007](007-open-the-cli-transport-to-any-agent-by-descriptor.md)) — selected by
   configuration, never authored by it.

4. **A worker that cannot reach cowork is not penalised.** Not every backend can call
   back — an endpoint model driving cowork's own loop, a CLI with no MCP client. Those
   keep the two-state vocabulary and say so, rather than having a capability they lack
   reported as one they simply never used.

5. **`needs_input` is the state `follow_up` was waiting for.** Answering a worker's
   question is continuing its context with new information — which is what `follow_up`
   already does. The two features connect: a `needs_input` dispatch carries the
   question, and the orchestrator answers it into the same context. `blocked` is not
   answerable that way: it needs the *grant* to change (a wider workspace, a
   capability), then a fresh dispatch.

6. **The tool list stays fixed** ([ADR 001](001-fix-the-tool-list-as-cowork-public-contract.md)).
   The declaration surface is offered *to the worker*, alongside the lineage
   environment it already inherits. It is not an eleventh tool in the orchestrator's
   contract.

## Consequences

- **An orchestrating agent can finally route on the outcome.** "Answer the question
  and continue", "widen the grant and re-dispatch", and "the work is done" become
  three distinguishable results instead of one word.
- **The honest gap gets smaller, and what remains is visible.** A worker that stops
  early *and* declares nothing is still reported as it always was. That is not solved
  here, and pretending otherwise would be the papering-over this ADR exists to avoid —
  so a backend whose declaration is asserted rather than proven carries the same
  `unverified` provenance marker every other config-asserted capability does
  ([ADR 007](007-open-the-cli-transport-to-any-agent-by-descriptor.md)).
- **Cowork still never grades work.** It does not decide whether a task was really
  finished; it only carries a richer statement of what the worker said about itself.
  The messenger principle is unchanged — the message just has more words in it.
- **`succeeded` means more than it did.** Previously it meant "the process ended and
  declared nothing wrong". It now additionally means "the worker did not tell us it
  was stuck". That is a strictly stronger claim, and the two runs above are why it
  needed to be.

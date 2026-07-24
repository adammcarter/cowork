# ADR 007: Open the CLI transport to any agent, by descriptor

## Status

Accepted - 2026-07-24

Depends on: [ADR 000](000-define-cowork-purpose-as-truthful-dispatch.md),
[ADR 001](001-fix-the-tool-list-as-cowork-public-contract.md),
[ADR 005](005-configure-providers-globally-and-compose-them-with-profiles.md),
[ADR 006](006-model-workers-by-transport-not-by-location.md).

Amends [ADR 006](006-model-workers-by-transport-not-by-location.md) clause 3.

## Context

[ADR 006](006-model-workers-by-transport-not-by-location.md) settled that a worker
is modelled by its transport, and that within the CLI transport the fork is the
driver dialect. It also made adding a CLI agent cheap — "one thin driver". Cheap,
but still **code**: `CliDialect` was a closed enum of three cases, each with a
hand-written `OneShotDriver`, so the set of agents cowork could dispatch to was
fixed at compile time by cowork's authors.

The pressure that exposed this came from small local models. A raw model served
over HTTP is an endpoint worker, and cowork drives it with a thin relay loop that
owns the message list — which means cowork owns the context, and a small window
eventually overflows. The honest options are to refuse, or to let something that
already solves this own the model's whole lifecycle. Writing cowork's own context
manager is exactly the harness creep
[ADR 000](000-define-cowork-purpose-as-truthful-dispatch.md) forbids.

The answer was already in the architecture: an agent harness that manages its own
context *is* a CLI worker. Point an existing headless harness at the local model,
register it as a CLI backend, and cowork goes back to being a messenger — dispatch,
collect, report. A spike confirmed the mechanism works (an existing harness drove a
local model to completion headlessly).

The only thing standing in the way was that the CLI door opened for exactly three
named binaries. A user cannot add a fourth without a cowork release. That is a
policy decision cowork had accidentally reserved to itself.

Widening it is not a free move. A CLI descriptor spawns an **arbitrary executable
with arbitrary arguments and environment**, and the outcome rule
([ADR 000](000-define-cowork-purpose-as-truthful-dispatch.md)) is the product
itself. A careless schema could let configuration make a worker's failure look like
a success, or let a cloned repository run a binary of its choosing.

## Decision

The CLI transport is opened to **any** agent, wired from configuration by a
declarative **descriptor**. Both backend kinds remain; the *kind* is the user's
choice, and neither is deprecated by the other.

```text
                          cowork dispatch
                                 │
            ┌────────────────────┴────────────────────┐
       CLI transport                             ENDPOINT transport
   spawn a process, speak                   HTTP POST, cowork runs the
   over stdin/stdout                        thin relay loop (it owns the
   the WORKER owns its own                  message list — and therefore
   context and lifecycle                    the context window)
            │                                          │
   fork = a DESCRIPTOR, from config           fork = HTTP dialect only
            │
   ├ built-in  claude / grok / codex  → sealed descriptor constants
   └ generic   kind = "generic"       → the descriptor the user wrote
                                        (any CLI: an agent harness
                                         wrapping a local model, a
                                         house tool, a shim)
```

1. **A CLI's wire is a descriptor, not a driver.** One `ConfiguredDriver`
   interprets a `CliDescriptor`: where the task goes (argv / raw stdin / a
   stream-json user envelope), the argument template with optional `{task}`,
   `{workspace}` and `{resume}` segments, the environment, how to extract the
   answer, and which outcome rule applies. The three built-ins become sealed
   descriptor constants; the hand-written drivers are gone.

2. **Configuration SELECTS an outcome rule; it never AUTHORS one.** `verdict` picks
   one of a closed set of named, tested `Verdict.*` functions. There is deliberately
   no "success when field X equals Y" knob — that would let a config report a
   truncation as success, the exact lie
   [ADR 000](000-define-cowork-purpose-as-truthful-dispatch.md) exists to prevent.
   A genuinely new declaration shape requires a new tested rule in reviewed code.
   **Adding a strategy is code; choosing one is config.**

3. **A strategy may not ignore a declaration cowork can see.** Judging by exit code
   alone is honest only for a worker that declares nothing else, so a generic row
   may select it only with raw output; the incoherent pairings are refused at load
   rather than left to fail silently at dispatch.

4. **A generic descriptor is global-origin only.** A project's config may *select* a
   built-in but may not define a generic CLI — the same reasoning that refuses a
   project-named credential in
   [ADR 005](005-configure-providers-globally-and-compose-them-with-profiles.md),
   applied to a strictly larger risk: a cloned repository must not be able to choose
   which binary runs on the user's machine.

5. **Configuration may move bytes, never author execution-sensitive state.** A CLI's
   environment may not set `PATH`, `HOME`, `USER`, `LANG`, `COWORK_*`, `DYLD_*` or
   `LD_*`, and a value may be an `env:NAME` reference so a config file holds a
   pointer and never a secret. Substitution is whole-argument and no shell is
   involved, so a task value cannot inject an argument or a command.

6. **Live sessions stay code-backed; capability stays derived.** A session speaks a
   bespoke stateful protocol (stream-json, ACP, MCP) that a descriptor cannot
   express, and one adapter carries a copy of the user's credentials — so an adapter
   is bound to its built-in and cannot be named from config. A generic CLI is
   therefore truthfully one-shot: `supports_message` is the *presence of the
   operation*, so it cannot be forged, and an interactive dispatch is refused rather
   than silently run one-shot ([ADR 006](006-model-workers-by-transport-not-by-location.md)).

7. **Asserted is reported distinctly from proven.** Configuration states intent;
   only a performed run proves behaviour. A config-wired capability is advertised
   *with* a marker naming it unverified — follow-up that is wired but not yet shown
   to be honoured, an exit-code verdict not yet shown to surface real failures.
   Built-ins, verified against the real CLIs, carry no such marker. The difference
   is reported rather than papered over, which is
   [ADR 000](000-define-cowork-purpose-as-truthful-dispatch.md) applied to
   capabilities.

## Consequences

- **Adding a CLI agent is now configuration, not a cowork release.** The parity
  [ADR 006](006-model-workers-by-transport-not-by-location.md) gave model hosts
  ("a new host is a config line") now holds for CLI agents too.
- **Small local models have an honest answer.** Point an existing headless harness
  at the model and register it as a CLI backend: the harness owns the context and
  compaction, cowork stays a messenger. Cowork builds no context manager, and the
  user does not think about windows — they dispatch work and it completes.
- **Both backend kinds keep their place.** A raw model that completes in a few turns
  is still simplest as an endpoint, where cowork's thin loop drives it directly; the
  loop is untouched by this decision. A worker that needs its own lifecycle goes
  behind a harness on the CLI path. The user picks by how they register it.
- **The blast radius of a bad config is bounded by design, not by care.** The
  origin gate, the protected-key denylist, the closed verdict set, the coherence
  rules and whole-argument substitution are load-time refusals; a mistake is a
  config error the user can read, not a silent misbehaviour at dispatch.
- **The built-ins are sealed.** A built-in row carrying descriptor fields, or a
  generic row pointing at a built-in's executable name, is refused — so opening the
  door cannot be used to re-author a dialect that was verified against the real CLI.
- **One interpreter is now load-bearing for every CLI dispatch.** That concentration
  is the point (one place to reason about argv, environment and outcome), and it is
  why the built-ins' wire is pinned by tests that were first proven against the
  hand-written drivers they replaced.

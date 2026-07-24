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

The first cut of this decision kept the three named agents as *sealed built-in
descriptors* and left live sessions bound to them in code. That half-measure did
not survive contact. It meant cowork still carried three vendor names, still
decided which agents were first-class, and still needed a release when one of them
changed a flag. Worse, a name in cowork's code is a claim cowork cannot keep: it
recognises an agent by a string the *user* chose, and a recognised name licensed
behaviour the user never asked for — an implicit copy of their credentials. So the
built-ins went too, and clauses 3 and 6 below are the corrected versions.

## Decision

The CLI transport is opened to **any** agent, wired from configuration by a
declarative **descriptor**. Cowork ships **no** agents. Both backend kinds remain;
the *kind* is the user's choice, and neither is deprecated by the other.

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
   every [cli.<name>] row, all equal: an agent
   harness wrapping a local model, a vendor CLI,
   a house tool, a shim — cowork cannot tell
   them apart, so it cannot favour one
```

1. **A CLI's wire is a descriptor, not a driver.** One `ConfiguredDriver`
   interprets a `CliDescriptor`: where the task goes (argv / raw stdin / a
   stream-json user envelope), the argument template with optional `{task}`,
   `{workspace}` and `{resume}` segments, the environment, how to extract the
   answer, and which outcome rule applies. There are no hand-written drivers and no
   descriptor constants — a row in `~/.cowork/config.toml` is the only place a wire
   exists.

2. **Configuration SELECTS an outcome rule; it never AUTHORS one.** `verdict` picks
   one of a closed set of named, tested `Verdict.*` functions, each named for the
   *declaration shape* it reads: `exit_code`, `declared_result`, `stop_reason`.
   There is deliberately no "success when field X equals Y" knob — that would let a
   config report a truncation as success, the exact lie
   [ADR 000](000-define-cowork-purpose-as-truthful-dispatch.md) exists to prevent.
   A genuinely new declaration shape requires a new tested rule in reviewed code.
   **Adding a strategy is code; choosing one is config.**

3. **Nothing in cowork is named after an agent.** Verdicts, session wires and
   diagnostics are named by shape or protocol, never by vendor, and no diagnostic
   interpolates a row's name — *which* CLI ran already lives in the dispatch
   record's backend id, so repeating it there would only make two agents speaking
   the same protocol look incomparable. This is not tidiness. A name in code is a
   recognition, and a recognition licenses behaviour: the concrete case was the MCP
   session copying the user's auth file into a throwaway home *because it recognised
   the agent*. That copy now exists only where a user wrote
   `[cli.<n>.isolate] seed = …`. **Cowork never copies a credential on its own
   initiative.**

4. **A CLI row is global-origin only.** A project's config may *dispatch* any
   globally-declared CLI by name, but may not declare one at all — the same
   reasoning that refuses a project-named credential in
   [ADR 005](005-configure-providers-globally-and-compose-them-with-profiles.md),
   applied to a strictly larger risk: a cloned repository must not be able to choose
   which binary runs on the user's machine. With no built-ins left there is no
   weaker "select a sealed dialect" row a project could safely be allowed, so the
   whole table kind is refused, with `config.project-cli-refused` naming the fix.

5. **Configuration may move bytes, never author execution-sensitive state.** A CLI's
   environment may not set `PATH`, `HOME`, `USER`, `LANG`, `COWORK_*`, `DYLD_*` or
   `LD_*` — and neither may an isolation `var`, which reaches the same environment
   through a different door. A value may be an `env:NAME` reference so a config file
   holds a pointer and never a secret. Substitution is whole-argument and no shell is
   involved, so a task value cannot inject an argument or a command.

6. **A live session is a wire the row NAMES, not a privilege cowork grants.** Three
   stateful protocols ship as protocol clients — `stream_json`, `acp`, `mcp` — and a
   `[cli.<n>.session]` block selects one and supplies the argv that launches it. The
   one genuinely agent-specific value, the MCP tool-name pair, is a config value.
   Capability remains the *presence of the operation*: a row with no `[session]`
   block has no session to open, so `supports_message` is false and an interactive
   dispatch is refused with `cli.session-code-only` rather than silently run
   one-shot ([ADR 006](006-model-workers-by-transport-not-by-location.md)). What a
   config row can now assert, it must also carry a marker for — see clause 7.

7. **Asserted is reported distinctly from proven.** Configuration states intent;
   only a performed run proves behaviour. Every config-asserted capability is
   advertised *with* a marker naming it unverified: `cli.follow-up-unverified` for
   follow-up that is wired but not yet shown to be honoured,
   `cli.session-unverified` for a session wire the binary is merely claimed to
   speak, `cli.verdict-unverified` for an exit-code verdict not yet shown to surface
   real failures. Every row is config-authored now, so these markers are
   unconditional — there is no privileged provenance left to exempt, and exempting
   one anyway would be the papering-over
   [ADR 000](000-define-cowork-purpose-as-truthful-dispatch.md) forbids. A performed
   journey is what clears them.

## Consequences

- **Adding a CLI agent is now configuration, not a cowork release.** The parity
  [ADR 006](006-model-workers-by-transport-not-by-location.md) gave model hosts
  ("a new host is a config line") now holds for CLI agents too — and so does the
  converse: when an agent changes a flag or a JSON key, the fix is a line in the
  user's own config rather than a wait for cowork to ship.
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
- **A fresh install dispatches to nothing until the user says otherwise.** That is
  the price of shipping no agents, and it is the right default: cowork will not
  launch a binary because it guessed a name. `examples/config.toml` carries a
  complete worked row for each supported shape, the installer places it at
  `~/.cowork/examples/config.toml`, and cowork's wire tests are pinned against that
  file — so the sample users are told to copy is provably the sample the parser
  accepts.
- **The observable vocabulary changed, and that is a break.** Diagnostics that
  carried an agent's name (`cli.claude.exit`, `cli.grok.truncated`,
  `cli.codex-mcp.rpc-error`) are now shape-named (`cli.exit`,
  `cli.stop-reason.truncated`, `cli.mcp.rpc-error`); the `verdict` wire values were
  renamed to their shapes; `kind` and `deadline_diagnostic` no longer exist, and a
  leftover `kind` is a load error rather than a silently-ignored key — ignoring it
  would launch an interactive agent with no arguments and report the ensuing hang
  as a timeout. Accepted deliberately, pre-v1: a comparable vocabulary is worth more
  than compatibility with three names that were never going to stay.
- **Two second opinions were lost with the built-ins.** `cli.kind-mismatch` compared
  a declared `kind` against a sniffed executable, and `cli.driver-unknown` reported
  a row whose dialect did not resolve. Neither has a subject any more: there is no
  label left to mislabel, and every row carries a descriptor by construction — so
  what was a probe-time diagnostic is now a load-time refusal, which is stronger and
  is named.
- **One interpreter is now load-bearing for every CLI dispatch.** That concentration
  is the point (one place to reason about argv, environment and outcome), and it is
  why the shipped example rows' wires are pinned by tests that were first proven
  against the hand-written drivers they replaced.

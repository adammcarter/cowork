# ADR 006: Model workers by transport, not by where they run

## Status

Accepted - 2026-07-21

Depends on: [ADR 000](000-define-cowork-purpose-as-truthful-dispatch.md),
[ADR 001](001-fix-the-tool-list-as-cowork-public-contract.md),
[ADR 005](005-configure-providers-globally-and-compose-them-with-profiles.md).

## Context

Cowork dispatches to many kinds of worker: a model served on localhost, a model
served from a datacentre behind an API key, an installed CLI agent like Claude
Code, Codex, or Grok. The obvious mental model forks on the things a human
notices first — *local vs remote*, or *which vendor* — and both are wrong. Forking
on local-vs-remote invites cowork to special-case where a model runs; forking on
vendor invites a bespoke path per provider. Either way lies a pile of conditionals
and, worse, the pull to reach inside a worker to smooth over its quirks — the
harness creep [ADR 000](000-define-cowork-purpose-as-truthful-dispatch.md) and the
messenger principle ("Cowork is a messenger, not a harness") forbid.

The right axis is the one that actually changes cowork's code: **how it physically
carries a message to the worker.** Everything else is configuration or a truthful
capability report.

## Decision

A worker is modelled by its **transport**, of which there are exactly two, and by
the **dialect** it speaks over that transport. Nothing else forks the code.

```text
                          cowork dispatch
                                 │
            ┌────────────────────┴────────────────────┐
       CLI transport                             ENDPOINT transport
   spawn a child process,                    HTTP POST to /v1/chat/completions,
   speak over its stdin/stdout               cowork runs the thin relay loop
            │                                          │
   fork = driver dialect (kind)              fork = HTTP dialect only
            │                                openai_compatible (extensible)
   ├ claude  stream-json (interactive)                 │
   ├ grok    -p json  (ACP for interactive)  local vs remote is NOT a fork:
   └ codex   exec, one-shot                  same code path, only config differs
                                            ├ local:  localhost / LAN, no credential
                                            └ remote: https://… + API credential
```

1. **Two transports, and only two.** A **CLI** worker is a process cowork spawns
   and speaks to over stdin/stdout. An **endpoint** worker is a URL cowork POSTs
   to. These are the only two ways cowork reaches a worker, and they are the only
   split that changes its code (`CliRunner`/`CliSession` vs
   `EndpointBackend`/`EndpointSession`).

2. **Local vs remote is not a fork.** An ollama box on the LAN and a hosted model
   in another region are the *same endpoint transport*; the only difference is the
   `base_url` and whether a credential rides along ([ADR 005](005-configure-providers-globally-and-compose-them-with-profiles.md)).
   Cowork is deliberately indifferent to *where* a model runs — that indifference
   is the messenger principle in force, and it is why a new host is a config line,
   never a code change.

3. **Within CLI, the fork is the driver dialect (`kind`).** Each installed agent
   speaks its own protocol — Claude over `stream-json`, Grok over
   `-p --output-format json`, Codex over `exec` — so each needs a thin driver
   adapter and declares its `kind` in config. Adding a CLI agent is one adapter,
   not a new transport.

4. **Within endpoint, the only variation is the HTTP dialect.**
   `openai_compatible` (the `/v1/chat/completions` shape) is the implemented
   dialect; the seam is a single `EndpointDialect`, so a second dialect (e.g. a
   native-Ollama `/api/chat`) is a minor branch at the request boundary, not a
   worker model.

5. **Interactivity is an orthogonal capability, never a transport.** Whether a
   worker can hold a live `send`/`finish` session is a fact *about that worker*,
   reported truthfully by `capabilities` ([ADR 001](001-fix-the-tool-list-as-cowork-public-contract.md)),
   not a fifth branch. Claude, Grok, and Codex can each be messaged mid-session
   over their own session (each CLI is `SessionCapable`); an endpoint can too, via
   cowork's owned message list. A worker that cannot be messaged says so rather
   than pretend.

## Consequences

- **Adding a model host is configuration, not code** — a `[provider.*]` block, the
  same for a laptop's ollama and a hosted API. Local/remote parity is free.
- **Adding a CLI agent is one thin driver** — Grok joined this way (a `CliRunner`
  with the Grok driver, `kind = "grok"`), reusing the shared `ContainedProcess`
  containment and only
  supplying its own dialect. Codex is built the same way — a thin driver reusing
  the shared containment.
- **Interactivity is discovered, never assumed.** A worker that cannot be messaged
  is refused for an interactive dispatch rather than silently run one-shot, and
  `capabilities.supports_message` names the reason.
- **Interactive support for a CLI is an adapter question, not a hard limit of the
  agent.** Both are now built: Grok multi-turn runs over `grok agent stdio`
  (ACP JSON-RPC) via `GrokAcpSession`, and Codex interactive runs over
  `codex mcp-server` (`codex`/`codex-reply`) via `CodexMcpSession` — each a thin
  session adapter reusing the shared containment. Codex's one-shot `exec` path
  still leaves no continuation handle, so `follow_up` (resuming a *finished*
  dispatch in a fresh run) remains refused for Codex.
- **No worker's internals leak into the model.** Because the fork is transport and
  dialect — how to carry a message — and never the worker's cognition, the model
  stays a messenger's model: indifferent to what, and where, the black box is.

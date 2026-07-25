# ADR 001: Fix the tool list as cowork's public contract

## Status

Accepted - 2026-07-16
Amended - 2026-07-22 (clarify core-vs-role tools; see "Core tools and role tools")

Depends on: [ADR 000](000-define-cowork-purpose-as-truthful-dispatch.md).

## Context

[ADR 000](000-define-cowork-purpose-as-truthful-dispatch.md) fixes cowork's
purpose: dispatch work to an agent, manage that dispatch, truthfully. This
record turns that purpose into the surface callers actually touch.

Cowork's consumers are four host CLIs and a prose skills layer. What they can
depend on must be small, stable, and expressible without reference to how cowork
works inside. The tool list is therefore the contract: everything beneath it —
language, process model, storage, transport — must stay free to change, and no
caller may be required to know any of it.

Two capability facts, established against the installed CLIs on
2026-07-16, constrain the surface and must not be designed away:

- **A live Claude worker can be messaged.** `claude -p --input-format
  stream-json` accepts further user messages on stdin while the session lives.
  Proven: two messages to one process eight seconds apart, each producing its
  own declared result.
- **A live Codex worker can be messaged, by a different transport.** `codex
  mcp-server` exposes `codex` and `codex-reply` ("Continue a Codex conversation
  by providing the thread id and prompt"), confirmed by an MCP `tools/list`
  handshake against the installed binary. `codex exec` — one-shot, where stdin
  *is* the prompt — cannot, and is therefore the wrong foundation for a Codex
  driver.

  **Implemented and wired.** The `codex` → `codex-reply` exchange is implemented
  (`CodexMcpSession` drives it for interactive sessions; `CodexAgent` is
  `SessionCapable`, so `capabilities` advertises `supports_message` for Codex).
  The contract treats `codex-reply`'s described behaviour as an assumption.
  `supports_message` is conformance-derived (a fact about the agent, not a runtime
  probe) and so does not flip; but if a real exchange ever misbehaves, the dispatch
  reports that failure truthfully rather than break.

This matters because giving a running worker one extra detail, or pivoting it
after it has been fired off, is otherwise impossible: the only recourse is to
stop it and start again, losing its context and its work.

A third fact, established against a locally hosted endpoint on 2026-07-16, constrains
the endpoint side just as firmly:

- **Local endpoints already do real agentic work.** A local model served over the
  OpenAI-compatible dialect returned `finish_reason: tool_calls` with a
  well-formed `tool_calls` array, and carried `reasoning_content` alongside it.
  Tool calling and thinking are native to the endpoint, not something cowork adds.

So cowork's agent loop is a **faithful client of the endpoint's own contract, not
an abstraction over it**. It passes tools through, honours the tool-call cycle,
and preserves reasoning content rather than stripping it. It never reimplements
inference, and never reduces a provider's features to a lowest common denominator
in the name of a tidy interface — a backend that can think and call tools must not
be made to look like one that cannot.

This also fixes a state the lifecycle would otherwise get wrong:
`finish_reason: tool_calls` is a **continuation**, not a terminal outcome. Only
the loop's own conclusion is terminal.

Scope: the public tools and the observable event stream. Non-goals: the backend
interface, storage layout, language, and process model.

## Decision

Cowork's public contract is **ten core tools and one event stream**. Nothing else
is *promised*; anything not listed here is an implementation detail that may change
without notice.

### Core tools and role tools

The exposed tool list is **the 10 core tools plus N role tools** — never a fixed
count of ten. The two are different kinds of thing and must not be conflated:

- **The 10 core tools** (below) are the fixed, stable, versioned contract. They are
  **always present, always named and shaped exactly as here**, and a caller may
  depend on every one of them. This is what "the contract" means.
- **Role tools** are the additive sugar of
  [ADR 002](002-layer-cowork-as-core-and-sugar.md): one dynamically-surfaced tool per
  role *file*, discovered at runtime. They are **strictly additive and namespaced**
  (a `role_`-prefixed name), so a role can never remove, rename, reshape, or shadow a
  core tool. They are not part of the fixed contract — they come and go with the
  files on disk — but they are a first-class, intended part of the exposed surface,
  not an implementation detail.

The invariant is therefore *"the 10 core tools are always present and unchanged,"*
**not** *"the list length is exactly 10."* Deleting every role file leaves exactly
the 10-core contract (the confirmation in
[ADR 002](002-layer-cowork-as-core-and-sugar.md)). Feasibility of the dynamic,
file-driven role-tool list was proven live against the Swift MCP SDK on 2026-07-22
(`tools/list` returned 10 core + 2 file-derived `role_*` tools). Roles reload by
re-reading the role set on every `tools/list` — a new or edited `.role` file
takes effect with no restart; cowork advertises `listChanged: false` and emits
no `notifications/tools/list_changed`.

### Tools

| Tool | Contract |
|---|---|
| `dispatch(task, backend, workspace?, interactive?) -> id` | Start one dispatch. `id` is minted by cowork and is opaque: unique in practice (the first 8 hex of a UUID; collisions are not detected), with no other meaning. |
| `send(id, message)` | Send a message to a live worker. Requires `capabilities.supports_message`. |
| `finish(id)` | End an interactive dispatch and release its worker. |
| `follow_up(id, task) -> id` | New dispatch carrying a finished dispatch's context. Inherits backend and workspace. Requires `capabilities.supports_follow_up`. |
| `status(id) -> state + diagnostics` | Current lifecycle state and truthful diagnostics. |
| `output(id) -> result` | The worker's declared result. |
| `wait(id, timeout) -> state` | Block up to a hard-capped timeout, then return the state, including "still running". Never blocks indefinitely. |
| `cancel(id)` | Stop a dispatch and its worker. |
| `list(scope?) -> dispatch[]` | Dispatches and their states. Scoped to the caller's own lineage by default; `all` for everything on the machine. |
| `capabilities(backend?) -> facts` | Truthful facts, including **current availability**. |

### Lifecycle

```text
queued -> running -> awaiting_input ⇄ running -> succeeded | failed
                                                | cancelled | timed_out
```

`awaiting_input` is a real state, not a variant of success: an interactive
worker has declared a turn's outcome and remains alive awaiting a `send`.

> **Extended by [ADR 008](008-let-a-worker-declare-that-it-stopped-early.md) —
> DECIDED, NOT YET EMITTED.** The states below are what the product emits today;
> ADR 008 adds `needs_input` and `blocked` to this vocabulary but is not built,
> so nothing fires them yet. When implemented they are terminal states for a worker that has
> **exited** having declared that it stopped early — distinct from `awaiting_input`,
> where the worker is still alive. Both are declared by the worker and never inferred,
> so a dispatch with no such declaration keeps exactly the states above.

### Rules binding every tool

1. **The worker's declared outcome is the verdict.** Terminal state derives from
   what the worker said about itself. Process exit is a diagnostic. A worker
   exiting 0 having declared an error is `failed`. The one exception is a backend
   with no declared outcome at all — `codex exec` one-shot reports nothing but its
   exit code, so for it the exit code *is* the verdict (`Verdict.codex`).
2. **A turn ending is not a dispatch ending.** For interactive dispatches these
   are distinct: a turn's outcome is the worker's to declare; the dispatch ends
   on `finish`, an idle timeout, or worker exit. A worker cannot know whether a
   further message is coming, so it is not asked.
3. **Capabilities are facts, never comfort.** `capabilities` reports live
   reachability, and reports differences between backends rather than
   flattening them — including `supports_message` being false where a backend
   cannot honestly do it.
4. **`interactive` defaults to false.** The common case is fire-and-forget; a
   caller opts in to keeping a worker warm, and thereby opts in to its cost.
5. **`workspace` is optional.** It is a directory path or absent. When present,
   the worker is started in that directory (a cwd grant); when absent, it
   inherits cowork's own cwd and the dispatch is recorded as `unconfined` in the
   event stream. Either way the grant is recorded, because a caller must be able
   to tell what authority a worker was given. The grant is a starting directory,
   **not** filesystem confinement — a worker is not restricted to it (see
   [ADR 003](003-bound-workers-to-their-orchestrator-without-a-daemon.md)'s
   "workspace is a grant, not a sandbox"). Omitting the workspace is a
   legitimate explicit choice — a model asked to summarise text touches no
   repository — but never a silent default.
6. **Ids are minted by cowork.** Callers never supply them.
7. **Every dispatch is attributed to its orchestrator.** Lineage is derived by
   cowork, not asserted by callers.

### Event stream

Cowork appends every dispatch lifecycle event to a single, append-only stream of
one JSON object per line, with a stable versioned schema:

```json
{"v":1,"ts":"2026-07-16T19:00:00Z","id":"j_7f3a","parent":"s_claude_a91c",
 "root":"s_claude_a91c","backend":"codex","event":"started"}
```

The stream is a **public contract with no API**: any plugin and any agent may
watch it by tailing it. Its schema is versioned; its location and rotation are
implementation details.

### Attribution and filtering

Every event carries `parent` — the orchestrator that fired the dispatch — and
`root`, the orchestrator at the top of the chain. Dispatches therefore form a
tree, and both useful filters are a single pass over one line:

```text
  s_claude_a91c  (an orchestrating session)
    ├── j_7f3a   codex        parent=s_claude_a91c  root=s_claude_a91c
    │     └── j_2b19  claude   parent=j_7f3a        root=s_claude_a91c
    └── j_c40d   endpoint     parent=s_claude_a91c  root=s_claude_a91c
```

`parent` answers "who fired this one"; `root` answers "whose work is this" —
without a consumer having to accumulate the tree in memory to find out. A
monitor showing only its own session's workers filters on `root`; a caller
inspecting one worker's children filters on `parent`.

Lineage is **derived, not trusted**. Cowork identifies the orchestrator from the
host session it is running under, and injects the current dispatch's identity
into each spawned CLI worker's environment (an endpoint dispatch has no worker
process, so its attribution lives in the dispatch record). A CLI worker that
itself calls cowork is therefore attributed automatically, with no cooperation
from the caller and nothing to spoof. The injected variables are part of the
sanitized environment allowlist by construction.

## Validation and evidence

Performed against real endpoints on 2026-07-16.

**The dialect is provider-neutral, not Ollama-shaped.** The same code path, with
no provider-specific branch, drove three providers across two transports and two
credential mechanisms through a full agentic tool loop:

```text
  oMLX   (host,   HTTP,  API key)   example-7b                -> summary.txt = 6   (correct)
  z.ai   (hosted, HTTPS, API key)   glm-4.6                         -> summary.txt = 6   (correct)
  NVIDIA (hosted, HTTPS, API key)   meta/llama-3.1-70b              -> summary.txt = 5
  Ollama (LAN,    HTTP,  no auth)   llama3.2:3b                     -> summary.txt = 123
```

Four providers, three URL layouts, two transports, both credential mechanisms —
and **no provider-specific code**. Each provider is one configuration entry.

The sharpest test of independence was oMLX, which began the day unauthenticated
and later required a key. Adding one is a **single line** on the existing entry:
`credential = "env:OMLX_API_KEY"`, exactly as a hosted provider does it. No new
code path, no local-versus-hosted branch.

That matters because "local" and "no credential" are easy to couple by accident,
and the coupling is false: authentication is a property of an endpoint's
configuration, not of where it happens to run. A local model behind a key and a
hosted 70B behind a bearer token are the same shape:

| | no auth | API key |
|---|---|---|
| **local** | Ollama (LAN) | oMLX (host) |
| **hosted** | — | NVIDIA, z.ai |

**Adding a hosted provider over HTTPS with an API key required no new code** —
one configuration entry, the same dialect, the same loop, the same tools. That is
the strongest evidence for the claim that provider identity, endpoint location,
and credential mechanism are independent concerns: a remote 70B behind a bearer
token is the same shape as a 9B on the machine next to you.

It also demonstrates, uncomfortably and usefully, what cowork refuses to do. Half
those answers are wrong — "the sea is deep and blue" is six words; the hosted 70B
said 5 and the local 3B said 123 — and **all are reported `succeeded`**, because
every worker declared it was done. Cowork reports what happened. Grading belongs
to the caller.

**The path is configuration, not contract.** "OpenAI-compatible" fixes the
request and response *shape*; it does not fix the URL layout. NVIDIA and Ollama
serve `/v1/chat/completions`; z.ai serves `/api/coding/paas/v4/chat/completions`.
Hardcoding `/v1` silently excludes real providers while looking as though *they*
are non-compliant.

**A provider's error body is its declared outcome.** Pointed at z.ai's API, the
response was HTTP 429 whose nested `error` body carried the provider's own
`code` and `message`. Reducing that to `endpoint.http-429` throws away the only
actionable part, and here it was actively misleading: the message was true, and
the real fault was a wrong endpoint. Cowork therefore preserves the `code` and
`message` it finds in the OpenAI-style nested `error` body — the same rule that
makes a worker's `finish_reason` the verdict. (A provider that reports errors
in a non-nested shape is reported as a bare HTTP failure; only the nested shape
is parsed today.)

**Credentials do not leak.** Audited after a live hosted run: the key appears in
no event, no record, no transcript, and no tracked file. It is fetched at the
point of use, never stored, and a missing one fails before the request is sent
with `endpoint.credential-absent,expected=NVIDIA_API_KEY` — naming the variable,
never a value. A rejected one is `endpoint.auth-rejected`, distinct from a generic
HTTP failure.

That is the "faithful client" rule paying off: tools and reasoning are native to
the endpoint, and passing them through unchanged is what makes one path serve
both. `reasoning_content` survives into the dispatch log, so a reader sees the
worker's actual thinking rather than a summary cowork invented.

**Latency is a product constraint, and it is enormous.** For the same three-tool
request, a small model answers in a few seconds, a larger one in tens of
seconds, and a thinking model in minutes — confirmed as the model rather than the
client by timing the identical request through `curl`. A single default deadline cannot serve that spread, and a
deadline that is too short reports `timed_out` truthfully while still being the
wrong answer.

**"Local" is ambiguous, which is why `capabilities` must probe.** An endpoint
bound to `127.0.0.1` on a VM host is invisible from the guest: the host answers
ping promptly while its port stays closed until it is bound past loopback.
Cowork reported `endpoint.unreachable,code=-1004` rather than hanging or
guessing. Config therefore needs real addresses, and reachability is a live fact
rather than a stored one — rule 3 exists for exactly this.

**Proven live.** All ten core tools are implemented, and the interactive
`send`/`finish` round-trip plus `follow_up` are exercised by performed acceptance
journeys against the backends that support them (Claude Code, Grok). `codex` is
interactive as well — `CodexAgent` is `SessionCapable`, so `send`/`finish` go
over its MCP session — but it is the one exception for `follow_up`: its one-shot
path leaves no continuation handle, so resuming a *finished* dispatch in a fresh
run is refused for it by design (ADR 006), reported truthfully rather than
papered over.

## Consequences

**Positive**

- Callers depend on ten tools, not on a protocol, a daemon, or a client library.
  The implementation beneath is free — including being replaced wholesale.
- The contract is small enough to implement completely and to verify by
  performed journey rather than by unit test.
- `send` closes the gap where a worker needing a pivot or one extra detail
  forces a stop-and-restart that discards its context.
- One append-only stream means a monitor or a panel latches onto exactly one
  thing, and a shell one-liner is a first-class consumer.
- Attribution makes one shared stream practical: many orchestrators write to it
  concurrently, and each consumer filters to its own lineage on a single field.
  Nesting — a worker that dispatches its own workers — is observable for free.

**Negative and accepted costs**

- **Ten tools is more than a pure fire-and-forget runtime needs.** `send`,
  `finish`, and `awaiting_input` exist solely for interactive dispatches and add
  a state every consumer must handle, including callers that never use them.
- **Interactive dispatches leak resources by design.** A warm worker holds a live
  process and its context. `finish` plus an idle timeout bound the damage; they
  do not remove it.
- **The contract forces uncomfortable truths outward.** A backend reporting
  `supports_message: false` means callers branch. That is the point, and it is
  friction.
- **`follow_up` and `send` look similar and are not.** One starts a new dispatch
  with prior context; the other speaks to a live worker. The distinction is real
  — they map to different mechanisms — and will be mistaken for redundancy.
- **Backend transports diverge under a converged surface.** Claude messaging is
  stdin JSON; Codex messaging is JSON-RPC to `codex mcp-server`; endpoints are an
  in-process loop. Three mechanisms sit behind `send`, and each is real work.
- **Derived lineage depends on the environment surviving.** A worker whose
  environment is stripped, or which is launched outside cowork, appears as its
  own root rather than as a child. That is the honest failure mode — an
  orphan is reported as an orphan, never guessed into a tree — but it means
  lineage is best-effort, and a consumer must tolerate a dispatch whose parent
  it never saw.
- **One shared stream has one writer problem.** Concurrent appends stay atomic
  only while event lines remain small; bulk worker output must go elsewhere, and
  the stream needs rotation. Both are constraints on the implementation, not on
  callers.

**Follow-up**

- Automatic worker selection, if added, layers over `capabilities` facts as an
  opinion — never as a hidden router.
- `pause`/`resume` are rejected: on inspection they free no resource — CLI agents
  wait on cloud APIs, and endpoint generation happens inside the model server,
  not in cowork's process — while `SIGSTOP` can break a worker's in-flight
  request and corrupt the dispatch. `cancel` covers the real need.

## Confirmation

The contract holds when every tool is exercised against a real backend in a
performed journey, and when `capabilities` reports `supports_message: false` for
a backend that cannot do it while another reports true — proving cowork reports
difference rather than inventing uniformity.

The contract is broken the moment a caller needs to know the storage layout, the
process model, or the language to use cowork.

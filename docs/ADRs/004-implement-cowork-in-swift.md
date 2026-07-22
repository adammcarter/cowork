# ADR 004: Implement cowork in Swift

## Status

Accepted - 2026-07-16 · Amended - 2026-07-22 (distribution cost resolved, below)

Depends on: [ADR 003](003-bound-workers-to-their-orchestrator-without-a-daemon.md).

## Context

Cowork looks like a job for a scripting language: spawn a subprocess, POST JSON,
read and write small files. On that reading the runtime is glue, and a language
already present on every host — the Node that each host CLI starts to load an MCP
server — wins by default.

That reading is wrong, because it prices the easy 80% and ignores the dangerous
20%. Cowork's hard part is
[ADR 003](003-bound-workers-to-their-orchestrator-without-a-daemon.md)'s
no-orphans rule, and that rule is pure POSIX process control:

- inheriting a death-pipe descriptor into a supervisor, and reading EOF the
  instant the orchestrator's descriptors close;
- placing each worker in its own process group and killing that group as a unit;
- `SIGTERM`, a grace period, then `SIGKILL`, with teardown and a terminal event
  posted inside the grace;
- `O_EXCL` slot files with liveness-based reclamation.

That is the property the product's safety rests on — a running agent must never
outlive the orchestrator that fired it — and it is the code most likely to be
subtly wrong. It is not incidental to the runtime; it is its centre. A language
that expresses process groups, signals and descriptor inheritance only
approximately is weakest exactly where cowork must be strongest.

The forces:

- **Swift does not lock the platform.** The product boundary is Apple-silicon
  macOS, but that is a product decision, not a consequence of this one: Swift,
  SwiftPM and Foundation run on Linux and Windows, and the runtime can be
  statically linked where it is not preinstalled. The supervision design is
  deliberately POSIX — `posix_spawn`, process groups, signals, pipes, `O_EXCL` —
  and ports as-is. Choosing Swift is not a one-way door.
- **The Swift runtime is ABI-stable and ships with macOS.** A compiled binary
  runs with no runtime dependency at all — where Node is a dependency that
  happens to be present.
- **MCP in Swift is real.** `modelcontextprotocol/swift-sdk` is official and
  actively maintained (verified 2026-07-16). An MCP server is a stdio JSON-RPC
  process; the host does not care what produced it.
- **Direct access to the platform.** `posix_spawn`, process groups, signals,
  kqueue, and file descriptors are first-class in Swift, not abstracted behind a
  thin and partial wrapper.
- **Maintainability by its owner.** This codebase's maintainer works primarily in
  Swift on Apple platforms. A runtime that is hard for its owner to reason about
  is not safe, whatever its type system says.

## Decision

**Cowork is written in Swift**, built as a single binary that serves MCP over
stdio using the official Swift SDK.

This governs the core runtime and the sugar layer. It does not govern role files,
which are data ([ADR 002](002-layer-cowork-as-core-and-sugar.md)).

> **Implementation status.** The Swift build ships the core supervision of
> [ADR 003](003-bound-workers-to-their-orchestrator-without-a-daemon.md) — own
> process group, death pipe, `SIGTERM`→`SIGKILL`, reconciliation, and
> `RLIMIT_CPU`. The `O_EXCL` concurrency slots named above, and the Seatbelt
> confinement and Keychain credential storage named below, are part of the design
> but **not yet built** (see ADR 003's implementation status).

## Consequences

**Positive**

- The safety-critical code is written in a language that expresses it directly.
  Death pipes, process groups, signal handling and descriptor inheritance are
  said plainly rather than approximated.
- Memory and data-race safety on exactly the concurrent supervision code that
  would otherwise be the easiest place to be quietly wrong.
- One binary, no runtime dependency, because the Swift runtime is part of the OS.
- A small dependency surface, in a tool whose job is running other agents against
  a user's workspace.
- Native to the platform the product is scoped to, and to the person who
  maintains it.

**Negative and accepted costs**

- **Distribution now needs a build.** Host plugin models copy a repo; they do not
  compile it. Cowork must therefore either ship a prebuilt binary or build on
  install, and both are worse than "the host already runs the runtime". This is
  the real price of this decision. **Resolved 2026-07-22 — see "Distribution —
  resolved" below.**
- **Platform integrations, not the language, are what would need porting.** The
  core supervision is POSIX and portable. Stronger confinement (macOS Seatbelt)
  and credential storage (Keychain) are *possible* Apple-specific modules —
  neither is built yet — and each would need a counterpart elsewhere (Landlock or
  Bubblewrap, Secret Service) only if the product boundary ever moves.
- **More ceremony for the easy parts.** JSON handling, prompt composition and
  role templating are more verbose in Swift than in TypeScript. The easy 80% gets
  slightly harder so the dangerous 20% gets substantially safer.
- **A smaller ecosystem.** Fewer libraries, and a smaller pool of people and
  agents fluent in the idioms — including for MCP, where the TypeScript SDK is
  the better-trodden path.

## Validation and evidence

Checked on 2026-07-16:

- Swift 6.4 toolchain present; `/usr/lib/swift` present, so the ABI-stable
  runtime is part of the OS and a compiled binary carries no runtime dependency.
- `modelcontextprotocol/swift-sdk` exists, is official, and was updated the same
  day (1,443 stars) — MCP over stdio in Swift is a live path, not a hope.
- The POSIX mechanisms this decision is made for were proven in principle before
  choosing the language: process-group kill contains an ordinary descendant tree,
  and an inherited death pipe reports EOF the instant the orchestrator is
  `SIGKILL`ed ([ADR 003](003-bound-workers-to-their-orchestrator-without-a-daemon.md)).

**Proven — the SDK serves stdio, and the POSIX mechanisms work from inside it.**
A minimal Swift package was built against the SDK and driven over stdio by a real
JSON-RPC client:

```text
  initialize -> OK, server: cowork | protocol: 2025-11-25 (latest spec)
  tools/list -> ["dispatch"]
  tools/call -> spawned pid=12345 pgid_own=true rlimit_cpu=5s spawn_rc=0 exit=0
```

The tool handler did the real thing rather than a stub: `posix_spawn` with
`POSIX_SPAWN_SETPGROUP` into its own process group, under a hard `RLIMIT_CPU`,
reaped with `waitpid`. So both halves of this decision are demonstrated together —
Swift serves MCP, and Swift expresses
[ADR 003](003-bound-workers-to-their-orchestrator-without-a-daemon.md)'s
supervision primitives directly, from the same process. Clean build in 33s from a
cold SwiftPM resolve.

The one wrinkle found: Darwin constants are imported inconsistently
(`NOTE_EXIT` is `UInt32`, `NOTE_TRACK` is `Int32`), so bitmask code needs
deliberate normalisation. An irritation, not an obstacle.

## Distribution — resolved (2026-07-22)

The open cost above has an answer: **ship a prebuilt binary and register it as an
MCP server per host — do not build on install.** This is the whole distribution
model, and it is now proven, not proposed.

- **Artifact:** a single universal (arm64 + x86_64) macOS binary, built and
  published by GitHub Actions on a `vX.Y.Z` tag
  ([`.github/workflows/release.yml`](../../.github/workflows/release.yml)). The
  binary carries no runtime dependency (the Swift runtime is part of the OS), so
  the whole product is `bin/cowork` plus its prose assets (`roles/`, `skills/`).
- **Install = place + register, never compile.**
  [`scripts/install.sh`](../../scripts/install.sh) copies the binary and its
  shipped roles/skills into a prefix, then registers cowork as an MCP server on
  every host CLI present — Claude Code, Codex, Copilot, OpenCode — via each host's
  own mechanism (`claude mcp add`; `codex mcp add` / `~/.codex/config.toml`;
  `copilot mcp add` / `~/.copilot/mcp-config.json`; `~/.config/opencode/opencode.json`).
  Config-file edits are idempotent and preserve unrelated settings.
- **Why prebuilt over build-on-install:** build-on-install would put a Swift
  toolchain and a multi-minute cold `swift build` in every user's install path,
  on a machine that may have neither. Prebuilt makes "install cowork" a copy plus
  a config line — the same cost as the host-runs-the-runtime plugins this ADR
  gave up — and moves the one build to CI, where it belongs.
- **Signing:** the release is signed with a Developer ID + hardened runtime and
  notarized when the repo carries the signing secrets; without them it ships
  ad-hoc-signed and the installer clears the quarantine bit for a local install.
  Notarization is the only piece gated on credentials, not on the design.
- **Version integrity:** the version lives in exactly one place
  ([`Sources/cowork/Version.swift`](../../Sources/cowork/Version.swift)); the shared
  gate [`scripts/check-release-ready.sh`](../../scripts/check-release-ready.sh)
  refuses to release a tag whose `vX.Y.Z` does not equal it, and proves the built
  binary self-reports that version over a real MCP `initialize`. A tag can never
  outrun the binary it names.

**Proven — a clean install registers on every host and a host connects.** The
installer, run from a clean prefix, laid down the binary + 27 roles, passed the
binary's own MCP handshake (10 core + 27 role tools), and registered on all four
host CLIs from one run; `claude mcp list` reported cowork **`✔ Connected`**. This
satisfies the distribution requirement — a decision is recorded, and a host CLI
can install cowork and dispatch from a clean state. Full manual steps and
per-host verification live in [`docs/install.md`](../install.md).

The confirmation trigger this ADR named — "distribution friction proves worse in
practice than the safety it buys" — has not fired: install is a copy plus a
config line.

## Confirmation

The decision holds while cowork is one Swift package with no second language in
its runtime.

It is working when ADR 003's confirmation passes: killing an orchestrating
session with `SIGKILL` leaves no worker alive, verified by process inspection.

It should be revisited if distribution friction proves worse in practice than the
safety it buys. A change of product boundary is not by itself a trigger: the
language follows, and only the platform integrations need counterparts.

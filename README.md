# cowork

**One self-contained binary that lets your coding agent delegate to peer coding
agents.** cowork runs as an MCP server inside your host CLI (Claude Code, Codex,
Copilot, or OpenCode) and dispatches work — implementation, review, QA, audits —
to whichever backend fits, under containment, with a truthful terminal verdict and
attributed lineage (every dispatch records its parent and root). The product itself is a single compiled binary plus its prose
assets (roles and skills) — no runtime to *run*. (The installer uses `python3`
to merge each host's MCP config; see Requirements.)

cowork is a *messenger*, not a harness: it carries a task to a worker and reports
what actually happened. It does not reach inside a worker to smooth over its
quirks, and it never claims success it did not observe.

## The contract — 10 core tools

Every host integration speaks the same ten tools:

| Tool | Purpose |
|---|---|
| `dispatch` | Hand a task to a backend; returns a dispatch id |
| `status` | A dispatch's current state |
| `wait` | Block until a terminal state or a hard-capped timeout, then return the state (including "still running") |
| `output` | The worker's declared result |
| `cancel` | Stop a running dispatch |
| `list` | Your dispatches |
| `send` | Message a warm interactive worker (keeps its context) |
| `finish` | End a warm interactive session |
| `follow_up` | Continue a finished dispatch's context in a fresh run (where the backend supports it) |
| `capabilities` | Available backends + current availability |

On top of the ten, cowork exposes **one tool per shipped role** (`roles/*.role`)
— a role is a reusable task template with hard slots. Editing a role file changes
how work gets done; nothing is recompiled. Skills (`skills/`) are the prose
judgment loops (review, qa, audit, jury, visionaries, superreview) that call these
tools.

## Backends

- **CLI agents** — Claude Code, Codex, Grok built in, plus **any other CLI** you
  wire from config (see below). The worker owns its own lifecycle; cowork
  dispatches and collects. Interactive `send`/`finish` keep a built-in worker warm
  across turns.
- **HTTP endpoints** — any OpenAI-compatible chat API (hosted models, or a local
  Ollama over `/v1`). Cowork drives the turn loop itself.

### Wiring any CLI

A `kind = "generic"` block in `~/.cowork/config.toml` describes a CLI's wire, so a
new agent is configuration rather than a cowork release. This is the answer for a
small local model: put an agent harness in front of it and let the harness own the
context and compaction.

```toml
[cli.opencode]
executable     = "~/.opencode/bin/opencode"
kind           = "generic"
task_delivery  = "argv"              # argv | stdin_raw | stdin_json_stream_user
args           = ["run", "{task}"]
workspace_args = ["--cwd", "{workspace}"]
output         = "raw"               # raw | json_field | stream_json_result
verdict        = "exit_code"    # a CLOSED set of tested outcome rules

[cli.opencode.env]
OPENCODE_MODEL = "ollama/qwen2.5-coder:7b"

[cli.opencode.isolate]
var = "XDG_CONFIG_HOME"              # fresh 0700 dir per dispatch, always removed
```

`verdict` **selects** one of cowork's tested outcome rules — it can never author
one, so no config can make a failed worker report success. Generic blocks are
global-config only, their environment may not touch execution-sensitive keys, and a
config-wired capability is advertised with an `unverified` marker until a real run
proves it. See
**[ADR 007](docs/ADRs/007-open-the-cli-transport-to-any-agent-by-descriptor.md)**.

## Install

```sh
# from a release tarball:
tar -xzf cowork-<version>-macos-universal.tar.gz
cd cowork-<version>-macos-universal
./install.sh
```

The installer places the binary + its roles/skills and registers cowork as an MCP
server on every host CLI it finds. Full steps, per-host verification, signing /
notarization notes, and how to cut a release: **[docs/install.md](docs/install.md)**.

## Requirements

- macOS 14+ (universal arm64 + x86_64 binary).
- `python3` (used by the installer to merge each host's MCP config).
- At least one host CLI on `PATH` (Claude Code, Codex, Copilot, or OpenCode) and
  a backend it can reach.

## Developing cowork

```sh
swift build -c release      # the binary lands at .build/release/cowork
swift test                  # hermetic — no API keys or peer CLIs required
scripts/install.sh --local  # install your local build
```

The release pipeline (`.github/workflows/`) builds, tests, signs, and publishes a
GitHub Release on a `vX.Y.Z` tag. Architecture decisions live in
[`docs/ADRs/`](docs/ADRs).

## Verification

cowork's contract is acceptance-gated by the
[use-cases](https://github.com/adammcarter/use-cases) plugin. The matrix in
`use-cases/` defines one row per contract behaviour; each row's verifier is a
**performed journey** that drives the *built binary* over real stdio MCP — the
same surface a host CLI touches — and observes the behaviour rather than
asserting it in a unit test. A row that cannot be performed fails loudly; there
is no skip.

```sh
swift build -c release   # the journeys run against the built binary
uc verify --all          # perform every acceptance row (use-cases plugin)
uc scan                  # matrix health
```

These journeys are **live** — they dispatch to real backends, so they need a
backend reachable from your machine and run locally rather than in CI. That is
deliberate: `swift test` (the CI gate) fakes every peer CLI and proves the code
is internally consistent with no keys; `uc verify` proves the contract actually
works end-to-end against a real backend.

## License

[MIT](LICENSE).

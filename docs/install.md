# Installing cowork

cowork is **one self-contained binary**. A host CLI runs it as an MCP server; it
is never compiled on the host. Installing is therefore two things: put the binary
(and its roles/skills) somewhere, and register it as an MCP server on each host.
`scripts/install.sh` does both.

## Quick start (from a release)

```sh
# download + unpack a release tarball, then:
tar -xzf cowork-<version>-macos-universal.tar.gz
cd cowork-<version>-macos-universal
./install.sh
```

The installer:

1. copies `bin/cowork` + `roles/` + `skills/` into `~/.cowork` (override with
   `--prefix` or `COWORK_PREFIX`),
2. clears the download quarantine bit so the binary runs,
3. self-checks the binary (MCP handshake + the 10 core tools),
4. registers cowork as an MCP server on every host CLI it finds.

## From a local build (developing cowork)

```sh
swift build -c release
scripts/install.sh --local
```

## What gets registered, per host

| Host | Mechanism | Verify |
|---|---|---|
| Claude Code | `claude mcp add --scope user cowork -- <bin>` | `claude mcp list \| grep cowork` → `✔ Connected` |
| Codex | `codex mcp add cowork -- <bin>`, else a `[mcp_servers.cowork]` block in `~/.codex/config.toml` | `codex mcp list` |
| Copilot | `copilot mcp add cowork -- <bin>`, else `~/.copilot/mcp-config.json` | `copilot mcp list` |
| OpenCode | `mcp.cowork` in `~/.config/opencode/opencode.json` | `opencode mcp list` |

Every config-file edit is idempotent and preserves unrelated settings. A host CLI
that isn't on `PATH` is skipped, not an error.

### Side-by-side installs

Set `COWORK_MCP_NAME` to register under a different name (e.g. try a new build
next to a working one without clobbering it):

```sh
COWORK_MCP_NAME=cowork-next scripts/install.sh --local --prefix ~/.cowork/next
```

## Layout it writes

```
~/.cowork/            # the install prefix (COWORK_PREFIX)
├── bin/cowork             # the binary
├── roles/*.role           # SHIPPED roles — found by walking up from the binary
├── skills/…               # prose skills
└── commands/…

~/.cowork/roles/           # your GLOBAL role overrides (separate, untouched)
<project>/.cowork/roles/   # per-project role overrides
```

Shipped roles travel *beside the binary* on purpose: cowork locates them by
walking up from its own path, so the global override layer at `~/.cowork/roles`
stays cleanly separate. Deleting every role still leaves a complete, working core
(the 10 contract tools).

## Signing, notarization, and Gatekeeper

Releases are built by GitHub Actions (`.github/workflows/release.yml`) as a
universal (arm64 + x86_64) binary.

- **With Developer ID secrets** in the repo (`MACOS_CERTIFICATE`, `MACOS_SIGN_IDENTITY`,
  `MACOS_NOTARY_KEY`/`_ID`/`ISSUER`), the binary is signed with a hardened runtime
  and notarized — it runs on any Mac with no extra step.
- **Without those secrets**, the release binary is ad-hoc signed. It runs after the
  installer clears the quarantine bit (`xattr -dr com.apple.quarantine`). To run a
  raw downloaded copy by hand, clear it yourself:

  ```sh
  xattr -dr com.apple.quarantine /path/to/cowork
  ```

## Cutting a release

Version lives in exactly one place: `Sources/cowork/Version.swift`. A release is a
deliberate bump commit that lands *before* the tag.

```sh
# 1. bump Sources/cowork/Version.swift, commit
# 2. verify locally (build + tests + the binary self-reports the version over MCP)
bash scripts/check-release-ready.sh --version X.Y.Z
# 3. tag — the Release workflow re-runs the same gate and refuses on any mismatch
git tag vX.Y.Z && git push origin vX.Y.Z
```

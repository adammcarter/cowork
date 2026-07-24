#!/usr/bin/env bash
#
# cowork installer — places the prebuilt binary + its roles/skills, then registers
# it as an MCP server on every host CLI it finds (Claude Code, Codex, Copilot,
# OpenCode). cowork is one self-contained binary: a host runs it, it never gets
# compiled on the host.
#
# Run it three ways:
#   • from an unpacked release tarball:   ./install.sh            (uses ./bin/cowork)
#   • from a local dev build:             scripts/install.sh --local
#                                         (uses .build/release/cowork)
#   • point at any binary:                ./install.sh --binary /path/to/cowork
#
# Layout it writes — flat, straight into cowork's home. The shipped roles land
# at ~/.cowork/roles, which is ALSO the user's global role layer: the binary
# reads one directory as one layer, and this installer MERGES into it (shipped
# names are updated, roles the user added are never touched). Runtime state
# (config.toml, jobs/) lives beside it and is never written by this script.
#
#   $COWORK_PREFIX/                 (default ~/.cowork)
#   ├── bin/cowork
#   ├── roles/*.role                (shipped ∪ yours — merged, never clobbered)
#   ├── skills/…
#   ├── commands/…
#   └── examples/config.toml       (a worked sample — never $PREFIX/config.toml)
#
# Skills are then LINKED into each host's skill discovery directory
# (~/.claude/skills, ~/.codex/skills, ~/.copilot/skills) as cowork-<name>
# symlinks pointing back at $PREFIX/skills/<name> — one canonical source, no
# copies to drift. OpenCode has no skill loader; its users get the same
# capabilities as role_* tools. Override the host dirs for testing with
# COWORK_CLAUDE_SKILLS_DIR / COWORK_CODEX_SKILLS_DIR / COWORK_COPILOT_SKILLS_DIR.
set -euo pipefail

GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
heading() { printf "\n%s== %s ==%s\n" "$DIM" "$1" "$RESET"; }
ok()      { printf "%s[ok]%s %s\n" "$GREEN" "$RESET" "$1"; }
skip()    { printf "%s[skip]%s %s\n" "$DIM" "$RESET" "$1"; }
warn()    { printf "%s[warn]%s %s\n" "$YELLOW" "$RESET" "$1" >&2; }
die()     { printf "%s[fail]%s %s\n" "$RED" "$RESET" "$1" >&2; exit 1; }

PREFIX="${COWORK_PREFIX:-$HOME/.cowork}"
SRC=""            # directory holding bin/cowork + roles + skills
BINARY_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --local)      SRC="local"; shift ;;
    --binary)     BINARY_OVERRIDE="${2:?--binary needs a path}"; shift 2 ;;
    --prefix)     PREFIX="${2:?--prefix needs a path}"; shift 2 ;;
    -h|--help)
      sed -n '2,22p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 is required for host config merges"

# Canonicalise the prefix to an absolute path — the resolved path is what gets
# registered with every host, so a relative one would leave a dangling command.
mkdir -p "$PREFIX" && PREFIX="$(cd "$PREFIX" && pwd)"

# --- 1. locate the source tree (binary + roles + skills) -----------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "$BINARY_OVERRIDE" ]; then
  [ -x "$BINARY_OVERRIDE" ] || die "not an executable: $BINARY_OVERRIDE"
  SRC="$(cd "$(dirname "$BINARY_OVERRIDE")/.." && pwd)"   # expects <src>/bin/cowork
  [ "$(basename "$BINARY_OVERRIDE")" = "cowork" ] || warn "binary is not named 'cowork'"
elif [ "$SRC" = "local" ]; then
  REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
  [ -x "$REPO/.build/release/cowork" ] || die "no local build — run: swift build -c release"
  # Stage a source tree with the expected bin/ layout from the repo.
  SRC="$(mktemp -d)"
  mkdir -p "$SRC/bin"
  cp "$REPO/.build/release/cowork" "$SRC/bin/cowork"
  cp -R "$REPO/roles" "$SRC/roles"
  cp -R "$REPO/skills" "$SRC/skills"
  [ -d "$REPO/commands" ] && cp -R "$REPO/commands" "$SRC/commands"
  [ -d "$REPO/examples" ] && cp -R "$REPO/examples" "$SRC/examples" || true
  trap 'rm -rf "$SRC"' EXIT   # staged copy is throwaway
elif [ -x "$SCRIPT_DIR/bin/cowork" ]; then
  SRC="$SCRIPT_DIR"                        # unpacked release tarball: install.sh sits next to bin/
elif [ -x "$SCRIPT_DIR/../bin/cowork" ]; then
  SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  die "could not find a cowork binary — unpack a release tarball and run ./install.sh, or use --local / --binary"
fi

[ -x "$SRC/bin/cowork" ] || die "missing $SRC/bin/cowork"
[ -d "$SRC/roles" ]      || die "missing $SRC/roles (shipped roles must travel with the binary)"

# --- 2. install into the prefix ------------------------------------------------
heading "Installing to $PREFIX"
mkdir -p "$PREFIX/bin"
cp "$SRC/bin/cowork" "$PREFIX/bin/cowork"
chmod +x "$PREFIX/bin/cowork"
# Merge roles: overwrite shipped names, preserve any .role the user added.
# (~/.cowork/roles doubles as the user's global layer in the flat layout.)
mkdir -p "$PREFIX/roles"
cp "$SRC/roles/"*.role "$PREFIX/roles/"
[ -d "$SRC/skills" ]   && { rm -rf "$PREFIX/skills";   cp -R "$SRC/skills"   "$PREFIX/skills"; }
[ -d "$SRC/commands" ] && { rm -rf "$PREFIX/commands"; cp -R "$SRC/commands" "$PREFIX/commands"; }
# The example config lands beside the user's real one, never on top of it: cowork
# ships no built-in agents, so this file is the only worked reference for wiring
# a CLI — but it is a sample, and $PREFIX/config.toml is the user's own state.
[ -d "$SRC/examples" ] && { rm -rf "$PREFIX/examples"; cp -R "$SRC/examples" "$PREFIX/examples"; } || true

# --- 2b. link skills into each host's discovery directory ----------------------
# One canonical source (the installed $PREFIX/skills) linked as cowork-<name>
# into every host that loads SKILL.md from a skills dir. Idempotent: stale
# cowork-* links owned by us (i.e. resolving into $PREFIX/skills) are removed
# first, so renamed or retired skills disappear; anything else in the host dir
# is never touched.
#: @use-case:sugar.skills.installed_skills_reach_every_host_loader
link_skills_into() {
  host_dir="$1"; host_name="$2"
  [ -d "$PREFIX/skills" ] || return 0
  mkdir -p "$host_dir"
  for link in "$host_dir"/cowork-*; do
    [ -L "$link" ] || continue
    case "$(readlink "$link")" in "$PREFIX/skills/"*) rm "$link" ;; esac
  done
  linked=0
  for skill in "$PREFIX/skills"/*/; do
    name="$(basename "$skill")"
    [ -f "$skill/SKILL.md" ] || { warn "[$host_name] skills/$name has no SKILL.md — not linked"; continue; }
    ln -s "$PREFIX/skills/$name" "$host_dir/cowork-$name"
    linked=$((linked + 1))
  done
  ok "[$host_name] $linked skills linked into $host_dir"
}

link_skills_into "${COWORK_CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"   claude
link_skills_into "${COWORK_CODEX_SKILLS_DIR:-$HOME/.codex/skills}"     codex
link_skills_into "${COWORK_COPILOT_SKILLS_DIR:-$HOME/.copilot/skills}" copilot
# opencode: no SKILL.md loader — the role_* tools carry these capabilities there.
#: @use-case:end sugar.skills.installed_skills_reach_every_host_loader

BIN="$PREFIX/bin/cowork"
# The MCP server name hosts register cowork under. Override to install a second
# copy side-by-side (e.g. a new build next to a working one) without clobbering
# the existing registration.
MCP_NAME="${COWORK_MCP_NAME:-cowork}"
# A downloaded / ad-hoc-signed binary carries the quarantine bit; clear it so the
# locally-installed copy runs. (A notarized Developer ID build needs no help.)
xattr -dr com.apple.quarantine "$BIN" 2>/dev/null || true

ROLE_COUNT="$(find "$PREFIX/roles" -name '*.role' | wc -l | tr -d ' ')"
[ "$ROLE_COUNT" -gt 0 ] || die "no .role files shipped beside the binary — install is incomplete"
ok "binary + $ROLE_COUNT roles at $PREFIX"

# --- 3. self-check: the installed binary answers MCP ---------------------------
heading "Verifying the installed binary"
python3 - "$BIN" <<'PY' || die "installed binary failed its MCP handshake"
import json, subprocess, sys, threading
p = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, text=True, bufsize=1)
def _hang():
    p.kill(); sys.stderr.write("cowork did not answer initialize within 30s\n")
watchdog = threading.Timer(30.0, _hang); watchdog.daemon = True; watchdog.start()
try:
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":1,"method":"initialize",
      "params":{"protocolVersion":"2024-11-05","capabilities":{},
                "clientInfo":{"name":"install","version":"1"}}})+"\n"); p.stdin.flush()
    info = json.loads(p.stdout.readline())["result"]["serverInfo"]
    p.stdin.write(json.dumps({"jsonrpc":"2.0","method":"notifications/initialized","params":{}})+"\n")
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}})+"\n"); p.stdin.flush()
    tools = json.loads(p.stdout.readline())["result"]["tools"]
finally:
    watchdog.cancel(); p.stdin.close(); p.terminate()
core = {"dispatch","status","output","wait","cancel","list","send","finish","follow_up","capabilities"}
have = {t["name"] for t in tools}
if not core <= have:
    sys.exit(f"missing core tools: {sorted(core - have)}")
print(f"  cowork {info['version']} — {len(have)} tools ({len(have)-len(core)} role tools)")
PY
ok "MCP handshake + 10 core tools present"

# --- 4. register as an MCP server on every host present ------------------------
heading "Registering cowork as an MCP server"

# Claude Code — CLI, user scope, idempotent (remove then add).
if command -v claude >/dev/null 2>&1; then
  claude mcp remove "$MCP_NAME" --scope user >/dev/null 2>&1 || true
  if claude mcp add --scope user "$MCP_NAME" -- "$BIN" >/dev/null 2>&1; then
    ok "[claude] registered as '$MCP_NAME'"
  else warn "[claude] registration failed"; fi
else skip "[claude] CLI not on PATH"; fi

# Codex — prefer `codex mcp add`, else an idempotent config.toml block.
if command -v codex >/dev/null 2>&1; then
  if codex mcp add "$MCP_NAME" -- "$BIN" >/dev/null 2>&1; then
    ok "[codex] registered as '$MCP_NAME' (codex mcp add)"
  else
    python3 - "$HOME/.codex/config.toml" "$BIN" "$MCP_NAME" <<'PY' && ok "[codex] registered (config.toml)" || warn "[codex] registration failed"
import pathlib, re, sys
path, binp, name = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
path.parent.mkdir(parents=True, exist_ok=True)
text = path.read_text() if path.exists() else ""
block = f'[mcp_servers.{name}]\ncommand = "{binp}"\nargs = []\n'
# Replace an existing [mcp_servers.<name>] block, else append — never clobber the rest.
# NOTE: multiline (?m) only, NOT DOTALL — with (?s) the greedy `.*` would swallow
# every following section and silently delete other users' MCP servers.
pat = re.compile(rf'(?m)^\[mcp_servers\.{re.escape(name)}\]\n(?:(?!^\[).*\n?)*')
text = pat.sub(block, text) if pat.search(text) else (text.rstrip()+"\n\n"+block if text.strip() else block)
tmp = path.with_name(path.name+".tmp"); tmp.write_text(text); tmp.replace(path)
PY
  fi
else skip "[codex] CLI not on PATH"; fi

# Copilot — prefer `copilot mcp add`, else ~/.copilot/mcp-config.json.
if command -v copilot >/dev/null 2>&1; then
  if copilot mcp add "$MCP_NAME" -- "$BIN" >/dev/null 2>&1; then
    ok "[copilot] registered as '$MCP_NAME' (copilot mcp add)"
  else
    python3 - "$HOME/.copilot/mcp-config.json" "$BIN" "$MCP_NAME" <<'PY' && ok "[copilot] registered (mcp-config.json)" || warn "[copilot] registration failed"
import json, pathlib, sys
path, binp, name = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
path.parent.mkdir(parents=True, exist_ok=True)
data = json.loads(path.read_text()) if path.exists() and path.read_text().strip() else {}
data.setdefault("mcpServers", {})[name] = {"type":"local","command":binp,"args":[],"tools":["*"]}
tmp = path.with_name(path.name+".tmp"); tmp.write_text(json.dumps(data, indent=2)+"\n"); tmp.replace(path)
PY
  fi
else skip "[copilot] CLI not on PATH"; fi

# OpenCode — merge into ~/.config/opencode/opencode.json, preserving all else.
OPENCODE_CFG="${COWORK_OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
if command -v opencode >/dev/null 2>&1 || [ -f "$OPENCODE_CFG" ]; then
  python3 - "$OPENCODE_CFG" "$BIN" "$MCP_NAME" <<'PY' && ok "[opencode] registered as '$MCP_NAME'" || warn "[opencode] registration failed"
import json, pathlib, sys
path, binp, name = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
path.parent.mkdir(parents=True, exist_ok=True)
data = json.loads(path.read_text()) if path.exists() and path.read_text().strip() else {}
if not isinstance(data, dict): raise SystemExit(f"{path} must be a JSON object")
data.setdefault("$schema", "https://opencode.ai/config.json")
mcp = data.setdefault("mcp", {})
mcp[name] = {"type":"local","command":[binp],"enabled":True}
tmp = path.with_name(path.name+".tmp"); tmp.write_text(json.dumps(data, indent=2)+"\n"); tmp.replace(path)
PY
else skip "[opencode] CLI not on PATH"; fi

# --- 5. summary ----------------------------------------------------------------
heading "Done"
cat <<EOF
cowork is installed at $BIN

Verify a host picked it up:
  claude mcp list        | grep cowork      # → cowork: ... ✔ Connected
  codex mcp list         | grep cowork
  opencode mcp list      | grep cowork

cowork ships no built-in agents: every backend is a row in ~/.cowork/config.toml.
Copy the rows for the agents you have from $PREFIX/examples/config.toml and fix
the paths, then check what cowork can reach with the \`capabilities\` tool.

Shipped roles live at ~/.cowork/roles — add your own .role files right there
(reinstalls merge, never clobber) or per-project in <project>/.cowork/roles.
See docs/install.md.
EOF

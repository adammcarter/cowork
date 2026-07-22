#!/usr/bin/env bash
#
# The shared local / CI / release gate. No arguments: verify the current
# canonical version builds, tests green, and the built binary reports that exact
# version over a real MCP `initialize`. With `--version X.Y.Z`: additionally
# assert the canonical version already equals X.Y.Z, so a tag can never race
# ahead of the binary it names.
#
# A release is therefore always a deliberate bump commit (edit Version.swift)
# that lands BEFORE the tag — the release workflow runs this with the tag's
# version and refuses to publish on any mismatch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EXPECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) EXPECT="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --- 1. canonical version, from the one place it lives --------------------
VERSION="$(sed -nE 's/^let coworkVersion = "([^"]+)".*/\1/p' Sources/cowork/Version.swift)"
if [ -z "$VERSION" ]; then
  echo "FAIL: cannot read coworkVersion from Sources/cowork/Version.swift" >&2
  exit 1
fi
echo "== canonical version: $VERSION =="

if [ -n "$EXPECT" ] && [ "$EXPECT" != "$VERSION" ]; then
  echo "FAIL: --version $EXPECT but Sources/cowork/Version.swift says $VERSION" >&2
  echo "      bump Version.swift and commit before tagging v$EXPECT" >&2
  exit 1
fi

# --- 2. build + hermetic tests -------------------------------------------
echo "== swift build -c release =="
swift build -c release

echo "== swift test =="
swift test

# --- 3. the built binary reports the canonical version over MCP ----------
# End-to-end proof, not a grep: a strict host learns the version from the
# `initialize` reply, so that is what we check.
BIN=".build/release/cowork"
[ -x "$BIN" ] || { echo "FAIL: $BIN not built" >&2; exit 1; }

echo "== MCP initialize version probe =="
COWORK_SHIPPED_ROLES="" python3 - "$BIN" "$VERSION" <<'PY'
import json, subprocess, sys, threading

binary, expected = sys.argv[1], sys.argv[2]
proc = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, text=True, bufsize=1)
def _hang():
    proc.kill(); sys.stderr.write("cowork did not answer initialize within 30s\n")
watchdog = threading.Timer(30.0, _hang); watchdog.daemon = True; watchdog.start()
req = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
       "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                  "clientInfo": {"name": "release-gate", "version": "1"}}}
proc.stdin.write(json.dumps(req) + "\n"); proc.stdin.flush()
line = proc.stdout.readline()
watchdog.cancel(); proc.stdin.close(); proc.terminate()
try:
    reported = json.loads(line)["result"]["serverInfo"]["version"]
except Exception as e:
    sys.exit(f"FAIL: could not read serverInfo.version from initialize reply: {e}\n{line!r}")
if reported != expected:
    sys.exit(f"FAIL: binary reports version {reported!r}, expected {expected!r}")
print(f"OK: binary reports version {reported}")
PY

echo "== RELEASE READY at $VERSION =="

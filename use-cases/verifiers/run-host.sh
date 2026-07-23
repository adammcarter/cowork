#!/usr/bin/env bash
# The host-conformance verifier: one row family, one HOST HARNESS per variant.
#
# Where run.sh proves the contract against a generic stdio MCP client, this
# script proves it through a real agent CLI: the variant names the host
# (claude | codex | copilot | opencode), and the journey drives that host
# headlessly with cowork registered as a scoped MCP server. Exit codes are the
# variant's verdict, same contract as run.sh:
#   0  the behaviour was observed through this host, now
#   1  the behaviour was NOT observed — a finding
#   3  the variant's precondition is genuinely absent (host CLI not installed)
set -uo pipefail

row="${1:-}"
variant="${2:-}"
if [[ -z "$row" || -z "$variant" ]]; then
  echo "usage: run-host.sh <row-id> <host-variant>" >&2
  exit 2
fi

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ ! -x "$repo/.build/release/cowork" ]]; then
  echo "run-host.sh: build the binary first: swift build -c release" >&2
  exit 3
fi

exec python3 "$repo/use-cases/verifiers/host_journeys.py" "$row" "$variant"

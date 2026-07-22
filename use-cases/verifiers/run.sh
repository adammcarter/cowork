#!/usr/bin/env bash
# The verifier `uc` runs for every row. One row id in, one performed journey out.
#
# Exit codes are the row's verdict:
#   0  the behaviour was observed, now, against the real binary
#   1  the behaviour was NOT observed — a finding, never something to smooth over
#   3  the row's precondition is genuinely absent (see the reason on stderr)
#
# There is no skip. A row that cannot be verified fails, loudly, with its reason.
set -uo pipefail

row="${1:-}"
if [[ -z "$row" ]]; then
  echo "usage: run.sh <row-id>" >&2
  exit 2
fi

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ ! -x "$repo/.build/release/cowork" ]]; then
  echo "the cowork binary is not built. run: swift build -c release" >&2
  exit 2
fi

exec python3 "$repo/use-cases/verifiers/journeys.py" "$row"

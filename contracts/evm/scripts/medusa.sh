#!/usr/bin/env bash
# Run Crytic Medusa against Bunni-style `test/fuzz/FuzzEntry.sol` without Echidna linked-library preparation.
#
# Prerequisites: `medusa` on PATH (https://github.com/crytic/medusa/releases), `crytic-compile` with Foundry support.
#
# Default: compile only `FuzzEntry.sol` so the full protocol graph does not hit crytic-compile library deployment-order
# cycles. Override with MEDUSA_COMPILE_TARGET or pass --compilation-target yourself.
#
# Usage (from contracts/evm/):
#   ./scripts/medusa.sh
#   ./scripts/medusa.sh --config medusa.json --test-limit 2000
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v medusa >/dev/null 2>&1; then
  echo "medusa: not found on PATH. Install a release from https://github.com/crytic/medusa/releases" >&2
  exit 1
fi

DEFAULT_TARGET="${MEDUSA_COMPILE_TARGET:-./test/fuzz/FuzzEntry.sol}"
has_compile_target=false
for arg in "$@"; do
  if [[ "$arg" == "--compilation-target" ]]; then
    has_compile_target=true
    break
  fi
done

if [[ "$has_compile_target" == false ]]; then
  exec medusa fuzz --compilation-target "$DEFAULT_TARGET" "$@"
else
  exec medusa fuzz "$@"
fi

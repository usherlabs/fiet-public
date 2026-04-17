#!/usr/bin/env sh
set -eu

# -----------------------------------------------------------------------------
# Purpose and high-level behavior
# -----------------------------------------------------------------------------
# Generic Medusa runner for this repo.
#
# Usage:
#   just medusa file=test/fuzz/invariants/LCC01.sol contract=LCC01
#
# The Solidity harness/property names intentionally retain their legacy
# `echidna_*` prefixes so Medusa can run the existing suite without a broad
# contract rename.

# Run from repo root or from contracts/evm/; normalize to contracts/evm.
if [ -d "contracts/evm" ]; then
  cd "contracts/evm"
fi

FILE=""
CONTRACT=""
CONFIG="medusa.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      FILE="${2:-}"
      shift 2
      ;;
    --contract)
      CONTRACT="${2:-}"
      shift 2
      ;;
    --config)
      CONFIG="${2:-}"
      shift 2
      ;;
    --help|-h)
      echo "Usage: medusa.sh --file <path.sol> --contract <ContractName> [--config <path.json>] [-- <extra medusa args>]" 1>&2
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

EXTRA_ARGS="$*"

if [ -z "$FILE" ] || [ -z "$CONTRACT" ]; then
  echo "error: missing --file or --contract" 1>&2
  echo "example: just medusa file=test/fuzz/invariants/LCC01.sol contract=LCC01" 1>&2
  exit 2
fi

case "$FILE" in
  /*)
    TARGET_FILE="$FILE"
    ;;
  *)
    TARGET_FILE="$(pwd)/$FILE"
    ;;
esac

if [ ! -f "$TARGET_FILE" ]; then
  echo "error: target file not found: $FILE" 1>&2
  exit 2
fi

if ! command -v medusa >/dev/null 2>&1; then
  echo "error: medusa binary not found in PATH" 1>&2
  exit 1
fi

TMP_CONFIG="$(mktemp "${TMPDIR:-/tmp}/medusa.${CONTRACT}.XXXXXX.json")"
cleanup() {
  rm -f "$TMP_CONFIG"
}
trap cleanup EXIT INT TERM

python3 - "$CONFIG" "$TMP_CONFIG" "$TARGET_FILE" "$CONTRACT" <<'PY'
import json
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
file = sys.argv[3]
contract = sys.argv[4]

config = json.loads(src.read_text())
config.setdefault("fuzzing", {})["targetContracts"] = [contract]
config.setdefault("compilation", {}).setdefault("platformConfig", {})["target"] = file
dst.write_text(json.dumps(config, indent=2) + "\n")
PY

# shellcheck disable=SC2086
medusa fuzz --config "$TMP_CONFIG" $EXTRA_ARGS

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
# Solidity property functions use the repo-standard `fuzz_*` prefix.
#
# If MEDUSA_CORPUS_DIR is set, coverage-guided corpus artifacts are written to
# <MEDUSA_CORPUS_DIR>/<ContractName>/ using an absolute path rooted at this repo.

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

CORPUS_DIR=""
if [ "${MEDUSA_CORPUS_DIR:-}" != "" ]; then
  case "$MEDUSA_CORPUS_DIR" in
    /*)
      CORPUS_DIR="$MEDUSA_CORPUS_DIR/$CONTRACT"
      ;;
    *)
      CORPUS_DIR="$(pwd)/$MEDUSA_CORPUS_DIR/$CONTRACT"
      ;;
  esac
  mkdir -p "$CORPUS_DIR"
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

python3 - "$CONFIG" "$TMP_CONFIG" "$TARGET_FILE" "$CONTRACT" "$CORPUS_DIR" <<'PY'
import json
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
file = sys.argv[3]
contract = sys.argv[4]
corpus = sys.argv[5]

config = json.loads(src.read_text())
config.setdefault("fuzzing", {})["targetContracts"] = [contract]
if corpus:
    config["fuzzing"]["corpusDirectory"] = corpus
config.setdefault("compilation", {}).setdefault("platformConfig", {})["target"] = file
dst.write_text(json.dumps(config, indent=2) + "\n")
PY

# shellcheck disable=SC2086
medusa fuzz --config "$TMP_CONFIG" $EXTRA_ARGS

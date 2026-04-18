#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Purpose and high-level behavior
# -----------------------------------------------------------------------------
# Config-driven Medusa runner for the supported FuzzEntry path.
#
# Usage:
#   just medusa-entry
#
# The config must declare:
# - fuzzing.targetContracts = ["FuzzEntry", ...]
# - compilation.platformConfig.target = "./test/fuzz/FuzzEntry.sol"
#
# If MEDUSA_CORPUS_DIR is set, coverage-guided corpus artifacts are written to
# <MEDUSA_CORPUS_DIR>/<TargetContract>/ using an absolute path rooted at this repo.

# Run from repo root or from contracts/evm/; normalize to contracts/evm.
if [ -d "contracts/evm" ]; then
  cd "contracts/evm"
fi

if ! command -v medusa >/dev/null 2>&1; then
  echo "error: medusa binary not found in PATH" 1>&2
  exit 1
fi

CONFIG="medusa.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      CONFIG="${2:-}"
      shift 2
      ;;
    --help|-h)
      echo "Usage: medusa.sh [--config <path.json>] [-- <extra medusa args>]" 1>&2
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

EXTRA_ARGS=("$@")

if [ ! -f "$CONFIG" ]; then
  echo "error: config not found: $CONFIG" 1>&2
  exit 2
fi

CORPUS_ROOT=""
if [ "${MEDUSA_CORPUS_DIR:-}" != "" ]; then
  case "$MEDUSA_CORPUS_DIR" in
    /*)
      CORPUS_ROOT="$MEDUSA_CORPUS_DIR"
      ;;
    *)
      CORPUS_ROOT="$(pwd)/$MEDUSA_CORPUS_DIR"
      ;;
  esac
  mkdir -p "$CORPUS_ROOT"
fi

TMP_CONFIG="$(mktemp "${TMPDIR:-/tmp}/medusa.config.XXXXXX.json")"
cleanup() {
  rm -f "$TMP_CONFIG"
}
trap cleanup EXIT INT TERM

python3 - "$CONFIG" "$TMP_CONFIG" "$CORPUS_ROOT" <<'PY'
import json
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
corpus_root = sys.argv[3]

config = json.loads(src.read_text())
fuzzing = config.setdefault("fuzzing", {})
target_contracts = fuzzing.get("targetContracts") or []
if not target_contracts or not target_contracts[0]:
    raise SystemExit("error: config must set fuzzing.targetContracts to at least one concrete contract")

platform_config = config.setdefault("compilation", {}).setdefault("platformConfig", {})
target = platform_config.get("target")
if not target:
    raise SystemExit("error: config must set compilation.platformConfig.target to a concrete Solidity file")

target_path = pathlib.Path(target)
if not target_path.is_absolute():
    target_path = (src.parent / target_path).resolve()
platform_config["target"] = str(target_path)

if corpus_root:
    fuzzing["corpusDirectory"] = str(pathlib.Path(corpus_root).resolve() / target_contracts[0])

dst.write_text(json.dumps(config, indent=2) + "\n")
PY

medusa fuzz --config "$TMP_CONFIG" "${EXTRA_ARGS[@]}"

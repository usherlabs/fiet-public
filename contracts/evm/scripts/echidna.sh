#!/usr/bin/env sh
set -eu

# Generic Echidna runner for this repo.
#
# Native-first: if `echidna`/`echidna-test` is installed locally, we use it.
# Docker fallback is optional; set FORCE_DOCKER=1 to force Docker.
#
# Usage:
#   yarn run echidna -- --file test/fuzz/MyHarness.sol --contract MyHarness

# Run from repo root or from contracts/evm/; normalize to contracts/evm.
if [ -d "contracts/evm" ]; then
  cd "contracts/evm"
fi

FILE=""
CONTRACT=""
CONFIG="echidna.config.yml"

COMPILE_BACKEND="${ECHIDNA_COMPILE:-solc}" # solc | foundry

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
      echo "Usage: echidna.sh --file <path.sol> --contract <ContractName> [--config <path.yml>] [-- <extra echidna args>]" 1>&2
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      # Allow passing through extra echidna args without `--`.
      break
      ;;
  esac
done

EXTRA_ARGS="$*"

if [ -z "$FILE" ] || [ -z "$CONTRACT" ]; then
  echo "error: missing --file or --contract" 1>&2
  echo "example: yarn run echidna -- --file test/fuzz/LiquidityHubLCCBackingEchidnaTest.sol --contract LiquidityHubLCCBackingEchidnaTest" 1>&2
  exit 2
fi

# CryticCompile's Foundry platform expects a *project directory* target, not a single Solidity file.
# In foundry mode, we compile from the repo root and select the harness via --contract.
ECHIDNA_TARGET="$FILE"
if [ "$COMPILE_BACKEND" = "foundry" ]; then
  ECHIDNA_TARGET="."
fi

ECHIDNA_BIN=""
if command -v echidna-test >/dev/null 2>&1; then
  ECHIDNA_BIN="echidna-test"
elif command -v echidna >/dev/null 2>&1; then
  ECHIDNA_BIN="echidna"
fi

if [ "${FORCE_DOCKER:-}" != "" ]; then
  ECHIDNA_BIN=""
fi

if [ -n "$ECHIDNA_BIN" ]; then
  # shellcheck disable=SC2086
  "$ECHIDNA_BIN" "$ECHIDNA_TARGET" --contract "$CONTRACT" --config "$CONFIG" $EXTRA_ARGS
  exit 0
fi

if command -v docker >/dev/null 2>&1; then
  IMAGE="${ECHIDNA_IMAGE:-trailofbits/eth-security-toolbox}"

  PLATFORM_ARG=""
  if [ "${DOCKER_PLATFORM:-}" != "" ]; then
    PLATFORM_ARG="--platform ${DOCKER_PLATFORM}"
  fi

  OUT_DIR="${FOUNDRY_OUT_DIR:-out}"

  if [ "$COMPILE_BACKEND" = "foundry" ]; then
    # IMPORTANT: crytic-compile needs --foundry-out-directory to find build-info/artifacts if we use a non-default out dir.
    CRYTIC_ARGS="${ECHIDNA_CRYTIC_ARGS:---compile-force-framework foundry --foundry-compile-all --foundry-out-directory $OUT_DIR}"
  else
    # Note: the toolbox image uses solc-select shims and may not have a solc version installed.
    # In restricted environments this can fail; prefer ECHIDNA_COMPILE=foundry.
    CRYTIC_ARGS="${ECHIDNA_CRYTIC_ARGS:---compile-force-framework solc --solc /root/.crytic/bin/solc --solc-remaps @openzeppelin/=lib/openzeppelin-contracts/ --solc-remaps openzeppelin-contracts/=lib/openzeppelin-contracts/ --solc-remaps v4-periphery/=lib/v4-periphery/ --solc-remaps @uniswap/v4-core/=lib/v4-periphery/lib/v4-core/ --solc-remaps v4-core/=lib/v4-periphery/lib/v4-core/src/}"
  fi

  # shellcheck disable=SC2086
  docker run --rm -t $PLATFORM_ARG \
    -v "$(pwd)":/src \
    -w /src \
    ${FOUNDRY_PROFILE:+-e FOUNDRY_PROFILE=$FOUNDRY_PROFILE} \
    ${FOUNDRY_OUT_DIR:+-e FOUNDRY_OUT_DIR=$FOUNDRY_OUT_DIR} \
    "$IMAGE" \
    echidna "$ECHIDNA_TARGET" --contract "$CONTRACT" --config "$CONFIG" \
      --crytic-args "$CRYTIC_ARGS" \
      $EXTRA_ARGS
  exit 0
fi

echo "error: no local echidna binary (echidna/echidna-test) found, and docker not available" 1>&2
exit 1


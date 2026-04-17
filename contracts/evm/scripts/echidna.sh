#!/usr/bin/env sh
set -eu

# -----------------------------------------------------------------------------
# Purpose and high-level behavior
# -----------------------------------------------------------------------------
# Generic Echidna runner for this repo.
#
# Native-first: if `echidna`/`echidna-test` is installed locally, we use it.
# Docker fallback is optional; set FORCE_DOCKER=1 to force Docker.
#
# Usage:
#   just echidna file=test/fuzz/MyHarness.sol contract=MyHarness

# Run from repo root or from contracts/evm/; normalize to contracts/evm.
if [ -d "contracts/evm" ]; then
  cd "contracts/evm"
fi

# -----------------------------------------------------------------------------
# Default CLI/config values
# -----------------------------------------------------------------------------
FILE=""
CONTRACT=""
CONFIG="echidna.config.yml"

COMPILE_BACKEND="${ECHIDNA_COMPILE:-solc}" # solc | foundry

# -----------------------------------------------------------------------------
# Parse script arguments
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Preserve extra Echidna args for passthrough
# -----------------------------------------------------------------------------
EXTRA_ARGS="$*"

# -----------------------------------------------------------------------------
# Validate required inputs
# -----------------------------------------------------------------------------
if [ -z "$FILE" ] || [ -z "$CONTRACT" ]; then
  echo "error: missing --file or --contract" 1>&2
  echo "example: just echidna file=test/fuzz/HUB01Fuzz.sol contract=HUB01Fuzz" 1>&2
  exit 2
fi

# -----------------------------------------------------------------------------
# Build crytic-compile arguments based on selected backend
# -----------------------------------------------------------------------------
# Compute default CryticCompile args so local and Docker runs behave the same.
OUT_DIR="${FOUNDRY_OUT_DIR:-out}"
if [ "$COMPILE_BACKEND" = "foundry" ]; then
  # Generate `.echidna-gen/foundry.toml` with a converged [profile.echidna].libraries map (via
  # GenerateEchidnaLinkedLibAddresses.printManifest in echidna_prepare_linked_libs.py), then compile+smoke.
  # Skip with ECHIDNA_SKIP_PREPARE=1 (you must set FOUNDRY_CONFIG yourself).
  if [ "${ECHIDNA_SKIP_PREPARE:-}" != "1" ]; then
    echo "[echidna] preparing linked libraries for Foundry backend (see [echidna-prepare] lines on stderr)..." 1>&2
    FOUNDRY_CONFIG_GEN="$(python3 scripts/echidna_prepare_linked_libs.py)" || exit 1
    export FOUNDRY_CONFIG="$FOUNDRY_CONFIG_GEN"
  fi
  # IMPORTANT: crytic-compile needs --foundry-out-directory to find build-info/artifacts if we use a non-default out dir.
  CRYTIC_ARGS="${ECHIDNA_CRYTIC_ARGS:---compile-force-framework foundry --foundry-compile-all --foundry-out-directory $OUT_DIR}"
else
  CRYTIC_ARGS="${ECHIDNA_CRYTIC_ARGS:---compile-force-framework solc --solc-remaps @openzeppelin/=lib/openzeppelin-contracts/ --solc-remaps openzeppelin-contracts/=lib/openzeppelin-contracts/ --solc-remaps v4-periphery/=lib/v4-periphery/ --solc-remaps @uniswap/v4-core/=lib/v4-periphery/lib/v4-core/ --solc-remaps v4-core/=lib/v4-periphery/lib/v4-core/src/}"
fi

# -----------------------------------------------------------------------------
# Select Echidna compilation target format
# -----------------------------------------------------------------------------
# CryticCompile's Foundry platform expects a *project directory* target, not a single Solidity file.
# In foundry mode, we compile from the repo root and select the harness via --contract.
ECHIDNA_TARGET="$FILE"
if [ "$COMPILE_BACKEND" = "foundry" ]; then
  ECHIDNA_TARGET="."
fi

# -----------------------------------------------------------------------------
# Discover local Echidna binary (unless Docker is forced)
# -----------------------------------------------------------------------------
ECHIDNA_BIN=""
if command -v echidna-test >/dev/null 2>&1; then
  ECHIDNA_BIN="echidna-test"
elif command -v echidna >/dev/null 2>&1; then
  ECHIDNA_BIN="echidna"
fi

if [ "${FORCE_DOCKER:-}" != "" ]; then
  ECHIDNA_BIN=""
fi

# -----------------------------------------------------------------------------
# Native execution path (preferred)
# -----------------------------------------------------------------------------
if [ -n "$ECHIDNA_BIN" ]; then
  # shellcheck disable=SC2086
  "$ECHIDNA_BIN" "$ECHIDNA_TARGET" --contract "$CONTRACT" --config "$CONFIG" \
    --crytic-args "$CRYTIC_ARGS" \
    $EXTRA_ARGS
  exit 0
fi

# -----------------------------------------------------------------------------
# Docker fallback path
# -----------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  IMAGE="${ECHIDNA_IMAGE:-trailofbits/eth-security-toolbox}"

  PLATFORM_ARG=""
  if [ "${DOCKER_PLATFORM:-}" != "" ]; then
    PLATFORM_ARG="--platform ${DOCKER_PLATFORM}"
  fi

  if [ "$COMPILE_BACKEND" != "foundry" ]; then
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
    ${FOUNDRY_CONFIG:+-e FOUNDRY_CONFIG=/src/.echidna-gen/foundry.toml} \
    "$IMAGE" \
    echidna "$ECHIDNA_TARGET" --contract "$CONTRACT" --config "$CONFIG" \
      --crytic-args "$CRYTIC_ARGS" \
      $EXTRA_ARGS
  exit 0
fi

# -----------------------------------------------------------------------------
# Hard failure when no execution backend is available
# -----------------------------------------------------------------------------
echo "error: no local echidna binary (echidna/echidna-test) found, and docker not available" 1>&2
exit 1

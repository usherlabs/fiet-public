#!/usr/bin/env bash
set -euo pipefail

# Build the Stylus policy WASM and post-process it for ArbOs Foundry's deployStylusCode cheatcode.
#
# ArbOs Foundry requires the WASM to have type references removed. The recommended approach is:
#   wasm2wat -> wat2wasm
#
# Usage (from protocol/contracts/stylus):
#   ./tools/arbos/build-wasm.sh
#
# Requirements:
# - Rust toolchain with wasm32-unknown-unknown target installed
# - WABT installed (wasm2wat, wat2wasm)
# - Brotli CLI installed (brotli) for producing a .wasm.br artefact (recommended for arbos-forge)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POLICY_DIR="${ROOT_DIR}/fiet-maker-policy"
OUT_WASM_DIR="${ROOT_DIR}/wasm"

# NOTE: `contracts/stylus/` is a Cargo workspace, so artefacts are written to the workspace
# target directory (ROOT_DIR/target), not the member crate's directory.
WASM_IN="${ROOT_DIR}/target/wasm32-unknown-unknown/release/fiet_maker_policy.wasm"

# Raw artefact copied directly from Cargo output (useful for A/B debugging).
WASM_OUT_RAW="${OUT_WASM_DIR}/intent-policy.raw.wasm"

# Stripped artefact (type refs removed via wasm2wat -> wat2wasm).
WASM_OUT="${OUT_WASM_DIR}/intent-policy.wasm"

# Brotli-compressed artefact (empty dictionary) for deployment via arbos-forge.
WASM_BR_OUT="${OUT_WASM_DIR}/intent-policy.wasm.br"

WAT_TMP="${OUT_WASM_DIR}/intent-policy.wat"

mkdir -p "${OUT_WASM_DIR}"

if ! command -v wasm2wat >/dev/null 2>&1 || ! command -v wat2wasm >/dev/null 2>&1; then
  cat >&2 <<'EOM'
Missing required tools: wasm2wat / wat2wasm (WABT).

ArbOs Foundry requires the deployed WASM to have type references removed; the recommended
approach is a wasm2wat -> wat2wasm round-trip.

Install WABT, then re-run:
  - macOS (Homebrew): brew install wabt
  - Linux: use your package manager (or install from https://github.com/WebAssembly/wabt)
EOM
  exit 1
fi

if ! command -v brotli >/dev/null 2>&1; then
  cat >&2 <<'EOM'
Missing required tool: brotli (CLI).

We generate a pre-compressed `.wasm.br` artefact to ensure arbos-forge deploys and executes
large programs reliably (and to avoid any size-based auto-compression surprises).

Install brotli, then re-run:
  - macOS (Homebrew): brew install brotli
  - Linux: use your package manager
EOM
  exit 1
fi

echo "Building WASM (release) for fiet-maker-policy..."
(
  cd "${POLICY_DIR}"
  cargo build --release --target wasm32-unknown-unknown
)

if [ ! -f "${WASM_IN}" ]; then
  echo "Expected WASM not found at: ${WASM_IN}" >&2
  exit 1
fi

echo "Copying raw WASM -> ${WASM_OUT_RAW}"
cp "${WASM_IN}" "${WASM_OUT_RAW}"

echo "Copying WASM -> ${WASM_OUT}"
cp "${WASM_IN}" "${WASM_OUT}"

echo "Stripping type references via wasm2wat/wat2wasm..."
wasm2wat "${WASM_OUT}" > "${WAT_TMP}"
wat2wasm "${WAT_TMP}" -o "${WASM_OUT}"
rm -f "${WAT_TMP}"

if command -v wasm-opt >/dev/null 2>&1; then
  echo "Optimising WASM via wasm-opt (aggressive, strip debug/producers)..."
  # Inspired by renegade-stylus-contracts/scripts/src/utils.rs::build_stylus_contract (wasm-opt post-pass).
  # We prioritise size and remove custom debug sections, which can reduce incompatibilities.
  # ArbOs Foundry's embedded WASM parser/executor is stricter than general-purpose runtimes.
  # In particular, it currently rejects the DataCount section (bulk-memory), and rejects tail-calls.
  # We therefore lower to MVP-compatible features here.
  wasm-opt \
    --mvp-features \
    --disable-bulk-memory \
    --disable-bulk-memory-opt \
    --disable-tail-call \
    -Oz --strip-dwarf --strip-producers \
    -o "${WASM_OUT}" "${WASM_OUT}"
else
  echo "wasm-opt not found; skipping additional optimisation."
fi

echo "Compressing stripped WASM -> ${WASM_BR_OUT}"
# Use high quality/window; dictionary is empty (arbos-forge indicates compression byte 0).
brotli --quality=11 --lgwin=22 --force --output="${WASM_BR_OUT}" "${WASM_OUT}"

echo "Done. WASM ready for arbos-forge at: ${WASM_OUT}"
echo "Raw (unstripped) WASM at: ${WASM_OUT_RAW}"
echo "Brotli-compressed WASM at: ${WASM_BR_OUT}"

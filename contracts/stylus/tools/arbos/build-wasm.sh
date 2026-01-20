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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POLICY_DIR="${ROOT_DIR}/fiet-maker-policy"
OUT_WASM_DIR="${ROOT_DIR}/wasm"

# NOTE: `contracts/stylus/` is a Cargo workspace, so artefacts are written to the workspace
# target directory (ROOT_DIR/target), not the member crate's directory.
WASM_IN="${ROOT_DIR}/target/wasm32-unknown-unknown/release/fiet_maker_policy.wasm"
WASM_OUT="${OUT_WASM_DIR}/intent-policy.wasm"
WAT_TMP="${OUT_WASM_DIR}/intent-policy.wat"

mkdir -p "${OUT_WASM_DIR}"

if ! command -v wasm2wat >/dev/null 2>&1 || ! command -v wat2wasm >/dev/null 2>&1; then
  cat >&2 <<'EOF'
Missing required tools: wasm2wat / wat2wasm (WABT).

ArbOs Foundry requires the deployed WASM to have type references removed; the recommended
approach is a wasm2wat -> wat2wasm round-trip.

Install WABT, then re-run:
  - macOS (Homebrew): brew install wabt
  - Linux: use your package manager (or install from https://github.com/WebAssembly/wabt)
EOF
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

echo "Copying WASM -> ${WASM_OUT}"
cp "${WASM_IN}" "${WASM_OUT}"

echo "Stripping type references via wasm2wat/wat2wasm..."
wasm2wat "${WASM_OUT}" > "${WAT_TMP}"
wat2wasm "${WAT_TMP}" -o "${WASM_OUT}"
rm -f "${WAT_TMP}"

echo "Done. WASM ready for arbos-forge at: ${WASM_OUT}"

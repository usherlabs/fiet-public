#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-artifacts.sh

Builds the fiet-protocol artifacts tarball consumed by downstream projects.
Produces:

  dist/fiet-protocol-v<VERSION>.tar.gz
  dist/fiet-protocol-v<VERSION>.tar.gz.sha256

Reads VERSION from the env var of the same name, falling back to the
top-level VERSION file.

Required tools: forge, jq, node, npm, tar, sha256sum.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
}

require_tool forge
require_tool jq
require_tool node
require_tool npm
require_tool sha256sum
require_tool tar

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVM_DIR="$REPO_ROOT/contracts/evm"
EVM_SCRIPTS_DIR="$REPO_ROOT/contracts/evm-scripts"
DIST_DIR="$REPO_ROOT/dist"

if [[ -z "${VERSION:-}" ]]; then
  if [[ -f "$REPO_ROOT/VERSION" ]]; then
    VERSION="$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")"
  else
    echo "VERSION env var unset and no VERSION file at $REPO_ROOT/VERSION" >&2
    exit 1
  fi
fi
TAG="v${VERSION}"
PACKAGE_NAME="fiet-protocol-${TAG}"

TMP_ROOT="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

STAGE_DIR="$TMP_ROOT/fiet-protocol"
ABI_DIR="$STAGE_DIR/abis"
BYTECODE_DIR="$STAGE_DIR/bytecode"
BUILD_ROOT="$TMP_ROOT/build"

mkdir -p "$ABI_DIR" "$BYTECODE_DIR" "$BUILD_ROOT" "$DIST_DIR"
echo "$VERSION" >"$STAGE_DIR/VERSION"

echo "==> Building protocol contracts (default profile)..."
(
  cd "$EVM_DIR"
  forge build -q -o "$BUILD_ROOT/protocol"
)

echo "==> Building ProxyHook with deploy profile..."
(
  cd "$EVM_SCRIPTS_DIR"
  FOUNDRY_PROFILE=deploy forge build -q
)

write_abi_from_json() {
  local output_path="$1"
  local source_path="$2"

  if [[ ! -f "$source_path" ]]; then
    echo "Missing artifact for $(basename "$output_path"): $source_path" >&2
    exit 1
  fi

  jq '.abi' "$source_path" >"$output_path"
}

fetch_npm_package() {
  local package_name="$1"
  local package_version="$2"
  local output_dir="$3"
  local pack_dir
  local tarball

  mkdir -p "$output_dir"
  pack_dir="$(mktemp -d "$TMP_ROOT/npm-pack.XXXXXX")"

  if ! tarball="$(npm pack "$package_name@$package_version" --silent --pack-destination "$pack_dir")"; then
    echo "Failed to download npm package $package_name@$package_version" >&2
    exit 1
  fi

  tar -xzf "$pack_dir/$tarball" -C "$output_dir"
  rm -rf "$pack_dir"
  printf '%s/package' "$output_dir"
}

echo "==> Extracting ABIs..."
write_abi_from_json \
  "$ABI_DIR/GlobalConfig.abi.json" \
  "$BUILD_ROOT/protocol/GlobalConfig.sol/GlobalConfig.json"
write_abi_from_json \
  "$ABI_DIR/LiquidityHub.abi.json" \
  "$BUILD_ROOT/protocol/LiquidityHub.sol/LiquidityHub.json"
write_abi_from_json \
  "$ABI_DIR/MarketFactory.abi.json" \
  "$BUILD_ROOT/protocol/MarketFactory.sol/MarketFactory.json"
write_abi_from_json \
  "$ABI_DIR/MarketVault.abi.json" \
  "$BUILD_ROOT/protocol/MarketVaultFacade.sol/MarketVaultFacade.json"
write_abi_from_json \
  "$ABI_DIR/OracleHelper.abi.json" \
  "$BUILD_ROOT/protocol/OracleHelper.sol/OracleHelper.json"
write_abi_from_json \
  "$ABI_DIR/PoolManager.abi.json" \
  "$BUILD_ROOT/protocol/PoolManager.sol/PoolManager.json"
write_abi_from_json \
  "$ABI_DIR/VRLSettlementObserver.abi.json" \
  "$BUILD_ROOT/protocol/VRLSettlementObserver.sol/VRLSettlementObserver.json"
write_abi_from_json \
  "$ABI_DIR/VRLSignalManager.abi.json" \
  "$BUILD_ROOT/protocol/VRLSignalManager.sol/VRLSignalManager.json"
write_abi_from_json \
  "$ABI_DIR/VTSOrchestrator.abi.json" \
  "$BUILD_ROOT/protocol/VTSOrchestrator.sol/VTSOrchestrator.json"
write_abi_from_json \
  "$ABI_DIR/LCC.abi.json" \
  "$BUILD_ROOT/protocol/LCC.sol/LiquidityCommitmentCertificate.json"

# lib/oracle is a source-only sibling submodule with no Hardhat artifacts.
# Fetch the published npm packages at the version lib/oracle pins so the ABI
# snapshots use the official artifacts — no yarn install required.
ORACLE_VERSION="$(node -p "require('$EVM_DIR/lib/oracle/package.json').version")"
ORACLE_PACKAGE_DIR="$(fetch_npm_package "@venusprotocol/oracle" "$ORACLE_VERSION" "$TMP_ROOT/npm/oracle")"

write_abi_from_json \
  "$ABI_DIR/ChainlinkOracle.abi.json" \
  "$ORACLE_PACKAGE_DIR/artifacts/contracts/oracles/ChainlinkOracle.sol/ChainlinkOracle.json"
write_abi_from_json \
  "$ABI_DIR/ResilientOracle.abi.json" \
  "$ORACLE_PACKAGE_DIR/artifacts/contracts/ResilientOracle.sol/ResilientOracle.json"

GOVERNANCE_RANGE="$(node -e '
const candidates = [
  require("'"$EVM_DIR"'/lib/oracle/package.json"),
  require("'"$ORACLE_PACKAGE_DIR"'/package.json"),
];
const fields = ["dependencies", "devDependencies", "peerDependencies"];
let found;
for (const pkg of candidates) {
  for (const field of fields) {
    if (pkg[field] && pkg[field]["@venusprotocol/governance-contracts"]) {
      found = pkg[field]["@venusprotocol/governance-contracts"];
      break;
    }
  }
  if (found) break;
}
if (!found) throw new Error("governance-contracts version not declared by lib/oracle or @venusprotocol/oracle");
process.stdout.write(found);
')"
GOVERNANCE_PACKAGE_DIR="$(fetch_npm_package "@venusprotocol/governance-contracts" "$GOVERNANCE_RANGE" "$TMP_ROOT/npm/governance")"

write_abi_from_json \
  "$ABI_DIR/AccessControlManager.abi.json" \
  "$GOVERNANCE_PACKAGE_DIR/artifacts/contracts/Governance/AccessControlManager.sol/AccessControlManager.json"

echo "==> Copying ProxyHook bytecode artifact..."
PROXY_HOOK_SRC="$EVM_SCRIPTS_DIR/out/ProxyHook.sol/ProxyHook.json"
if [[ ! -f "$PROXY_HOOK_SRC" ]]; then
  echo "Missing ProxyHook artifact at $PROXY_HOOK_SRC" >&2
  exit 1
fi
cp "$PROXY_HOOK_SRC" "$BYTECODE_DIR/ProxyHook.json"

echo "==> Packaging $PACKAGE_NAME.tar.gz..."
TARBALL="$DIST_DIR/$PACKAGE_NAME.tar.gz"
(
  cd "$TMP_ROOT"
  tar -czf "$TARBALL" fiet-protocol
)
(
  cd "$DIST_DIR"
  sha256sum "$PACKAGE_NAME.tar.gz" >"$PACKAGE_NAME.tar.gz.sha256"
)

echo "==> Done."
echo "    $TARBALL"
echo "    $TARBALL.sha256"

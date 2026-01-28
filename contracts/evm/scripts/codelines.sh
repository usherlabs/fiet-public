#!/usr/bin/env bash
set -euo pipefail

# Aggregated Solidity LoC for formal-audit-critical code.
# Notes:
# - Excludes interfaces and stubs (ABI/test scaffolding).
# - Excludes small vendor-derived “glue” by default (e.g. TickUtils).
# - Files not listed in FILES are intentionally omitted from the count.
# - Optional flags allow you to include those if you prefer.

usage() {
  cat <<'EOF'
Usage:
  ./codelines.sh [--include-types] [--include-glue]

Options:
  --include-types   Include src/types/*.sol in the LoC count (schema/struct-heavy).
  --include-glue    Include small vendor/glue helpers (e.g. TickUtils, HookFlags).

Output:
  Prints a single integer: total Solidity code lines (tokei -> jq).
EOF
}

INCLUDE_TYPES=0
INCLUDE_GLUE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-types) INCLUDE_TYPES=1; shift ;;
    --include-glue)  INCLUDE_GLUE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT/contracts/evm"

# Core contracts and libraries that implement the audit objectives (accounting, settlement, hooks, solvency).
FILES=(
  src/CoreHook.sol
  src/ProxyHook.sol
  src/VTSOrchestrator.sol

  src/LiquidityHub.sol
  src/LCC.sol

  src/MarketFactory.sol
  src/MarketVaultDeployer.sol
  src/DirectLPDeltaResolver.sol

  src/MMPositionManager.sol
  src/MMPositionActionsImpl.sol

  src/VRLSignalManager.sol
  src/VRLSettlementObserver.sol
  src/verifiers/ECDSASignatureSignalVerifier.sol

  src/OracleHelper.sol

  src/modules/MarketVault.sol
  src/modules/BoundRegistry.sol
  src/modules/DelegateCallGuard.sol
  src/modules/ImmutableMarketState.sol
  src/modules/ImmutableVTSState.sol
  src/modules/NativeWrapper.sol
  src/modules/PausableVTS.sol
  src/modules/PositionManagerBase.sol
  src/modules/PositionManagerEntrypoint.sol
  src/modules/PositionManagerImpl.sol
  src/modules/VTSCurrencyDelta.sol

  src/libraries/Bounds.sol
  src/libraries/Checkpoint.sol
  src/libraries/CurrencyTransfer.sol
  src/libraries/DynamicCurrencyDelta.sol
  src/libraries/LCCFactoryLib.sol
  src/libraries/LiquidityHubLib.sol
  src/libraries/LiquidityUtils.sol
  src/libraries/MMCalldataDecoder.sol
  src/libraries/MMActions.sol
  src/libraries/MMHelpers.sol
  src/libraries/MarketHandlerLib.sol
  src/libraries/MarketMaker.sol
  src/libraries/OracleUtils.sol
  src/libraries/ProxySwapFlag.sol
  src/libraries/SwapSimulator.sol
  src/libraries/TransientSlots.sol
  src/libraries/VTSCommitLib.sol
  src/libraries/VTSConfigs.sol
  src/libraries/VTSFeeLib.sol
  src/libraries/VTSPositionLib.sol
  src/libraries/VTSSwapLib.sol
)

if [[ "$INCLUDE_TYPES" -eq 1 ]]; then
  FILES+=(
    src/types/Checkpoint.sol
    src/types/Commit.sol
    src/types/Liquidity.sol
    src/types/Pool.sol
    src/types/Position.sol
    src/types/VTS.sol
  )
fi

if [[ "$INCLUDE_GLUE" -eq 1 ]]; then
  FILES+=(
    src/libraries/TickUtils.sol
    src/libraries/HookFlags.sol
  )
fi

tokei -t Solidity --output json "${FILES[@]}" | jq -r '.Solidity.code'


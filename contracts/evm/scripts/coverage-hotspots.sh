#!/usr/bin/env bash
# Fast branch-coverage feedback: runs only selected test files that target low-coverage modules
# (VTSPositionMMOpsLib, CurrencyTransfer, ProxyHook mutation harness, NativeWrapper forks).
# For full CI-equivalent numbers, use ./coverage.sh from contracts/evm/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVM_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${EVM_ROOT}"

# Single glob (forge does not allow repeating --match-path)
forge coverage \
    --report summary \
    --no-match-coverage "(test|mock|node_modules|script|Fast|TypedMemView)" \
    --no-match-test "Fork" \
    --no-match-contract "Fork" \
    --match-path 'test/{libraries/VTSPositionMMOpsLib.accessor,libraries/CurrencyTransfer,ProxyHook.mutationHardening,forks/NativeWrapper}.t.sol'

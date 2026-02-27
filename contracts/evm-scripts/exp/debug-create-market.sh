#!/usr/bin/env bash
set -euo pipefail

JSON_PATH="${1:-contracts/evm-scripts/broadcast/CreateMarket.s.sol/42161/run-latest.json}"
RPC="${2:-${ARB_MAINNET_RPC_URL:-}}"
RPC_FALLBACK="${3:-}"

if [[ -z "${RPC}" ]]; then
  echo "Usage: $0 <run-*.json path> <rpc-url> [fallback-rpc-url]" >&2
  exit 1
fi

FROM="$(jq -r '.transactions[0].transaction.from' "$JSON_PATH")"
TO="$(jq -r '.transactions[0].transaction.to' "$JSON_PATH")"
DATA="$(jq -r '.transactions[0].transaction.input' "$JSON_PATH")"

GLOBAL_CONFIG="$(jq -r '.transactions[0].contractAddress' "$JSON_PATH")"
MARKET_FACTORY="$(jq -r '.transactions[0].arguments[0]' "$JSON_PATH")"
INNER_CALLDATA="$(jq -r '.transactions[0].arguments[1]' "$JSON_PATH")"
PROXY_HOOK="$(jq -r '.transactions[0].additionalContracts // [] | .[] | select(.contractName=="ProxyHook") | .address' "$JSON_PATH")"

echo "JSON_PATH=$JSON_PATH"
echo "RPC=$RPC"
echo "FROM=$FROM"
echo "GLOBAL_CONFIG=$GLOBAL_CONFIG"
echo "MARKET_FACTORY=$MARKET_FACTORY"
echo "PROXY_HOOK=$PROXY_HOOK"
echo

echo "## 1) ProxyHook code (collision check)"
cast code "$PROXY_HOOK" --rpc-url "$RPC"
echo

echo "## 2) Can ProxyHook deploy be simulated?"
DEPLOYER="$(cast call "$MARKET_FACTORY" "marketVaultDeployer()(address)" --rpc-url "$RPC")"
POOL_MANAGER="$(cast call "$MARKET_FACTORY" "poolManager()(address)" --rpc-url "$RPC")"
# Pull salt from the inner calldata: it’s the bytes32 right after initialSqrtPriceX96 in your encoding.
# Easiest/robust: just read it from the script logs; or hardcode it per-run.
echo "DEPLOYER=$DEPLOYER"
echo "POOL_MANAGER=$POOL_MANAGER"
echo "(Skipping salt extraction; pass SALT env var to test deployProxyHook)"
if [[ -n "${SALT:-}" ]]; then
  cast call "$DEPLOYER" "deployProxyHook(address,bytes32)(address)" \
    "$POOL_MANAGER" "$SALT" --from "$MARKET_FACTORY" --rpc-url "$RPC"
else
  echo "Set SALT=0x... to run deployProxyHook preflight."
fi
echo

echo "## 3) Inner createMarket eth_call (bypass proxyCall masking)"
cast call "$MARKET_FACTORY" "$INNER_CALLDATA" --from "$GLOBAL_CONFIG" --rpc-url "$RPC"
echo

echo "## 4) eth_estimateGas for proxyCall tx (what forge relies on)"
cast rpc --rpc-url "$RPC" eth_estimateGas \
  "{\"from\":\"$FROM\",\"to\":\"$TO\",\"data\":\"$DATA\"}" \
  "\"pending\""
echo

if [[ -n "$RPC_FALLBACK" ]]; then
  echo "## 5) Compare estimateGas on fallback RPC"
  cast rpc --rpc-url "$RPC_FALLBACK" eth_estimateGas \
    "{\"from\":\"$FROM\",\"to\":\"$TO\",\"data\":\"$DATA\"}" \
    "\"pending\""
  echo
fi

echo "Done."

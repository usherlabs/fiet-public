#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=live-demo-lib.sh
source "$SCRIPT_DIR/live-demo-lib.sh"

PROTOCOL_CHAIN_ID="${PROTOCOL_CHAIN_ID:-42161}"
ARBISCAN_BASE="${ARBISCAN_BASE:-https://arbiscan.io/tx}"
REACTSCAN_BASE="${REACTSCAN_BASE:-https://reactscan.net/tx}"

# Defaults for the 7 June 2026 cohesive run (commit 3, position 1).
TX_CREATE="${TX_CREATE:-0x397f6e69b91a82678edbed385617930d299bb3c98238420eda01d6a24254b32b}"
TX_SWAP="${TX_SWAP:-0x1967ba9e38183ed9c6e553b069063097393d435085a195c8f71c4e33c7c0d41e}"
TX_SETTLE_A="${TX_SETTLE_A:-0xb5edbb2281570fb323400b0e2dde0658a4f89f7269200b1d4cd2a63bd0dc0e2c}"
TX_SETTLE_B="${TX_SETTLE_B:-0x39fa18d9c6aea9966d1a04e9124575d4eddf1501fea9630e192e46edd70bdccd}"
TX_CALLBACK="${TX_CALLBACK:-0x703289d26d55b9b8db75c08d82974dfe22715b0978cf34ece562089b213a5187}"
TX_CLOSE="${TX_CLOSE:-0xf6260d42c30cfa39b0065eef6024528d5d52e285f98369bbdb1f4560db14023b}"
TX_REACT_MIRROR_1="${TX_REACT_MIRROR_1:-0x2c6c4d510e4a1f5dc46d08d493def6eb1a755ab39718ee5943185cb8405d07fa}"
TX_REACT_MIRROR_2="${TX_REACT_MIRROR_2:-0x0e04a6f0b70dbdb49cc17705feb854622746939080873ed277eff5f8f97013b6}"
TX_REACT_DISPATCH="${TX_REACT_DISPATCH:-0xbe08704709faa0ec689adc8c6766d8560aa1ea7c7fc25950ec00de6d8a9e4712}"
TX_REACT_DISPATCH_2="${TX_REACT_DISPATCH_2:-0xac3ddbc7c04b8edd402a9c7bd6af5bf095455ff6b34bf4d9c4e2c9a99193ddbf}"
TX_REACT_DISPATCH_3="${TX_REACT_DISPATCH_3:-0x720f610517d82d603771a5a4f8e2258ccd1715db7365bd54e3677bd39908fce5}"

link_arb() {
  local hash="$1"
  printf '%s/%s' "$ARBISCAN_BASE" "$hash"
}

link_react() {
  local hash="$1"
  printf '%s/%s' "$REACTSCAN_BASE" "$hash"
}

print_row() {
  local step="$1"
  local kind="$2"
  local explorer="$3"
  local hash="$4"
  local notes="$5"
  local url
  if [ "$explorer" = "Arbiscan" ]; then
    url="$(link_arb "$hash")"
  else
    url="$(link_react "$hash")"
  fi
  printf '| %s | %s | %s | [%s](%s) | %s |\n' "$step" "$kind" "$explorer" "$hash" "$url" "$notes"
}

maybe_fill_from_broadcast() {
  local var_name="$1"
  local script_rel="$2"
  local current="${!var_name}"
  if [ -n "$current" ]; then
    return 0
  fi
  local hash
  hash="$(last_broadcast_hash "$script_rel")"
  if [ -n "$hash" ]; then
    printf -v "$var_name" '%s' "$hash"
  fi
}

maybe_fill_from_broadcast TX_CREATE "CreateMMPosition.s.sol"
maybe_fill_from_broadcast TX_SWAP "SwapV4.s.sol"
maybe_fill_from_broadcast TX_CLOSE "CloseMMPosition.s.sol"

receipt_block() {
  local rpc="$1"
  local hash="$2"
  cast receipt "$hash" --rpc-url "$rpc" blockNumber 2>/dev/null || true
}

verify_hash() {
  local rpc="$1"
  local hash="$2"
  local label="$3"
  if [ -z "$hash" ]; then
    echo "  $label: <unset>"
    return 0
  fi
  local block
  block="$(receipt_block "$rpc" "$hash")"
  if [ -n "$block" ]; then
    echo "  $label: $hash (block $(to_dec "$block"))"
  else
    echo "  $label: $hash (receipt not found on configured RPC)"
  fi
}

echo "Live demo transaction collector"
echo "  protocol chain: ${PROTOCOL_CHAIN_ID}"
echo "  broadcast dir:  $EVM_SCRIPTS_DIR/broadcast/<Script>.s.sol/${PROTOCOL_CHAIN_ID}/run-latest.json"
echo ""
echo "Resolved hashes:"
if [ -n "${PROTOCOL_RPC:-}" ]; then
  verify_hash "$PROTOCOL_RPC" "$TX_CREATE" "TX_CREATE"
  verify_hash "$PROTOCOL_RPC" "$TX_SWAP" "TX_SWAP"
  verify_hash "$PROTOCOL_RPC" "$TX_SETTLE_A" "TX_SETTLE_A"
  verify_hash "$PROTOCOL_RPC" "$TX_SETTLE_B" "TX_SETTLE_B"
  verify_hash "$PROTOCOL_RPC" "$TX_CALLBACK" "TX_CALLBACK"
  verify_hash "$PROTOCOL_RPC" "$TX_CLOSE" "TX_CLOSE"
else
  echo "  PROTOCOL_RPC unset — printing configured hashes without receipt checks"
  echo "  TX_CREATE=$TX_CREATE"
  echo "  TX_SWAP=$TX_SWAP"
  echo "  TX_SETTLE_A=$TX_SETTLE_A"
  echo "  TX_SETTLE_B=$TX_SETTLE_B"
  echo "  TX_CALLBACK=$TX_CALLBACK"
  echo "  TX_CLOSE=$TX_CLOSE"
fi
if [ -n "${REACTIVE_RPC:-}" ]; then
  verify_hash "$REACTIVE_RPC" "$TX_REACT_MIRROR_1" "TX_REACT_MIRROR_1"
  verify_hash "$REACTIVE_RPC" "$TX_REACT_MIRROR_2" "TX_REACT_MIRROR_2"
  verify_hash "$REACTIVE_RPC" "$TX_REACT_DISPATCH" "TX_REACT_DISPATCH"
  verify_hash "$REACTIVE_RPC" "$TX_REACT_DISPATCH_2" "TX_REACT_DISPATCH_2"
  verify_hash "$REACTIVE_RPC" "$TX_REACT_DISPATCH_3" "TX_REACT_DISPATCH_3"
else
  echo "  REACTIVE_RPC unset — reactive hashes not receipt-checked"
  echo "  TX_REACT_MIRROR_1=$TX_REACT_MIRROR_1"
  echo "  TX_REACT_MIRROR_2=$TX_REACT_MIRROR_2"
  echo "  TX_REACT_DISPATCH=$TX_REACT_DISPATCH"
fi

echo ""
echo "Markdown rows (paste into LIVE_DEMO_RUN-07062026.md):"
echo ""
echo "| Step | Kind | Explorer | Link | Notes |"
echo "|------|------|----------|------|-------|"
print_row "1" "Origin" "Arbiscan" "$TX_CREATE" "CreateMMPosition"
print_row "2" "Origin" "Arbiscan" "$TX_SWAP" "SwapV4"
print_row "3" "Origin" "Arbiscan" "$TX_SWAP" "SettlementQueued in swap tx"
print_row "4" "Reactive" "Reactscan" "$TX_REACT_MIRROR_1" "RVM react on HubRSC"
print_row "4" "Reactive" "Reactscan" "$TX_REACT_MIRROR_2" "Follow-on react"
print_row "5" "Origin" "Arbiscan" "$TX_SETTLE_A" "SettleMMPosition attempt 1 (Run A)"
print_row "5" "Origin" "Arbiscan" "$TX_SETTLE_B" "SettleMMPosition attempt 2 (Run B)"
print_row "6" "Reactive" "Reactscan" "$TX_REACT_DISPATCH" "Destination dispatch"
print_row "6" "Reactive" "Reactscan" "$TX_REACT_DISPATCH_2" "Dispatch follow-on"
print_row "6" "Reactive" "Reactscan" "$TX_REACT_DISPATCH_3" "Dispatch follow-on"
print_row "6" "Callback" "Arbiscan" "$TX_CALLBACK" "BatchProcessSettlement.processSettlements"
print_row "7" "Origin" "Arbiscan" "$TX_CLOSE" "CloseMMPosition"
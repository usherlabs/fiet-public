#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=live-demo-lib.sh
source "$SCRIPT_DIR/live-demo-lib.sh"

main() {
  echo "Running live Reactive settlement demo preflight..."
  preflight

  create_out="$(run_checked "Create live MM position" run_create_position)"
  COMMIT_ID="$(extract_label "CommitId" "$create_out")"
  POSITION_INDEX="$(extract_label "PositionIndex" "$create_out")"
  COMMIT_MODE="$(extract_label "CommitMode" "$create_out")"
  COMMIT_EXPIRES_AT="$(extract_label "CommitExpiresAt" "$create_out")"
  CREATED_TICK_LOWER="$(extract_label "TickLower" "$create_out")"
  CREATED_TICK_UPPER="$(extract_label "TickUpper" "$create_out")"
  POSITION_LIQUIDITY="$(extract_label "Liquidity" "$create_out")"
  AMOUNT0_MAX="$(extract_label "Amount0Max" "$create_out")"
  AMOUNT1_MAX="$(extract_label "Amount1Max" "$create_out")"
  POSITION_USD_WAD_ACTUAL="$(extract_label "PositionUsdWad" "$create_out")"
  TARGET_POSITION_USD_WAD="$(extract_label "TargetPositionUsdWad" "$create_out")"
  BASE_SETTLE0="$(extract_label "BaseSettle0" "$create_out")"
  BASE_SETTLE1="$(extract_label "BaseSettle1" "$create_out")"
  LCC0="$(extract_label "LCC0" "$create_out")"
  LCC1="$(extract_label "LCC1" "$create_out")"
  CREATE_TX="$(extract_tx_hash_with_fallback "$create_out" "CreateMMPosition.s.sol")"
  [ -n "$COMMIT_ID" ] || fail "Could not parse CommitId from CreateMMPosition output"
  [ -n "$POSITION_INDEX" ] || fail "Could not parse PositionIndex from CreateMMPosition output"
  [ -n "$COMMIT_MODE" ] || fail "Could not parse CommitMode from CreateMMPosition output"
  [ -n "$COMMIT_EXPIRES_AT" ] || fail "Could not parse CommitExpiresAt from CreateMMPosition output"
  [ -n "$CREATED_TICK_LOWER" ] || fail "Could not parse TickLower from CreateMMPosition output"
  [ -n "$CREATED_TICK_UPPER" ] || fail "Could not parse TickUpper from CreateMMPosition output"
  [ -n "$POSITION_LIQUIDITY" ] || fail "Could not parse Liquidity from CreateMMPosition output"
  [ -n "$AMOUNT0_MAX" ] || fail "Could not parse Amount0Max from CreateMMPosition output"
  [ -n "$AMOUNT1_MAX" ] || fail "Could not parse Amount1Max from CreateMMPosition output"
  [ -n "$POSITION_USD_WAD_ACTUAL" ] || fail "Could not parse PositionUsdWad from CreateMMPosition output"
  [ -n "$BASE_SETTLE0" ] || fail "Could not parse BaseSettle0 from CreateMMPosition output"
  [ -n "$BASE_SETTLE1" ] || fail "Could not parse BaseSettle1 from CreateMMPosition output"
  [ -n "$LCC0" ] || fail "Could not parse LCC0 from CreateMMPosition output"
  [ -n "$LCC1" ] || fail "Could not parse LCC1 from CreateMMPosition output"
  export COMMIT_ID POSITION_INDEX
  if [ "$BROADCAST" = "true" ]; then
    WF_CREATE="PASS"
  else
    WF_CREATE="DRY-RUN"
  fi

  if [ "$BROADCAST" != "true" ]; then
    swap_out="$(run_checked "Dry-run recipient-signed exact-input swap" run_swap)"
    LCC_OUT="$(extract_label "LccOut" "$swap_out")"
    SWAP_TX="$(extract_tx_hash_with_fallback "$swap_out" "SwapV4.s.sol")"
    QUEUED_BEFORE="0"
    QUEUED_AFTER_SWAP="0"
    QUEUED_FINAL="0"
    CLOSE_STATUS="not-run"
    WF_SWAP="DRY-RUN"
    WF_QUEUE_INCREASE="SKIP"
    WF_HUB_MIRROR="SKIP"
    WF_SETTLE="SKIP"
    WF_QUEUE_DECREASE="SKIP"
    WF_CLOSE="SKIP"
    print_summary "PASS (dry-run only; no live transactions broadcast)"
    return 0
  fi

  local q0_before q1_before
  q0_before="$(read_queue "$LCC0" "$RECIPIENT")"
  q1_before="$(read_queue "$LCC1" "$RECIPIENT")"

  swap_out="$(run_checked "Broadcast recipient-signed exact-input swap" run_swap)"
  LCC_OUT="$(extract_label "LccOut" "$swap_out")"
  SWAP_TX="$(extract_tx_hash_with_fallback "$swap_out" "SwapV4.s.sol")"
  WF_SWAP="PASS"
  [ -n "$LCC_OUT" ] || fail "Could not parse LccOut from SwapV4 output"

  if same_address "$LCC_OUT" "$LCC0"; then
    QUEUED_BEFORE="$q0_before"
  elif same_address "$LCC_OUT" "$LCC1"; then
    QUEUED_BEFORE="$q1_before"
  else
    warn "LccOut did not match CreateMMPosition LCC0/LCC1; using current queue as baseline fallback."
    QUEUED_BEFORE="$(read_queue "$LCC_OUT" "$RECIPIENT")"
  fi

  if ! wait_until "protocol settleQueue increase for LccOut/recipient" queue_increased; then
    QUEUED_AFTER_SWAP="$(read_queue "$LCC_OUT" "$RECIPIENT")"
    QUEUED_FINAL="$QUEUED_AFTER_SWAP"
    WF_QUEUE_INCREASE="FAIL"
    print_summary "FAIL"
    fail "No queued settlement was observed. Try a larger AMOUNT/EAMOUNT, verify the recipient signed the swap, and verify the swap creates an output deficit."
  fi
  QUEUED_AFTER_SWAP="$(read_queue "$LCC_OUT" "$RECIPIENT")"
  WF_QUEUE_INCREASE="PASS"

  if ! wait_until "HubRSC mirrored pending or in-flight work" hub_work_observed; then
    QUEUED_FINAL="$QUEUED_AFTER_SWAP"
    WF_HUB_MIRROR="FAIL"
    print_summary "FAIL"
    fail "HubRSC did not mirror queued work. Check recipient registration/funding, callback proxy delivery, and Reactive funding."
  fi
  WF_HUB_MIRROR="PASS"

  run_settle_until_rfs_closed
  WF_SETTLE="PASS"

  if ! wait_until "protocol settleQueue decrease after maker settlement" queue_decreased; then
    QUEUED_FINAL="$(read_queue "$LCC_OUT" "$RECIPIENT")"
    WF_QUEUE_DECREASE="FAIL"
    print_summary "FAIL"
    fail "Settlement queue did not decrease. Check BatchProcessSettlement events and HubRSC retry/terminal state."
  fi

  QUEUED_FINAL="$(read_queue "$LCC_OUT" "$RECIPIENT")"
  WF_QUEUE_DECREASE="PASS"
  run_close_if_enabled
  print_summary "PASS"
}

main "$@"
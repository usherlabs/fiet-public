#!/usr/bin/env bash
# Shared helpers for reactive e2e deploy and integration scripts.
# shellcheck shell=bash

extract_labeled_address() {
  local label="$1"
  local text="$2"
  printf '%s\n' "$text" | sed -n "s/.*${label}:[[:space:]]*\(0x[a-fA-F0-9]\{40\}\).*/\1/p" | tail -n1
}

extract_transaction_hash() {
  local text="$1"
  printf '%s\n' "$text" | sed -n 's/.*transactionHash[[:space:]]*\(0x[a-fA-F0-9]\{64\}\).*/\1/p' | tail -n1
}

run_and_print() {
  local title="$1"
  shift
  echo "========================================" >&2
  echo "$title" >&2
  local out
  if [ "${DEPLOY_DEBUG:-false}" = "true" ]; then
    out="$("$@" 2>&1 | tee /dev/stderr)"
  else
    out="$("$@" 2>&1)"
  fi
  printf '%s' "$out"
}

cast_send_with_nonce_retry() {
  local out status next_nonce attempt=1
  local -a nonce_arg=()

  while [ "$attempt" -le 3 ]; do
    set +e
    out="$(cast send "$@" "${nonce_arg[@]}" 2>&1)"
    status=$?
    set -e

    if [ "$status" -eq 0 ]; then
      printf '%s' "$out"
      return 0
    fi

    next_nonce="$(
      printf '%s\n' "$out" \
        | sed -n 's/.*nonce too low: next nonce \([0-9][0-9]*\), tx nonce [0-9][0-9]*.*/\1/p' \
        | tail -n1
    )"
    if [ -z "$next_nonce" ]; then
      printf '%s\n' "$out" >&2
      return "$status"
    fi

    echo "cast send hit stale nonce; retrying with node-reported nonce $next_nonce" >&2
    nonce_arg=(--nonce "$next_nonce")
    attempt=$((attempt + 1))
    sleep 2
  done

  printf '%s\n' "$out" >&2
  return "$status"
}

to_dec() {
  local value
  value="$(printf '%s\n' "${1:-}" | sed -n '1p' | tr -d '[:space:]')"
  if [ -z "$value" ]; then
    printf '0'
    return
  fi
  if [[ "$value" == 0x* ]]; then
    cast to-dec "$value" 2>/dev/null || printf '0'
    return
  fi
  printf '%s' "$value"
}

uint_or_zero() {
  local value
  value="$(to_dec "${1:-}")"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
    return
  fi
  printf '0'
}

wait_until() {
  local description="$1"
  local timeout_seconds="${POLL_TIMEOUT_SECONDS:-180}"
  local interval_seconds="${POLL_INTERVAL_SECONDS:-5}"
  shift

  local deadline=$(( $(date +%s) + timeout_seconds ))
  echo "Waiting for ${description}..."
  while true; do
    if "$@"; then
      echo "Observed ${description}"
      return 0
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "Timed out waiting for ${description} after ${timeout_seconds}s" >&2
      return 1
    fi

    sleep "$interval_seconds"
  done
}

contract_code_exists() {
  local contract_addr="$1"
  local rpc_url="$2"
  local code
  code="$(cast code "$contract_addr" --rpc-url "$rpc_url" 2>/dev/null || true)"
  [ -n "$code" ] && [ "$code" != "0x" ]
}

recipient_is_active() {
  local hub_addr="$1"
  local recipient_addr="$2"
  local active
  active="$(cast call "$hub_addr" \
    "recipientActive(address)(bool)" \
    "$recipient_addr" \
    --rpc-url "$REACTIVE_RPC" 2>/dev/null || true)"
  [ "$active" = "true" ]
}

pending_at_least() {
  local hub_addr="$1"
  local lcc_addr="$2"
  local recipient_addr="$3"
  local expected_amount="$4"
  local key state amount exists

  key="$(cast call "$hub_addr" \
    "computeKey(address,address)(bytes32)" \
    "$lcc_addr" \
    "$recipient_addr" \
    --rpc-url "$REACTIVE_RPC" 2>/dev/null || true)"
  if [ -z "$key" ]; then
    return 1
  fi

  state="$(cast call "$hub_addr" \
    "pendingStateByKey(bytes32)(uint256,bool)" \
    "$key" \
    --rpc-url "$REACTIVE_RPC" 2>/dev/null || true)"
  amount="$(uint_or_zero "$(printf '%s\n' "$state" | sed -n '1p')")"
  exists="$(printf '%s\n' "$state" | sed -n '2p' | tr -d '[:space:]')"

  [ "$exists" = "true" ] && [ "$amount" -ge "$expected_amount" ]
}

settled_at_least() {
  local liquidity_hub_addr="$1"
  local lcc_addr="$2"
  local recipient_addr="$3"
  local expected_amount="$4"
  local total_settled
  total_settled="$(cast call "$liquidity_hub_addr" \
    "getTotalAmountSettled(address,address)(uint256)" \
    "$lcc_addr" \
    "$recipient_addr" \
    --rpc-url "$PROTOCOL_RPC" 2>/dev/null || true)"
  total_settled="$(uint_or_zero "$total_settled")"

  [ "$total_settled" -ge "$expected_amount" ]
}

print_dispatch_state_diagnostics() {
  local hub_addr="$1"
  local liquidity_hub_addr="$2"
  local lcc_addr="$3"
  local recipient_addr="$4"
  local expected_amount="$5"

  local key pending_state pending_amount pending_exists inflight budget wake_epoch total_settled
  key="$(cast call "$hub_addr" \
    "computeKey(address,address)(bytes32)" \
    "$lcc_addr" \
    "$recipient_addr" \
    --rpc-url "$REACTIVE_RPC" 2>/dev/null || true)"
  pending_state="$(cast call "$hub_addr" \
    "pendingStateByKey(bytes32)(uint256,bool)" \
    "$key" \
    --rpc-url "$REACTIVE_RPC" 2>/dev/null || true)"
  pending_amount="$(uint_or_zero "$(printf '%s\n' "$pending_state" | sed -n '1p')")"
  pending_exists="$(printf '%s\n' "$pending_state" | sed -n '2p' | tr -d '[:space:]')"
  inflight="$(cast call "$hub_addr" \
    "inFlightByKey(bytes32)(uint256)" \
    "$key" \
    --rpc-url "$REACTIVE_RPC" 2>/dev/null || true)"
  inflight="$(uint_or_zero "$inflight")"
  budget="$(cast call "$hub_addr" \
    "availableBudgetByDispatchLane(address)(uint256)" \
    "$lcc_addr" \
    --rpc-url "$REACTIVE_RPC" 2>/dev/null || true)"
  budget="$(uint_or_zero "$budget")"
  wake_epoch="$(cast call "$hub_addr" \
    "protocolLiquidityWakeEpochByLane(address)(uint256)" \
    "$lcc_addr" \
    --rpc-url "$REACTIVE_RPC" 2>/dev/null || true)"
  wake_epoch="$(uint_or_zero "$wake_epoch")"
  total_settled="$(cast call "$liquidity_hub_addr" \
    "getTotalAmountSettled(address,address)(uint256)" \
    "$lcc_addr" \
    "$recipient_addr" \
    --rpc-url "$PROTOCOL_RPC" 2>/dev/null || true)"
  total_settled="$(uint_or_zero "$total_settled")"

  echo "---- reactive dispatch state diagnostics ----" >&2
  echo "HubRSC: $hub_addr" >&2
  echo "LCC: $lcc_addr" >&2
  echo "Recipient: $recipient_addr" >&2
  echo "Expected settlement: $expected_amount" >&2
  echo "Pending key: ${key:-unknown}" >&2
  echo "Pending state: amount=$pending_amount exists=${pending_exists:-unknown}" >&2
  echo "In-flight amount: $inflight" >&2
  echo "Available budget for LCC lane: $budget" >&2
  echo "Protocol liquidity wake epoch for LCC lane: $wake_epoch" >&2
  echo "Protocol total settled: $total_settled" >&2
  echo "---- end reactive dispatch state diagnostics ----" >&2
}

print_callback_bridge_diagnostics() {
  local from_block="$1"
  local hub_addr="$2"
  shift 2

  local callback_failure_topic="0xc8313f695443128e273f1edfcec40b94b7deea8dfbeafd0043290d6601d999db"
  local callback_proxy="0x0000000000000000000000000000000000fffFfF"
  local callback_selector
  callback_selector="$(cast sig "applyCanonicalProtocolLog(address,(uint256,address,uint256,uint256,uint256,uint256,bytes,uint256,uint256,uint256,uint256,uint256))" 2>/dev/null || true)"

  echo "---- reactive callback bridge diagnostics ----" >&2
  echo "HubRSC target: $hub_addr" >&2
  echo "Expected canonical callback selector: ${callback_selector:-unknown}" >&2
  echo "Reactive callback proxy: $callback_proxy" >&2
  echo "Reactive CallbackFailure topic: $callback_failure_topic" >&2
  echo "Reactive diagnostic block range: ${from_block:-latest}..latest" >&2

  local tx_hash
  for tx_hash in "$@"; do
    if [ -n "$tx_hash" ]; then
      echo "Protocol trigger tx: $tx_hash" >&2
      cast receipt "$tx_hash" --rpc-url "$PROTOCOL_RPC" 2>/dev/null | sed -n '1,80p' >&2 || true
    fi
  done

  if [ -n "${from_block:-}" ]; then
    echo "Recent Reactive CallbackFailure logs:" >&2
    cast logs \
      --from-block "$from_block" \
      --to-block latest \
      --address "$callback_proxy" \
      "$callback_failure_topic" \
      --rpc-url "$REACTIVE_RPC" 2>/dev/null | sed -n '1,120p' >&2 || true
  fi
  echo "---- end reactive callback bridge diagnostics ----" >&2
}

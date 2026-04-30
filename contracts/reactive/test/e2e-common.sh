#!/usr/bin/env bash
# Shared helpers for reactive e2e deploy and integration scripts.
# shellcheck shell=bash

extract_labeled_address() {
  local label="$1"
  local text="$2"
  printf '%s\n' "$text" | sed -n "s/.*${label}:[[:space:]]*\(0x[a-fA-F0-9]\{40\}\).*/\1/p" | tail -n1
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

to_dec() {
  local value
  value="$(printf '%s\n' "${1:-}" | sed -n '1p' | tr -d '[:space:]')"
  if [ -z "$value" ]; then
    printf '0'
    return
  fi
  if [[ "$value" == 0x* ]]; then
    cast to-dec "$value"
    return
  fi
  printf '%s' "$value"
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
  amount="$(to_dec "$(printf '%s\n' "$state" | sed -n '1p')")"
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
  total_settled="$(to_dec "$total_settled")"

  [ "$total_settled" -ge "$expected_amount" ]
}

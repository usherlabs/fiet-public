#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REACTIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$REACTIVE_DIR/../.." && pwd)"
EVM_SCRIPTS_DIR="$REPO_ROOT/contracts/evm-scripts"

if [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

SYSTEM_CONTRACT_ADDR="0x0000000000000000000000000000000000fffFfF"
BROADCAST="${BROADCAST:-false}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-${POLL_TIMEOUT_SECONDS:-180}}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"
SWAP_TYPE="${SWAP_TYPE:-0}"
BATCH_RECEIVER="${BATCH_RECEIVER:-${BATCH_PROCESS_SETTLEMENT:-}}"
SWAP_PRIVATE_KEY_VALUE="${SWAP_PRIVATE_KEY:-${LP_PRIVATE_KEY:-${MM_PRIVATE_KEY:-}}}"
CLOSE_POSITION_AFTER_DEMO="${CLOSE_POSITION_AFTER_DEMO:-true}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    fail "Missing $name. Set it in the environment or local .env."
  fi
}

has_env_value() {
  local name="$1"
  [ -n "${!name:-}" ]
}

is_address() {
  [[ "${1:-}" =~ ^0x[a-fA-F0-9]{40}$ ]]
}

require_address() {
  local name="$1"
  local value="${!name:-}"
  is_address "$value" || fail "$name must be a 20-byte hex address; got '${value:-<empty>}'"
}

lower_address() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

same_address() {
  [ "$(lower_address "$1")" = "$(lower_address "$2")" ]
}

normalize_dec() {
  local v="${1:-0}"
  v="${v//[[:space:]]/}"
  v="${v//[^0-9]/}"
  while [[ "$v" == 0* && "${#v}" -gt 1 ]]; do
    v="${v#0}"
  done
  [ -n "$v" ] || v="0"
  printf '%s' "$v"
}

dec_cmp() {
  local a b
  a="$(normalize_dec "$1")"
  b="$(normalize_dec "$2")"
  if [ "${#a}" -gt "${#b}" ]; then printf '1'; return; fi
  if [ "${#a}" -lt "${#b}" ]; then printf -- '-1'; return; fi
  if [[ "$a" > "$b" ]]; then printf '1'; return; fi
  if [[ "$a" < "$b" ]]; then printf -- '-1'; return; fi
  printf '0'
}

dec_gt() {
  [ "$(dec_cmp "$1" "$2")" = "1" ]
}

dec_lt() {
  [ "$(dec_cmp "$1" "$2")" = "-1" ]
}

dec_sub_nonneg() {
  local a b result borrow i j da db diff
  a="$(normalize_dec "$1")"
  b="$(normalize_dec "$2")"
  if dec_lt "$a" "$b"; then
    printf '0'
    return
  fi
  result=""
  borrow=0
  i=${#a}
  j=${#b}
  while [ "$i" -gt 0 ] || [ "$j" -gt 0 ]; do
    da=0
    db=0
    if [ "$i" -gt 0 ]; then
      da="${a:i-1:1}"
      i=$((i - 1))
    fi
    if [ "$j" -gt 0 ]; then
      db="${b:j-1:1}"
      j=$((j - 1))
    fi
    diff=$((10#$da - borrow - 10#$db))
    if [ "$diff" -lt 0 ]; then
      diff=$((diff + 10))
      borrow=1
    else
      borrow=0
    fi
    result="${diff}${result}"
  done
  normalize_dec "$result"
}

to_dec() {
  local value
  value="$(printf '%s\n' "${1:-}" | sed -n '1p' | tr -d '[:space:]')"
  if [ -z "$value" ]; then
    printf '0'
  elif [[ "$value" == 0x* ]]; then
    cast to-dec "$value" 2>/dev/null || printf '0'
  else
    printf '%s' "$value"
  fi
}

cast_call() {
  local rpc="$1"
  shift
  cast call "$@" --rpc-url "$rpc"
}

contract_code_exists() {
  local rpc="$1"
  local addr="$2"
  local code
  code="$(cast code "$addr" --rpc-url "$rpc" 2>/dev/null || true)"
  [ -n "$code" ] && [ "$code" != "0x" ]
}

read_queue() {
  local lcc="$1"
  local recipient="$2"
  to_dec "$(cast_call "$PROTOCOL_RPC" "$LIQUIDITY_HUB" "settleQueue(address,address)(uint256)" "$lcc" "$recipient" 2>/dev/null || true)"
}

read_hub_state() {
  local lcc="$1"
  local recipient="$2"
  local key state amount exists inflight
  key="$(cast_call "$REACTIVE_RPC" "$HUB_RSC" "computeKey(address,address)(bytes32)" "$lcc" "$recipient" 2>/dev/null || true)"
  state="$(cast_call "$REACTIVE_RPC" "$HUB_RSC" "pendingStateByKey(bytes32)(uint256,bool)" "$key" 2>/dev/null || true)"
  amount="$(to_dec "$(printf '%s\n' "$state" | sed -n '1p')")"
  exists="$(printf '%s\n' "$state" | sed -n '2p' | tr -d '[:space:]')"
  inflight="$(to_dec "$(cast_call "$REACTIVE_RPC" "$HUB_RSC" "inFlightByKey(bytes32)(uint256)" "$key" 2>/dev/null || true)")"
  printf '%s %s %s %s\n' "${key:-0x0}" "$amount" "${exists:-false}" "$inflight"
}

wait_until() {
  local description="$1"
  shift
  local deadline=$(( $(date +%s) + MAX_WAIT_SECONDS ))
  echo "Waiting for ${description}..."
  while true; do
    if "$@"; then
      echo "Observed ${description}"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "Timed out waiting for ${description} after ${MAX_WAIT_SECONDS}s" >&2
      return 1
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
}

queue_increased() {
  local current
  current="$(read_queue "$LCC_OUT" "$RECIPIENT")"
  dec_gt "$current" "$QUEUED_BEFORE"
}

hub_work_observed() {
  local state pending exists inflight
  state="$(read_hub_state "$LCC_OUT" "$RECIPIENT")"
  pending="$(printf '%s\n' "$state" | awk '{print $2}')"
  exists="$(printf '%s\n' "$state" | awk '{print $3}')"
  inflight="$(printf '%s\n' "$state" | awk '{print $4}')"
  { [ "$exists" = "true" ] && dec_gt "$pending" 0; } || dec_gt "$inflight" 0
}

queue_decreased() {
  local current
  current="$(read_queue "$LCC_OUT" "$RECIPIENT")"
  dec_lt "$current" "$QUEUED_AFTER_SWAP"
}

derive_swap_signer() {
  local signer
  signer="$(cast wallet address --private-key "$SWAP_PRIVATE_KEY_VALUE" 2>/dev/null || true)"
  printf '%s' "$signer" | tr -d '[:space:]'
}

extract_label() {
  local label="$1"
  local text="$2"
  printf '%s\n' "$text" | sed -n \
    -e "s/^${label}:[[:space:]]*//p" \
    -e "s/.*[[:space:]]${label}:[[:space:]]*//p" | awk 'NF {print $1}' | tail -n1
}

extract_tx_hash() {
  local text="$1"
  printf '%s\n' "$text" | sed -n \
    -e 's/.*transactionHash[[:space:]:]*\(0x[a-fA-F0-9]\{64\}\).*/\1/p' \
    -e 's/.*Transaction hash:[[:space:]]*\(0x[a-fA-F0-9]\{64\}\).*/\1/p' \
    -e 's/.*Hash:[[:space:]]*\(0x[a-fA-F0-9]\{64\}\).*/\1/p' | tail -n1
}

broadcast_flag=()
if [ "$BROADCAST" = "true" ]; then
  broadcast_flag=(--broadcast)
fi

run_create_position() {
  (
    cd "$EVM_SCRIPTS_DIR"
    env \
      NETWORK="$NETWORK" \
      CORE_POOL_ID="$CORE_POOL_ID" \
      COMMIT_ID="${COMMIT_ID:-}" \
      COMMIT_MIN_VALIDITY_SECONDS="${COMMIT_MIN_VALIDITY_SECONDS:-300}" \
      MM_PRIVATE_KEY="$MM_PRIVATE_KEY" \
      MM_RANGE_WIDTH="$MM_RANGE_WIDTH" \
      MM_POSITION_USD_WAD="$MM_POSITION_USD_WAD" \
      LIQUIDITY_SIGNAL_HEX="${LIQUIDITY_SIGNAL_HEX:-}" \
      POSITION_INDEX="${POSITION_INDEX:-0}" \
      FOUNDRY_PROFILE="${EVM_SCRIPTS_FOUNDRY_PROFILE:-deploy}" \
      forge script script/CreateMMPosition.s.sol:CreateMMPosition \
        --rpc-url "$PROTOCOL_RPC" "${broadcast_flag[@]}" -vvv
  )
}

run_swap() {
  (
    cd "$EVM_SCRIPTS_DIR"
    env \
      NETWORK="$NETWORK" \
      CORE_POOL_ID="$CORE_POOL_ID" \
      PRIVATE_KEY="${PRIVATE_KEY:-$MM_PRIVATE_KEY}" \
      LP_PRIVATE_KEY="$SWAP_PRIVATE_KEY_VALUE" \
      SWAP_TYPE="$SWAP_TYPE" \
      AMOUNT="${AMOUNT:-}" \
      EAMOUNT="${EAMOUNT:-}" \
      FOUNDRY_PROFILE="${EVM_SCRIPTS_FOUNDRY_PROFILE:-deploy}" \
      forge script script/SwapV4.s.sol:SwapV4 \
        --rpc-url "$PROTOCOL_RPC" "${broadcast_flag[@]}" -vvv
  )
}

run_settle_position() {
  (
    cd "$EVM_SCRIPTS_DIR"
    env \
      NETWORK="$NETWORK" \
      CORE_POOL_ID="$CORE_POOL_ID" \
      MM_PRIVATE_KEY="$MM_PRIVATE_KEY" \
      COMMIT_ID="$COMMIT_ID" \
      POSITION_INDEX="${POSITION_INDEX:-0}" \
      FOUNDRY_PROFILE="${EVM_SCRIPTS_FOUNDRY_PROFILE:-deploy}" \
      forge script script/SettleMMPosition.s.sol:SettleMMPosition \
        --rpc-url "$PROTOCOL_RPC" "${broadcast_flag[@]}" -vvv
  )
}

run_close_position() {
  (
    cd "$EVM_SCRIPTS_DIR"
    env \
      NETWORK="$NETWORK" \
      CORE_POOL_ID="$CORE_POOL_ID" \
      MM_PRIVATE_KEY="$MM_PRIVATE_KEY" \
      COMMIT_ID="$COMMIT_ID" \
      POSITION_INDEX="${POSITION_INDEX:-0}" \
      FOUNDRY_PROFILE="${EVM_SCRIPTS_FOUNDRY_PROFILE:-deploy}" \
      forge script script/CloseMMPosition.s.sol:CloseMMPosition \
        --rpc-url "$PROTOCOL_RPC" "${broadcast_flag[@]}" -vvv
  )
}

run_checked() {
  local title="$1"
  shift
  local out status
  echo "========================================" >&2
  echo "$title" >&2
  set +e
  out="$("$@" 2>&1)"
  status=$?
  set -e
  printf '%s\n' "$out" >&2
  if [ "$status" -ne 0 ]; then
    fail "$title failed with exit code $status"
  fi
  printf '%s' "$out"
}

preflight() {
  require_cmd cast
  require_cmd forge

  for name in PROTOCOL_RPC REACTIVE_RPC NETWORK CORE_POOL_ID LIQUIDITY_HUB HUB_RSC BATCH_RECEIVER RECIPIENT \
    MM_PRIVATE_KEY MM_RANGE_WIDTH MM_POSITION_USD_WAD; do
    require_env "$name"
  done
  if ! has_env_value COMMIT_ID; then
    require_env LIQUIDITY_SIGNAL_HEX
  fi
  [ -n "$SWAP_PRIVATE_KEY_VALUE" ] || fail "Missing SWAP_PRIVATE_KEY, LP_PRIVATE_KEY, or MM_PRIVATE_KEY for SwapV4."
  [ -n "${AMOUNT:-}" ] || [ -n "${EAMOUNT:-}" ] || fail "Missing AMOUNT or EAMOUNT for SwapV4."

  require_address LIQUIDITY_HUB
  require_address HUB_RSC
  require_address BATCH_RECEIVER
  require_address RECIPIENT
  if [ -n "${HUB_CALLBACK:-}" ]; then require_address HUB_CALLBACK; fi
  if [ -n "${SPOKE_RSC:-}" ]; then require_address SPOKE_RSC; fi

  case "$SWAP_TYPE" in
    0|1|2) ;;
    3|4|5) fail "Recipient-signed exact-input demo cannot use exact-output SWAP_TYPE=$SWAP_TYPE" ;;
    *) fail "Invalid SWAP_TYPE=$SWAP_TYPE. Use 0, 1, or 2 for this live demo." ;;
  esac
  case "$CLOSE_POSITION_AFTER_DEMO" in
    true|false) ;;
    *) fail "Invalid CLOSE_POSITION_AFTER_DEMO=$CLOSE_POSITION_AFTER_DEMO. Use true or false." ;;
  esac

  local swap_signer
  swap_signer="$(derive_swap_signer)"
  is_address "$swap_signer" || fail "Could not derive swap signer from SWAP_PRIVATE_KEY, LP_PRIVATE_KEY, or MM_PRIVATE_KEY"
  same_address "$swap_signer" "$RECIPIENT" \
    || fail "RECIPIENT must equal the swap signer ($swap_signer). Empty hook data relies on ProxyHook locker/msgSender resolution."
  echo "Swap signer / queue recipient: $swap_signer"

  local protocol_chain reactive_chain
  protocol_chain="$(cast chain-id --rpc-url "$PROTOCOL_RPC")"
  reactive_chain="$(cast chain-id --rpc-url "$REACTIVE_RPC")"
  if [ -n "${PROTOCOL_CHAIN_ID:-}" ] && [ "$protocol_chain" != "$PROTOCOL_CHAIN_ID" ]; then
    fail "PROTOCOL_RPC chain id $protocol_chain does not match PROTOCOL_CHAIN_ID=$PROTOCOL_CHAIN_ID"
  fi
  if [ -n "${REACTIVE_CHAIN_ID:-}" ] && [ "$reactive_chain" != "$REACTIVE_CHAIN_ID" ]; then
    fail "REACTIVE_RPC chain id $reactive_chain does not match REACTIVE_CHAIN_ID=$REACTIVE_CHAIN_ID"
  fi

  contract_code_exists "$PROTOCOL_RPC" "$LIQUIDITY_HUB" || fail "No code at LIQUIDITY_HUB=$LIQUIDITY_HUB on PROTOCOL_RPC"
  contract_code_exists "$PROTOCOL_RPC" "$BATCH_RECEIVER" || fail "No code at BATCH_RECEIVER=$BATCH_RECEIVER on PROTOCOL_RPC"
  contract_code_exists "$REACTIVE_RPC" "$HUB_RSC" || fail "No code at HUB_RSC=$HUB_RSC on REACTIVE_RPC"
  if [ -n "${HUB_CALLBACK:-}" ]; then
    contract_code_exists "$REACTIVE_RPC" "$HUB_CALLBACK" || fail "No code at legacy HUB_CALLBACK=$HUB_CALLBACK on REACTIVE_RPC"
  else
    warn "HUB_CALLBACK is not set; skipping legacy HubCallback code check because current HubRSC runtime has no HubCallback."
  fi
  if [ -n "${SPOKE_RSC:-}" ]; then
    contract_code_exists "$REACTIVE_RPC" "$SPOKE_RSC" || fail "No code at legacy SPOKE_RSC=$SPOKE_RSC on REACTIVE_RPC"
  fi

  local receiver_hub receiver_rvm hub_liquidity_hub hub_receiver max_dispatch registered active base_active
  receiver_hub="$(cast_call "$PROTOCOL_RPC" "$BATCH_RECEIVER" "liquidityHub()(address)")"
  same_address "$receiver_hub" "$LIQUIDITY_HUB" || fail "BATCH_RECEIVER.liquidityHub()=$receiver_hub does not match LIQUIDITY_HUB=$LIQUIDITY_HUB"

  receiver_rvm="$(cast_call "$PROTOCOL_RPC" "$BATCH_RECEIVER" "hubRVMId()(address)")"
  if [ -n "${HUB_RVM_ID:-}" ] && ! same_address "$receiver_rvm" "$HUB_RVM_ID"; then
    fail "BATCH_RECEIVER.hubRVMId()=$receiver_rvm does not match HUB_RVM_ID=$HUB_RVM_ID"
  fi
  if [ -n "${SPOKE_RVM_ID:-}" ] && ! same_address "$receiver_rvm" "$SPOKE_RVM_ID"; then
    fail "BATCH_RECEIVER.hubRVMId()=$receiver_rvm does not match SPOKE_RVM_ID=$SPOKE_RVM_ID"
  fi
  echo "Receiver callback origin whitelist/RVM id: $receiver_rvm"
  echo "Note: this is the Reactive VM id configured on BatchProcessSettlement, not necessarily a deployed Spoke/HubRSC contract address."

  hub_liquidity_hub="$(cast_call "$REACTIVE_RPC" "$HUB_RSC" "liquidityHub()(address)")"
  same_address "$hub_liquidity_hub" "$LIQUIDITY_HUB" || fail "HubRSC.liquidityHub()=$hub_liquidity_hub does not match LIQUIDITY_HUB=$LIQUIDITY_HUB"
  hub_receiver="$(cast_call "$REACTIVE_RPC" "$HUB_RSC" "destinationReceiverContract()(address)")"
  same_address "$hub_receiver" "$BATCH_RECEIVER" || fail "HubRSC.destinationReceiverContract()=$hub_receiver does not match BATCH_RECEIVER=$BATCH_RECEIVER"

  max_dispatch="$(to_dec "$(cast_call "$REACTIVE_RPC" "$HUB_RSC" "maxDispatchItems()(uint256)")")"
  dec_gt "$max_dispatch" 0 || fail "HubRSC.maxDispatchItems() must be > 0"

  base_active="$(cast_call "$REACTIVE_RPC" "$HUB_RSC" "baseSubscriptionsActive()(bool)")"
  [ "$base_active" = "true" ] || fail "HubRSC base subscriptions are inactive. Run scripts/activatebasesubscriptions.sh for this existing HubRSC."

  registered="$(cast_call "$REACTIVE_RPC" "$HUB_RSC" "recipientRegistered(address)(bool)" "$RECIPIENT")"
  active="$(cast_call "$REACTIVE_RPC" "$HUB_RSC" "recipientActive(address)(bool)" "$RECIPIENT")"
  [ "$registered" = "true" ] || fail "RECIPIENT is not registered on HubRSC. Register/fund it before running the live demo."
  [ "$active" = "true" ] || fail "RECIPIENT is not active on HubRSC. Top it up with fundRecipient/registerRecipient before running the live demo."

  local reserves debts hub_balance
  reserves="$(to_dec "$(cast_call "$REACTIVE_RPC" "$SYSTEM_CONTRACT_ADDR" "reserves(address)(uint256)" "$HUB_RSC" 2>/dev/null || true)")"
  debts="$(to_dec "$(cast_call "$REACTIVE_RPC" "$SYSTEM_CONTRACT_ADDR" "debts(address)(uint256)" "$HUB_RSC" 2>/dev/null || true)")"
  hub_balance="$(to_dec "$(cast balance "$HUB_RSC" --rpc-url "$REACTIVE_RPC" 2>/dev/null || true)")"
  if ! dec_gt "$reserves" 0 && ! dec_gt "$hub_balance" 0; then
    fail "HubRSC has no visible Reactive system reserve or native balance. Fund it before running live automation."
  fi
  echo "Reactive funding: reserves=$reserves debts=$debts hubBalance=$hub_balance"
}

print_summary() {
  local status="$1"
  local state pending exists inflight remaining queue_settled_amount
  state="$(read_hub_state "${LCC_OUT:-${LCC0:-0x0000000000000000000000000000000000000000}}" "$RECIPIENT" 2>/dev/null || true)"
  pending="$(printf '%s\n' "$state" | awk '{print $2}')"
  exists="$(printf '%s\n' "$state" | awk '{print $3}')"
  inflight="$(printf '%s\n' "$state" | awk '{print $4}')"
  remaining="${QUEUED_FINAL:-${QUEUED_AFTER_SWAP:-0}}"
  queue_settled_amount="$(dec_sub_nonneg "${QUEUED_AFTER_SWAP:-0}" "${QUEUED_FINAL:-${QUEUED_AFTER_SWAP:-0}}")"

  echo "========================================"
  echo "Live Reactive Settlement demo summary"
  echo "  status: $status"
  echo "  commitMode: ${COMMIT_MODE:-unknown}"
  echo "  commitId: ${COMMIT_ID:-unknown}"
  echo "  commitExpiresAt: ${COMMIT_EXPIRES_AT:-unknown}"
  echo "  positionIndex: ${POSITION_INDEX:-0}"
  echo "  tickLower: ${CREATED_TICK_LOWER:-unknown}"
  echo "  tickUpper: ${CREATED_TICK_UPPER:-unknown}"
  echo "  liquidity: ${POSITION_LIQUIDITY:-unknown}"
  echo "  amount0Max: ${AMOUNT0_MAX:-unknown}"
  echo "  amount1Max: ${AMOUNT1_MAX:-unknown}"
  echo "  positionUsdWad: ${POSITION_USD_WAD_ACTUAL:-unknown}"
  echo "  targetPositionUsdWad: ${TARGET_POSITION_USD_WAD:-${MM_POSITION_USD_WAD:-unknown}}"
  echo "  baseSettle0: ${BASE_SETTLE0:-unknown}"
  echo "  baseSettle1: ${BASE_SETTLE1:-unknown}"
  echo "  makerSettle0: ${MAKER_SETTLE0:-unknown}"
  echo "  makerSettle1: ${MAKER_SETTLE1:-unknown}"
  echo "  rfsOpenAfterSettle: ${RFS_OPEN_AFTER_SETTLE:-unknown}"
  echo "  lccOut: ${LCC_OUT:-unknown}"
  echo "  recipient: $RECIPIENT"
  echo "  queuedBefore: ${QUEUED_BEFORE:-unknown}"
  echo "  queuedAfterSwap: ${QUEUED_AFTER_SWAP:-unknown}"
  echo "  queuedFinal: ${QUEUED_FINAL:-unknown}"
  echo "  queueSettledAmount: $queue_settled_amount"
  echo "  createTx: ${CREATE_TX:-unknown}"
  echo "  swapTx: ${SWAP_TX:-unknown}"
  echo "  settleTx: ${SETTLE_TX:-unknown}"
  echo "  closeTx: ${CLOSE_TX:-unknown}"
  echo "  closePositionAfterDemo: $CLOSE_POSITION_AFTER_DEMO"
  echo "  closeStatus: ${CLOSE_STATUS:-unknown}"
  echo "  closedLiquidity: ${CLOSED_LIQUIDITY:-unknown}"
  echo "  positionActiveAfterClose: ${POSITION_ACTIVE_AFTER_CLOSE:-unknown}"
  echo "  positionLiquidityAfterClose: ${POSITION_LIQUIDITY_AFTER_CLOSE:-unknown}"
  echo "  pending: ${pending:-unknown} (exists=${exists:-unknown})"
  echo "  inFlight: ${inflight:-unknown}"
  echo "  remainingQueue: $remaining"
}

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
  CREATE_TX="$(extract_tx_hash "$create_out")"
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

  if [ "$BROADCAST" != "true" ]; then
    swap_out="$(run_checked "Dry-run recipient-signed exact-input swap" run_swap)"
    LCC_OUT="$(extract_label "LccOut" "$swap_out")"
    SWAP_TX="$(extract_tx_hash "$swap_out")"
    QUEUED_BEFORE="0"
    QUEUED_AFTER_SWAP="0"
    QUEUED_FINAL="0"
    CLOSE_STATUS="not-run"
    print_summary "PASS (dry-run only; no live transactions broadcast)"
    return 0
  fi

  local q0_before q1_before
  q0_before="$(read_queue "$LCC0" "$RECIPIENT")"
  q1_before="$(read_queue "$LCC1" "$RECIPIENT")"

  swap_out="$(run_checked "Broadcast recipient-signed exact-input swap" run_swap)"
  LCC_OUT="$(extract_label "LccOut" "$swap_out")"
  SWAP_TX="$(extract_tx_hash "$swap_out")"
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
    print_summary "FAIL"
    fail "No queued settlement was observed. Try a larger AMOUNT/EAMOUNT, verify the recipient signed the swap, and verify the swap creates an output deficit."
  fi
  QUEUED_AFTER_SWAP="$(read_queue "$LCC_OUT" "$RECIPIENT")"

  if ! wait_until "HubRSC mirrored pending or in-flight work" hub_work_observed; then
    QUEUED_FINAL="$QUEUED_AFTER_SWAP"
    print_summary "FAIL"
    fail "HubRSC did not mirror queued work. Check recipient registration/funding, callback proxy delivery, and Reactive funding."
  fi

  settle_out="$(run_checked "Broadcast maker settlement for MM position" run_settle_position)"
  SETTLE_TX="$(extract_tx_hash "$settle_out")"
  MAKER_SETTLE0="$(extract_label "Settle0" "$settle_out")"
  MAKER_SETTLE1="$(extract_label "Settle1" "$settle_out")"
  RFS_OPEN_AFTER_SETTLE="$(extract_label "RfsOpenAfter" "$settle_out")"
  [ -n "$MAKER_SETTLE0" ] || fail "Could not parse Settle0 from SettleMMPosition output"
  [ -n "$MAKER_SETTLE1" ] || fail "Could not parse Settle1 from SettleMMPosition output"
  [ -n "$RFS_OPEN_AFTER_SETTLE" ] || fail "Could not parse RfsOpenAfter from SettleMMPosition output"
  if [ "$RFS_OPEN_AFTER_SETTLE" != "false" ]; then
    QUEUED_FINAL="$QUEUED_AFTER_SWAP"
    print_summary "FAIL"
    fail "Maker RFS remained open after settlement; refusing to continue to queue settlement or cleanup."
  fi

  if ! wait_until "protocol settleQueue decrease after maker settlement" queue_decreased; then
    QUEUED_FINAL="$(read_queue "$LCC_OUT" "$RECIPIENT")"
    print_summary "FAIL"
    fail "Settlement queue did not decrease. Check BatchProcessSettlement events and HubRSC retry/terminal state."
  fi

  QUEUED_FINAL="$(read_queue "$LCC_OUT" "$RECIPIENT")"
  if [ "$CLOSE_POSITION_AFTER_DEMO" = "true" ]; then
    close_out="$(run_checked "Broadcast close live MM position" run_close_position)"
    CLOSE_TX="$(extract_tx_hash "$close_out")"
    CLOSE_STATUS="$(extract_label "CloseStatus" "$close_out")"
    CLOSED_LIQUIDITY="$(extract_label "ClosedLiquidity" "$close_out")"
    POSITION_ACTIVE_AFTER_CLOSE="$(extract_label "PositionActiveAfter" "$close_out")"
    POSITION_LIQUIDITY_AFTER_CLOSE="$(extract_label "PositionLiquidityAfter" "$close_out")"
    [ -n "$CLOSE_STATUS" ] || fail "Could not parse CloseStatus from CloseMMPosition output"
    [ -n "$CLOSED_LIQUIDITY" ] || fail "Could not parse ClosedLiquidity from CloseMMPosition output"
    [ -n "$POSITION_ACTIVE_AFTER_CLOSE" ] || fail "Could not parse PositionActiveAfter from CloseMMPosition output"
    [ -n "$POSITION_LIQUIDITY_AFTER_CLOSE" ] || fail "Could not parse PositionLiquidityAfter from CloseMMPosition output"
  else
    CLOSE_STATUS="skipped"
  fi
  print_summary "PASS"
}

main "$@"

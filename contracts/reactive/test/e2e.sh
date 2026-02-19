#!/usr/bin/env bash
set -euo pipefail

# Load local env overrides when present.
if [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

REACTIVE_RPC="${REACTIVE_RPC:-}"
PROTOCOL_RPC="${PROTOCOL_RPC:-}"
PRIVATE_KEY="${PRIVATE_KEY:-}"
DEPLOY_DEBUG="${DEBUG:-false}"
export RECIPIENT="0xb797466544DeB18F1e19185e85400A26FC5d3E95"
export BROADCAST=true

: "${REACTIVE_RPC:?REACTIVE_RPC is required}"
: "${PROTOCOL_RPC:?PROTOCOL_RPC is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"
: "${RECIPIENT:?RECIPIENT is required}"

# Reactive VM id maps to the deployer address derived from the deployer private key.
RVM_ID="$(cast wallet address --private-key "$PRIVATE_KEY")"
export RVM_ID

broadcast_flag=""
if [ "$BROADCAST" = "true" ]; then
  broadcast_flag="--broadcast"
fi

extract_labeled_address() {
  local label="$1"
  local text="$2"
  # Match even when forge prefixes log lines with spaces or extra text.
  printf '%s\n' "$text" | sed -n "s/.*${label}:[[:space:]]*\(0x[a-fA-F0-9]\{40\}\).*/\1/p" | tail -n1
}

run_and_print() {
  local title="$1"
  shift
  echo "========================================" >&2
  echo "$title" >&2
  local out
  # When DEPLOY_DEBUG=true, stream command output live while still capturing it.
  if [ "$DEPLOY_DEBUG" = "true" ]; then
    out="$("$@" 2>&1 | tee /dev/stderr)"
  else
    out="$("$@" 2>&1)"
  fi
  printf '%s' "$out"
}

deploy() {
  # 1) Deploy protocol mock liquidity hub.
  mock_out="$(run_and_print \
    "Deploying MockLiquidityHub..." \
    forge script scripts/_mocks/DeployMockLiquidityHub.s.sol:DeployMockLiquidityHub \
      --rpc-url "$PROTOCOL_RPC" \
      $broadcast_flag)"

  MOCK_LIQUIDITY_HUB="$(extract_labeled_address "MockLiquidityHub" "$mock_out")"
  if [ -z "${MOCK_LIQUIDITY_HUB:-}" ]; then
    echo "Failed to parse MockLiquidityHub address."
    echo "---- raw output ----"
    echo "$mock_out"
    exit 1
  fi

  echo "MockLiquidityHub deployed to: $MOCK_LIQUIDITY_HUB"
  export LIQUIDITY_HUB="$MOCK_LIQUIDITY_HUB"

  # 2) Deploy protocol receiver.
  receiver_out="$(run_and_print \
    "Deploying BatchProcessSettlement receiver..." \
    forge script scripts/DeployReceiver.s.sol:DeployReceiver \
      --rpc-url "$PROTOCOL_RPC" \
      $broadcast_flag)"

  BATCH_RECEIVER="$(extract_labeled_address "BatchProcessSettlementReceiver" "$receiver_out")"
  if [ -z "${BATCH_RECEIVER:-}" ]; then
    echo "Failed to parse BatchProcessSettlementReceiver address."
    exit 1
  fi
  echo "BatchProcessSettlementReceiver deployed to: $BATCH_RECEIVER"
  export BATCH_RECEIVER

  # 3) Deploy reactive hub stack (HubCallback + HubRSC).
  hub_out="$(run_and_print "Deploying reactive hub stack..." bash scripts/deployreactivehub.sh)"

  HUB_CALLBACK="$(extract_labeled_address "HubCallback" "$hub_out")"
  HUB_RSC="$(extract_labeled_address "HubRSC" "$hub_out")"
  if [ -z "${HUB_CALLBACK:-}" ] || [ -z "${HUB_RSC:-}" ]; then
    echo "Failed to parse HubCallback/HubRSC addresses."
    echo "---- raw output ----"
    echo "$hub_out"
    exit 1
  fi
  echo "HubCallback deployed to: $HUB_CALLBACK"
  echo "HubRSC deployed to: $HUB_RSC"
  export HUB_CALLBACK
  export HUB_RSC

  sleep 10

  # 4) Deploy reactive spoke.
  set +e
  spoke_out="$(run_and_print "Deploying SpokeRSC..." bash scripts/deployreactivespoke.sh)"
  spoke_status=$?
  set -e
  if [ "$spoke_status" -ne 0 ]; then
    echo "Spoke deployment step failed."
    echo "---- raw output ----"
    echo "$spoke_out"
    exit "$spoke_status"
  fi
  SPOKE_RSC="$(extract_labeled_address "SpokeRSC" "$spoke_out")"
  if [ -z "${SPOKE_RSC:-}" ]; then
    echo "Failed to parse SpokeRSC address."
    echo "---- raw output ----"
    echo "$spoke_out"
    exit 1
  fi
  echo "SpokeRSC deployed to: $SPOKE_RSC"
  export SPOKE_RSC

  # 5) Register recipient -> spoke mapping on HubCallback.
  whitelist_out="$(run_and_print "Setting spoke for recipient..." forge script scripts/WhitelistSpokeForRecipient.s.sol:WhitelistSpokeForRecipient --rpc-url "$REACTIVE_RPC" $broadcast_flag)"
  echo "$whitelist_out"
  echo "Spoke set for recipient"

  sleep 10

  # 5.1) Assert recipient -> spoke mapping is set to the deployer RVM id.
  mapped_spoke="$(cast call "$HUB_CALLBACK" \
    "spokeForRecipient(address)(address)" \
    "$RECIPIENT" \
    --rpc-url "$REACTIVE_RPC")"

  mapped_spoke_lc="$(printf '%s' "$mapped_spoke" | tr '[:upper:]' '[:lower:]')"
  rvm_id_lc="$(printf '%s' "$RVM_ID" | tr '[:upper:]' '[:lower:]')"
  if [ "$mapped_spoke_lc" != "$rvm_id_lc" ]; then
    echo "spokeForRecipient mismatch: expected $RVM_ID got $mapped_spoke"
    exit 1
  fi
  echo "spokeForRecipient mapping verified: $mapped_spoke"

  echo "================== DEPLOYMENT COMPLETE ======================"
  echo "MockLiquidityHub:              $MOCK_LIQUIDITY_HUB"
  echo "BatchProcessSettlementReceiver: $BATCH_RECEIVER"
  echo "HubCallback:                   $HUB_CALLBACK"
  echo "HubRSC:                        $HUB_RSC"
  echo "SpokeRSC:                      $SPOKE_RSC"
  echo "Recipient:                     $RECIPIENT"
}

integration() {
  local rpc_url="$PROTOCOL_RPC"
  local deployer_private_key="$PRIVATE_KEY"
  local mock_liq_hub="$LIQUIDITY_HUB"
  local recipient_addr="$RECIPIENT"
  local lcc_addr="0x5FbDB2315678afecb367f032d93F642f64180aa3"
  local check_amount="100"
  local sleep_seconds="${SLEEP_SECONDS:-60}"

  echo "=================== RUNNING INTEGRATION TESTS ===================="
  echo "  RPC_URL=$rpc_url"
  echo "  LIQUIDITY_HUB=$mock_liq_hub"
  echo "  LCC=$lcc_addr"
  echo "  RECIPIENT=$recipient_addr"
  echo "  CHECK_AMOUNT=$check_amount"
  echo "  SLEEP_SECONDS=$sleep_seconds"

  # 1) Emit queue event.
  echo "Emitting settlement queued event..."
  cast send "$mock_liq_hub" \
    "triggerSettlementQueued(address,address,uint256)" \
    "$lcc_addr" \
    "$recipient_addr" \
    "$check_amount" \
    --rpc-url "$rpc_url" \
    --private-key "$deployer_private_key" >/dev/null
  echo "Settlement queued"

  # 2) Wait for off-chain reactive processing to pick up and callback.
  echo "Waiting for off-chain reactive processing to pick up and callback..."
  sleep "$sleep_seconds"

  # 3) read mapping from callback to ensure the settlement was processed
    echo "Reading mapping from callback to ensure the settlement was processed by hub callback and forwarded to hub reactive contract"
    total_processed="$(cast call "$HUB_CALLBACK" \
        "getTotalAmountProcessed(address,address)(uint256)" \
        "$lcc_addr" \
        "$recipient_addr" \
        --rpc-url "$REACTIVE_RPC")"
    echo "total_processed by hub callback=$total_processed"
    if [ "$total_processed" = "0" ]; then
        echo "total_processed is 0, settlement not processed yet"
        exit 1
    fi

  echo "Emitting liquidity available event to disburse queued settlements"
  cast send "$mock_liq_hub" \
    "triggerLiquidityAvailable(address,address,uint256,bytes32)" \
    "$lcc_addr" \
    "$recipient_addr" \
    "$check_amount" \
    "0x0000000000000000000000000000000000000000000000000000000000000001" \
    --rpc-url "$rpc_url" \
    --private-key "$deployer_private_key" >/dev/null

  echo "Waiting for settlement to be processed and dispatched..."
  sleep "$sleep_seconds"

  # 4) Read mapped processed amount.
  echo "Reading settled amount for the given lcc and recipient to ensure the settlement was paid out to the recipient"
  local total_settled
  total_settled="$(cast call "$mock_liq_hub" \
    "getTotalAmountSettled(address,address)(uint256)" \
    "$lcc_addr" \
    "$recipient_addr" \
    --rpc-url "$rpc_url")"

  echo "total_settled=$total_settled"
  if [ "$total_settled" = "0" ]; then
    echo "total_settled is 0, amount not settled for the given lcc and recipient yet"
    exit 1
  fi
}

# run deployment
deploy
# run integration test
integration
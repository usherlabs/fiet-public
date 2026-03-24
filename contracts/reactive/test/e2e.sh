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
# Default only when unset so a sourced `.env` or caller-provided env is not overwritten.
RECIPIENT_ONE="${RECIPIENT_ONE:-0xb797466544DeB18F1e19185e85400A26FC5d3E95}"
RECIPIENT_TWO="${RECIPIENT_TWO:-0xa4260A121bC44d085AC9a18e628A5712Ef3Bd49C}"
export BROADCAST=true

: "${REACTIVE_RPC:?REACTIVE_RPC is required}"
: "${PROTOCOL_RPC:?PROTOCOL_RPC is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"
: "${RECIPIENT_ONE:?RECIPIENT_ONE is required}"
: "${RECIPIENT_TWO:?RECIPIENT_TWO is required}"
# ensure that both spoke private keys are different and are both funded with the same amount of lasna reactive tokens
: "${SPOKE_ONE_PRIVATE_KEY:?SPOKE_ONE_PRIVATE_KEY is required}"
: "${SPOKE_TWO_PRIVATE_KEY:?SPOKE_TWO_PRIVATE_KEY is required}"

# Expected HubRSC callback origin (RVM id) for receiver auth.
# Always derived from the deployer private key used by deployreactivehub.sh.
HUB_RVM_ID="$(cast wallet address --private-key "$PRIVATE_KEY")"
export HUB_RVM_ID


# Reactive VM id maps to the deployer address derived from the deployer private key.
RVM_ID_ONE="$(cast wallet address --private-key "$SPOKE_ONE_PRIVATE_KEY")"
RVM_ID_TWO="$(cast wallet address --private-key "$SPOKE_TWO_PRIVATE_KEY")"


broadcast_flag=""
if [ "$BROADCAST" = "true" ]; then
  broadcast_flag="--broadcast"
fi

# UTILITY HELPER FUNCTION TO EXTRACT THE ADDRESS OF THE DEPLOYED CONTRACT FROM THE FORGE OUTPUT
extract_labeled_address() {
  local label="$1"
  local text="$2"
  # Match even when forge prefixes log lines with spaces or extra text.
  printf '%s\n' "$text" | sed -n "s/.*${label}:[[:space:]]*\(0x[a-fA-F0-9]\{40\}\).*/\1/p" | tail -n1
}

# UTILITY HELPER FUNCTION TO RUN A COMMAND AND PRINT THE OUTPUT
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

# DEPLOYMENT FUNCTION TO DEPLOY THE PROTOCOL MOCK LIQUIDITY HUB, PROTOCOL RECEIVER, REACTIVE HUB STACK (HUB CALLBACK + HUB RSC), AND REACTIVE SPOKES FOR RECIPIENT ONE AND TWO
deploy() {
  # 1) Deploy protocol mock liquidity hub.
  mock_out="$(run_and_print \
    "Deploying MockLiquidityHub..." \
    forge script scripts/_mocks/DeployMockLiquidityHub.s.sol:DeployMockLiquidityHub \
      --rpc-url "$PROTOCOL_RPC" \
      $broadcast_flag)"

  # extract the right address from the deployment output
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
  hub_out="$(run_and_print "Deploying reactive hub stack..." env BATCH_SIZE=1 bash scripts/deployreactivehub.sh)"

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

  # 4) Deploy reactive spoke for recipient one and recipient two.
  set +e
  spoke_out="$(run_and_print "Deploying SpokeRSC for recipient one..." env ${SPOKE_ONE_PRIVATE_KEY:+OVERRIDE_PRIVATE_KEY="$SPOKE_ONE_PRIVATE_KEY"} RECIPIENT="$RECIPIENT_ONE" bash scripts/deployreactivespoke.sh)"
  spoke_status=$?
  set -e
  if [ "$spoke_status" -ne 0 ]; then
    echo "Spoke deployment step failed."
    echo "---- raw output ----"
    echo "$spoke_out"
    exit "$spoke_status"
  fi
  SPOKE_ONE_RSC="$(extract_labeled_address "SpokeRSC" "$spoke_out")"
  if [ -z "${SPOKE_ONE_RSC:-}" ]; then
    echo "Failed to parse SpokeRSC for recipient one address."
    echo "---- raw output ----"
    echo "$spoke_out"
    exit 1
  fi
  echo "SpokeRSC for recipient one deployed to: $SPOKE_ONE_RSC"
  export SPOKE_ONE_RSC

  # 5) Deploy Reactive spoke for recipient two.
  set +e
  spoke_out="$(run_and_print "Deploying SpokeRSC for recipient two..." env ${SPOKE_TWO_PRIVATE_KEY:+OVERRIDE_PRIVATE_KEY="$SPOKE_TWO_PRIVATE_KEY"} RECIPIENT="$RECIPIENT_TWO" bash scripts/deployreactivespoke.sh)"
  spoke_status=$?
  set -e
  if [ "$spoke_status" -ne 0 ]; then
    echo "Spoke for recipient two deployment step failed."
    echo "---- raw output ----"
    echo "$spoke_out"
    exit "$spoke_status"
  fi

  # extract the right address from the deployment output
  SPOKE_TWO_RSC="$(extract_labeled_address "SpokeRSC" "$spoke_out")"
  if [ -z "${SPOKE_TWO_RSC:-}" ]; then
    echo "Failed to parse SpokeRSC for recipient two address."
    echo "---- raw output ----"
    echo "$spoke_out"
    exit 1
  fi
  echo "SpokeRSC for recipient two deployed to: $SPOKE_TWO_RSC"
  export SPOKE_TWO_RSC

  sleep 10

  # 5) Register recipients -> spoke mapping on HubCallback.
  whitelist_out_one="$(run_and_print "Setting spoke for recipient one..." env RECIPIENT="$RECIPIENT_ONE" RVM_ID="$RVM_ID_ONE" forge script scripts/WhitelistSpokeForRecipient.s.sol:WhitelistSpokeForRecipient --rpc-url "$REACTIVE_RPC" $broadcast_flag)"
  whitelist_out_two="$(run_and_print "Setting spoke for recipient two..." env RECIPIENT="$RECIPIENT_TWO" RVM_ID="$RVM_ID_TWO" forge script scripts/WhitelistSpokeForRecipient.s.sol:WhitelistSpokeForRecipient --rpc-url "$REACTIVE_RPC" $broadcast_flag)"
  echo "Spoke set for both recipients"
  sleep 10

  # 7) Assert recipient -> spoke mapping is set to the deployer RVM id for recipient one and recipient two.
  mapped_spoke="$(cast call "$HUB_CALLBACK" \
    "spokeForRecipient(address)(address)" \
    "$RECIPIENT_ONE" \
    --rpc-url "$REACTIVE_RPC")"

  mapped_spoke_lc="$(printf '%s' "$mapped_spoke" | tr '[:upper:]' '[:lower:]')"
  rvm_id_lc="$(printf '%s' "$RVM_ID_ONE" | tr '[:upper:]' '[:lower:]')"
  if [ "$mapped_spoke_lc" != "$rvm_id_lc" ]; then
    echo "spokeForRecipient mismatch: expected $RVM_ID_ONE got $mapped_spoke"
    exit 1
  fi
  echo "spokeForRecipient for recipient one mapping verified: $mapped_spoke"

  mapped_spoke="$(cast call "$HUB_CALLBACK" \
    "spokeForRecipient(address)(address)" \
    "$RECIPIENT_TWO" \
    --rpc-url "$REACTIVE_RPC")"

  mapped_spoke_lc="$(printf '%s' "$mapped_spoke" | tr '[:upper:]' '[:lower:]')"
  rvm_id_lc="$(printf '%s' "$RVM_ID_TWO" | tr '[:upper:]' '[:lower:]')"
  if [ "$mapped_spoke_lc" != "$rvm_id_lc" ]; then
    echo "spokeForRecipient mismatch: expected $RVM_ID_TWO got $mapped_spoke"
    exit 1
  fi
  echo "spokeForRecipient for recipient two mapping verified: $mapped_spoke"

  echo "================== DEPLOYMENT COMPLETE ======================"
  echo "MockLiquidityHub:              $MOCK_LIQUIDITY_HUB"
  echo "BatchProcessSettlementReceiver: $BATCH_RECEIVER"
  echo "HubCallback:                   $HUB_CALLBACK"
  echo "HubRSC:                        $HUB_RSC"
  echo "SpokeRSC One:                   $SPOKE_ONE_RSC"
  echo "SpokeRSC Two:                   $SPOKE_TWO_RSC"
  echo "Recipient:                     $RECIPIENT_ONE"
}

# run an intergration test that follows this flow:
# 1) Emit queue event for recipient one and recipient two.
# 2) Wait for off-chain reactive processing to pick up and callback.
# 3) Read mapping from callback to ensure the settlement was processed by hub callback and forwarded to hub reactive contract.
# 4) Emitting liquidity available event to disburse queued settlements.
# 5) Wait for settlement to be processed and dispatched for only one recipient
# 6) The `moreLiquidityAvailable` event is emitted to trigger another round of processing.
# 7) The flow is repeated until all settlements are processed and liquidity is exhausted.
# 6) Read mapped processed amount for recipient one and recipient two.
# 7) Assert the settlement was paid out to the recipient on the destination chain.
integration() {
  local rpc_url="$PROTOCOL_RPC"
  local deployer_private_key="$PRIVATE_KEY"
  local mock_liq_hub="$LIQUIDITY_HUB"
  local recipient_one_addr="$RECIPIENT_ONE"
  local recipient_two_addr="$RECIPIENT_TWO"
  local lcc_addr="0x5FbDB2315678afecb367f032d93F642f64180aa3"
  local queue_amount_one="111"
  local queue_amount_two="222"
  local liquidity_amount="1000"
  local sleep_seconds="${SLEEP_SECONDS:-90}"

  echo "=================== RUNNING INTEGRATION TESTS ===================="
  echo "  RPC_URL=$rpc_url"
  echo "  LIQUIDITY_HUB=$mock_liq_hub"
  echo "  LCC=$lcc_addr"
  echo "  RECIPIENT_ONE=$recipient_one_addr"
  echo "  RECIPIENT_TWO=$recipient_two_addr"
  echo "  CHECK_AMOUNT_ONE=$queue_amount_one"
  echo "  CHECK_AMOUNT_TWO=$queue_amount_two"
  echo "  SLEEP_SECONDS=$sleep_seconds"

  # 1) Emit queue event.
  echo "Emitting settlement queued event..."
  cast send "$mock_liq_hub" \
    "triggerSettlementQueued(address,address,uint256)" \
    "$lcc_addr" \
    "$recipient_one_addr" \
    "$queue_amount_one" \
    --rpc-url "$rpc_url" \
    --private-key "$deployer_private_key" >/dev/null

  cast send "$mock_liq_hub" \
    "triggerSettlementQueued(address,address,uint256)" \
    "$lcc_addr" \
    "$recipient_two_addr" \
    "$queue_amount_two" \
    --rpc-url "$rpc_url" \
    --private-key "$deployer_private_key" >/dev/null
  echo "Settlement queued"

  # 2) Wait for off-chain reactive processing to pick up and callback.
  echo "Waiting for off-chain reactive processing to pick up and callback..."
  sleep "$sleep_seconds"

  # 3) read mapping from callback to ensure the settlement was processed by the hub callback and forwarded to the hub reactive contract
  echo "Reading mapping from callback to ensure the settlement was processed by hub callback and forwarded to hub reactive contract"
  # total processed amount for recipient one by hub callback
  total_processed="$(cast call "$HUB_CALLBACK" \
      "getTotalAmountProcessed(address,address)(uint256)" \
      "$lcc_addr" \
      "$recipient_one_addr" \
      --rpc-url "$REACTIVE_RPC")"
  echo "total_processed for recipient one by hub callback=$total_processed"
  if [ "$total_processed" = "0" ]; then
      echo "total_processed is 0, settlement not processed yet"
      exit 1
  fi
  # total processed amount for recipient two by hub callback
  total_processed="$(cast call "$HUB_CALLBACK" \
    "getTotalAmountProcessed(address,address)(uint256)" \
    "$lcc_addr" \
    "$recipient_two_addr" \
    --rpc-url "$REACTIVE_RPC")"
    echo "total_processed for recipient two by hub callback=$total_processed"
    if [ "$total_processed" = "0" ]; then
        echo "total_processed is 0, settlement not processed yet"
        exit 1
    fi

  # 4) Emitting liquidity available event to disburse queued settlements
  echo "Emitting liquidity available event to disburse queued settlements"
  cast send "$mock_liq_hub" \
    "triggerLiquidityAvailable(address,address,uint256,bytes32)" \
    "$lcc_addr" \
    "$recipient_two_addr" \
    "$liquidity_amount" \
    "0x0000000000000000000000000000000000000000000000000000000000000001" \
    --rpc-url "$rpc_url" \
    --private-key "$deployer_private_key" >/dev/null

  echo "Waiting for settlement to be processed and dispatched..."
  sleep "$sleep_seconds"

  # 4) Read variable that tracks the total amount settled for the given lcc and recipient to ensure the settlement was paid out to the recipient.
  echo "Reading settled amount for the given lcc and recipient to ensure the settlement was paid out to the recipient"
  # total settled amount for recipient one
  local total_settled
  total_settled="$(cast call "$mock_liq_hub" \
    "getTotalAmountSettled(address,address)(uint256)" \
    "$lcc_addr" \
    "$recipient_one_addr" \
    --rpc-url "$rpc_url")"

  echo "total_settled for recipient one=$total_settled"
  if [ "$total_settled" = "0" ]; then
    echo "total_settled is 0, amount not settled for the given lcc and recipient yet"
    exit 1
  fi

  # total settled amount for recipient two
  total_settled="$(cast call "$mock_liq_hub" \
    "getTotalAmountSettled(address,address)(uint256)" \
    "$lcc_addr" \
    "$recipient_two_addr" \
    --rpc-url "$rpc_url")"
  echo "total_settled for recipient two=$total_settled"
  if [ "$total_settled" = "0" ]; then
    echo "total_settled is 0, amount not settled for the given lcc and recipient yet"
    exit 1
  fi
}

# run deployment
deploy
# run integration test
integration
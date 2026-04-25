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

# Expected HubRSC callback origin (RVM id) for receiver auth.
# Always derived from the deployer private key used by deployreactivehub.sh.
HUB_RVM_ID="$(cast wallet address --private-key "$PRIVATE_KEY")"
export HUB_RVM_ID


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

# DEPLOYMENT FUNCTION TO DEPLOY THE PROTOCOL MOCK LIQUIDITY HUB, PROTOCOL RECEIVER, AND SINGLE HUB RSC.
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

  # 3) Deploy reactive HubRSC.
  hub_out="$(run_and_print "Deploying reactive HubRSC..." env BATCH_SIZE=1 bash scripts/deployreactivehub.sh)"

  HUB_RSC="$(extract_labeled_address "HubRSC" "$hub_out")"
  if [ -z "${HUB_RSC:-}" ]; then
    echo "Failed to parse HubRSC address."
    echo "---- raw output ----"
    echo "$hub_out"
    exit 1
  fi
  echo "HubRSC deployed to: $HUB_RSC"
  export HUB_RSC

  sleep 10

  # 4) Register and fund recipients on HubRSC so exact-match subscriptions become active.
  cast send "$HUB_RSC" \
    "registerRecipient(address,uint256)" \
    "$RECIPIENT_ONE" \
    "100" \
    --rpc-url "$REACTIVE_RPC" \
    --private-key "$PRIVATE_KEY" >/dev/null
  cast send "$HUB_RSC" \
    "registerRecipient(address,uint256)" \
    "$RECIPIENT_TWO" \
    "100" \
    --rpc-url "$REACTIVE_RPC" \
    --private-key "$PRIVATE_KEY" >/dev/null
  echo "Recipients registered and funded on HubRSC"

  echo "================== DEPLOYMENT COMPLETE ======================"
  echo "MockLiquidityHub:              $MOCK_LIQUIDITY_HUB"
  echo "BatchProcessSettlementReceiver: $BATCH_RECEIVER"
  echo "HubRSC:                        $HUB_RSC"
  echo "Recipient:                     $RECIPIENT_ONE"
}

# run an intergration test that follows this flow:
# 1) Emit queue event for recipient one and recipient two.
# 2) Wait for off-chain reactive processing to pick up and callback.
# 3) Emitting liquidity available event to disburse queued settlements.
# 4) Wait for settlement to be processed.
# 5) Assert the settlement was paid out to each registered recipient on the destination chain.
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

  # 3) Emitting liquidity available event to disburse queued settlements
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

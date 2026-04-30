# shellcheck shell=bash
# Sourced after e2e-common.sh. Requires LIQUIDITY_HUB, HUB_RSC, PROTOCOL_RPC, REACTIVE_RPC,
# PRIVATE_KEY, RECIPIENT_ONE, RECIPIENT_TWO. Optional LCC, SIBLING_LCC, etc. (see e2e-integration.sh).

# .inc.sh files (e2e-deploy.inc.sh, e2e-integration.inc.sh)
# Intended use: sourced from another script, not run as bash …/e2e-deploy.inc.sh.
# What they contain: Only function definitions (e.g. e2e_deploy, e2e_integration). No top-level “do the work” steps when sourced.
# Why they exist: So the same deploy/integration logic can be used in two ways:
# Standalone entrypoints (e2e-deploy.sh, e2e-integration.sh) source the .inc and call the function once.
# e2e.sh sources both .inc files in one shell, runs e2e_deploy then e2e_integration, so exports such as LIQUIDITY_HUB and HUB_R_SC set during deploy are still visible for integration (they would not carry over if deploy and integration were two separate bash processes).

e2e_integration() {
  local rpc_url="$PROTOCOL_RPC"
  local deployer_private_key="$PRIVATE_KEY"
  local mock_liq_hub="$LIQUIDITY_HUB"
  local recipient_one_addr="$RECIPIENT_ONE"
  local recipient_two_addr="$RECIPIENT_TWO"
  local lcc_addr="${LCC:-0x5FbDB2315678afecb367f032d93F642f64180aa3}"
  local sibling_lcc_addr="${SIBLING_LCC:-0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512}"
  local underlying_addr="${UNDERLYING:-0xDeaD000000000000000000000000000000000001}"
  local sibling_underlying_addr="${SIBLING_UNDERLYING:-0xDeaD000000000000000000000000000000000002}"
  local market_id="${MARKET_ID:-0x0000000000000000000000000000000000000000000000000000000000000001}"
  local queue_amount_one="${CHECK_AMOUNT_ONE:-111}"
  local queue_amount_two="${CHECK_AMOUNT_TWO:-222}"
  local liquidity_amount="${LIQUIDITY_AMOUNT:-1000}"

  echo "=================== RUNNING INTEGRATION TESTS ===================="
  echo "  REACTIVE_RPC=$REACTIVE_RPC"
  echo "  PROTOCOL_RPC=$rpc_url"
  echo "  HUB_RSC=$HUB_RSC"
  echo "  LIQUIDITY_HUB=$mock_liq_hub"
  echo "  LCC=$lcc_addr"
  echo "  SIBLING_LCC=$sibling_lcc_addr"
  echo "  UNDERLYING=$underlying_addr"
  echo "  SIBLING_UNDERLYING=$sibling_underlying_addr"
  echo "  MARKET_ID=$market_id"
  echo "  RECIPIENT_ONE=$recipient_one_addr"
  echo "  RECIPIENT_TWO=$recipient_two_addr"
  echo "  CHECK_AMOUNT_ONE=$queue_amount_one"
  echo "  CHECK_AMOUNT_TWO=$queue_amount_two"
  echo "  LIQUIDITY_AMOUNT=$liquidity_amount"
  echo "  POLL_TIMEOUT_SECONDS=${POLL_TIMEOUT_SECONDS:-180}"
  echo "  POLL_INTERVAL_SECONDS=${POLL_INTERVAL_SECONDS:-5}"

  local reactive_diagnostic_start_block
  reactive_diagnostic_start_block="$(cast block-number --rpc-url "$REACTIVE_RPC" 2>/dev/null || true)"

  echo "Emitting LCCCreated pair..."
  cast send "$mock_liq_hub" \
    "triggerLccCreated(address,address,bytes32)" \
    "$underlying_addr" \
    "$lcc_addr" \
    "$market_id" \
    --rpc-url "$rpc_url" \
    --private-key "$deployer_private_key" >/dev/null
  cast send "$mock_liq_hub" \
    "triggerLccCreated(address,address,bytes32)" \
    "$sibling_underlying_addr" \
    "$sibling_lcc_addr" \
    "$market_id" \
    --rpc-url "$rpc_url" \
    --private-key "$deployer_private_key" >/dev/null
  echo "LCCCreated pair emitted"

  echo "Emitting settlement queued event..."
  local queue_one_out queue_two_out queue_one_tx queue_two_tx
  queue_one_out="$(cast send "$mock_liq_hub" \
    "triggerSettlementQueued(address,address,uint256)" \
    "$lcc_addr" \
    "$recipient_one_addr" \
    "$queue_amount_one" \
    --rpc-url "$rpc_url" \
    --private-key "$deployer_private_key")"
  queue_one_tx="$(extract_transaction_hash "$queue_one_out")"

  queue_two_out="$(cast send "$mock_liq_hub" \
    "triggerSettlementQueued(address,address,uint256)" \
    "$lcc_addr" \
    "$recipient_two_addr" \
    "$queue_amount_two" \
    --rpc-url "$rpc_url" \
    --private-key "$deployer_private_key")"
  queue_two_tx="$(extract_transaction_hash "$queue_two_out")"
  echo "Settlement queued"
  echo "  recipient one protocol tx: ${queue_one_tx:-unknown}"
  echo "  recipient two protocol tx: ${queue_two_tx:-unknown}"

  if ! wait_until "recipient one pending settlement on HubRSC" \
    pending_at_least "$HUB_RSC" "$lcc_addr" "$recipient_one_addr" "$queue_amount_one"; then
    print_callback_bridge_diagnostics "$reactive_diagnostic_start_block" "$HUB_RSC" "$queue_one_tx" "$queue_two_tx"
    exit 1
  fi
  if ! wait_until "recipient two pending settlement on HubRSC" \
    pending_at_least "$HUB_RSC" "$lcc_addr" "$recipient_two_addr" "$queue_amount_two"; then
    print_callback_bridge_diagnostics "$reactive_diagnostic_start_block" "$HUB_RSC" "$queue_one_tx" "$queue_two_tx"
    exit 1
  fi

  echo "Emitting liquidity available event to disburse queued settlements"
  cast send "$mock_liq_hub" \
    "triggerLiquidityAvailable(address,address,uint256,bytes32)" \
    "$lcc_addr" \
    "$underlying_addr" \
    "$liquidity_amount" \
    "$market_id" \
    --rpc-url "$rpc_url" \
    --private-key "$deployer_private_key" >/dev/null

  echo "Waiting for settlement to be processed and dispatched..."
  wait_until "recipient one protocol settlement" \
    settled_at_least "$mock_liq_hub" "$lcc_addr" "$recipient_one_addr" "$queue_amount_one"
  wait_until "recipient two protocol settlement" \
    settled_at_least "$mock_liq_hub" "$lcc_addr" "$recipient_two_addr" "$queue_amount_two"

  echo "Reading settled amount for the given lcc and recipient to ensure the settlement was paid out to the recipient"
  local total_settled
  total_settled="$(cast call "$mock_liq_hub" \
    "getTotalAmountSettled(address,address)(uint256)" \
    "$lcc_addr" \
    "$recipient_one_addr" \
    --rpc-url "$rpc_url")"
  total_settled="$(to_dec "$total_settled")"

  echo "total_settled for recipient one=$total_settled"
  if [ "$total_settled" = "0" ]; then
    echo "total_settled is 0, amount not settled for the given lcc and recipient yet"
    exit 1
  fi

  total_settled="$(cast call "$mock_liq_hub" \
    "getTotalAmountSettled(address,address)(uint256)" \
    "$lcc_addr" \
    "$recipient_two_addr" \
    --rpc-url "$rpc_url")"
  total_settled="$(to_dec "$total_settled")"
  echo "total_settled for recipient two=$total_settled"
  if [ "$total_settled" = "0" ]; then
    echo "total_settled is 0, amount not settled for the given lcc and recipient yet"
    exit 1
  fi
}

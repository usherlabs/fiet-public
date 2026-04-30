# shellcheck shell=bash
# Sourced after e2e-common.sh and deploy-related env vars are set.

# .inc.sh files (e2e-deploy.inc.sh, e2e-integration.inc.sh)
# Intended use: sourced from another script, not run as bash …/e2e-deploy.inc.sh.
# What they contain: Only function definitions (e.g. e2e_deploy, e2e_integration). No top-level “do the work” steps when sourced.
# Why they exist: So the same deploy/integration logic can be used in two ways:
# Standalone entrypoints (e2e-deploy.sh, e2e-integration.sh) source the .inc and call the function once.
# e2e.sh sources both .inc files in one shell, runs e2e_deploy then e2e_integration, so exports such as LIQUIDITY_HUB,
# BATCH_RECEIVER, and HUB_RSC set during deploy are still visible for integration (they would not carry over if deploy
# and integration were two separate bash processes).
#
# Do not declare HUB_RSC or BATCH_RECEIVER with `local`: `export` inside the function only promotes locals to the
# environment for child processes, not the caller's global scope, so integration would see empty HUB_RSC.

e2e_deploy() {
  local mock_out receiver_out hub_out
  local MOCK_LIQUIDITY_HUB

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

  receiver_out="$(run_and_print \
    "Deploying BatchProcessSettlement receiver..." \
    forge script scripts/DeployReceiver.s.sol:DeployReceiver \
      --rpc-url "$PROTOCOL_RPC" \
      $broadcast_flag)"

  BATCH_RECEIVER="$(extract_labeled_address "BatchProcessSettlementReceiver" "$receiver_out")"
  if [ -z "${BATCH_RECEIVER:-}" ]; then
    echo "Failed to parse BatchProcessSettlementReceiver address."
    echo "---- raw output ----"
    echo "$receiver_out"
    exit 1
  fi
  if [ "$(printf '%s' "$BATCH_RECEIVER" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$LIQUIDITY_HUB" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "BatchProcessSettlementReceiver address equals LIQUIDITY_HUB, refusing to continue: $BATCH_RECEIVER"
    echo "---- raw output ----"
    echo "$receiver_out"
    exit 1
  fi
  if ! wait_until "BatchProcessSettlementReceiver code on protocol chain" contract_code_exists "$BATCH_RECEIVER" "$PROTOCOL_RPC"; then
    echo "BatchProcessSettlementReceiver has no deployed code at: $BATCH_RECEIVER"
    echo "---- raw output ----"
    echo "$receiver_out"
    exit 1
  fi
  echo "BatchProcessSettlementReceiver deployed to: $BATCH_RECEIVER"
  export BATCH_RECEIVER

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

  wait_until "HubRSC code on reactive chain" contract_code_exists "$HUB_RSC" "$REACTIVE_RPC"

  cast send "$HUB_RSC" \
    "activateBaseSubscriptions()" \
    --rpc-url "$REACTIVE_RPC" \
    --private-key "$PRIVATE_KEY" >/dev/null
  echo "HubRSC base subscriptions activated"

  cast send "$HUB_RSC" \
    "registerRecipient(address)" \
    "$RECIPIENT_ONE" \
    --rpc-url "$REACTIVE_RPC" \
    --private-key "$PRIVATE_KEY" \
    --value "$RECIPIENT_DEPOSIT_WEI" >/dev/null
  cast send "$HUB_RSC" \
    "registerRecipient(address)" \
    "$RECIPIENT_TWO" \
    --rpc-url "$REACTIVE_RPC" \
    --private-key "$PRIVATE_KEY" \
    --value "$RECIPIENT_DEPOSIT_WEI" >/dev/null
  echo "Recipients registered and funded on HubRSC"
  wait_until "recipient one active on HubRSC" recipient_is_active "$HUB_RSC" "$RECIPIENT_ONE"
  wait_until "recipient two active on HubRSC" recipient_is_active "$HUB_RSC" "$RECIPIENT_TWO"

  if [ "${SUBSCRIPTION_PROPAGATION_SECONDS:-0}" -gt 0 ]; then
    echo "Waiting ${SUBSCRIPTION_PROPAGATION_SECONDS}s for live Reactive subscriptions to propagate..."
    sleep "$SUBSCRIPTION_PROPAGATION_SECONDS"
  fi

  echo "================== DEPLOYMENT COMPLETE ======================"
  echo "MockLiquidityHub:              $MOCK_LIQUIDITY_HUB"
  echo "BatchProcessSettlementReceiver: $BATCH_RECEIVER"
  echo "HubRSC:                        $HUB_RSC"
  echo "Recipient:                     $RECIPIENT_ONE"
}

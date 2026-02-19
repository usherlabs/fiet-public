#!/usr/bin/env bash
# deploys the hub rsc and hub callback on the reactive chain
set -euo pipefail

# Load local env overrides when present.
if [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

# Extracts the last deployed contract address from `forge create` output.
# Matches flexible formats, e.g. with leading spaces or extra log prefixes.
extract_deployed_address() {
  local forge_output="$1"
  printf '%s\n' "$forge_output" | sed -n 's/.*Deployed to:[[:space:]]*\(0x[a-fA-F0-9]\{40\}\).*/\1/p' | tail -n1
}

# Use one deployer key for both protocol- and reactive-chain deployments.
DEPLOYER_PRIVATE_KEY="${PRIVATE_KEY:-}"

# Required runtime configuration.
: "${REACTIVE_RPC:?REACTIVE_RPC is required}"
: "${DEPLOYER_PRIVATE_KEY:?PRIVATE_KEY is required}"
: "${PROTOCOL_CHAIN_ID:?PROTOCOL_CHAIN_ID is required}"
: "${REACTIVE_CHAIN_ID:?REACTIVE_CHAIN_ID is required}"
: "${LIQUIDITY_HUB:?LIQUIDITY_HUB is required}"
: "${PROTOCOL_RPC:?PROTOCOL_RPC is required}"
: "${BATCH_RECEIVER:?BATCH_RECEIVER is required}"
: "${REACTIVE_CALLBACK_PROXY:?REACTIVE_CALLBACK_PROXY is required}"

CALLBACK_PROXY="${REACTIVE_CALLBACK_PROXY}"

# Optional prefunding values for callback and hub deployments.
HUB_RSC_VALUE="${HUB_RSC_VALUE:-1ether}"
HUB_CALLBACK_VALUE="${HUB_CALLBACK_VALUE:-0.1ether}"
BROADCAST_FLAG="--broadcast"

# 1) Deploy HubCallback on the protocol chain (origin event emitter).
echo "Deploying HubCallback on protocol chain..."
hub_callback_output="$(
  forge create "$BROADCAST_FLAG" \
    --rpc-url "$REACTIVE_RPC" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    src/HubCallback.sol:HubCallback \
    --value "$HUB_CALLBACK_VALUE" \
    --constructor-args "$CALLBACK_PROXY" 2>&1
)"
echo "$hub_callback_output"

# Parse deployed callback address for use in the reactive-chain hub deployment.
HUB_CALLBACK="$(extract_deployed_address "$hub_callback_output")"
if [ -z "${HUB_CALLBACK:-}" ]; then
  echo "Failed to parse HubCallback address from forge output."
  echo "---- raw forge output (HubCallback) ----"
  echo "$hub_callback_output"
  exit 1
fi
echo "Parsed HUB_CALLBACK=$HUB_CALLBACK"

sleep 10

# 2) Deploy HubRSC on the reactive chain with the protocol callback address wired in.
echo "Deploying HubRSC with:"
echo "  REACTIVE_RPC=$REACTIVE_RPC"
echo "  PROTOCOL_CHAIN_ID=$PROTOCOL_CHAIN_ID"
echo "  REACTIVE_CHAIN_ID=$REACTIVE_CHAIN_ID"
echo "  LIQUIDITY_HUB=$LIQUIDITY_HUB"
echo "  HUB_CALLBACK=$HUB_CALLBACK"
echo "  BATCH_RECEIVER=$BATCH_RECEIVER"
echo "  HUB_RSC_VALUE=$HUB_RSC_VALUE"

hub_rsc_output="$(
  forge create "$BROADCAST_FLAG" \
    --rpc-url "$REACTIVE_RPC" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    src/HubRSC.sol:HubRSC \
    --value "$HUB_RSC_VALUE" \
    --constructor-args \
      "$PROTOCOL_CHAIN_ID" \
      "$REACTIVE_CHAIN_ID" \
      "$LIQUIDITY_HUB" \
      "$HUB_CALLBACK" \
      "$BATCH_RECEIVER" 2>&1
)"
echo "$hub_rsc_output"

HUB_RSC="$(extract_deployed_address "$hub_rsc_output")"
if [ -z "${HUB_RSC:-}" ]; then
  echo "Failed to parse HubRSC address from forge output."
  echo "---- raw forge output (HubRSC) ----"
  echo "$hub_rsc_output"
  exit 1
fi


# ensure to log the address of the deployed contract
# using the format contract_name:address
# that way it can be parsed from the stdout of the script execution
echo "========================================"
echo "HubCallback: $HUB_CALLBACK"
echo "HubRSC:      $HUB_RSC"

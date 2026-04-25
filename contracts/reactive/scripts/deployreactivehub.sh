#!/usr/bin/env bash
# deploys the hub rsc on the reactive chain
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

# Hub RVM id is the deployer address for this deployment flow.
DEPLOYER_ADDRESS="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
RVM_ID="$DEPLOYER_ADDRESS"
export RVM_ID

# Optional prefunding value for hub deployment.
HUB_RSC_VALUE="${HUB_RSC_VALUE:-1ether}"
BROADCAST_FLAG="--broadcast"

# Deploy HubRSC on the reactive chain.
echo "Deploying HubRSC with:"
echo "  REACTIVE_RPC=$REACTIVE_RPC"
echo "  PROTOCOL_CHAIN_ID=$PROTOCOL_CHAIN_ID"
echo "  REACTIVE_CHAIN_ID=$REACTIVE_CHAIN_ID"
echo "  LIQUIDITY_HUB=$LIQUIDITY_HUB"
echo "  BATCH_RECEIVER=$BATCH_RECEIVER"
echo "  HUB_RSC_VALUE=$HUB_RSC_VALUE"
echo "  RVM_ID=$RVM_ID"
echo "  BATCH_SIZE=${BATCH_SIZE:-20}"

hub_rsc_output="$(
  forge create "$BROADCAST_FLAG" \
    --rpc-url "$REACTIVE_RPC" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    src/HubRSC.sol:HubRSC \
    --value "$HUB_RSC_VALUE" \
    --constructor-args \
      "${BATCH_SIZE:-20}" \
      "$PROTOCOL_CHAIN_ID" \
      "$REACTIVE_CHAIN_ID" \
      "$LIQUIDITY_HUB" \
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
echo "RVM_ID:     $RVM_ID"
echo "HubRSC:      $HUB_RSC"

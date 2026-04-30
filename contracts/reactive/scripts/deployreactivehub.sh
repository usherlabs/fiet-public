#!/usr/bin/env bash
# deploys the hub rsc on the reactive chain
set -euo pipefail

# Load local env defaults when present, but preserve any values already
# provided by the caller (for example `test/e2e.sh` exporting fresh deploy
# addresses for `LIQUIDITY_HUB` and `BATCH_RECEIVER`).
preserve_env_var() {
  local name="$1"
  local marker_var="PRESERVED_${name}__SET"
  local value_var="PRESERVED_${name}__VALUE"
  if [ "${!name+x}" = "x" ]; then
    printf -v "$marker_var" '%s' "1"
    printf -v "$value_var" '%s' "${!name}"
  fi
}

restore_env_var() {
  local name="$1"
  local marker_var="PRESERVED_${name}__SET"
  local value_var="PRESERVED_${name}__VALUE"
  if [ "${!marker_var:-}" = "1" ]; then
    export "$name=${!value_var}"
  fi
}

for env_name in \
  REACTIVE_RPC \
  PRIVATE_KEY \
  PROTOCOL_CHAIN_ID \
  REACTIVE_CHAIN_ID \
  LIQUIDITY_HUB \
  PROTOCOL_RPC \
  BATCH_RECEIVER \
  REACTIVE_CALLBACK_PROXY \
  HUB_RSC_VALUE \
  HUB_RVM_ID \
  BATCH_SIZE; do
  preserve_env_var "$env_name"
done

if [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

for env_name in \
  REACTIVE_RPC \
  PRIVATE_KEY \
  PROTOCOL_CHAIN_ID \
  REACTIVE_CHAIN_ID \
  LIQUIDITY_HUB \
  PROTOCOL_RPC \
  BATCH_RECEIVER \
  REACTIVE_CALLBACK_PROXY \
  HUB_RSC_VALUE \
  HUB_RVM_ID \
  BATCH_SIZE; do
  restore_env_var "$env_name"
done

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

# Authorised caller for `applyCanonicalProtocolLog` on the canonical Reactive deployment (Reactive chain).
# Defaults to the Reactive system contract address, which is the published callback executor on Lasna/Reactive testnets.
REACTIVE_CALLBACK_PROXY="${REACTIVE_CALLBACK_PROXY:-0x0000000000000000000000000000000000fffFfF}"

# Hub RVM id is the deployer address for this deployment flow.
DEPLOYER_ADDRESS="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
HUB_RVM_ID="$DEPLOYER_ADDRESS"
export HUB_RVM_ID

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
echo "  REACTIVE_CALLBACK_PROXY=$REACTIVE_CALLBACK_PROXY"
echo "  HUB_RSC_VALUE=$HUB_RSC_VALUE"
echo "  HUB_RVM_ID=$HUB_RVM_ID"
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
      "$BATCH_RECEIVER" \
      "$REACTIVE_CALLBACK_PROXY" 2>&1
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
echo "HUB_RVM_ID: $HUB_RVM_ID"
echo "HubRSC:      $HUB_RSC"

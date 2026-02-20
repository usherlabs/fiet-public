#!/usr/bin/env bash
# deploys the spoke rsc on the reactive chain
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

# Use one deployer key for spoke deployment.
DEPLOYER_PRIVATE_KEY="${PRIVATE_KEY:-}"
RECIPIENT="${1:-${RECIPIENT:-}}"

# Required runtime configuration.
: "${REACTIVE_RPC:?REACTIVE_RPC is required}"
: "${DEPLOYER_PRIVATE_KEY:?PRIVATE_KEY is required}"
: "${PROTOCOL_CHAIN_ID:?PROTOCOL_CHAIN_ID is required}"
: "${REACTIVE_CHAIN_ID:?REACTIVE_CHAIN_ID is required}"
: "${LIQUIDITY_HUB:?LIQUIDITY_HUB is required}"
: "${HUB_CALLBACK:?HUB_CALLBACK is required}"
: "${RECIPIENT:?RECIPIENT is required}"

# Optional prefunding for the spoke deployment.
SPOKE_VALUE="${SPOKE_VALUE:-1ether}"

echo "Deploying SpokeRSC with:"
echo "  REACTIVE_RPC=$REACTIVE_RPC"
echo "  PROTOCOL_CHAIN_ID=$PROTOCOL_CHAIN_ID"
echo "  REACTIVE_CHAIN_ID=$REACTIVE_CHAIN_ID"
echo "  LIQUIDITY_HUB=$LIQUIDITY_HUB"
echo "  HUB_CALLBACK=$HUB_CALLBACK"
echo "  RECIPIENT=$RECIPIENT"
echo "  SPOKE_VALUE=$SPOKE_VALUE"

set +e
spoke_output="$(
  forge create --broadcast \
    --rpc-url "$REACTIVE_RPC" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    src/SpokeRSC.sol:SpokeRSC \
    --value "$SPOKE_VALUE" \
    --constructor-args \
      "$PROTOCOL_CHAIN_ID" \
      "$REACTIVE_CHAIN_ID" \
      "$LIQUIDITY_HUB" \
      "$HUB_CALLBACK" \
      "$RECIPIENT" 2>&1
)"
forge_status=$?
set -e
echo "$spoke_output"

if [ "$forge_status" -ne 0 ]; then
  echo "SpokeRSC deployment failed (forge exit code: $forge_status)."
  exit "$forge_status"
fi

SPOKE_RSC="$(extract_deployed_address "$spoke_output")"
if [ -z "${SPOKE_RSC:-}" ]; then
  echo "Failed to parse SpokeRSC address from forge output."
  echo "---- raw forge output ----"
  echo "$spoke_output"
  exit 1
fi


# ensure to log the address of the deployed contract
# using the format contract_name:address
# that way it can be parsed from the stdout of the script execution
echo "========================================"
echo "SpokeRSC: $SPOKE_RSC"

#!/usr/bin/env bash
set -euo pipefail

# Load local env overrides when present.
if [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

HUB_RSC="${1:-${HUB_RSC:-}}"
REACTIVE_RPC="${REACTIVE_RPC:-}"
REACTIVE_PRIVATE_KEY="${PRIVATE_KEY:-}"

: "${HUB_RSC:?HUB_RSC is required (arg1 or HUB_RSC)}"
: "${REACTIVE_RPC:?REACTIVE_RPC is required}"
: "${REACTIVE_PRIVATE_KEY:?PRIVATE_KEY is required}"

echo "Activating HubRSC base subscriptions"
echo "  hub: $HUB_RSC"
echo "  rpc: $REACTIVE_RPC"

base_subscriptions_active="$(cast call \
  "$HUB_RSC" \
  "baseSubscriptionsActive()(bool)" \
  --rpc-url "$REACTIVE_RPC" | tr '[:upper:]' '[:lower:]')"

if [ "$base_subscriptions_active" = "true" ]; then
  echo "  Base subscriptions already active."
  exit 0
fi

cast send \
  --rpc-url "$REACTIVE_RPC" \
  --private-key "$REACTIVE_PRIVATE_KEY" \
  "$HUB_RSC" \
  "activateBaseSubscriptions()"

echo "  Base subscriptions activation submitted."

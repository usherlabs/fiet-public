#!/usr/bin/env bash
set -euo pipefail

# Load local env overrides when present.
if [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

HUB_RSC="${HUB_RSC:-}"
RECIPIENT="${1:-${RECIPIENT:-}}"
AMOUNT_WEI="${2:-${RECIPIENT_DEPOSIT_WEI:-100000000000000000}}"
REACTIVE_RPC="${REACTIVE_RPC:-}"
REACTIVE_PRIVATE_KEY="${PRIVATE_KEY:-}"

: "${HUB_RSC:?HUB_RSC is required}"
: "${RECIPIENT:?recipient is required (arg1 or RECIPIENT)}"
: "${AMOUNT_WEI:?amount in wei is required (arg2 or RECIPIENT_DEPOSIT_WEI)}"
: "${REACTIVE_RPC:?REACTIVE_RPC is required}"
: "${REACTIVE_PRIVATE_KEY:?PRIVATE_KEY is required}"

echo "Funding HubRSC recipient"
echo "  hub:          $HUB_RSC"
echo "  recipient:    $RECIPIENT"
echo "  amount (wei): $AMOUNT_WEI"
echo "  rpc:          $REACTIVE_RPC"

cast send \
  --rpc-url "$REACTIVE_RPC" \
  --private-key "$REACTIVE_PRIVATE_KEY" \
  "$HUB_RSC" \
  "fundRecipient(address)" \
  "$RECIPIENT" \
  --value "$AMOUNT_WEI"

echo "  Recipient top-up submitted."

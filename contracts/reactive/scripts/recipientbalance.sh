#!/usr/bin/env bash
set -euo pipefail

# Load local env overrides when present.
if [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

SYSTEM_CONTRACT_ADDR="0x0000000000000000000000000000000000fffFfF"
HUB_RSC="${HUB_RSC:-}"
RECIPIENT="${1:-${RECIPIENT:-}}"
REACTIVE_RPC="${REACTIVE_RPC:-}"

: "${HUB_RSC:?HUB_RSC is required}"
: "${RECIPIENT:?recipient is required (arg1 or RECIPIENT)}"
: "${REACTIVE_RPC:?REACTIVE_RPC is required}"

call_hub() {
  cast call "$HUB_RSC" "$@" --rpc-url "$REACTIVE_RPC"
}

to_dec() {
  local value
  value="$(printf '%s\n' "${1:-}" | sed -n '1p' | tr -d '[:space:]')"
  if [ -z "$value" ]; then
    printf '0'
  elif [[ "$value" == 0x* ]]; then
    cast to-dec "$value" 2>/dev/null || printf '0'
  else
    printf '%s' "$value"
  fi
}

registered="$(call_hub "recipientRegistered(address)(bool)" "$RECIPIENT")"
active="$(call_hub "recipientActive(address)(bool)" "$RECIPIENT")"
recipient_balance="$(call_hub "recipientBalance(address)(int256)" "$RECIPIENT")"
hub_native_balance="$(cast balance "$HUB_RSC" --rpc-url "$REACTIVE_RPC" 2>/dev/null || true)"
hub_reserves="$(to_dec "$(cast call "$SYSTEM_CONTRACT_ADDR" "reserves(address)(uint256)" "$HUB_RSC" --rpc-url "$REACTIVE_RPC" 2>/dev/null || true)")"
hub_debts="$(to_dec "$(cast call "$SYSTEM_CONTRACT_ADDR" "debts(address)(uint256)" "$HUB_RSC" --rpc-url "$REACTIVE_RPC" 2>/dev/null || true)")"

echo "HubRSC recipient balance"
echo "  hub:                     $HUB_RSC"
echo "  recipient:               $RECIPIENT"
echo "  registered:              $registered"
echo "  active:                  $active"
echo "  recipientBalance (wei):  $recipient_balance"
echo "  hub native balance:      ${hub_native_balance:-unknown}"
echo "  hub system reserves:     $hub_reserves"
echo "  hub system debts:        $hub_debts"

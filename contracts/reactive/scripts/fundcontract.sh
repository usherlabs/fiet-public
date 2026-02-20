#!/usr/bin/env bash
set -euo pipefail

# Load local env overrides when present.
if [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

# Reactive Network system contract (also callback proxy on reactive chain).
SYSTEM_CONTRACT_ADDR="0x0000000000000000000000000000000000fffFfF"

CONTRACT_ADDR="${1:-${CONTRACT_ADDR:-}}"
AMOUNT_WEI="${2:-${AMOUNT_WEI:-1000000000000000000}}"
REACTIVE_RPC="${REACTIVE_RPC:-}"
REACTIVE_PRIVATE_KEY="${PRIVATE_KEY:-}"

: "${CONTRACT_ADDR:?contract address is required (arg1 or CONTRACT_ADDR)}"
: "${AMOUNT_WEI:?amount in wei is required (arg2 or AMOUNT_WEI)}"
: "${REACTIVE_RPC:?REACTIVE_RPC is required}"
: "${REACTIVE_PRIVATE_KEY:?PRIVATE_KEY is required}"

# Uses Python bigint arithmetic to avoid Bash 64-bit overflow.
big_int_sub() {
  python3 - "$1" "$2" <<'PY'
import sys

a = int(sys.argv[1], 10)
b = int(sys.argv[2], 10)
print(a - b)
PY
}

echo "Funding reactive contract deposit"
echo "  system contract: $SYSTEM_CONTRACT_ADDR"
echo "  contract:        $CONTRACT_ADDR"
echo "  amount (wei):    $AMOUNT_WEI"
echo "  rpc:             $REACTIVE_RPC"


reserves_before="$(cast call "$SYSTEM_CONTRACT_ADDR" "reserves(address)" "$CONTRACT_ADDR" --rpc-url "$REACTIVE_RPC" | cast to-dec)"
contract_balance_before="$(cast balance "$CONTRACT_ADDR" --rpc-url "$REACTIVE_RPC")"
contract_debt_before="$(cast call "$SYSTEM_CONTRACT_ADDR" "debts(address)" "$CONTRACT_ADDR" --rpc-url "$REACTIVE_RPC" | cast to-dec)"

cast send \
  --rpc-url "$REACTIVE_RPC" \
  --private-key "$REACTIVE_PRIVATE_KEY" \
  "$SYSTEM_CONTRACT_ADDR" \
  "depositTo(address)" \
  "$CONTRACT_ADDR" \
  --value "$AMOUNT_WEI"
reserves_after="$(cast call "$SYSTEM_CONTRACT_ADDR" "reserves(address)" "$CONTRACT_ADDR" --rpc-url "$REACTIVE_RPC" | cast to-dec)"
contract_balance_after="$(cast balance "$CONTRACT_ADDR" --rpc-url "$REACTIVE_RPC")"
contract_debt_after="$(cast call "$SYSTEM_CONTRACT_ADDR" "debts(address)" "$CONTRACT_ADDR" --rpc-url "$REACTIVE_RPC" | cast to-dec)"

echo "  Funding of contract $CONTRACT_ADDR with $AMOUNT_WEI wei successfully."
echo "  ================= reserves========================"
echo  "  reserves before: $reserves_before wei"
echo "  reserves after:  $reserves_after wei"
echo "  reserves delta:  $(big_int_sub "$reserves_after" "$reserves_before") wei"
echo "  ================= contract balance ========================"
echo "  contract balance before: $contract_balance_before wei"
echo "  contract balance after:  $contract_balance_after wei"
echo "  contract balance delta:  $(big_int_sub "$contract_balance_after" "$contract_balance_before") wei"
echo "  ================= contract debt ========================"
echo "  contract debt before:    $contract_debt_before wei"
echo "  contract debt after:     $contract_debt_after wei"
echo "  contract debt delta:     $(big_int_sub "$contract_debt_after" "$contract_debt_before") wei"

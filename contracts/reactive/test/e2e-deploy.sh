#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e-common.sh
source "$SCRIPT_DIR/e2e-common.sh"

if [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

REACTIVE_RPC="${REACTIVE_RPC:-}"
PROTOCOL_RPC="${PROTOCOL_RPC:-}"
PRIVATE_KEY="${PRIVATE_KEY:-${REACTIVE_CI_PRIVATE_KEY:-}}"
DEPLOY_DEBUG="${DEBUG:-false}"
RECIPIENT_ONE="${RECIPIENT_ONE:-0xb797466544DeB18F1e19185e85400A26FC5d3E95}"
RECIPIENT_TWO="${RECIPIENT_TWO:-0xa4260A121bC44d085AC9a18e628A5712Ef3Bd49C}"
RECIPIENT_DEPOSIT_WEI="${RECIPIENT_DEPOSIT_WEI:-100000000000000000}"
export BROADCAST=true

: "${REACTIVE_RPC:?REACTIVE_RPC is required}"
: "${PROTOCOL_RPC:?PROTOCOL_RPC is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"
: "${RECIPIENT_ONE:?RECIPIENT_ONE is required}"
: "${RECIPIENT_TWO:?RECIPIENT_TWO is required}"

HUB_RVM_ID="$(cast wallet address --private-key "$PRIVATE_KEY")"
export HUB_RVM_ID

broadcast_flag=""
if [ "$BROADCAST" = "true" ]; then
  broadcast_flag="--broadcast"
fi

# shellcheck source=e2e-deploy.inc.sh
source "$SCRIPT_DIR/e2e-deploy.inc.sh"
e2e_deploy

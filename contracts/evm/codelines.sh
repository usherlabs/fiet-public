#!/usr/bin/env bash
set -euo pipefail

# Compatibility shim:
# `develop` expects this script at `contracts/evm/codelines.sh`.
# The maintained implementation lives at `contracts/evm/scripts/codelines.sh`.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/scripts/codelines.sh" "$@"


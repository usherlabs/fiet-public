#!/bin/bash

# Reference: https://github.com/hyperlane-xyz/hyperlane-monorepo/blob/main/solidity/coverage.sh

# exit on error
set -e

forge coverage \
    --report lcov \
    --report summary \
    --no-match-coverage "(test|mock|node_modules|script|Fast|TypedMemView)" \
    --no-match-test "Fork" \
    --no-match-contract "Fork"

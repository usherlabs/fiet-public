// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library TransientSlots {
    bytes32 internal constant TRACING_FLAG_SLOT = keccak256("TRACING_FLAG");
    bytes32 internal constant CURRENT_MARKET_SLOT = keccak256("CURRENT_MARKET");
    bytes32 internal constant SWAP_DELTA_SLOT = keccak256("SWAP_DELTA");
    bytes32 internal constant PROXY_SWAP_FLAG_SLOT = keccak256("PROXY_SWAP_FLAG");
    bytes32 internal constant SQRTP_BEFORE_SLOT = keccak256("SQRTP_BEFORE");
}

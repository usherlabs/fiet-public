// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @notice Shared topics and callback selectors for reactive settlement flow.
library ReactiveConstants {
    // Liquidity events.
    uint256 internal constant LIQUIDITY_AVAILABLE_TOPIC =
        uint256(keccak256("LiquidityAvailable(address,address,uint256,bytes32)"));
    uint256 internal constant MORE_LIQUIDITY_AVAILABLE_TOPIC =
        uint256(keccak256("MoreLiquidityAvailable(address,uint256)"));
    /// @notice LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId).
    uint256 internal constant LCC_CREATED_TOPIC = uint256(keccak256("LCCCreated(address,address,bytes32)"));

    // Protocol-chain lifecycle events observed by HubRSC.
    uint256 internal constant SETTLEMENT_QUEUED_TOPIC = uint256(keccak256("SettlementQueued(address,address,uint256)"));
    uint256 internal constant SETTLEMENT_ANNULLED_TOPIC =
        uint256(keccak256("SettlementAnnulled(address,address,uint256)"));
    uint256 internal constant SETTLEMENT_PROCESSED_TOPIC =
        uint256(keccak256("SettlementProcessed(address,address,uint256,uint256)"));
    uint256 internal constant SETTLEMENT_SUCCEEDED_TOPIC =
        uint256(keccak256("SettlementSucceeded(address,address,uint256,uint256)"));
    uint256 internal constant SETTLEMENT_FAILED_TOPIC =
        uint256(keccak256("SettlementFailed(address,address,uint256,uint256,bytes)"));

    // Destination receiver function selector used for callbacks.
    bytes4 internal constant PROCESS_SETTLEMENTS_SELECTOR =
        bytes4(keccak256("processSettlements(address,address[],address[],uint256[],uint256[])"));
}

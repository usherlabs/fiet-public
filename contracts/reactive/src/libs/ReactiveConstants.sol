// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @notice Shared topics and callback selectors for reactive settlement flow.
library ReactiveConstants {
    // Liquidity events.
    uint256 internal constant LIQUIDITY_AVAILABLE_TOPIC =
        uint256(keccak256("LiquidityAvailable(address,address,uint256,bytes32)"));
    uint256 internal constant MORE_LIQUIDITY_AVAILABLE_TOPIC =
        uint256(keccak256("MoreLiquidityAvailable(address,uint256)"));

    // Protocol-chain events observed by SpokeRSC.
    uint256 internal constant SETTLEMENT_QUEUED_TOPIC = uint256(keccak256("SettlementQueued(address,address,uint256)"));
    uint256 internal constant SETTLEMENT_ANNULLED_TOPIC =
        uint256(keccak256("SettlementAnnulled(address,address,uint256)"));
    uint256 internal constant SETTLEMENT_PROCESSED_TOPIC =
        uint256(keccak256("SettlementProcessed(address,address,uint256)"));
    uint256 internal constant SETTLEMENT_FAILED_TOPIC =
        uint256(keccak256("SettlementFailed(address,address,uint256,bytes)"));
    uint256 internal constant SETTLEMENT_QUEUED_REPORTED_TOPIC =
        uint256(keccak256("SettlementQueuedReported(address,address,uint256,uint256)"));
    uint256 internal constant SETTLEMENT_ANNULLED_REPORTED_TOPIC =
        uint256(keccak256("SettlementAnnulledReported(address,address,uint256)"));
    uint256 internal constant SETTLEMENT_PROCESSED_REPORTED_TOPIC =
        uint256(keccak256("SettlementProcessedReported(address,address,uint256)"));
    uint256 internal constant SETTLEMENT_FAILED_REPORTED_TOPIC =
        uint256(keccak256("SettlementFailedReported(address,address,uint256)"));

    // HubCallback function selectors used for callbacks.
    bytes4 internal constant RECORD_SETTLEMENT_QUEUED_SELECTOR =
        bytes4(keccak256("recordSettlementQueued(address,address,address,uint256,uint256)"));
    bytes4 internal constant RECORD_SETTLEMENT_ANNULLED_SELECTOR =
        bytes4(keccak256("recordSettlementAnnulled(address,address,address,uint256,uint256)"));
    bytes4 internal constant RECORD_SETTLEMENT_PROCESSED_SELECTOR =
        bytes4(keccak256("recordSettlementProcessed(address,address,address,uint256,uint256)"));
    bytes4 internal constant RECORD_SETTLEMENT_FAILED_SELECTOR =
        bytes4(keccak256("recordSettlementFailed(address,address,address,uint256,uint256)"));
    bytes4 internal constant PROCESS_SETTLEMENTS_SELECTOR =
        bytes4(keccak256("processSettlements(address,address[],address[],uint256[])"));
    bytes4 internal constant TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR =
        bytes4(keccak256("triggerMoreLiquidityAvailable(address,address,uint256)"));
}

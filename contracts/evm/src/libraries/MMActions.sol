// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @notice Library to define MM Position Manager actions
/// @dev These action codes are used by MMPositionManager and MMPMActions for action dispatch
/// @dev Actions < SETTLE_POSITION_FROM_DELTAS + 1 are delegated to MMPMActionsImpl (position operations)
/// @dev Actions >= COMMIT_SIGNAL and < TAKE are handled in MMPositionManager (commitments)
/// @dev Actions >= TAKE are handled in MMPositionManager (utilities)
library MMActions {
    // ═══════════════════════════════════════════════════════════════════════════
    // POSITION OPERATIONS (0x00-0x09) - Delegated to MMPMActionsImpl
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Settle underlying assets to/from a position
    uint256 internal constant SETTLE_POSITION = 0x00;

    /// @notice Mint a new position within a commitment
    uint256 internal constant MINT_POSITION = 0x01;

    /// @notice Increase liquidity in an existing position
    uint256 internal constant INCREASE_LIQUIDITY = 0x02;

    /// @notice Decrease liquidity from an existing position
    uint256 internal constant DECREASE_LIQUIDITY = 0x03;

    /// @notice Burn (fully decrease) a position
    uint256 internal constant BURN_POSITION = 0x04;

    /// @notice Seize a position (third-party guarantor action)
    uint256 internal constant SEIZE_POSITION = 0x05;

    /// @notice Increase liquidity using available delta credits
    uint256 internal constant INCREASE_LIQUIDITY_FROM_DELTAS = 0x07;

    /// @notice Mint a new position using available delta credits
    uint256 internal constant MINT_POSITION_FROM_DELTAS = 0x08;

    /// @notice Settle a position using available delta credits
    uint256 internal constant SETTLE_POSITION_FROM_DELTAS = 0x09;

    // ═══════════════════════════════════════════════════════════════════════════
    // COMMITMENT OPERATIONS (0x20-0x23) - Handled in MMPositionManager
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Commit a new liquidity signal and mint commitment NFT
    uint256 internal constant COMMIT_SIGNAL = 0x20;

    /// @notice Renew an existing signal with new parameters
    uint256 internal constant RENEW_SIGNAL = 0x21;

    /// @notice Decommit a signal and burn the commitment NFT
    uint256 internal constant DECOMMIT_SIGNAL = 0x22;

    /// @notice Checkpoint a position (optionally run commitment backing check)
    uint256 internal constant CHECKPOINT = 0x23;

    /// @notice Extend grace period for a commitment via proof
    uint256 internal constant EXTEND_GRACE_PERIOD = 0x24;

    // ═══════════════════════════════════════════════════════════════════════════
    // CURRENCY/UTILITY OPERATIONS (0x40+) - Handled in MMPositionManager
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Take currency from delta and transfer to recipient
    uint256 internal constant TAKE = 0x40;

    /// @notice Unwrap LCC tokens to underlying asset
    uint256 internal constant UNWRAP_LCC = 0x41;

    /// @notice Wrap native ETH to WETH
    uint256 internal constant WRAP_NATIVE = 0x42;

    /// @notice Unwrap WETH to native ETH
    uint256 internal constant UNWRAP_NATIVE = 0x43;

    /// @notice Collect available liquidity from settlement queue
    uint256 internal constant COLLECT_AVAILABLE_LIQUIDITY = 0x44;
}


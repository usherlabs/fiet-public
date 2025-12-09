// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Library to define MM Position Manager actions
/// @dev These action codes are used by MMPositionManager and MMPMActions for action dispatch
library MMActions {
    // ═══════════════════════════════════════════════════════════════════════════
    // Signal Management
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Commit a new liquidity signal and mint commitment NFT
    uint256 internal constant COMMIT_SIGNAL = 0x00;

    /// @notice Renew an existing signal with new parameters
    uint256 internal constant RENEW_SIGNAL = 0x06;

    /// @notice Decommit a signal and burn the commitment NFT
    uint256 internal constant DECOMMIT_SIGNAL = 0x09;

    /// @notice Declare a commitment as unbacked (third-party guarantor action)
    uint256 internal constant DECLARE_UNBACKED_COMMITMENT = 0x12;

    // ═══════════════════════════════════════════════════════════════════════════
    // Position Lifecycle
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Mint a new position within a commitment
    uint256 internal constant MINT_POSITION = 0x01;

    /// @notice Mint a new position using available delta credits
    uint256 internal constant MINT_POSITION_FROM_DELTAS = 0x10;

    /// @notice Burn (fully decrease) a position
    uint256 internal constant BURN_POSITION = 0x05;

    // ═══════════════════════════════════════════════════════════════════════════
    // Liquidity Operations
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Increase liquidity in an existing position
    uint256 internal constant INCREASE_LIQUIDITY = 0x03;

    /// @notice Increase liquidity using available delta credits
    uint256 internal constant INCREASE_LIQUIDITY_FROM_DELTAS = 0x0f;

    /// @notice Decrease liquidity from an existing position
    uint256 internal constant DECREASE_LIQUIDITY = 0x04;

    // ═══════════════════════════════════════════════════════════════════════════
    // Settlement Operations
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Settle underlying assets to/from a position
    uint256 internal constant SETTLE_POSITION = 0x02;

    /// @notice Settle a position using available delta credits
    uint256 internal constant SETTLE_POSITION_FROM_DELTAS = 0x11;

    /// @notice Extend grace period for a position via proof
    uint256 internal constant EXTEND_GRACE_PERIOD = 0x0d;

    // ═══════════════════════════════════════════════════════════════════════════
    // Seizure Operations
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Seize a position (third-party guarantor action)
    uint256 internal constant SEIZE_POSITION = 0x07;

    /// @notice Seize an entire commitment
    uint256 internal constant SEIZE_COMMITMENT = 0x08;

    // ═══════════════════════════════════════════════════════════════════════════
    // Currency Operations
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Unwrap LCC tokens to underlying asset
    uint256 internal constant UNWRAP_LCC = 0x0a;

    /// @notice Wrap native ETH to WETH
    uint256 internal constant WRAP_NATIVE = 0x0b;

    /// @notice Unwrap WETH to native ETH
    uint256 internal constant UNWRAP_NATIVE = 0x0c;

    /// @notice Take currency from delta and transfer to recipient
    uint256 internal constant TAKE = 0x0e;

    /// @notice Collect available liquidity from settlement queue
    uint256 internal constant COLLECT_AVAILABLE_LIQUIDITY = 0x13;
}


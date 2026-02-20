// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";

/// @notice Reactive-free settlement processor shared by destination receivers.
abstract contract AbstractBatchProcessSettlement {
    error InvalidArrayLengths();
    error BatchTooLarge(uint256 length, uint256 maxLength);

    /// @notice Emitted when a batch is received.
    event BatchReceived(uint256 count);
    /// @notice Emitted when a settlement call succeeds.
    event SettlementSucceeded(address indexed lcc, address indexed recipient, uint256 maxAmount);
    /// @notice Emitted when a settlement call fails.
    event SettlementFailed(address indexed lcc, address indexed recipient, uint256 maxAmount, bytes reason);

    /// @notice Max number of items allowed per batch.
    uint256 public constant MAX_BATCH_SIZE = 30;

    /// @notice LiquidityHub to call on the destination chain.
    ILiquidityHub public immutable liquidityHub;

    /// @param _liquidityHub LiquidityHub to call on the destination chain.
    constructor(address _liquidityHub) {
        liquidityHub = ILiquidityHub(_liquidityHub);
    }

    /// @notice Process a batch of settlement requests.
    /// @param lcc Array of LCC token addresses.
    /// @param recipient Array of recipients.
    /// @param maxAmount Array of max amounts to settle.
    /// @dev Internal logic intended to be wrapped by protocol-specific access control.
    /// @custom:emits BatchReceived, SettlementSucceeded, SettlementFailed
    function processSettlements(address[] memory lcc, address[] memory recipient, uint256[] memory maxAmount) internal {
        uint256 count = lcc.length;
        if (recipient.length != count || maxAmount.length != count) {
            revert InvalidArrayLengths();
        }
        if (count > MAX_BATCH_SIZE) {
            revert BatchTooLarge(count, MAX_BATCH_SIZE);
        }

        emit BatchReceived(count);

        for (uint256 i = 0; i < count; i++) {
            try liquidityHub.processSettlementFor(lcc[i], recipient[i], maxAmount[i]) {
                emit SettlementSucceeded(lcc[i], recipient[i], maxAmount[i]);
            } catch (bytes memory reason) {
                emit SettlementFailed(lcc[i], recipient[i], maxAmount[i], reason);
            }
        }
    }
}

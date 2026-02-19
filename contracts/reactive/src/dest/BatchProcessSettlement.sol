// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {AbstractBatchProcessSettlement} from "evm/periphery/BatchProcessSettlement.sol";
import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";

/// @notice Reactive destination receiver that batches settlement processing.
contract BatchProcessSettlement is AbstractBatchProcessSettlement, AbstractCallback {
    /// @param _callbackProxy Reactive callback proxy address for this chain.
    /// https://dev.reactive.network/origins-and-destinations#testnet-chains
    /// @param _liquidityHub LiquidityHub to call on the destination chain.
    constructor(address _callbackProxy, address _liquidityHub)
        payable
        AbstractBatchProcessSettlement(_liquidityHub)
        AbstractCallback(_callbackProxy)
    {}

    /// @notice Process a batch of settlement requests received from Reactive callbacks.
    /// @param callbackOrigin Originating callback contract address from the source chain.
    /// @param lcc Array of LCC token addresses.
    /// @param recipient Array of recipients.
    /// @param maxAmount Array of max amounts to settle.
    /// @dev Continues on individual failures and emits per-item success/failure.
    /// @custom:emits BatchReceived, SettlementSucceeded, SettlementFailed
    function processSettlements(
        address callbackOrigin,
        address[] memory lcc,
        address[] memory recipient,
        uint256[] memory maxAmount
    ) external authorizedSenderOnly {
        callbackOrigin;
        processSettlements(lcc, recipient, maxAmount);
    }
}

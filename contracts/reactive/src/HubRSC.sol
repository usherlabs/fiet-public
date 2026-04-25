// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {HubRSCDispatch} from "./hub/HubRSCDispatch.sol";
import {HubRSCStorage} from "./hub/HubRSCStorage.sol";

/// @notice Hub RSC facade that mirrors authoritative protocol settlement state and dispatches settlements.
contract HubRSC is HubRSCDispatch {
    constructor(
        uint256 _maxDispatchItems,
        uint256 _protocolChainId,
        uint256 _reactChainId,
        address _liquidityHub,
        address _hubCallback,
        address _destinationReceiverContract
    )
        payable
        HubRSCStorage(
            _maxDispatchItems,
            _protocolChainId,
            _reactChainId,
            _liquidityHub,
            _hubCallback,
            _destinationReceiverContract
        )
    {
        if (!vm) {
            service.subscribe(
                protocolChainId, liquidityHub, LCC_CREATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
            service.subscribe(
                protocolChainId,
                liquidityHub,
                LIQUIDITY_AVAILABLE_TOPIC,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            service.subscribe(
                protocolChainId,
                liquidityHub,
                SETTLEMENT_QUEUED_TOPIC,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            service.subscribe(
                protocolChainId,
                liquidityHub,
                SETTLEMENT_ANNULLED_TOPIC,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            service.subscribe(
                protocolChainId,
                liquidityHub,
                SETTLEMENT_PROCESSED_TOPIC,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            service.subscribe(
                reactChainId,
                hubCallback,
                MORE_LIQUIDITY_AVAILABLE_TOPIC,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            service.subscribe(
                protocolChainId,
                destinationReceiverContract,
                SETTLEMENT_SUCCEEDED_TOPIC,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            service.subscribe(
                protocolChainId,
                destinationReceiverContract,
                SETTLEMENT_FAILED_TOPIC,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    /// @notice Returns the released-success and early-processed ordering state held on a pending key.
    function reconciliationStateByKey(bytes32 key) external view returns (uint256, uint256) {
        return (_completedAwaitingProcessedByKey[key], _processedRequestedCreditByKey[key]);
    }

    /// @notice Returns the current retry-block state for a key.
    function retryBlockStateByKey(bytes32 key, address lcc)
        external
        view
        returns (uint256 blockedAtWakeEpoch, bool active)
    {
        blockedAtWakeEpoch = _retryBlockedAtWakeEpochByKey[key];
        active = _isRetryBlocked(key, lcc);
    }

    /// @notice Returns the mutable pending amount and existence bit tracked for a key.
    function pendingStateByKey(bytes32 key) external view returns (uint256, bool) {
        Pending storage entry = pending[key];
        return (entry.amount, entry.exists);
    }

    /// @notice Returns buffered authoritative processed decreases awaiting pending creation.
    function bufferedProcessedStateByKey(bytes32 key) external view returns (uint256, uint256) {
        BufferedProcessedSettlement storage buffered = bufferedProcessedDecreaseByKey[key];
        return (buffered.settledAmount, buffered.inflightAmountToReduce);
    }

    /// @notice Returns the remaining reserved amount tracked for a dispatch attempt.
    function attemptReservationAmountById(uint256 attemptId) external view returns (uint256) {
        return _attemptReservationById[attemptId].amount;
    }

    /// @notice React to origin chain logs (ReactVM only).
    function react(IReactive.LogRecord calldata log) external vmOnly {
        if (log.topic_0 == LCC_CREATED_TOPIC) {
            _handleLccCreated(log);
            return;
        }

        if (log.topic_0 == SETTLEMENT_QUEUED_TOPIC) {
            _handleSettlementQueued(log);
            return;
        }

        if (log.topic_0 == LIQUIDITY_AVAILABLE_TOPIC) {
            _handleLiquidityAvailable(log);
            return;
        }

        if (log.topic_0 == MORE_LIQUIDITY_AVAILABLE_TOPIC) {
            _handleMoreLiquidityAvailable(log);
            return;
        }

        if (log.topic_0 == SETTLEMENT_ANNULLED_TOPIC) {
            _handleSettlementAnnulled(log);
            return;
        }

        if (log.topic_0 == SETTLEMENT_PROCESSED_TOPIC) {
            _handleSettlementProcessed(log);
            return;
        }

        if (log.topic_0 == SETTLEMENT_SUCCEEDED_TOPIC) {
            _handleSettlementSucceeded(log);
            return;
        }

        if (log.topic_0 == SETTLEMENT_FAILED_TOPIC) {
            _handleSettlementFailed(log);
            return;
        }
    }

    /// @notice Queue size accessor.
    function queueSize() public view returns (uint256) {
        return queueData.size;
    }

    /// @notice Queue head accessor.
    function listHead() public view returns (bytes32) {
        return queueData.head;
    }

    /// @notice Queue tail accessor.
    function listTail() public view returns (bytes32) {
        return queueData.tail;
    }

    /// @notice Queue cursor accessor.
    function scanCursor() public view returns (bytes32) {
        return queueData.cursor;
    }

    /// @notice Membership accessor for a queue key.
    function inQueue(bytes32 key) public view returns (bool) {
        return queueData.inQueue[key];
    }

    /// @notice Next pointer accessor for a queue key.
    function nextInQueue(bytes32 key) public view returns (bytes32) {
        return queueData.next[key];
    }

    /// @notice Previous pointer accessor for a queue key.
    function prevInQueue(bytes32 key) public view returns (bytes32) {
        return queueData.prev[key];
    }
}

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
        address _destinationReceiverContract,
        address _reactiveCallbackProxy
    )
        payable
        HubRSCStorage(
            _maxDispatchItems,
            _protocolChainId,
            _reactChainId,
            _liquidityHub,
            _destinationReceiverContract,
            _reactiveCallbackProxy
        )
    {}

    /// @notice Activates HubRSC-wide subscriptions that are not scoped to one recipient.
    function activateBaseSubscriptions() external rnOnly {
        if (baseSubscriptionsActive) return;
        baseSubscriptionsActive = true;
        _subscribeBaseLogs();
        emit BaseSubscriptionsActivated(msg.sender);
    }

    /// @notice Explicitly registers a recipient and optionally funds immediate activation with native value.
    function registerRecipient(address recipient) external payable {
        _syncObservedSystemDebt();
        if (recipient == address(0)) revert InvalidRecipient();
        if (recipientRegistered[recipient]) revert RecipientAlreadyRegistered(recipient);

        recipientRegistered[recipient] = true;
        emit RecipientRegistered(recipient, msg.value, recipientBalance[recipient] + int256(msg.value));
        _creditRecipientDeposit(recipient, msg.value);
        _syncRecipientActivation(recipient);
        if (recipientActive[recipient]) {
            _recordLifecycleDebtContext(recipient);
        }
        _coverObservedDebtIfFunded();
    }

    /// @notice Tops up a registered recipient with native value and reactivates when the balance is positive.
    function fundRecipient(address recipient) external payable {
        _syncObservedSystemDebt();
        if (!recipientRegistered[recipient]) revert RecipientNotRegistered(recipient);
        if (msg.value == 0) return;

        _creditRecipientDeposit(recipient, msg.value);
        _syncRecipientActivation(recipient);
        if (recipientActive[recipient]) {
            _recordLifecycleDebtContext(recipient);
        }
        _coverObservedDebtIfFunded();
    }

    /// @notice Allocates newly observed Reactive system debt to the previous work context and pays what it can.
    function syncSystemDebt() external {
        _syncObservedSystemDebt();
    }

    /// @notice Computes the HubRSC pending-state key for an LCC/recipient pair.
    function computeKey(address lcc, address recipient) external pure returns (bytes32) {
        return _computeKey(lcc, recipient);
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
    /// @dev ReactVM execution must not assume canonical storage persistence. This entrypoint only emits
    ///      `Callback` to the reactive network, which delivers `applyCanonicalProtocolLog` on the canonical deployment.
    function react(IReactive.LogRecord calldata log) external vmOnly {
        emit Callback(
            reactChainId,
            canonicalReactiveHub,
            CANONICAL_APPLY_CALLBACK_GAS_LIMIT,
            abi.encodeWithSelector(this.applyCanonicalProtocolLog.selector, address(0), log)
        );
    }

    /// @notice Applies an observed protocol or self-continuation log to canonical HubRSC storage.
    /// @dev Callable only by `reactiveCallbackProxy` after the ReactVM `react` path emits `Callback`.
    /// @param callbackOrigin Reactive callback origin injected by the callback proxy.
    function applyCanonicalProtocolLog(address callbackOrigin, IReactive.LogRecord calldata log)
        external
        onlyReactiveCallbackProxy
    {
        emit CanonicalProtocolLogCallback(callbackOrigin, log.chain_id, log._contract);
        _syncObservedSystemDebt();
        _dispatchCanonicalInboundLog(log);
    }

    /// @notice Routes decoded inbound logs to the same handlers used for canonical state updates.
    function _dispatchCanonicalInboundLog(IReactive.LogRecord calldata log) internal {
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

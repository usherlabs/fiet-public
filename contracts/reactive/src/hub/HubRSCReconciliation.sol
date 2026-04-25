// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {SettlementFailureLib} from "../libs/SettlementFailureLib.sol";
import {LinkedQueue} from "../libs/LinkedQueue.sol";
import {HubRSCRouting} from "./HubRSCRouting.sol";

abstract contract HubRSCReconciliation is HubRSCRouting {
    using LinkedQueue for LinkedQueue.Data;

    /// @notice Reconciles pending amount from authoritative LiquidityHub settlement processing.
    function _handleSettlementProcessed(IReactive.LogRecord calldata log) internal {
        if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
        if (!_markLogProcessed(log)) return;

        address lcc = address(uint160(log.topic_1));
        address recipient = address(uint160(log.topic_2));
        if (!_chargeMatchingRecipientEvent(recipient)) return;
        (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));

        _reconcileProcessedRequestedAmount(_computeKey(lcc, recipient), requestedAmount);
        _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, 0, true);
        _dispatchLiquidityIfBudgetAvailable(lcc, true);
    }

    /// @notice Releases trusted in-flight amount for completed destination settlements.
    function _handleSettlementSucceeded(IReactive.LogRecord calldata log) internal {
        if (log.chain_id != protocolChainId || log._contract != destinationReceiverContract) return;
        if (!_markLogProcessed(log)) return;

        address lcc = address(uint160(log.topic_1));
        address recipient = address(uint160(log.topic_2));
        if (!_chargeMatchingRecipientEvent(recipient)) return;
        (uint256 succeededAmount, uint256 attemptId) = abi.decode(log.data, (uint256, uint256));
        if (succeededAmount == 0) return;

        uint256 releasedAmount = _releaseInFlightReservation(attemptId, lcc, recipient, false);
        _registerCompletedAwaitingProcessed(_computeKey(lcc, recipient), releasedAmount);
        _dispatchLiquidityIfBudgetAvailable(lcc, true);
    }

    /// @notice Reconciles pending amount from authoritative LiquidityHub queue annulments.
    function _handleSettlementAnnulled(IReactive.LogRecord calldata log) internal {
        if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
        if (!_markLogProcessed(log)) return;

        address lcc = address(uint160(log.topic_1));
        address recipient = address(uint160(log.topic_2));
        if (!_chargeMatchingRecipientEvent(recipient)) return;
        uint256 annulledAmount = abi.decode(log.data, (uint256));

        _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, annulledAmount, 0, false);
    }

    /// @notice Releases reserved in-flight amount for failed destination settlements.
    function _handleSettlementFailed(IReactive.LogRecord calldata log) internal {
        if (log.chain_id != protocolChainId || log._contract != destinationReceiverContract) return;
        if (!_markLogProcessed(log)) return;

        address lcc = address(uint160(log.topic_1));
        address recipient = address(uint160(log.topic_2));
        if (!_chargeMatchingRecipientEvent(recipient)) return;
        (uint256 failedAmount, uint256 attemptId, bytes memory revertData) =
            abi.decode(log.data, (uint256, uint256, bytes));
        bytes4 failureSelector = SettlementFailureLib.selectorFromRevertData(revertData);
        uint8 failureClass = SettlementFailureLib.classify(failureSelector);
        if (failedAmount == 0) return;

        bytes32 key = _computeKey(lcc, recipient);
        _releaseInFlightReservation(attemptId, lcc, recipient, SettlementFailureLib.restoresBudget(failureClass));
        if (SettlementFailureLib.isTerminal(failureClass)) {
            Pending storage entry = pending[key];
            if (entry.exists) {
                _clearRetryBlock(lcc, recipient, key);
                _markTerminalFailure(entry, key, failedAmount, failureSelector, failureClass);
            }
            _dispatchLiquidityIfBudgetAvailable(lcc, true);
            return;
        }

        _markRetryBlocked(lcc, recipient, key, failureClass);

        // Liquidity-exhausted failures scrub speculative budget and wait for the next authoritative wake-up.
        if (SettlementFailureLib.requiresFreshLiquidity(failureClass)) return;

        _dispatchLiquidityIfBudgetAvailable(lcc, true);
    }

    /// @notice Applies authoritative decrease immediately when pending exists, otherwise buffers it.
    /// @param isProcessedCallback When true, remainder is routed to processed buffers; otherwise to annulled buffer.
    function _applyAuthoritativeDecreaseOrBuffer(
        address lcc,
        address recipient,
        uint256 settledAmount,
        uint256 inflightAmountToReduce,
        bool isProcessedCallback
    ) internal {
        if (settledAmount == 0 && inflightAmountToReduce == 0) return;
        bytes32 key = _computeKey(lcc, recipient);
        _clearRetryBlock(lcc, recipient, key);
        Pending storage entry = pending[key];

        if (entry.exists) {
            _clearTerminalFailure(lcc, recipient, key);
            (uint256 remainingSettled, uint256 remainingInflight) =
                _consumeAuthoritativeDecrease(entry, key, settledAmount, inflightAmountToReduce);
            _restoreQueueMembership(entry, key);
            if (remainingSettled > 0 || remainingInflight > 0) {
                if (isProcessedCallback) {
                    bufferedProcessedDecreaseByKey[key].settledAmount += remainingSettled;
                } else {
                    bufferedAnnulledDecreaseByKey[key] += remainingSettled;
                }
            }
            return;
        }

        if (isProcessedCallback) {
            bufferedProcessedDecreaseByKey[key].settledAmount += settledAmount;
        } else {
            bufferedAnnulledDecreaseByKey[key] += settledAmount;
        }
    }

    function _releaseInFlightReservation(uint256 attemptId, address lcc, address recipient, bool restoreBudget)
        internal
        returns (uint256 release)
    {
        AttemptReservation memory reservation = _attemptReservationById[attemptId];
        if (reservation.amount == 0) return 0;
        if (reservation.lcc != lcc || reservation.recipient != recipient) return 0;

        delete _attemptReservationById[attemptId];

        bytes32 key = _computeKey(lcc, recipient);
        uint256 reserved = inFlightByKey[key];
        if (reserved == 0) return 0;

        release = reservation.amount < reserved ? reservation.amount : reserved;
        inFlightByKey[key] = reserved - release;
        if (restoreBudget) {
            _creditDispatchBudget(lcc, release);
        }

        Pending storage entry = pending[key];
        if (entry.exists) {
            _pruneIfFullySettled(entry, key);
        }

        return release;
    }

    function _markTerminalFailure(
        Pending storage entry,
        bytes32 key,
        uint256 failedAmount,
        bytes4 failureSelector,
        uint8 failureClass
    ) internal {
        if (_isTerminalFailure(terminalFailureByKey[key])) return;

        address lcc = entry.lcc;
        terminalFailureByKey[key] = _packTerminalFailure(failureSelector, failureClass);

        if (mirroredToUnderlyingByKey[key] && hasUnderlyingForLcc[lcc]) {
            queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
        } else if (!hasUnderlyingForLcc[lcc]) {
            _clearHistoricalBackfillForKey(lcc, key);
        }
        queueDataByLcc[lcc].remove(key);
        queueData.remove(key);

        emit TerminalFailureQuarantined(lcc, entry.recipient, failedAmount, failureSelector, failureClass);
    }

    function _markRetryBlocked(address lcc, address recipient, bytes32 key, uint8 failureClass) internal {
        _retryBlockedAtWakeEpochByKey[key] = protocolLiquidityWakeEpochByLane[_dispatchBudgetLane(lcc)];
        emit RetryBlocked(lcc, recipient, _dispatchBudgetLane(lcc), failureClass);
    }

    function _clearRetryBlock(address lcc, address recipient, bytes32 key) internal {
        if (_retryBlockedAtWakeEpochByKey[key] == 0) return;
        delete _retryBlockedAtWakeEpochByKey[key];
        emit RetryBlockCleared(lcc, recipient, _dispatchBudgetLane(lcc));
    }

    function _isRetryBlocked(bytes32 key, address lcc) internal view returns (bool) {
        uint256 blockedAtWakeEpoch = _retryBlockedAtWakeEpochByKey[key];
        if (blockedAtWakeEpoch == 0) return false;
        return blockedAtWakeEpoch == protocolLiquidityWakeEpochByLane[_dispatchBudgetLane(lcc)];
    }

    function _clearTerminalFailure(address lcc, address recipient, bytes32 key) internal {
        uint40 terminalFailure = terminalFailureByKey[key];
        if (!_isTerminalFailure(terminalFailure)) return;

        bytes4 failureSelector = _failureSelector(terminalFailure);
        uint8 failureClass = _failureClass(terminalFailure);
        delete terminalFailureByKey[key];

        Pending storage entry = pending[key];
        if (
            entry.exists && entry.amount > 0 && !hasUnderlyingForLcc[lcc] && !mirroredToUnderlyingByKey[key]
                && !historicalBackfillPendingByKey[key]
        ) {
            historicalBackfillPendingByKey[key] = true;
            underlyingBackfillRemainingByLcc[lcc] += 1;
        }

        emit TerminalFailureCleared(lcc, recipient, failureSelector, failureClass);
    }

    function _restoreQueueMembership(Pending storage entry, bytes32 key) internal {
        if (!entry.exists || entry.amount == 0 || _isTerminalFailure(terminalFailureByKey[key])) return;

        if (!queueDataByLcc[entry.lcc].inQueue[key]) {
            queueDataByLcc[entry.lcc].enqueue(key);
        }
        if (!queueData.inQueue[key]) {
            queueData.enqueue(key);
        }
        if (hasUnderlyingForLcc[entry.lcc]) {
            _enqueueUnderlyingKey(entry.lcc, key);
        }
    }

    /// @notice Applies authoritative queue decrement without mutating attempt-scoped reservations.
    /// @dev Returns any settled decrease not applied to `entry.amount`. Attempt completions release reservations via
    ///      `_releaseInFlightReservation`, so the inflight remainder channel is retained only for struct compatibility.
    function _consumeAuthoritativeDecrease(
        Pending storage entry,
        bytes32 key,
        uint256 settledAmount,
        uint256 inflightAmountToReduce
    ) internal returns (uint256 remainingSettled, uint256 remainingInflight) {
        if (!entry.exists) {
            return (settledAmount, inflightAmountToReduce);
        }
        if (settledAmount == 0 && inflightAmountToReduce == 0) return (0, 0);

        uint256 dec = settledAmount < entry.amount ? settledAmount : entry.amount;
        if (dec > 0) {
            entry.amount -= dec;
        }
        remainingSettled = settledAmount - dec;

        remainingInflight = inflightAmountToReduce;

        _pruneIfFullySettled(entry, key);
    }

    /// @notice Holds released-success capacity on the key until processed reconciliation catches up.
    function _registerCompletedAwaitingProcessed(bytes32 key, uint256 amount) internal {
        if (amount == 0) return;

        uint256 processedCredit = _processedRequestedCreditByKey[key];
        if (processedCredit >= amount) {
            _processedRequestedCreditByKey[key] = processedCredit - amount;
            return;
        }

        if (processedCredit != 0) {
            amount -= processedCredit;
            delete _processedRequestedCreditByKey[key];
        }

        _completedAwaitingProcessedByKey[key] += amount;
    }

    /// @notice Reconciles processed requested-amount ordering against already released successes on the same key.
    function _reconcileProcessedRequestedAmount(bytes32 key, uint256 requestedAmount) internal {
        if (requestedAmount == 0) return;

        uint256 awaitingProcessed = _completedAwaitingProcessedByKey[key];
        if (awaitingProcessed >= requestedAmount) {
            _completedAwaitingProcessedByKey[key] = awaitingProcessed - requestedAmount;
            return;
        }

        if (awaitingProcessed != 0) {
            requestedAmount -= awaitingProcessed;
            delete _completedAwaitingProcessedByKey[key];
        }

        _processedRequestedCreditByKey[key] += requestedAmount;
    }

    /// @notice Applies buffered authoritative decreases after pending entry creation/increase.
    function _applyBufferedDecreases(Pending storage entry, bytes32 key) internal {
        BufferedProcessedSettlement memory bufferedProcessed = bufferedProcessedDecreaseByKey[key];
        if (bufferedProcessed.settledAmount > 0 || bufferedProcessed.inflightAmountToReduce > 0) {
            (uint256 remSettled, uint256 remInflight) = _consumeAuthoritativeDecrease(
                entry, key, bufferedProcessed.settledAmount, bufferedProcessed.inflightAmountToReduce
            );
            bufferedProcessedDecreaseByKey[key] = BufferedProcessedSettlement(remSettled, remInflight);
        }
        uint256 bufferedAnnulled = bufferedAnnulledDecreaseByKey[key];
        if (bufferedAnnulled != 0) {
            (uint256 remAnnulled,) = _consumeAuthoritativeDecrease(entry, key, bufferedAnnulled, 0);
            bufferedAnnulledDecreaseByKey[key] = remAnnulled;
        }
    }

    /// @notice Marks callback log identity as processed; returns false for duplicates.
    function _markLogProcessed(IReactive.LogRecord calldata log) internal returns (bool) {
        bytes32 reportId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
        if (processedReport[reportId]) {
            emit DuplicateLogIgnored(reportId);
            return false;
        }
        processedReport[reportId] = true;
        return true;
    }

    function _clearHistoricalBackfillForKey(address lcc, bytes32 key) internal virtual override {
        if (!historicalBackfillPendingByKey[key]) return;

        delete historicalBackfillPendingByKey[key];
        uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
        if (remaining > 0) {
            underlyingBackfillRemainingByLcc[lcc] = remaining - 1;
        }
        _syncUnderlyingBackfillState(lcc);
    }

    /// @notice Removes queue membership once both pending and in-flight amounts are zero.
    function _pruneIfFullySettled(Pending storage entry, bytes32 key) internal {
        if (entry.amount != 0 || inFlightByKey[key] != 0 || _completedAwaitingProcessedByKey[key] != 0) return;
        address lcc = entry.lcc;
        bool terminal = _isTerminalFailure(terminalFailureByKey[key]);
        entry.exists = false;
        if (mirroredToUnderlyingByKey[key] && hasUnderlyingForLcc[lcc]) {
            queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
        } else if (!terminal) {
            _clearHistoricalBackfillForKey(lcc, key);
        }
        delete terminalFailureByKey[key];
        delete _retryBlockedAtWakeEpochByKey[key];
        delete mirroredToUnderlyingByKey[key];
        delete historicalBackfillPendingByKey[key];
        queueDataByLcc[lcc].remove(key);
        queueData.remove(key);
    }

    function _packTerminalFailure(bytes4 failureSelector, uint8 failureClass) internal pure returns (uint40) {
        return (uint40(uint32(failureSelector)) << 8) | uint40(failureClass);
    }

    function _failureSelector(uint40 terminalFailure) internal pure returns (bytes4) {
        return bytes4(uint32(terminalFailure >> 8));
    }

    function _failureClass(uint40 terminalFailure) internal pure returns (uint8) {
        return uint8(terminalFailure);
    }

    function _isTerminalFailure(uint40 terminalFailure) internal pure returns (bool) {
        return terminalFailure != 0;
    }

    function _dispatchLiquidityIfBudgetAvailable(address lcc, bool allowBootstrapRetry) internal virtual;
}

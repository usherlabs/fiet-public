// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ReactiveConstants} from "../libs/ReactiveConstants.sol";
import {LinkedQueue} from "../libs/LinkedQueue.sol";
import {HubRSCReconciliation} from "./HubRSCReconciliation.sol";

abstract contract HubRSCDispatch is HubRSCReconciliation {
    using LinkedQueue for LinkedQueue.Data;

    /// @notice Ingests an authoritative LiquidityHub `SettlementQueued` log into pending state.
    /// @dev Deduplicates by log identity, ignores zero amounts, and either creates or increments a queued pending entry.
    function _handleSettlementQueued(IReactive.LogRecord calldata log) internal {
        if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;

        address lcc = address(uint160(log.topic_1));
        address recipient = address(uint160(log.topic_2));
        uint256 amount = abi.decode(log.data, (uint256));

        if (!_markLogProcessed(log)) return;
        if (!_acceptMatchingRecipientEvent(recipient)) return;
        if (amount == 0) return;

        bytes32 key = _computeKey(lcc, recipient);
        _clearTerminalFailure(lcc, recipient, key);
        _clearRetryBlock(lcc, recipient, key);
        Pending storage entry = pending[key];

        if (!entry.exists) {
            entry.lcc = lcc;
            entry.recipient = recipient;
            entry.amount = amount;
            entry.exists = true;
            queueData.enqueue(key);
            queueDataByLcc[lcc].enqueue(key);
            if (hasUnderlyingForLcc[lcc]) {
                _enqueueUnderlyingKey(lcc, key);
            } else {
                historicalBackfillPendingByKey[key] = true;
                underlyingBackfillRemainingByLcc[lcc] += 1;
            }
            emit PendingAdded(lcc, recipient, amount);
        } else {
            entry.amount += amount;
            if (!queueDataByLcc[lcc].inQueue[key]) {
                queueDataByLcc[lcc].enqueue(key);
            }
            if (!queueData.inQueue[key]) {
                queueData.enqueue(key);
            }
            if (hasUnderlyingForLcc[lcc]) {
                _enqueueUnderlyingKey(lcc, key);
            }
            emit PendingIncreased(lcc, recipient, amount);
        }

        _applyBufferedDecreases(entry, key);
        _dispatchLiquidityIfBudgetAvailable(lcc, true);
    }

    /// @notice Registers canonical underlying from LiquidityHub `LCCCreated` logs.
    function _handleLccCreated(IReactive.LogRecord calldata log) internal {
        if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;

        address underlying = address(uint160(log.topic_1));
        address lcc = address(uint160(log.topic_2));
        _registerLccUnderlying(lcc, underlying);
    }

    /// @notice Builds and dispatches a bounded settlement batch when liquidity is available.
    /// @dev Decodes LiquidityAvailable log fields, registers `lcc -> underlying`, then routes dispatch.
    function _handleLiquidityAvailable(IReactive.LogRecord calldata log) internal {
        if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
        if (!_markLogProcessed(log)) return;
        address lcc = address(uint160(log.topic_1));
        (address underlying, uint256 available,) = abi.decode(log.data, (address, uint256, bytes32));
        _registerLccUnderlying(lcc, underlying);
        protocolLiquidityWakeEpochByLane[_dispatchBudgetLane(lcc)] += 1;
        _creditDispatchBudget(lcc, available);
        _dispatchLiquidityIfBudgetAvailable(lcc, true);
    }

    /// @notice Handles HubRSC self-continuation liquidity notices.
    function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
        if (log.chain_id != reactChainId || log._contract != address(this)) return;
        if (!_markLogProcessed(log)) return;
        address lcc = address(uint160(log.topic_1));
        address budgetLane = _dispatchBudgetLane(lcc);
        // The callback amount is informational; persisted lane budget remains the dispatch source of truth.
        bool allowBootstrapRetry = continuationBootstrapPendingByLane[budgetLane];
        continuationBootstrapPendingByLane[budgetLane] = false;
        _dispatchLiquidityIfBudgetAvailable(lcc, allowBootstrapRetry);
    }

    /// @notice Dispatches liquidity for a given LCC.
    function _dispatchLiquidity(address lcc) internal {
        address underlying = underlyingByLcc[lcc];
        address budgetLane = _dispatchBudgetLane(lcc);
        uint256 available = availableBudgetByDispatchLane[budgetLane];
        bool useSharedUnderlying = _sharedUnderlyingRoutingReady(lcc, underlying);
        address dispatchLane = useSharedUnderlying ? underlying : lcc;
        _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);

        LinkedQueue.Data storage scanQueue =
            useSharedUnderlying ? queueDataByUnderlying[dispatchLane] : queueDataByLcc[lcc];
        if (available == 0) return;
        if (scanQueue.size == 0) {
            if (
                !useSharedUnderlying && hasUnderlyingForLcc[lcc] && pendingBackfillLccsByUnderlying[underlying].size > 0
            ) {
                _triggerMoreLiquidityAvailable(lcc, available);
            }
            return;
        }

        _dispatchLiquidityFromQueue(scanQueue, lcc, dispatchLane, budgetLane, available, useSharedUnderlying);
    }

    function _dispatchLiquidityFromQueue(
        LinkedQueue.Data storage scanQueue,
        address triggerLcc,
        address dispatchLane,
        address budgetLane,
        uint256 available,
        bool useSharedUnderlying
    ) internal {
        uint256 startSize = scanQueue.size;
        uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;

        DispatchBatch memory batch = DispatchBatch({
            lccs: new address[](cap),
            recipients: new address[](cap),
            amounts: new uint256[](cap),
            attemptIds: new uint256[](cap)
        });

        DispatchState memory state = DispatchState({
            remainingLiquidity: available, batchCount: 0, scanned: 0, cursor: scanQueue.currentCursor()
        });

        while (state.scanned < cap && state.remainingLiquidity > 0) {
            bytes32 key = state.cursor;
            state.cursor = scanQueue.nextOrHead(key);
            _scanDispatchEntry(scanQueue, key, dispatchLane, useSharedUnderlying, state, batch);
            state.scanned++;
        }

        scanQueue.cursor = state.cursor;
        availableBudgetByDispatchLane[budgetLane] = state.remainingLiquidity;

        if (_handleZeroBatchRetry(dispatchLane, triggerLcc, state.batchCount, state.remainingLiquidity, startSize)) {
            return;
        }

        _finalizeLiquidityDispatch(
            triggerLcc,
            available,
            state.batchCount,
            state.remainingLiquidity,
            batch.lccs,
            batch.recipients,
            batch.amounts,
            batch.attemptIds
        );
    }

    /// @notice Handles the "zero-batch but liquidity remains" continuation case.
    function _handleZeroBatchRetry(
        address dispatchLane,
        address triggerLcc,
        uint256 batchCount,
        uint256 remainingLiquidity,
        uint256 queueSizeAtStart
    ) internal returns (bool shouldReturn) {
        if (batchCount == 0 && remainingLiquidity > 0) {
            uint256 credits = zeroBatchRetryCreditsRemaining[dispatchLane];
            if (credits == 0 && bootstrapZeroBatchRetry) {
                uint256 remaining = queueSizeAtStart > maxDispatchItems ? queueSizeAtStart - maxDispatchItems : 0;
                credits = _zeroBatchRetryWindowCount(remaining);
            }
            if (credits > 0) {
                zeroBatchRetryCreditsRemaining[dispatchLane] = credits - 1;
                _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
                return true;
            }
            zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
        }

        if (batchCount > 0) {
            zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
        }

        return false;
    }

    function _zeroBatchRetryWindowCount(uint256 remainingEntries) internal view returns (uint256 windows) {
        if (remainingEntries == 0) return 0;
        windows = (remainingEntries + maxDispatchItems - 1) / maxDispatchItems;
        if (windows > MAX_ZERO_BATCH_RETRY_WINDOWS) windows = MAX_ZERO_BATCH_RETRY_WINDOWS;
    }

    /// @notice Checks whether a pending entry belongs to the current dispatch lane.
    function _entryMatchesDispatchLane(address entryLcc, address dispatchLane, bool useSharedUnderlying)
        internal
        view
        returns (bool)
    {
        return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
            ? underlyingByLcc[entryLcc] == dispatchLane
            : entryLcc == dispatchLane;
    }

    function _scanDispatchEntry(
        LinkedQueue.Data storage scanQueue,
        bytes32 key,
        address dispatchLane,
        bool useSharedUnderlying,
        DispatchState memory state,
        DispatchBatch memory batch
    ) internal {
        Pending storage entry = pending[key];
        if (!scanQueue.inQueue[key] || !entry.exists) {
            scanQueue.remove(key);
            queueData.remove(key);
            return;
        }

        if (_isTerminalFailure(terminalFailureByKey[key])) return;
        if (!_entryMatchesDispatchLane(entry.lcc, dispatchLane, useSharedUnderlying)) return;
        if (_isRetryBlocked(key, entry.lcc)) return;

        uint256 reserved = inFlightByKey[key];
        if (entry.amount == 0 && reserved == 0) {
            _pruneIfFullySettled(entry, key);
            return;
        }

        uint256 dispatchable = entry.amount;
        if (reserved >= dispatchable) return;
        dispatchable -= reserved;

        uint256 awaitingProcessed = _completedAwaitingProcessedByKey[key];
        if (awaitingProcessed >= dispatchable) return;
        dispatchable -= awaitingProcessed;
        if (dispatchable == 0) return;
        if (!_recipientServiceActive(entry.recipient)) return;

        uint256 settleAmount = dispatchable <= state.remainingLiquidity ? dispatchable : state.remainingLiquidity;
        inFlightByKey[key] = reserved + settleAmount;
        uint256 attemptId = ++nextAttemptId;
        _attemptReservationById[attemptId] =
            AttemptReservation({lcc: entry.lcc, recipient: entry.recipient, amount: settleAmount});
        state.remainingLiquidity -= settleAmount;

        batch.lccs[state.batchCount] = entry.lcc;
        batch.recipients[state.batchCount] = entry.recipient;
        batch.amounts[state.batchCount] = settleAmount;
        batch.attemptIds[state.batchCount] = attemptId;
        state.batchCount++;
    }

    function _dispatchLiquidityIfBudgetAvailable(address lcc, bool allowBootstrapRetry) internal virtual override {
        if (_availableBudgetForLcc(lcc) == 0) return;
        if (hasUnderlyingForLcc[lcc]) {
            address underlying = underlyingByLcc[lcc];
            _continueUnderlyingBackfill(underlying, maxDispatchItems);
            if (pendingBackfillLccsByUnderlying[underlying].size > 0 && queueDataByLcc[lcc].size == 0) {
                _triggerMoreLiquidityAvailable(lcc, _availableBudgetForLcc(lcc));
                return;
            }
        }
        bootstrapZeroBatchRetry = allowBootstrapRetry;
        _dispatchLiquidity(lcc);
        bootstrapZeroBatchRetry = false;
    }

    /// @dev Shrink batch arrays, emit destination callback, and optionally request more liquidity on the callback chain.
    function _finalizeLiquidityDispatch(
        address triggerLcc,
        uint256 available,
        uint256 batchCount,
        uint256 remainingLiquidity,
        address[] memory lccs,
        address[] memory recipients,
        uint256[] memory amounts,
        uint256[] memory attemptIds
    ) internal {
        if (batchCount == 0) return;

        assembly {
            mstore(lccs, batchCount)
            mstore(recipients, batchCount)
            mstore(amounts, batchCount)
            mstore(attemptIds, batchCount)
        }

        bytes memory payload = abi.encodeWithSelector(
            ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR, address(0), lccs, recipients, amounts, attemptIds
        );

        emit DispatchRequested(triggerLcc, available, batchCount, remainingLiquidity);
        emit DestinationCallbackRequested(payload);
        if (vm) {
            emit Callback(protocolChainId, destinationReceiverContract, CALLBACK_GAS_LIMIT, payload);
        }
        _recordDispatchDebtContext(recipients, batchCount);

        if (remainingLiquidity > 0) {
            _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
        }
    }

    /// @notice Triggers a HubRSC-local continuation event.
    function _triggerMoreLiquidityAvailable(address triggerLcc, uint256 remainingLiquidity) internal {
        continuationBootstrapPendingByLane[_dispatchBudgetLane(triggerLcc)] = true;
        emit MoreLiquidityAvailable(triggerLcc, remainingLiquidity);
    }

    /// @dev Zero-batch retry credits are keyed by the lane that was actually scanned.
    function _clearInactiveZeroBatchRetryCredits(address lcc, address underlying, bool useSharedUnderlying) internal {
        if (useSharedUnderlying) {
            zeroBatchRetryCreditsRemaining[lcc] = 0;
            return;
        }

        if (hasUnderlyingForLcc[lcc]) {
            zeroBatchRetryCreditsRemaining[underlying] = 0;
        }
    }
}

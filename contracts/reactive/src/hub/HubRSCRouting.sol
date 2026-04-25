// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {HubRSCStorage} from "./HubRSCStorage.sol";
import {LinkedQueue} from "../libs/LinkedQueue.sol";

abstract contract HubRSCRouting is HubRSCStorage {
    using LinkedQueue for LinkedQueue.Data;

    /// @notice Registers a LCC underlying.
    /// @dev Registers a LCC underlying and sets the hasUnderlyingForLcc flag to true.
    function _registerLccUnderlying(address lcc, address underlying) internal {
        if (hasUnderlyingForLcc[lcc]) return;
        uint256 preRegistrationBudget = availableBudgetByDispatchLane[lcc];
        uint256 preRegistrationWakeEpoch = protocolLiquidityWakeEpochByLane[lcc];
        underlyingByLcc[lcc] = underlying;
        hasUnderlyingForLcc[lcc] = true;
        if (preRegistrationBudget > 0) {
            availableBudgetByDispatchLane[underlying] += preRegistrationBudget;
            delete availableBudgetByDispatchLane[lcc];
        }
        if (protocolLiquidityWakeEpochByLane[underlying] < preRegistrationWakeEpoch) {
            protocolLiquidityWakeEpochByLane[underlying] = preRegistrationWakeEpoch;
        }
        _initializeUnderlyingBackfill(lcc, underlying);
    }

    /// @notice Seeds bounded shared-lane backfill for an LCC that queued work before underlying registration.
    /// @dev The first registration pass mirrors at most `maxDispatchItems` historical keys immediately and leaves
    ///      the remainder to `_continueUnderlyingBackfill`, which resumes from the saved cursor.
    function _initializeUnderlyingBackfill(address lcc, address underlying) internal {
        if (underlyingBackfillRemainingByLcc[lcc] == 0) return;
        pendingBackfillLccsByUnderlying[underlying].enqueue(_backfillLccKey(lcc));
        underlyingBackfillCursorByLcc[lcc] = queueDataByLcc[lcc].currentCursor();
        _continueUnderlyingBackfillForLcc(lcc, underlying, maxDispatchItems);
        _syncUnderlyingBackfillState(lcc);
    }

    /// @notice Enqueues a key into the underlying queue for a given LCC.
    function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
        if (!hasUnderlyingForLcc[lcc]) return;
        queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
        if (!mirroredToUnderlyingByKey[key]) {
            mirroredToUnderlyingByKey[key] = true;
            _clearHistoricalBackfillForKey(lcc, key);
        }
    }

    function _dispatchBudgetLane(address lcc) internal view returns (address) {
        return hasUnderlyingForLcc[lcc] ? underlyingByLcc[lcc] : lcc;
    }

    function _availableBudgetForLcc(address lcc) internal view returns (uint256) {
        return availableBudgetByDispatchLane[_dispatchBudgetLane(lcc)];
    }

    function _creditDispatchBudget(address lcc, uint256 amount) internal {
        if (amount == 0) return;
        address budgetLane = _dispatchBudgetLane(lcc);
        availableBudgetByDispatchLane[budgetLane] += amount;
    }

    function _sharedUnderlyingRoutingReady(address lcc, address underlying) internal view returns (bool) {
        if (!hasUnderlyingForLcc[lcc] || queueDataByUnderlying[underlying].size == 0) return false;
        if (pendingBackfillLccsByUnderlying[underlying].size == 0) return true;

        // While sibling historical keys are still being mirrored, prefer the trigger LCC's dedicated lane whenever
        // it already has visible work. If the trigger lane is empty, using the shared lane is still safe and avoids
        // stalling mirrored historical recipients behind a no-op per-LCC scan.
        return queueDataByLcc[lcc].size == 0;
    }

    /// @notice Continues bounded historical backfill for LCCs registered on a shared underlying lane.
    /// @dev This keeps first-time registration O(`maxDispatchItems`) instead of O(queue size) while allowing
    ///      later liquidity callbacks on the same underlying to make forward progress on any remaining backlog.
    function _continueUnderlyingBackfill(address underlying, uint256 budget) internal {
        LinkedQueue.Data storage backfillQueue = pendingBackfillLccsByUnderlying[underlying];
        while (budget > 0 && backfillQueue.size > 0) {
            bytes32 lccKey = backfillQueue.currentCursor();
            address lcc = _lccFromBackfillKey(lccKey);
            bytes32 nextLccKey = backfillQueue.nextOrHead(lccKey);

            uint256 scanned = _continueUnderlyingBackfillForLcc(lcc, underlying, budget);
            if (scanned == 0) {
                break;
            }
            budget -= scanned;
            if (underlyingBackfillRemainingByLcc[lcc] == 0) {
                backfillQueue.remove(lccKey);
                continue;
            }
            backfillQueue.cursor = nextLccKey;
        }
    }

    /// @notice Mirrors up to `budget` historical per-LCC queue keys into the shared underlying lane.
    function _continueUnderlyingBackfillForLcc(address lcc, address underlying, uint256 budget)
        internal
        returns (uint256 scanned)
    {
        uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
        if (budget == 0 || remaining == 0) return 0;

        LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
        if (lccQueue.size == 0) {
            underlyingBackfillRemainingByLcc[lcc] = 0;
            _syncUnderlyingBackfillState(lcc);
            return 0;
        }
        bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
        if (cursor == bytes32(0) || !lccQueue.inQueue[cursor]) {
            cursor = lccQueue.currentCursor();
        }

        while (remaining > 0 && scanned < budget) {
            bytes32 key = cursor;
            cursor = lccQueue.nextOrHead(key);

            Pending storage entry = pending[key];
            if (entry.exists && entry.lcc == lcc && !mirroredToUnderlyingByKey[key]) {
                queueDataByUnderlying[underlying].enqueue(key);
                mirroredToUnderlyingByKey[key] = true;
                if (historicalBackfillPendingByKey[key]) {
                    delete historicalBackfillPendingByKey[key];
                    remaining--;
                }
            }
            scanned++;
        }

        underlyingBackfillRemainingByLcc[lcc] = remaining;
        underlyingBackfillCursorByLcc[lcc] = remaining == 0 ? bytes32(0) : cursor;
        _syncUnderlyingBackfillState(lcc);
        return scanned;
    }

    function _syncUnderlyingBackfillState(address lcc) internal {
        if (!hasUnderlyingForLcc[lcc]) return;

        LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
        if (lccQueue.size == 0) {
            underlyingBackfillRemainingByLcc[lcc] = 0;
        }

        LinkedQueue.Data storage backfillQueue = pendingBackfillLccsByUnderlying[underlyingByLcc[lcc]];
        bytes32 lccKey = _backfillLccKey(lcc);
        if (underlyingBackfillRemainingByLcc[lcc] == 0) {
            backfillQueue.remove(lccKey);
            delete underlyingBackfillCursorByLcc[lcc];
            return;
        }

        backfillQueue.enqueue(lccKey);
        bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
        if (cursor == bytes32(0) || !lccQueue.inQueue[cursor]) {
            underlyingBackfillCursorByLcc[lcc] = lccQueue.currentCursor();
        }
    }

    function _backfillLccKey(address lcc) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(lcc)));
    }

    function _lccFromBackfillKey(bytes32 lccKey) internal pure returns (address) {
        return address(uint160(uint256(lccKey)));
    }

    function _clearHistoricalBackfillForKey(address lcc, bytes32 key) internal virtual;
}

// SPDX-License-Identifier: MIT
/// @notice Library for tracking rolling outflow of a currency in a pool/market data in a time window
pragma solidity ^0.8.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {console} from "forge-std/console.sol";

/**
 * @title RollingOutflowTracker
 * @notice Tracks outflow data for a specific time window using a circular buffer
 * @dev Efficiently maintains rolling totals of outflow amounts over configurable time periods
 */
struct RollingOutflowTracker {
    /// @notice Array of timestamps for outflow events
    uint256[] timestamps;
    /// @notice Array of outflow amounts for currency0
    uint256[] outflow0;
    /// @notice Array of outflow amounts for currency1
    uint256[] outflow1;
    /// @notice Current head position in the circular buffer
    uint256 head;
    /// @notice Current tail position in the circular buffer
    uint256 tail;
    /// @notice Time window duration in seconds
    uint256 timeWindow;
    /// @notice Total outflow for currency0 pending in specified time window
    uint256 totalOutflow0;
    /// @notice Total outflow for currency1 pending in specified time window
    uint256 totalOutflow1;
    /// @notice Is Initialized
    bool isInitialized;
}

/**
 * @title RollingOutflowTrackerLibrary
 * @notice Library for managing rolling outflow tracking
 * @dev Provides efficient circular buffer implementation for rolling time window calculations
 */
library RollingOutflowTrackerLibrary {
    /// @notice Fixed buffer size for optimal gas efficiency
    /// @dev this is the maximum number of items that can be stored in the buffer
    /// @dev this is a trade-off between gas efficiency and memory usage
    /// @dev we can increase this if we need to store more items
    /// @dev we can decrease this if we need to save gas
    /// @dev we have to make sure the buffer will not get full before timeWindow(t) elapses
    uint256 public constant BUFFER_SIZE = 10000;

    error AlreadyInitialized();

    /**
     * @notice Initializes a new rolling outflow tracker
     * @param tracker The tracker to initialize
     * @param timeWindow The time window duration in seconds
     */
    function initialize(RollingOutflowTracker storage tracker, uint256 timeWindow) internal {
        // confirm not initialized yet
        if (tracker.isInitialized) {
            revert AlreadyInitialized();
        }

        tracker.timestamps = new uint256[](0);
        tracker.outflow0 = new uint256[](0);
        tracker.outflow1 = new uint256[](0);
        tracker.head = 0;
        tracker.tail = 0;
        tracker.timeWindow = timeWindow;
        tracker.totalOutflow0 = 0;
        tracker.totalOutflow1 = 0;
        tracker.isInitialized = true;
    }

    /**
     * @notice Records new outflow data and updates rolling totals
     * @param tracker The tracker to update
     * @param outflow0 Outflow amount for currency0
     * @param outflow1 Outflow amount for currency1
     */
    function recordOutflow(RollingOutflowTracker storage tracker, uint256 outflow0, uint256 outflow1) internal {
        uint256 currentTime = block.timestamp;
        uint256 nextHead = (tracker.head + 1) % BUFFER_SIZE;
        // Clean old entries outside time window
        _subtractStaleEntryFromRunningTotal(tracker, currentTime);

        if (nextHead == tracker.tail) {
            //? tail should always be behind head
            //? if it comes from behind to be equal due to the nature of circular buffers
            //? it means the current circular buffer is full of items that are not stale yet
            //? we cannot clean unused entries
            //? since buffer is full without enough time elapsing
            //? we do nothing
            // ? when enough time has passed, the tail will be updated to give more space to new entries
            return;
        }

        // Add new entry to circular buffer
        if (tracker.timestamps.length < BUFFER_SIZE) {
            tracker.timestamps.push(currentTime);
            tracker.outflow0.push(outflow0);
            tracker.outflow1.push(outflow1);
        } else {
            // if we have reached the limit of the buffer, we need to overwrite the oldest item
            tracker.timestamps[tracker.head] = currentTime;
            tracker.outflow0[tracker.head] = outflow0;
            tracker.outflow1[tracker.head] = outflow1;
        }
        // update tracker head
        tracker.head = nextHead;

        // Update running totals
        tracker.totalOutflow0 += outflow0;
        tracker.totalOutflow1 += outflow1;
    }

    /**
     * @notice Gets the total outflow in the current time window
     * @param tracker The tracker to query
     * @return totalOutflow0 Total outflow for currency0
     * @return totalOutflow1 Total outflow for currency1
     */
    function getTotalOutflow(RollingOutflowTracker storage tracker)
        internal
        view
        returns (uint256 totalOutflow0, uint256 totalOutflow1)
    {
        return (tracker.totalOutflow0, tracker.totalOutflow1);
    }

    /**
     * @notice Cleans old entries outside the time window
     *         And it does this by updating the tail pointer
     *         Which keeps track of the first item in the buffer that is not stale yet
     * @param tracker The tracker to clean
     * @param currentTime The current timestamp
     */
    function _subtractStaleEntryFromRunningTotal(RollingOutflowTracker storage tracker, uint256 currentTime) private {
        // if not enough time has elapsed or if no items have been added yet
        if (currentTime < tracker.timeWindow || tracker.head == tracker.tail) {
            return;
        }

        // if no time window was set, then use full time range and just keep a running sum
        if (tracker.timeWindow == 0) {
            // if time window is 0, we do not need to clean old entries
            // we can just return
            tracker.tail = tracker.head - 1;
            return;
        }

        // otherwise check entries that have become stale from the last stale entry
        uint256 cutoffTime = currentTime - tracker.timeWindow;
        uint256 trailingHead = tracker.tail;

        // iterate from last stale entry until we reach none-stale item or we reach the head i.e all items are stale
        while (trailingHead != tracker.head && tracker.timestamps[trailingHead] <= cutoffTime) {
            // Subtract old outflow from totals
            tracker.totalOutflow0 -= tracker.outflow0[trailingHead];
            tracker.totalOutflow1 -= tracker.outflow1[trailingHead];

            trailingHead = (trailingHead + 1) % BUFFER_SIZE;
        }
        tracker.tail = trailingHead;
    }
}

// SPDX-License-Identifier: MIT
/// @notice Library for tracking rolling outflow of a currency in a pool/market data in a time window
pragma solidity ^0.8.0;

/**
 * @title TimeBucketOutflowTracker
 * @notice Tracks outflow data for a specific time window using time-based bucketing
 * @dev Uses time-based bucketing to track outflow data over configurable time periods
 */
struct TimeBucketOutflowTracker {
    /// @notice Array of start timestamps for each bucket
    uint256[] bucketTimestamps;
    /// @notice Array of aggregated outflow amounts for currency0 per bucket
    uint256[] bucketOutflow0;
    /// @notice Array of aggregated outflow amounts for currency1 per bucket
    uint256[] bucketOutflow1;
    /// @notice Current head bucket index
    uint256 head;
    /// @notice Time window duration in seconds
    uint256 timeWindow;
    /// @notice Precomputed bucket duration in seconds
    uint256 bucketDuration;
    /// @notice Start timestamp of the current head bucket (aligned to bucketDuration)
    uint256 lastBucketStart;
    /// @notice Is Initialized
    bool isInitialized;
}

/**
 * @title TimeBucketOutflowTrackerLibrary
 * @notice Library for managing rolling outflow tracking using time-based bucketing
 * @dev Provides efficient circular buffer implementation for rolling time window calculations
 */
library TimeBucketOutflowTrackerLibrary {
    /// @notice Fixed number of buckets for aggregation
    uint256 public constant NUM_BUCKETS = 1024;

    error AlreadyInitialized();
    error InvalidTimeWindow();

    /**
     * @notice Initializes a new rolling outflow tracker
     * @param tracker The tracker to initialize
     * @param timeWindow The time window duration in seconds
     */
    function initialize(TimeBucketOutflowTracker storage tracker, uint256 timeWindow) internal {
        // confirm not initialized yet
        if (tracker.isInitialized) {
            revert AlreadyInitialized();
        }
        if (timeWindow == 0) {
            revert InvalidTimeWindow();
        }

        tracker.bucketTimestamps = new uint256[](NUM_BUCKETS);
        tracker.bucketOutflow0 = new uint256[](NUM_BUCKETS);
        tracker.bucketOutflow1 = new uint256[](NUM_BUCKETS);
        tracker.timeWindow = timeWindow;
        // Precompute bucketDuration = ceil(timeWindow / NUM_BUCKETS), minimum 1
        uint256 bucketDuration = (timeWindow + NUM_BUCKETS - 1) / NUM_BUCKETS;
        if (bucketDuration == 0) bucketDuration = 1;
        tracker.bucketDuration = bucketDuration;

        // Initialise head and aligned bucket start based on current time
        uint256 currentTime = block.timestamp;
        uint256 currentBucket = (currentTime / bucketDuration) & (NUM_BUCKETS - 1);
        tracker.head = currentBucket;
        uint256 alignedStart = currentTime - (currentTime % bucketDuration);
        tracker.lastBucketStart = alignedStart;
        tracker.bucketTimestamps[currentBucket] = alignedStart;
        tracker.isInitialized = true;
    }

    /**
     * @notice Records new outflow data
     * @param tracker The tracker to update
     * @param outflow0 Outflow amount for currency0
     * @param outflow1 Outflow amount for currency1
     */
    function recordOutflow(TimeBucketOutflowTracker storage tracker, uint256 outflow0, uint256 outflow1) internal {
        // unintitalized tracker
        // do nothing
        if (tracker.isInitialized == false) {
            return;
        }

        uint256 currentTime = block.timestamp;
        uint256 head = tracker.head;
        uint256 lastStart = tracker.lastBucketStart;
        uint256 bucketDuration = tracker.bucketDuration;

        // Fast path: still within current bucket window (no division/modulo)
        if (currentTime < lastStart + bucketDuration) {
            tracker.bucketOutflow0[head] += outflow0;
            tracker.bucketOutflow1[head] += outflow1;
            return;
        }

        // Crossed one or more bucket windows; compute how many steps forward
        uint256 steps = (currentTime - lastStart) / bucketDuration;
        uint256 newHead = (head + steps) & (NUM_BUCKETS - 1);

        // Reset destination bucket and set its start timestamp aligned to bucket boundary
        tracker.bucketOutflow0[newHead] = 0;
        tracker.bucketOutflow1[newHead] = 0;
        uint256 newStart = lastStart + steps * bucketDuration;
        tracker.bucketTimestamps[newHead] = newStart;

        // Update head and last start
        tracker.head = newHead;
        tracker.lastBucketStart = newStart;

        // Aggregate into new head bucket
        tracker.bucketOutflow0[newHead] += outflow0;
        tracker.bucketOutflow1[newHead] += outflow1;
    }

    /**
     * @notice Gets the total outflow in the current time window
     * @param tracker The tracker to query
     * @return totalOutflow0 Total outflow for currency0
     * @return totalOutflow1 Total outflow for currency1
     */
    function getTotalOutflow(TimeBucketOutflowTracker storage tracker)
        internal
        view
        returns (uint256 totalOutflow0, uint256 totalOutflow1)
    {
        uint256 total0 = 0;
        uint256 total1 = 0;

        if (tracker.timeWindow == 0) {
            // If no time window, sum all buckets
            for (uint256 i = 0; i < NUM_BUCKETS; i++) {
                total0 += tracker.bucketOutflow0[i];
                total1 += tracker.bucketOutflow1[i];
            }
            return (total0, total1);
        }

        uint256 cutoffTime = block.timestamp >= tracker.timeWindow ? block.timestamp - tracker.timeWindow : 0;

        // Scan all buckets; include only those within the window
        for (uint256 i = 0; i < NUM_BUCKETS; i++) {
            uint256 ts = tracker.bucketTimestamps[i];
            if (ts != 0 && ts > cutoffTime) {
                total0 += tracker.bucketOutflow0[i];
                total1 += tracker.bucketOutflow1[i];
            }
        }

        return (total0, total1);
    }
}

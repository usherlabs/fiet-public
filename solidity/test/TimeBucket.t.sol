// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {TimeBucketOutflowTracker, TimeBucketOutflowTrackerLibrary} from "../src/libraries/TimeBucket.sol";

contract TimeBucketOutflowTrackerTest is Test {
    using TimeBucketOutflowTrackerLibrary for TimeBucketOutflowTracker;

    TimeBucketOutflowTracker public tracker;

    uint256 constant TIME_WINDOW = 300; // 5 minutes

    function setUp() public {
        // Ensure non-zero timestamp so bucket timestamps are included in window filtering
        vm.warp(1);
        tracker.initialize(TIME_WINDOW);
    }

    function test_recordOutflow() public {
        // Record some outflows
        tracker.recordOutflow(100, 200);
        tracker.recordOutflow(300, 400);

        // Check the current head bucket accumulated values
        assertEq(tracker.bucketOutflow0[tracker.head], 400); // 100 + 300
        assertEq(tracker.bucketOutflow1[tracker.head], 600); // 200 + 400
    }

    function test_recordAndGetOutflow() public {
        // Record some outflows
        tracker.recordOutflow(100, 200);
        tracker.recordOutflow(300, 400);

        // Check the current head bucket accumulated values
        assertEq(tracker.bucketOutflow0[tracker.head], 400); // 100 + 300
        assertEq(tracker.bucketOutflow1[tracker.head], 600); // 200 + 400

        // Check totals
        (uint256 total0, uint256 total1) = tracker.getTotalOutflow();
        assertEq(total0, 400);
        assertEq(total1, 600);
    }

    function test_timeWindowCleanup() public {
        // Record outflow at time 0
        vm.warp(0);
        tracker.recordOutflow(100, 200);

        // Record outflow at time 200 (within window)
        vm.warp(200);
        tracker.recordOutflow(300, 400);

        // Move time beyond window and record new outflow
        vm.warp(700); // 300 + 5 minutes + 100 seconds
        tracker.recordOutflow(500, 600);
        vm.warp(800); // 300 + 5 minutes + 200 seconds
        tracker.recordOutflow(10, 10);

        // Should only include data within the time window
        (uint256 total0, uint256 total1) = tracker.getTotalOutflow();
        assertEq(total0, 510); // Only the most recent outflow
        assertEq(total1, 610);
    }

    function test_zeroOutflow() public {
        // Record zero outflows
        tracker.recordOutflow(0, 0);
        tracker.recordOutflow(100, 0);
        tracker.recordOutflow(0, 200);

        // Should handle zeros correctly
        (uint256 total0, uint256 total1) = tracker.getTotalOutflow();
        assertEq(total0, 100);
        assertEq(total1, 200);
    }

    function test_bucketReuse() public {
        // Start at time 1 (avoid timestamp 0)
        vm.warp(1);
        tracker.recordOutflow(100, 200); // Goes to bucket 1

        // Record at time 2
        vm.warp(2);
        tracker.recordOutflow(300, 400); // Goes to bucket 2

        // Jump to time 1024 to reuse bucket 0
        vm.warp(1024);
        tracker.recordOutflow(500, 600); // Goes to bucket 0 (reused!)

        // Should only include the most recent outflow
        (uint256 total0, uint256 total1) = tracker.getTotalOutflow();
        assertEq(total0, 500);
        assertEq(total1, 600);
    }
}

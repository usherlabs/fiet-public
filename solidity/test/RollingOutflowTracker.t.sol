// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {RollingOutflowTracker, RollingOutflowTrackerLibrary} from "../src/libraries/RollingOutflow.sol";

contract RollingOutflowTrackerTest is Test {
    using RollingOutflowTrackerLibrary for RollingOutflowTracker;

    RollingOutflowTracker tracker;

    uint256 constant TIME_WINDOW = 300; // 5 minutes

    function setUp() public {
        tracker.initialize(TIME_WINDOW);
    }

    function testRecordAndGetOutflow() public {
        // Record some outflows
        tracker.recordOutflow(100, 200);
        tracker.recordOutflow(300, 400);

        // Check totals
        (uint256 total0, uint256 total1) = tracker.getTotalOutflow();
        assertEq(total0, 400); // 100 + 300
        assertEq(total1, 600); // 200 + 400
    }

    function testTimeWindowCleanup() public {
        // Record outflow at time 0
        vm.warp(0);
        tracker.recordOutflow(100, 200);

        // Record outflow at time 200 (within window)
        vm.warp(200);
        tracker.recordOutflow(300, 400);

        // Move time beyond window and record new outflow
        vm.warp(700); // 300 + 5 minutes + 100 seconds
        tracker.recordOutflow(500, 600);

        // Should have cleaned old entries, only new one remains
        assertEq(tracker.totalOutflow0, 500);
        assertEq(tracker.totalOutflow1, 600);
    }

    function testCircularBuffer() public {
        // Fill buffer beyond BUFFER_SIZE
        for (uint256 i = 0; i < 1005; i++) {
            tracker.recordOutflow(i, i * 2);
        }

        // Should still have BUFFER_SIZE entries
        assertEq(tracker.timestamps.length, 1000);
        assertEq(tracker.head, 5); // Head moved to position 5
    }

    function testZeroOutflow() public {
        // Record zero outflows
        tracker.recordOutflow(0, 0);
        tracker.recordOutflow(100, 0);
        tracker.recordOutflow(0, 200);

        // Should handle zeros correctly
        (uint256 total0, uint256 total1) = tracker.getTotalOutflow();
        assertEq(total0, 100);
        assertEq(total1, 200);
    }

    function testCircularBufferOverflow() public {
        // Nearly fill buffer but leave 100 slots
        uint256 BUFFER_SIZE = RollingOutflowTrackerLibrary.BUFFER_SIZE - 100;

        for (uint256 i = 0; i < BUFFER_SIZE; i++) {
            tracker.recordOutflow(i + 1, (i + 1) * 2);
        }

        assertEq(tracker.head, BUFFER_SIZE); // head corresponds to tip of data
        assertEq(tracker.tail, 0); // tail corresponds to start of stale data

        // Check totals after filling buffer
        (uint256 total0, uint256 total1) = tracker.getTotalOutflow();
        assertGt(total0, 0); // Sum of 1 to 1000
        assertGt(total1, 0); // Sum of 2 to 2000

        // Add one more entry to trigger circular buffer
        // move time ahead a bit
        vm.warp(TIME_WINDOW + 1);
        tracker.recordOutflow(9999, 19998);

        (uint256 total0After, uint256 total1After) = tracker.getTotalOutflow();
        assertEq(total0After, 9999);
        assertEq(total1After, 19998);

        // Should still have entries
        vm.warp(TIME_WINDOW);
        for (uint256 i = 0; i < 100; i++) {
            tracker.recordOutflow(i + 1, (i + 1) * 2);
        }

        assertEq(tracker.head, 1);
        assertEq(tracker.tail, BUFFER_SIZE);

        vm.warp(TIME_WINDOW + TIME_WINDOW + TIME_WINDOW);
        tracker.recordOutflow(9999, 19998);
        (total0, total1) = tracker.getTotalOutflow();
        assertEq(total0, 9999);
        assertEq(total1, 19998);

        assertEq(tracker.head, 2);
        assertEq(tracker.tail, 1);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {MockDebtQueue} from "./_mocks/MockDebtQueue.sol";

contract MarketDebtQueueTest is Test {
    MockDebtQueue debtQueue;
    address mockAsset = address(0x123);
    address user1 = address(0x1);
    address user2 = address(0x2);
    address user3 = address(0x3);
    bytes32 market1 = bytes32("market1");
    bytes32 market2 = bytes32("market2");

    function setUp() public {
        debtQueue = new MockDebtQueue(mockAsset);
    }

    /// @notice Tests adding debt to a specific market (cumulative)
    function testAddMarketDebtRequest() public {
        debtQueue.addMarketDebtRequest(market1, user1, 100);

        assertEq(debtQueue.getMarketTotalDebt(market1), 100);
        assertEq(debtQueue.getUserDebt(market1, user1), 100);
        assertTrue(debtQueue.userHasDebt(market1, user1));
    }

    /// @notice Tests cumulative debt - same user multiple requests
    function testCumulativeDebt() public {
        debtQueue.addMarketDebtRequest(market1, user1, 100);
        debtQueue.addMarketDebtRequest(market1, user1, 50);

        assertEq(debtQueue.getMarketTotalDebt(market1), 150);
        assertEq(debtQueue.getUserDebt(market1, user1), 150);
    }

    /// @notice Tests multiple users with debt in same market
    function testMultipleMarketDebtRequests() public {
        debtQueue.addMarketDebtRequest(market1, user1, 100);
        debtQueue.addMarketDebtRequest(market1, user2, 50);
        debtQueue.addMarketDebtRequest(market2, user3, 75);

        assertEq(debtQueue.getMarketTotalDebt(market1), 150);
        assertEq(debtQueue.getMarketTotalDebt(market2), 75);
        assertEq(debtQueue.getMarketQueueLength(market1), 2);
        assertEq(debtQueue.getMarketQueueLength(market2), 1);
    }

    /// @notice Tests processing debt by smallest amount first
    function testProcessMarketDebtQueueSmallestFirst() public {
        debtQueue.addMarketDebtRequest(market1, user1, 100); // Large debt
        debtQueue.addMarketDebtRequest(market1, user2, 30); // Small debt
        debtQueue.addMarketDebtRequest(market1, user3, 75); // Medium debt

        // Process with enough liquidity for smallest debt only
        uint256 processed = debtQueue.processMarketDebtQueue(market1, 30);

        assertEq(processed, 30);
        assertEq(debtQueue.getMarketTotalDebt(market1), 175); // 100 + 75 remaining
        assertEq(debtQueue.getUserDebt(market1, user2), 0); // Smallest paid first
        assertEq(debtQueue.getUserDebt(market1, user1), 100); // Large unpaid
        assertEq(debtQueue.getUserDebt(market1, user3), 75); // Medium unpaid
        assertFalse(debtQueue.userHasDebt(market1, user2));
    }

    /// @notice Tests partial payment of smallest debt
    function testProcessMarketDebtQueuePartialPayment() public {
        debtQueue.addMarketDebtRequest(market1, user1, 100);
        debtQueue.addMarketDebtRequest(market1, user2, 50);

        // Process with partial liquidity for smallest debt
        uint256 processed = debtQueue.processMarketDebtQueue(market1, 25);

        assertEq(processed, 25);
        assertEq(debtQueue.getMarketTotalDebt(market1), 125); // 150 - 25
        assertEq(debtQueue.getUserDebt(market1, user2), 25); // 50 - 25 partial payment
        assertEq(debtQueue.getUserDebt(market1, user1), 100); // Untouched
        assertTrue(debtQueue.userHasDebt(market1, user2)); // Still has debt
    }

    /// @notice Tests processing with more liquidity than total debt
    function testProcessMarketDebtQueueMoreThanNeeded() public {
        debtQueue.addMarketDebtRequest(market1, user1, 100);
        debtQueue.addMarketDebtRequest(market1, user2, 50);

        // Process with more liquidity than needed
        uint256 processed = debtQueue.processMarketDebtQueue(market1, 200);

        assertEq(processed, 150); // Only processes actual debt
        assertEq(debtQueue.getMarketTotalDebt(market1), 0);
        assertEq(debtQueue.getUserDebt(market1, user1), 0);
        assertEq(debtQueue.getUserDebt(market1, user2), 0);
        assertFalse(debtQueue.userHasDebt(market1, user1));
        assertFalse(debtQueue.userHasDebt(market1, user2));
    }

    /// @notice Tests market acquisition tracking
    function testTrackMarketAcquisition() public {
        debtQueue.trackMarketAcquisition(user1, market1, 100);
        debtQueue.trackMarketAcquisition(user1, market2, 50);

        assertEq(debtQueue.getUserMarketBalance(user1, market1), 100);
        assertEq(debtQueue.getUserMarketBalance(user1, market2), 50);
    }

    /// @notice Tests that different markets have isolated debt
    function testMarketIsolation() public {
        debtQueue.addMarketDebtRequest(market1, user1, 100);
        debtQueue.addMarketDebtRequest(market2, user1, 50);

        assertEq(debtQueue.getMarketTotalDebt(market1), 100);
        assertEq(debtQueue.getMarketTotalDebt(market2), 50);

        // Process only market1
        uint256 processed = debtQueue.processMarketDebtQueue(market1, 100);
        assertEq(processed, 100);
        assertEq(debtQueue.getMarketTotalDebt(market1), 0);
        assertEq(debtQueue.getMarketTotalDebt(market2), 50); // Unchanged
    }

    /// @notice Tests zero debt users are skipped
    function testSkipZeroDebt() public {
        debtQueue.addMarketDebtRequest(market1, user1, 100);
        debtQueue.addMarketDebtRequest(market1, user2, 50);

        // Pay user2's debt fully
        debtQueue.processMarketDebtQueue(market1, 50);
        assertEq(debtQueue.getUserDebt(market1, user2), 0);

        // Add more debt for user1
        debtQueue.addMarketDebtRequest(market1, user1, 25);

        // Process again - should skip user2 (0 debt) and pay user1
        uint256 processed = debtQueue.processMarketDebtQueue(market1, 50);
        assertEq(processed, 50);
        assertEq(debtQueue.getUserDebt(market1, user1), 75); // 125 - 50
        assertEq(debtQueue.getUserDebt(market1, user2), 0); // Still 0
    }
}

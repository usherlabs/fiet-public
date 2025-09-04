// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {MockSettlementQueue} from "./_mocks/MockSettlementQueue.sol";

contract MarketSettlementQueueTest is Test {
    MockSettlementQueue settlementQueue;
    address mockAsset = address(0x123);
    address user1 = address(0x1);
    address user2 = address(0x2);
    address user3 = address(0x3);
    bytes32 market1 = bytes32("market1");
    bytes32 market2 = bytes32("market2");

    function setUp() public {
        settlementQueue = new MockSettlementQueue(mockAsset);
    }

    /// @notice Tests adding a pending settlement to a specific market (cumulative)
    function testAddMarketSettlementRequest() public {
        settlementQueue.addMarketSettlementRequest(market1, user1, 100);

        assertEq(settlementQueue.getMarketTotalSettlement(market1), 100);
        assertEq(settlementQueue.getUserSettlement(market1, user1), 100);
        assertTrue(settlementQueue.userHasPendingSettlement(market1, user1));
    }

    /// @notice Tests cumulative pending settlements - same user multiple requests
    function testCumulativeSettlement() public {
        settlementQueue.addMarketSettlementRequest(market1, user1, 100);
        settlementQueue.addMarketSettlementRequest(market1, user1, 50);

        assertEq(settlementQueue.getMarketTotalSettlement(market1), 150);
        assertEq(settlementQueue.getUserSettlement(market1, user1), 150);
    }

    /// @notice Tests multiple users with pending settlements in same market
    function testMultipleMarketSettlementRequests() public {
        settlementQueue.addMarketSettlementRequest(market1, user1, 100);
        settlementQueue.addMarketSettlementRequest(market1, user2, 50);
        settlementQueue.addMarketSettlementRequest(market2, user3, 75);

        assertEq(settlementQueue.getMarketTotalSettlement(market1), 150);
        assertEq(settlementQueue.getMarketTotalSettlement(market2), 75);
        assertEq(settlementQueue.getNumPendingSettlementOwners(market1), 2);
        assertEq(settlementQueue.getNumPendingSettlementOwners(market2), 1);
    }

    /// @notice Tests partial payment of smallest pending settlement
    function testProcessMarketSettlementQueuePartialPayment() public {
        settlementQueue.addMarketSettlementRequest(market1, user2, 50);
        settlementQueue.addMarketSettlementRequest(market1, user1, 100);

        // Process with partial liquidity for smallest pending settlement
        uint256 processed = settlementQueue.processMarketSettlementQueue(market1, 25);

        assertEq(processed, 25);
        assertEq(settlementQueue.getMarketTotalSettlement(market1), 125); // 150 - 25
        assertEq(settlementQueue.getUserSettlement(market1, user2), 25); // 50 - 25 partial payment
        assertEq(settlementQueue.getUserSettlement(market1, user1), 100); // Untouched
        assertTrue(settlementQueue.userHasPendingSettlement(market1, user2)); // Still has pending settlement
    }

    /// @notice Tests processing with more liquidity than total pending settlements
    function testProcessMarketSettlementQueueMoreThanNeeded() public {
        settlementQueue.addMarketSettlementRequest(market1, user1, 100);
        settlementQueue.addMarketSettlementRequest(market1, user2, 50);

        // Process with more liquidity than needed for pending settlements
        uint256 processed = settlementQueue.processMarketSettlementQueue(market1, 200);

        assertEq(processed, 150); // Only processes actual pending settlement
        assertEq(settlementQueue.getMarketTotalSettlement(market1), 0);
        assertEq(settlementQueue.getUserSettlement(market1, user1), 0);
        assertEq(settlementQueue.getUserSettlement(market1, user2), 0);
        assertFalse(settlementQueue.userHasPendingSettlement(market1, user1));
        assertFalse(settlementQueue.userHasPendingSettlement(market1, user2));
    }

    /// @notice Tests market acquisition tracking
    function testTrackMarketAcquisition() public {
        settlementQueue.trackMarketAcquisition(user1, market1, 100);
        settlementQueue.trackMarketAcquisition(user1, market2, 50);

        assertEq(settlementQueue.getUserMarketBalance(user1, market1), 100);
        assertEq(settlementQueue.getUserMarketBalance(user1, market2), 50);
    }

    /// @notice Tests that different markets have isolated settlement queues
    function testMarketIsolation() public {
        settlementQueue.addMarketSettlementRequest(market1, user1, 100);
        settlementQueue.addMarketSettlementRequest(market2, user1, 50);

        assertEq(settlementQueue.getMarketTotalSettlement(market1), 100);
        assertEq(settlementQueue.getMarketTotalSettlement(market2), 50);

        // Process only market1 settlement queue
        uint256 processed = settlementQueue.processMarketSettlementQueue(market1, 100);
        assertEq(processed, 100);
        assertEq(settlementQueue.getMarketTotalSettlement(market1), 0);
        assertEq(settlementQueue.getMarketTotalSettlement(market2), 50);
    }
}

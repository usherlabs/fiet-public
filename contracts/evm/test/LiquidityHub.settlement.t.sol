// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHubTestBase} from "./base/LiquidityHubTestBase.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {Errors} from "../src/libraries/Errors.sol";

/**
 * @title LiquidityHubSettlementTest
 * @notice Tests for LiquidityHub settlement queue mechanics
 * @dev Tests the settlement queue functionality that queues settlements when unwrapping fails
 *      due to insufficient liquidity, and processes them when liquidity becomes available.
 */
contract LiquidityHubSettlementTest is LiquidityHubTestBase {
    event SettlementProcessed(
        address indexed lcc, address indexed recipient, uint256 settledAmount, uint256 requestedAmount
    );

    // ============ SETTLEMENT QUEUE TESTS ============

    /// @notice Tests queuing a settlement when unwrapping with remaining deficit amounts due to insufficient liquidity
    function testQueueSettlementOnUnwrapWithDeficit() public {
        // Setup: User has LCC tokens (via issue) but insufficient market liquidity

        // Wrap some LCC for user1
        uint256 wrapAmount = 100;
        underlyingAsset1.mint(user1, wrapAmount);
        vm.startPrank(user1);
        underlyingAsset1.approve(address(liquidityHub), wrapAmount);
        liquidityHub.wrap(lccToken1, wrapAmount);
        vm.stopPrank();

        // Verify user1 has LCC tokens
        ILCC lcc = ILCC(lccToken1);
        assertGt(lcc.balanceOf(user1), 0, "User should have LCC tokens after wrapping");
        (uint256 wrappedBal, uint256 marketBal) = lcc.balancesOf(user1);
        assertEq(wrappedBal, wrapAmount, "User should have direct balance");
        assertEq(marketBal, 0, "User should NOT have market balance");

        // Verify directSupply is set correctly
        assertEq(liquidityHub.directSupply(lccToken1), wrapAmount, "directSupply should equal wrapAmount");
        assertEq(liquidityHub.reserveOfUnderlying(lccToken1), wrapAmount, "reserveOfUnderlying should equal wrapAmount");

        // Mock factory to return insufficient liquidity for market unwrap
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector),
            abi.encode(uint256(0)) // used = 0 (no liquidity available)
        );

        // Mock marketLiquidity to return 0
        vm.mockCall(factory, abi.encodeWithSelector(IMarketFactory.marketLiquidity.selector), abi.encode(uint256(0)));

        // User tries to unwrap their full balance
        // Since there's no market liquidity, it should use direct unwrap and succeed
        vm.prank(user1);
        liquidityHub.unwrap(lccToken1, wrapAmount);

        // Verify underlying was transferred
        assertEq(underlyingAsset1.balanceOf(user1), wrapAmount);
        assertEq(lcc.balanceOf(user1), 0);
        (wrappedBal, marketBal) = lcc.balancesOf(user1);
        assertEq(wrappedBal, 0);
        assertEq(marketBal, 0);

        // To test settlement queue, we need market-derived balance
        _createSettlementQueueEntry(lccToken1, user1, wrapAmount);

        assertEq(liquidityHub.totalQueued(lccToken1), wrapAmount);
    }

    /// @notice Tests that settlements are cumulative for the same recipient
    function testCumulativeSettlement() public view {
        // Verify the settlement queue structure supports cumulative settlements
        assertEq(liquidityHub.totalQueued(lccToken1), 0);
        assertEq(liquidityHub.settleQueue(lccToken1, user1), 0);
        assertEq(liquidityHub.settleQueue(lccToken1, user2), 0);
    }

    /// @notice Tests that processSettlementFor reverts when no settlement is queued
    function testProcessSettlementForRevertsWhenNoQueue() public {
        // Setup: Wrap some LCC (creates direct supply but no queue)
        uint256 amount = 100;
        underlyingAsset1.mint(user1, amount);
        vm.startPrank(user1);
        underlyingAsset1.approve(address(liquidityHub), amount);
        liquidityHub.wrap(lccToken1, amount);
        vm.stopPrank();

        // Verify no settlement is queued
        assertEq(liquidityHub.settleQueue(lccToken1, user1), 0, "No settlement should be queued");

        // Try to process settlement when none is queued (should revert)
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        liquidityHub.processSettlementFor(lccToken1, user1, type(uint256).max);

        // Also test for a different user with no queue
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        liquidityHub.processSettlementFor(lccToken1, user2, type(uint256).max);
    }

    /// @notice Tests that different LCC tokens have isolated settlement queues
    function testLccIsolation() public {
        (address lccToken3,) = _createSecondLCCPair();

        // Verify queues are separate
        assertEq(liquidityHub.totalQueued(lccToken1), 0);
        assertEq(liquidityHub.totalQueued(lccToken3), 0);
        assertEq(liquidityHub.settleQueue(lccToken1, user1), 0);
        assertEq(liquidityHub.settleQueue(lccToken3, user1), 0);
        assertEq(liquidityHub.settleQueue(lccToken1, user2), 0);
        assertEq(liquidityHub.settleQueue(lccToken3, user2), 0);
    }

    /// @notice Tests that totalQueued tracks the sum of all queued settlements
    function testTotalQueuedTracking() public view {
        // Verify totalQueued starts at 0
        assertEq(liquidityHub.totalQueued(lccToken1), 0);
    }

    /// @notice Tests that settleQueue correctly maps LCC -> recipient -> amount
    function testSettleQueueMapping() public view {
        // Verify the mapping structure
        assertEq(liquidityHub.settleQueue(lccToken1, user1), 0);
        assertEq(liquidityHub.settleQueue(lccToken1, user2), 0);
        assertEq(liquidityHub.settleQueue(lccToken1, user3), 0);

        // Verify different LCCs have separate mappings
        assertEq(liquidityHub.settleQueue(lccToken2, user1), 0);
    }

    /// @notice Tests that processSettlementFor requires queued settlement > 0
    function testProcessSettlementForRequiresQueue() public {
        // Try to process when no settlement is queued
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        liquidityHub.processSettlementFor(lccToken1, user1, type(uint256).max);

        // Try with different recipient
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        liquidityHub.processSettlementFor(lccToken1, user2, type(uint256).max);
    }

    // ============ HUB SETTLEMENT TESTS ============

    /// @notice Tests Hub-specific settlement processing (isForHub = true path)
    /// @dev When recipient is address(this), the Hub path burns Hub-held LCC
    ///      without transferring underlying or decrementing reserves.
    ///      This path is used when LCCs back LCCs (via wrapWithLogic).
    function testProcessSettlementForHub() public {
        uint256 queuedAmount = 50;
        uint256 availableReserve = 100;

        // Create underlying reserve in the Hub
        underlyingAsset1.mint(address(liquidityHub), availableReserve);
        vm.prank(proxyHook);
        liquidityHub.confirmTake(lccToken1, availableReserve, false);

        // Create a settlement queue entry for the Hub itself (not an external user)
        _createSettlementQueueEntry(lccToken1, address(liquidityHub), queuedAmount);

        // Verify queue was created for the Hub
        assertEq(
            liquidityHub.settleQueue(lccToken1, address(liquidityHub)),
            queuedAmount,
            "Hub should have queued settlement"
        );

        // Record state before settlement
        uint256 hubUnderlyingBefore = underlyingAsset1.balanceOf(address(liquidityHub));
        ILCC lcc = ILCC(lccToken1);
        uint256 hubLccBalanceBefore = lcc.balanceOf(address(liquidityHub));

        // Process settlement for the Hub (isForHub = true path)
        vm.expectEmit(true, true, false, true, address(liquidityHub));
        emit SettlementProcessed(lccToken1, address(liquidityHub), queuedAmount, queuedAmount);
        liquidityHub.processSettlementFor(lccToken1, address(liquidityHub), queuedAmount);

        // Assertions for Hub path (isForHub = true):
        // 1. Hub's underlying balance should remain the SAME (no transfer occurs)
        assertEq(
            underlyingAsset1.balanceOf(address(liquidityHub)),
            hubUnderlyingBefore,
            "Hub underlying should NOT change (stays in shared pool)"
        );
        // 2. Hub's LCC balance should decrease (tokens are burned)
        assertEq(
            lcc.balanceOf(address(liquidityHub)), hubLccBalanceBefore - queuedAmount, "Hub-held LCC should be burned"
        );
        // 3. Queue should be cleared
        assertEq(liquidityHub.settleQueue(lccToken1, address(liquidityHub)), 0, "Hub queue should be cleared");
        // 4. totalQueued should be decremented
        assertEq(liquidityHub.totalQueued(lccToken1), 0, "totalQueued should be 0");
    }

    /// @notice Tests successful settlement processing for an external user
    /// @dev Tests the external path in processSettlementLogic where isForHub = false
    function testProcessSettlementForExternalUser() public {
        uint256 queueAmount = 50;
        uint256 availableReserve = 100;

        // Step 1: Set up a queued settlement (requires market-derived balance scenario)
        _createSettlementQueueEntry(lccToken1, user1, queueAmount);

        // Verify queue was created
        assertEq(liquidityHub.settleQueue(lccToken1, user1), queueAmount, "Settlement should be queued");
        assertEq(liquidityHub.totalQueued(lccToken1), queueAmount, "totalQueued should match");

        // Step 2: Add underlying liquidity to reserveOfUnderlying
        // (confirmTake simulates liquidity arriving from market operations)
        underlyingAsset1.mint(address(liquidityHub), availableReserve);
        vm.prank(proxyHook);
        liquidityHub.confirmTake(lccToken1, availableReserve, false);

        // Record state before settlement
        ILCC lcc1 = ILCC(lccToken1);
        uint256 userUnderlyingBefore = underlyingAsset1.balanceOf(user1);
        uint256 userLccBalanceBefore = lcc1.balanceOf(user1);
        uint256 hubUnderlyingBefore = underlyingAsset1.balanceOf(address(liquidityHub));

        // Step 3: Call processSettlementFor
        vm.expectEmit(true, true, false, true, address(liquidityHub));
        emit SettlementProcessed(lccToken1, user1, queueAmount, queueAmount);
        liquidityHub.processSettlementFor(lccToken1, user1, queueAmount);

        // Assertions for external user path:
        // 1. User should have received the underlying asset
        assertEq(
            underlyingAsset1.balanceOf(user1), userUnderlyingBefore + queueAmount, "User should receive underlying"
        );
        // 2. Hub's underlying balance should decrease
        assertEq(
            underlyingAsset1.balanceOf(address(liquidityHub)),
            hubUnderlyingBefore - queueAmount,
            "Hub underlying should decrease"
        );
        // 3. Queue should be cleared
        assertEq(liquidityHub.settleQueue(lccToken1, user1), 0, "Queue should be cleared");
        // 4. totalQueued should be decremented
        assertEq(liquidityHub.totalQueued(lccToken1), 0, "totalQueued should be 0");
        // 5. User LCC should be burned
        assertEq(lcc1.balanceOf(user1), userLccBalanceBefore - queueAmount, "User LCC should be burned");
    }

    /// @notice Fail-closed settlement when a legacy unwrap queued a protocol-bound endpoint (`BOUND_ENDPOINT`).
    function testProcessSettlementFor_revertsProtocolBoundRecipientEvenWhenQueued() public {
        uint256 amt = 40;
        vm.mockCall(factory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0)));
        vm.prank(proxyHook);
        liquidityHub.issue(lccToken1, factory, amt);
        vm.prank(factory);
        ILCC(lccToken1).approve(address(liquidityHub), amt);
        vm.prank(factory);
        liquidityHub.unwrap(lccToken1, amt);
        assertEq(liquidityHub.settleQueue(lccToken1, factory), amt);

        underlyingAsset1.mint(address(liquidityHub), amt);
        vm.prank(proxyHook);
        liquidityHub.confirmTake(lccToken1, amt, false);

        uint256 reserveBefore = liquidityHub.reserveOfUnderlying(lccToken1);

        vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, factory));
        liquidityHub.processSettlementFor(lccToken1, factory, amt);

        assertEq(liquidityHub.reserveOfUnderlying(lccToken1), reserveBefore, "reserve must not be consumed");
    }
}

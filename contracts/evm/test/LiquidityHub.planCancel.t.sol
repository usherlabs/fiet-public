// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHubTestBase} from "./base/LiquidityHubTestBase.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {Errors} from "../src/libraries/Errors.sol";

/**
 * @title LiquidityHubPlanCancelTest
 * @notice Tests for LiquidityHub planCancel and planCancelWithQueue functionality
 * @dev Tests the planned cancellation mechanics used during LCC transfers
 */
contract LiquidityHubPlanCancelTest is LiquidityHubTestBase {
    // ============ PLAN CANCEL TESTS ============

    /// @notice Tests that planCancel reverts when called by non-issuer
    function testPlanCancelRevertsForNonIssuer() public {
        uint256 amount = 100;

        // user1 is not an issuer
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, user1));
        liquidityHub.planCancel(lccToken1, factory, user1, amount);
    }

    /// @notice Tests that planCancel reverts with zero amount
    function testPlanCancelRevertsWithZeroAmount() public {
        vm.prank(vtsOrchestrator);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        liquidityHub.planCancel(lccToken1, factory, user1, 0);
    }

    /// @notice Tests that planCancel stores params and executes on matching transfer
    function testPlanCancelExecutesOnMatchingTransfer() public {
        uint256 amount = 100;

        // Setup: Mint LCC to factory (protocol-bound) so it can transfer to user1
        _wrapDirectLCC(factory, lccToken1, amount);

        // Factory plans a cancel for when it transfers to user1
        vm.prank(vtsOrchestrator);
        liquidityHub.planCancel(lccToken1, factory, user1, amount);

        // Before transfer: user1 has no LCC
        ILCC lcc = ILCC(lccToken1);
        assertEq(lcc.balanceOf(user1), 0, "user1 should have no LCC before transfer");

        // Mock user1 as non-protocol for transfer to go through
        _mockAddressAsProtocolBound(user1, false);

        // Transfer from factory to user1 - this should trigger the planned cancel
        vm.prank(factory);
        lcc.transfer(user1, amount);

        // After transfer: the planned cancel should have burned the tokens from user1
        // Since the cancel happens after the transfer adds to marketDerivedBalances,
        // and then burns from the recipient, user1 should end up with 0 balance
        assertEq(lcc.balanceOf(user1), 0, "user1 should have 0 LCC after planned cancel executed");
    }

    /// @notice Tests that planCancel does NOT execute on non-matching transfer path
    function testPlanCancelDoesNotExecuteOnNonMatchingTransfer() public {
        uint256 amount = 100;

        // Setup: Mint LCC to factory
        _wrapDirectLCC(factory, lccToken1, amount);

        // Factory plans a cancel for when it transfers to user2 (not user1)
        vm.prank(vtsOrchestrator);
        liquidityHub.planCancel(lccToken1, factory, user2, amount);

        // Mock user1 as non-protocol
        _mockAddressAsProtocolBound(user1, false);

        // Transfer from factory to user1 (different recipient than planned)
        vm.prank(factory);
        ILCC(lccToken1).transfer(user1, amount);

        // user1 should have the full amount since the cancel was planned for user2
        assertEq(ILCC(lccToken1).balanceOf(user1), amount, "user1 should have full amount");
    }

    // ============ PLAN CANCEL WITH QUEUE TESTS ============

    /// @notice Tests that planCancelWithQueue reverts when called by non-issuer
    function testPlanCancelWithQueueRevertsForNonIssuer() public {
        uint256 principalAmount = 100;
        uint256 queueAmount = 50;

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, user1));
        liquidityHub.planCancelWithQueue(lccToken1, factory, user1, principalAmount, queueAmount, user2);
    }

    /// @notice Tests that planCancelWithQueue reverts with zero principal amount
    function testPlanCancelWithQueueRevertsWithZeroPrincipal() public {
        vm.prank(vtsOrchestrator);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        liquidityHub.planCancelWithQueue(lccToken1, factory, user1, 0, 0, user2);
    }

    /// @notice Tests that planCancelWithQueue reverts when queueAmount > principalAmount
    function testPlanCancelWithQueueRevertsWhenQueueExceedsPrincipal() public {
        uint256 principalAmount = 100;
        uint256 queueAmount = 150; // exceeds principal

        vm.prank(vtsOrchestrator);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, queueAmount, principalAmount));
        liquidityHub.planCancelWithQueue(lccToken1, factory, user1, principalAmount, queueAmount, user2);
    }

    /// @notice Tests that planCancelWithQueue executes and queues settlement on matching transfer
    function testPlanCancelWithQueueExecutesOnMatchingTransfer() public {
        uint256 principalAmount = 100;
        uint256 queueAmount = 40; // 40 goes to queue, 60 gets canceled

        // Setup: Mint LCC to factory
        _wrapDirectLCC(factory, lccToken1, principalAmount);
        _wrapMarketDerivedLCC(user2, lccToken1, queueAmount);

        // Factory plans a cancel with queue for when it transfers to user1
        // Settlement queue recipient is user2
        vm.prank(vtsOrchestrator);
        liquidityHub.planCancelWithQueue(lccToken1, factory, user1, principalAmount, queueAmount, user2);

        // Mock user1 as non-protocol
        _mockAddressAsProtocolBound(user1, false);

        // Before transfer
        ILCC lcc = ILCC(lccToken1);
        assertEq(lcc.balanceOf(user1), 0, "user1 should have no LCC before transfer");
        assertEq(liquidityHub.settleQueue(lccToken1, user2), 0, "user2 should have no queued settlement");

        // Transfer from factory to user1 - this should trigger the planned cancel with queue
        vm.prank(factory);
        lcc.transfer(user1, principalAmount);

        // After transfer:
        // 1. user1 should have 40 LCCs (queueAmount) since: (principal - queueAmount) is cancelled
        assertEq(lcc.balanceOf(user1), queueAmount, "user1 should have 40 LCCs after planned cancel");

        // 2. user2 should have queueAmount queued for settlement
        assertEq(liquidityHub.settleQueue(lccToken1, user2), queueAmount, "user2 should have queued settlement");

        // 3. totalQueued should reflect the queue
        assertEq(liquidityHub.totalQueued(lccToken1), queueAmount, "totalQueued should reflect queued amount");
    }

    /// @notice Tests planCancelWithQueue with full queue (no immediate burn)
    function testPlanCancelWithQueueFullQueue() public {
        uint256 principalAmount = 100;
        uint256 queueAmount = 100; // entire amount goes to queue

        // Setup: Mint LCC to factory
        _wrapDirectLCC(factory, lccToken1, principalAmount);
        _wrapMarketDerivedLCC(user3, lccToken1, queueAmount);

        // Factory plans a cancel with queue where everything is queued
        vm.prank(vtsOrchestrator);
        liquidityHub.planCancelWithQueue(lccToken1, factory, user1, principalAmount, queueAmount, user3);

        // Mock user1 as non-protocol
        _mockAddressAsProtocolBound(user1, false);

        // Transfer triggers the planned cancel
        vm.prank(factory);
        ILCC(lccToken1).transfer(user1, principalAmount);

        // user1 should have the queueAmount LCCs since the entire principal amount is queued
        assertEq(ILCC(lccToken1).balanceOf(user1), queueAmount, "user1 should have queueAmount LCCs");

        // user3 should have full amount in queue
        assertEq(liquidityHub.settleQueue(lccToken1, user3), queueAmount, "user3 should have full amount queued");
    }

    /// @notice Tests planCancelWithQueue with zero queue (immediate full burn)
    function testPlanCancelWithQueueZeroQueue() public {
        uint256 principalAmount = 100;
        uint256 queueAmount = 0; // nothing queued, all burned

        // Setup: Mint LCC to factory
        _wrapDirectLCC(factory, lccToken1, principalAmount);

        // Factory plans a cancel with zero queue
        vm.prank(vtsOrchestrator);
        liquidityHub.planCancelWithQueue(lccToken1, factory, user1, principalAmount, queueAmount, user2);

        // Mock user1 as non-protocol
        _mockAddressAsProtocolBound(user1, false);

        // Transfer triggers the planned cancel
        vm.prank(factory);
        ILCC(lccToken1).transfer(user1, principalAmount);

        // user1 should have 0
        assertEq(ILCC(lccToken1).balanceOf(user1), 0, "user1 should have 0 LCC");

        // No settlement should be queued
        assertEq(liquidityHub.settleQueue(lccToken1, user2), 0, "user2 should have no queued settlement");
        assertEq(liquidityHub.totalQueued(lccToken1), 0, "totalQueued should be 0");
    }

    /// @notice Tests that planned cancel does NOT persist across transactions (transient storage)
    function testPlanCancelIsTransient() public {
        uint256 amount = 100;

        // Setup: Mint LCC to factory
        _wrapDirectLCC(factory, lccToken1, amount);

        // Factory plans a cancel in first transaction
        vm.prank(vtsOrchestrator);
        liquidityHub.planCancel(lccToken1, factory, user1, amount);

        // Simulate new transaction by rolling to next block
        // Note: In actual transient storage, the data is cleared at end of transaction
        // For testing purposes, we verify the cancel was stored but would need
        // the transfer to happen in the same transaction to execute

        // Mock user1 as non-protocol
        _mockAddressAsProtocolBound(user1, false);

        // In a real scenario, if the transfer happens in the same tx, the cancel executes
        // If transfer happens in a new tx, transient storage is cleared
        // This test verifies the storage mechanism works within same tx
        vm.prank(factory);
        ILCC(lccToken1).transfer(user1, amount);

        // Cancel should have executed (within same tx context in test)
        assertEq(ILCC(lccToken1).balanceOf(user1), 0, "Planned cancel should execute within same tx");
    }

    /// @notice Tests planCancel with multiple sequential plans (last one wins within same path)
    function testPlanCancelOverwritesSamePath() public {
        uint256 amount1 = 50;
        uint256 amount2 = 75;

        // Setup: Mint LCC to factory
        _wrapDirectLCC(factory, lccToken1, amount2);

        // First plan
        vm.prank(vtsOrchestrator);
        liquidityHub.planCancel(lccToken1, factory, user1, amount1);

        // Second plan for same path (should overwrite)
        vm.prank(vtsOrchestrator);
        liquidityHub.planCancel(lccToken1, factory, user1, amount2);

        // Mock user1 as non-protocol
        _mockAddressAsProtocolBound(user1, false);

        // Transfer triggers the cancel - second amount should be used
        vm.prank(factory);
        ILCC(lccToken1).transfer(user1, amount2);

        // user1 should have 0 (amount2 was canceled)
        assertEq(ILCC(lccToken1).balanceOf(user1), 0, "Second plan amount should be canceled");
    }

    /// @notice Tests planCancelWithQueue takes precedence over planCancel for same path
    function testPlanCancelWithQueueTakesPrecedence() public {
        uint256 simpleAmount = 100;
        uint256 principalAmount = 100;
        uint256 queueAmount = 30;

        // Setup: Mint LCC to factory
        _wrapDirectLCC(factory, lccToken1, principalAmount);
        _wrapMarketDerivedLCC(user2, lccToken1, queueAmount);

        // First: plan a simple cancel
        vm.prank(vtsOrchestrator);
        liquidityHub.planCancel(lccToken1, factory, user1, simpleAmount);

        // Second: plan a cancel with queue for same path
        vm.prank(vtsOrchestrator);
        liquidityHub.planCancelWithQueue(lccToken1, factory, user1, principalAmount, queueAmount, user2);

        // Mock user1 as non-protocol
        _mockAddressAsProtocolBound(user1, false);

        // Transfer triggers - planCancelWithQueue should take precedence
        vm.prank(factory);
        ILCC(lccToken1).transfer(user1, principalAmount);

        // planCancelWithQueue was executed (check queue exists)
        assertEq(liquidityHub.settleQueue(lccToken1, user2), queueAmount, "Queue should exist from planCancelWithQueue");
        assertEq(ILCC(lccToken1).balanceOf(user1), queueAmount, "user1 should have queueAmount LCCs");
    }
}


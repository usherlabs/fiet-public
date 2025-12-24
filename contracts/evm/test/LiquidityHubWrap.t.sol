// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LiquidityHubTestBase} from "./LiquidityHubTestBase.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {MockERC20} from "./_mocks/MockERC20.sol";

/**
 * @title LiquidityHubWrapTest
 * @notice Tests for LiquidityHub wrap, unwrap, wrapWith and wrapWithTo functionality
 * @dev Tests the wrap/unwrap mechanics including O(1) flattening and cross-LCC operations
 */
contract LiquidityHubWrapTest is LiquidityHubTestBase {
    // ============ WRAP WITH LCC : O(1) FLATTENING TESTS ============

    /// @notice Tests O(1) flattening: wrapping withLCC into lcc immediately flattens withLCC
    function testWrapWithFlattensImmediately() public {
        // Setup: Create two LCC tokens with same underlying
        // ensures that the liquidity hub address is protocol-bound
        // so that it can facilitate transfers
        vm.mockCall(
            factory, abi.encodeWithSelector(IMarketFactory.bounds.selector, address(liquidityHub)), abi.encode(true)
        );

        (address lccToken3,) = _createSecondLCCPair();

        // Wrap some LCC for user1
        uint256 wrapAmount = 100;

        // Wrap underlying to create withLCC balance
        _wrapDirectLCC(user1, lccToken1, wrapAmount);

        // Verify withLCC has directSupply
        assertEq(liquidityHub.directSupply(lccToken1), wrapAmount, "withLCC should have directSupply");

        // Now wrap lccToken3 using lccToken1 as backing
        uint256 wrapWithAmount = 50;
        ILCC withLCC = ILCC(lccToken1);
        ILCC toLCC = ILCC(lccToken3);

        // Wrap lccToken3 using lccToken1 as backing
        vm.startPrank(user1);
        withLCC.approve(address(liquidityHub), wrapWithAmount);
        liquidityHub.wrapWith(address(toLCC), address(withLCC), wrapWithAmount);
        vm.stopPrank();

        // Verify: withLCC's directSupply should be consumed (flattened)
        assertEq(
            liquidityHub.directSupply(lccToken1), wrapAmount - wrapWithAmount, "withLCC directSupply should be consumed"
        );

        // Verify: lccToken3 was minted to user1
        assertEq(toLCC.balanceOf(user1), wrapWithAmount, "lccToken3 should be minted to user1");
        (uint256 wrappedBal, uint256 marketBal) = toLCC.balancesOf(user1);
        assertEq(wrappedBal, wrapWithAmount, "Should be wrapped balance");
        assertEq(marketBal, 0, "Should not have market balance");

        // Verify: withLCC was burned from Hub
        assertEq(withLCC.balanceOf(address(liquidityHub)), 0, "Hub should not hold withLCC");
    }

    /// @notice Tests O(1) flattening with netting: reverse reserve nets out
    function testWrapWithNetsReverseReserve() public {
        (address lccToken3,) = _createSecondLCCPair();

        uint256 wrapAmount1 = 100;
        ILCC lcc1 = ILCC(lccToken1);
        ILCC lcc2 = ILCC(lccToken3);

        // Wrap underlying to create both LCC balances
        _wrapDirectLCC(user1, address(lcc2), wrapAmount1);

        // First wrap: lcc1 using lccToken3 (this will flatten lccToken3)
        _mockAddressAsProtocolBound(address(liquidityHub), true);
        vm.startPrank(user1);
        lcc2.approve(address(liquidityHub), wrapAmount1);
        liquidityHub.wrapWith(address(lcc1), address(lcc2), wrapAmount1);
        vm.stopPrank();

        // Verify direct supply was transferred (flattening worked)
        assertEq(liquidityHub.directSupply(address(lcc2)), 0, "lccToken3 directSupply should be consumed");
        assertEq(liquidityHub.directSupply(address(lcc1)), wrapAmount1, "lcc1 directSupply should equal amount");
        // Validate the user1 got the lcc1 back
        assertEq(lcc1.balanceOf(user1), wrapAmount1, "user1 should have the amount of lcc1 wrapped");
        assertEq(lcc2.balanceOf(user1), 0, "user1 should have zero lcc2 since it was sent to the hub");

        // Now create a Hub queue for lcc1 (the "reverse reserve" scenario)
        uint256 queueAmount = 50;
        _createSettlementQueueEntry(address(lcc1), address(liquidityHub), queueAmount);
        assertEq(
            liquidityHub.settleQueue(address(lcc1), address(liquidityHub)),
            queueAmount,
            "lcc1 queue should be equal to the queue amount"
        );
        assertEq(lcc1.balanceOf(address(liquidityHub)), queueAmount, "Hub should hold amount of lcc1 that is queued up");

        // Before the second wrapWith, check user1's balance
        uint256 user1BalanceBefore = lcc1.balanceOf(user1);

        // Now wrap lcc1 using lccToken3 - Step 0 should net against Hub queue
        uint256 wrapAmount2 = 30;
        _wrapDirectLCC(user1, address(lcc2), wrapAmount2);

        uint256 queueBefore = liquidityHub.settleQueue(address(lcc1), address(liquidityHub));
        uint256 hubBalanceBefore = lcc1.balanceOf(address(liquidityHub));
        assertEq(hubBalanceBefore, queueAmount, "Hub should hold amount of lcc1 that is queued up");
        assertEq(queueBefore, queueAmount, "Queue should be equal to the queue amount");

        _mockAddressAsProtocolBound(address(liquidityHub), true);
        vm.startPrank(user1);
        lcc2.approve(address(liquidityHub), wrapAmount2);
        liquidityHub.wrapWith(address(lcc1), address(lcc2), wrapAmount2);
        vm.stopPrank();

        // Verify Step 0 netting happened:
        // 1. Queue should be reduced by wrapAmount2
        assertEq(
            liquidityHub.settleQueue(address(lcc1), address(liquidityHub)),
            queueBefore - wrapAmount2,
            "Queue should be reduced by netted amount"
        );

        // 2. Hub-held lccToken1 should be burned
        assertEq(
            lcc1.balanceOf(address(liquidityHub)), hubBalanceBefore - wrapAmount2, "Hub-held lccToken1 should be burned"
        );

        // 3. User should receive lccToken1 (minted as market-derived from queue origin)
        uint256 user1BalanceAfter = lcc1.balanceOf(user1);
        assertEq(
            user1BalanceAfter - user1BalanceBefore, wrapAmount2, "User should receive exactly wrapAmount2 of lccToken1"
        );

        (uint256 wrappedBalance, uint256 marketBalBefore) = lcc1.balancesOf(user1);

        // The wrapped balance should be equal to the wrapAmount1 since that was a direct wrap
        // The market balance should be equal to the netted amount from the queue
        assertEq(wrappedBalance, wrapAmount1, "Wrapped balance should be equal to the wrapAmount1");
        assertEq(
            marketBalBefore,
            wrapAmount2,
            "Market balance should be equal to the netted amount from the queue which is the wrapAmount2"
        );

        // Validate netting of the lccwith queue entry
        uint256 claimAmount = 20;
        ILCC wrapWithLCC = ILCC(lcc1);

        assertEq(liquidityHub.settleQueue(address(wrapWithLCC), address(liquidityHub)), claimAmount);

        // Wrap lcc1 using the wrapWithLCC (should net against the queue entry)
        _mockAddressAsProtocolBound(address(liquidityHub), true);
        vm.startPrank(user1);
        wrapWithLCC.approve(address(liquidityHub), claimAmount);
        liquidityHub.wrapWith(address(lcc2), address(wrapWithLCC), claimAmount);
        vm.stopPrank();
    }

    /// @notice Tests that wrapWith queues shortfall to Hub when market liquidity insufficient
    function testWrapWithQueuesShortfallToHub() public {
        uint256 wrapAmount = 100;
        (address lccToken3,) = _createSecondLCCPair();

        ILCC lcc1 = ILCC(lccToken1);
        ILCC lcc2 = ILCC(lccToken3);

        ILCC withLCC = ILCC(lcc1);

        _wrapMarketDerivedLCC(user1, address(withLCC), wrapAmount);

        // Mock: no directSupply available, no market liquidity
        vm.mockCall(factory, abi.encodeWithSelector(IMarketFactory.marketLiquidity.selector), abi.encode(uint256(0)));
        vm.mockCall(factory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0)));

        _mockAddressAsProtocolBound(address(liquidityHub), true);
        vm.startPrank(user1);
        withLCC.approve(address(liquidityHub), wrapAmount);
        liquidityHub.wrapWith(address(lcc2), address(withLCC), wrapAmount);
        vm.stopPrank();

        // Verify: shortfall should be queued to Hub
        assertGt(liquidityHub.settleQueue(lccToken1, address(liquidityHub)), 0, "Shortfall should be queued to Hub");
        assertGt(liquidityHub.totalQueued(lccToken1), 0, "totalQueued should reflect Hub queue");
    }

    // ============ WRAP WITH LCC : REVERT TESTS ============

    /// @notice Tests wrapWith reverts with zero amount
    function testWrapWithRevertsWithZeroAmount() public {
        (address lccToken3,) = _createSecondLCCPair();

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        liquidityHub.wrapWith(lccToken3, lccToken1, 0);
    }

    /// @notice Tests wrapWith reverts when lcc == withLCC
    function testWrapWithRevertsWhenSameLCC() public {
        uint256 amount = 100;
        _wrapDirectLCC(user1, lccToken1, amount);

        vm.startPrank(user1);
        ILCC(lccToken1).approve(address(liquidityHub), amount);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, lccToken1));
        liquidityHub.wrapWith(lccToken1, lccToken1, amount);
        vm.stopPrank();
    }

    /// @notice Tests wrapWith reverts when underlying assets don't match
    function testWrapWithRevertsWhenUnderlyingMismatch() public {
        // Create a third underlying asset and LCC pair with different underlying
        MockERC20 underlyingAsset3 = new MockERC20("Token3", "TK3", 18);

        vm.startPrank(factory);
        (address lccToken3,) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0x9999)),
            address(underlyingAsset3), // Different underlying!
            address(underlyingAsset2),
            "Test Market 3",
            new address[](0)
        );
        liquidityHub.initialize(lccToken3, lccToken2, bytes32("market3"), abi.encodePacked(address(0x9999)));
        vm.stopPrank();

        // Wrap some LCC for user1
        uint256 amount = 100;
        _wrapDirectLCC(user1, lccToken1, amount);

        // Try to wrap lccToken3 (different underlying) with lccToken1
        _mockAddressAsProtocolBound(address(liquidityHub), true);
        vm.startPrank(user1);
        ILCC(lccToken1).approve(address(liquidityHub), amount);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.UnderlyingAssetMismatch.selector, address(underlyingAsset3), address(underlyingAsset1)
            )
        );
        liquidityHub.wrapWith(lccToken3, lccToken1, amount);
        vm.stopPrank();
    }

    /// @notice Tests wrapWith reverts when amount exceeds balance
    function testWrapWithRevertsWhenAmountExceedsBalance() public {
        (address lccToken3,) = _createSecondLCCPair();
        uint256 wrapAmount = 100;
        _wrapDirectLCC(user1, lccToken1, wrapAmount);

        _mockAddressAsProtocolBound(address(liquidityHub), true);

        vm.startPrank(user1);
        ILCC(lccToken1).approve(address(liquidityHub), wrapAmount + 1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, wrapAmount + 1, wrapAmount));
        liquidityHub.wrapWith(lccToken3, lccToken1, wrapAmount + 1);
        vm.stopPrank();
    }

    /// @notice Tests wrapWith reverts when withLCC is invalid
    function testWrapWithRevertsWhenWithLCCInvalid() public {
        address invalidLCC = address(0xDEAD);
        uint256 amount = 100;

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, invalidLCC));
        liquidityHub.wrapWith(lccToken1, invalidLCC, amount);
    }

    /// @notice Tests wrapWith reverts when target lcc is invalid
    function testWrapWithRevertsWhenTargetLCCInvalid() public {
        address invalidLCC = address(0xDEAD);
        uint256 amount = 100;
        _wrapDirectLCC(user1, lccToken1, amount);

        vm.startPrank(user1);
        ILCC(lccToken1).approve(address(liquidityHub), amount);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, invalidLCC));
        liquidityHub.wrapWith(invalidLCC, lccToken1, amount);
        vm.stopPrank();
    }

    // ============ WRAP WITH TO TESTS ============

    /// @notice Tests wrapWithTo sends to different recipient
    function testWrapWithToSendsToRecipient() public {
        (address lccToken3,) = _createSecondLCCPair();
        uint256 wrapAmount = 100;
        _wrapDirectLCC(user1, lccToken1, wrapAmount);

        _mockAddressAsProtocolBound(address(liquidityHub), true);

        vm.startPrank(user1);
        ILCC(lccToken1).approve(address(liquidityHub), wrapAmount);
        liquidityHub.wrapWithTo(lccToken3, lccToken1, user2, wrapAmount);
        vm.stopPrank();

        // user2 should have the target LCC, not user1
        assertEq(ILCC(lccToken3).balanceOf(user2), wrapAmount, "user2 should receive the target LCC");
        assertEq(ILCC(lccToken3).balanceOf(user1), 0, "user1 should not have target LCC");
    }

    /// @notice Tests wrapWithTo reverts with zero amount
    function testWrapWithToRevertsWithZeroAmount() public {
        (address lccToken3,) = _createSecondLCCPair();

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        liquidityHub.wrapWithTo(lccToken3, lccToken1, user2, 0);
    }

    // ============ WRAP WITH LCC : EDGE CASE TESTS ============

    /// @notice Tests wrapWith with only market-derived balance (zero wrapped)
    function testWrapWithOnlyMarketDerivedBalance() public {
        (address lccToken3,) = _createSecondLCCPair();
        uint256 wrapAmount = 100;

        // Create market-derived balance (not wrapped)
        _wrapMarketDerivedLCC(user1, lccToken1, wrapAmount);

        (uint256 wrappedBal, uint256 marketBal) = ILCC(lccToken1).balancesOf(user1);
        assertEq(wrappedBal, 0, "Should have no wrapped balance");
        assertEq(marketBal, wrapAmount, "Should have market balance");

        // Mock market liquidity for unwrap
        vm.mockCall(factory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(wrapAmount));

        _mockAddressAsProtocolBound(address(liquidityHub), true);

        vm.startPrank(user1);
        ILCC(lccToken1).approve(address(liquidityHub), wrapAmount);
        liquidityHub.wrapWith(lccToken3, lccToken1, wrapAmount);
        vm.stopPrank();

        // Verify LCC was minted
        assertEq(ILCC(lccToken3).balanceOf(user1), wrapAmount, "User should receive target LCC");
    }

    /// @notice Tests wrapWith when user has mixed balance (both wrapped and market-derived)
    function testWrapWithMixedBalance() public {
        (address lccToken3,) = _createSecondLCCPair();
        uint256 directAmount = 50;
        uint256 marketAmount = 50;
        uint256 totalAmount = directAmount + marketAmount;

        // Create mixed balance: first wrapped (direct)
        _wrapDirectLCC(user1, lccToken1, directAmount);

        // Then add market-derived balance manually (don't use helper as it has assertions that conflict)
        _wrapDirectLCC(factory, lccToken1, marketAmount);
        vm.prank(factory);
        ILCC(lccToken1).transfer(user1, marketAmount);

        // Verify user has both balances
        (uint256 userWrapped, uint256 userMarket) = ILCC(lccToken1).balancesOf(user1);
        assertEq(userWrapped, directAmount, "User should have wrapped balance");
        assertEq(userMarket, marketAmount, "User should have market balance");

        // Record state before
        uint256 userTotalBefore = ILCC(lccToken1).balanceOf(user1);
        assertEq(userTotalBefore, totalAmount, "User should have total balance");

        // Mock market liquidity - return the market-derived amount (Step 3 may request market liquidity for residual)
        // The mock returns what was requested (capped to available)
        vm.mockCall(
            factory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(marketAmount)
        );

        _mockAddressAsProtocolBound(address(liquidityHub), true);

        vm.startPrank(user1);
        ILCC(lccToken1).approve(address(liquidityHub), totalAmount);
        liquidityHub.wrapWith(lccToken3, lccToken1, totalAmount);
        vm.stopPrank();

        // Verify user received target LCC
        assertEq(ILCC(lccToken3).balanceOf(user1), totalAmount, "User should receive total amount");

        // Verify source LCC was fully consumed
        assertEq(ILCC(lccToken1).balanceOf(user1), 0, "Source LCC should be fully consumed");
    }

    /// @notice Tests wrapWith when user has no wrapped balance (only market-derived)
    /// @dev This tests the scenario where Step 1 (direct conversion) has no user wrapped balance to process
    function testWrapWithZeroDirectSupply() public {
        (address lccToken3,) = _createSecondLCCPair();
        uint256 wrapAmount = 100;

        // Create only market-derived balance for user
        _wrapMarketDerivedLCC(user1, lccToken1, wrapAmount);

        // Verify user has only market-derived balance
        (uint256 userWrapped, uint256 userMarket) = ILCC(lccToken1).balancesOf(user1);
        assertEq(userWrapped, 0, "User should have no wrapped balance");
        assertEq(userMarket, wrapAmount, "User should have market balance");

        // Mock market liquidity
        vm.mockCall(factory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(wrapAmount));

        _mockAddressAsProtocolBound(address(liquidityHub), true);

        vm.startPrank(user1);
        ILCC(lccToken1).approve(address(liquidityHub), wrapAmount);
        liquidityHub.wrapWith(lccToken3, lccToken1, wrapAmount);
        vm.stopPrank();

        // User should receive target LCC
        assertEq(ILCC(lccToken3).balanceOf(user1), wrapAmount, "User should receive target LCC");
    }

    /// @notice Tests wrapWith with partial amount from mixed balance
    /// @dev Tests that wrapWith correctly handles partial wrapping from a mixed balance
    function testWrapWithPartialFromMixedBalance() public {
        (address lccToken3,) = _createSecondLCCPair();
        uint256 directAmount = 100;
        uint256 marketAmount = 50;
        uint256 wrapWithAmount = 50;

        // Create mixed balance: first wrapped (direct)
        _wrapDirectLCC(user1, lccToken1, directAmount);

        // Then add market-derived balance manually (don't use helper as it has assertions that conflict)
        _wrapDirectLCC(factory, lccToken1, marketAmount);
        vm.prank(factory);
        ILCC(lccToken1).transfer(user1, marketAmount);

        // Verify user has both balances
        (uint256 userWrappedBefore, uint256 userMarketBefore) = ILCC(lccToken1).balancesOf(user1);
        assertEq(userWrappedBefore, directAmount, "User should have wrapped balance");
        assertEq(userMarketBefore, marketAmount, "User should have market balance");

        uint256 totalBefore = ILCC(lccToken1).balanceOf(user1);
        assertEq(totalBefore, directAmount + marketAmount, "User should have total balance");

        // Mock market liquidity
        vm.mockCall(
            factory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(wrapWithAmount)
        );

        _mockAddressAsProtocolBound(address(liquidityHub), true);

        // Wrap partial amount
        vm.startPrank(user1);
        ILCC(lccToken1).approve(address(liquidityHub), wrapWithAmount);
        liquidityHub.wrapWith(lccToken3, lccToken1, wrapWithAmount);
        vm.stopPrank();

        // Verify user received target LCC
        assertEq(ILCC(lccToken3).balanceOf(user1), wrapWithAmount, "User should receive target LCC");

        // Verify source LCC balance decreased by wrapWithAmount
        uint256 totalAfter = ILCC(lccToken1).balanceOf(user1);
        assertEq(totalAfter, totalBefore - wrapWithAmount, "Source LCC should decrease by wrap amount");
    }

    // ============ USER UNWRAP TESTS ============

    /// @notice Tests that standard user unwrap still works after refactoring
    function testUserUnwrapStillWorks() public {
        uint256 wrapAmount = 100;
        underlyingAsset1.mint(user1, wrapAmount);

        // Wrap
        vm.startPrank(user1);
        underlyingAsset1.approve(address(liquidityHub), wrapAmount);
        liquidityHub.wrap(lccToken1, wrapAmount);
        vm.stopPrank();

        ILCC lcc = ILCC(lccToken1);

        // Verify balance
        assertEq(lcc.balanceOf(user1), wrapAmount, "User should have LCC");

        // Unwrap
        vm.prank(user1);
        liquidityHub.unwrap(lccToken1, wrapAmount);

        // Verify underlying returned
        assertEq(underlyingAsset1.balanceOf(user1), wrapAmount, "User should receive underlying");
        assertEq(lcc.balanceOf(user1), 0, "LCC should be burned");
    }

    /// @notice Tests that unwrapTo still works for external recipients
    function testUnwrapToExternalRecipient() public {
        uint256 wrapAmount = 100;

        // Wrap
        _wrapDirectLCC(user1, lccToken1, wrapAmount);

        // Unwrap to different recipient
        vm.prank(user1);
        liquidityHub.unwrapTo(lccToken1, user2, wrapAmount);

        // Verify user2 received underlying
        assertEq(underlyingAsset1.balanceOf(user2), wrapAmount, "user2 should receive underlying");
        assertEq(underlyingAsset1.balanceOf(user1), 0, "user1 should not have underlying");
    }

    /// @notice Tests unwrap reverts with zero amount
    function testUnwrapRevertsWithZeroAmount() public {
        uint256 wrapAmount = 100;
        _wrapDirectLCC(user1, lccToken1, wrapAmount);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), wrapAmount));
        liquidityHub.unwrap(lccToken1, 0);
    }

    /// @notice Tests unwrap reverts when amount exceeds balance
    function testUnwrapRevertsWhenAmountExceedsBalance() public {
        uint256 wrapAmount = 100;
        _wrapDirectLCC(user1, lccToken1, wrapAmount);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, wrapAmount + 1, wrapAmount));
        liquidityHub.unwrap(lccToken1, wrapAmount + 1);
    }

    /// @notice Tests unwrap with invalid LCC reverts
    function testUnwrapRevertsWithInvalidLCC() public {
        address invalidLCC = address(0xDEAD);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, invalidLCC));
        liquidityHub.unwrap(invalidLCC, 100);
    }

    // ============ WRAP TESTS ============

    /// @notice Tests wrap reverts with zero amount
    function testWrapRevertsWithZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        liquidityHub.wrap(lccToken1, 0);
    }

    /// @notice Tests wrap reverts with invalid LCC
    function testWrapRevertsWithInvalidLCC() public {
        address invalidLCC = address(0xDEAD);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, invalidLCC));
        liquidityHub.wrap(invalidLCC, 100);
    }

    /// @notice Tests wrapTo sends to different recipient
    function testWrapToSendsToRecipient() public {
        uint256 wrapAmount = 100;
        underlyingAsset1.mint(user1, wrapAmount);

        vm.startPrank(user1);
        underlyingAsset1.approve(address(liquidityHub), wrapAmount);
        liquidityHub.wrapTo(lccToken1, user2, wrapAmount);
        vm.stopPrank();

        // user2 should have the LCC, not user1
        assertEq(ILCC(lccToken1).balanceOf(user2), wrapAmount, "user2 should receive LCC");
        assertEq(ILCC(lccToken1).balanceOf(user1), 0, "user1 should not have LCC");
    }
}


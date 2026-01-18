// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHubTestBase} from "../base/LiquidityHubTestBase.sol";
import {ILCC} from "../../src/interfaces/ILCC.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

/**
 * @title LiquidityHubLibTest
 * @notice Unit tests that specifically harden mutation survivors for LiquidityHubLib logic.
 * @dev These tests intentionally target hard-to-hit branches in:
 *      - wrapWith lazy-claim netting and clamping (`nettedLCCsAsUnderlying`)
 *      - settlement edge cases (`LiquidityError` path)
 *      - partial market-liquidity returns (exact shortfall queueing)
 */
contract LiquidityHubLibTest is LiquidityHubTestBase {
    using stdStorage for StdStorage;

    StdStorage internal _store;

    // IMPORTANT:
    // `LiquidityHubStorage internal s;` is NOT necessarily at slot 0 because LiquidityHub inherits OZ Ownable.
    // We therefore derive `s`'s base slot dynamically by:
    // 1) Asking Foundry for the concrete storage slot used by `lccToUnderlying(lcc)` (a mapping getter)
    // 2) Brute-forcing the small base-slot range to find `base` s.t. keccak(lcc, base + offset) matches.
    //
    // Field offsets within LiquidityHubStorage (see `src/types/Liquidity.sol`):
    // - lccToUnderlying offset = 1
    // - nettedLCCsAsUnderlying offset = 11
    uint256 internal constant _OFFSET_LCC_TO_UNDERLYING = 1;
    uint256 internal constant _OFFSET_LCC_TO_MARKET = 3;
    uint256 internal constant _OFFSET_NETTED = 11;
    uint256 internal constant _OFFSET_DIRECT_SUPPLY = 8;
    uint256 internal constant _OFFSET_SETTLE_QUEUE = 9;
    uint256 internal constant _OFFSET_TOTAL_QUEUED = 10;
    uint256 internal constant _OFFSET_RESERVE_OF_UNDERLYING = 12;

    function _deriveSBaseSlot() internal returns (uint256 base) {
        // Find the *actual* slot used for lccToUnderlying[lccToken1] in LiquidityHub storage.
        uint256 slotFound =
            _store.target(address(liquidityHub)).sig("lccToUnderlying(address)").with_key(lccToken1).find();

        // `base` will be very small (a few inherited slots). Brute force a safe range.
        for (uint256 candidate = 0; candidate < 64; candidate++) {
            uint256 computed = uint256(keccak256(abi.encode(lccToken1, candidate + _OFFSET_LCC_TO_UNDERLYING)));
            if (computed == slotFound) {
                return candidate;
            }
        }

        revert("failed to derive LiquidityHubStorage base slot");
    }

    function _slotNetted(address lcc) internal returns (bytes32) {
        uint256 base = _deriveSBaseSlot();
        uint256 root = base + _OFFSET_NETTED;
        return keccak256(abi.encode(lcc, root));
    }

    function _slotLccToMarket(address lcc) internal returns (bytes32) {
        uint256 base = _deriveSBaseSlot();
        uint256 root = base + _OFFSET_LCC_TO_MARKET;
        return keccak256(abi.encode(lcc, root));
    }

    function _setLccToMarketFactory(address lcc, address factoryAddr) internal {
        vm.store(address(liquidityHub), _slotLccToMarket(lcc), bytes32(uint256(uint160(factoryAddr))));
    }

    function _setLccToMarketId(address lcc, bytes32 id) internal {
        bytes32 slot = _slotLccToMarket(lcc);
        vm.store(address(liquidityHub), bytes32(uint256(slot) + 1), id);
    }

    function _setLccToMarketRefLength(address lcc, uint256 length) internal {
        bytes32 slot = _slotLccToMarket(lcc);
        vm.store(address(liquidityHub), bytes32(uint256(slot) + 2), bytes32(length));
    }

    function _setNetted(address lcc, uint256 value) internal {
        vm.store(address(liquidityHub), _slotNetted(lcc), bytes32(value));
    }

    function _slotDirectSupply(address lcc) internal returns (bytes32) {
        uint256 base = _deriveSBaseSlot();
        uint256 root = base + _OFFSET_DIRECT_SUPPLY;
        return keccak256(abi.encode(lcc, root));
    }

    function _setDirectSupply(address lcc, uint256 value) internal {
        vm.store(address(liquidityHub), _slotDirectSupply(lcc), bytes32(value));
    }

    function _slotTotalQueued(address lcc) internal returns (bytes32) {
        uint256 base = _deriveSBaseSlot();
        uint256 root = base + _OFFSET_TOTAL_QUEUED;
        return keccak256(abi.encode(lcc, root));
    }

    function _setTotalQueued(address lcc, uint256 value) internal {
        vm.store(address(liquidityHub), _slotTotalQueued(lcc), bytes32(value));
    }

    function _slotSettleQueue(address lcc, address recipient) internal returns (bytes32) {
        uint256 base = _deriveSBaseSlot();
        uint256 root = base + _OFFSET_SETTLE_QUEUE;
        bytes32 outer = keccak256(abi.encode(lcc, root));
        return keccak256(abi.encode(recipient, outer));
    }

    function _setSettleQueue(address lcc, address recipient, uint256 value) internal {
        vm.store(address(liquidityHub), _slotSettleQueue(lcc, recipient), bytes32(value));
    }

    function _slotReserveOfUnderlying(address underlying) internal returns (bytes32) {
        uint256 base = _deriveSBaseSlot();
        uint256 root = base + _OFFSET_RESERVE_OF_UNDERLYING;
        return keccak256(abi.encode(underlying, root));
    }

    function _setReserveOfUnderlying(address underlying, uint256 value) internal {
        vm.store(address(liquidityHub), _slotReserveOfUnderlying(underlying), bytes32(value));
    }

    /// @notice Reads `LiquidityHubStorage.nettedLCCsAsUnderlying[lcc]` from the Hub.
    /// @dev This value is the Hub’s **lazy-claimed netting counter** for a given LCC, used by `LiquidityHubLib`.
    ///
    /// Correlation / meaning:
    /// - It tracks how much of the Hub’s own settlement queue for `lcc` has already been “netted as underlying”
    ///   during `wrapWith` Step 2 (market-derived netting), without immediately burning Hub-held LCC.
    /// - Later, when settling the Hub’s queue (`processSettlementFor(lcc, address(hub), ...)`), the Hub path
    ///   consumes this counter first (`decrement = min(claimed, toSettle)`), and only burns the remaining amount
    ///   (`effectiveToBurn = toSettle - decrement`).
    ///
    /// In short: **higher value == more of the Hub’s queued obligation is considered already netted**, so less LCC
    /// should be burned during Hub settlement until this counter is reduced back toward zero.
    function _getNetted(address lcc) internal returns (uint256) {
        return uint256(vm.load(address(liquidityHub), _slotNetted(lcc)));
    }

    function test_assertValidLcc_revertsWhenMarketIdMissing_only() public {
        _setLccToMarketId(lccToken1, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, lccToken1));
        liquidityHub.processSettlementFor(lccToken1, user1, 1);
    }

    function test_assertValidLcc_revertsWhenRefMissing_only() public {
        _setLccToMarketRefLength(lccToken1, 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, lccToken1));
        liquidityHub.processSettlementFor(lccToken1, user1, 1);
    }

    function test_assertValidLcc_revertsWhenFactoryMissing_only() public {
        _setLccToMarketFactory(lccToken1, address(0));

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, lccToken1));
        liquidityHub.processSettlementFor(lccToken1, user1, 1);
    }

    function test_unwrap_wrappedOnly_decrementsDirectSupplyAndReserve() public {
        uint256 amount = 10;
        _wrapDirectLCC(user1, lccToken1, amount);

        uint256 directSupplyBefore = liquidityHub.directSupply(lccToken1);
        uint256 reserveBefore = liquidityHub.reserveOfUnderlying(lccToken1);
        assertEq(directSupplyBefore, amount, "precondition: directSupply should equal wrapped amount");
        assertEq(reserveBefore, amount, "precondition: reserve should equal wrapped amount");

        vm.prank(user1);
        liquidityHub.unwrap(lccToken1, 7);

        assertEq(liquidityHub.directSupply(lccToken1), directSupplyBefore - 7, "directSupply should decrement");
        assertEq(liquidityHub.reserveOfUnderlying(lccToken1), reserveBefore - 7, "reserve should decrement");
    }

    function test_unwrap_revertsInvalidAmount_whenReserveInsufficientEvenIfDirectSupplyPresent() public {
        uint256 amount = 5;
        _wrapDirectLCC(user1, lccToken1, amount);

        // Break the (normally true) invariant: directSupply > 0 but reserve == 0.
        // This forces `transferUnderlying` to hit the InvalidAmount revert (mutation target).
        _setReserveOfUnderlying(address(underlyingAsset1), 0);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, amount, uint256(0)));
        liquidityHub.unwrap(lccToken1, amount);
    }

    function test_unwrap_whenNoMarketBalance_doesNotCallUseMarketLiquidity_andQueuesAll() public {
        // User has wrapped balance, but we set directSupply to 0 so direct-unwrapping is impossible.
        // With marketDerivedBalance == 0, unwrapInternalLogic must NOT call useMarketLiquidity at all.
        uint256 amount = 1;
        _wrapDirectLCC(user1, lccToken1, amount);
        _setDirectSupply(lccToken1, 0);

        // If useMarketLiquidity is called (it should not be), revert.
        vm.mockCallRevert(
            factory,
            abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector),
            abi.encodeWithSignature("Error(string)", "useMarketLiquidity called")
        );

        vm.prank(user1);
        liquidityHub.unwrap(lccToken1, amount);

        assertEq(liquidityHub.settleQueue(lccToken1, user1), amount, "should queue full amount");
        assertEq(liquidityHub.totalQueued(lccToken1), amount, "totalQueued should equal queued amount");
    }

    function test_processSettlementFor_hub_doesNotDecrementReserveOrTransferUnderlying() public {
        uint256 queued = 10;
        // Create queue for the Hub itself.
        _createSettlementQueueEntry(lccToken1, address(liquidityHub), queued);

        // Ensure reserve is non-zero WITHOUT calling confirmTake (which would greedily process the Hub queue).
        // We deliberately set the reserve mapping directly to keep the queue intact.
        _setReserveOfUnderlying(address(underlyingAsset1), queued);

        uint256 reserveBefore = liquidityHub.reserveOfUnderlying(lccToken1);
        uint256 hubUnderlyingBefore = underlyingAsset1.balanceOf(address(liquidityHub));

        // Process Hub settlement.
        liquidityHub.processSettlementFor(lccToken1, address(liquidityHub), queued);

        // Hub settlement burns Hub-held LCC but must NOT transfer underlying nor decrement reserve.
        assertEq(
            liquidityHub.reserveOfUnderlying(lccToken1), reserveBefore, "reserve must not change for hub settlement"
        );
        assertEq(
            underlyingAsset1.balanceOf(address(liquidityHub)),
            hubUnderlyingBefore,
            "hub underlying balance must not change for hub settlement"
        );
    }

    function test_processSettlementFor_hub_revertsAfterHubTake() public {
        uint256 queued = 10;
        // Create queue for the Hub itself.
        _createSettlementQueueEntry(lccToken1, address(liquidityHub), queued);

        // Fund reserve AFTER queue creation (confirmTake will greedily process Hub queue if it exists).
        underlyingAsset1.mint(address(liquidityHub), queued);
        vm.prank(proxyHook);
        liquidityHub.confirmTake(lccToken1, queued, false);

        // Process Hub settlement.
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, 0, 0));
        liquidityHub.processSettlementFor(lccToken1, address(liquidityHub), queued);
    }

    function test_processSettlementFor_hub_usesTotalBalance_whenWrappedOnly() public {
        uint256 queued = 6;

        // Hub holds wrapped LCC only (market-derived is 0).
        _wrapDirectLCC(address(liquidityHub), lccToken1, queued);

        // Seed hub queue and reserve directly to avoid market-derived balances.
        _setSettleQueue(lccToken1, address(liquidityHub), queued);
        _setTotalQueued(lccToken1, queued);
        _setReserveOfUnderlying(address(underlyingAsset1), queued);

        uint256 hubBalanceBefore = ILCC(lccToken1).balanceOf(address(liquidityHub));
        assertEq(hubBalanceBefore, queued, "precondition: hub balance should be wrapped only");

        liquidityHub.processSettlementFor(lccToken1, address(liquidityHub), queued);

        assertEq(liquidityHub.settleQueue(lccToken1, address(liquidityHub)), 0, "hub queue should clear");
        assertEq(liquidityHub.totalQueued(lccToken1), 0, "totalQueued should clear");
        assertEq(ILCC(lccToken1).balanceOf(address(liquidityHub)), hubBalanceBefore - queued, "hub LCC should burn");
    }

    function test_wrapWith_step2_lazyClaim_increasesNetted_andDoesNotQueueResidual() public {
        (address lccToken3,) = _createSecondLCCPair();

        uint256 hubQueue = 50;
        _createSettlementQueueEntry(lccToken1, address(liquidityHub), hubQueue);

        uint256 amount = 30;
        _wrapMarketDerivedLCC(user1, lccToken1, amount);

        // Hub is already protocol-bound (bucket-exempt) in test setup.

        uint256 nettedBefore = _getNetted(lccToken1);
        assertEq(nettedBefore, 0, "precondition: netted should start at 0");

        uint256 queueBefore = liquidityHub.settleQueue(lccToken1, address(liquidityHub));
        uint256 totalQueuedBefore = liquidityHub.totalQueued(lccToken1);
        assertEq(queueBefore, hubQueue, "precondition: hub queue should exist");
        assertEq(totalQueuedBefore, hubQueue, "precondition: totalQueued should match hub queue");

        vm.startPrank(user1);
        ILCC(lccToken1).approve(address(liquidityHub), amount);
        liquidityHub.wrapWith(lccToken3, lccToken1, amount);
        vm.stopPrank();

        // Step 2 should lazy-claim (increase netted) but must NOT mutate the queue itself.
        assertEq(_getNetted(lccToken1), nettedBefore + amount, "netted should increase by nettable");
        assertEq(
            liquidityHub.settleQueue(lccToken1, address(liquidityHub)),
            queueBefore,
            "hub queue should not change due to lazy-claim"
        );
        assertEq(
            liquidityHub.totalQueued(lccToken1), totalQueuedBefore, "totalQueued should not change due to lazy-claim"
        );
    }

    function test_wrapWith_step2_netting_consumesMarketDerived_soResidualDoesNotUseMarketLiquidity() public {
        (address lccToken3,) = _createSecondLCCPair();

        // Create a hub queue for withLCC so Step 2 can net against it.
        uint256 hubQueue = 10;
        _createSettlementQueueEntry(lccToken1, address(liquidityHub), hubQueue);

        // User amount includes both market-derived and wrapped components.
        // - market-derived = 10 (fully nettable)
        // - wrapped = 40
        // Total amount = 50.
        uint256 marketAmount = 10;
        uint256 wrappedAmount = 40;
        uint256 amount = marketAmount + wrappedAmount;

        _wrapMarketDerivedLCC(user1, lccToken1, marketAmount);
        _wrapDirectLCC(user1, lccToken1, wrappedAmount);

        // Prevent Step 1 direct conversion; we want Step 3 to queue the wrapped residual to the Hub.
        _setDirectSupply(lccToken1, 0);

        // If Step 3 tries to use market liquidity (it shouldn't after Step 2 consumes market-derived),
        // revert hard to kill the mutation.
        vm.mockCallRevert(
            factory,
            abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector),
            abi.encodeWithSignature("Error(string)", "useMarketLiquidity called")
        );

        uint256 queueBefore = liquidityHub.settleQueue(lccToken1, address(liquidityHub));
        uint256 totalQueuedBefore = liquidityHub.totalQueued(lccToken1);

        vm.startPrank(user1);
        ILCC(lccToken1).approve(address(liquidityHub), amount);
        liquidityHub.wrapWith(lccToken3, lccToken1, amount);
        vm.stopPrank();

        // The wrapped residual should be queued to the Hub exactly.
        assertEq(
            liquidityHub.settleQueue(lccToken1, address(liquidityHub)),
            queueBefore + wrappedAmount,
            "hub queue should increase only by wrapped residual"
        );
        assertEq(
            liquidityHub.totalQueued(lccToken1),
            totalQueuedBefore + wrappedAmount,
            "totalQueued should increase only by wrapped residual"
        );
    }

    function test_wrapWith_step2_netting_clampsToEffectiveQueue_whenClaimedPresent() public {
        (address targetLcc,) = _createSecondLCCPair();
        address withLcc = lccToken1;

        uint256 hubQueue = 50;
        uint256 claimed = 20;
        uint256 effectiveQueue = hubQueue - claimed;
        uint256 amount = effectiveQueue;

        _createSettlementQueueEntry(withLcc, address(liquidityHub), hubQueue);
        _setNetted(withLcc, claimed);

        _wrapMarketDerivedLCC(user1, withLcc, amount);
        // Hub is already protocol-bound (bucket-exempt) in test setup.

        uint256 nettedBefore = _getNetted(withLcc);
        assertEq(nettedBefore, claimed, "precondition: netted should be claimed");

        uint256 queueBefore = liquidityHub.settleQueue(withLcc, address(liquidityHub));
        uint256 totalQueuedBefore = liquidityHub.totalQueued(withLcc);

        vm.startPrank(user1);
        ILCC(withLcc).approve(address(liquidityHub), amount);
        liquidityHub.wrapWith(targetLcc, withLcc, amount);
        vm.stopPrank();

        assertEq(_getNetted(withLcc), nettedBefore + effectiveQueue, "netted should clamp to effective queue");
        assertEq(
            liquidityHub.settleQueue(withLcc, address(liquidityHub)),
            queueBefore,
            "queue should remain unchanged by lazy-claim"
        );
        assertEq(
            liquidityHub.totalQueued(withLcc), totalQueuedBefore, "totalQueued should remain unchanged by lazy-claim"
        );
    }

    function test_wrapWith_step0_consumesMarketDerived_andQueuesOnlyWrappedResidual() public {
        // This test is engineered to kill Step 0 accounting mutants in LiquidityHubLib:
        // - ctx.fromMarketDerivedAmount -= consumeMarket   (mutant: +=)
        // - remaining = netTarget - consumeMarket          (mutant: +)
        // - remainderAmount = remainderAmount - targetToBurn (mutant: +)
        //
        // Setup:
        // - Target LCC has a Hub queue and Hub-held balance, but queue < amount, so Step 0 nets PARTIALLY.
        // - User has mixed backing balance: marketDerived == netTarget, wrapped == remainder.
        // - There is ALSO a Hub queue for withLCC so Step 2 would net if marketDerived were incorrectly left > 0.
        // - We block market liquidity calls; if Step 0 fails to consume market-derived, Step 3 would try to use it.

        (address targetLcc,) = _createSecondLCCPair();
        address withLcc = lccToken1;

        uint256 netTarget = 10;
        uint256 wrappedRemainder = 20;
        uint256 amount = netTarget + wrappedRemainder;

        // Create a Hub queue for the TARGET LCC so Step 0 can net against it.
        _createSettlementQueueEntry(targetLcc, address(liquidityHub), netTarget);
        uint256 targetQueueBefore = liquidityHub.settleQueue(targetLcc, address(liquidityHub));
        uint256 targetTotalQueuedBefore = liquidityHub.totalQueued(targetLcc);
        assertEq(targetQueueBefore, netTarget, "precondition: target queue should be netTarget");
        assertEq(targetTotalQueuedBefore, netTarget, "precondition: target totalQueued should be netTarget");

        // Create a Hub queue for withLCC so Step 2 has effectiveQueue > 0 (but should net 0 if Step 0 consumed market).
        _createSettlementQueueEntry(withLcc, address(liquidityHub), 100);
        uint256 withQueueBefore = liquidityHub.settleQueue(withLcc, address(liquidityHub));
        uint256 withTotalQueuedBefore = liquidityHub.totalQueued(withLcc);

        // User holds EXACTLY netTarget as market-derived, plus wrapped remainder.
        _wrapMarketDerivedLCC(user1, withLcc, netTarget);
        _wrapDirectLCC(user1, withLcc, wrappedRemainder);

        // Prevent Step 1 direct conversion AND prevent Step 3 direct unwrapping, so residual must queue.
        _setDirectSupply(withLcc, 0);

        // If any market liquidity is used, the test should fail (Step 0 should consume all market-derived netTarget).
        vm.mockCallRevert(
            factory,
            abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector),
            abi.encodeWithSignature("Error(string)", "useMarketLiquidity called")
        );

        assertEq(_getNetted(withLcc), 0, "precondition: netted starts at 0");

        vm.startPrank(user1);
        ILCC(withLcc).approve(address(liquidityHub), amount);
        liquidityHub.wrapWith(targetLcc, withLcc, amount);
        vm.stopPrank();

        // Step 0 should have reduced the TARGET queue/totalQueued by netTarget.
        assertEq(
            liquidityHub.settleQueue(targetLcc, address(liquidityHub)),
            targetQueueBefore - netTarget,
            "target queue should decrease by netTarget"
        );
        assertEq(
            liquidityHub.totalQueued(targetLcc),
            targetTotalQueuedBefore - netTarget,
            "target totalQueued should decrease by netTarget"
        );

        // Step 2 should NOT have netted anything (market-derived was fully consumed by Step 0).
        assertEq(_getNetted(withLcc), 0, "netted should remain 0 when Step 0 consumes market-derived");

        // Only the WRAPPED remainder should be queued to the Hub (since no liquidity is used).
        assertEq(
            liquidityHub.settleQueue(withLcc, address(liquidityHub)),
            withQueueBefore + wrappedRemainder,
            "withLCC queue should increase only by wrapped remainder"
        );
        assertEq(
            liquidityHub.totalQueued(withLcc),
            withTotalQueuedBefore + wrappedRemainder,
            "withLCC totalQueued should increase only by wrapped remainder"
        );
    }

    function test_wrapWith_step0_partialMarket_consumesWrappedRemainder_correctly() public {
        (address targetLcc,) = _createSecondLCCPair();
        address withLcc = lccToken1;

        uint256 netTarget = 12;
        uint256 marketAmount = 5;
        uint256 wrappedAmount = 15;
        uint256 amount = marketAmount + wrappedAmount;

        // Step 0 netting on target queue.
        _createSettlementQueueEntry(targetLcc, address(liquidityHub), netTarget);

        // User has partial market-derived balance; Step 0 must consume wrapped remainder.
        _wrapMarketDerivedLCC(user1, withLcc, marketAmount);
        _wrapDirectLCC(user1, withLcc, wrappedAmount);

        // Prevent Step 1 direct conversion.
        _setDirectSupply(withLcc, 0);

        // Hub is already protocol-bound (bucket-exempt) in test setup.

        uint256 queueBefore = liquidityHub.settleQueue(withLcc, address(liquidityHub));
        uint256 totalQueuedBefore = liquidityHub.totalQueued(withLcc);

        vm.startPrank(user1);
        ILCC(withLcc).approve(address(liquidityHub), amount);
        liquidityHub.wrapWith(targetLcc, withLcc, amount);
        vm.stopPrank();

        // Only the post-Step 0 residual should queue.
        uint256 expectedResidual = amount - netTarget;
        assertEq(
            liquidityHub.settleQueue(withLcc, address(liquidityHub)),
            queueBefore + expectedResidual,
            "queued residual should match amount - netTarget"
        );
        assertEq(
            liquidityHub.totalQueued(withLcc), totalQueuedBefore + expectedResidual, "totalQueued should match residual"
        );
    }

    function test_wrapWith_step3_excludesDirectToMint_fromResidualWrapped_andQueuesFullRemainder() public {
        (address targetLcc,) = _createSecondLCCPair();
        address withLcc = lccToken1;

        uint256 wrappedAmount = 4;
        uint256 marketAmount = 6;
        uint256 amount = wrappedAmount + marketAmount;

        _wrapDirectLCC(user1, withLcc, wrappedAmount);
        _wrapDirectLCC(proxyHook, withLcc, marketAmount);
        vm.prank(proxyHook);
        ILCC(withLcc).transfer(user1, marketAmount);

        (uint256 wrappedBal, uint256 marketBal) = ILCC(withLcc).balancesOf(user1);
        assertEq(wrappedBal, wrappedAmount, "precondition: wrapped balance should match");
        assertEq(marketBal, marketAmount, "precondition: market balance should match");

        // Ensure directSupply is larger than wrapped amount to make residualWrappedForUnwrap observable.
        _setDirectSupply(withLcc, wrappedAmount + 6);

        // No market liquidity; all remaining amount should queue.
        vm.mockCall(factory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0)));

        // Hub is already protocol-bound (bucket-exempt) in test setup.

        uint256 queueBefore = liquidityHub.settleQueue(withLcc, address(liquidityHub));
        uint256 totalQueuedBefore = liquidityHub.totalQueued(withLcc);

        vm.startPrank(user1);
        ILCC(withLcc).approve(address(liquidityHub), amount);
        liquidityHub.wrapWith(targetLcc, withLcc, amount);
        vm.stopPrank();

        // Step 3 should not consume directSupply again; full marketAmount should be queued.
        assertEq(
            liquidityHub.settleQueue(withLcc, address(liquidityHub)),
            queueBefore + marketAmount,
            "queue should increase by the full market-derived remainder"
        );
        assertEq(
            liquidityHub.totalQueued(withLcc),
            totalQueuedBefore + marketAmount,
            "totalQueued should increase by the full market-derived remainder"
        );

        uint256 expectedDirectSupply = (wrappedAmount + 6) - wrappedAmount;
        assertEq(
            liquidityHub.directSupply(withLcc),
            expectedDirectSupply,
            "directSupply should only decrease by the Step 1 direct conversion"
        );
    }

    function test_wrapWith_step3_usesMarketDerived_whenWrappedFullyConverted() public {
        (address targetLcc,) = _createSecondLCCPair();
        address withLcc = lccToken1;

        uint256 wrappedAmount = 6;
        uint256 marketAmount = 4;
        uint256 amount = wrappedAmount + marketAmount;

        _wrapMarketDerivedLCC(user1, withLcc, marketAmount);
        _wrapDirectLCC(user1, withLcc, wrappedAmount);

        // Ensure Step 1 converts all wrapped, leaving no residual wrapped for Step 3.
        _setDirectSupply(withLcc, amount);

        // Force Step 3 to queue market-derived remainder.
        vm.mockCall(factory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0)));

        // Hub is already protocol-bound (bucket-exempt) in test setup.

        uint256 queueBefore = liquidityHub.settleQueue(withLcc, address(liquidityHub));
        uint256 totalQueuedBefore = liquidityHub.totalQueued(withLcc);

        vm.startPrank(user1);
        ILCC(withLcc).approve(address(liquidityHub), amount);
        liquidityHub.wrapWith(targetLcc, withLcc, amount);
        vm.stopPrank();

        assertEq(
            liquidityHub.settleQueue(withLcc, address(liquidityHub)),
            queueBefore + marketAmount,
            "queue should match market-derived remainder"
        );
        assertEq(
            liquidityHub.totalQueued(withLcc),
            totalQueuedBefore + marketAmount,
            "totalQueued should match market-derived remainder"
        );

        (uint256 wrappedOut, uint256 marketOut) = ILCC(targetLcc).balancesOf(user1);
        assertEq(wrappedOut, wrappedAmount, "target wrapped mint should equal direct conversion");
        assertEq(marketOut, marketAmount, "target market mint should equal residual amount");
    }

    function test_processSettlementFor_external_revertsLiquidityError_whenMaxAmountZero() public {
        uint256 queued = 10;
        _createSettlementQueueEntry(lccToken1, user1, queued);

        vm.expectRevert(abi.encodeWithSelector(Errors.LiquidityError.selector, lccToken1, uint256(0)));
        liquidityHub.processSettlementFor(lccToken1, user1, 0);
    }

    function test_processSettlementFor_hub_consumesClaimedFirst_noBurn_whenClaimedGteToSettle() public {
        uint256 queued = 40;
        _createSettlementQueueEntry(lccToken1, address(liquidityHub), queued);

        uint256 claimed = 50;
        _setNetted(lccToken1, claimed);

        uint256 hubLccBefore = ILCC(lccToken1).balanceOf(address(liquidityHub));
        assertEq(hubLccBefore, queued, "precondition: hub must hold queued LCC");

        liquidityHub.processSettlementFor(lccToken1, address(liquidityHub), queued);

        // Queue cleared.
        assertEq(liquidityHub.settleQueue(lccToken1, address(liquidityHub)), 0);
        assertEq(liquidityHub.totalQueued(lccToken1), 0);

        // Claimed portion consumed first; no burn when claimed >= toSettle.
        assertEq(ILCC(lccToken1).balanceOf(address(liquidityHub)), hubLccBefore, "no burn expected");
        assertEq(_getNetted(lccToken1), claimed - queued, "claimed should decrement by toSettle");
    }

    function test_processSettlementFor_hub_burnsOnlyExcessOverClaimed_whenClaimedLtToSettle() public {
        uint256 queued = 40;
        _createSettlementQueueEntry(lccToken1, address(liquidityHub), queued);

        uint256 claimed = 15;
        _setNetted(lccToken1, claimed);

        uint256 hubLccBefore = ILCC(lccToken1).balanceOf(address(liquidityHub));
        assertEq(hubLccBefore, queued, "precondition: hub must hold queued LCC");

        liquidityHub.processSettlementFor(lccToken1, address(liquidityHub), queued);

        // Queue cleared.
        assertEq(liquidityHub.settleQueue(lccToken1, address(liquidityHub)), 0);
        assertEq(liquidityHub.totalQueued(lccToken1), 0);

        // Burn only the unclaimed portion.
        uint256 expectedBurn = queued - claimed;
        assertEq(
            ILCC(lccToken1).balanceOf(address(liquidityHub)),
            hubLccBefore - expectedBurn,
            "burn should equal (toSettle - claimed)"
        );
        assertEq(_getNetted(lccToken1), 0, "claimed should be fully consumed");
    }

    function test_wrapWith_clampsNettedToCurrentQueueInFinaliseBurns() public {
        // Create a hub queue for withLCC and set a pathological netted value above it.
        uint256 queueAmount = 10;
        _createSettlementQueueEntry(lccToken1, address(liquidityHub), queueAmount);

        _setNetted(lccToken1, 100);
        assertEq(_getNetted(lccToken1), 100, "precondition: netted should be forced above queue");

        (address lccToken3,) = _createSecondLCCPair();

        // Hub is already protocol-bound (bucket-exempt) in test setup.

        // Provide minimal backing LCC to user and perform wrapWith to trigger `_finaliseBurns`.
        _wrapDirectLCC(user1, lccToken1, 1);
        vm.startPrank(user1);
        ILCC(lccToken1).approve(address(liquidityHub), 1);
        liquidityHub.wrapWith(lccToken3, lccToken1, 1);
        vm.stopPrank();

        uint256 currentQueue = liquidityHub.settleQueue(lccToken1, address(liquidityHub));
        assertEq(currentQueue, queueAmount, "queue should remain unchanged in this setup");
        assertEq(_getNetted(lccToken1), currentQueue, "netted should clamp to current queue");
    }

    function test_unwrap_marketLiquidityPartial_queuesExactShortfallAndPaysPartial() public {
        uint256 amount = 50;
        uint256 used = 20;
        uint256 shortfall = amount - used;

        // Create market-derived balance (wrapped=0, market=amount).
        _wrapMarketDerivedLCC(user1, lccToken1, amount);

        // Partial market liquidity: return less than requested to force queueing.
        vm.mockCall(factory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(used));

        uint256 underlyingBefore = underlyingAsset1.balanceOf(user1);

        vm.prank(user1);
        liquidityHub.unwrap(lccToken1, amount);

        // Paid only the liquid portion.
        assertEq(underlyingAsset1.balanceOf(user1), underlyingBefore + used, "should pay only used amount");

        // Remaining shortfall must be queued exactly.
        assertEq(liquidityHub.settleQueue(lccToken1, user1), shortfall, "queued shortfall mismatch");
        assertEq(liquidityHub.totalQueued(lccToken1), shortfall, "totalQueued mismatch");

        // User keeps the un-settled LCC balance.
        assertEq(ILCC(lccToken1).balanceOf(user1), shortfall, "residual LCC balance should equal shortfall");
    }

    // ============================================================
    // Mutation hardening: kill Step 0 arithmetic mutant (Line 146)
    // _netAgainstTargetQueue: `remaining = netTarget - consumeMarket` → `+`
    // ============================================================

    /// @notice Kills Line 146 mutant: `netTarget - consumeMarket` → `netTarget + consumeMarket`
    /// @dev When user has mixed balance (market-derived + wrapped), Step 0 should:
    ///      1. Consume market-derived first up to netTarget
    ///      2. Calculate remaining = netTarget - consumeMarket
    ///      3. Consume wrapped for the remaining
    ///      Under the mutant, remaining would be netTarget + consumeMarket (too large),
    ///      causing excess wrapped consumption.
    function test_wrapWith_step0_remainingMinusConsumeMarket_drivesStep1Conversion_andPreventsQueueing() public {
        (address targetLcc,) = _createSecondLCCPair();
        address withLcc = lccToken1;

        // Make Step 0 net only a portion of `amount` (amount > targetQueue),
        // so incorrect wrapped consumption becomes observable in downstream state.
        uint256 netTarget = 50;
        uint256 amount = 100;

        // Target queue netting: Hub queue for targetLcc = 50.
        _createSettlementQueueEntry(targetLcc, address(liquidityHub), netTarget);

        // User has mixed backing balance: 30 market-derived + 70 wrapped.
        uint256 marketAmount = 30;
        uint256 wrappedAmount = amount - marketAmount; // 70
        _wrapMarketDerivedLCC(user1, withLcc, marketAmount);
        _wrapDirectLCC(user1, withLcc, wrappedAmount);

        // Verify user balance composition.
        (uint256 wrappedBal, uint256 marketBal) = ILCC(withLcc).balancesOf(user1);
        assertEq(wrappedBal, wrappedAmount, "precondition: wrapped balance");
        assertEq(marketBal, marketAmount, "precondition: market balance");

        // Enable Step 1 direct conversion, but cap directSupply so the correct code converts
        // exactly the wrapped remainder left after Step 0 (50), while the mutant converts 0.
        uint256 directSupplyAvail = 50;
        _setDirectSupply(withLcc, directSupplyAvail);

        // If any market liquidity is used, the test should fail; the correct path should not call it here.
        vm.mockCallRevert(
            factory,
            abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector),
            abi.encodeWithSignature("Error(string)", "useMarketLiquidity called")
        );

        // Hub is already protocol-bound (bucket-exempt) in test setup.

        uint256 targetDirectBefore = liquidityHub.directSupply(targetLcc);
        uint256 withDirectBefore = liquidityHub.directSupply(withLcc);
        uint256 withQueueBefore = liquidityHub.settleQueue(withLcc, address(liquidityHub));

        vm.startPrank(user1);
        ILCC(withLcc).approve(address(liquidityHub), amount);
        liquidityHub.wrapWith(targetLcc, withLcc, amount);
        vm.stopPrank();

        // Correct code:
        // - Step 0 consumes 30 market + 20 wrapped, leaving 50 wrapped for Step 1
        // - Step 1 converts 50 directSupply from withLcc -> targetLcc
        // - remainder becomes 0, so no settlement is queued on withLcc
        //
        // Mutant:
        // - Step 0 consumes all 70 wrapped, leaving 0 for Step 1
        // - Step 1 converts 0, remainder becomes 50 and is queued
        assertEq(
            liquidityHub.directSupply(targetLcc),
            targetDirectBefore + directSupplyAvail,
            "target directSupply should increase by Step 1 conversion"
        );
        assertEq(
            liquidityHub.directSupply(withLcc),
            withDirectBefore - directSupplyAvail,
            "withLcc directSupply should decrease by Step 1 conversion"
        );
        assertEq(
            liquidityHub.settleQueue(withLcc, address(liquidityHub)),
            withQueueBefore,
            "withLcc queue should remain unchanged when remainder is fully flattened"
        );
    }

    // ============================================================
    // Mutation hardening: kill Step 2 arithmetic mutant (Line 220)
    // _netMarketDerived: `effectiveQueue = hubQueueForWith - claimed` → `+`
    // ============================================================

    /// @notice Kills Line 220 mutant: `hubQueueForWith - claimed` → `hubQueueForWith + claimed`
    /// @dev When there's a pre-existing lazy-claimed amount (netted), the effective queue
    ///      should be total queue minus claimed, not plus.
    function test_wrapWith_step2_effectiveQueue_isHubQueueMinusClaimed_andQueuesResidual() public {
        (address targetLcc,) = _createSecondLCCPair();
        address withLcc = lccToken1;

        // Setup: Hub queue for withLcc = 80, already claimed (netted) = 50.
        // Effective queue = 30.
        uint256 hubQueue = 80;
        uint256 claimed = 50;
        uint256 effectiveQueue = hubQueue - claimed; // 30

        _createSettlementQueueEntry(withLcc, address(liquidityHub), hubQueue);
        _setNetted(withLcc, claimed);

        // User has market-derived balance > effectiveQueue so Step 2 must clamp.
        uint256 marketAmount = 60;
        _wrapMarketDerivedLCC(user1, withLcc, marketAmount);

        // Verify preconditions.
        assertEq(_getNetted(withLcc), claimed, "precondition: netted should be claimed");
        assertEq(liquidityHub.settleQueue(withLcc, address(liquidityHub)), hubQueue, "precondition: hub queue");

        // Hub is already protocol-bound (bucket-exempt) in test setup.

        // Disable Step 1 direct conversion.
        _setDirectSupply(withLcc, 0);

        // Block market liquidity so any residual must queue.
        vm.mockCall(factory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0)));

        uint256 queueBefore = liquidityHub.settleQueue(withLcc, address(liquidityHub));

        vm.startPrank(user1);
        ILCC(withLcc).approve(address(liquidityHub), marketAmount);
        liquidityHub.wrapWith(targetLcc, withLcc, marketAmount);
        vm.stopPrank();

        // Correct: Step 2 nets only `effectiveQueue` and leaves `marketAmount - effectiveQueue` to be queued.
        // Mutant (+): Step 2 over-nets, leaving nothing to queue (observable).
        assertEq(_getNetted(withLcc), claimed + effectiveQueue, "netted should increase by effective queue only");

        uint256 residual = marketAmount - effectiveQueue;
        assertEq(
            liquidityHub.settleQueue(withLcc, address(liquidityHub)),
            queueBefore + residual,
            "residual should be queued when market liquidity is unavailable"
        );
    }

    // ============================================================
    // Mutation hardening: kill Step 3 arithmetic mutants (Lines 260, 270, 272)
    // ============================================================

    /// @notice Kills Line 260 arithmetic mutant by inducing an overflow in the mutant expression.
    /// @dev In `_unwrapResidual`, when `residualWrappedForUnwrap > ctx.directToMint`, the correct code computes:
    ///      `residualWrappedForUnwrap - ctx.directToMint`.
    ///      The mutant changes this to `+`, which can overflow under large enough values.
    function test_wrapWith_step3_residualWrappedForUnwrap_minusDoesNotOverflow_plusWouldOverflow() public {
        (address targetLcc,) = _createSecondLCCPair();
        address withLcc = lccToken1;

        // Choose values so that:
        // - fromWrappedAmount = amount is very large
        // - directToMint = directSupplyAvail is slightly smaller (so the `>` branch is taken)
        // - correct residual = 1
        // - mutant (`+`) overflows
        uint256 amount = type(uint256).max - 1;
        uint256 directSupplyAvail = type(uint256).max - 2;

        _wrapDirectLCC(user1, withLcc, amount); // user has wrapped balance == amount
        _setDirectSupply(withLcc, directSupplyAvail); // force partial direct conversion (directAvail < wrapped)

        // Prevent any external market liquidity effects.
        vm.mockCall(factory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0)));

        // Hub is already protocol-bound (bucket-exempt) in test setup.

        vm.startPrank(user1);
        ILCC(withLcc).approve(address(liquidityHub), amount);
        liquidityHub.wrapWith(targetLcc, withLcc, amount);
        vm.stopPrank();

        // Sanity: the call succeeded under correct code (i.e. no overflow in residual calc).
        // Any revert here under mutation run indicates the mutant was killed.
        assertTrue(true);
    }
}


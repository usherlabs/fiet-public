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
        vm.prank(factory);
        liquidityHub.confirmTake(lccToken1, queued, false);

        // Process Hub settlement.
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, 0, 0));
        liquidityHub.processSettlementFor(lccToken1, address(liquidityHub), queued);
    }

    function test_wrapWith_step2_lazyClaim_increasesNetted_andDoesNotQueueResidual() public {
        (address lccToken3,) = _createSecondLCCPair();

        uint256 hubQueue = 50;
        _createSettlementQueueEntry(lccToken1, address(liquidityHub), hubQueue);

        uint256 amount = 30;
        _wrapMarketDerivedLCC(user1, lccToken1, amount);

        // Ensure Hub can pull LCC from user.
        _mockAddressAsProtocolBound(address(liquidityHub), true);

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

        _mockAddressAsProtocolBound(address(liquidityHub), true);

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

        _mockAddressAsProtocolBound(address(liquidityHub), true);
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

    function test_wrapWith_step3_excludesDirectToMint_fromResidualWrapped_andQueuesFullRemainder() public {
        (address targetLcc,) = _createSecondLCCPair();
        address withLcc = lccToken1;

        uint256 wrappedAmount = 4;
        uint256 marketAmount = 6;
        uint256 amount = wrappedAmount + marketAmount;

        _wrapDirectLCC(user1, withLcc, wrappedAmount);
        _wrapDirectLCC(factory, withLcc, marketAmount);
        vm.prank(factory);
        ILCC(withLcc).transfer(user1, marketAmount);

        (uint256 wrappedBal, uint256 marketBal) = ILCC(withLcc).balancesOf(user1);
        assertEq(wrappedBal, wrappedAmount, "precondition: wrapped balance should match");
        assertEq(marketBal, marketAmount, "precondition: market balance should match");

        // Ensure directSupply is larger than wrapped amount to make residualWrappedForUnwrap observable.
        _setDirectSupply(withLcc, wrappedAmount + 6);

        // No market liquidity; all remaining amount should queue.
        vm.mockCall(factory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0)));

        _mockAddressAsProtocolBound(address(liquidityHub), true);

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

        // Ensure hub is protocol-bound so it can facilitate wrapWith transfers.
        _mockAddressAsProtocolBound(address(liquidityHub), true);

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
}


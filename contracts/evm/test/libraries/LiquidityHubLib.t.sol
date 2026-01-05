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
    uint256 internal constant _OFFSET_NETTED = 11;

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

    function _setNetted(address lcc, uint256 value) internal {
        vm.store(address(liquidityHub), _slotNetted(lcc), bytes32(value));
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


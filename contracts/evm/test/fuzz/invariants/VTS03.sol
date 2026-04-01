// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSSwapLibHarness} from "../../libraries/harnesses/VTSSwapLibHarness.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-periphery/lib/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";

/// @notice Echidna harness for VTS-03 segment-growth accounting.
/// @dev Uses `VTSSwapLibHarness` wrappers over real VTSSwapLib internals (`_accrueSegmentGrowth`, `_flipOutside`).
///      This is still narrower than full `afterCoreSwap -> processSwap` integration but now anchors assertions
///      to the production growth update helpers instead of a duplicated local implementation.
contract VTS03 {
    uint256 internal constant MAX_VACUOUS_ATTEMPTS = 10;

    VTSSwapLibHarness internal swapHarness;

    PoolId internal constant POOL_ID = PoolId.wrap(bytes32(uint256(0x5A03)));

    uint256 internal segmentAttempts;
    uint256 internal segmentChecks;
    bool internal segmentAllOk = true;
    uint256 internal flipAttempts;

    bool internal sZeroForOne;
    uint160 internal sSqrtCurrent;
    uint160 internal sSqrtTarget;
    uint128 internal sLiq;
    uint256 internal sDef0;
    uint256 internal sDef1;
    uint256 internal sInf0;
    uint256 internal sInf1;

    struct GrowthSnap {
        uint256 def0;
        uint256 def1;
        uint256 inf0;
        uint256 inf1;
    }

    GrowthSnap internal beforeSnap;
    GrowthSnap internal afterSnap;
    bool internal checkedFlip;
    bool internal lastFlipOk;
    int24 internal expectedFlipTick;
    uint256 internal expectedDefAfter0;
    uint256 internal expectedDefAfter1;
    uint256 internal expectedInfAfter0;
    uint256 internal expectedInfAfter1;

    constructor() {
        swapHarness = new VTSSwapLibHarness();
    }

    /// @notice Accrue a segment and assert deficit/inflow growth increments per token.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_accrue_segment(
        bool zeroForOne,
        uint160 sqrtCurrentRaw,
        uint160 sqrtTargetRaw,
        uint128 liquidityRaw,
        uint256 def0Raw,
        uint256 def1Raw,
        uint256 inf0Raw,
        uint256 inf1Raw
    ) external {
        unchecked {
            segmentAttempts++;
        }
        // Cache/clamp inputs for deterministic price segment and liquidity.
        _cacheInputs(zeroForOne, sqrtCurrentRaw, sqrtTargetRaw, liquidityRaw, def0Raw, def1Raw, inf0Raw, inf1Raw);
        // Apply a single segment accrual and compare against expected deltas.
        bool ok = _applyAndCheck();
        segmentChecks++;
        segmentAllOk = segmentAllOk && ok;
    }

    /// @notice Cross a tick and assert outside growth flips as `outside := global - outside`.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_tick_cross_flip(
        int24 tickRaw,
        uint256 defGlobal0,
        uint256 defGlobal1,
        uint256 infGlobal0,
        uint256 infGlobal1,
        uint256 defOutside0,
        uint256 defOutside1,
        uint256 infOutside0,
        uint256 infOutside1
    ) external {
        unchecked {
            flipAttempts++;
        }
        int24 tick = tickRaw;
        uint256 defOut0 = defGlobal0 == 0 ? 0 : defOutside0 % (defGlobal0 + 1);
        uint256 defOut1 = defGlobal1 == 0 ? 0 : defOutside1 % (defGlobal1 + 1);
        uint256 infOut0 = infGlobal0 == 0 ? 0 : infOutside0 % (infGlobal0 + 1);
        uint256 infOut1 = infGlobal1 == 0 ? 0 : infOutside1 % (infGlobal1 + 1);

        swapHarness.setDeficitGrowthGlobal(POOL_ID, defGlobal0, defGlobal1);
        swapHarness.setInflowGrowthGlobal(POOL_ID, infGlobal0, infGlobal1);
        swapHarness.setDeficitGrowthOutside(POOL_ID, tick, defOut0, defOut1);
        swapHarness.setInflowGrowthOutside(POOL_ID, tick, infOut0, infOut1);
        expectedFlipTick = tick;
        expectedDefAfter0 = defGlobal0 - defOut0;
        expectedDefAfter1 = defGlobal1 - defOut1;
        expectedInfAfter0 = infGlobal0 - infOut0;
        expectedInfAfter1 = infGlobal1 - infOut1;

        swapHarness.flipOutside(POOL_ID, tick, 0, 0);
        swapHarness.flipOutside(POOL_ID, tick, 1, 0);
        swapHarness.flipOutside(POOL_ID, tick, 0, 1);
        swapHarness.flipOutside(POOL_ID, tick, 1, 1);

        checkedFlip = true;
        lastFlipOk = _flipMatchesExpected();
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_vts_03_segment_growth_accounting() external view returns (bool) {
        if (segmentChecks == 0) {
            return segmentAttempts < MAX_VACUOUS_ATTEMPTS;
        }
        return segmentAllOk;
    }

    // Auxiliary flip identity check retained in this harness so flip calls don't become unverified.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_vts_03_aux_flip_identity() external view returns (bool) {
        if (!checkedFlip) {
            return flipAttempts < MAX_VACUOUS_ATTEMPTS;
        }
        return lastFlipOk;
    }

    // Keep a second trivial property to avoid rare Echidna instability with single-property targets.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_vts_03_smoke() external pure returns (bool) {
        return true;
    }

    function _clampSqrt(uint160 sqrtPriceX96) internal pure returns (uint160) {
        if (sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        if (sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return sqrtPriceX96;
    }

    function _cacheInputs(
        bool zeroForOne,
        uint160 sqrtCurrentRaw,
        uint160 sqrtTargetRaw,
        uint128 liquidityRaw,
        uint256 def0Raw,
        uint256 def1Raw,
        uint256 inf0Raw,
        uint256 inf1Raw
    ) internal {
        // Normalize direction and clamp sqrt prices into valid bounds.
        sZeroForOne = zeroForOne;
        sSqrtCurrent = _clampSqrt(sqrtCurrentRaw);
        sSqrtTarget = _clampSqrt(sqrtTargetRaw);
        if (sSqrtCurrent == sSqrtTarget) {
            sSqrtTarget =
                sSqrtCurrent == TickMath.MIN_SQRT_PRICE + 1 ? TickMath.MIN_SQRT_PRICE + 2 : TickMath.MIN_SQRT_PRICE + 1;
        }

        // Ensure sqrt ordering matches swap direction to avoid invalid deltas.
        if (sZeroForOne) {
            if (sSqrtTarget >= sSqrtCurrent) {
                if (sSqrtCurrent <= TickMath.MIN_SQRT_PRICE + 1) {
                    sSqrtCurrent = TickMath.MIN_SQRT_PRICE + 2;
                }
                sSqrtTarget = sSqrtCurrent - 1;
            }
        } else {
            if (sSqrtTarget <= sSqrtCurrent) {
                if (sSqrtCurrent >= TickMath.MAX_SQRT_PRICE - 1) {
                    sSqrtCurrent = TickMath.MAX_SQRT_PRICE - 2;
                }
                sSqrtTarget = sSqrtCurrent + 1;
            }
        }

        // Clamp liquidity and seed starting globals for the pool.
        sLiq = liquidityRaw == 0 ? 1 : liquidityRaw;
        sDef0 = def0Raw;
        sDef1 = def1Raw;
        sInf0 = inf0Raw;
        sInf1 = inf1Raw;

        swapHarness.setDeficitGrowthGlobal(POOL_ID, sDef0, sDef1);
        swapHarness.setInflowGrowthGlobal(POOL_ID, sInf0, sInf1);
    }

    function _applyAndCheck() internal returns (bool) {
        // Snapshot before/after growth globals across the segment.
        _snapshot(beforeSnap);
        swapHarness.accrueSegmentGrowth(POOL_ID, sZeroForOne, sSqrtCurrent, sSqrtTarget, sLiq);
        _snapshot(afterSnap);

        // Compute expected segment amounts and convert to growth deltas.
        uint256 outSeg = sZeroForOne
            ? SqrtPriceMath.getAmount1Delta(sSqrtTarget, sSqrtCurrent, sLiq, false)
            : SqrtPriceMath.getAmount0Delta(sSqrtCurrent, sSqrtTarget, sLiq, false);
        uint256 inNoFee = sZeroForOne
            ? SqrtPriceMath.getAmount0Delta(sSqrtCurrent, sSqrtTarget, sLiq, true)
            : SqrtPriceMath.getAmount1Delta(sSqrtTarget, sSqrtCurrent, sLiq, true);

        uint256 defDelta = outSeg == 0 ? 0 : FullMath.mulDiv(outSeg, FixedPoint128.Q128, uint256(sLiq));
        uint256 infDelta = inNoFee == 0 ? 0 : FullMath.mulDiv(inNoFee, FixedPoint128.Q128, uint256(sLiq));

        if (sZeroForOne) {
            return afterSnap.def0 == beforeSnap.def0 && afterSnap.def1 == beforeSnap.def1 + defDelta
                && afterSnap.inf0 == beforeSnap.inf0 + infDelta && afterSnap.inf1 == beforeSnap.inf1;
        }
        return afterSnap.def0 == beforeSnap.def0 + defDelta && afterSnap.def1 == beforeSnap.def1
            && afterSnap.inf0 == beforeSnap.inf0 && afterSnap.inf1 == beforeSnap.inf1 + infDelta;
    }

    function _snapshot(GrowthSnap storage snap) internal {
        // Read deficit/inflow global growth accumulators for both tokens.
        (snap.def0, snap.def1) = swapHarness.getDeficitGrowthGlobal(POOL_ID);
        (snap.inf0, snap.inf1) = swapHarness.getInflowGrowthGlobal(POOL_ID);
    }

    function _flipMatchesExpected() internal view returns (bool) {
        (uint256 defOut0After, uint256 defOut1After) = swapHarness.getDeficitGrowthOutside(POOL_ID, expectedFlipTick);
        (uint256 infOut0After, uint256 infOut1After) = swapHarness.getInflowGrowthOutside(POOL_ID, expectedFlipTick);
        return defOut0After == expectedDefAfter0 && defOut1After == expectedDefAfter1
            && infOut0After == expectedInfAfter0 && infOut1After == expectedInfAfter1;
    }
}

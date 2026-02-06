// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSSwapLibHarness} from "../libraries/harnesses/VTSSwapLibHarness.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-periphery/lib/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";

/// @notice Echidna harness for VTS-03: Swap outcomes must be reflected via segment-based deficit/inflow growth.
///         Segment-based deficit/inflow growth must accrue to the correct token
///         based on swap direction and price segment boundaries.
///         This sets initial globals, accrues a single segment, and checks the
///         expected per-token growth deltas computed from the same swap math.
contract VTSSwapVTS03SegmentGrowthEchidnaTest {
    VTSSwapLibHarness internal swapHarness;

    PoolId internal constant POOL_ID = PoolId.wrap(bytes32(uint256(0x5A03)));

    bool internal checked;
    bool internal lastOk;

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
        checked = false;
        lastOk = true;
        // Cache/clamp inputs for deterministic price segment and liquidity.
        _cacheInputs(zeroForOne, sqrtCurrentRaw, sqrtTargetRaw, liquidityRaw, def0Raw, def1Raw, inf0Raw, inf1Raw);
        // Apply a single segment accrual and compare against expected deltas.
        bool ok = _applyAndCheck();
        checked = true;
        lastOk = ok;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_vts_03_segment_growth_accounting() external view returns (bool) {
        return !checked || lastOk;
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
}

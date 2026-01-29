// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSStorage, PoolAccounting, GrowthPair} from "../../../src/types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {VTSSwapLib} from "../../../src/libraries/VTSSwapLib.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";

/// @title VTSSwapLibHarness
/// @notice Exposes internal VTSSwapLib functions for testing with an isolated VTSStorage
contract VTSSwapLibHarness {
    VTSStorage internal s;

    // ========= Exposed VTSSwapLib internals =========

    function flipOutside(PoolId poolId, int24 tick, uint8 tokenIndex, uint8 growthType) external {
        VTSSwapLib._flipOutside(s, poolId, tick, tokenIndex, growthType);
    }

    function accrueSegmentGrowth(
        PoolId poolId,
        bool zeroForOne,
        uint160 sqrtCurrent,
        uint160 sqrtTarget,
        uint128 liquidity
    ) external {
        // Inline the segment-growth logic to avoid touching core library visibility.
        if (liquidity == 0 || sqrtTarget == sqrtCurrent) return;

        uint256 outSeg = zeroForOne
            ? SqrtPriceMath.getAmount1Delta(sqrtTarget, sqrtCurrent, liquidity, false)
            : SqrtPriceMath.getAmount0Delta(sqrtCurrent, sqrtTarget, liquidity, false);
        if (outSeg > 0) {
            uint256 deltaG = FullMath.mulDiv(outSeg, FixedPoint128.Q128, uint256(liquidity));
            if (zeroForOne) {
                s.poolAccounting[poolId].deficitGrowthGlobal.token1 += deltaG;
            } else {
                s.poolAccounting[poolId].deficitGrowthGlobal.token0 += deltaG;
            }
        }

        uint256 inNoFee = zeroForOne
            ? SqrtPriceMath.getAmount0Delta(sqrtCurrent, sqrtTarget, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(sqrtTarget, sqrtCurrent, liquidity, true);
        if (inNoFee > 0) {
            uint256 deltaG = FullMath.mulDiv(inNoFee, FixedPoint128.Q128, uint256(liquidity));
            if (zeroForOne) {
                s.poolAccounting[poolId].inflowGrowthGlobal.token0 += deltaG;
            } else {
                s.poolAccounting[poolId].inflowGrowthGlobal.token1 += deltaG;
            }
        }
    }

    // ========= Storage setters =========

    function setDeficitGrowthGlobal(PoolId poolId, uint256 g0, uint256 g1) external {
        s.poolAccounting[poolId].deficitGrowthGlobal.token0 = g0;
        s.poolAccounting[poolId].deficitGrowthGlobal.token1 = g1;
    }

    function setInflowGrowthGlobal(PoolId poolId, uint256 g0, uint256 g1) external {
        s.poolAccounting[poolId].inflowGrowthGlobal.token0 = g0;
        s.poolAccounting[poolId].inflowGrowthGlobal.token1 = g1;
    }

    function setDeficitGrowthOutside(PoolId poolId, int24 tick, uint256 outside0, uint256 outside1) external {
        s.deficitGrowthOutside[poolId][tick] = GrowthPair({token0: outside0, token1: outside1});
    }

    function setInflowGrowthOutside(PoolId poolId, int24 tick, uint256 outside0, uint256 outside1) external {
        s.inflowGrowthOutside[poolId][tick] = GrowthPair({token0: outside0, token1: outside1});
    }

    // ========= Storage getters =========

    function getDeficitGrowthGlobal(PoolId poolId) external view returns (uint256 g0, uint256 g1) {
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        return (paPool.deficitGrowthGlobal.token0, paPool.deficitGrowthGlobal.token1);
    }

    function getInflowGrowthGlobal(PoolId poolId) external view returns (uint256 g0, uint256 g1) {
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        return (paPool.inflowGrowthGlobal.token0, paPool.inflowGrowthGlobal.token1);
    }

    function getDeficitGrowthOutside(PoolId poolId, int24 tick) external view returns (uint256 o0, uint256 o1) {
        GrowthPair storage outside = s.deficitGrowthOutside[poolId][tick];
        return (outside.token0, outside.token1);
    }

    function getInflowGrowthOutside(PoolId poolId, int24 tick) external view returns (uint256 o0, uint256 o1) {
        GrowthPair storage outside = s.inflowGrowthOutside[poolId][tick];
        return (outside.token0, outside.token1);
    }
}

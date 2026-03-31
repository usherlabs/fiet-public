// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSStorage, PoolAccounting, GrowthPair} from "../../../src/types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {VTSSwapLib} from "../../../src/libraries/VTSSwapLib.sol";

/// @title VTSSwapLibHarness
/// @notice Utility harness exposing selected VTSSwapLib-style maths over isolated storage.
/// @dev Used for narrow segment-growth property checks, not full swap integration.
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
        VTSSwapLib._accrueSegmentGrowth(s, poolId, zeroForOne, sqrtCurrent, sqrtTarget, liquidity);
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/**
 * @title GrowthAccounting
 * @notice Shared helpers for tick-indexed, per-liquidity growth accounting used by VTS.
 *
 * This library centralises the common mechanics adopted from Uniswap v3/v4:
 * - Global per-liquidity growth accumulators per token (Q128 scaling)
 * - Per-tick "outside" flips to derive exact "inside" growth for a range
 * - Inside growth computation across [tickLower, tickUpper]
 * - Settlement skeleton: delta vs last snapshot, scaled by position liquidity
 *
 * Functions:
 * - accrue:    add amount/L as Q128 growth to a pool’s global accumulator
 * - flipOutside: update a tick’s outside value (global - currentOutside)
 * - inside:    compute inside growth for a [lower, upper] range
 * - deltaAndCheckpoint: compute per-token adds (delta*L>>128) and update last snapshots
 *
 * Notes:
 * - Accepts storage mappings by reference; reads/writes cost the same as inline code
 * - Liquidity must be supplied by the caller (pool-wide for accrual; position for settle)
 * - This library is internal and intended to be inlined by the optimizer
 */
library GrowthAccounting {
    uint256 internal constant Q128 = 1 << 128;

    /**
     * - Growth accrues globally per swap as a per‑liquidity‑unit increment. Bound (initialised) ticks are only the partition points we flip at to compute “inside” for any range.
     *     - “Normalise over liquidity depth” happens implicitly: growth is per unit liquidity, then you multiply by the position’s liquidity to get raw token units; you don’t divide by L again.
     *
     *     The flow:
     *     - On each swap outflow for token A: Δg = outflowA / L_current → add to `deficitGrowthGlobal_A`.
     *     - On each initialised tick crossed (both directions): flip `deficitGrowthOutside_A(tick)` for A=0,1.
     *     - For a position r = [tickLower, tickUpper]:
     *     - `inside_A = global_A − outside_A(lower) − outside_A(upper)`.
     *     - `ΔD_attr = (inside_A − insideLast_A(r)) * L(r)` (raw token A units).
     *     - Net against in‑market settlements: consume `S_A(r)` first; only `max(0, ΔD_attr − S_A(r))` is added to `cumulativeDeficit_A(r)`.
     *     - Update `insideLast_A(r) = inside_A`.
     *
     *     - VTS_required(r, A) = min(1, `cumulativeDeficit_A(r)` / `C_A(r)`).
     *
     *     So: deficits are accrued globally per outflow, ticks just enable exact “inside” slice for your bounds, and the position’s attributed deficit is the inside growth times its liquidity, netted against its settled balance.
     */
    function accrue(
        mapping(PoolId => uint256[2]) storage gmap,
        PoolId poolId,
        uint8 token,
        uint256 amount,
        uint128 liquidity
    ) internal {
        if (token > 1 || amount == 0 || liquidity == 0) return;
        uint256 deltaG = FullMath.mulDiv(amount, Q128, uint256(liquidity));
        uint256[2] storage g = gmap[poolId];
        g[token] = g[token] + deltaG;
    }

    /**
     * - On each initialised tick crossed (both directions): flip `deficitGrowthOutside_A(tick)` for A=0,1.
     */
    function flipOutside(
        mapping(PoolId => uint256[2]) storage gmap,
        mapping(PoolId => mapping(int24 => uint256[2])) storage outside,
        PoolId poolId,
        int24 tick,
        uint8 token
    ) internal {
        if (token > 1) return;
        uint256 g = gmap[poolId][token];
        uint256 o = outside[poolId][tick][token];
        outside[poolId][tick][token] = g - o;
    }

    /**
     * - For a position r = [tickLower, tickUpper]:
     * - `inside_A = global_A − outside_A(lower) − outside_A(upper)`.
     */
    function inside(
        mapping(PoolId => uint256[2]) storage gmap,
        mapping(PoolId => mapping(int24 => uint256[2])) storage outside,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (uint256 inside0, uint256 inside1) {
        uint256 g0 = gmap[poolId][0];
        uint256 g1 = gmap[poolId][1];
        uint256 l0 = outside[poolId][tickLower][0];
        uint256 l1 = outside[poolId][tickLower][1];
        uint256 u0 = outside[poolId][tickUpper][0];
        uint256 u1 = outside[poolId][tickUpper][1];
        inside0 = g0 - l0 - u0;
        inside1 = g1 - l1 - u1;
    }

    function deltaAndCheckpoint(
        mapping(PoolId => uint256[2]) storage gmap,
        mapping(PoolId => mapping(int24 => uint256[2])) storage outside,
        uint256[2] storage lastSnap,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal returns (uint256 add0, uint256 add1) {
        (uint256 inside0, uint256 inside1) = inside(gmap, outside, poolId, tickLower, tickUpper);
        uint256 d0 = inside0 - lastSnap[0];
        uint256 d1 = inside1 - lastSnap[1];
        if (liquidity > 0) {
            if (d0 > 0) add0 = (d0 * uint256(liquidity)) >> 128; // TODO: is there a safer way to do this?
            if (d1 > 0) add1 = (d1 * uint256(liquidity)) >> 128;
        }
        lastSnap[0] = inside0;
        lastSnap[1] = inside1;
    }
}

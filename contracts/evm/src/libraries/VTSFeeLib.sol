// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {
    VTSStorage,
    PositionAccounting,
    PoolAccounting,
    GrowthPair,
    MarketVTSConfiguration,
    TokenPairUint,
    TokenPairInt,
    TokenPairLib
} from "../types/VTS.sol";
import {PositionId, Position} from "../types/Position.sol";
import {Pool} from "../types/Pool.sol";
import {LiquidityUtils} from "./LiquidityUtils.sol";

/// @title VTSFeeLib
/// @notice Fee processing, slashed pot management, and coverage burn logic for VTS
/// @dev All functions are external/public for linked-library usage but prefixed with `_` as they are conceptually internal.
/// @author Fiet Protocol
library VTSFeeLib {
    using SafeCast for uint256;
    using SafeCast for int256;
    using CurrencySettler for Currency;
    using TokenPairLib for TokenPairUint;
    using TokenPairLib for TokenPairInt;
    using StateLibrary for IPoolManager;

    // --------------------------------------------------
    // Fee Adjustment Helpers
    // --------------------------------------------------

    /// @notice Peek the current pending fee adjustments for a position without mutating state
    /// @param s The central VTS storage
    /// @param positionId The position ID
    /// @return adj0 The pending fee adjustment for token0 (+slash, -bonus)
    /// @return adj1 The pending fee adjustment for token1 (+slash, -bonus)
    function _peekFeeAdjustment(VTSStorage storage s, PositionId positionId)
        public
        view
        returns (int256 adj0, int256 adj1)
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        adj0 = pa.pendingFeeAdj.token0;
        adj1 = pa.pendingFeeAdj.token1;
    }

    /// @notice Increase the slashed pot for a pool/token when a take() succeeds
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param poolId The pool ID
    /// @param lccCurrency The LCC currency
    /// @param tokenIndex The token index (0 or 1)
    /// @param amount The amount to fund
    function _fundFeePot(
        VTSStorage storage s,
        IPoolManager poolManager,
        PoolId poolId,
        Currency lccCurrency,
        uint8 tokenIndex,
        uint256 amount
    ) public {
        if (amount == 0) return;
        // In linked libraries, address(this) refers to the calling contract via DELEGATECALL
        lccCurrency.take(poolManager, address(this), amount, true);
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        uint256 currentPot = paPool.slashedPot.get(tokenIndex);
        paPool.slashedPot.set(tokenIndex, currentPot + amount);
    }

    /// @notice Decrease the slashed pot when settling bonuses (giving out from CoreHook to PoolManager)
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param poolId The pool ID
    /// @param lccCurrency The LCC currency
    /// @param tokenIndex The token index (0 or 1)
    /// @param amount The amount to drain
    function _drainFeePot(
        VTSStorage storage s,
        IPoolManager poolManager,
        PoolId poolId,
        Currency lccCurrency,
        uint8 tokenIndex,
        uint256 amount
    ) public {
        if (amount == 0) return;
        lccCurrency.settle(poolManager, address(this), amount, true);
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        uint256 pot = paPool.slashedPot.get(tokenIndex);
        // Clamp to available pot to avoid underflow; caller must have already bounded the amount
        if (amount > pot) amount = pot;
        paPool.slashedPot.set(tokenIndex, pot - amount);
    }

    /// @notice Read fees since last snapshot and checkpoint fee growth and outflow snapshots atomically
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    /// @param poolId The pool ID
    /// @param tokenIndex The token index (0 or 1)
    /// @param positionLiquidity The position liquidity
    /// @return fees The fees accrued since last snapshot
    /// @return ofDelta The outflow delta since last fee snapshot
    function _readFeesAndCheckpoint(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId,
        PoolId poolId,
        uint8 tokenIndex,
        uint128 positionLiquidity
    ) public returns (uint256 fees, uint256 ofDelta) {
        Position memory pos = s.positions[positionId];
        (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, poolId, pos.tickLower, pos.tickUpper);
        uint256 fg = tokenIndex == 0 ? fg0 : fg1;

        PositionAccounting storage pa = s.positionAccounting[positionId];
        uint256 last = pa.feeGrowthInsideLast.get(tokenIndex);

        if (positionLiquidity > 0 && fg > last) {
            fees = FullMath.mulDiv(fg - last, uint256(positionLiquidity), FixedPoint128.Q128);
        } else {
            fees = 0;
        }

        // Compute outflow window and checkpoint both snapshots
        uint256 cf = pa.cumulativeOutflows.get(tokenIndex);
        uint256 snap = pa.outflowsAtFeeSnap.get(tokenIndex);
        ofDelta = cf >= snap ? (cf - snap) : 0;

        // Snapshot fees here
        pa.feeGrowthInsideLast.set(tokenIndex, fg);
        pa.outflowsAtFeeSnap.set(tokenIndex, cf);
    }

    /// @notice Apply coverage burn for a position
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param id The position ID
    /// @param p The pool ID
    /// @param tokenIndex The token index (0 or 1)
    /// @param cov The coverage usage amount
    /// @param positionLiquidity The position liquidity
    function _applyCoverageBurn(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId id,
        PoolId p,
        uint8 tokenIndex,
        uint256 cov,
        uint128 positionLiquidity
    ) public {
        PositionAccounting storage pa = s.positionAccounting[id];
        uint256 d = pa.cumulativeDeficit.get(tokenIndex);
        uint256 settled = pa.settled.get(tokenIndex);
        if (cov == 0 || (d == 0 && settled == 0)) return;

        // Enforce invariant: cov <= d + settled, then burn only deficit portion
        uint256 cEff = cov <= (d + settled) ? cov : (d + settled);
        if (cEff == 0 || d == 0) return;
        uint256 burnBase = cEff < d ? cEff : d; // min(coverage, deficit)

        (uint256 fees, uint256 ofDelta) = _readFeesAndCheckpoint(s, poolManager, id, p, tokenIndex, positionLiquidity);
        if (fees == 0 || ofDelta == 0) return;

        Pool memory pool = s.pools[p];
        MarketVTSConfiguration memory cfg = pool.vtsConfig;
        uint256 bps = cfg.coverageFeeShare;
        if (bps == 0) return;

        // feesBurn = fees * (burnBase / ofDelta) * bps/10000
        uint256 feesBurn = FullMath.mulDiv(fees, burnBase, ofDelta);
        feesBurn = FullMath.mulDiv(feesBurn, bps, LiquidityUtils.BPS_DENOMINATOR);
        if (feesBurn == 0) return;
        if (feesBurn > fees) feesBurn = fees; // clamp to fees accrued

        uint256 growthInc = 0;
        if (positionLiquidity > 0) {
            growthInc = FullMath.mulDiv(feesBurn, FixedPoint128.Q128, uint256(positionLiquidity));
            // Burn by advancing fee growth baseline
            uint256 currentFeeGrowth = pa.feeGrowthInsideLast.get(tokenIndex);
            pa.feeGrowthInsideLast.set(tokenIndex, currentFeeGrowth + growthInc);
        }

        PoolAccounting storage paPool = s.poolAccounting[p];
        uint256 currentProtocolFee = paPool.protocolFeeAccrued.get(tokenIndex);
        paPool.protocolFeeAccrued.set(tokenIndex, currentProtocolFee + feesBurn);
        uint256 currentFeesShared = pa.feesShared.get(tokenIndex);
        pa.feesShared.set(tokenIndex, currentFeesShared + feesBurn);
        int256 currentPendingAdj = pa.pendingFeeAdj.get(tokenIndex);
        pa.pendingFeeAdj.set(tokenIndex, currentPendingAdj + int256(feesBurn));
    }

    /// @notice Finalise a portion of the pending fee adjustment as materialised in the current hook call
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    /// @param poolId The pool ID
    /// @param currency0 The currency for token0
    /// @param currency1 The currency for token1
    /// @return adj The materialised delta as BalanceDelta for the hook to apply this call only
    function _finaliseFeeAdjustment(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId,
        PoolId poolId,
        Currency currency0,
        Currency currency1
    ) internal returns (BalanceDelta adj) {
        // Materialise pending: fund slashed pot for +ve; drain to LP for -ve
        (int256 pend0, int256 pend1) = _peekFeeAdjustment(s, positionId);
        int256 mat0 = 0;
        int256 mat1 = 0;

        if (pend0 > 0) {
            _fundFeePot(s, poolManager, poolId, currency0, 0, uint256(pend0));
            mat0 = pend0;
        } else if (pend0 < 0) {
            uint256 need0 = uint256(-pend0);
            PoolAccounting storage paPool = s.poolAccounting[poolId];
            uint256 pot0 = paPool.slashedPot.token0;
            uint256 pay0 = pot0 < need0 ? pot0 : need0;
            if (pay0 > 0) {
                _drainFeePot(s, poolManager, poolId, currency0, 0, pay0);
                mat0 = -pay0.toInt256();
            }
        }

        if (pend1 > 0) {
            _fundFeePot(s, poolManager, poolId, currency1, 1, uint256(pend1));
            mat1 = pend1;
        } else if (pend1 < 0) {
            uint256 need1 = uint256(-pend1);
            PoolAccounting storage paPool = s.poolAccounting[poolId];
            uint256 pot1 = paPool.slashedPot.token1;
            uint256 pay1 = pot1 < need1 ? pot1 : need1;
            if (pay1 > 0) {
                _drainFeePot(s, poolManager, poolId, currency1, 1, pay1);
                mat1 = -pay1.toInt256();
            }
        }

        // Clamp materialised values to current pending to avoid over-finalisation
        // For positive pending, materialised must be in [0, p]; for negative pending, in [p, 0]
        if (pend0 >= 0) {
            if (mat0 < 0) mat0 = 0;
            if (mat0 > pend0) mat0 = pend0;
        } else {
            if (mat0 > 0) mat0 = 0;
            if (mat0 < pend0) mat0 = pend0;
        }
        if (pend1 >= 0) {
            if (mat1 < 0) mat1 = 0;
            if (mat1 > pend1) mat1 = pend1;
        } else {
            if (mat1 > 0) mat1 = 0;
            if (mat1 < pend1) mat1 = pend1;
        }

        // Subtract the materialised portion from pending (note: signed arithmetic)
        PositionAccounting storage pa = s.positionAccounting[positionId];
        pa.pendingFeeAdj.token0 = pend0 - mat0;
        pa.pendingFeeAdj.token1 = pend1 - mat1;

        adj = LiquidityUtils.safeToBalanceDelta(mat0, mat1);

        // Snapshot current pending after finalisation to keep future settle-time funding incremental
        pa.lastFundedPendingAdj.token0 = pa.pendingFeeAdj.token0;
        pa.lastFundedPendingAdj.token1 = pa.pendingFeeAdj.token1;
    }

    /// @notice Consolidated fee processing for a position during modification: applies and zeros nets, queues bonus using net weighting
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    /// @param currency0 The currency for token0
    /// @param currency1 The currency for token1
    /// @return adj The materialised fee adjustment delta
    function _processPositionFees(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId,
        Currency currency0,
        Currency currency1
    ) public returns (BalanceDelta adj) {
        Position memory pos = s.positions[positionId];
        PoolId poolId = pos.poolId;
        Pool memory pool = s.pools[poolId];

        // If fee sharing is enabled, skip processing (fees handled elsewhere)
        if (pool.vtsConfig.coverageFeeShare > 0) {
            return toBalanceDelta(0, 0);
        }

        PositionAccounting storage pa = s.positionAccounting[positionId];
        PoolAccounting storage paPool = s.poolAccounting[poolId];

        // Read per-position nets (already applied to settled via _updateSettlement). Do not mutate yet
        int256 selfNet0 = pa.netSettlementSinceLastMod.token0;
        int256 selfNet1 = pa.netSettlementSinceLastMod.token1;

        // Queue bonuses using positive nets since last modification
        for (uint8 t = 0; t < 2; t++) {
            int256 selfNet = (t == 0) ? selfNet0 : selfNet1;
            if (selfNet <= 0) continue;

            uint256 pot = paPool.protocolFeeAccrued.get(t);
            uint256 selfContrib = pa.feesShared.get(t);
            uint256 potAvail = pot > selfContrib ? (pot - selfContrib) : 0;
            if (potAvail == 0) continue;

            uint256 totalNetBefore = paPool.poolNetSinceLastMod.get(t);
            // totalNetBefore is UNSIGNED. Only positive when settled > 0 - preventing positive nets that cover deficits from being used
            if (totalNetBefore == 0) continue;

            // Dust guard
            if (uint256(selfNet) < 1e12) continue;

            uint256 bonus = FullMath.mulDiv(potAvail, uint256(selfNet), totalNetBefore);
            if (bonus > potAvail) bonus = potAvail;

            // Deduct from pot, keep self-contrib excluded
            paPool.protocolFeeAccrued.set(t, potAvail - bonus + selfContrib);
            // Queue negative pending (bonus increases payout at materialisation)
            int256 currentPending = pa.pendingFeeAdj.get(t);
            pa.pendingFeeAdj.set(t, currentPending - bonus.toInt256());
        }

        // After allocation, zero/decrement nets so future allocations don't double-count
        if (selfNet0 != 0) {
            pa.netSettlementSinceLastMod.token0 = 0;
            if (selfNet0 > 0) {
                uint256 cur0 = paPool.poolNetSinceLastMod.token0;
                uint256 dec0 = uint256(selfNet0);
                paPool.poolNetSinceLastMod.token0 = dec0 > cur0 ? 0 : (cur0 - dec0);
            }
        }
        if (selfNet1 != 0) {
            pa.netSettlementSinceLastMod.token1 = 0;
            if (selfNet1 > 0) {
                uint256 cur1 = paPool.poolNetSinceLastMod.token1;
                uint256 dec1 = uint256(selfNet1);
                paPool.poolNetSinceLastMod.token1 = dec1 > cur1 ? 0 : (cur1 - dec1);
            }
        }

        return _finaliseFeeAdjustment(s, poolManager, positionId, poolId, currency0, currency1);
    }

    /// @dev Check if fee sharing is enabled for a pool
    function _isFeeSharingEnabled(VTSStorage storage s, PoolId p) public view returns (bool) {
        return s.pools[p].vtsConfig.coverageFeeShare > 0;
    }
}

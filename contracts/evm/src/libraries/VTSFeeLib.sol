// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {
    VTSStorage,
    PositionAccounting,
    PoolAccounting,
    TokenPairUint,
    TokenPairInt,
    TokenPairLib
} from "../types/VTS.sol";
import {PositionId, Position} from "../types/Position.sol";
import {LiquidityUtils} from "./LiquidityUtils.sol";

/// @title VTSFeeLib
/// @notice Fee processing, slashed pot management, and coverage burn logic for VTS
/// @author Fiet Protocol
library VTSFeeLib {
    using SafeCast for uint256;
    using SafeCast for int256;
    using TokenPairLib for TokenPairUint;
    using TokenPairLib for TokenPairInt;

    // --------------------------------------------------
    // Fee Adjustment Helpers
    // --------------------------------------------------

    /// @dev Queue a bonus for a single token using fee-accrual weighted positive net settlement since last modification.
    /// @return allocated True iff a non-zero bonus was queued (i.e. pendingFeeAdj was decreased).
    function _queueBonusForToken(
        PositionAccounting storage pa,
        PoolAccounting storage paPool,
        uint8 tokenIndex,
        int256 selfNet
    ) internal returns (bool allocated) {
        if (selfNet <= 0) return false;

        uint256 pot = paPool.protocolFeeAccrued.get(tokenIndex);
        uint256 selfContrib = pa.feesShared.get(tokenIndex);
        uint256 potAvail = pot > selfContrib ? (pot - selfContrib) : 0;
        if (potAvail == 0) return false;

        // Dust guard
        if (uint256(selfNet) < 1e12) return false;

        // Fee-accrual weighting (per token)
        uint256 selfFeeWeight = pa.feesAccruedSinceLastMod.get(tokenIndex);
        if (selfFeeWeight == 0) return false;

        uint256 totalWeightBefore = paPool.poolNetFeeWeightSinceLastMod.get(tokenIndex);
        if (totalWeightBefore == 0) return false;

        uint256 selfWeight = uint256(selfNet) * selfFeeWeight;
        if (selfWeight == 0) return false;

        // bonus = potAvail * selfWeight / totalWeightBefore
        uint256 bonus = FullMath.mulDiv(potAvail, selfWeight, totalWeightBefore);
        if (bonus > potAvail) bonus = potAvail;
        // Banked selfNet/feeWeight: if rounding yields 0, do not clear windows so it can be allocated later.
        if (bonus == 0) return false;

        // Deduct from pot, keep self-contrib excluded
        paPool.protocolFeeAccrued.set(tokenIndex, potAvail - bonus + selfContrib);
        // Queue negative pending (bonus increases payout at materialisation)
        int256 currentPending = pa.pendingFeeAdj.get(tokenIndex);
        pa.pendingFeeAdj.set(tokenIndex, currentPending - bonus.toInt256());
        return true;
    }

    /// @dev After bonus allocation, clear/decrement per-position and per-pool windows so future allocations don't double-count.
    function _cleanupAfterAllocationForToken(
        PositionAccounting storage pa,
        PoolAccounting storage paPool,
        uint8 tokenIndex,
        int256 selfNet
    ) internal {
        if (selfNet == 0) return;

        uint256 feeW = pa.feesAccruedSinceLastMod.get(tokenIndex);
        pa.netSettlementSinceLastMod.set(tokenIndex, 0);

        if (selfNet > 0) {
            uint256 curNet = paPool.poolNetSinceLastMod.get(tokenIndex);
            uint256 decNet = uint256(selfNet);
            paPool.poolNetSinceLastMod.set(tokenIndex, decNet > curNet ? 0 : (curNet - decNet));
        }

        // Decrement product-weight accumulator and fee-weight pool totals, then clear position fee weight window.
        if (feeW > 0) {
            if (selfNet > 0) {
                uint256 curW = paPool.poolNetFeeWeightSinceLastMod.get(tokenIndex);
                uint256 decW = uint256(selfNet) * feeW;
                paPool.poolNetFeeWeightSinceLastMod.set(tokenIndex, decW > curW ? 0 : (curW - decW));
            }

            uint256 curF = paPool.poolFeesAccruedSinceLastMod.get(tokenIndex);
            paPool.poolFeesAccruedSinceLastMod.set(tokenIndex, feeW > curF ? 0 : (curF - feeW));
            pa.feesAccruedSinceLastMod.set(tokenIndex, 0);
        }
    }

    /// @notice Peek the current pending fee adjustments for a position without mutating state
    /// @param s The central VTS storage
    /// @param positionId The position ID
    /// @return adj0 The pending fee adjustment for token0 (+slash, -bonus)
    /// @return adj1 The pending fee adjustment for token1 (+slash, -bonus)
    function _peekFeeAdjustment(VTSStorage storage s, PositionId positionId)
        internal
        view
        returns (int256 adj0, int256 adj1)
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        adj0 = pa.pendingFeeAdj.token0;
        adj1 = pa.pendingFeeAdj.token1;
    }

    /// @notice Increase the slashed pot accounting for a pool/token
    /// @dev Only updates accounting state. Actual ERC6909 mint is handled by CoreHook.settleHookDeltasToPot
    /// @param s The central VTS storage
    /// @param poolId The pool ID
    /// @param tokenIndex The token index (0 or 1)
    /// @param amount The amount to fund
    function _fundFeePot(VTSStorage storage s, PoolId poolId, uint8 tokenIndex, uint256 amount) internal {
        if (amount == 0) return;
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        uint256 currentPot = paPool.slashedPot.get(tokenIndex);
        paPool.slashedPot.set(tokenIndex, currentPot + amount);
    }

    /// @notice Decrease the slashed pot accounting when settling bonuses
    /// @dev Only updates accounting state. Actual ERC6909 burn is handled by CoreHook.settleHookDeltasToPot
    /// @param s The central VTS storage
    /// @param poolId The pool ID
    /// @param tokenIndex The token index (0 or 1)
    /// @param amount The amount to drain
    function _drainFeePot(VTSStorage storage s, PoolId poolId, uint8 tokenIndex, uint256 amount) internal {
        if (amount == 0) return;
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        uint256 pot = paPool.slashedPot.get(tokenIndex);
        // Clamp to available pot to avoid underflow; caller must have already bounded the amount
        if (amount > pot) amount = pot;
        paPool.slashedPot.set(tokenIndex, pot - amount);
    }

    /// @notice Finalise a portion of the pending fee adjustment as materialised in the current hook call
    /// @dev Updates accounting state only. Actual ERC6909 mint/burn is handled by CoreHook.settleHookDeltasToPot
    /// @param s The central VTS storage
    /// @param positionId The position ID
    /// @param poolId The pool ID
    /// @return adj The materialised delta as BalanceDelta for the hook to apply this call only
    function _finaliseFeeAdjustment(VTSStorage storage s, PositionId positionId, PoolId poolId)
        internal
        returns (BalanceDelta adj)
    {
        // Materialise pending: fund slashed pot for +ve; drain to LP for -ve
        (int256 pend0, int256 pend1) = _peekFeeAdjustment(s, positionId);
        int256 mat0 = 0;
        int256 mat1 = 0;

        if (pend0 > 0) {
            _fundFeePot(s, poolId, 0, uint256(pend0));
            mat0 = pend0;
        } else if (pend0 < 0) {
            uint256 need0 = uint256(-pend0);
            PoolAccounting storage paPool = s.poolAccounting[poolId];
            uint256 pot0 = paPool.slashedPot.token0;
            uint256 pay0 = pot0 < need0 ? pot0 : need0;
            if (pay0 > 0) {
                _drainFeePot(s, poolId, 0, pay0);
                mat0 = -pay0.toInt256();
            }
        }

        if (pend1 > 0) {
            _fundFeePot(s, poolId, 1, uint256(pend1));
            mat1 = pend1;
        } else if (pend1 < 0) {
            uint256 need1 = uint256(-pend1);
            PoolAccounting storage paPool = s.poolAccounting[poolId];
            uint256 pot1 = paPool.slashedPot.token1;
            uint256 pay1 = pot1 < need1 ? pot1 : need1;
            if (pay1 > 0) {
                _drainFeePot(s, poolId, 1, pay1);
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
    }

    /// @notice Consolidated fee processing for a position during modification: applies and zeros nets, queues bonus using net weighting
    /// @dev Updates accounting state only. Actual ERC6909 mint/burn is handled by CoreHook.settleHookDeltasToPot
    /// @param s The central VTS storage
    /// @param positionId The position ID
    /// @return adj The materialised fee adjustment delta
    function processPositionFees(VTSStorage storage s, PositionId positionId) internal returns (BalanceDelta adj) {
        Position memory pos = s.positions[positionId];
        PoolId poolId = pos.poolId;

        // If fee sharing is disabled, skip processing (fees handled natively by Uniswap)
        if (!_isFeeSharingEnabled(s, poolId)) {
            return toBalanceDelta(0, 0);
        }

        PositionAccounting storage pa = s.positionAccounting[positionId];
        PoolAccounting storage paPool = s.poolAccounting[poolId];

        // Read per-position nets (already applied to settled via _updateSettlement). Do not mutate yet
        int256 selfNet0 = pa.netSettlementSinceLastMod.token0;
        int256 selfNet1 = pa.netSettlementSinceLastMod.token1;

        // Queue bonuses using positive nets since last modification, and distribute proportionally
        // to native Uniswap fees accrued (modifyLiquidity-time) as a proxy for time/exposure.
        //
        // Weight per token: w = selfNet * feeWeight, where feeWeight is feesAccruedSinceLastMod.
        bool allocated0 = _queueBonusForToken(pa, paPool, 0, selfNet0);
        bool allocated1 = _queueBonusForToken(pa, paPool, 1, selfNet1);

        // Banked selfNet:
        // Only clear/decrement the windows if we actually queued a bonus for that token.
        // This ensures contributions remain eligible if potAvail was 0 at touch time.
        if (allocated0) _cleanupAfterAllocationForToken(pa, paPool, 0, selfNet0);
        if (allocated1) _cleanupAfterAllocationForToken(pa, paPool, 1, selfNet1);

        return _finaliseFeeAdjustment(s, positionId, poolId);
    }

    /// @dev Check if fee sharing is enabled for a pool
    function _isFeeSharingEnabled(VTSStorage storage s, PoolId p) internal view returns (bool) {
        return s.pools[p].vtsConfig.coverageFeeShare > 0;
    }
}

/// @title VTSFeeLinkedLib
/// @notice Library for VTS fee processing
/// @dev Operates on VTSStorage storage struct via storage pointers
library VTSFeeLinkedLib {
    /// @notice Processes the fees for a position
    /// @dev Updates accounting state only. Actual ERC6909 mint/burn is handled by CoreHook.settleHookDeltasToPot
    /// @param s The VTS storage
    /// @param positionId The position ID
    /// @return adj The materialised fee adjustment delta
    function processPositionFees(VTSStorage storage s, PositionId positionId) external returns (BalanceDelta adj) {
        return VTSFeeLib.processPositionFees(s, positionId);
    }
}

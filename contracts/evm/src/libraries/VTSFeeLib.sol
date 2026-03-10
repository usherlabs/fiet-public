// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
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

    /// @dev Queue a bonus for a single token using CISE (Coverage-Indexed Settled Exposure).
    /// @notice CISE replaces selfNet as the primary eligibility gate, fixing the commitmentMax clamp bug.
    ///         Positions accrue exposure when incrementCoverage is called, proportional to their settled liquidity.
    ///         CSI (Contribution Spend Index) is used for self-exclusion to ensure positions can receive bonuses
    ///         even after their contributed slashes have been distributed to others.
    /// @param pa The position accounting storage reference
    /// @param paPool The pool accounting storage reference
    /// @param feeTokenIndex The fee token index (0 or 1) - the pot from which bonus is allocated
    /// @param coverageTokenIndex The coverage token index (opposite of feeTokenIndex) - the token whose exposure is used
    /// @param ciseExposure The position's realised CISE exposure since last allocation (from coverageTokenIndex)
    /// @return allocated True iff a non-zero bonus was queued (i.e. pendingFeeAdj was decreased).
    function _queueBonusForToken(
        PositionAccounting storage pa,
        PoolAccounting storage paPool,
        uint8 feeTokenIndex,
        uint8 coverageTokenIndex,
        uint256 ciseExposure
    ) internal returns (bool allocated) {
        // CISE: Use exposure as eligibility gate instead of selfNet
        if (ciseExposure == 0) return false;

        // CSI: Sync remaining contribution shares before reading selfRemaining
        _syncFeesSharedRemainingForToken(pa, paPool, feeTokenIndex);

        uint256 pot = paPool.protocolFeeAccrued.get(feeTokenIndex);

        // CSI: feesShared is stored as remaining self-contribution (not lifetime)
        uint256 selfRemaining = pa.feesShared.get(feeTokenIndex);
        uint256 potAvail = pot > selfRemaining ? (pot - selfRemaining) : 0;

        if (potAvail == 0) return false;

        // CISE: Use totalCISEExposureSinceLastMod from coverageTokenIndex as denominator
        uint256 totalExposure = paPool.totalCISEExposureSinceLastMod.get(coverageTokenIndex);
        if (totalExposure == 0) return false;

        // bonus = potAvail * ciseExposure / totalExposure
        uint256 bonus = FullMath.mulDiv(potAvail, ciseExposure, totalExposure);
        if (bonus > potAvail) bonus = potAvail;
        // Banked exposure: if rounding yields 0, do not clear windows so it can be allocated later.
        if (bonus == 0) return false;

        // CSI: Advance spend index (spend down the pot across all remaining contribution shares).
        // Note: Under consistent accounting, total remaining shares == current pot (pre-spend).
        if (pot > 0) {
            uint256 deltaIndex = FullMath.mulDiv(bonus, FixedPoint128.Q128, pot);
            uint256 currentIndex = paPool.feesSharedSpendIndexX128.get(feeTokenIndex);
            // The spend index is a accumulator tracking how much of the pot, comprised of all positions' feesShared, has been spent.
            paPool.feesSharedSpendIndexX128.set(feeTokenIndex, currentIndex + deltaIndex);
        }

        // Deduct from pot (accounting)
        paPool.protocolFeeAccrued.set(feeTokenIndex, pot - bonus);

        // Queue negative pending (bonus increases payout at materialisation)
        int256 currentPending = pa.pendingFeeAdj.get(feeTokenIndex);
        pa.pendingFeeAdj.set(feeTokenIndex, currentPending - bonus.toInt256());
        return true;
    }

    /// @dev After bonus allocation, clear/decrement per-position and per-pool CISE windows so future allocations don't double-count.
    /// @param pa The position accounting storage reference
    /// @param paPool The pool accounting storage reference
    /// @param coverageTokenIndex The coverage token index - the token whose exposure was used for allocation
    /// @param ciseExposure The position's CISE exposure for the coverage token
    function _cleanupAfterAllocationForToken(
        PositionAccounting storage pa,
        PoolAccounting storage paPool,
        uint8 coverageTokenIndex,
        uint256 ciseExposure
    ) internal {
        if (ciseExposure == 0) return;

        // CISE: Clear position exposure window and decrement pool total
        uint256 curExposure = paPool.totalCISEExposureSinceLastMod.get(coverageTokenIndex);
        paPool.totalCISEExposureSinceLastMod
            .set(coverageTokenIndex, ciseExposure > curExposure ? 0 : (curExposure - ciseExposure));
        pa.ciseExposureSinceLastMod.set(coverageTokenIndex, 0);
    }

    // --------------------------------------------------
    // CSI (Contribution Spend Index) Helpers
    // --------------------------------------------------

    /// @dev Sync a position's remaining feesShared (self-contribution still embedded in the pot)
    ///      against the pool spend index.
    /// @notice Must be called BEFORE incrementing feesShared (slash) or reading selfRemaining (bonus)
    /// @param pa The position accounting storage reference
    /// @param paPool The pool accounting storage reference
    /// @param tokenIndex The token index (0 or 1)
    function _syncFeesSharedRemainingForToken(
        PositionAccounting storage pa,
        PoolAccounting storage paPool,
        uint8 tokenIndex
    ) internal {
        uint256 indexNow = paPool.feesSharedSpendIndexX128.get(tokenIndex);
        uint256 indexLast = pa.feesSharedIndexLastX128.get(tokenIndex);

        // Always checkpoint index (even if no consumption to apply)
        if (indexNow != indexLast) {
            pa.feesSharedIndexLastX128.set(tokenIndex, indexNow);
        }

        uint256 deltaIndex = indexNow - indexLast;
        if (deltaIndex > 0) {
            uint256 sharesRemaining = pa.feesShared.get(tokenIndex);
            uint256 spent = FullMath.mulDiv(sharesRemaining, deltaIndex, FixedPoint128.Q128);
            if (spent > 0) {
                pa.feesShared.set(tokenIndex, spent >= sharesRemaining ? 0 : (sharesRemaining - spent));
            }
        }
    }

    // --------------------------------------------------
    // CISE (Coverage-Indexed Settled Exposure) Helpers
    // --------------------------------------------------

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
    //#olympix-ignore-reentrancy
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

        // Note on clamping:
        // Under the current construction:
        // - pend > 0  => mat == pend
        // - pend < 0  => mat == -min(pot, -pend) which is always in [pend, 0]
        // Therefore, mat cannot over-finalise pending, and sign-mismatch clamps are unreachable.

        // Subtract the materialised portion from pending (note: signed arithmetic)
        PositionAccounting storage pa = s.positionAccounting[positionId];
        pa.pendingFeeAdj.token0 = pend0 - mat0;
        pa.pendingFeeAdj.token1 = pend1 - mat1;

        adj = LiquidityUtils.safeToBalanceDelta(mat0, mat1);
    }

    /// @notice Consolidated fee processing for a position during modification: realises CISE exposure and queues bonus
    /// @dev Updates accounting state only. Actual ERC6909 mint/burn is handled by CoreHook.settleHookDeltasToPot
    /// @param s The central VTS storage
    /// @param positionId The position ID
    /// @return adj The materialised fee adjustment delta
    function _processPositionFees(VTSStorage storage s, PositionId positionId) internal returns (BalanceDelta adj) {
        Position memory pos = s.positions[positionId];
        PoolId poolId = pos.poolId;

        // If fee sharing is disabled, skip processing (fees handled natively by Uniswap)
        if (!_isFeeSharingEnabled(s, poolId)) {
            return toBalanceDelta(0, 0);
        }

        PositionAccounting storage pa = s.positionAccounting[positionId];
        PoolAccounting storage paPool = s.poolAccounting[poolId];

        // Read CISE exposure for bonus allocation
        // Note: Raw exposure values per coverage token
        uint256 ciseExposure0 = pa.ciseExposureSinceLastMod.token0;
        uint256 ciseExposure1 = pa.ciseExposureSinceLastMod.token1;

        // Queue bonuses using CISE exposure (coverage-indexed settled exposure)
        // Token direction mapping: fee pot in token T is funded by deficits in the opposite token.
        // - token0 pot ← token1 deficit coverage → use token1 exposure for token0 bonus
        // - token1 pot ← token0 deficit coverage → use token0 exposure for token1 bonus
        // This fixes the commitmentMax clamp bug where selfNet stays 0 for fully-settled positions
        bool allocated0 = _queueBonusForToken(pa, paPool, 0, 1, ciseExposure1);
        bool allocated1 = _queueBonusForToken(pa, paPool, 1, 0, ciseExposure0);

        // Banked exposure:
        // Only clear/decrement the windows if we actually queued a bonus for that token.
        // This ensures contributions remain eligible if potAvail was 0 at touch time.
        if (allocated0) _cleanupAfterAllocationForToken(pa, paPool, 1, ciseExposure1);
        if (allocated1) _cleanupAfterAllocationForToken(pa, paPool, 0, ciseExposure0);

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
    /// @notice Processes the fees for a position after touch
    /// @dev Updates accounting state only. Actual ERC6909 mint/burn is handled by CoreHook.settleHookDeltasToPot
    /// @param s The VTS storage
    /// @param positionId The position ID
    /// @return adj The materialised fee adjustment delta
    function afterTouchPosition(VTSStorage storage s, PositionId positionId) external returns (BalanceDelta adj) {
        return VTSFeeLib._processPositionFees(s, positionId);
    }
}

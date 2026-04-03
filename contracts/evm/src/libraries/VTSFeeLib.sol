// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
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

    /// @dev Internal struct to keep fee-burn helper signatures below stack-too-deep thresholds.
    struct FeesBurnParams {
        PoolId poolId;
        uint8 deficitTokenIndex;
        uint8 feeTokenIndex;
        uint256 burnBase;
        uint128 positionLiquidity;
        uint256 outflowFloor;
    }

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

        // CISE: Denominator is the pool-wide coverage window (eager on incrementCoverage / CISE residual flush),
        // decremented on allocation; not lazily summed from per-touch position realisations.
        uint256 totalExposure = paPool.totalCISEExposureSinceLastMod.get(coverageTokenIndex);
        if (totalExposure == 0) return false;

        // bonus = potAvail * ciseExposure / totalExposure (round up so dust does not strand eligible exposure)
        uint256 bonus = FullMath.mulDivRoundingUp(potAvail, ciseExposure, totalExposure);
        if (bonus > potAvail) bonus = potAvail;
        if (bonus == 0) return false;

        // CSI: Update the cumulative remaining-share factor for this epoch.
        // Note: Under consistent accounting, total remaining shares == current pot (pre-spend).
        if (pot > 0) _advanceFeesSharedFactor(paPool, feeTokenIndex, pot, bonus);

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
    ///      against the pool remaining-share factor for the current spend epoch.
    /// @notice Must be called BEFORE incrementing feesShared (slash) or reading selfRemaining (bonus)
    /// @param pa The position accounting storage reference
    /// @param paPool The pool accounting storage reference
    /// @param tokenIndex The token index (0 or 1)
    function _syncFeesSharedRemainingForToken(
        PositionAccounting storage pa,
        PoolAccounting storage paPool,
        uint8 tokenIndex
    ) internal {
        uint256 epochNow = _currentFeesSharedEpoch(paPool, tokenIndex);
        if (epochNow == 0) return;

        uint256 epochLast = pa.feesSharedEpoch.get(tokenIndex);
        uint256 indexNow = paPool.feesSharedSpendIndexX128.get(tokenIndex);

        // Legacy positions from pre-epoch storage are treated as belonging to epoch 1 so outstanding shares remain
        // valid after this upgrade. Later epoch changes only happen after a full spend-down, so stale shares are 0.
        if (epochLast == 0 && epochNow == 1) {
            epochLast = 1;
        }

        if (epochLast != epochNow) {
            if (pa.feesShared.get(tokenIndex) != 0) {
                pa.feesShared.set(tokenIndex, 0);
            }
            pa.feesSharedEpoch.set(tokenIndex, epochNow);
            pa.feesSharedIndexLastX128.set(tokenIndex, indexNow);
            return;
        }

        uint256 indexLast = pa.feesSharedIndexLastX128.get(tokenIndex);
        if (indexNow == indexLast) return;

        uint256 sharesRemaining = pa.feesShared.get(tokenIndex);
        if (sharesRemaining > 0) {
            uint256 updatedShares;
            if (indexLast == 0) {
                // No spend had been realised against this position in the current epoch yet. A zero pool factor is still
                // the identity state until the first bonus allocation stores a non-zero remaining-share factor.
                updatedShares =
                    indexNow == 0 ? sharesRemaining : FullMath.mulDiv(sharesRemaining, indexNow, FixedPoint128.Q128);
            } else {
                updatedShares = indexNow == 0 ? 0 : FullMath.mulDiv(sharesRemaining, indexNow, indexLast);
            }

            if (updatedShares != sharesRemaining) {
                pa.feesShared.set(tokenIndex, updatedShares);
            }
        }

        pa.feesSharedEpoch.set(tokenIndex, epochNow);
        pa.feesSharedIndexLastX128.set(tokenIndex, indexNow);
    }

    function _currentFeesSharedEpoch(PoolAccounting storage paPool, uint8 tokenIndex)
        private
        view
        returns (uint256 epoch)
    {
        epoch = paPool.feesSharedEpoch.get(tokenIndex);
        if (epoch == 0) {
            uint256 factor = paPool.feesSharedSpendIndexX128.get(tokenIndex);
            uint256 protocolPot = paPool.protocolFeeAccrued.get(tokenIndex);
            if (factor != 0 || protocolPot != 0) {
                return 1;
            }
        }
    }

    function _beginFeesSharedEpochIfNeeded(PoolAccounting storage paPool, uint8 tokenIndex) internal {
        uint256 epoch = paPool.feesSharedEpoch.get(tokenIndex);
        if (epoch == 0) {
            paPool.feesSharedEpoch.set(tokenIndex, 1);
            return;
        }

        uint256 factor = paPool.feesSharedSpendIndexX128.get(tokenIndex);
        uint256 protocolPot = paPool.protocolFeeAccrued.get(tokenIndex);
        if (factor == 0 && protocolPot == 0) {
            paPool.feesSharedEpoch.set(tokenIndex, epoch + 1);
        }
    }

    function _advanceFeesSharedFactor(PoolAccounting storage paPool, uint8 tokenIndex, uint256 pot, uint256 bonus)
        private
    {
        if (paPool.feesSharedEpoch.get(tokenIndex) == 0) {
            paPool.feesSharedEpoch.set(tokenIndex, 1);
        }

        uint256 currentFactor = paPool.feesSharedSpendIndexX128.get(tokenIndex);
        uint256 factorBase = currentFactor == 0 ? FixedPoint128.Q128 : currentFactor;
        uint256 nextFactor = FullMath.mulDivRoundingUp(factorBase, pot - bonus, pot);
        paPool.feesSharedSpendIndexX128.set(tokenIndex, nextFactor);
    }

    function _prepareFeeShareMint(PositionAccounting storage pa, PoolAccounting storage paPool, uint8 feeTokenIndex)
        internal
    {
        _beginFeesSharedEpochIfNeeded(paPool, feeTokenIndex);
        _syncFeesSharedRemainingForToken(pa, paPool, feeTokenIndex);
    }

    /// @notice Calculate fees and checkpoint snapshots for coverage burn
    /// @dev Extracted to keep position-side DICE orchestration small.
    function _calculateFeesBurn(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId,
        FeesBurnParams memory params
    ) internal returns (uint256 feesBurn, uint256 consumedBurnBase, uint256 consumedFees) {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        uint256 fees;
        uint256 fg;

        {
            Position memory pos = s.positions[positionId];
            (uint256 fg0, uint256 fg1) =
                StateLibrary.getFeeGrowthInside(poolManager, params.poolId, pos.tickLower, pos.tickUpper);
            fg = params.feeTokenIndex == 0 ? fg0 : fg1;

            uint256 lastFeeGrowth = pa.feeGrowthInsideLast.get(params.feeTokenIndex);
            if (params.positionLiquidity > 0 && fg > lastFeeGrowth) {
                fees = FullMath.mulDiv(fg - lastFeeGrowth, uint256(params.positionLiquidity), FixedPoint128.Q128);
            }
        }

        uint256 cumulativeOutflows = pa.cumulativeOutflows.get(params.deficitTokenIndex);
        uint256 snap = pa.outflowsAtFeeSnap.get(params.deficitTokenIndex);
        if (params.outflowFloor > snap) {
            snap = params.outflowFloor;
        }
        uint256 ofDelta = cumulativeOutflows >= snap ? (cumulativeOutflows - snap) : 0;

        if (fees == 0 || ofDelta == 0) {
            return (0, 0, 0);
        }

        return _finaliseFeesBurn(s, pa, params, fees, ofDelta, snap);
    }

    /// @dev Finalise fees burn maths and update outflow checkpoints for the consumed window share.
    function _finaliseFeesBurn(
        VTSStorage storage s,
        PositionAccounting storage pa,
        FeesBurnParams memory params,
        uint256 fees,
        uint256 ofDelta,
        uint256 snap
    ) internal returns (uint256, uint256, uint256) {
        uint256 bps = s.pools[params.poolId].vtsConfig.coverageFeeShare;
        if (bps == 0) {
            return (0, 0, 0);
        }
        if (bps > LiquidityUtils.BPS_DENOMINATOR) {
            bps = LiquidityUtils.BPS_DENOMINATOR;
        }

        uint256 consumedBurnBase = params.burnBase <= ofDelta ? params.burnBase : ofDelta;
        uint256 consumedFees = FullMath.mulDiv(fees, consumedBurnBase, ofDelta);
        uint256 feesBurn = FullMath.mulDiv(consumedFees, bps, LiquidityUtils.BPS_DENOMINATOR);

        if (feesBurn > 0) {
            pa.outflowsAtFeeSnap.set(params.deficitTokenIndex, snap + consumedBurnBase);
        }

        return (feesBurn, consumedBurnBase, consumedFees);
    }

    /// @dev Keep `_applyBurnBase` below stack-too-deep threshold for non-via-ir builds.
    function _calculateFeesBurnForApply(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId,
        PoolId poolId,
        uint8 tokenIndex,
        uint8 feeTokenIndex,
        uint256 burnBase,
        uint128 positionLiquidity,
        uint256 outflowFloor
    ) internal returns (uint256 feesBurn, uint256 consumedBurnBase, uint256 consumedFees) {
        FeesBurnParams memory params = FeesBurnParams({
            poolId: poolId,
            deficitTokenIndex: tokenIndex,
            feeTokenIndex: feeTokenIndex,
            burnBase: burnBase,
            positionLiquidity: positionLiquidity,
            outflowFloor: outflowFloor
        });
        return _calculateFeesBurn(s, poolManager, positionId, params);
    }

    /// @notice Apply a precomputed burn base for a position and return the consumed outflow share
    function _applyBurnBase(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId,
        PoolId poolId,
        uint8 tokenIndex,
        uint256 burnBase,
        uint128 positionLiquidity,
        uint256 outflowFloor
    ) internal returns (uint256 consumedBurnBase) {
        if (burnBase == 0) return 0;

        PositionAccounting storage pa = s.positionAccounting[positionId];
        uint8 feeTokenIndex = tokenIndex == 0 ? 1 : 0;
        uint256 feesBurn;
        uint256 consumedFees;
        (feesBurn, consumedBurnBase, consumedFees) = _calculateFeesBurnForApply(
            s, poolManager, positionId, poolId, tokenIndex, feeTokenIndex, burnBase, positionLiquidity, outflowFloor
        );

        if (feesBurn == 0) return 0;

        if (positionLiquidity > 0) {
            uint256 liquidity = uint256(positionLiquidity);
            uint256 carryIn = pa.feeBurnGrowthRemainder.get(feeTokenIndex);
            (uint256 growthInc, uint256 newCarry) =
                LiquidityUtils.feeBurnGrowthIncWithRemainder(consumedFees, liquidity, carryIn);
            pa.feeBurnGrowthRemainder.set(feeTokenIndex, newCarry);
            pa.feeGrowthInsideLast.set(feeTokenIndex, pa.feeGrowthInsideLast.get(feeTokenIndex) + growthInc);
        }

        PoolAccounting storage paPool = s.poolAccounting[poolId];
        _prepareFeeShareMint(pa, paPool, feeTokenIndex);

        paPool.protocolFeeAccrued.set(feeTokenIndex, paPool.protocolFeeAccrued.get(feeTokenIndex) + feesBurn);
        pa.feesShared.set(feeTokenIndex, pa.feesShared.get(feeTokenIndex) + feesBurn);
        pa.pendingFeeAdj.set(feeTokenIndex, pa.pendingFeeAdj.get(feeTokenIndex) + feesBurn.toInt256());
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
    /// @notice Prepares CSI state before minting fresh fee-share contributions for a position
    /// @dev Advances the spend epoch if needed, then syncs the position's remaining self-share
    ///      against the current pool factor before the caller increases `protocolFeeAccrued` and `feesShared`.
    /// @param pa The position accounting storage reference
    /// @param paPool The pool accounting storage reference
    /// @param feeTokenIndex The fee token index receiving the newly minted contribution
    function beforeFeeShareMint(PositionAccounting storage pa, PoolAccounting storage paPool, uint8 feeTokenIndex)
        external
    {
        VTSFeeLib._prepareFeeShareMint(pa, paPool, feeTokenIndex);
    }

    /// @notice Processes the fees for a position after touch
    /// @dev Updates accounting state only. Actual ERC6909 mint/burn is handled by CoreHook.settleHookDeltasToPot
    /// @param s The VTS storage
    /// @param positionId The position ID
    /// @return adj The materialised fee adjustment delta
    function afterTouchPosition(VTSStorage storage s, PositionId positionId) external returns (BalanceDelta adj) {
        return VTSFeeLib._processPositionFees(s, positionId);
    }

    /// @notice Apply the fee-burn pipeline for a position and return the consumed outflow share
    function applyBurnBase(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId,
        PoolId poolId,
        uint8 tokenIndex,
        uint256 burnBase,
        uint128 positionLiquidity,
        uint256 outflowFloor
    ) external returns (uint256 consumedBurnBase) {
        return VTSFeeLib._applyBurnBase(
            s, poolManager, positionId, poolId, tokenIndex, burnBase, positionLiquidity, outflowFloor
        );
    }
}

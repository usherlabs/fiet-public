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
import {VTSFeeStorage, PositionFeeAccounting, PoolFeeAccounting} from "../types/VTSFee.sol";
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
        bool consumeResidualFeeBacking;
    }

    struct FeesBurnResolution {
        uint256 totalFees;
        uint256 bankedFees;
        uint256 ofDelta;
        uint256 snap;
    }

    struct FeesBurnComputation {
        uint256 freshFees;
        uint256 bankedFees;
        uint256 snap;
        uint256 ofDelta;
        uint256 totalFees;
        uint256 bps;
        uint256 consumedBurnBase;
        uint256 consumedTotalFees;
        uint256 feesBurn;
        uint256 consumedBankedFees;
        uint256 consumedFreshFees;
    }

    // --------------------------------------------------
    // Fee Adjustment Helpers
    // --------------------------------------------------

    /// @dev Queue a bonus for a single token using CISE (Coverage-Indexed Settled Exposure).
    /// @notice CISE replaces selfNet as the primary eligibility gate, fixing the commitmentMax clamp bug.
    ///         Positions accrue exposure when incrementCoverage is called, proportional to their settled liquidity.
    ///         CSI remaining-share factors are used for self-exclusion to ensure positions can receive bonuses
    ///         even after their contributed slashes have been distributed to others.
    /// @param pf The position fee accounting storage reference
    /// @param pfPool The pool fee accounting storage reference
    /// @param feeTokenIndex The fee token index (0 or 1) - the pot from which bonus is allocated
    /// @param coverageTokenIndex The coverage token index (opposite of feeTokenIndex) - the token whose exposure is used
    /// @param ciseExposure The position's realised CISE exposure since last allocation (from coverageTokenIndex)
    /// @return allocated True iff a non-zero bonus was queued (i.e. pendingFeeAdj was decreased).
    function _queueBonusForToken(
        PositionFeeAccounting storage pf,
        PoolFeeAccounting storage pfPool,
        uint8 feeTokenIndex,
        uint8 coverageTokenIndex,
        uint256 ciseExposure
    ) internal returns (bool allocated) {
        // CISE: Use exposure as eligibility gate instead of selfNet
        if (ciseExposure == 0) return false;

        // CSI: Sync remaining contribution shares before reading selfRemaining
        _syncFeesSharedRemainingForToken(pf, pfPool, feeTokenIndex);

        // Bonuses are allocated only against the materialised slashed pot (positive `pendingFeeAdj` must be
        // materialised in `_processPositionFees` before this runs).
        uint256 pot = pfPool.slashedPot.get(feeTokenIndex);

        // CSI: feesShared is stored as remaining self-contribution (not lifetime)
        uint256 selfRemaining = pf.feesShared.get(feeTokenIndex);
        uint256 potAvail = pot > selfRemaining ? (pot - selfRemaining) : 0;

        if (potAvail == 0) return false;

        // CISE: Denominator is the pool-wide allocatable coverage window, updated eagerly on `incrementCoverage`
        // and decremented on allocation; not lazily summed from per-touch position realisations. Coverage exercised
        // while `totalSettled == 0` is excluded upstream because no settled liquidity was live to earn that weight.
        uint256 totalExposure = pfPool.totalCISEExposureSinceLastMod.get(coverageTokenIndex);
        if (totalExposure == 0) return false;

        // bonus = potAvail * ciseExposure / totalExposure (round up so dust does not strand eligible exposure)
        uint256 bonus = FullMath.mulDivRoundingUp(potAvail, ciseExposure, totalExposure);
        if (bonus > potAvail) bonus = potAvail;
        if (bonus == 0) return false;

        // CSI: Update the cumulative remaining-share factor for this epoch.
        // Note: Under consistent accounting, total remaining shares == current pot (pre-spend).
        if (pot > 0) _advanceFeesSharedFactor(pfPool, feeTokenIndex, pot, bonus);

        // Queue negative pending (bonus increases payout at materialisation); `slashedPot` is drained when
        // negative `pendingFeeAdj` is materialised in `_finaliseNegativeFeeAdjustment`.
        int256 currentPending = pf.pendingFeeAdj.get(feeTokenIndex);
        pf.pendingFeeAdj.set(feeTokenIndex, currentPending - bonus.toInt256());
        return true;
    }

    /// @dev After bonus allocation, clear/decrement per-position and per-pool CISE windows so future allocations don't double-count.
    function _cleanupAfterAllocationForToken(
        PositionFeeAccounting storage pf,
        PoolFeeAccounting storage pfPool,
        uint8 coverageTokenIndex,
        uint256 ciseExposure
    ) internal {
        if (ciseExposure == 0) return;

        // CISE: Clear position exposure window and decrement pool total
        uint256 curExposure = pfPool.totalCISEExposureSinceLastMod.get(coverageTokenIndex);
        pfPool.totalCISEExposureSinceLastMod
            .set(coverageTokenIndex, ciseExposure > curExposure ? 0 : (curExposure - ciseExposure));
        pf.ciseExposureSinceLastMod.set(coverageTokenIndex, 0);
    }

    // --------------------------------------------------
    // CSI Remaining-Factor Helpers
    // --------------------------------------------------

    /// @dev Sync a position's remaining feesShared (self-contribution still embedded in the pot)
    ///      against the pool remaining-share factor for the current spend epoch.
    /// @notice Must be called BEFORE incrementing feesShared (slash) or reading selfRemaining (bonus)
    function _syncFeesSharedRemainingForToken(
        PositionFeeAccounting storage pf,
        PoolFeeAccounting storage pfPool,
        uint8 tokenIndex
    ) internal {
        uint256 epochNow = _currentFeesSharedEpoch(pfPool, tokenIndex);
        if (epochNow == 0) return;

        uint256 epochLast = pf.feesSharedEpoch.get(tokenIndex);
        uint256 factorNow = pfPool.feesSharedRemainingFactorX128.get(tokenIndex);

        if (epochLast != epochNow) {
            if (pf.feesShared.get(tokenIndex) != 0) {
                pf.feesShared.set(tokenIndex, 0);
            }
            pf.feesSharedEpoch.set(tokenIndex, epochNow);
            pf.feesSharedRemainingFactorLastX128.set(tokenIndex, factorNow);
            return;
        }

        uint256 factorLast = pf.feesSharedRemainingFactorLastX128.get(tokenIndex);
        if (factorNow == factorLast) return;

        uint256 sharesRemaining = pf.feesShared.get(tokenIndex);
        if (sharesRemaining > 0) {
            uint256 updatedShares;
            if (factorLast == 0) {
                // No spend had been realised against this position in the current epoch yet. A zero pool factor is still
                // the identity state until the first bonus allocation stores a non-zero remaining-share factor.
                // Keep remaining shares conservative for tiny balances so self-exclusion does not collapse early.
                updatedShares = factorNow == 0
                    ? sharesRemaining
                    : FullMath.mulDivRoundingUp(sharesRemaining, factorNow, FixedPoint128.Q128);
            } else {
                // Round up so partial spend does not floor tiny remaining self-contribution to zero.
                updatedShares = factorNow == 0 ? 0 : FullMath.mulDivRoundingUp(sharesRemaining, factorNow, factorLast);
            }

            if (updatedShares != sharesRemaining) {
                pf.feesShared.set(tokenIndex, updatedShares);
            }
        }

        pf.feesSharedEpoch.set(tokenIndex, epochNow);
        pf.feesSharedRemainingFactorLastX128.set(tokenIndex, factorNow);
    }

    function _currentFeesSharedEpoch(PoolFeeAccounting storage pfPool, uint8 tokenIndex)
        private
        view
        returns (uint256 epoch)
    {
        epoch = pfPool.feesSharedEpoch.get(tokenIndex);
    }

    function _beginFeesSharedEpochIfNeeded(PoolFeeAccounting storage pfPool, uint8 tokenIndex) internal {
        uint256 epoch = pfPool.feesSharedEpoch.get(tokenIndex);
        if (epoch == 0) {
            pfPool.feesSharedEpoch.set(tokenIndex, 1);
            return;
        }

        uint256 factor = pfPool.feesSharedRemainingFactorX128.get(tokenIndex);
        uint256 materialPot = pfPool.slashedPot.get(tokenIndex);
        if (factor == 0 && materialPot == 0) {
            pfPool.feesSharedEpoch.set(tokenIndex, epoch + 1);
        }
    }

    function _advanceFeesSharedFactor(PoolFeeAccounting storage pfPool, uint8 tokenIndex, uint256 pot, uint256 bonus)
        private
    {
        if (pfPool.feesSharedEpoch.get(tokenIndex) == 0) {
            pfPool.feesSharedEpoch.set(tokenIndex, 1);
        }

        uint256 currentFactor = pfPool.feesSharedRemainingFactorX128.get(tokenIndex);
        uint256 factorBase = currentFactor == 0 ? FixedPoint128.Q128 : currentFactor;
        uint256 nextFactor = FullMath.mulDivRoundingUp(factorBase, pot - bonus, pot);
        pfPool.feesSharedRemainingFactorX128.set(tokenIndex, nextFactor);
    }

    function _prepareFeeShareMint(VTSFeeStorage storage f, PositionId positionId, PoolId poolId, uint8 feeTokenIndex)
        internal
    {
        PositionFeeAccounting storage pf = f.positionFeeAccounting[positionId];
        PoolFeeAccounting storage pfPool = f.poolFeeAccounting[poolId];
        _beginFeesSharedEpochIfNeeded(pfPool, feeTokenIndex);
        _syncFeesSharedRemainingForToken(pf, pfPool, feeTokenIndex);
    }

    /// @notice Calculate fees and checkpoint snapshots for coverage burn
    /// @dev Extracted to keep position-side DICE orchestration small.
    function _calculateFeesBurn(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        IPoolManager poolManager,
        PositionId positionId,
        FeesBurnParams memory params
    ) internal returns (uint256, uint256, uint256, uint256) {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        PositionFeeAccounting storage pf = f.positionFeeAccounting[positionId];
        FeesBurnComputation memory c;

        {
            Position memory pos = s.positions[positionId];
            (uint256 fg0, uint256 fg1) =
                StateLibrary.getFeeGrowthInside(poolManager, params.poolId, pos.tickLower, pos.tickUpper);
            uint256 fg = params.feeTokenIndex == 0 ? fg0 : fg1;

            uint256 lastFeeGrowth = pf.feeGrowthInsideLast.get(params.feeTokenIndex);
            if (params.positionLiquidity > 0 && fg > lastFeeGrowth) {
                c.freshFees = FullMath.mulDiv(fg - lastFeeGrowth, uint256(params.positionLiquidity), FixedPoint128.Q128);
            }
            if (params.consumeResidualFeeBacking) {
                c.bankedFees = pf.pendingResidualFeeBacking.get(params.feeTokenIndex);
            }
        }

        uint256 cumulativeOutflows = pa.cumulativeOutflows.get(params.deficitTokenIndex);
        c.snap = pf.outflowsAtFeeSnap.get(params.deficitTokenIndex);
        if (params.outflowFloor > c.snap) {
            c.snap = params.outflowFloor;
        }
        c.ofDelta = cumulativeOutflows >= c.snap ? (cumulativeOutflows - c.snap) : 0;

        c.totalFees = c.freshFees + c.bankedFees;
        if (c.totalFees == 0 || c.ofDelta == 0) {
            return (0, 0, 0, 0);
        }

        c.bps = s.pools[params.poolId].vtsConfig.coverageFeeShare;
        if (c.bps == 0) {
            return (0, 0, 0, 0);
        }
        if (c.bps > LiquidityUtils.BPS_DENOMINATOR) {
            c.bps = LiquidityUtils.BPS_DENOMINATOR;
        }

        c.consumedBurnBase = params.burnBase <= c.ofDelta ? params.burnBase : c.ofDelta;
        c.consumedTotalFees = FullMath.mulDiv(c.totalFees, c.consumedBurnBase, c.ofDelta);
        c.feesBurn = FullMath.mulDiv(c.consumedTotalFees, c.bps, LiquidityUtils.BPS_DENOMINATOR);
        if (c.feesBurn == 0) {
            return (0, 0, 0, 0);
        }

        c.consumedBankedFees = c.consumedTotalFees <= c.bankedFees ? c.consumedTotalFees : c.bankedFees;
        c.consumedFreshFees = c.consumedTotalFees - c.consumedBankedFees;
        pf.outflowsAtFeeSnap.set(params.deficitTokenIndex, c.snap + c.consumedBurnBase);

        return (c.feesBurn, c.consumedBurnBase, c.consumedFreshFees, c.consumedBankedFees);
    }

    /// @notice Apply a precomputed burn base for a position and return the consumed outflow share
    function _applyBurnBase(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        IPoolManager poolManager,
        PositionId positionId,
        PoolId poolId,
        uint8 tokenIndex,
        uint256 burnBase,
        uint128 positionLiquidity,
        uint256 outflowFloor,
        bool consumeResidualFeeBacking
    ) internal returns (uint256 consumedBurnBase) {
        if (burnBase == 0) return 0;
        FeesBurnParams memory params = FeesBurnParams({
            poolId: poolId,
            deficitTokenIndex: tokenIndex,
            feeTokenIndex: tokenIndex == 0 ? 1 : 0,
            burnBase: burnBase,
            positionLiquidity: positionLiquidity,
            outflowFloor: outflowFloor,
            consumeResidualFeeBacking: consumeResidualFeeBacking
        });
        return _applyBurnBaseWithParams(s, f, poolManager, positionId, params);
    }

    /// @dev Split from `_applyBurnBase` to avoid stack-too-deep under non-IR compilation.
    function _applyBurnBaseWithParams(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        IPoolManager poolManager,
        PositionId positionId,
        FeesBurnParams memory params
    ) private returns (uint256 consumedBurnBase) {
        uint256 feesBurn;
        uint256 consumedFreshFees;
        uint256 consumedBankedFees;
        (feesBurn, consumedBurnBase, consumedFreshFees, consumedBankedFees) =
            _calculateFeesBurn(s, f, poolManager, positionId, params);

        if (feesBurn == 0) return 0;

        _finaliseBurnAccounting(
            f,
            positionId,
            params.poolId,
            params.feeTokenIndex,
            params.positionLiquidity,
            consumedFreshFees,
            consumedBankedFees,
            feesBurn
        );
        return consumedBurnBase;
    }

    function _finaliseBurnAccounting(
        VTSFeeStorage storage f,
        PositionId positionId,
        PoolId poolId,
        uint8 feeTokenIndex,
        uint128 positionLiquidity,
        uint256 consumedFreshFees,
        uint256 consumedBankedFees,
        uint256 feesBurn
    ) private {
        PositionFeeAccounting storage pf = f.positionFeeAccounting[positionId];
        if (consumedBankedFees > 0) {
            uint256 currentBacking = pf.pendingResidualFeeBacking.get(feeTokenIndex);
            pf.pendingResidualFeeBacking
                .set(feeTokenIndex, consumedBankedFees > currentBacking ? 0 : (currentBacking - consumedBankedFees));
        }

        if (positionLiquidity > 0 && consumedFreshFees > 0) {
            uint256 liquidity = uint256(positionLiquidity);
            uint256 carryIn = pf.feeBurnGrowthRemainder.get(feeTokenIndex);
            (uint256 growthInc, uint256 newCarry) =
                LiquidityUtils.feeBurnGrowthIncWithRemainder(consumedFreshFees, liquidity, carryIn);
            pf.feeBurnGrowthRemainder.set(feeTokenIndex, newCarry);
            pf.feeGrowthInsideLast.set(feeTokenIndex, pf.feeGrowthInsideLast.get(feeTokenIndex) + growthInc);
        }

        _prepareFeeShareMint(f, positionId, poolId, feeTokenIndex);
        pf.feesShared.set(feeTokenIndex, pf.feesShared.get(feeTokenIndex) + feesBurn);
        pf.pendingFeeAdj.set(feeTokenIndex, pf.pendingFeeAdj.get(feeTokenIndex) + feesBurn.toInt256());
    }

    // --------------------------------------------------
    // CISE (Coverage-Indexed Settled Exposure) Helpers
    // --------------------------------------------------

    /// @notice Peek the current pending fee adjustments for a position without mutating state
    /// @param f The fee-era storage root
    /// @param positionId The position ID
    /// @return adj0 The pending fee adjustment for token0 (+slash, -bonus)
    /// @return adj1 The pending fee adjustment for token1 (+slash, -bonus)
    function _peekFeeAdjustment(VTSFeeStorage storage f, PositionId positionId)
        internal
        view
        returns (int256 adj0, int256 adj1)
    {
        PositionFeeAccounting storage pf = f.positionFeeAccounting[positionId];
        adj0 = pf.pendingFeeAdj.token0;
        adj1 = pf.pendingFeeAdj.token1;
    }

    /// @notice Increase the slashed pot accounting for a pool/token
    /// @dev Only updates accounting state. Actual ERC6909 mint is handled by CoreHook.settleHookDeltasToPot
    /// @param poolId The pool ID
    /// @param tokenIndex The token index (0 or 1)
    /// @param amount The amount to fund
    function _fundFeePot(VTSFeeStorage storage f, PoolId poolId, uint8 tokenIndex, uint256 amount) internal {
        if (amount == 0) return;
        PoolFeeAccounting storage pfPool = f.poolFeeAccounting[poolId];
        uint256 currentPot = pfPool.slashedPot.get(tokenIndex);
        pfPool.slashedPot.set(tokenIndex, currentPot + amount);
    }

    /// @notice Decrease the slashed pot accounting when settling bonuses
    /// @dev Only updates accounting state. Actual ERC6909 burn is handled by CoreHook.settleHookDeltasToPot
    /// @param poolId The pool ID
    /// @param tokenIndex The token index (0 or 1)
    /// @param amount The amount to drain
    function _drainFeePot(VTSFeeStorage storage f, PoolId poolId, uint8 tokenIndex, uint256 amount) internal {
        if (amount == 0) return;
        PoolFeeAccounting storage pfPool = f.poolFeeAccounting[poolId];
        uint256 pot = pfPool.slashedPot.get(tokenIndex);
        // Clamp to available pot to avoid underflow; caller must have already bounded the amount
        if (amount > pot) amount = pot;
        pfPool.slashedPot.set(tokenIndex, pot - amount);
    }

    /// @notice Materialise positive `pendingFeeAdj` into `slashedPot` up to per-leg caps (SETTLE-03 on decreases).
    function _finalisePositiveFeeAdjustment(
        VTSFeeStorage storage f,
        PositionId positionId,
        PoolId poolId,
        uint256 positiveCap0,
        uint256 positiveCap1
    ) internal returns (BalanceDelta adj) {
        (int256 pend0, int256 pend1) = _peekFeeAdjustment(f, positionId);
        int256 mat0 = 0;
        int256 mat1 = 0;

        if (pend0 > 0) {
            uint256 pendPos0 = uint256(pend0);
            uint256 pay0 = pendPos0 < positiveCap0 ? pendPos0 : positiveCap0;
            if (pay0 > 0) {
                _fundFeePot(f, poolId, 0, pay0);
                mat0 = pay0.toInt256();
            }
        }

        if (pend1 > 0) {
            uint256 pendPos1 = uint256(pend1);
            uint256 pay1 = pendPos1 < positiveCap1 ? pendPos1 : positiveCap1;
            if (pay1 > 0) {
                _fundFeePot(f, poolId, 1, pay1);
                mat1 = pay1.toInt256();
            }
        }

        PositionFeeAccounting storage pf = f.positionFeeAccounting[positionId];
        pf.pendingFeeAdj.token0 = pend0 - mat0;
        pf.pendingFeeAdj.token1 = pend1 - mat1;

        adj = LiquidityUtils.safeToBalanceDelta(mat0, mat1);
    }

    /// @notice Materialise negative `pendingFeeAdj` by draining `slashedPot` (bonuses queued after positive phase).
    function _finaliseNegativeFeeAdjustment(VTSFeeStorage storage f, PositionId positionId, PoolId poolId)
        internal
        returns (BalanceDelta adj)
    {
        (int256 pend0, int256 pend1) = _peekFeeAdjustment(f, positionId);
        int256 mat0 = 0;
        int256 mat1 = 0;

        if (pend0 < 0) {
            uint256 need0 = uint256(-pend0);
            PoolFeeAccounting storage pfPool = f.poolFeeAccounting[poolId];
            uint256 pot0 = pfPool.slashedPot.token0;
            uint256 pay0 = pot0 < need0 ? pot0 : need0;
            if (pay0 > 0) {
                _drainFeePot(f, poolId, 0, pay0);
                mat0 = -pay0.toInt256();
            }
        }

        if (pend1 < 0) {
            uint256 need1 = uint256(-pend1);
            PoolFeeAccounting storage pfPool = f.poolFeeAccounting[poolId];
            uint256 pot1 = pfPool.slashedPot.token1;
            uint256 pay1 = pot1 < need1 ? pot1 : need1;
            if (pay1 > 0) {
                _drainFeePot(f, poolId, 1, pay1);
                mat1 = -pay1.toInt256();
            }
        }

        PositionFeeAccounting storage pf = f.positionFeeAccounting[positionId];
        pf.pendingFeeAdj.token0 = pend0 - mat0;
        pf.pendingFeeAdj.token1 = pend1 - mat1;

        adj = LiquidityUtils.safeToBalanceDelta(mat0, mat1);
    }

    /// @notice Finalise pending fee adjustments with optional per-leg caps on positive slash materialisation
    /// @dev Positive pending adjustment (`pend > 0`) is materialised at most up to `positiveCap*` for each leg.
    ///      Any unmaterialised remainder stays queued in `pendingFeeAdj` for future touches.
    ///      Negative pending (`pend < 0`) bonus materialisation drains `slashedPot`.
    /// @dev Updates accounting state only. Actual ERC6909 mint/burn is handled by CoreHook.settleHookDeltasToPot.
    ///      Positive pending (`pend > 0`) materialises at most `positiveCap*` per leg; pass `type(uint256).max` on both
    ///      legs for uncapped behaviour. Any unmaterialised positive remainder stays in `pendingFeeAdj`.
    /// @dev Not used on the production fee-sharing path: `_processPositionFees` runs Phase 2 (bonus allocation)
    ///      between `_finalisePositiveFeeAdjustment` and `_finaliseNegativeFeeAdjustment`. Exposed for
    ///      `VTSFeeLibHarness` / unit tests that exercise positive+negative materialisation without Phase 2.
    /// @param f The fee-era storage root
    /// @param positionId The position ID
    /// @param poolId The pool ID
    /// @return adj The materialised delta as BalanceDelta for the hook to apply this call only
    //#olympix-ignore-reentrancy
    function _finaliseFeeAdjustment(
        VTSFeeStorage storage f,
        PositionId positionId,
        PoolId poolId,
        uint256 positiveCap0,
        uint256 positiveCap1
    ) internal returns (BalanceDelta adj) {
        BalanceDelta adjPos = _finalisePositiveFeeAdjustment(f, positionId, poolId, positiveCap0, positiveCap1);
        BalanceDelta adjNeg = _finaliseNegativeFeeAdjustment(f, positionId, poolId);
        return adjPos + adjNeg;
    }

    /// @notice Uncapped finalisation (`positiveCap* = max`).
    function _finaliseFeeAdjustment(VTSFeeStorage storage f, PositionId positionId, PoolId poolId)
        internal
        returns (BalanceDelta adj)
    {
        return _finaliseFeeAdjustment(f, positionId, poolId, type(uint256).max, type(uint256).max);
    }

    /// @notice Consolidated fee processing for a position during modification (three phases)
    /// @dev Phase 1: materialise positive `pendingFeeAdj` into `slashedPot` (capped per leg on decreases).
    ///      Phase 2: allocate bonuses from the materialised pot via CISE/CSI (queues negative pending).
    ///      Phase 3: materialise negative pending by draining `slashedPot`.
    ///      Updates accounting state only. Actual ERC6909 mint/burn is handled by CoreHook.settleHookDeltasToPot.
    ///      Pass `type(uint256).max` for both caps for uncapped positive slash materialisation.
    /// @param s The central VTS storage
    /// @param positionId The position ID
    /// @return adj The materialised fee adjustment delta
    function _processPositionFees(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        PositionId positionId,
        uint256 positiveCap0,
        uint256 positiveCap1
    ) internal returns (BalanceDelta adj) {
        Position memory pos = s.positions[positionId];
        PoolId poolId = pos.poolId;

        // If fee sharing is disabled, skip processing (fees handled natively by Uniswap)
        if (!_isFeeSharingEnabled(s, poolId)) {
            return toBalanceDelta(0, 0);
        }

        PositionFeeAccounting storage pf = f.positionFeeAccounting[positionId];
        PoolFeeAccounting storage pfPool = f.poolFeeAccounting[poolId];

        // Phase 1 — fund `slashedPot` from positive pending before bonus allocation.
        BalanceDelta adjPos = _finalisePositiveFeeAdjustment(f, positionId, poolId, positiveCap0, positiveCap1);

        // Read CISE exposure for bonus allocation
        // Note: Raw exposure values per coverage token
        uint256 ciseExposure0 = pf.ciseExposureSinceLastMod.token0;
        uint256 ciseExposure1 = pf.ciseExposureSinceLastMod.token1;

        // Phase 2 — queue bonuses using CISE exposure (coverage-indexed settled exposure)
        // Token direction mapping: fee pot in token T is funded by deficits in the opposite token.
        // - token0 pot ← token1 deficit coverage → use token1 exposure for token0 bonus
        // - token1 pot ← token0 deficit coverage → use token0 exposure for token1 bonus
        // This fixes the commitmentMax clamp bug where selfNet stays 0 for fully-settled positions
        bool allocated0 = _queueBonusForToken(pf, pfPool, 0, 1, ciseExposure1);
        bool allocated1 = _queueBonusForToken(pf, pfPool, 1, 0, ciseExposure0);

        // Banked exposure:
        // Only clear/decrement the windows if we actually queued a bonus for that token.
        // This ensures contributions remain eligible if potAvail was 0 at touch time.
        if (allocated0) _cleanupAfterAllocationForToken(pf, pfPool, 1, ciseExposure1);
        if (allocated1) _cleanupAfterAllocationForToken(pf, pfPool, 0, ciseExposure0);

        // Phase 3 — drain `slashedPot` for queued bonuses (and any other negative pending).
        BalanceDelta adjNeg = _finaliseNegativeFeeAdjustment(f, positionId, poolId);
        return adjPos + adjNeg;
    }

    /// @notice Uncapped fee processing (`positiveCap* = max`).
    function _processPositionFees(VTSStorage storage s, VTSFeeStorage storage f, PositionId positionId)
        internal
        returns (BalanceDelta adj)
    {
        return _processPositionFees(s, f, positionId, type(uint256).max, type(uint256).max);
    }

    /// @dev Check if fee sharing is enabled for a pool
    function _isFeeSharingEnabled(VTSStorage storage s, PoolId p) internal view returns (bool) {
        return s.pools[p].vtsConfig.coverageFeeShare > 0;
    }

    // --------------------------------------------------
    // DICE (deficit-indexed coverage exercise) — position settlement
    //
    // In practice: pool commits move coverage indices; each `settlePositionGrowths` touch reconciles the position
    // against those indices, turns the implied coverage into a fee-slash obligation, and runs it through the same
    // delayed burn path as historical “residual” DICE — bank in `pendingResidualBurnBase`, then try `_applyBurnBase`.
    // Ordinary and residual index legs both bank here; naming on pending fields is legacy for layout compatibility.
    // (Linked from `VTSPositionLib.settlePositionGrowths`, before inflow nets deficit principal.)
    // --------------------------------------------------

    /// @dev Fee backing is episode-scoped: once the matching banked DICE burn base is exhausted,
    ///      any leftover backing on the opposite fee lane must not survive into a later episode.
    function _clearResolvedResidualFeeBacking(PositionFeeAccounting storage pf, uint8 deficitTokenIndex) internal {
        if (pf.pendingResidualBurnBase.get(deficitTokenIndex) != 0) return;

        uint8 feeTokenIndex = deficitTokenIndex == 0 ? 1 : 0;
        pf.pendingResidualFeeBacking.set(feeTokenIndex, 0);
    }

    /// @notice Chained floor realisation for `deficitPrincipal * deltaIndex / Q128`.
    /// @dev In practice: many small index moves across separate settles must assign the same total raw coverage as one
    ///      big move. Without `carryIn`/`carryOut`, independent `floor` per touch loses dust to rounding; this matches
    ///      the fee-burn remainder story (COV-04 / INVARIANTS COV-05).
    function _realisedCoverageWithCarry(uint256 deficitPrincipal, uint256 deltaIndex, uint256 carryIn)
        private
        pure
        returns (uint256 covOut, uint256 carryOut)
    {
        if (deltaIndex == 0 || deficitPrincipal == 0) {
            return (0, carryIn);
        }
        uint256 q = FullMath.mulDiv(deficitPrincipal, deltaIndex, FixedPoint128.Q128);
        uint256 r = mulmod(deficitPrincipal, deltaIndex, FixedPoint128.Q128);
        unchecked {
            uint256 sum = r + carryIn;
            covOut = q + sum / FixedPoint128.Q128;
            carryOut = sum % FixedPoint128.Q128;
        }
    }

    /// @dev Same clamp as `_applyCoverageBurn`: burn base is min(min(cov, d+settled), d).
    function _effectiveDiceBurnBase(PositionAccounting storage pa, uint8 tokenIndex, uint256 cov)
        private
        view
        returns (uint256 burnBase)
    {
        uint256 d = pa.cumulativeDeficit.get(tokenIndex);
        uint256 settled = pa.settled.get(tokenIndex);
        if (d == 0 && settled == 0) return 0;
        uint256 cEff = cov <= (d + settled) ? cov : (d + settled);
        if (d == 0) return 0;
        burnBase = cEff < d ? cEff : d;
    }

    /// @dev In practice: each touch only adds incremental coverage `incremCov`, but the slash is capped by current
    ///      deficit (and settled) via `_effectiveDiceBurnBase`. Naively banking `min(incremCov, D)` every touch can
    ///      over-bank when many touches sum to more assigned coverage than `D` allows; we therefore track cumulative
    ///      assigned coverage in `dice*CovAgg` and bank only `f(newAgg) - f(oldAgg)` where `f` is that clamp.
    function _bankDiceBurnFromCovWaterfall(
        PositionAccounting storage pa,
        PositionFeeAccounting storage pf,
        uint8 tokenIndex,
        uint256 incremCov,
        bool residualLeg
    ) private returns (uint256 burnDelta) {
        if (incremCov == 0) return 0;
        TokenPairUint storage aggSlot = residualLeg ? pf.diceResidualCovAgg : pf.diceOrdinaryCovAgg;
        uint256 oldAgg = aggSlot.get(tokenIndex);
        uint256 newAgg = oldAgg + incremCov;
        aggSlot.set(tokenIndex, newAgg);
        uint256 burnOld = _effectiveDiceBurnBase(pa, tokenIndex, oldAgg);
        uint256 burnNew = _effectiveDiceBurnBase(pa, tokenIndex, newAgg);
        if (burnNew <= burnOld) return 0;
        unchecked {
            return burnNew - burnOld;
        }
    }

    /// @dev Append to shared banked DICE burn and optionally refresh the outflow watermark.
    /// @param useCumulativeOutflowsFloor If true (residual-index realisation), raise floor toward `cumulativeOutflows`
    ///        so burn consumes only on **new** outflows after the event. If false (ordinary index realisation), align
    ///        floor with `outflowsAtFeeSnap` so the same window as immediate `_applyCoverageBurn` remains eligible.
    ///      In practice: residual-backed banks behave like “only after fresh outflows”; ordinary-backed banks behave
    ///      like the legacy immediate path’s outflow snapshot, and overwrite the floor so a residual high-water mark
    ///      cannot strand ordinary burn in the same pass.
    function _bankPendingDiceBurn(
        PositionAccounting storage pa,
        PositionFeeAccounting storage pf,
        uint8 tokenIndex,
        uint256 burnBase,
        bool useCumulativeOutflowsFloor
    ) private {
        if (burnBase == 0) return;
        pf.pendingResidualBurnBase.set(tokenIndex, pf.pendingResidualBurnBase.get(tokenIndex) + burnBase);

        uint256 existingFloor = pf.pendingResidualBurnOutflowsFloor.get(tokenIndex);
        if (useCumulativeOutflowsFloor) {
            uint256 curOutflows = pa.cumulativeOutflows.get(tokenIndex);
            if (curOutflows > existingFloor) {
                pf.pendingResidualBurnOutflowsFloor.set(tokenIndex, curOutflows);
            }
        } else {
            // Ordinary-index realisation: align with `outflowsAtFeeSnap` (same as immediate `_applyCoverageBurn` with
            // `outflowFloor == 0`). Overwrite any residual-only cumulative watermark so mixed residual+ordinary banks
            // in the same `_settleDICEForToken` pass remain consumable on the current outflow window.
            uint256 snapNow = pf.outflowsAtFeeSnap.get(tokenIndex);
            pf.pendingResidualBurnOutflowsFloor.set(tokenIndex, snapNow);
        }
    }

    /// @dev Shared residual-backing capture: banks `liquidityScale * (fg - feeGrowthInsideLast)` per fee lane when
    ///      `pendingResidualBurnBase` implies that lane. Uses `getPositionInfo` fee growth (position snapshot after
    ///      modifyLiquidity), which stays authoritative after full removes that clear ticks.
    /// @param advanceFeeGrowthCheckpoint If true (full deactivation), set `feeGrowthInsideLast` to `fg` whenever
    ///        `fg > last`. If false (partial decrease), leave `feeGrowthInsideLast` unchanged for surviving liquidity.
    function _accumulateResidualFeeBackingForLanes(
        PositionFeeAccounting storage pf,
        uint256 fg0,
        uint256 fg1,
        bool needFeeToken0,
        bool needFeeToken1,
        uint256 liquidityScale,
        bool advanceFeeGrowthCheckpoint
    ) private {
        if (needFeeToken0) {
            uint256 last0 = pf.feeGrowthInsideLast.token0;
            if (fg0 > last0) {
                uint256 backing0 = FullMath.mulDiv(fg0 - last0, liquidityScale, FixedPoint128.Q128);
                if (backing0 > 0) pf.pendingResidualFeeBacking.token0 += backing0;
                if (advanceFeeGrowthCheckpoint) pf.feeGrowthInsideLast.token0 = fg0;
            }
        }

        if (needFeeToken1) {
            uint256 last1 = pf.feeGrowthInsideLast.token1;
            if (fg1 > last1) {
                uint256 backing1 = FullMath.mulDiv(fg1 - last1, liquidityScale, FixedPoint128.Q128);
                if (backing1 > 0) pf.pendingResidualFeeBacking.token1 += backing1;
                if (advanceFeeGrowthCheckpoint) pf.feeGrowthInsideLast.token1 = fg1;
            }
        }
    }

    /// @dev Loads pending-residual lanes, reads post-modify position fee growth from PoolManager, then banks backing.
    ///      Prefer `getPositionInfo` over range `getFeeGrowthInside` on full deactivation: after a full remove, Uniswap
    ///      may clear boundary ticks so range-based reads can be wrong; the position snapshot from `modifyLiquidity` is authoritative.
    function _captureResidualFeeBackingForLiquidityScale(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        IPoolManager poolManager,
        PositionId id,
        uint128 liquidityScale,
        bool advanceFeeGrowthCheckpoint
    ) private {
        if (liquidityScale == 0) return;

        PositionFeeAccounting storage pf = f.positionFeeAccounting[id];
        bool needFeeToken0 = pf.pendingResidualBurnBase.token1 > 0;
        bool needFeeToken1 = pf.pendingResidualBurnBase.token0 > 0;
        if (!needFeeToken0 && !needFeeToken1) return;

        Position memory pos = s.positions[id];
        (, uint256 fg0, uint256 fg1) = StateLibrary.getPositionInfo(poolManager, pos.poolId, PositionId.unwrap(id));

        _accumulateResidualFeeBackingForLanes(
            pf, fg0, fg1, needFeeToken0, needFeeToken1, uint256(liquidityScale), advanceFeeGrowthCheckpoint
        );
    }

    /// @notice Freeze unresolved residual-burn fee backing before a position deactivates to zero liquidity.
    /// @dev Captures fee growth accrued up to the remove call on the fee token lanes needed by pending residual burn.
    function _captureResidualFeeBackingOnDeactivation(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        IPoolManager poolManager,
        PositionId id,
        uint128 liquidityBeforeRemove
    ) internal {
        _captureResidualFeeBackingForLiquidityScale(s, f, poolManager, id, liquidityBeforeRemove, true);
    }

    /// @notice Bank fee-token backing for removed liquidity during a partial decrease while a residual episode is open.
    /// @dev Unlike full deactivation, does not advance `feeGrowthInsideLast`: remaining live liquidity keeps the same
    ///      baseline so `freshFees` on later burns still include its share of growth since the last checkpoint.
    function _captureResidualFeeBackingOnPartialDecrease(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        IPoolManager poolManager,
        PositionId id,
        uint128 removedLiquidity
    ) internal {
        _captureResidualFeeBackingForLiquidityScale(s, f, poolManager, id, removedLiquidity, false);
    }

    /// @notice Apply banked DICE burn (ordinary + residual realisation) against eligible fee/outflow windows.
    /// @dev In practice: whatever is sitting in `pendingResidualBurnBase` (from either index leg) is fed to
    ///      `_applyBurnBase` once per token per settle. If fees/outflows are insufficient, nothing is consumed and the
    ///      obligation stays pending for a later touch; fee-backing hooks still treat this as one “episode”.
    function _applyBankedResidualBurn(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        IPoolManager poolManager,
        PositionId id,
        PoolId p,
        uint8 tokenIndex,
        uint128 positionLiquidity
    ) internal {
        PositionFeeAccounting storage pf = f.positionFeeAccounting[id];
        uint256 pendingBurnBase = pf.pendingResidualBurnBase.get(tokenIndex);
        if (pendingBurnBase == 0) return;

        uint256 outflowFloor = pf.pendingResidualBurnOutflowsFloor.get(tokenIndex);
        uint256 consumedBurnBase = _applyBurnBase(
            s, f, poolManager, id, p, tokenIndex, pendingBurnBase, positionLiquidity, outflowFloor, true
        );
        if (consumedBurnBase > 0) {
            pf.pendingResidualBurnBase.set(tokenIndex, pendingBurnBase - consumedBurnBase);
            if (pendingBurnBase == consumedBurnBase) {
                pf.pendingResidualBurnOutflowsFloor.set(tokenIndex, 0);
                _clearResolvedResidualFeeBacking(pf, tokenIndex);
            }
        }
    }

    // --------------------------------------------------
    // DICE / CISE coverage settlement (linked from VTSPositionLib.settlePositionGrowths)
    // --------------------------------------------------

    /// @notice Flush any pending deficit-indexed coverage residual into the DICE index
    function _flushCoverageResidualIfNeeded(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        PoolId poolId,
        uint8 tokenIndex
    ) internal {
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        PoolFeeAccounting storage pfPool = f.poolFeeAccounting[poolId];
        uint256 residual = pfPool.coverageResidualDICE.get(tokenIndex);
        uint256 principal = paPool.totalDeficitPrincipal.get(tokenIndex);

        if (residual > 0 && principal > 0) {
            uint256 deltaIndex = FullMath.mulDiv(residual, FixedPoint128.Q128, principal);
            uint256 currentIndex = pfPool.coveragePerResidualDeficitIndexX128.get(tokenIndex);
            pfPool.coveragePerResidualDeficitIndexX128.set(tokenIndex, currentIndex + deltaIndex);
            pfPool.coverageResidualDICE.set(tokenIndex, 0);
        }
    }

    function _settleCISEForToken(
        PositionAccounting storage pa,
        PoolFeeAccounting storage pfPool,
        PositionFeeAccounting storage pf,
        uint8 tokenIndex
    ) internal {
        uint256 indexNow = pfPool.coveragePerSettledIndexX128.get(tokenIndex);
        uint256 indexLast = pf.ciseIndexLastX128.get(tokenIndex);

        if (indexNow != indexLast) {
            pf.ciseIndexLastX128.set(tokenIndex, indexNow);
        }

        uint256 deltaIndex = indexNow - indexLast;
        if (deltaIndex > 0) {
            uint256 settled = pa.settled.get(tokenIndex);
            uint256 exposure = FullMath.mulDiv(settled, deltaIndex, FixedPoint128.Q128);
            if (exposure > 0) {
                pf.ciseExposureSinceLastMod.set(tokenIndex, pf.ciseExposureSinceLastMod.get(tokenIndex) + exposure);
            }
        }
    }

    /// @notice Reconcile one deficit-token lane for DICE: realise pool index deltas, bank slash obligation, consume.
    /// @dev Order is fixed: (1) residual-only pool index into shared pending, (2) ordinary per-deficit index into the
    ///      same pending, (3) one consumption attempt. In practice this means value is not dropped when the burn
    ///      cannot run on this touch (`feesBurn == 0` / outflow gating); it waits in `pendingResidualBurnBase` like
    ///      pre-existing residual DICE behaviour.
    function _settleDICEForToken(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        IPoolManager poolManager,
        PositionId positionId,
        PoolId poolId,
        uint8 tokenIndex,
        uint128 liq
    ) internal {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        PositionFeeAccounting storage pf = f.positionFeeAccounting[positionId];
        PoolFeeAccounting storage pfPool = f.poolFeeAccounting[poolId];
        uint256 deficitPrincipal = pa.cumulativeDeficit.get(tokenIndex);

        _clearResolvedResidualFeeBacking(pf, tokenIndex);

        // Residual-index leg (pool had no deficit principal when coverage landed; later socialised via residual index).
        {
            uint256 residualIndexNow = pfPool.coveragePerResidualDeficitIndexX128.get(tokenIndex);
            uint256 residualIndexLast = pf.residualCoverageIndexLastX128.get(tokenIndex);

            if (residualIndexNow != residualIndexLast) {
                pf.residualCoverageIndexLastX128.set(tokenIndex, residualIndexNow);
            }

            uint256 deltaResidualIndex = residualIndexNow - residualIndexLast;
            if (deltaResidualIndex > 0 && deficitPrincipal > 0) {
                uint256 carryResIn = pf.diceResidualRealisationCarry.get(tokenIndex);
                (uint256 residualCov, uint256 carryResOut) =
                    _realisedCoverageWithCarry(deficitPrincipal, deltaResidualIndex, carryResIn);
                pf.diceResidualRealisationCarry.set(tokenIndex, carryResOut);

                if (residualCov > 0) {
                    uint256 burnDelta = _bankDiceBurnFromCovWaterfall(pa, pf, tokenIndex, residualCov, true);
                    _bankPendingDiceBurn(pa, pf, tokenIndex, burnDelta, true);
                }
            }
        }

        // Ordinary per-deficit-index leg (principal existed when pool bumped `coveragePerDeficitIndexX128`).
        {
            uint256 indexNow = pfPool.coveragePerDeficitIndexX128.get(tokenIndex);
            uint256 indexLast = pf.coverageIndexLastX128.get(tokenIndex);

            if (indexNow != indexLast) {
                pf.coverageIndexLastX128.set(tokenIndex, indexNow);
            }

            uint256 deltaIndex = indexNow - indexLast;
            if (deltaIndex > 0 && deficitPrincipal > 0) {
                uint256 carryOrdIn = pf.diceOrdinaryRealisationCarry.get(tokenIndex);
                (uint256 cov, uint256 carryOrdOut) =
                    _realisedCoverageWithCarry(deficitPrincipal, deltaIndex, carryOrdIn);
                pf.diceOrdinaryRealisationCarry.set(tokenIndex, carryOrdOut);

                if (cov > 0) {
                    uint256 burnDelta = _bankDiceBurnFromCovWaterfall(pa, pf, tokenIndex, cov, false);
                    _bankPendingDiceBurn(pa, pf, tokenIndex, burnDelta, false);
                }
            }
        }

        // Single consumption pass for whatever accumulated on this lane (ordinary + residual banks are additive).
        _applyBankedResidualBurn(s, f, poolManager, positionId, poolId, tokenIndex, liq);
    }

    function _settleDeficitIndexedCoverageUsage(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        IPoolManager poolManager,
        PositionId positionId
    ) internal {
        Position memory pos = s.positions[positionId];
        PoolId poolId = pos.poolId;
        uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));

        _settleDICEForToken(s, f, poolManager, positionId, poolId, 0, liq);
        _settleDICEForToken(s, f, poolManager, positionId, poolId, 1, liq);
    }

    function _settleSettledIndexedCoverageUsage(VTSStorage storage s, VTSFeeStorage storage f, PositionId positionId)
        internal
    {
        Position memory pos = s.positions[positionId];
        PoolId poolId = pos.poolId;

        PositionAccounting storage pa = s.positionAccounting[positionId];
        PoolFeeAccounting storage pfPool = f.poolFeeAccounting[poolId];
        PositionFeeAccounting storage pf = f.positionFeeAccounting[positionId];

        _settleCISEForToken(pa, pfPool, pf, 0);
        _settleCISEForToken(pa, pfPool, pf, 1);
    }

    /// @notice Apply coverage burn for a position (deficit-indexed coverage exercise → fee share)
    /// @dev Fees accrue on the input token, not the deficit token.
    function _applyCoverageBurn(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        IPoolManager poolManager,
        PositionId id,
        PoolId p,
        uint8 tokenIndex,
        uint256 cov,
        uint128 positionLiquidity
    ) internal {
        PositionAccounting storage pa = s.positionAccounting[id];

        uint256 burnBase;
        {
            uint256 d = pa.cumulativeDeficit.get(tokenIndex);
            uint256 settled = pa.settled.get(tokenIndex);
            if (d == 0 && settled == 0) return;

            uint256 cEff = cov <= (d + settled) ? cov : (d + settled);
            if (d == 0) return;
            burnBase = cEff < d ? cEff : d;

            if (burnBase == 0) return;
        }

        _applyBurnBase(s, f, poolManager, id, p, tokenIndex, burnBase, positionLiquidity, 0, false);
    }
}

/// @title VTSFeeLinkedLib
/// @notice Library for VTS fee processing
/// @dev Operates on `VTSStorage` and fee-owned `VTSFeeStorage` via storage pointers (`VTSOrchestrator` holds both).
library VTSFeeLinkedLib {
    /// @notice Returns true when the fee-sharing / coverage-fee capability is enabled for a pool.
    /// @dev Phase 1 quarantine: `coverageFeeShare == 0` is the base market line; DICE/CISE/fee-adjustment paths are skipped.
    function isFeeCapabilityEnabled(VTSStorage storage s, PoolId poolId) external view returns (bool enabled) {
        return s.pools[poolId].vtsConfig.coverageFeeShare > 0;
    }

    /// @notice Prepares CSI state before minting fresh fee-share contributions for a position
    /// @dev Advances the spend epoch if needed, then syncs the position's remaining self-share
    ///      against the current pool factor before the caller increases `pendingFeeAdj` / `feesShared`.
    /// @param f The fee-era storage root
    /// @param positionId The position receiving the minted contribution
    /// @param poolId The pool ID
    /// @param feeTokenIndex The fee token index receiving the newly minted contribution
    function beforeFeeShareMint(VTSFeeStorage storage f, PositionId positionId, PoolId poolId, uint8 feeTokenIndex)
        external
    {
        VTSFeeLib._prepareFeeShareMint(f, positionId, poolId, feeTokenIndex);
    }

    /// @notice Processes the fees for a position after touch
    /// @dev Updates accounting state only. Actual ERC6909 mint/burn is handled by CoreHook.settleHookDeltasToPot
    /// @param s The VTS storage
    /// @param f The fee-era storage root
    /// @param positionId The position ID
    /// @return adj The materialised fee adjustment delta
    function afterTouchPosition(VTSStorage storage s, VTSFeeStorage storage f, PositionId positionId)
        external
        returns (BalanceDelta adj)
    {
        return VTSFeeLib._processPositionFees(s, f, positionId);
    }

    /// @notice Processes position fees after touch with optional per-leg caps on positive slash materialisation.
    /// @dev Positive caps limit only the current-touch materialisation (`feeAdj`) for `pendingFeeAdj > 0`. Any excess
    ///      remains queued in `pendingFeeAdj`.
    function afterTouchPositionWithPositiveCaps(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        PositionId positionId,
        uint256 positiveCap0,
        uint256 positiveCap1
    ) external returns (BalanceDelta adj) {
        return VTSFeeLib._processPositionFees(s, f, positionId, positiveCap0, positiveCap1);
    }

    /// @notice Apply the fee-burn pipeline for a position and return the consumed outflow share
    function applyBurnBase(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        IPoolManager poolManager,
        PositionId positionId,
        PoolId poolId,
        uint8 tokenIndex,
        uint256 burnBase,
        uint128 positionLiquidity,
        uint256 outflowFloor,
        bool consumeResidualFeeBacking
    ) external returns (uint256 consumedBurnBase) {
        return VTSFeeLib._applyBurnBase(
            s,
            f,
            poolManager,
            positionId,
            poolId,
            tokenIndex,
            burnBase,
            positionLiquidity,
            outflowFloor,
            consumeResidualFeeBacking
        );
    }

    /// @notice Episode-scoped cleanup when pending residual burn base is zero (DICE settle path)
    function clearResolvedResidualFeeBacking(VTSFeeStorage storage f, PositionId positionId, uint8 deficitTokenIndex)
        external
    {
        VTSFeeLib._clearResolvedResidualFeeBacking(f.positionFeeAccounting[positionId], deficitTokenIndex);
    }

    /// @notice Freeze unresolved residual-burn fee backing before deactivation to zero liquidity
    function captureResidualFeeBackingOnDeactivation(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        IPoolManager poolManager,
        PositionId id,
        uint128 liquidityBeforeRemove
    ) external {
        VTSFeeLib._captureResidualFeeBackingOnDeactivation(s, f, poolManager, id, liquidityBeforeRemove);
    }

    /// @notice Bank historical fee backing for the removed liquidity slice on partial decrease (residual episode open)
    function captureResidualFeeBackingOnPartialDecrease(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        IPoolManager poolManager,
        PositionId id,
        uint128 removedLiquidity
    ) external {
        VTSFeeLib._captureResidualFeeBackingOnPartialDecrease(s, f, poolManager, id, removedLiquidity);
    }

    /// @notice Apply banked DICE burn (ordinary + residual realisation) against eligible outflow windows
    function applyBankedResidualBurn(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        IPoolManager poolManager,
        PositionId id,
        PoolId p,
        uint8 tokenIndex,
        uint128 positionLiquidity
    ) external {
        VTSFeeLib._applyBankedResidualBurn(s, f, poolManager, id, p, tokenIndex, positionLiquidity);
    }

    /// @notice Apply coverage burn from deficit-indexed coverage exercise
    function applyCoverageBurn(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        IPoolManager poolManager,
        PositionId id,
        PoolId p,
        uint8 tokenIndex,
        uint256 cov,
        uint128 positionLiquidity
    ) external {
        VTSFeeLib._applyCoverageBurn(s, f, poolManager, id, p, tokenIndex, cov, positionLiquidity);
    }

    /// @notice Flush pending deficit-indexed coverage residual into the DICE index when principal becomes non-zero
    function flushCoverageResidualIfNeeded(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        PoolId poolId,
        uint8 tokenIndex
    ) external {
        VTSFeeLib._flushCoverageResidualIfNeeded(s, f, poolId, tokenIndex);
    }

    /// @notice Settle settled-indexed coverage usage (CISE) for both tokens
    function settleSettledIndexedCoverageUsage(VTSStorage storage s, VTSFeeStorage storage f, PositionId positionId)
        external
    {
        VTSFeeLib._settleSettledIndexedCoverageUsage(s, f, positionId);
    }

    /// @notice Settle deficit-indexed coverage usage (DICE) for both tokens
    function settleDeficitIndexedCoverageUsage(
        VTSStorage storage s,
        VTSFeeStorage storage f,
        IPoolManager poolManager,
        PositionId positionId
    ) external {
        VTSFeeLib._settleDeficitIndexedCoverageUsage(s, f, poolManager, positionId);
    }
}

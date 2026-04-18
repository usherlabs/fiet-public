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

        // Bonuses are allocated only against the materialised slashed pot (positive `pendingFeeAdj` must be
        // materialised in `_processPositionFees` before this runs).
        uint256 pot = paPool.slashedPot.get(feeTokenIndex);

        // CSI: feesShared is stored as remaining self-contribution (not lifetime)
        uint256 selfRemaining = pa.feesShared.get(feeTokenIndex);
        uint256 potAvail = pot > selfRemaining ? (pot - selfRemaining) : 0;

        if (potAvail == 0) return false;

        // CISE: Denominator is the pool-wide allocatable coverage window, updated eagerly on `incrementCoverage`
        // and decremented on allocation; not lazily summed from per-touch position realisations. Coverage exercised
        // while `totalSettled == 0` is excluded upstream because no settled liquidity was live to earn that weight.
        uint256 totalExposure = paPool.totalCISEExposureSinceLastMod.get(coverageTokenIndex);
        if (totalExposure == 0) return false;

        // bonus = potAvail * ciseExposure / totalExposure (round up so dust does not strand eligible exposure)
        uint256 bonus = FullMath.mulDivRoundingUp(potAvail, ciseExposure, totalExposure);
        if (bonus > potAvail) bonus = potAvail;
        if (bonus == 0) return false;

        // CSI: Update the cumulative remaining-share factor for this epoch.
        // Note: Under consistent accounting, total remaining shares == current pot (pre-spend).
        if (pot > 0) _advanceFeesSharedFactor(paPool, feeTokenIndex, pot, bonus);

        // Queue negative pending (bonus increases payout at materialisation); `slashedPot` is drained when
        // negative `pendingFeeAdj` is materialised in `_finaliseNegativeFeeAdjustment`.
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
    // CSI Remaining-Factor Helpers
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
        uint256 factorNow = paPool.feesSharedRemainingFactorX128.get(tokenIndex);

        if (epochLast != epochNow) {
            if (pa.feesShared.get(tokenIndex) != 0) {
                pa.feesShared.set(tokenIndex, 0);
            }
            pa.feesSharedEpoch.set(tokenIndex, epochNow);
            pa.feesSharedRemainingFactorLastX128.set(tokenIndex, factorNow);
            return;
        }

        uint256 factorLast = pa.feesSharedRemainingFactorLastX128.get(tokenIndex);
        if (factorNow == factorLast) return;

        uint256 sharesRemaining = pa.feesShared.get(tokenIndex);
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
                pa.feesShared.set(tokenIndex, updatedShares);
            }
        }

        pa.feesSharedEpoch.set(tokenIndex, epochNow);
        pa.feesSharedRemainingFactorLastX128.set(tokenIndex, factorNow);
    }

    function _currentFeesSharedEpoch(PoolAccounting storage paPool, uint8 tokenIndex)
        private
        view
        returns (uint256 epoch)
    {
        epoch = paPool.feesSharedEpoch.get(tokenIndex);
    }

    function _beginFeesSharedEpochIfNeeded(PoolAccounting storage paPool, uint8 tokenIndex) internal {
        uint256 epoch = paPool.feesSharedEpoch.get(tokenIndex);
        if (epoch == 0) {
            paPool.feesSharedEpoch.set(tokenIndex, 1);
            return;
        }

        uint256 factor = paPool.feesSharedRemainingFactorX128.get(tokenIndex);
        uint256 materialPot = paPool.slashedPot.get(tokenIndex);
        if (factor == 0 && materialPot == 0) {
            paPool.feesSharedEpoch.set(tokenIndex, epoch + 1);
        }
    }

    function _advanceFeesSharedFactor(PoolAccounting storage paPool, uint8 tokenIndex, uint256 pot, uint256 bonus)
        private
    {
        if (paPool.feesSharedEpoch.get(tokenIndex) == 0) {
            paPool.feesSharedEpoch.set(tokenIndex, 1);
        }

        uint256 currentFactor = paPool.feesSharedRemainingFactorX128.get(tokenIndex);
        uint256 factorBase = currentFactor == 0 ? FixedPoint128.Q128 : currentFactor;
        uint256 nextFactor = FullMath.mulDivRoundingUp(factorBase, pot - bonus, pot);
        paPool.feesSharedRemainingFactorX128.set(tokenIndex, nextFactor);
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
    ) internal returns (uint256, uint256, uint256, uint256) {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        FeesBurnComputation memory c;

        {
            Position memory pos = s.positions[positionId];
            (uint256 fg0, uint256 fg1) =
                StateLibrary.getFeeGrowthInside(poolManager, params.poolId, pos.tickLower, pos.tickUpper);
            uint256 fg = params.feeTokenIndex == 0 ? fg0 : fg1;

            uint256 lastFeeGrowth = pa.feeGrowthInsideLast.get(params.feeTokenIndex);
            if (params.positionLiquidity > 0 && fg > lastFeeGrowth) {
                c.freshFees = FullMath.mulDiv(fg - lastFeeGrowth, uint256(params.positionLiquidity), FixedPoint128.Q128);
            }
            if (params.consumeResidualFeeBacking) {
                c.bankedFees = pa.pendingResidualFeeBacking.get(params.feeTokenIndex);
            }
        }

        uint256 cumulativeOutflows = pa.cumulativeOutflows.get(params.deficitTokenIndex);
        c.snap = pa.outflowsAtFeeSnap.get(params.deficitTokenIndex);
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
        pa.outflowsAtFeeSnap.set(params.deficitTokenIndex, c.snap + c.consumedBurnBase);

        return (c.feesBurn, c.consumedBurnBase, c.consumedFreshFees, c.consumedBankedFees);
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
        uint256 outflowFloor,
        bool consumeResidualFeeBacking
    ) internal returns (uint256 consumedBurnBase) {
        if (burnBase == 0) return 0;

        uint8 feeTokenIndex = tokenIndex == 0 ? 1 : 0;
        uint256 feesBurn;
        uint256 consumedFreshFees;
        uint256 consumedBankedFees;
        FeesBurnParams memory params = FeesBurnParams({
            poolId: poolId,
            deficitTokenIndex: tokenIndex,
            feeTokenIndex: feeTokenIndex,
            burnBase: burnBase,
            positionLiquidity: positionLiquidity,
            outflowFloor: outflowFloor,
            consumeResidualFeeBacking: consumeResidualFeeBacking
        });
        (feesBurn, consumedBurnBase, consumedFreshFees, consumedBankedFees) =
            _calculateFeesBurn(s, poolManager, positionId, params);

        if (feesBurn == 0) return 0;

        _finaliseBurnAccounting(
            s, positionId, poolId, feeTokenIndex, positionLiquidity, consumedFreshFees, consumedBankedFees, feesBurn
        );
    }

    function _finaliseBurnAccounting(
        VTSStorage storage s,
        PositionId positionId,
        PoolId poolId,
        uint8 feeTokenIndex,
        uint128 positionLiquidity,
        uint256 consumedFreshFees,
        uint256 consumedBankedFees,
        uint256 feesBurn
    ) private {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        if (consumedBankedFees > 0) {
            uint256 currentBacking = pa.pendingResidualFeeBacking.get(feeTokenIndex);
            pa.pendingResidualFeeBacking
                .set(feeTokenIndex, consumedBankedFees > currentBacking ? 0 : (currentBacking - consumedBankedFees));
        }

        if (positionLiquidity > 0 && consumedFreshFees > 0) {
            uint256 liquidity = uint256(positionLiquidity);
            uint256 carryIn = pa.feeBurnGrowthRemainder.get(feeTokenIndex);
            (uint256 growthInc, uint256 newCarry) =
                LiquidityUtils.feeBurnGrowthIncWithRemainder(consumedFreshFees, liquidity, carryIn);
            pa.feeBurnGrowthRemainder.set(feeTokenIndex, newCarry);
            pa.feeGrowthInsideLast.set(feeTokenIndex, pa.feeGrowthInsideLast.get(feeTokenIndex) + growthInc);
        }

        PoolAccounting storage paPool = s.poolAccounting[poolId];
        _prepareFeeShareMint(pa, paPool, feeTokenIndex);
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

    /// @notice Materialise positive `pendingFeeAdj` into `slashedPot` up to per-leg caps (SETTLE-03 on decreases).
    function _finalisePositiveFeeAdjustment(
        VTSStorage storage s,
        PositionId positionId,
        PoolId poolId,
        uint256 positiveCap0,
        uint256 positiveCap1
    ) internal returns (BalanceDelta adj) {
        (int256 pend0, int256 pend1) = _peekFeeAdjustment(s, positionId);
        int256 mat0 = 0;
        int256 mat1 = 0;

        if (pend0 > 0) {
            uint256 pendPos0 = uint256(pend0);
            uint256 pay0 = pendPos0 < positiveCap0 ? pendPos0 : positiveCap0;
            if (pay0 > 0) {
                _fundFeePot(s, poolId, 0, pay0);
                mat0 = pay0.toInt256();
            }
        }

        if (pend1 > 0) {
            uint256 pendPos1 = uint256(pend1);
            uint256 pay1 = pendPos1 < positiveCap1 ? pendPos1 : positiveCap1;
            if (pay1 > 0) {
                _fundFeePot(s, poolId, 1, pay1);
                mat1 = pay1.toInt256();
            }
        }

        PositionAccounting storage pa = s.positionAccounting[positionId];
        pa.pendingFeeAdj.token0 = pend0 - mat0;
        pa.pendingFeeAdj.token1 = pend1 - mat1;

        adj = LiquidityUtils.safeToBalanceDelta(mat0, mat1);
    }

    /// @notice Materialise negative `pendingFeeAdj` by draining `slashedPot` (bonuses queued after positive phase).
    function _finaliseNegativeFeeAdjustment(VTSStorage storage s, PositionId positionId, PoolId poolId)
        internal
        returns (BalanceDelta adj)
    {
        (int256 pend0, int256 pend1) = _peekFeeAdjustment(s, positionId);
        int256 mat0 = 0;
        int256 mat1 = 0;

        if (pend0 < 0) {
            uint256 need0 = uint256(-pend0);
            PoolAccounting storage paPool = s.poolAccounting[poolId];
            uint256 pot0 = paPool.slashedPot.token0;
            uint256 pay0 = pot0 < need0 ? pot0 : need0;
            if (pay0 > 0) {
                _drainFeePot(s, poolId, 0, pay0);
                mat0 = -pay0.toInt256();
            }
        }

        if (pend1 < 0) {
            uint256 need1 = uint256(-pend1);
            PoolAccounting storage paPool = s.poolAccounting[poolId];
            uint256 pot1 = paPool.slashedPot.token1;
            uint256 pay1 = pot1 < need1 ? pot1 : need1;
            if (pay1 > 0) {
                _drainFeePot(s, poolId, 1, pay1);
                mat1 = -pay1.toInt256();
            }
        }

        PositionAccounting storage pa = s.positionAccounting[positionId];
        pa.pendingFeeAdj.token0 = pend0 - mat0;
        pa.pendingFeeAdj.token1 = pend1 - mat1;

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
    /// @param s The central VTS storage
    /// @param positionId The position ID
    /// @param poolId The pool ID
    /// @return adj The materialised delta as BalanceDelta for the hook to apply this call only
    //#olympix-ignore-reentrancy
    function _finaliseFeeAdjustment(
        VTSStorage storage s,
        PositionId positionId,
        PoolId poolId,
        uint256 positiveCap0,
        uint256 positiveCap1
    ) internal returns (BalanceDelta adj) {
        BalanceDelta adjPos = _finalisePositiveFeeAdjustment(s, positionId, poolId, positiveCap0, positiveCap1);
        BalanceDelta adjNeg = _finaliseNegativeFeeAdjustment(s, positionId, poolId);
        return adjPos + adjNeg;
    }

    /// @notice Uncapped finalisation (`positiveCap* = max`).
    function _finaliseFeeAdjustment(VTSStorage storage s, PositionId positionId, PoolId poolId)
        internal
        returns (BalanceDelta adj)
    {
        return _finaliseFeeAdjustment(s, positionId, poolId, type(uint256).max, type(uint256).max);
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

        PositionAccounting storage pa = s.positionAccounting[positionId];
        PoolAccounting storage paPool = s.poolAccounting[poolId];

        // Phase 1 — fund `slashedPot` from positive pending before bonus allocation.
        BalanceDelta adjPos = _finalisePositiveFeeAdjustment(s, positionId, poolId, positiveCap0, positiveCap1);

        // Read CISE exposure for bonus allocation
        // Note: Raw exposure values per coverage token
        uint256 ciseExposure0 = pa.ciseExposureSinceLastMod.token0;
        uint256 ciseExposure1 = pa.ciseExposureSinceLastMod.token1;

        // Phase 2 — queue bonuses using CISE exposure (coverage-indexed settled exposure)
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

        // Phase 3 — drain `slashedPot` for queued bonuses (and any other negative pending).
        BalanceDelta adjNeg = _finaliseNegativeFeeAdjustment(s, positionId, poolId);
        return adjPos + adjNeg;
    }

    /// @notice Uncapped fee processing (`positiveCap* = max`).
    function _processPositionFees(VTSStorage storage s, PositionId positionId) internal returns (BalanceDelta adj) {
        return _processPositionFees(s, positionId, type(uint256).max, type(uint256).max);
    }

    /// @dev Check if fee sharing is enabled for a pool
    function _isFeeSharingEnabled(VTSStorage storage s, PoolId p) internal view returns (bool) {
        return s.pools[p].vtsConfig.coverageFeeShare > 0;
    }

    // --------------------------------------------------
    // Residual / coverage burn orchestration (linked from VTSPositionLib)
    // --------------------------------------------------

    /// @dev Residual fee backing is episode-scoped: once the matching burn base is exhausted,
    ///      any leftover backing on the opposite fee lane must not survive into a later residual episode.
    function _clearResolvedResidualFeeBacking(PositionAccounting storage pa, uint8 deficitTokenIndex) internal {
        if (pa.pendingResidualBurnBase.get(deficitTokenIndex) != 0) return;

        uint8 feeTokenIndex = deficitTokenIndex == 0 ? 1 : 0;
        pa.pendingResidualFeeBacking.set(feeTokenIndex, 0);
    }

    /// @dev Shared residual-backing capture: banks `liquidityScale * (fg - feeGrowthInsideLast)` per fee lane when
    ///      `pendingResidualBurnBase` implies that lane. Uses `getPositionInfo` fee growth (position snapshot after
    ///      modifyLiquidity), which stays authoritative after full removes that clear ticks.
    /// @param advanceFeeGrowthCheckpoint If true (full deactivation), set `feeGrowthInsideLast` to `fg` whenever
    ///        `fg > last`. If false (partial decrease), leave `feeGrowthInsideLast` unchanged for surviving liquidity.
    function _accumulateResidualFeeBackingForLanes(
        PositionAccounting storage pa,
        uint256 fg0,
        uint256 fg1,
        bool needFeeToken0,
        bool needFeeToken1,
        uint256 liquidityScale,
        bool advanceFeeGrowthCheckpoint
    ) private {
        if (needFeeToken0) {
            uint256 last0 = pa.feeGrowthInsideLast.token0;
            if (fg0 > last0) {
                uint256 backing0 = FullMath.mulDiv(fg0 - last0, liquidityScale, FixedPoint128.Q128);
                if (backing0 > 0) pa.pendingResidualFeeBacking.token0 += backing0;
                if (advanceFeeGrowthCheckpoint) pa.feeGrowthInsideLast.token0 = fg0;
            }
        }

        if (needFeeToken1) {
            uint256 last1 = pa.feeGrowthInsideLast.token1;
            if (fg1 > last1) {
                uint256 backing1 = FullMath.mulDiv(fg1 - last1, liquidityScale, FixedPoint128.Q128);
                if (backing1 > 0) pa.pendingResidualFeeBacking.token1 += backing1;
                if (advanceFeeGrowthCheckpoint) pa.feeGrowthInsideLast.token1 = fg1;
            }
        }
    }

    /// @dev Loads pending-residual lanes, reads post-modify position fee growth from PoolManager, then banks backing.
    ///      Prefer `getPositionInfo` over range `getFeeGrowthInside` on full deactivation: after a full remove, Uniswap
    ///      may clear boundary ticks so range-based reads can be wrong; the position snapshot from `modifyLiquidity` is authoritative.
    function _captureResidualFeeBackingForLiquidityScale(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId id,
        uint128 liquidityScale,
        bool advanceFeeGrowthCheckpoint
    ) private {
        if (liquidityScale == 0) return;

        PositionAccounting storage pa = s.positionAccounting[id];
        bool needFeeToken0 = pa.pendingResidualBurnBase.token1 > 0;
        bool needFeeToken1 = pa.pendingResidualBurnBase.token0 > 0;
        if (!needFeeToken0 && !needFeeToken1) return;

        Position memory pos = s.positions[id];
        (, uint256 fg0, uint256 fg1) = StateLibrary.getPositionInfo(poolManager, pos.poolId, PositionId.unwrap(id));

        _accumulateResidualFeeBackingForLanes(
            pa, fg0, fg1, needFeeToken0, needFeeToken1, uint256(liquidityScale), advanceFeeGrowthCheckpoint
        );
    }

    /// @notice Freeze unresolved residual-burn fee backing before a position deactivates to zero liquidity.
    /// @dev Captures fee growth accrued up to the remove call on the fee token lanes needed by pending residual burn.
    function _captureResidualFeeBackingOnDeactivation(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId id,
        uint128 liquidityBeforeRemove
    ) internal {
        _captureResidualFeeBackingForLiquidityScale(s, poolManager, id, liquidityBeforeRemove, true);
    }

    /// @notice Bank fee-token backing for removed liquidity during a partial decrease while a residual episode is open.
    /// @dev Unlike full deactivation, does not advance `feeGrowthInsideLast`: remaining live liquidity keeps the same
    ///      baseline so `freshFees` on later burns still include its share of growth since the last checkpoint.
    function _captureResidualFeeBackingOnPartialDecrease(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId id,
        uint128 removedLiquidity
    ) internal {
        _captureResidualFeeBackingForLiquidityScale(s, poolManager, id, removedLiquidity, false);
    }

    /// @notice Apply banked residual-derived DICE burn against later outflow windows only
    function _applyBankedResidualBurn(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId id,
        PoolId p,
        uint8 tokenIndex,
        uint128 positionLiquidity
    ) internal {
        PositionAccounting storage pa = s.positionAccounting[id];
        uint256 pendingBurnBase = pa.pendingResidualBurnBase.get(tokenIndex);
        if (pendingBurnBase == 0) return;

        uint256 outflowFloor = pa.pendingResidualBurnOutflowsFloor.get(tokenIndex);
        uint256 consumedBurnBase =
            _applyBurnBase(s, poolManager, id, p, tokenIndex, pendingBurnBase, positionLiquidity, outflowFloor, true);
        if (consumedBurnBase > 0) {
            pa.pendingResidualBurnBase.set(tokenIndex, pendingBurnBase - consumedBurnBase);
            if (pendingBurnBase == consumedBurnBase) {
                pa.pendingResidualBurnOutflowsFloor.set(tokenIndex, 0);
                _clearResolvedResidualFeeBacking(pa, tokenIndex);
            }
        }
    }

    // --------------------------------------------------
    // DICE / CISE coverage settlement (linked from VTSPositionLib.settlePositionGrowths)
    // --------------------------------------------------

    /// @notice Flush any pending deficit-indexed coverage residual into the DICE index
    function _flushCoverageResidualIfNeeded(VTSStorage storage s, PoolId poolId, uint8 tokenIndex) internal {
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        uint256 residual = paPool.coverageResidualDICE.get(tokenIndex);
        uint256 principal = paPool.totalDeficitPrincipal.get(tokenIndex);

        if (residual > 0 && principal > 0) {
            uint256 deltaIndex = FullMath.mulDiv(residual, FixedPoint128.Q128, principal);
            uint256 currentIndex = paPool.coveragePerResidualDeficitIndexX128.get(tokenIndex);
            paPool.coveragePerResidualDeficitIndexX128.set(tokenIndex, currentIndex + deltaIndex);
            paPool.coverageResidualDICE.set(tokenIndex, 0);
        }
    }

    function _settleCISEForToken(PositionAccounting storage pa, PoolAccounting storage paPool, uint8 tokenIndex)
        internal
    {
        uint256 indexNow = paPool.coveragePerSettledIndexX128.get(tokenIndex);
        uint256 indexLast = pa.ciseIndexLastX128.get(tokenIndex);

        if (indexNow != indexLast) {
            pa.ciseIndexLastX128.set(tokenIndex, indexNow);
        }

        uint256 deltaIndex = indexNow - indexLast;
        if (deltaIndex > 0) {
            uint256 settled = pa.settled.get(tokenIndex);
            uint256 exposure = FullMath.mulDiv(settled, deltaIndex, FixedPoint128.Q128);
            if (exposure > 0) {
                pa.ciseExposureSinceLastMod.set(tokenIndex, pa.ciseExposureSinceLastMod.get(tokenIndex) + exposure);
            }
        }
    }

    function _settleDICEForToken(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId,
        PoolId poolId,
        uint8 tokenIndex,
        uint128 liq
    ) internal {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        uint256 deficitPrincipal = pa.cumulativeDeficit.get(tokenIndex);

        _clearResolvedResidualFeeBacking(pa, tokenIndex);

        {
            uint256 residualIndexNow = s.poolAccounting[poolId].coveragePerResidualDeficitIndexX128.get(tokenIndex);
            uint256 residualIndexLast = pa.residualCoverageIndexLastX128.get(tokenIndex);

            if (residualIndexNow != residualIndexLast) {
                pa.residualCoverageIndexLastX128.set(tokenIndex, residualIndexNow);
            }

            uint256 deltaResidualIndex = residualIndexNow - residualIndexLast;
            if (deltaResidualIndex > 0 && deficitPrincipal > 0) {
                uint256 residualCov = FullMath.mulDiv(deficitPrincipal, deltaResidualIndex, FixedPoint128.Q128);
                if (residualCov > 0) {
                    pa.pendingResidualBurnBase.set(tokenIndex, pa.pendingResidualBurnBase.get(tokenIndex) + residualCov);

                    uint256 curOutflows = pa.cumulativeOutflows.get(tokenIndex);
                    uint256 existingFloor = pa.pendingResidualBurnOutflowsFloor.get(tokenIndex);
                    if (curOutflows > existingFloor) {
                        pa.pendingResidualBurnOutflowsFloor.set(tokenIndex, curOutflows);
                    }
                }
            }
        }

        {
            uint256 indexNow = s.poolAccounting[poolId].coveragePerDeficitIndexX128.get(tokenIndex);
            uint256 indexLast = pa.coverageIndexLastX128.get(tokenIndex);

            if (indexNow != indexLast) {
                pa.coverageIndexLastX128.set(tokenIndex, indexNow);
            }

            uint256 deltaIndex = indexNow - indexLast;
            if (deltaIndex > 0 && deficitPrincipal > 0) {
                uint256 cov = FullMath.mulDiv(deficitPrincipal, deltaIndex, FixedPoint128.Q128);
                if (cov > 0) {
                    _applyCoverageBurn(s, poolManager, positionId, poolId, tokenIndex, cov, liq);
                }
            }
        }

        _applyBankedResidualBurn(s, poolManager, positionId, poolId, tokenIndex, liq);
    }

    function _settleDeficitIndexedCoverageUsage(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
        internal
    {
        Position memory pos = s.positions[positionId];
        PoolId poolId = pos.poolId;
        uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));

        _settleDICEForToken(s, poolManager, positionId, poolId, 0, liq);
        _settleDICEForToken(s, poolManager, positionId, poolId, 1, liq);
    }

    function _settleSettledIndexedCoverageUsage(VTSStorage storage s, PositionId positionId) internal {
        Position memory pos = s.positions[positionId];
        PoolId poolId = pos.poolId;

        _settleCISEForToken(s.positionAccounting[positionId], s.poolAccounting[poolId], 0);
        _settleCISEForToken(s.positionAccounting[positionId], s.poolAccounting[poolId], 1);
    }

    /// @notice Apply coverage burn for a position (deficit-indexed coverage exercise → fee share)
    /// @dev Fees accrue on the input token, not the deficit token.
    function _applyCoverageBurn(
        VTSStorage storage s,
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

        _applyBurnBase(s, poolManager, id, p, tokenIndex, burnBase, positionLiquidity, 0, false);
    }
}

/// @title VTSFeeLinkedLib
/// @notice Library for VTS fee processing
/// @dev Operates on VTSStorage storage struct via storage pointers
library VTSFeeLinkedLib {
    /// @notice Prepares CSI state before minting fresh fee-share contributions for a position
    /// @dev Advances the spend epoch if needed, then syncs the position's remaining self-share
    ///      against the current pool factor before the caller increases `pendingFeeAdj` / `feesShared`.
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

    /// @notice Processes position fees after touch with optional per-leg caps on positive slash materialisation.
    /// @dev Positive caps limit only the current-touch materialisation (`feeAdj`) for `pendingFeeAdj > 0`. Any excess
    ///      remains queued in `pendingFeeAdj`.
    function afterTouchPositionWithPositiveCaps(
        VTSStorage storage s,
        PositionId positionId,
        uint256 positiveCap0,
        uint256 positiveCap1
    ) external returns (BalanceDelta adj) {
        return VTSFeeLib._processPositionFees(s, positionId, positiveCap0, positiveCap1);
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
        uint256 outflowFloor,
        bool consumeResidualFeeBacking
    ) external returns (uint256 consumedBurnBase) {
        return VTSFeeLib._applyBurnBase(
            s,
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
    function clearResolvedResidualFeeBacking(PositionAccounting storage pa, uint8 deficitTokenIndex) external {
        VTSFeeLib._clearResolvedResidualFeeBacking(pa, deficitTokenIndex);
    }

    /// @notice Freeze unresolved residual-burn fee backing before deactivation to zero liquidity
    function captureResidualFeeBackingOnDeactivation(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId id,
        uint128 liquidityBeforeRemove
    ) external {
        VTSFeeLib._captureResidualFeeBackingOnDeactivation(s, poolManager, id, liquidityBeforeRemove);
    }

    /// @notice Bank historical fee backing for the removed liquidity slice on partial decrease (residual episode open)
    function captureResidualFeeBackingOnPartialDecrease(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId id,
        uint128 removedLiquidity
    ) external {
        VTSFeeLib._captureResidualFeeBackingOnPartialDecrease(s, poolManager, id, removedLiquidity);
    }

    /// @notice Apply banked residual-derived burn against eligible outflow windows
    function applyBankedResidualBurn(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId id,
        PoolId p,
        uint8 tokenIndex,
        uint128 positionLiquidity
    ) external {
        VTSFeeLib._applyBankedResidualBurn(s, poolManager, id, p, tokenIndex, positionLiquidity);
    }

    /// @notice Apply coverage burn from deficit-indexed coverage exercise
    function applyCoverageBurn(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId id,
        PoolId p,
        uint8 tokenIndex,
        uint256 cov,
        uint128 positionLiquidity
    ) external {
        VTSFeeLib._applyCoverageBurn(s, poolManager, id, p, tokenIndex, cov, positionLiquidity);
    }

    /// @notice Flush pending deficit-indexed coverage residual into the DICE index when principal becomes non-zero
    function flushCoverageResidualIfNeeded(VTSStorage storage s, PoolId poolId, uint8 tokenIndex) external {
        VTSFeeLib._flushCoverageResidualIfNeeded(s, poolId, tokenIndex);
    }

    /// @notice Settle settled-indexed coverage usage (CISE) for both tokens
    function settleSettledIndexedCoverageUsage(VTSStorage storage s, PositionId positionId) external {
        VTSFeeLib._settleSettledIndexedCoverageUsage(s, positionId);
    }

    /// @notice Settle deficit-indexed coverage usage (DICE) for both tokens
    function settleDeficitIndexedCoverageUsage(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
        external
    {
        VTSFeeLib._settleDeficitIndexedCoverageUsage(s, poolManager, positionId);
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSFeeLibHarness} from "../../libraries/harnesses/VTSFeeLibHarness.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionId} from "../../../src/types/Position.sol";
import {MarketVTSConfiguration, TokenConfiguration} from "../../../src/types/VTS.sol";
import {FullMath} from "v4-periphery/lib/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";

/// @notice Echidna harness for FEE-01: Bonus queue vs materialised slashed pot.
///         Bonuses are allocated against `slashedPot` after positive pending is materialised; queueing only
///         adjusts `pendingFeeAdj` (and CSI factor) while `slashedPot` stays fixed until negative finalisation.
///         This is split into two actions:
///         - queueBonus: moves pending (and spend index) while `slashedPot` stays fixed.
///         - finalise: moves `slashedPot` when materialising pending (positive funds / negative drains).
///
/// @dev Each action resets CSI epoch / remaining-factor state so expectations match `VTSFeeLib._queueBonusForToken`
///      without implicit carry-over from prior fuzz steps (Echidna reuses one contract instance).
contract FEE01 {
    VTSFeeLibHarness internal feeHarness;

    PoolId internal constant POOL_ID = PoolId.wrap(bytes32(uint256(0xFEE01)));
    PositionId internal constant POSITION_ID = PositionId.wrap(bytes32(uint256(0xFEE01)));
    uint256 internal constant MAX_UNITS = 1e36;

    bool internal checkedQueue;
    bool internal lastOkQueue;
    bool internal checkedFinalise;
    bool internal lastOkFinalise;

    uint8 internal sFeeTokenIndex;
    uint8 internal sCoverageTokenIndex;
    uint256 internal sPot;
    uint256 internal sSelfRemaining;
    uint256 internal sExposure;
    uint256 internal sTotalExposure;
    int256 internal sPending;
    uint256 internal sSlashedPot;
    uint256 internal sIndexBefore;

    struct QueueSnap {
        /// @dev Materialised `slashedPot` balance on the fee-token lane under test
        uint256 materialisedPot;
        int256 pending;
        uint256 spendIndex;
    }

    QueueSnap internal beforeQueue;
    QueueSnap internal afterQueue;

    constructor() {
        // Minimal pool/position setup so fee logic can run in isolation.
        feeHarness = new VTSFeeLibHarness();
        feeHarness.setupPool(POOL_ID, _config(1000));
        feeHarness.setupPosition(POSITION_ID, POOL_ID);
    }

    /// @notice Queue a bonus and assert pending moves while materialised `slashedPot` stays unchanged.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_queue_bonus(
        uint8 feeTokenIndexRaw,
        uint256 protocolFeeAccruedRaw,
        uint256 selfRemainingRaw,
        uint256 ciseExposureRaw,
        uint256 totalExposureRaw
    ) external {
        checkedQueue = false;
        lastOkQueue = true;

        // Cache inputs so we can compute expected queue effects deterministically.
        _cacheQueueInputs(feeTokenIndexRaw, protocolFeeAccruedRaw, selfRemainingRaw, ciseExposureRaw, totalExposureRaw);
        // Set up pool/position state as if there is a pot with self-remaining shares and exposure windows.
        _setupQueueState();

        // Apply queueing and check that only queued fields change.
        bool ok = _applyQueueAndCheck();
        checkedQueue = true;
        lastOkQueue = ok;
    }

    /// @notice Finalise pending and assert `slashedPot` updates per positive/negative materialisation.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_finalise_materialisation(
        uint8 tokenIndexRaw,
        int256 pendingRaw,
        uint256 slashedPotRaw,
        uint256 /* protocolFeeAccruedRaw */
    )
        external
    {
        checkedFinalise = false;
        lastOkFinalise = true;

        uint8 tokenIndex = tokenIndexRaw % 2;
        int256 pending = pendingRaw;
        uint256 slashedPot = _clamp(slashedPotRaw);

        _resetFeeShareIsolationBaseline();

        // Seed pending adjustment and pot state for the selected token.
        _setPending(tokenIndex, pending);
        _setSlashedPot(tokenIndex, slashedPot);

        // Snapshot before finalisation.
        (uint256 pot0Before, uint256 pot1Before) = feeHarness.getSlashedPot(POOL_ID);

        // Finalisation materialises pending into the slashed pot (positive + negative phases).
        feeHarness.finaliseFeeAdjustment(POSITION_ID, POOL_ID);

        (uint256 pot0After, uint256 pot1After) = feeHarness.getSlashedPot(POOL_ID);

        lastOkFinalise = _checkFinalise(tokenIndex, pending, pot0Before, pot1Before, pot0After, pot1After);

        checkedFinalise = true;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_fee_01_queue_vs_pot() external view returns (bool) {
        return !checkedQueue || lastOkQueue;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_fee_01_materialise_updates_pot_only() external view returns (bool) {
        return !checkedFinalise || lastOkFinalise;
    }

    // Keep a second trivial property to avoid rare Echidna instability with single-property targets.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_fee_01_smoke() external pure returns (bool) {
        return true;
    }

    function _checkFinalise(
        uint8 tokenIndex,
        int256 pending,
        uint256 pot0Before,
        uint256 pot1Before,
        uint256 pot0After,
        uint256 pot1After
    ) internal pure returns (bool) {
        uint256 potBefore = tokenIndex == 0 ? pot0Before : pot1Before;
        uint256 potAfter = tokenIndex == 0 ? pot0After : pot1After;

        // Positive pending funds the pot; negative pending drains up to availability.
        if (pending > 0) {
            return potAfter == potBefore + uint256(pending);
        }
        if (pending < 0) {
            uint256 need = uint256(-pending);
            uint256 pay = potBefore < need ? potBefore : need;
            return potAfter == potBefore - pay;
        }
        return potAfter == potBefore;
    }

    function _cacheQueueInputs(
        uint8 feeTokenIndexRaw,
        uint256 protocolFeeAccruedRaw,
        uint256 selfRemainingRaw,
        uint256 ciseExposureRaw,
        uint256 totalExposureRaw
    ) internal {
        // Normalize and store inputs for deterministic expectation math.
        sFeeTokenIndex = feeTokenIndexRaw % 2;
        sCoverageTokenIndex = sFeeTokenIndex == 0 ? 1 : 0;
        sPot = _clamp(protocolFeeAccruedRaw);
        sSelfRemaining = _clamp(selfRemainingRaw);
        sExposure = _clamp(ciseExposureRaw);
        sTotalExposure = _clamp(totalExposureRaw);
        sIndexBefore = 0;
    }

    function _setupQueueState() internal {
        _resetFeeShareIsolationBaseline();

        // Seed materialised pot, self-remaining shares, and exposure windows.
        _setMaterialisedPot(sFeeTokenIndex, sPot);
        _setFeesShared(sFeeTokenIndex, sSelfRemaining);
        if (sCoverageTokenIndex == 0) {
            feeHarness.setPoolTotalCISEExposure(POOL_ID, sTotalExposure, 0);
        } else {
            feeHarness.setPoolTotalCISEExposure(POOL_ID, 0, sTotalExposure);
        }
        feeHarness.setPoolFeesSharedRemainingFactorX128(POOL_ID, 0, 0);
        feeHarness.setPositionFeesSharedRemainingFactorLastX128(POSITION_ID, 0, 0);
    }

    /// @notice Clears cross-action CSI state so each fuzz action matches a fresh `VTSFeeLib` baseline.
    function _resetFeeShareIsolationBaseline() internal {
        feeHarness.setSlashedPot(POOL_ID, 0, 0);
        feeHarness.setPendingFeeAdj(POSITION_ID, 0, 0);
        feeHarness.setFeesShared(POSITION_ID, 0, 0);
        feeHarness.setPoolTotalCISEExposure(POOL_ID, 0, 0);
        feeHarness.setPoolFeesSharedEpoch(POOL_ID, 0, 0);
        feeHarness.setPositionFeesSharedEpoch(POSITION_ID, 0, 0);
        feeHarness.setPoolFeesSharedRemainingFactorX128(POOL_ID, 0, 0);
        feeHarness.setPositionFeesSharedRemainingFactorLastX128(POSITION_ID, 0, 0);
    }

    function _applyQueueAndCheck() internal returns (bool) {
        // Snapshot state, run queue, then compare against expected accounting deltas.
        _snapshotQueue(beforeQueue);
        bool allocated =
            feeHarness.queueBonusForToken(POSITION_ID, POOL_ID, sFeeTokenIndex, sCoverageTokenIndex, sExposure);
        _snapshotQueue(afterQueue);

        (uint256 expMaterialisedPot, int256 expPending, uint256 expIndex, bool expAllocated) = _expectedQueue();

        if (!allocated && !expAllocated) {
            return afterQueue.materialisedPot == beforeQueue.materialisedPot
                && afterQueue.pending == beforeQueue.pending && afterQueue.spendIndex == beforeQueue.spendIndex;
        }

        if (allocated != expAllocated) return false;

        return afterQueue.materialisedPot == expMaterialisedPot && afterQueue.pending == expPending
            && afterQueue.materialisedPot == beforeQueue.materialisedPot && afterQueue.spendIndex == expIndex;
    }

    function _expectedQueue()
        internal
        view
        returns (uint256 expMaterialisedPot, int256 expPending, uint256 expSpendIndex, bool expAllocated)
    {
        // Mirror _queueBonusForToken math to determine expected state changes.
        uint256 pot = sPot;
        uint256 selfRemaining = sSelfRemaining;
        uint256 potAvail = pot > selfRemaining ? (pot - selfRemaining) : 0;

        if (sExposure == 0 || sTotalExposure == 0 || potAvail == 0) {
            return (beforeQueue.materialisedPot, beforeQueue.pending, beforeQueue.spendIndex, false);
        }

        uint256 bonus = FullMath.mulDivRoundingUp(potAvail, sExposure, sTotalExposure);
        if (bonus > potAvail) bonus = potAvail;
        if (bonus == 0) {
            return (beforeQueue.materialisedPot, beforeQueue.pending, beforeQueue.spendIndex, false);
        }

        // Materialised `slashedPot` is not decremented on queue; bonus is banked in negative pending until finalise.
        expMaterialisedPot = beforeQueue.materialisedPot;
        expPending = beforeQueue.pending - int256(bonus);
        // Mirror VTSFeeLib._advanceFeesSharedFactor: multiplicative remaining-share factor, not additive delta.
        if (pot > 0) {
            uint256 currentFactor = beforeQueue.spendIndex;
            uint256 factorBase = currentFactor == 0 ? FixedPoint128.Q128 : currentFactor;
            expSpendIndex = FullMath.mulDivRoundingUp(factorBase, pot - bonus, pot);
        } else {
            expSpendIndex = beforeQueue.spendIndex;
        }
        expAllocated = true;
    }

    function _snapshotQueue(QueueSnap storage snap) internal {
        // Read materialised pot, pending, and CSI remaining factor for the fee token under test.
        (uint256 pot0, uint256 pot1) = feeHarness.getSlashedPot(POOL_ID);
        (int256 pend0, int256 pend1) = feeHarness.getPendingFeeAdj(POSITION_ID);
        (uint256 idx0, uint256 idx1) = feeHarness.getPoolFeesSharedRemainingFactorX128(POOL_ID);

        snap.materialisedPot = sFeeTokenIndex == 0 ? pot0 : pot1;
        snap.pending = sFeeTokenIndex == 0 ? pend0 : pend1;
        snap.spendIndex = sFeeTokenIndex == 0 ? idx0 : idx1;
    }

    function _setMaterialisedPot(uint8 tokenIndex, uint256 amount) internal {
        feeHarness.setSlashedPot(POOL_ID, tokenIndex == 0 ? amount : 0, tokenIndex == 1 ? amount : 0);
    }

    function _setFeesShared(uint8 tokenIndex, uint256 amount) internal {
        feeHarness.setFeesShared(POSITION_ID, tokenIndex == 0 ? amount : 0, tokenIndex == 1 ? amount : 0);
    }

    function _setPending(uint8 tokenIndex, int256 amount) internal {
        feeHarness.setPendingFeeAdj(
            POSITION_ID, tokenIndex == 0 ? amount : int256(0), tokenIndex == 1 ? amount : int256(0)
        );
    }

    function _setSlashedPot(uint8 tokenIndex, uint256 amount) internal {
        feeHarness.setSlashedPot(POOL_ID, tokenIndex == 0 ? amount : 0, tokenIndex == 1 ? amount : 0);
    }

    function _clamp(uint256 value) internal pure returns (uint256) {
        return value > MAX_UNITS ? MAX_UNITS : value;
    }

    function _config(uint16 coverageFeeShare) internal pure returns (MarketVTSConfiguration memory) {
        TokenConfiguration memory tc = TokenConfiguration({
            gracePeriodTime: 0,
            baseVTSRate: 0,
            maxGracePeriodTime: 0,
            unbackedCommitmentGraceBypassTime: 0,
            unbackedCommitmentGraceBypassThreshold: 0
        });
        return MarketVTSConfiguration({
            token0: tc,
            token1: tc,
            coverageFeeShare: coverageFeeShare,
            minResidualUnits: 0,
            unbackedCommitmentGraceBypassBps: 0
        });
    }
}

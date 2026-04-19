// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionId} from "./Position.sol";
import {TokenPairUint, TokenPairInt} from "./VTSPairTypes.sol";

/// @notice Fee-era storage root; held by `VTSOrchestrator` (fee hook owner), not embedded in `VTSStorage`.
struct VTSFeeStorage {
    mapping(PoolId => PoolFeeAccounting) poolFeeAccounting;
    mapping(PositionId => PositionFeeAccounting) positionFeeAccounting;
}

/// @notice Fee-era / DICE / CISE / CSI position accounting (split from `PositionAccounting` for clarity)
/// @dev Lives in `VTSFeeStorage.positionFeeAccounting`; ambient mutation is gated by fee capability (`coverageFeeShare > 0`).
struct PositionFeeAccounting {
    // Fee growth snapshots per token (legacy fee / coverage-fee-burn path)
    TokenPairUint feeGrowthInsideLast;
    // Outflow snapshots at last fee snap per token
    TokenPairUint outflowsAtFeeSnap;
    // Fees shared by position per token
    TokenPairUint feesShared;
    // Pending fee adjustments per token: +slash (reduces payout), -bonus (increases payout)
    TokenPairInt pendingFeeAdj;
    // DICE: Coverage index checkpoint per token (snapshot of pool index at last settlement)
    TokenPairUint coverageIndexLastX128;
    // DICE: Residual-only coverage index checkpoint per token
    TokenPairUint residualCoverageIndexLastX128;
    // DICE: Banked burn base awaiting a later fee/outflow window (ordinary + residual index realisation).
    TokenPairUint pendingResidualBurnBase;
    // DICE: Historical fee backing frozen for the currently unresolved DICE-burn episode across
    // zero-liquidity intervals and partial liquidity decreases (removed slice).
    TokenPairUint pendingResidualFeeBacking;
    // DICE: Outflow watermark captured when banked burn base is increased
    TokenPairUint pendingResidualBurnOutflowsFloor;
    // DICE: Q128 remainder so split index deltas do not lose wei to repeated `floor(D * Δ / Q128)` (ordinary lane).
    TokenPairUint diceOrdinaryRealisationCarry;
    // DICE: Same as above for the residual-only coverage-per-residual-deficit index lane.
    TokenPairUint diceResidualRealisationCarry;
    // DICE: Cumulative assigned coverage (raw units) since the lane last had zero `cumulativeDeficit`
    TokenPairUint diceOrdinaryCovAgg;
    // DICE: Same cumulative bookkeeping for the residual-index leg (symmetry with ordinary).
    TokenPairUint diceResidualCovAgg;
    // CISE: Position checkpoint of pool coverage-per-settled index (Q128)
    TokenPairUint ciseIndexLastX128;
    // CISE: Banked realised exposure since last bonus allocation
    TokenPairUint ciseExposureSinceLastMod;
    // CSI: Position checkpoint of the pool remaining-share factor (Q128)
    TokenPairUint feesSharedRemainingFactorLastX128;
    // CSI: Position checkpoint of the pool spend epoch (per token)
    TokenPairUint feesSharedEpoch;
    // Remainder numerator for coverage fee-burn baseline checkpoint (see VTSFeeLib._applyBurnBase).
    TokenPairUint feeBurnGrowthRemainder;
}

/// @notice Fee-era / DICE / CISE / CSI pool accounting (split from `PoolAccounting` for clarity)
/// @dev Lives in `VTSFeeStorage.poolFeeAccounting`; base denominators remain on `PoolAccounting` in `VTSStorage`.
struct PoolFeeAccounting {
    // Materialised slashed-pot balances per token
    TokenPairUint slashedPot;
    // DICE: Coverage-per-deficit-unit index (Q128) per token
    TokenPairUint coveragePerDeficitIndexX128;
    // DICE: Residual-only coverage-per-deficit-unit index (Q128) per token
    TokenPairUint coveragePerResidualDeficitIndexX128;
    // DICE: Deferred coverage residual (socialised when totalDeficitPrincipal = 0 at exercise time)
    TokenPairUint coverageResidualDICE;
    // CISE: Coverage-per-settled index (Q128) per token
    TokenPairUint coveragePerSettledIndexX128;
    // CISE: Pool-wide bonus denominator window
    TokenPairUint totalCISEExposureSinceLastMod;
    // CSI: Pool-wide remaining-share factor (Q128)
    TokenPairUint feesSharedRemainingFactorX128;
    // CSI: Pool-wide spend epoch
    TokenPairUint feesSharedEpoch;
}

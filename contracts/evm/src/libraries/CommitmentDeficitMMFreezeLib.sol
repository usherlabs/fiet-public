// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PositionAccounting, MarketVTSConfiguration} from "../types/VTS.sol";

/// @title CommitmentDeficitMMFreezeLib
/// @notice Materiality check for when non-seizing MM liquidity changes must be blocked.
library CommitmentDeficitMMFreezeLib {
    /// @notice When true, non-seizing MM `touchPosition` with `liquidityDelta != 0` reverts
    ///         (`Errors.CommitmentDeficitBlocksLiquidityChange`).
    /// @dev Distinguishes **dust** raw `commitmentDeficit` (e.g. from sub-1 bps USD shortfall with `commitmentDeficitBps`
    ///      floored to 0) from **material** insolvency signals: non-zero bps severity, or a lane at/above the optional
    ///      per-token `unbackedCommitmentGraceBypassThreshold`. Seizure path age-gating in `CheckpointLibrary` remains
    ///      separate: this predicate is for MM modify availability only, not for bypass eligibility.
    function blocksNonSeizingMMLiquidityChange(PositionAccounting storage pa, MarketVTSConfiguration memory cfg)
        internal
        view
        returns (bool)
    {
        if (pa.commitmentDeficitBps > 0) {
            return true;
        }
        if (
            cfg.token0.unbackedCommitmentGraceBypassThreshold > 0
                && pa.commitmentDeficit.token0 >= cfg.token0.unbackedCommitmentGraceBypassThreshold
        ) {
            return true;
        }
        if (
            cfg.token1.unbackedCommitmentGraceBypassThreshold > 0
                && pa.commitmentDeficit.token1 >= cfg.token1.unbackedCommitmentGraceBypassThreshold
        ) {
            return true;
        }
        return false;
    }
}

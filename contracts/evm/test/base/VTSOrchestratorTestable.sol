// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSOrchestrator} from "../../src/VTSOrchestrator.sol";
import {PositionAccounting, PoolAccounting} from "../../src/types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionId} from "../../src/types/Position.sol";

// ============================================================
// Testable VTSOrchestrator with Debug View Functions
// ============================================================

/// @title VTSOrchestratorTestable
/// @notice Extends VTSOrchestrator with debug view functions for testing
/// @dev Only used in test files - keeps production VTSOrchestrator clean
contract VTSOrchestratorTestable is VTSOrchestrator {
    constructor(address _poolManager, address _oracleHelper, address _liquidityHub, address _owner)
        VTSOrchestrator(_poolManager, _oracleHelper, _liquidityHub, _owner)
    {}

    /// @notice Get position accounting details for debugging
    /// @param positionId The position identifier
    /// @return cumulativeDeficit0 Cumulative deficit for token0
    /// @return cumulativeDeficit1 Cumulative deficit for token1
    /// @return settled0 Settled amount for token0
    /// @return settled1 Settled amount for token1
    /// @return commitmentMax0 Commitment max for token0
    /// @return commitmentMax1 Commitment max for token1
    function getPositionAccounting(PositionId positionId)
        external
        view
        returns (
            uint256 cumulativeDeficit0,
            uint256 cumulativeDeficit1,
            uint256 settled0,
            uint256 settled1,
            uint256 commitmentMax0,
            uint256 commitmentMax1
        )
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        return (
            pa.cumulativeDeficit.token0,
            pa.cumulativeDeficit.token1,
            pa.settled.token0,
            pa.settled.token1,
            pa.commitmentMax.token0,
            pa.commitmentMax.token1
        );
    }

    /// @notice TEST-ONLY: override commitment maxima to force edge-cases in isPositionValid
    /// @dev This is intentionally unsafe and should only be used in tests.
    function _setCommitmentMax(PositionId positionId, uint256 commitmentMax0, uint256 commitmentMax1) external {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        pa.commitmentMax.token0 = commitmentMax0;
        pa.commitmentMax.token1 = commitmentMax1;
    }

    /// @notice TEST-ONLY: set commitment deficit values directly
    /// @dev This is intentionally unsafe and should only be used in tests.
    function _setCommitmentDeficit(PositionId positionId, uint256 commitmentDeficit0, uint256 commitmentDeficit1)
        external
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        pa.commitmentDeficit.token0 = commitmentDeficit0;
        pa.commitmentDeficit.token1 = commitmentDeficit1;
        if (commitmentDeficit0 == 0) pa.commitmentDeficitSince.token0 = 0;
        if (commitmentDeficit1 == 0) pa.commitmentDeficitSince.token1 = 0;
    }

    /// @notice Get pool DICE (Deficit-Indexed Coverage Exercise) accounting for debugging
    /// @param poolId The pool identifier
    /// @return totalDeficitPrincipal0 Total deficit principal for token0
    /// @return totalDeficitPrincipal1 Total deficit principal for token1
    /// @return coveragePerDeficitIndex0 Coverage per deficit index (Q128) for token0
    /// @return coveragePerDeficitIndex1 Coverage per deficit index (Q128) for token1
    /// @return coverageResidual0 Deferred coverage residual for token0
    /// @return coverageResidual1 Deferred coverage residual for token1
    function getPoolDICEAccounting(PoolId poolId)
        external
        view
        returns (
            uint256 totalDeficitPrincipal0,
            uint256 totalDeficitPrincipal1,
            uint256 coveragePerDeficitIndex0,
            uint256 coveragePerDeficitIndex1,
            uint256 coverageResidual0,
            uint256 coverageResidual1
        )
    {
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        return (
            paPool.totalDeficitPrincipal.token0,
            paPool.totalDeficitPrincipal.token1,
            paPool.coveragePerDeficitIndexX128.token0,
            paPool.coveragePerDeficitIndexX128.token1,
            paPool.coverageResidualDICE.token0,
            paPool.coverageResidualDICE.token1
        );
    }

    /// @notice Get position's DICE coverage index checkpoint for debugging
    /// @param positionId The position identifier
    /// @return coverageIndexLast0 Last coverage index checkpoint for token0
    /// @return coverageIndexLast1 Last coverage index checkpoint for token1
    function getPositionCoverageIndex(PositionId positionId)
        external
        view
        returns (uint256 coverageIndexLast0, uint256 coverageIndexLast1)
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        return (pa.coverageIndexLastX128.token0, pa.coverageIndexLastX128.token1);
    }

    /// @notice Get position's commitment deficit (backing insolvency gate) for debugging
    /// @param positionId The position identifier
    /// @return commitmentDeficit0 Commitment deficit for token0
    /// @return commitmentDeficit1 Commitment deficit for token1
    function getCommitmentDeficit(PositionId positionId)
        external
        view
        returns (uint256 commitmentDeficit0, uint256 commitmentDeficit1)
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        return (pa.commitmentDeficit.token0, pa.commitmentDeficit.token1);
    }

    /// @notice Get bonus weighting inputs for a position (CISE-only)
    /// @dev Bonus eligibility uses CISE exposure (coverage-indexed settled exposure).
    /// @param positionId The position identifier
    /// @return ciseExposure0 CISE exposure since last allocation for token0
    /// @return ciseExposure1 CISE exposure since last allocation for token1
    function getPositionBonusWeights(PositionId positionId)
        external
        view
        returns (uint256 ciseExposure0, uint256 ciseExposure1)
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        return (pa.ciseExposureSinceLastMod.token0, pa.ciseExposureSinceLastMod.token1);
    }

    /// @notice Get pool-wide CISE bonus weighting totals (debug/observability)
    /// @param poolId The pool identifier
    /// @return totalCISEExposure0 Pool-wide CISE exposure since last modification for token0
    /// @return totalCISEExposure1 Pool-wide CISE exposure since last modification for token1
    function getPoolBonusWeightTotals(PoolId poolId)
        external
        view
        returns (uint256 totalCISEExposure0, uint256 totalCISEExposure1)
    {
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        return (paPool.totalCISEExposureSinceLastMod.token0, paPool.totalCISEExposureSinceLastMod.token1);
    }

    /// @notice Get pool CISE (Coverage-Indexed Settled Exposure) accounting for debugging
    /// @param poolId The pool identifier
    /// @return totalSettled0 Total settled aggregate for token0
    /// @return totalSettled1 Total settled aggregate for token1
    /// @return coveragePerSettledIndex0 Coverage per settled index (Q128) for token0
    /// @return coveragePerSettledIndex1 Coverage per settled index (Q128) for token1
    /// @return coverageResidualCISE0 Deferred CISE residual for token0
    /// @return coverageResidualCISE1 Deferred CISE residual for token1
    /// @return totalCISEExposure0 Pool-wide CISE exposure since last modification for token0
    /// @return totalCISEExposure1 Pool-wide CISE exposure since last modification for token1
    function getPoolCISEAccounting(PoolId poolId)
        external
        view
        returns (
            uint256 totalSettled0,
            uint256 totalSettled1,
            uint256 coveragePerSettledIndex0,
            uint256 coveragePerSettledIndex1,
            uint256 coverageResidualCISE0,
            uint256 coverageResidualCISE1,
            uint256 totalCISEExposure0,
            uint256 totalCISEExposure1
        )
    {
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        return (
            paPool.totalSettled.token0,
            paPool.totalSettled.token1,
            paPool.coveragePerSettledIndexX128.token0,
            paPool.coveragePerSettledIndexX128.token1,
            paPool.coverageResidualCISE.token0,
            paPool.coverageResidualCISE.token1,
            paPool.totalCISEExposureSinceLastMod.token0,
            paPool.totalCISEExposureSinceLastMod.token1
        );
    }

    /// @notice Get position's CISE index checkpoint for debugging
    /// @param positionId The position identifier
    /// @return ciseIndexLast0 Last CISE index checkpoint for token0
    /// @return ciseIndexLast1 Last CISE index checkpoint for token1
    function getPositionCISEIndex(PositionId positionId)
        external
        view
        returns (uint256 ciseIndexLast0, uint256 ciseIndexLast1)
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        return (pa.ciseIndexLastX128.token0, pa.ciseIndexLastX128.token1);
    }

    /// @notice Get pool CSI (Contribution Spend Index) accounting for debugging
    /// @param poolId The pool identifier
    /// @return feesSharedSpendIndex0 Spend-per-share index (Q128) for token0
    /// @return feesSharedSpendIndex1 Spend-per-share index (Q128) for token1
    function getPoolCSIAccounting(PoolId poolId)
        external
        view
        returns (uint256 feesSharedSpendIndex0, uint256 feesSharedSpendIndex1)
    {
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        return (paPool.feesSharedSpendIndexX128.token0, paPool.feesSharedSpendIndexX128.token1);
    }

    /// @notice Get position's CSI (Contribution Spend Index) accounting for debugging
    /// @param positionId The position identifier
    /// @return feesShared0 Remaining self-contribution shares for token0
    /// @return feesShared1 Remaining self-contribution shares for token1
    /// @return feesSharedIndexLast0 Last spend index checkpoint for token0
    /// @return feesSharedIndexLast1 Last spend index checkpoint for token1
    function getPositionCSIAccounting(PositionId positionId)
        external
        view
        returns (uint256 feesShared0, uint256 feesShared1, uint256 feesSharedIndexLast0, uint256 feesSharedIndexLast1)
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        return (
            pa.feesShared.token0,
            pa.feesShared.token1,
            pa.feesSharedIndexLastX128.token0,
            pa.feesSharedIndexLastX128.token1
        );
    }
}

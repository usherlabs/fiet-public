// SPDX-License-Identifier: BUSL-1.1
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
    constructor(
        address _poolManager,
        address _signalManager,
        address _oracleHelper,
        address _liquidityHub,
        address _settlementObserver,
        address _owner
    ) VTSOrchestrator(_poolManager, _signalManager, _oracleHelper, _liquidityHub, _settlementObserver, _owner) {}

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

    /// @notice Get fee-sharing accounting for a position (debug)
    /// @param positionId The position identifier
    /// @return feesShared0 Total fees attributed to this position for token0
    /// @return feesShared1 Total fees attributed to this position for token1
    /// @return pendingFeeAdj0 Pending fee adjustment for token0 (+slash, -bonus)
    /// @return pendingFeeAdj1 Pending fee adjustment for token1 (+slash, -bonus)
    function getPositionFeeAccounting(PositionId positionId)
        external
        view
        returns (uint256 feesShared0, uint256 feesShared1, int256 pendingFeeAdj0, int256 pendingFeeAdj1)
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        return (pa.feesShared.token0, pa.feesShared.token1, pa.pendingFeeAdj.token0, pa.pendingFeeAdj.token1);
    }

    /// @notice Get slashed pot balances for a pool (debug)
    /// @dev The slashed pot holds LCC claims used for fee-sharing bonus payouts
    /// @param poolId The pool identifier
    /// @return slashedPot0 Slashed pot balance for token0
    /// @return slashedPot1 Slashed pot balance for token1
    function getSlashedPot(PoolId poolId) external view returns (uint256 slashedPot0, uint256 slashedPot1) {
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        return (paPool.slashedPot.token0, paPool.slashedPot.token1);
    }
}

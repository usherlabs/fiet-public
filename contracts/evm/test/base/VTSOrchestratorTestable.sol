// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSOrchestrator} from "../../src/VTSOrchestrator.sol";
import {PositionAccounting, PoolAccounting} from "../../src/types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionId} from "../../src/types/Position.sol";
import {IVRLSignalManager} from "../../src/interfaces/IVRLSignalManager.sol";
import {IVRLSettlementObserver} from "../../src/interfaces/IVRLSettlementObserver.sol";

// ============================================================
// Testable VTSOrchestrator with Debug View Functions
// ============================================================

/// @title VTSOrchestratorTestable
/// @notice Extends VTSOrchestrator with debug view functions for testing
/// @dev Only used in test files — legacy fee / DICE / CISE / CSI debug readers were removed with fee disablement.
contract VTSOrchestratorTestable is VTSOrchestrator {
    constructor(address _poolManager, address _oracleHelper, address _liquidityHub, address _owner)
        VTSOrchestrator(_poolManager, _oracleHelper, _liquidityHub, _owner)
    {}

    /// @dev TEST-ONLY: clears VRL handler pointers so tests can assert `onlyIfVRLHandlersRegistered` on entrypoints.
    function testOnly_clearVRLHandlers() external {
        signalManager = IVRLSignalManager(address(0));
        settlementObserver = IVRLSettlementObserver(address(0));
    }

    /// @notice Get position accounting details for debugging
    function getPositionAccounting(PositionId positionId)
        external
        view
        returns (
            uint256 cumulativeDeficit0,
            uint256 cumulativeDeficit1,
            uint256 settled0,
            uint256 settled1,
            uint256 commitmentMax0,
            uint256 commitmentMax1,
            uint256 settledOverflow0,
            uint256 settledOverflow1
        )
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        return (
            pa.cumulativeDeficit.token0,
            pa.cumulativeDeficit.token1,
            pa.settled.token0,
            pa.settled.token1,
            pa.commitmentMax.token0,
            pa.commitmentMax.token1,
            pa.settledOverflow.token0,
            pa.settledOverflow.token1
        );
    }

    /// @notice TEST-ONLY: override commitment maxima to force edge-cases in isPositionValid
    function _setCommitmentMax(PositionId positionId, uint256 commitmentMax0, uint256 commitmentMax1) external {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        pa.commitmentMax.token0 = commitmentMax0;
        pa.commitmentMax.token1 = commitmentMax1;
    }

    /// @notice TEST-ONLY: set commitment deficit values directly
    function _setCommitmentDeficit(PositionId positionId, uint256 commitmentDeficit0, uint256 commitmentDeficit1)
        external
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        pa.commitmentDeficit.token0 = commitmentDeficit0;
        pa.commitmentDeficit.token1 = commitmentDeficit1;
        if (commitmentDeficit0 == 0) pa.commitmentDeficitSince.token0 = 0;
        if (commitmentDeficit1 == 0) pa.commitmentDeficitSince.token1 = 0;
    }

    /// @notice TEST-ONLY: set deferred settled overflow amounts directly.
    function _setSettledOverflow(PositionId positionId, uint256 settledOverflow0, uint256 settledOverflow1) external {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        pa.settledOverflow.token0 = settledOverflow0;
        pa.settledOverflow.token1 = settledOverflow1;
    }

    /// @notice Pool base aggregates: deficit growth / inflow growth globals plus totals (mirrors on-chain getters)
    function getPoolBaseAggregates(PoolId poolId)
        external
        view
        returns (
            uint256 deficitGrowth0,
            uint256 deficitGrowth1,
            uint256 inflowGrowth0,
            uint256 inflowGrowth1,
            uint256 totalDeficitPrincipal0,
            uint256 totalDeficitPrincipal1,
            uint256 totalSettled0,
            uint256 totalSettled1
        )
    {
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        return (
            paPool.deficitGrowthGlobal.token0,
            paPool.deficitGrowthGlobal.token1,
            paPool.inflowGrowthGlobal.token0,
            paPool.inflowGrowthGlobal.token1,
            paPool.totalDeficitPrincipal.token0,
            paPool.totalDeficitPrincipal.token1,
            paPool.totalSettled.token0,
            paPool.totalSettled.token1
        );
    }

    /// @notice Get position's commitment deficit (backing insolvency gate) for debugging
    function getCommitmentDeficit(PositionId positionId)
        external
        view
        returns (uint256 commitmentDeficit0, uint256 commitmentDeficit1)
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        return (pa.commitmentDeficit.token0, pa.commitmentDeficit.token1);
    }

    function getPositionEffectiveSettledAmounts(PositionId positionId)
        external
        view
        returns (uint256 effectiveSettled0, uint256 effectiveSettled1)
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        return (
            pa.settled.token0 + pa.settledOverflow.token0, pa.settled.token1 + pa.settledOverflow.token1
        );
    }

    /// @notice Commitment-deficit bypass timer fields (for integration tests)
    function getCommitmentDeficitAgeFields(PositionId positionId)
        external
        view
        returns (uint256 since0, uint256 since1, uint16 deficitBps)
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        return (pa.commitmentDeficitSince.token0, pa.commitmentDeficitSince.token1, pa.commitmentDeficitBps);
    }
}

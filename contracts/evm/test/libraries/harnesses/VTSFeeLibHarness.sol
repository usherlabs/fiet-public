// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSStorage, MarketVTSConfiguration} from "../../../src/types/VTS.sol";
import {PositionId, Position} from "../../../src/types/Position.sol";
import {Pool} from "../../../src/types/Pool.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {VTSFeeLib} from "../../../src/libraries/VTSFeeLib.sol";
import {RFSCheckpoint} from "../../../src/types/Checkpoint.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";

/// @title VTSFeeLibHarness
/// @notice Exposes internal VTSFeeLib functions for unit testing
/// @dev Manages its own VTSStorage that tests manipulate via setup functions
contract VTSFeeLibHarness {
    /// @notice Internal VTSStorage for testing
    VTSStorage internal s;

    // ============ Library Function Exposers ============

    /// @notice Exposes _peekFeeAdjustment
    function peekFeeAdjustment(PositionId positionId) external view returns (int256 adj0, int256 adj1) {
        return VTSFeeLib._peekFeeAdjustment(s, positionId);
    }

    /// @notice Exposes _fundFeePot (accounting only, no PoolManager interaction)
    function fundFeePot(PoolId poolId, uint8 tokenIndex, uint256 amount) external {
        VTSFeeLib._fundFeePot(s, poolId, tokenIndex, amount);
    }

    /// @notice Exposes _drainFeePot (accounting only, no PoolManager interaction)
    function drainFeePot(PoolId poolId, uint8 tokenIndex, uint256 amount) external {
        VTSFeeLib._drainFeePot(s, poolId, tokenIndex, amount);
    }

    /// @notice Exposes _finaliseFeeAdjustment (accounting only, no PoolManager interaction)
    function finaliseFeeAdjustment(PositionId positionId, PoolId poolId) external returns (BalanceDelta adj) {
        return VTSFeeLib._finaliseFeeAdjustment(s, positionId, poolId);
    }

    /// @notice Exposes processPositionFees via the linked library (accounting only, no PoolManager interaction)
    function afterTouchPosition(PositionId positionId) external returns (BalanceDelta adj) {
        return VTSFeeLib._processPositionFees(s, positionId);
    }

    // ============ Internal Helper Exposers (for branch coverage) ============

    /// @notice Exposes VTSFeeLib._syncFeesSharedRemainingForToken
    function syncFeesSharedRemainingForToken(PositionId positionId, PoolId poolId, uint8 tokenIndex) external {
        VTSFeeLib._syncFeesSharedRemainingForToken(
            s.positionAccounting[positionId], s.poolAccounting[poolId], tokenIndex
        );
    }

    /// @notice Exposes VTSFeeLib._prepareFeeShareMint
    function prepareFeeShareMint(PositionId positionId, PoolId poolId, uint8 feeTokenIndex) external {
        VTSFeeLib._prepareFeeShareMint(s.positionAccounting[positionId], s.poolAccounting[poolId], feeTokenIndex);
    }

    /// @notice Exposes VTSFeeLib._queueBonusForToken
    function queueBonusForToken(
        PositionId positionId,
        PoolId poolId,
        uint8 feeTokenIndex,
        uint8 coverageTokenIndex,
        uint256 ciseExposure
    ) external returns (bool allocated) {
        return VTSFeeLib._queueBonusForToken(
            s.positionAccounting[positionId], s.poolAccounting[poolId], feeTokenIndex, coverageTokenIndex, ciseExposure
        );
    }

    /// @notice Exposes VTSFeeLib._cleanupAfterAllocationForToken
    function cleanupAfterAllocationForToken(
        PositionId positionId,
        PoolId poolId,
        uint8 coverageTokenIndex,
        uint256 ciseExposure
    ) external {
        VTSFeeLib._cleanupAfterAllocationForToken(
            s.positionAccounting[positionId], s.poolAccounting[poolId], coverageTokenIndex, ciseExposure
        );
    }

    /// @notice Exposes `_applyBurnBase` for direct fee-burn maths tests.
    function applyBurnBase(
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

    // ============ Storage Getters (for assertions) ============

    function getPendingFeeAdj(PositionId id) external view returns (int256 adj0, int256 adj1) {
        return (s.positionAccounting[id].pendingFeeAdj.token0, s.positionAccounting[id].pendingFeeAdj.token1);
    }

    function getSlashedPot(PoolId poolId) external view returns (uint256 pot0, uint256 pot1) {
        return (s.poolAccounting[poolId].slashedPot.token0, s.poolAccounting[poolId].slashedPot.token1);
    }

    function getFeesShared(PositionId id) external view returns (uint256 fee0, uint256 fee1) {
        return (s.positionAccounting[id].feesShared.token0, s.positionAccounting[id].feesShared.token1);
    }

    function getCISEExposure(PositionId id) external view returns (uint256 exposure0, uint256 exposure1) {
        return (
            s.positionAccounting[id].ciseExposureSinceLastMod.token0,
            s.positionAccounting[id].ciseExposureSinceLastMod.token1
        );
    }

    function getPoolTotalCISEExposure(PoolId poolId) external view returns (uint256 exposure0, uint256 exposure1) {
        return (
            s.poolAccounting[poolId].totalCISEExposureSinceLastMod.token0,
            s.poolAccounting[poolId].totalCISEExposureSinceLastMod.token1
        );
    }

    function getPoolFeesSharedRemainingFactorX128(PoolId poolId)
        external
        view
        returns (uint256 factor0, uint256 factor1)
    {
        return (
            s.poolAccounting[poolId].feesSharedRemainingFactorX128.token0,
            s.poolAccounting[poolId].feesSharedRemainingFactorX128.token1
        );
    }

    function getPositionFeesSharedRemainingFactorLastX128(PositionId id)
        external
        view
        returns (uint256 factor0, uint256 factor1)
    {
        return (
            s.positionAccounting[id].feesSharedRemainingFactorLastX128.token0,
            s.positionAccounting[id].feesSharedRemainingFactorLastX128.token1
        );
    }

    function getPoolFeesSharedEpoch(PoolId poolId) external view returns (uint256 epoch0, uint256 epoch1) {
        return (s.poolAccounting[poolId].feesSharedEpoch.token0, s.poolAccounting[poolId].feesSharedEpoch.token1);
    }

    function getPositionFeesSharedEpoch(PositionId id) external view returns (uint256 epoch0, uint256 epoch1) {
        return (s.positionAccounting[id].feesSharedEpoch.token0, s.positionAccounting[id].feesSharedEpoch.token1);
    }

    /// @notice Returns the position's pending residual fee backing balances.
    /// @param id The position id.
    /// @return fee0 The token0 residual fee backing.
    /// @return fee1 The token1 residual fee backing.
    function getPendingResidualFeeBacking(PositionId id) external view returns (uint256 fee0, uint256 fee1) {
        return (
            s.positionAccounting[id].pendingResidualFeeBacking.token0,
            s.positionAccounting[id].pendingResidualFeeBacking.token1
        );
    }

    /// @notice Returns the position's cumulative outflow snapshot used for fee accounting.
    /// @param id The position id.
    /// @return snap0 The token0 outflow snapshot.
    /// @return snap1 The token1 outflow snapshot.
    function getOutflowsAtFeeSnap(PositionId id) external view returns (uint256 snap0, uint256 snap1) {
        return (s.positionAccounting[id].outflowsAtFeeSnap.token0, s.positionAccounting[id].outflowsAtFeeSnap.token1);
    }

    /// @notice Returns the last fee-growth-inside snapshot stored for the position.
    /// @param id The position id.
    /// @return fg0 The token0 fee growth inside snapshot.
    /// @return fg1 The token1 fee growth inside snapshot.
    function getFeeGrowthInsideLast(PositionId id) external view returns (uint256 fg0, uint256 fg1) {
        return
            (s.positionAccounting[id].feeGrowthInsideLast.token0, s.positionAccounting[id].feeGrowthInsideLast.token1);
    }

    // ============ Storage Setters (for test setup) ============

    /// @notice Sets up a pool with VTS configuration
    function setupPool(PoolId poolId, MarketVTSConfiguration memory config) external {
        s.pools[poolId] = Pool({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            vtsConfig: config,
            isPaused: false
        });
    }

    /// @notice Registers a position (simplified for fee testing)
    function setupPosition(PositionId id, PoolId poolId) external {
        s.positions[id] = Position({
            owner: address(this),
            poolId: poolId,
            commitId: 0,
            tickLower: -600,
            tickUpper: 600,
            liquidity: 1000e18,
            isActive: true,
            salt: bytes32(0),
            checkpoint: RFSCheckpoint({
                openMask: 0, openSince0: 0, openSince1: 0, gracePeriodExtension0: 0, gracePeriodExtension1: 0
            })
        });
        s.positionAccounting[id].feesSharedEpoch.token0 = s.poolAccounting[poolId].feesSharedEpoch.token0;
        s.positionAccounting[id].feesSharedEpoch.token1 = s.poolAccounting[poolId].feesSharedEpoch.token1;
    }

    /// @notice Registers a position with explicit pool geometry for live PoolManager-backed fee tests.
    function setupPositionWithDetails(
        PositionId id,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        bytes32 salt
    ) external {
        s.positions[id] = Position({
            owner: address(this),
            poolId: poolId,
            commitId: 0,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            isActive: true,
            salt: salt,
            checkpoint: RFSCheckpoint({
                openMask: 0, openSince0: 0, openSince1: 0, gracePeriodExtension0: 0, gracePeriodExtension1: 0
            })
        });
        s.positionAccounting[id].feesSharedEpoch.token0 = s.poolAccounting[poolId].feesSharedEpoch.token0;
        s.positionAccounting[id].feesSharedEpoch.token1 = s.poolAccounting[poolId].feesSharedEpoch.token1;
    }

    /// @notice Sets pending fee adjustment for a position
    function setPendingFeeAdj(PositionId id, int256 adj0, int256 adj1) external {
        s.positionAccounting[id].pendingFeeAdj.token0 = adj0;
        s.positionAccounting[id].pendingFeeAdj.token1 = adj1;
    }

    /// @notice Sets slashed pot for a pool
    function setSlashedPot(PoolId poolId, uint256 pot0, uint256 pot1) external {
        s.poolAccounting[poolId].slashedPot.token0 = pot0;
        s.poolAccounting[poolId].slashedPot.token1 = pot1;
    }

    /// @notice Sets fees shared for a position
    function setFeesShared(PositionId id, uint256 fee0, uint256 fee1) external {
        s.positionAccounting[id].feesShared.token0 = fee0;
        s.positionAccounting[id].feesShared.token1 = fee1;
    }

    /// @notice Sets CISE exposure for a position
    function setCISEExposure(PositionId id, uint256 exposure0, uint256 exposure1) external {
        s.positionAccounting[id].ciseExposureSinceLastMod.token0 = exposure0;
        s.positionAccounting[id].ciseExposureSinceLastMod.token1 = exposure1;
    }

    /// @notice Sets pool total CISE exposure
    function setPoolTotalCISEExposure(PoolId poolId, uint256 exposure0, uint256 exposure1) external {
        s.poolAccounting[poolId].totalCISEExposureSinceLastMod.token0 = exposure0;
        s.poolAccounting[poolId].totalCISEExposureSinceLastMod.token1 = exposure1;
    }

    function setPoolFeesSharedRemainingFactorX128(PoolId poolId, uint256 factor0, uint256 factor1) external {
        s.poolAccounting[poolId].feesSharedRemainingFactorX128.token0 = factor0;
        s.poolAccounting[poolId].feesSharedRemainingFactorX128.token1 = factor1;
    }

    function setPositionFeesSharedRemainingFactorLastX128(PositionId id, uint256 factor0, uint256 factor1) external {
        s.positionAccounting[id].feesSharedRemainingFactorLastX128.token0 = factor0;
        s.positionAccounting[id].feesSharedRemainingFactorLastX128.token1 = factor1;
    }

    function setPoolFeesSharedEpoch(PoolId poolId, uint256 epoch0, uint256 epoch1) external {
        s.poolAccounting[poolId].feesSharedEpoch.token0 = epoch0;
        s.poolAccounting[poolId].feesSharedEpoch.token1 = epoch1;
    }

    function setPositionFeesSharedEpoch(PositionId id, uint256 epoch0, uint256 epoch1) external {
        s.positionAccounting[id].feesSharedEpoch.token0 = epoch0;
        s.positionAccounting[id].feesSharedEpoch.token1 = epoch1;
    }

    /// @notice Sets the position's pending residual fee backing balances.
    /// @param id The position id.
    /// @param fee0 The token0 residual fee backing.
    /// @param fee1 The token1 residual fee backing.
    function setPendingResidualFeeBacking(PositionId id, uint256 fee0, uint256 fee1) external {
        s.positionAccounting[id].pendingResidualFeeBacking.token0 = fee0;
        s.positionAccounting[id].pendingResidualFeeBacking.token1 = fee1;
    }

    function setCumulativeOutflows(PositionId id, uint256 out0, uint256 out1) external {
        s.positionAccounting[id].cumulativeOutflows.token0 = out0;
        s.positionAccounting[id].cumulativeOutflows.token1 = out1;
    }

    /// @notice Sets the position's cumulative outflow snapshot used for fee accounting.
    /// @param id The position id.
    /// @param snap0 The token0 outflow snapshot.
    /// @param snap1 The token1 outflow snapshot.
    function setOutflowsAtFeeSnap(PositionId id, uint256 snap0, uint256 snap1) external {
        s.positionAccounting[id].outflowsAtFeeSnap.token0 = snap0;
        s.positionAccounting[id].outflowsAtFeeSnap.token1 = snap1;
    }

    /// @notice Sets the last fee-growth-inside snapshot stored for the position.
    /// @param id The position id.
    /// @param fg0 The token0 fee growth inside snapshot.
    /// @param fg1 The token1 fee growth inside snapshot.
    function setFeeGrowthInsideLast(PositionId id, uint256 fg0, uint256 fg1) external {
        s.positionAccounting[id].feeGrowthInsideLast.token0 = fg0;
        s.positionAccounting[id].feeGrowthInsideLast.token1 = fg1;
    }
}

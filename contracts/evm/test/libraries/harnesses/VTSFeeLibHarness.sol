// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VTSStorage, MarketVTSConfiguration} from "../../../src/types/VTS.sol";
import {PositionId, Position} from "../../../src/types/Position.sol";
import {Pool} from "../../../src/types/Pool.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {VTSFeeLib, VTSFeeLinkedLib} from "../../../src/libraries/VTSFeeLib.sol";
import {RFSCheckpoint} from "../../../src/types/Checkpoint.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

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
        return VTSFeeLinkedLib.afterTouchPosition(s, positionId);
    }

    // ============ Internal Helper Exposers (for branch coverage) ============

    /// @notice Exposes VTSFeeLib._syncFeesSharedRemainingForToken
    function syncFeesSharedRemainingForToken(PositionId positionId, PoolId poolId, uint8 tokenIndex) external {
        VTSFeeLib._syncFeesSharedRemainingForToken(
            s.positionAccounting[positionId], s.poolAccounting[poolId], tokenIndex
        );
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

    // ============ Storage Getters (for assertions) ============

    function getPendingFeeAdj(PositionId id) external view returns (int256 adj0, int256 adj1) {
        return (s.positionAccounting[id].pendingFeeAdj.token0, s.positionAccounting[id].pendingFeeAdj.token1);
    }

    function getSlashedPot(PoolId poolId) external view returns (uint256 pot0, uint256 pot1) {
        return (s.poolAccounting[poolId].slashedPot.token0, s.poolAccounting[poolId].slashedPot.token1);
    }

    function getProtocolFeeAccrued(PoolId poolId) external view returns (uint256 fee0, uint256 fee1) {
        return (s.poolAccounting[poolId].protocolFeeAccrued.token0, s.poolAccounting[poolId].protocolFeeAccrued.token1);
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

    function getPoolFeesSharedSpendIndexX128(PoolId poolId) external view returns (uint256 index0, uint256 index1) {
        return (
            s.poolAccounting[poolId].feesSharedSpendIndexX128.token0,
            s.poolAccounting[poolId].feesSharedSpendIndexX128.token1
        );
    }

    function getPositionFeesSharedIndexLastX128(PositionId id) external view returns (uint256 index0, uint256 index1) {
        return (
            s.positionAccounting[id].feesSharedIndexLastX128.token0,
            s.positionAccounting[id].feesSharedIndexLastX128.token1
        );
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
                timeOfLastTransition: block.timestamp, isOpen: false, gracePeriodExtension0: 0, gracePeriodExtension1: 0
            })
        });
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

    /// @notice Sets protocol fee accrued for a pool
    function setProtocolFeeAccrued(PoolId poolId, uint256 fee0, uint256 fee1) external {
        s.poolAccounting[poolId].protocolFeeAccrued.token0 = fee0;
        s.poolAccounting[poolId].protocolFeeAccrued.token1 = fee1;
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

    function setPoolFeesSharedSpendIndexX128(PoolId poolId, uint256 index0, uint256 index1) external {
        s.poolAccounting[poolId].feesSharedSpendIndexX128.token0 = index0;
        s.poolAccounting[poolId].feesSharedSpendIndexX128.token1 = index1;
    }

    function setPositionFeesSharedIndexLastX128(PositionId id, uint256 index0, uint256 index1) external {
        s.positionAccounting[id].feesSharedIndexLastX128.token0 = index0;
        s.positionAccounting[id].feesSharedIndexLastX128.token1 = index1;
    }
}

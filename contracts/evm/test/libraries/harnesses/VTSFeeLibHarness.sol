// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {VTSStorage, MarketVTSConfiguration} from "../../../src/types/VTS.sol";
import {PositionId, Position} from "../../../src/types/Position.sol";
import {Pool} from "../../../src/types/Pool.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {VTSFeeLib} from "../../../src/libraries/VTSFeeLib.sol";
import {RFSCheckpoint} from "../../../src/types/Checkpoint.sol";

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

    /// @notice Exposes _fundFeePot (requires actual poolManager)
    function fundFeePot(
        IPoolManager poolManager,
        PoolId poolId,
        Currency lccCurrency,
        uint8 tokenIndex,
        uint256 amount
    ) external {
        VTSFeeLib._fundFeePot(s, poolManager, poolId, lccCurrency, tokenIndex, amount);
    }

    /// @notice Exposes _drainFeePot (requires actual poolManager)
    function drainFeePot(
        IPoolManager poolManager,
        PoolId poolId,
        Currency lccCurrency,
        uint8 tokenIndex,
        uint256 amount
    ) external {
        VTSFeeLib._drainFeePot(s, poolManager, poolId, lccCurrency, tokenIndex, amount);
    }

    /// @notice Exposes _finaliseFeeAdjustment (requires actual poolManager)
    function finaliseFeeAdjustment(
        IPoolManager poolManager,
        PositionId positionId,
        PoolId poolId,
        Currency currency0,
        Currency currency1
    ) external returns (BalanceDelta adj) {
        return VTSFeeLib._finaliseFeeAdjustment(s, poolManager, positionId, poolId, currency0, currency1);
    }

    /// @notice Exposes processPositionFees (requires actual poolManager)
    function processPositionFees(
        IPoolManager poolManager,
        PositionId positionId,
        Currency currency0,
        Currency currency1
    ) external returns (BalanceDelta adj) {
        return VTSFeeLib.processPositionFees(s, poolManager, positionId, currency0, currency1);
    }

    /// @notice Exposes proactiveFunding (requires actual poolManager)
    function proactiveFunding(
        IPoolManager poolManager,
        PoolId poolId,
        PositionId positionId,
        Currency lccCurrency0,
        Currency lccCurrency1
    ) external {
        VTSFeeLib.proactiveFunding(s, poolManager, poolId, positionId, lccCurrency0, lccCurrency1);
    }

    // ============ Storage Getters (for assertions) ============

    function getPendingFeeAdj(PositionId id) external view returns (int256 adj0, int256 adj1) {
        return (s.positionAccounting[id].pendingFeeAdj.token0, s.positionAccounting[id].pendingFeeAdj.token1);
    }

    function getLastFundedPendingAdj(PositionId id) external view returns (int256 adj0, int256 adj1) {
        return
            (s.positionAccounting[id].lastFundedPendingAdj.token0, s.positionAccounting[id].lastFundedPendingAdj.token1);
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

    function getNetSettlementSinceLastMod(PositionId id) external view returns (int256 net0, int256 net1) {
        return (
            s.positionAccounting[id].netSettlementSinceLastMod.token0,
            s.positionAccounting[id].netSettlementSinceLastMod.token1
        );
    }

    function getPoolNetSinceLastMod(PoolId poolId) external view returns (uint256 net0, uint256 net1) {
        return
            (s.poolAccounting[poolId].poolNetSinceLastMod.token0, s.poolAccounting[poolId].poolNetSinceLastMod.token1);
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

    /// @notice Sets last funded pending adjustment for a position
    function setLastFundedPendingAdj(PositionId id, int256 adj0, int256 adj1) external {
        s.positionAccounting[id].lastFundedPendingAdj.token0 = adj0;
        s.positionAccounting[id].lastFundedPendingAdj.token1 = adj1;
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

    /// @notice Sets net settlement since last mod for a position
    function setNetSettlementSinceLastMod(PositionId id, int256 net0, int256 net1) external {
        s.positionAccounting[id].netSettlementSinceLastMod.token0 = net0;
        s.positionAccounting[id].netSettlementSinceLastMod.token1 = net1;
    }

    /// @notice Sets pool net since last mod
    function setPoolNetSinceLastMod(PoolId poolId, uint256 net0, uint256 net1) external {
        s.poolAccounting[poolId].poolNetSinceLastMod.token0 = net0;
        s.poolAccounting[poolId].poolNetSinceLastMod.token1 = net1;
    }
}

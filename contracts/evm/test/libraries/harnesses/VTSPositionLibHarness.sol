// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {VTSStorage, MarketVTSConfiguration, TokenConfiguration} from "../../../src/types/VTS.sol";
import {PositionId, Position} from "../../../src/types/Position.sol";
import {Pool} from "../../../src/types/Pool.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {VTSPositionLib} from "../../../src/libraries/VTSPositionLib.sol";
import {RFSCheckpoint} from "../../../src/types/Checkpoint.sol";
import {IMarketVault} from "../../../src/interfaces/IMarketVault.sol";
import {DynamicCurrencyDelta} from "../../../src/libraries/DynamicCurrencyDelta.sol";
import {CurrencyDelta} from "v4-periphery/lib/v4-core/src/libraries/CurrencyDelta.sol";

/// @title VTSPositionLibHarness
/// @notice Exposes internal VTSPositionLib functions for unit testing
/// @dev Manages its own VTSStorage that tests manipulate via setup functions
contract VTSPositionLibHarness {
    using CurrencyDelta for Currency;

    /// @notice Internal VTSStorage for testing
    VTSStorage internal s;

    // ============ Library Function Exposers ============

    /// @notice Exposes _trackCommitment
    function trackCommitment(PositionId positionId, ModifyLiquidityParams calldata params) external {
        VTSPositionLib._trackCommitment(s, positionId, params);
    }

    /// @notice Exposes _updateSettlement
    function updateSettlement(PositionId id, uint8 tokenIndex, int256 delta) external returns (int256 applied) {
        return VTSPositionLib._updateSettlement(s, id, tokenIndex, delta);
    }

    /// @notice Exposes _registerPosition
    function registerPosition(address owner, PoolId poolId, ModifyLiquidityParams calldata params) external {
        VTSPositionLib._registerPosition(s, owner, poolId, params);
    }

    /// @notice Exposes _linkPositionToCommit
    function linkPositionToCommit(PositionId positionId, uint256 commitId) external {
        VTSPositionLib._linkPositionToCommit(s, positionId, commitId);
    }

    /// @notice Exposes _initPositionSnapshots
    function initPositionSnapshots(IPoolManager poolManager, PositionId id) external {
        VTSPositionLib._initPositionSnapshots(s, poolManager, id);
    }

    /// @notice Exposes settlePositionGrowths
    function settlePositionGrowths(IPoolManager poolManager, PositionId positionId) external {
        VTSPositionLib.settlePositionGrowths(s, poolManager, positionId);
    }

    /// @notice Exposes calcRFS
    function calcRFS(IPoolManager poolManager, PositionId id, bool requireClosedRfS)
        external
        returns (bool rfsOpen, BalanceDelta delta)
    {
        return VTSPositionLib.calcRFS(s, poolManager, id, requireClosedRfS);
    }

    /// @notice Exposes getRFS (view)
    function getRFS(PositionId positionId) external view returns (bool rfsOpen, BalanceDelta delta) {
        return VTSPositionLib.getRFS(s, positionId);
    }

    /// @notice Exposes onMMSettle for testing
    function onMMSettle(
        IPoolManager poolManager,
        IMarketVault vault,
        PositionId positionId,
        Currency lccCurrency0,
        Currency lccCurrency1,
        BalanceDelta delta,
        bool isSeizing
    ) external returns (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiquidityUnits) {
        return VTSPositionLib.onMMSettle(
                s, poolManager, vault, positionId, lccCurrency0, lccCurrency1, delta, isSeizing
            );
    }

    // ============ Storage Getters (for assertions) ============

    function getPositionAccounting(PositionId id)
        external
        view
        returns (
            uint256 commitmentMax0,
            uint256 commitmentMax1,
            uint256 settled0,
            uint256 settled1,
            uint256 cumulativeDeficit0,
            uint256 cumulativeDeficit1
        )
    {
        return (
            s.positionAccounting[id].commitmentMax.token0,
            s.positionAccounting[id].commitmentMax.token1,
            s.positionAccounting[id].settled.token0,
            s.positionAccounting[id].settled.token1,
            s.positionAccounting[id].cumulativeDeficit.token0,
            s.positionAccounting[id].cumulativeDeficit.token1
        );
    }

    function getPosition(PositionId id) external view returns (Position memory) {
        return s.positions[id];
    }

    function getCommitmentDeficit(PositionId id) external view returns (uint256 cd0, uint256 cd1) {
        return (s.positionAccounting[id].commitmentDeficit.token0, s.positionAccounting[id].commitmentDeficit.token1);
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

    /// @notice Sets commitment maxima for a position
    function setCommitmentMax(PositionId id, uint256 c0, uint256 c1) external {
        s.positionAccounting[id].commitmentMax.token0 = c0;
        s.positionAccounting[id].commitmentMax.token1 = c1;
    }

    /// @notice Sets settled amounts for a position
    function setSettled(PositionId id, uint256 s0, uint256 s1) external {
        s.positionAccounting[id].settled.token0 = s0;
        s.positionAccounting[id].settled.token1 = s1;
    }

    /// @notice Sets cumulative deficit for a position
    function setCumulativeDeficit(PositionId id, uint256 d0, uint256 d1) external {
        s.positionAccounting[id].cumulativeDeficit.token0 = d0;
        s.positionAccounting[id].cumulativeDeficit.token1 = d1;
    }

    /// @notice Sets commitment deficit for a position
    function setCommitmentDeficit(PositionId id, uint256 cd0, uint256 cd1) external {
        s.positionAccounting[id].commitmentDeficit.token0 = cd0;
        s.positionAccounting[id].commitmentDeficit.token1 = cd1;
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

    /// @notice Sets deficit growth global for a pool
    function setDeficitGrowthGlobal(PoolId poolId, uint256 g0, uint256 g1) external {
        s.poolAccounting[poolId].deficitGrowthGlobal.token0 = g0;
        s.poolAccounting[poolId].deficitGrowthGlobal.token1 = g1;
    }

    /// @notice Sets inflow growth global for a pool
    function setInflowGrowthGlobal(PoolId poolId, uint256 g0, uint256 g1) external {
        s.poolAccounting[poolId].inflowGrowthGlobal.token0 = g0;
        s.poolAccounting[poolId].inflowGrowthGlobal.token1 = g1;
    }

    /// @notice Sets deficit growth inside last for a position
    function setDeficitGrowthInsideLast(PositionId id, uint256 dg0, uint256 dg1) external {
        s.positionAccounting[id].deficitGrowthInsideLast.token0 = dg0;
        s.positionAccounting[id].deficitGrowthInsideLast.token1 = dg1;
    }

    /// @notice Sets inflow growth inside last for a position
    function setInflowGrowthInsideLast(PositionId id, uint256 ig0, uint256 ig1) external {
        s.positionAccounting[id].inflowGrowthInsideLast.token0 = ig0;
        s.positionAccounting[id].inflowGrowthInsideLast.token1 = ig1;
    }

    /// @notice Sets position isActive state
    function setPositionActive(PositionId id, bool active) external {
        s.positions[id].isActive = active;
    }

    /// @notice Sets underlying currency delta using DynamicCurrencyDelta.accountDelta
    /// @dev Uses DynamicCurrencyDelta to match the actual implementation
    function setUnderlyingDelta(Currency currency, address target, int128 delta) external {
        DynamicCurrencyDelta.accountDelta(currency, delta, target);
    }

    /// @notice Gets RFS checkpoint for a position
    function getRFSCheckpoint(PositionId id) external view returns (RFSCheckpoint memory) {
        return s.positions[id].checkpoint;
    }

    /// @notice Sets RFS checkpoint manually for testing
    function setRFSCheckpoint(PositionId id, RFSCheckpoint memory checkpoint) external {
        s.positions[id].checkpoint = checkpoint;
    }

    /// @notice Gets underlying currency delta for a target address
    function getUnderlyingDelta(Currency currency, address target) external view returns (int256) {
        return currency.getDelta(target);
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {
    VTSStorage,
    PositionAccounting,
    MarketVTSConfiguration,
    TokenConfiguration,
    GrowthPair,
    PositionContext,
    TouchPositionParams,
    TouchPositionResult,
    SettleParams,
    SettleResult,
    VaultSettlementIntent,
    GrowthCarryQ128
} from "../../../src/types/VTS.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
import {PositionId, Position} from "../../../src/types/Position.sol";
import {Pool} from "../../../src/types/Pool.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {VTSPositionLib} from "../../../src/libraries/VTSPositionLib.sol";
import {VTSPositionMMOpsLib} from "../../../src/libraries/VTSPositionMMOpsLib.sol";
import {VTSLifecycleLinkedLib} from "../../../src/libraries/VTSLifecycleLinkedLib.sol";
import {RFSCheckpoint} from "../../../src/types/Checkpoint.sol";
import {IMarketVault} from "../../../src/interfaces/IMarketVault.sol";
import {OwnerCurrencyDelta} from "../../../src/libraries/OwnerCurrencyDelta.sol";
import {MarketCurrencyDelta} from "../../../src/libraries/MarketCurrencyDelta.sol";
import {ICanonicalVault} from "../../../src/interfaces/ICanonicalVault.sol";
import {CurrencyDelta} from "v4-periphery/lib/v4-core/src/libraries/CurrencyDelta.sol";
import {LiquidityUtils} from "../../../src/libraries/LiquidityUtils.sol";
import {CarryQ128, CarryQ128Lib} from "../../../src/types/Carry.sol";

/// @title VTSPositionLibHarness
/// @notice Exposes internal VTSPositionLib functions for unit testing
/// @dev Manages its own VTSStorage that tests manipulate via setup functions
contract VTSPositionLibHarness {
    using CurrencyDelta for Currency;

    /// @notice Internal VTSStorage for testing
    VTSStorage internal s;
    BalanceDelta internal lastSettleableDelta;
    BalanceDelta internal lastQueuedDelta;
    BalanceDelta internal lastUnderlyingDeltaSettlement;
    BalanceDelta internal lastSeizureExportedForSettlementClamp;
    BalanceDelta internal lastNonSeizureExportedForSettlementClamp;
    uint256 internal lastSeizureRetainedPrincipal0;
    uint256 internal lastSeizureRetainedPrincipal1;
    int256 internal lastUnderlyingDeltaSnapshot0;
    int256 internal lastUnderlyingDeltaSnapshot1;

    // ============ Library Function Exposers ============

    /// @notice Exposes `_trackCommitment` (source-of-truth commitment maxima for live liquidity)
    function trackCommitmentFromLiveLiquidity(PositionId positionId, uint128 liveLiquidity) external {
        VTSPositionLib._trackCommitment(s, positionId, liveLiquidity);
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

    /// @notice Exposes touchPosition for targeted branch tests
    function touchPosition(PositionContext memory ctx, TouchPositionParams calldata p)
        external
        returns (TouchPositionResult memory result)
    {
        return VTSPositionLib.touchPosition(s, ctx, p);
    }

    /// @notice Alias for `touchPosition` (MM tail runs inside `touchPosition`; returned `pos` is refreshed from storage).
    function touchPositionAndFinalizeMM(PositionContext memory ctx, TouchPositionParams calldata p)
        external
        returns (TouchPositionResult memory result)
    {
        result = VTSPositionLib.touchPosition(s, ctx, p);
    }

    /// @notice Exposes onMMSettle for testing
    function onMMSettle(
        IPoolManager poolManager,
        IMarketVault vault,
        PositionId positionId,
        Currency lccCurrency0,
        Currency lccCurrency1,
        BalanceDelta delta,
        bool isSeizing,
        bool fromDeltas
    ) external returns (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiquidityUnits) {
        SettleParams memory params;
        params.vault = vault;
        params.positionId = positionId;
        params.lccCurrency0 = lccCurrency0;
        params.lccCurrency1 = lccCurrency1;
        params.delta = delta;
        params.isSeizing = isSeizing;
        params.fromDeltas = fromDeltas;
        SettleResult memory result = VTSLifecycleLinkedLib._executeMMSettleFromParams(s, poolManager, params);
        return (result.settlementDelta, result.rfsOpen, result.seizedLiquidityUnits);
    }

    function onMMSettleWithIntent(
        IPoolManager poolManager,
        IMarketVault vault,
        PositionId positionId,
        Currency lccCurrency0,
        Currency lccCurrency1,
        BalanceDelta delta,
        bool isSeizing,
        bool fromDeltas
    ) external returns (BalanceDelta, bool, uint256, VaultSettlementIntent memory) {
        SettleParams memory params = SettleParams({
            vault: vault,
            positionId: positionId,
            lccCurrency0: lccCurrency0,
            lccCurrency1: lccCurrency1,
            delta: delta,
            isSeizing: isSeizing,
            fromDeltas: fromDeltas
        });
        SettleResult memory result = VTSLifecycleLinkedLib._executeMMSettleFromParams(s, poolManager, params);
        return (result.settlementDelta, result.rfsOpen, result.seizedLiquidityUnits, result.vaultSettlementIntent);
    }

    /// @dev Mirrors removed `previewLiquidityDecreaseRouting` early-return + `_computeLiquidityDecreaseRoutingSplit`.
    function _previewLiquidityDecreaseRoutingHarness(
        PositionContext memory ctx,
        BalanceDelta principalDelta,
        BalanceDelta requiredSettlementDelta
    )
        private
        view
        returns (
            uint256 retainedPrincipal0,
            uint256 retainedPrincipal1,
            BalanceDelta settleableDelta,
            BalanceDelta queuedDelta,
            BalanceDelta underlyingDeltaSettlement
        )
    {
        BalanceDelta exportedForSettlementClampUnused;
        (
            retainedPrincipal0,
            retainedPrincipal1,
            settleableDelta,
            queuedDelta,
            underlyingDeltaSettlement,
            exportedForSettlementClampUnused
        ) = VTSPositionMMOpsLib._computeLiquidityDecreaseRoutingSplit(ctx, principalDelta, requiredSettlementDelta);
    }

    /// @notice Exposes full non-seizure MM decrease routing split (incl. `exportedForSettlementClamp` for SETTLE-03 tests).
    function previewLiquidityDecreaseRoutingSplitFull(
        PositionContext memory ctx,
        BalanceDelta principalDelta,
        BalanceDelta requiredSettlementDelta
    )
        external
        view
        returns (
            uint256 retainedPrincipal0,
            uint256 retainedPrincipal1,
            BalanceDelta settleableDelta,
            BalanceDelta queuedDelta,
            BalanceDelta underlyingDeltaSettlement,
            BalanceDelta exportedForSettlementClamp
        )
    {
        return VTSPositionMMOpsLib._computeLiquidityDecreaseRoutingSplit(ctx, principalDelta, requiredSettlementDelta);
    }

    /// @notice Vault dry-modify view: immediate settleable slice vs per-leg shortfall (shared by decrease + seizure routing).
    function previewVaultSettleableViewForRequired(PositionContext memory ctx, BalanceDelta requiredSettlementDelta)
        external
        view
        returns (BalanceDelta settleableDelta, uint256 shortfallU0, uint256 shortfallU1)
    {
        VTSPositionMMOpsLib.VaultSettleableView memory v =
            VTSPositionMMOpsLib._vaultSettleableViewForRequired(ctx, requiredSettlementDelta);
        return (v.settleableDelta, v.shortfallU0, v.shortfallU1);
    }

    /// @notice Exposes internal liquidity decrease helper for unit tests (queue clamping, settleableDelta)
    function handleLiquidityDecrease(
        PositionContext memory ctx,
        address owner,
        PoolKey calldata poolKey,
        BalanceDelta principalDelta,
        BalanceDelta requiredSettlementDelta,
        address queueRecipient
    ) external returns (BalanceDelta settleableDelta) {
        BalanceDelta exported;
        (,, settleableDelta, lastQueuedDelta, lastUnderlyingDeltaSettlement, exported) =
            VTSPositionMMOpsLib._computeLiquidityDecreaseRoutingSplit(ctx, principalDelta, requiredSettlementDelta);
        lastSettleableDelta = settleableDelta;
        lastNonSeizureExportedForSettlementClamp = exported;
        VTSPositionMMOpsLib._handleLiquidityDecrease(
            ctx, owner, poolKey, principalDelta, requiredSettlementDelta, queueRecipient
        );
        return settleableDelta;
    }

    /// @notice Exposes full liquidity decrease routing splits for unit tests (preview + same effects as production).
    function handleLiquidityDecreaseDetailed(
        PositionContext memory ctx,
        address owner,
        PoolKey calldata poolKey,
        BalanceDelta principalDelta,
        BalanceDelta requiredSettlementDelta,
        address queueRecipient
    )
        external
        returns (BalanceDelta settleableDelta, BalanceDelta queuedDelta, BalanceDelta underlyingDeltaSettlement)
    {
        BalanceDelta exported;
        (,, settleableDelta, queuedDelta, underlyingDeltaSettlement, exported) =
            VTSPositionMMOpsLib._computeLiquidityDecreaseRoutingSplit(ctx, principalDelta, requiredSettlementDelta);
        lastSettleableDelta = settleableDelta;
        lastQueuedDelta = queuedDelta;
        lastUnderlyingDeltaSettlement = underlyingDeltaSettlement;
        lastNonSeizureExportedForSettlementClamp = exported;
        VTSPositionMMOpsLib._handleLiquidityDecrease(
            ctx, owner, poolKey, principalDelta, requiredSettlementDelta, queueRecipient
        );
        return (settleableDelta, queuedDelta, underlyingDeltaSettlement);
    }

    function getLastNonSeizureExportedForSettlementClamp() external view returns (BalanceDelta) {
        return lastNonSeizureExportedForSettlementClamp;
    }

    /// @notice Preview seizure-only routing split (no Hub staging).
    function previewSeizureLiquidityDecreaseRouting(
        PositionContext memory ctx,
        BalanceDelta principalDelta,
        BalanceDelta requiredSettlementDelta
    )
        external
        view
        returns (
            uint256 retainedPrincipal0,
            uint256 retainedPrincipal1,
            BalanceDelta underlyingDeltaSettlement,
            BalanceDelta exportedForSettlementClamp
        )
    {
        return VTSPositionMMOpsLib._computeSeizureLiquidityDecreaseRoutingSplit(
            ctx, principalDelta, requiredSettlementDelta
        );
    }

    /// @notice Exposes seizure decrease helper for tests (same Hub staging as production seizure path).
    function handleSeizureLiquidityDecrease(
        PositionContext memory ctx,
        address owner,
        PoolKey calldata poolKey,
        BalanceDelta principalDelta,
        BalanceDelta requiredSettlementDelta,
        address queueRecipient
    ) external returns (BalanceDelta underlyingDeltaSettlement) {
        BalanceDelta exported;
        (lastSeizureRetainedPrincipal0, lastSeizureRetainedPrincipal1, underlyingDeltaSettlement, exported) =
            VTSPositionMMOpsLib._computeSeizureLiquidityDecreaseRoutingSplit(
                ctx, principalDelta, requiredSettlementDelta
            );
        lastSeizureExportedForSettlementClamp = exported;
        lastUnderlyingDeltaSettlement = underlyingDeltaSettlement;
        VTSPositionMMOpsLib._handleSeizureLiquidityDecrease(
            ctx, owner, poolKey, principalDelta, requiredSettlementDelta, queueRecipient
        );
        return underlyingDeltaSettlement;
    }

    function getLastSeizureRouting()
        external
        view
        returns (
            uint256 retainedPrincipal0,
            uint256 retainedPrincipal1,
            BalanceDelta exportedForSettlementClamp,
            BalanceDelta underlyingDeltaSettlement
        )
    {
        return (
            lastSeizureRetainedPrincipal0,
            lastSeizureRetainedPrincipal1,
            lastSeizureExportedForSettlementClamp,
            lastUnderlyingDeltaSettlement
        );
    }

    function getLastSeizureExportedForSettlementClamp() external view returns (BalanceDelta) {
        return lastSeizureExportedForSettlementClamp;
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
            uint256 cumulativeDeficit1,
            uint256 settledOverflow0,
            uint256 settledOverflow1
        )
    {
        PositionAccounting storage pa = s.positionAccounting[id];
        return (
            pa.commitmentMax.token0,
            pa.commitmentMax.token1,
            pa.settled.token0,
            pa.settled.token1,
            pa.cumulativeDeficit.token0,
            pa.cumulativeDeficit.token1,
            pa.settledOverflow.token0,
            pa.settledOverflow.token1
        );
    }

    function getLastLiquidityDecreasePreview()
        external
        view
        returns (BalanceDelta settleableDelta, BalanceDelta queuedDelta, BalanceDelta underlyingDeltaSettlement)
    {
        return (lastSettleableDelta, lastQueuedDelta, lastUnderlyingDeltaSettlement);
    }

    function getPosition(PositionId id) external view returns (Position memory) {
        return s.positions[id];
    }

    /// @notice TEST-ONLY: desynchronise stored liquidity from PoolManager (simulates paused remove without touchPosition)
    function setPositionLiquidityMirror(PositionId id, uint128 liquidity) external {
        s.positions[id].liquidity = liquidity;
    }

    function getCommitmentDeficit(PositionId id) external view returns (uint256 cd0, uint256 cd1) {
        return (s.positionAccounting[id].commitmentDeficit.token0, s.positionAccounting[id].commitmentDeficit.token1);
    }

    function getPoolTotalSettled(PoolId poolId) external view returns (uint256 total0, uint256 total1) {
        return (s.poolAccounting[poolId].totalSettled.token0, s.poolAccounting[poolId].totalSettled.token1);
    }

    function getPoolTotalDeficitPrincipal(PoolId poolId)
        external
        view
        returns (uint256 principal0, uint256 principal1)
    {
        return (
            s.poolAccounting[poolId].totalDeficitPrincipal.token0, s.poolAccounting[poolId].totalDeficitPrincipal.token1
        );
    }

    function getCumulativeOutflows(PositionId id) external view returns (uint256 out0, uint256 out1) {
        return (s.positionAccounting[id].cumulativeOutflows.token0, s.positionAccounting[id].cumulativeOutflows.token1);
    }

    function getDeficitGrowthInsideLast(PositionId id) external view returns (uint256 dg0, uint256 dg1) {
        return (
            s.positionAccounting[id].deficitGrowthInsideLast.token0,
            s.positionAccounting[id].deficitGrowthInsideLast.token1
        );
    }

    function getInflowGrowthInsideLast(PositionId id) external view returns (uint256 ig0, uint256 ig1) {
        return (
            s.positionAccounting[id].inflowGrowthInsideLast.token0,
            s.positionAccounting[id].inflowGrowthInsideLast.token1
        );
    }

    /// @notice Test-only: read Q128 deficit growth carries (raw `< Q128`)
    function getDeficitGrowthCarry(PositionId id) external view returns (uint256 c0, uint256 c1) {
        return (
            GrowthCarryQ128.unwrap(s.positionAccounting[id].deficitGrowthCarry.token0),
            GrowthCarryQ128.unwrap(s.positionAccounting[id].deficitGrowthCarry.token1)
        );
    }

    /// @notice Test-only: read Q128 inflow growth carries
    function getInflowGrowthCarry(PositionId id) external view returns (uint256 c0, uint256 c1) {
        return (
            GrowthCarryQ128.unwrap(s.positionAccounting[id].inflowGrowthCarry.token0),
            GrowthCarryQ128.unwrap(s.positionAccounting[id].inflowGrowthCarry.token1)
        );
    }

    /// @notice Test-only: seed carries (values reduced mod Q128)
    function setDeficitGrowthCarry(PositionId id, uint256 c0, uint256 c1) external {
        s.positionAccounting[id].deficitGrowthCarry.token0 = GrowthCarryQ128.wrap(c0 % FixedPoint128.Q128);
        s.positionAccounting[id].deficitGrowthCarry.token1 = GrowthCarryQ128.wrap(c1 % FixedPoint128.Q128);
    }

    function setInflowGrowthCarry(PositionId id, uint256 c0, uint256 c1) external {
        s.positionAccounting[id].inflowGrowthCarry.token0 = GrowthCarryQ128.wrap(c0 % FixedPoint128.Q128);
        s.positionAccounting[id].inflowGrowthCarry.token1 = GrowthCarryQ128.wrap(c1 % FixedPoint128.Q128);
    }

    /// @notice Test-only: read Q128 seizure liquidity carries per lane (raw `< Q128`)
    function getSeizureLiquidityCarry(PositionId id) external view returns (uint256 c0, uint256 c1) {
        return (
            CarryQ128.unwrap(s.positionAccounting[id].seizureLiquidityCarry.token0),
            CarryQ128.unwrap(s.positionAccounting[id].seizureLiquidityCarry.token1)
        );
    }

    /// @notice Test-only: seed seizure carries (values reduced mod Q128)
    function setSeizureLiquidityCarry(PositionId id, uint256 c0, uint256 c1) external {
        s.positionAccounting[id].seizureLiquidityCarry.token0 = CarryQ128Lib.wrap(c0);
        s.positionAccounting[id].seizureLiquidityCarry.token1 = CarryQ128Lib.wrap(c1);
    }

    function getCommitExpiresAt(uint256 commitId) external view returns (uint256 expiresAt) {
        return s.commits[commitId].expiresAt;
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

    /// @notice TEST-ONLY: sets deferred amounts above `commitmentMax`
    function setSettledOverflow(PositionId id, uint256 o0, uint256 o1) external {
        s.positionAccounting[id].settledOverflow.token0 = o0;
        s.positionAccounting[id].settledOverflow.token1 = o1;
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

    function setCommitmentDeficitBps(PositionId id, uint16 bps) external {
        s.positionAccounting[id].commitmentDeficitBps = bps;
    }

    function getCommitmentDeficitBps(PositionId id) external view returns (uint16) {
        return s.positionAccounting[id].commitmentDeficitBps;
    }

    function setCommitmentDeficitSince(PositionId id, uint256 s0, uint256 s1) external {
        s.positionAccounting[id].commitmentDeficitSince.token0 = s0;
        s.positionAccounting[id].commitmentDeficitSince.token1 = s1;
    }

    function getCommitmentDeficitSince(PositionId id) external view returns (uint256, uint256) {
        return (
            s.positionAccounting[id].commitmentDeficitSince.token0,
            s.positionAccounting[id].commitmentDeficitSince.token1
        );
    }

    function setPoolTotalSettled(PoolId poolId, uint256 total0, uint256 total1) external {
        s.poolAccounting[poolId].totalSettled.token0 = total0;
        s.poolAccounting[poolId].totalSettled.token1 = total1;
    }

    function setPoolTotalDeficitPrincipal(PoolId poolId, uint256 principal0, uint256 principal1) external {
        s.poolAccounting[poolId].totalDeficitPrincipal.token0 = principal0;
        s.poolAccounting[poolId].totalDeficitPrincipal.token1 = principal1;
    }

    function setCumulativeOutflows(PositionId id, uint256 out0, uint256 out1) external {
        s.positionAccounting[id].cumulativeOutflows.token0 = out0;
        s.positionAccounting[id].cumulativeOutflows.token1 = out1;
    }

    function setCommitExpiresAt(uint256 commitId, uint256 expiresAt) external {
        s.commits[commitId].expiresAt = expiresAt;
    }

    function setCommitActivePositionCount(uint256 commitId, uint256 activeCount) external {
        s.commits[commitId].activePositionCount = activeCount;
    }

    function getCommitActivePositionCount(uint256 commitId) external view returns (uint256) {
        return s.commits[commitId].activePositionCount;
    }

    /// @notice Test-only: reads `Commit.inactiveRemnantCount` from harness storage
    function inactiveRemnantCount(uint256 commitId) external view returns (uint256) {
        return s.commits[commitId].inactiveRemnantCount;
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

    /// @notice Sets per-tick deficit growth outside values (Uniswap-style outside accumulators)
    function setDeficitGrowthOutside(PoolId poolId, int24 tick, uint256 outside0, uint256 outside1) external {
        s.deficitGrowthOutside[poolId][tick] = GrowthPair({token0: outside0, token1: outside1});
    }

    /// @notice Sets per-tick inflow growth outside values (Uniswap-style outside accumulators)
    function setInflowGrowthOutside(PoolId poolId, int24 tick, uint256 outside0, uint256 outside1) external {
        s.inflowGrowthOutside[poolId][tick] = GrowthPair({token0: outside0, token1: outside1});
    }

    /// @notice Gets per-tick deficit growth outside values
    function getDeficitGrowthOutside(PoolId poolId, int24 tick)
        external
        view
        returns (uint256 outside0, uint256 outside1)
    {
        GrowthPair storage outside = s.deficitGrowthOutside[poolId][tick];
        return (outside.token0, outside.token1);
    }

    /// @notice Gets per-tick inflow growth outside values
    function getInflowGrowthOutside(PoolId poolId, int24 tick)
        external
        view
        returns (uint256 outside0, uint256 outside1)
    {
        GrowthPair storage outside = s.inflowGrowthOutside[poolId][tick];
        return (outside.token0, outside.token1);
    }

    /// @notice Sets position isActive state
    function setPositionActive(PositionId id, bool active) external {
        s.positions[id].isActive = active;
    }

    function setPositionCommitId(PositionId id, uint256 commitId) external {
        s.positions[id].commitId = commitId;
    }

    /// @notice Sets underlying currency delta using OwnerCurrencyDelta.accountDelta
    /// @dev Uses OwnerCurrencyDelta to match the actual implementation
    function setUnderlyingDelta(Currency currency, address target, int128 delta) external {
        OwnerCurrencyDelta.accountDelta(currency, delta, target);
    }

    function addMarketProducedCredit(IMarketVault vault, Currency currency, uint256 amount) external {
        MarketCurrencyDelta.addProduced(ICanonicalVault(vault.canonicalVault()).marketFactory(), currency, amount);
    }

    function marketProducedCredit(address factory, Currency currency) external view returns (uint256) {
        return MarketCurrencyDelta.produced(factory, currency);
    }

    /// @notice Reads the current currency delta for a target in this harness' transient storage context
    function getDelta(Currency currency, address target) external view returns (int256) {
        return currency.getDelta(target);
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

    function snapshotUnderlyingDeltaPair(Currency currency0, Currency currency1, address target)
        external
        returns (int256 delta0, int256 delta1)
    {
        delta0 = currency0.getDelta(target);
        delta1 = currency1.getDelta(target);
        lastUnderlyingDeltaSnapshot0 = delta0;
        lastUnderlyingDeltaSnapshot1 = delta1;
    }

    function getLastUnderlyingDeltaSnapshot() external view returns (int256 delta0, int256 delta1) {
        return (lastUnderlyingDeltaSnapshot0, lastUnderlyingDeltaSnapshot1);
    }
}

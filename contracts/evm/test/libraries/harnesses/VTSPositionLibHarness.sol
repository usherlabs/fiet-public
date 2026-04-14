// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {
    VTSStorage,
    MarketVTSConfiguration,
    TokenConfiguration,
    GrowthPair,
    PositionContext,
    TouchPositionParams,
    TouchPositionResult,
    SettleParams,
    SettleResult,
    VaultSettlementIntent
} from "../../../src/types/VTS.sol";
import {PositionId, Position} from "../../../src/types/Position.sol";
import {Pool} from "../../../src/types/Pool.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {VTSPositionLib} from "../../../src/libraries/VTSPositionLib.sol";
import {VTSLifecycleLinkedLib} from "../../../src/libraries/VTSLifecycleLinkedLib.sol";
import {VTSFeeLinkedLib} from "../../../src/libraries/VTSFeeLib.sol";
import {VTSCommitLib} from "../../../src/libraries/VTSCommitLib.sol";
import {RFSCheckpoint} from "../../../src/types/Checkpoint.sol";
import {IMarketVault} from "../../../src/interfaces/IMarketVault.sol";
import {OwnerCurrencyDelta} from "../../../src/libraries/OwnerCurrencyDelta.sol";
import {MarketCurrencyDelta} from "../../../src/libraries/MarketCurrencyDelta.sol";
import {ICanonicalVault} from "../../../src/interfaces/ICanonicalVault.sol";
import {CurrencyDelta} from "v4-periphery/lib/v4-core/src/libraries/CurrencyDelta.sol";

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

    /// @notice Exposes incrementCoverage for CISE/DICE routing tests (same storage as position lib)
    function incrementCoverage(PoolId poolId, uint8 tokenIndex, uint256 coveredAmount) external {
        VTSCommitLib.incrementCoverage(s, poolId, tokenIndex, coveredAmount);
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

    /// @notice Exposes internal coverage burn for direct unit testing
    /// @dev Useful to kill mutants around `_calculateFeesBurn` / `_applyCoverageBurn` and outflow-window checkpointing.
    function applyCoverageBurn(
        IPoolManager poolManager,
        PositionId positionId,
        PoolId poolId,
        uint8 tokenIndex,
        uint256 cov,
        uint128 positionLiquidity
    ) external {
        VTSFeeLinkedLib.applyCoverageBurn(s, poolManager, positionId, poolId, tokenIndex, cov, positionLiquidity);
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
        (,, settleableDelta, lastQueuedDelta, lastUnderlyingDeltaSettlement) =
            VTSPositionLib._previewLiquidityDecreaseRouting(ctx, principalDelta, requiredSettlementDelta);
        lastSettleableDelta = settleableDelta;
        VTSPositionLib._handleLiquidityDecrease(
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
        (
            ,, settleableDelta, queuedDelta, underlyingDeltaSettlement
        ) = VTSPositionLib._previewLiquidityDecreaseRouting(ctx, principalDelta, requiredSettlementDelta);
        lastSettleableDelta = settleableDelta;
        lastQueuedDelta = queuedDelta;
        lastUnderlyingDeltaSettlement = underlyingDeltaSettlement;
        VTSPositionLib._handleLiquidityDecrease(
            ctx, owner, poolKey, principalDelta, requiredSettlementDelta, queueRecipient
        );
        return (settleableDelta, queuedDelta, underlyingDeltaSettlement);
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

    function getPoolTotalSettled(PoolId poolId) external view returns (uint256 total0, uint256 total1) {
        return (s.poolAccounting[poolId].totalSettled.token0, s.poolAccounting[poolId].totalSettled.token1);
    }

    function getPoolProtocolFeeAccrued(PoolId poolId) external view returns (uint256 fee0, uint256 fee1) {
        return (s.poolAccounting[poolId].protocolFeeAccrued.token0, s.poolAccounting[poolId].protocolFeeAccrued.token1);
    }

    /// @notice TEST-ONLY: sets `protocolFeeAccrued` for both pool fee-token lanes.
    /// @dev TEST-ONLY helper that writes storage directly for unit-test scenario setup.
    function setPoolProtocolFeeAccrued(PoolId poolId, uint256 fee0, uint256 fee1) external {
        s.poolAccounting[poolId].protocolFeeAccrued.token0 = fee0;
        s.poolAccounting[poolId].protocolFeeAccrued.token1 = fee1;
    }

    function getFeesShared(PositionId id) external view returns (uint256 fee0, uint256 fee1) {
        return (s.positionAccounting[id].feesShared.token0, s.positionAccounting[id].feesShared.token1);
    }

    function getPendingFeeAdj(PositionId id) external view returns (int256 adj0, int256 adj1) {
        return (s.positionAccounting[id].pendingFeeAdj.token0, s.positionAccounting[id].pendingFeeAdj.token1);
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

    function getPoolCoverageResidualDICE(PoolId poolId) external view returns (uint256 residual0, uint256 residual1) {
        return
            (s.poolAccounting[poolId].coverageResidualDICE.token0, s.poolAccounting[poolId].coverageResidualDICE.token1);
    }

    function getPoolCoveragePerSettledIndexX128(PoolId poolId) external view returns (uint256 idx0, uint256 idx1) {
        return (
            s.poolAccounting[poolId].coveragePerSettledIndexX128.token0,
            s.poolAccounting[poolId].coveragePerSettledIndexX128.token1
        );
    }

    function setPoolCoveragePerSettledIndexX128(PoolId poolId, uint256 idx0, uint256 idx1) external {
        s.poolAccounting[poolId].coveragePerSettledIndexX128.token0 = idx0;
        s.poolAccounting[poolId].coveragePerSettledIndexX128.token1 = idx1;
    }

    function getPoolCoveragePerDeficitIndexX128(PoolId poolId) external view returns (uint256 idx0, uint256 idx1) {
        return (
            s.poolAccounting[poolId].coveragePerDeficitIndexX128.token0,
            s.poolAccounting[poolId].coveragePerDeficitIndexX128.token1
        );
    }

    function getPoolCoveragePerResidualDeficitIndexX128(PoolId poolId)
        external
        view
        returns (uint256 idx0, uint256 idx1)
    {
        return (
            s.poolAccounting[poolId].coveragePerResidualDeficitIndexX128.token0,
            s.poolAccounting[poolId].coveragePerResidualDeficitIndexX128.token1
        );
    }

    function getCoverageIndexLastX128(PositionId id) external view returns (uint256 idx0, uint256 idx1) {
        return
            (
                s.positionAccounting[id].coverageIndexLastX128.token0,
                s.positionAccounting[id].coverageIndexLastX128.token1
            );
    }

    function getResidualCoverageIndexLastX128(PositionId id) external view returns (uint256 idx0, uint256 idx1) {
        return (
            s.positionAccounting[id].residualCoverageIndexLastX128.token0,
            s.positionAccounting[id].residualCoverageIndexLastX128.token1
        );
    }

    function getPendingResidualBurnBase(PositionId id) external view returns (uint256 burn0, uint256 burn1) {
        return (
            s.positionAccounting[id].pendingResidualBurnBase.token0,
            s.positionAccounting[id].pendingResidualBurnBase.token1
        );
    }

    function getPendingResidualFeeBacking(PositionId id) external view returns (uint256 fee0, uint256 fee1) {
        return (
            s.positionAccounting[id].pendingResidualFeeBacking.token0,
            s.positionAccounting[id].pendingResidualFeeBacking.token1
        );
    }

    function getPendingResidualBurnOutflowsFloor(PositionId id) external view returns (uint256 floor0, uint256 floor1) {
        return (
            s.positionAccounting[id].pendingResidualBurnOutflowsFloor.token0,
            s.positionAccounting[id].pendingResidualBurnOutflowsFloor.token1
        );
    }

    function getCISEIndexLastX128(PositionId id) external view returns (uint256 idx0, uint256 idx1) {
        return (s.positionAccounting[id].ciseIndexLastX128.token0, s.positionAccounting[id].ciseIndexLastX128.token1);
    }

    function getCumulativeOutflows(PositionId id) external view returns (uint256 out0, uint256 out1) {
        return (s.positionAccounting[id].cumulativeOutflows.token0, s.positionAccounting[id].cumulativeOutflows.token1);
    }

    function getOutflowsAtFeeSnap(PositionId id) external view returns (uint256 snap0, uint256 snap1) {
        return (s.positionAccounting[id].outflowsAtFeeSnap.token0, s.positionAccounting[id].outflowsAtFeeSnap.token1);
    }

    function getFeeGrowthInsideLast(PositionId id) external view returns (uint256 fg0, uint256 fg1) {
        return
            (s.positionAccounting[id].feeGrowthInsideLast.token0, s.positionAccounting[id].feeGrowthInsideLast.token1);
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

    function setPoolTotalSettled(PoolId poolId, uint256 total0, uint256 total1) external {
        s.poolAccounting[poolId].totalSettled.token0 = total0;
        s.poolAccounting[poolId].totalSettled.token1 = total1;
    }

    function setPoolTotalDeficitPrincipal(PoolId poolId, uint256 principal0, uint256 principal1) external {
        s.poolAccounting[poolId].totalDeficitPrincipal.token0 = principal0;
        s.poolAccounting[poolId].totalDeficitPrincipal.token1 = principal1;
    }

    function setPoolCoverageResidualDICE(PoolId poolId, uint256 residual0, uint256 residual1) external {
        s.poolAccounting[poolId].coverageResidualDICE.token0 = residual0;
        s.poolAccounting[poolId].coverageResidualDICE.token1 = residual1;
    }

    function setPoolCoveragePerDeficitIndexX128(PoolId poolId, uint256 idx0, uint256 idx1) external {
        s.poolAccounting[poolId].coveragePerDeficitIndexX128.token0 = idx0;
        s.poolAccounting[poolId].coveragePerDeficitIndexX128.token1 = idx1;
    }

    function setPoolCoveragePerResidualDeficitIndexX128(PoolId poolId, uint256 idx0, uint256 idx1) external {
        s.poolAccounting[poolId].coveragePerResidualDeficitIndexX128.token0 = idx0;
        s.poolAccounting[poolId].coveragePerResidualDeficitIndexX128.token1 = idx1;
    }

    function setCoverageIndexLastX128(PositionId id, uint256 idx0, uint256 idx1) external {
        s.positionAccounting[id].coverageIndexLastX128.token0 = idx0;
        s.positionAccounting[id].coverageIndexLastX128.token1 = idx1;
    }

    function setResidualCoverageIndexLastX128(PositionId id, uint256 idx0, uint256 idx1) external {
        s.positionAccounting[id].residualCoverageIndexLastX128.token0 = idx0;
        s.positionAccounting[id].residualCoverageIndexLastX128.token1 = idx1;
    }

    function setPendingResidualBurnBase(PositionId id, uint256 burn0, uint256 burn1) external {
        s.positionAccounting[id].pendingResidualBurnBase.token0 = burn0;
        s.positionAccounting[id].pendingResidualBurnBase.token1 = burn1;
    }

    function setPendingResidualFeeBacking(PositionId id, uint256 fee0, uint256 fee1) external {
        s.positionAccounting[id].pendingResidualFeeBacking.token0 = fee0;
        s.positionAccounting[id].pendingResidualFeeBacking.token1 = fee1;
    }

    function setPendingResidualBurnOutflowsFloor(PositionId id, uint256 floor0, uint256 floor1) external {
        s.positionAccounting[id].pendingResidualBurnOutflowsFloor.token0 = floor0;
        s.positionAccounting[id].pendingResidualBurnOutflowsFloor.token1 = floor1;
    }

    function setCISEIndexLastX128(PositionId id, uint256 idx0, uint256 idx1) external {
        s.positionAccounting[id].ciseIndexLastX128.token0 = idx0;
        s.positionAccounting[id].ciseIndexLastX128.token1 = idx1;
    }

    function setCumulativeOutflows(PositionId id, uint256 out0, uint256 out1) external {
        s.positionAccounting[id].cumulativeOutflows.token0 = out0;
        s.positionAccounting[id].cumulativeOutflows.token1 = out1;
    }

    function setOutflowsAtFeeSnap(PositionId id, uint256 snap0, uint256 snap1) external {
        s.positionAccounting[id].outflowsAtFeeSnap.token0 = snap0;
        s.positionAccounting[id].outflowsAtFeeSnap.token1 = snap1;
    }

    function setFeeGrowthInsideLast(PositionId id, uint256 fg0, uint256 fg1) external {
        s.positionAccounting[id].feeGrowthInsideLast.token0 = fg0;
        s.positionAccounting[id].feeGrowthInsideLast.token1 = fg1;
        s.positionAccounting[id].feeBurnGrowthRemainder.token0 = 0;
        s.positionAccounting[id].feeBurnGrowthRemainder.token1 = 0;
    }

    /// @notice TEST-ONLY: set fee-burn remainder (used to assert touchPosition clears it on liquidity change)
    function setFeeBurnGrowthRemainder(PositionId id, uint256 r0, uint256 r1) external {
        s.positionAccounting[id].feeBurnGrowthRemainder.token0 = r0;
        s.positionAccounting[id].feeBurnGrowthRemainder.token1 = r1;
    }

    function getFeeBurnGrowthRemainder(PositionId id) external view returns (uint256 r0, uint256 r1) {
        return (
            s.positionAccounting[id].feeBurnGrowthRemainder.token0,
            s.positionAccounting[id].feeBurnGrowthRemainder.token1
        );
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

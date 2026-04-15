// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSLifecycleLinkedLib} from "../../../src/libraries/VTSLifecycleLinkedLib.sol";
import {VTSCommitLib} from "../../../src/libraries/VTSCommitLib.sol";
import {VTSPositionLib} from "../../../src/libraries/VTSPositionLib.sol";
import {
    VTSStorage,
    VTSLifecycleContext,
    VTSCoreHookContext,
    VTSCommitRouterContext,
    SettleResult
} from "../../../src/types/VTS.sol";
import {PositionId, Position} from "../../../src/types/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {RFSCheckpoint} from "../../../src/types/Checkpoint.sol";
import {IMarketFactory} from "../../../src/interfaces/IMarketFactory.sol";
import {Pool} from "../../../src/types/Pool.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MarketMaker} from "../../../src/libraries/MarketMaker.sol";
import {VTSConfigs} from "../../../src/libraries/VTSConfigs.sol";

/// @title VTSLifecycleLinkedLibHarness
/// @notice Delegates to VTSLifecycleLinkedLib against isolated `VTSStorage` for unit tests
contract VTSLifecycleLinkedLibHarness {
    VTSStorage internal s;

    function checkpoint(VTSLifecycleContext memory ctx, uint256 commitId, bool withCommitment, PositionId positionId)
        external
        returns (RFSCheckpoint memory)
    {
        return withCommitment
            ? VTSCommitLib.checkpointAfterGrowthWithCommitment(s, ctx, commitId, positionId)
            : VTSLifecycleLinkedLib.checkpointAfterGrowthNoCommitment(s, ctx, commitId, positionId);
    }

    /// @notice TEST-ONLY helper for legacy flows that still want pre-settlement before checkpointing.
    function settleThenCheckpoint(
        VTSLifecycleContext memory ctx,
        uint256 commitId,
        bool withCommitment,
        PositionId positionId
    ) external returns (RFSCheckpoint memory) {
        VTSPositionLib.settlePositionGrowths(s, ctx.poolManager, positionId);
        return withCommitment
            ? VTSCommitLib.checkpointAfterGrowthWithCommitment(s, ctx, commitId, positionId)
            : VTSLifecycleLinkedLib.checkpointAfterGrowthNoCommitment(s, ctx, commitId, positionId);
    }

    function extendGracePeriod(
        VTSLifecycleContext memory ctx,
        PoolKey memory poolKey,
        PositionId positionId,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) external returns (RFSCheckpoint memory) {
        return VTSCommitLib.extendGracePeriod(
            s, ctx, poolKey, positionId, settlementTokenIndex, verifierIndex, settlementProof
        );
    }

    function validateSeize(
        VTSLifecycleContext memory ctx,
        uint256 commitId,
        uint256 positionIndex,
        PositionId positionId
    ) external {
        VTSCommitLib.validateSeize(s, ctx, commitId, positionIndex, positionId);
    }

    function onMMSettle(
        VTSLifecycleContext memory ctx,
        IMarketFactory factory,
        PositionId positionId,
        PoolId poolId,
        BalanceDelta amountDelta,
        bool isSeizing,
        bool fromDeltas
    ) external returns (SettleResult memory) {
        return VTSLifecycleLinkedLib.onMMSettle(s, ctx, factory, positionId, poolId, amountDelta, isSeizing, fromDeltas);
    }

    function validateMMOperation(
        VTSCoreHookContext memory ctx,
        address owner,
        PoolKey calldata poolKey,
        bytes calldata hookData
    ) external view returns (bool) {
        return VTSLifecycleLinkedLib.validateMMOperation(s, ctx, owner, poolKey, hookData);
    }

    function processPosition(
        VTSCoreHookContext memory ctx,
        address owner,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata params,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (Position memory pos, PositionId id, BalanceDelta feeAdj) {
        return VTSLifecycleLinkedLib.processPosition(s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData);
    }

    function commitSignal(
        VTSCommitRouterContext memory ctx,
        IMarketFactory factory,
        address caller,
        address sender,
        bytes memory liquiditySignal
    ) external returns (uint256 commitId) {
        return VTSCommitLib.commitSignal(s, ctx, factory, caller, sender, liquiditySignal);
    }

    function commitSignalRelayed(
        VTSCommitRouterContext memory ctx,
        IMarketFactory factory,
        address caller,
        address sender,
        bytes memory liquiditySignal,
        uint256 deadline,
        uint256 authNonce,
        bytes memory authSig
    ) external returns (uint256 commitId) {
        return VTSCommitLib.commitSignalRelayed(
            s, ctx, factory, caller, sender, liquiditySignal, deadline, authNonce, authSig
        );
    }

    function renewSignal(
        VTSCommitRouterContext memory ctx,
        IMarketFactory factory,
        address caller,
        address sender,
        uint256 commitId,
        bytes memory liquiditySignal
    ) external {
        VTSCommitLib.renewSignal(s, ctx, factory, caller, sender, commitId, liquiditySignal);
    }

    function renewSignalRelayed(
        VTSCommitRouterContext memory ctx,
        IMarketFactory factory,
        address caller,
        address sender,
        uint256 commitId,
        bytes memory liquiditySignal,
        uint256 deadline,
        uint256 authNonce,
        bytes memory authSig
    ) external {
        VTSCommitLib.renewSignalRelayed(
            s, ctx, factory, caller, sender, commitId, liquiditySignal, deadline, authNonce, authSig
        );
    }

    /// @dev TEST-ONLY: minimal commit state for validateMMOperation / signal validity tests
    function testSeedCommit(uint256 commitId, address owner_, address advancer_, uint256 expiresAt) external {
        MarketMaker.State storage st = s.commits[commitId].mmState;
        delete st.reserves;
        st.owner = owner_;
        st.advancer = advancer_;
        st.reserves.push(MarketMaker.Reserve({asset: "x", amount: 1}));
        s.commits[commitId].expiresAt = expiresAt;
    }

    function testSeedPool(PoolId poolId, Currency c0, Currency c1) external {
        s.pools[poolId] =
            Pool({currency0: c0, currency1: c1, vtsConfig: VTSConfigs.getDefaultConfig(), isPaused: false});
    }

    function testSeedPosition(PositionId pid, address owner_, PoolId poolId_, uint256 commitId_, bool active) external {
        s.positions[pid] = Position({
            owner: owner_,
            poolId: poolId_,
            commitId: commitId_,
            tickLower: 0,
            tickUpper: 0,
            liquidity: 0,
            isActive: active,
            salt: bytes32(0),
            checkpoint: RFSCheckpoint({
                openMask: 0, openSince0: 0, openSince1: 0, gracePeriodExtension0: 0, gracePeriodExtension1: 0
            })
        });
    }

    function testSetCheckpoint(
        PositionId pid,
        uint8 openMask,
        uint256 openSince0,
        uint256 openSince1,
        uint256 gracePeriodExtension0,
        uint256 gracePeriodExtension1
    ) external {
        s.positions[pid].checkpoint = RFSCheckpoint({
            openMask: openMask,
            openSince0: openSince0,
            openSince1: openSince1,
            gracePeriodExtension0: gracePeriodExtension0,
            gracePeriodExtension1: gracePeriodExtension1
        });
    }

    function testLinkCommitPosition(uint256 commitId, uint256 positionIndex, PositionId pid) external {
        s.commits[commitId].positions[positionIndex] = pid;
    }

    function testSetCommitmentDeficit(PositionId pid, uint256 d0, uint256 d1) external {
        s.positionAccounting[pid].commitmentDeficit.token0 = d0;
        s.positionAccounting[pid].commitmentDeficit.token1 = d1;
    }

    function testSetCommitmentMax(PositionId pid, uint256 c0, uint256 c1) external {
        s.positionAccounting[pid].commitmentMax.token0 = c0;
        s.positionAccounting[pid].commitmentMax.token1 = c1;
    }

    function getCommitMMOwner(uint256 commitId) external view returns (address) {
        return s.commits[commitId].mmState.owner;
    }

    function getCommitExpiresAt(uint256 commitId) external view returns (uint256) {
        return s.commits[commitId].expiresAt;
    }
}

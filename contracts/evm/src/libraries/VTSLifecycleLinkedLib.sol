// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {
    VTSStorage,
    VTSLifecycleContext,
    VTSCoreHookContext,
    VTSCommitRouterContext,
    PositionContext,
    TouchPositionParams,
    TouchPositionResult,
    SettleParams,
    SettleResult
} from "../types/VTS.sol";
import {
    PositionId,
    Position,
    PositionModificationHookData,
    PositionModificationHookDataLib
} from "../types/Position.sol";
import {Commit} from "../types/Commit.sol";
import {Pool} from "../types/Pool.sol";
import {RFSCheckpoint} from "../types/Checkpoint.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {IMarketVault} from "../interfaces/IMarketVault.sol";
import {VTSPositionLib} from "./VTSPositionLib.sol";
import {VTSCommitLib} from "./VTSCommitLib.sol";
import {CheckpointLibrary} from "./Checkpoint.sol";
import {MarketHandlerLib} from "./MarketHandlerLib.sol";
import {MarketMaker} from "./MarketMaker.sol";
import {Errors} from "./Errors.sol";
import {PositionLibrary} from "../types/Position.sol";

/// @title VTSLifecycleLinkedLib
/// @notice Linked orchestration entrypoints for orchestrator lifecycle, CoreHook, and commit-routing paths.
library VTSLifecycleLinkedLib {
    using PoolIdLibrary for PoolKey;

    function _assertRegisteredFactory(VTSCommitRouterContext memory ctx, IMarketFactory factory) internal view {
        if (!ctx.liquidityHub.isFactory(address(factory))) revert Errors.InvalidSender();
    }

    function _resolveSignalSender(
        VTSCommitRouterContext memory ctx,
        IMarketFactory factory,
        address caller,
        address sender
    ) internal view returns (address effectiveSender) {
        _assertRegisteredFactory(ctx, factory);
        if (MarketHandlerLib.isBounds(factory, caller)) {
            return sender;
        }
        if (sender != caller) revert Errors.InvalidSender();
        return caller;
    }

    function _isSignalValid(VTSStorage storage s, uint256 commitId, bool requireLiveSignal)
        internal
        view
        returns (bool isValid)
    {
        if (commitId == 0) return false;

        Commit storage commit = s.commits[commitId];
        if (commit.expiresAt == 0) return false;

        MarketMaker.State storage mmState = commit.mmState;
        if (mmState.owner == address(0)) return false;
        if (mmState.reserves.length == 0) return false;

        if (requireLiveSignal && block.timestamp >= commit.expiresAt) return false;

        return true;
    }

    function _assertPositionValid(VTSStorage storage s, PositionId id, bool requireActive, PoolId poolId)
        internal
        view
    {
        Position memory pos = s.positions[id];
        if (pos.owner == address(0)) revert Errors.InvalidPosition(0, 0, id);
        if (requireActive && !pos.isActive) revert Errors.InvalidPosition(0, 0, id);
        if (PoolId.unwrap(pos.poolId) != PoolId.unwrap(poolId)) revert Errors.InvalidPosition(0, 0, id);
    }

    function _resolveVault(VTSCoreHookContext memory ctx, PoolKey calldata poolKey)
        internal
        view
        returns (IMarketVault)
    {
        IMarketFactory factory = ctx.liquidityHub
            .getFactory(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
        return MarketHandlerLib.getVault(factory, poolKey.toId());
    }

    function _executeTouchPosition(
        VTSStorage storage s,
        VTSCoreHookContext memory ctx,
        address owner,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata params,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) private returns (TouchPositionResult memory result) {
        PositionContext memory positionCtx = PositionContext({
            poolManager: ctx.poolManager,
            liquidityHub: ctx.liquidityHub,
            oracleHelper: ctx.oracleHelper,
            marketVault: _resolveVault(ctx, poolKey)
        });

        TouchPositionParams memory tpParams = TouchPositionParams({
            owner: owner,
            poolKey: poolKey,
            params: params,
            callerDelta: callerDelta,
            feesAccrued: feesAccrued,
            hookData: hookData
        });

        result = VTSPositionLib.touchPosition(s, positionCtx, tpParams);
    }

    function _buildMMSettleParams(
        VTSStorage storage s,
        VTSLifecycleContext memory ctx,
        IMarketFactory factory,
        PositionId positionId,
        PoolId poolId,
        BalanceDelta amountDelta,
        bool isSeizing
    ) internal view returns (SettleParams memory params) {
        Pool memory pool = s.pools[poolId];
        Currency currency0 = pool.currency0;
        Currency currency1 = pool.currency1;
        IMarketFactory canonicalFactory =
            ctx.liquidityHub.getFactory(Currency.unwrap(currency0), Currency.unwrap(currency1));
        if (address(canonicalFactory) != address(factory)) revert Errors.InvalidSender();

        params = SettleParams({
            vault: MarketHandlerLib.getVault(factory, poolId),
            positionId: positionId,
            lccCurrency0: currency0,
            lccCurrency1: currency1,
            delta: amountDelta,
            isSeizing: isSeizing
        });
    }

    /// @dev Commitment backing (optional) plus RFS checkpoint marking from current stored accounting.
    ///      Caller must have settled position growths first when pause gating matters (e.g. via
    ///      `VTSOrchestrator.settlePositionGrowths`).
    function _checkpointAfterGrowthSettled(
        VTSStorage storage s,
        VTSLifecycleContext memory ctx,
        uint256 commitId,
        bool withCommitment,
        PositionId positionId
    ) private returns (RFSCheckpoint memory checkpointOut) {
        if (withCommitment) {
            VTSCommitLib.checkpointWithCommitment(s, ctx.poolManager, ctx.oracleHelper, commitId, positionId);
        }
        (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, positionId);
        CheckpointLibrary.markCheckpoint(s, positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
        checkpointOut = s.positions[positionId].checkpoint;
    }

    /// @notice Optional commitment backing check, then mark the RFS checkpoint from current state
    /// @dev Does not settle growths. The orchestrator must call `settlePositionGrowths` first so pause policy applies.
    function checkpoint(
        VTSStorage storage s,
        VTSLifecycleContext memory ctx,
        uint256 commitId,
        bool withCommitment,
        PositionId positionId
    ) external returns (RFSCheckpoint memory checkpointOut) {
        checkpointOut = _checkpointAfterGrowthSettled(s, ctx, commitId, withCommitment, positionId);
    }

    function extendGracePeriod(
        VTSStorage storage s,
        VTSLifecycleContext memory ctx,
        PoolKey memory poolKey,
        PositionId positionId,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) external returns (RFSCheckpoint memory checkpointOut) {
        VTSPositionLib.settlePositionGrowths(s, ctx.poolManager, positionId);
        (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, positionId);
        CheckpointLibrary.markCheckpoint(s, positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
        CheckpointLibrary.extendGracePeriod(
            s, ctx.settlementObserver, poolKey, positionId, settlementTokenIndex, verifierIndex, settlementProof
        );
        checkpointOut = s.positions[positionId].checkpoint;
    }

    function validateSeize(
        VTSStorage storage s,
        VTSLifecycleContext memory ctx,
        uint256 commitId,
        uint256 positionIndex,
        PositionId positionId
    ) external {
        bool hasStoredCommitmentDeficit = s.positionAccounting[positionId].commitmentDeficit.token0 > 0
            || s.positionAccounting[positionId].commitmentDeficit.token1 > 0;
        if (hasStoredCommitmentDeficit) {
            VTSPositionLib.settlePositionGrowths(s, ctx.poolManager, positionId);
            _checkpointAfterGrowthSettled(s, ctx, commitId, true, positionId);
        }

        CheckpointLibrary.isSeizable(s, commitId, positionIndex, true);
    }

    function onMMSettle(
        VTSStorage storage s,
        VTSLifecycleContext memory ctx,
        IMarketFactory factory,
        PositionId positionId,
        PoolId poolId,
        BalanceDelta amountDelta,
        bool isSeizing
    ) external returns (SettleResult memory result) {
        SettleParams memory params = _buildMMSettleParams(s, ctx, factory, positionId, poolId, amountDelta, isSeizing);
        result = VTSPositionLib.onMMSettle(s, ctx.poolManager, params);
    }

    function validateMMOperation(
        VTSStorage storage s,
        VTSCoreHookContext memory ctx,
        address owner,
        PoolKey calldata poolKey,
        bytes calldata hookData
    ) external view returns (bool isMMPosition) {
        PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
        if (!PositionModificationHookDataLib.isMMOperation(mmData)) {
            return false;
        }

        if (!_isSignalValid(s, mmData.commitId, !mmData.seizure.isSeizing)) {
            revert Errors.InvalidSignal(mmData.commitId);
        }

        IMarketFactory factory =
            ctx.liquidityHub.getFactory(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
        if (!MarketHandlerLib.isBounds(factory, owner)) revert Errors.InvalidSender();

        if (!mmData.seizure.isSeizing) {
            address locker = PositionModificationHookDataLib.getLocker(mmData);
            if (locker != s.commits[mmData.commitId].mmState.advancer) {
                revert Errors.InvalidSender();
            }
        }

        return true;
    }

    function processPosition(
        VTSStorage storage s,
        VTSCoreHookContext memory ctx,
        address owner,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata params,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (Position memory pos, PositionId id, BalanceDelta feeAdj) {
        PositionId expectedId = PositionLibrary.generateId(owner, params);
        if (s.positions[expectedId].owner != address(0)) {
            _assertPositionValid(s, expectedId, false, poolKey.toId());
        }

        TouchPositionResult memory result =
            _executeTouchPosition(s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData);
        pos = result.pos;
        id = result.id;
        feeAdj = result.feeAdj;
    }

    function commitSignal(
        VTSStorage storage s,
        VTSCommitRouterContext memory ctx,
        IMarketFactory factory,
        address caller,
        address sender,
        bytes memory liquiditySignal
    ) external returns (uint256 commitId) {
        address effectiveSender = _resolveSignalSender(ctx, factory, caller, sender);
        commitId = VTSCommitLib.commitSignal(s, effectiveSender, ctx.signalManager, liquiditySignal);
    }

    function commitSignalRelayed(
        VTSStorage storage s,
        VTSCommitRouterContext memory ctx,
        IMarketFactory factory,
        address caller,
        address sender,
        bytes memory liquiditySignal,
        uint256 deadline,
        uint256 authNonce,
        bytes memory authSig
    ) external returns (uint256 commitId) {
        address effectiveSender = _resolveSignalSender(ctx, factory, caller, sender);
        commitId = VTSCommitLib.commitSignalRelayed(
            s, effectiveSender, ctx.signalManager, liquiditySignal, deadline, authNonce, authSig
        );
    }

    function renewSignal(
        VTSStorage storage s,
        VTSCommitRouterContext memory ctx,
        IMarketFactory factory,
        address caller,
        address sender,
        uint256 commitId,
        bytes memory liquiditySignal
    ) external {
        address effectiveSender = _resolveSignalSender(ctx, factory, caller, sender);
        VTSCommitLib.renewSignal(s, effectiveSender, ctx.signalManager, commitId, liquiditySignal);
    }

    function renewSignalRelayed(
        VTSStorage storage s,
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
        address effectiveSender = _resolveSignalSender(ctx, factory, caller, sender);
        VTSCommitLib.renewSignalRelayed(
            s, effectiveSender, ctx.signalManager, commitId, liquiditySignal, deadline, authNonce, authSig
        );
    }
}

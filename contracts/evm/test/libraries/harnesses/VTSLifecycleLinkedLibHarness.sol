// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSLifecycleLinkedLib} from "../../../src/libraries/VTSLifecycleLinkedLib.sol";
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
        return VTSLifecycleLinkedLib.checkpoint(s, ctx, commitId, withCommitment, positionId);
    }

    function extendGracePeriod(
        VTSLifecycleContext memory ctx,
        PoolKey memory poolKey,
        PositionId positionId,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) external returns (RFSCheckpoint memory) {
        return VTSLifecycleLinkedLib.extendGracePeriod(
            s, ctx, poolKey, positionId, settlementTokenIndex, verifierIndex, settlementProof
        );
    }

    function validateSeize(
        VTSLifecycleContext memory ctx,
        uint256 commitId,
        uint256 positionIndex,
        PositionId positionId
    ) external {
        VTSLifecycleLinkedLib.validateSeize(s, ctx, commitId, positionIndex, positionId);
    }

    function onMMSettle(
        VTSLifecycleContext memory ctx,
        IMarketFactory factory,
        PositionId positionId,
        PoolId poolId,
        BalanceDelta amountDelta,
        bool isSeizing
    ) external returns (SettleResult memory) {
        return VTSLifecycleLinkedLib.onMMSettle(s, ctx, factory, positionId, poolId, amountDelta, isSeizing);
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
        return VTSLifecycleLinkedLib.commitSignal(s, ctx, factory, caller, sender, liquiditySignal);
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
        return VTSLifecycleLinkedLib.commitSignalRelayed(
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
        VTSLifecycleLinkedLib.renewSignal(s, ctx, factory, caller, sender, commitId, liquiditySignal);
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
        VTSLifecycleLinkedLib.renewSignalRelayed(
            s, ctx, factory, caller, sender, commitId, liquiditySignal, deadline, authNonce, authSig
        );
    }

    /// @dev TEST-ONLY: minimal commit state for validateMMOperation / signal validity tests
    function testSeedCommit(uint256 commitId, address owner_, address advancer_, uint256 expiresAt) external {
        MarketMaker.State storage st = s.commits[commitId].mmState;
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

    function testLinkCommitPosition(uint256 commitId, uint256 positionIndex, PositionId pid) external {
        s.commits[commitId].positions[positionIndex] = pid;
    }

    function testSetCommitmentDeficit(PositionId pid, uint256 d0, uint256 d1) external {
        s.positionAccounting[pid].commitmentDeficit.token0 = d0;
        s.positionAccounting[pid].commitmentDeficit.token1 = d1;
    }

    function getCommitMMOwner(uint256 commitId) external view returns (address) {
        return s.commits[commitId].mmState.owner;
    }

    function getCommitExpiresAt(uint256 commitId) external view returns (uint256) {
        return s.commits[commitId].expiresAt;
    }
}

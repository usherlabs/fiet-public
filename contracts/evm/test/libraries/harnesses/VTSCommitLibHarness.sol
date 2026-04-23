// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSCommitLib} from "../../../src/libraries/VTSCommitLib.sol";
import {VTSStorage, MarketVTSConfiguration, TokenConfiguration} from "../../../src/types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Pool} from "../../../src/types/Pool.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionId, Position} from "../../../src/types/Position.sol";
import {RFSCheckpoint} from "../../../src/types/Checkpoint.sol";
import {IVRLSignalManager} from "../../../src/interfaces/IVRLSignalManager.sol";
import {IOracleHelper} from "../../../src/interfaces/IOracleHelper.sol";
import {MarketMaker} from "../../../src/libraries/MarketMaker.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";

/// @title VTSCommitLibHarness
/// @notice Exposes VTSCommitLib functions for unit testing with an isolated VTSStorage
contract VTSCommitLibHarness {
    using StateLibrary for IPoolManager;

    VTSStorage internal s;

    // ============ Library Function Exposers ============

    function validateLiquidityDelta(
        IOracleHelper oracleHelper,
        uint256 commitId,
        PositionId positionId,
        VTSCommitLib.LiquidityDeltaParams memory params,
        bool revertIfInsufficientBacking
    ) external view returns (bool, uint256, uint256, uint256) {
        return VTSCommitLib.validateLiquidityDelta(
            s, oracleHelper, commitId, positionId, params, revertIfInsufficientBacking
        );
    }

    function validateLiquidityDelta(
        IOracleHelper oracleHelper,
        uint256 commitId,
        PositionId positionId,
        VTSCommitLib.LiquidityDeltaParams memory params,
        uint128 preAddLiquidity,
        uint256 mintAmount0,
        uint256 mintAmount1,
        bool revertIfInsufficientBacking
    ) external view returns (bool, uint256, uint256, uint256) {
        return VTSCommitLib.validateLiquidityDelta(
            s,
            oracleHelper,
            commitId,
            positionId,
            params,
            preAddLiquidity,
            mintAmount0,
            mintAmount1,
            revertIfInsufficientBacking
        );
    }

    function commitSignal(IVRLSignalManager mgr, address sender, IOracleHelper oracleHelper, bytes memory sig)
        external
        returns (uint256)
    {
        return VTSCommitLib._commitSignalLinked(s, sender, mgr, oracleHelper, sig, address(this));
    }

    function renewSignal(IVRLSignalManager mgr, IOracleHelper oracleHelper, uint256 commitId, bytes memory sig)
        external
    {
        VTSCommitLib._renewSignalLinked(s, msg.sender, mgr, oracleHelper, commitId, sig);
    }

    /// @dev TEST-ONLY: overwrite stored commit MM state (e.g. to simulate legacy unpriceable storage).
    function setCommitMmState(uint256 commitId, MarketMaker.State memory mm) external {
        MarketMaker.save(s.commits[commitId].mmState, mm);
    }

    /// @dev TEST-ONLY: read stored commit MM state (e.g. for metadata bloat regressions).
    function getCommitMmState(uint256 commitId) external view returns (MarketMaker.State memory) {
        return s.commits[commitId].mmState;
    }

    function checkpoint(IPoolManager poolManager, IOracleHelper oracleHelper, uint256 commitId, PositionId positionId)
        external
    {
        VTSCommitLib._checkpointWithCommitment(s, poolManager, oracleHelper, commitId, positionId);
    }

    // ============ Storage Setters (for test setup) ============

    function setupPool(PoolId poolId, Currency currency0, Currency currency1) external {
        s.pools[poolId] = Pool({currency0: currency0, currency1: currency1, vtsConfig: _emptyConfig(), isPaused: false});
    }

    function setupPosition(
        PositionId id,
        PoolId poolId,
        uint256 commitId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external {
        s.positions[id] = Position({
            owner: address(this),
            poolId: poolId,
            commitId: commitId,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            isActive: true,
            salt: bytes32(0),
            checkpoint: RFSCheckpoint({
                openMask: 0, openSince0: 0, openSince1: 0, gracePeriodExtension0: 0, gracePeriodExtension1: 0
            })
        });
    }

    function setPositionSettled(PositionId id, uint256 settled0, uint256 settled1) external {
        s.positionAccounting[id].settled.token0 = settled0;
        s.positionAccounting[id].settled.token1 = settled1;
    }

    function setPositionSettledOverflow(PositionId id, uint256 overflow0, uint256 overflow1) external {
        s.positionAccounting[id].settledOverflow.token0 = overflow0;
        s.positionAccounting[id].settledOverflow.token1 = overflow1;
    }

    function setPositionCommitmentDeficit(PositionId id, uint256 deficit0, uint256 deficit1) external {
        s.positionAccounting[id].commitmentDeficit.token0 = deficit0;
        s.positionAccounting[id].commitmentDeficit.token1 = deficit1;
    }

    function setPositionCommitmentDeficitSince(PositionId id, uint256 since0, uint256 since1) external {
        s.positionAccounting[id].commitmentDeficitSince.token0 = since0;
        s.positionAccounting[id].commitmentDeficitSince.token1 = since1;
    }

    function setCommitExpiresAt(uint256 commitId, uint256 expiresAt) external {
        s.commits[commitId].expiresAt = expiresAt;
    }

    function setPoolTotalDeficitPrincipal(PoolId poolId, uint8 tokenIndex, uint256 v) external {
        if (tokenIndex == 0) s.poolAccounting[poolId].totalDeficitPrincipal.token0 = v;
        else s.poolAccounting[poolId].totalDeficitPrincipal.token1 = v;
    }

    function setPoolTotalSettled(PoolId poolId, uint8 tokenIndex, uint256 v) external {
        if (tokenIndex == 0) s.poolAccounting[poolId].totalSettled.token0 = v;
        else s.poolAccounting[poolId].totalSettled.token1 = v;
    }

    // ============ Storage Getters (for assertions) ============

    function getNextCommitId() external view returns (uint256) {
        return s.nextCommitId;
    }

    function getCommitExpiresAt(uint256 commitId) external view returns (uint256) {
        return s.commits[commitId].expiresAt;
    }

    function getCommitOwner(uint256 commitId) external view returns (address) {
        return s.commits[commitId].mmState.owner;
    }

    function getCommitAdvancer(uint256 commitId) external view returns (address) {
        return s.commits[commitId].mmState.advancer;
    }

    function getCommitAuthorisedRelayer(uint256 commitId) external view returns (address) {
        return s.commits[commitId].authorisedRelayer;
    }

    function getPositionCommitmentDeficit(PositionId id) external view returns (uint256 deficit0, uint256 deficit1) {
        return (s.positionAccounting[id].commitmentDeficit.token0, s.positionAccounting[id].commitmentDeficit.token1);
    }

    function getPositionCommitmentDeficitBps(PositionId id) external view returns (uint16) {
        return s.positionAccounting[id].commitmentDeficitBps;
    }

    function getPositionCommitmentDeficitSince(PositionId id) external view returns (uint256 since0, uint256 since1) {
        return (
            s.positionAccounting[id].commitmentDeficitSince.token0,
            s.positionAccounting[id].commitmentDeficitSince.token1
        );
    }

    // ============ Internal Helpers ============

    function _emptyConfig() internal pure returns (MarketVTSConfiguration memory cfg) {
        TokenConfiguration memory tc = TokenConfiguration({
            gracePeriodTime: 0,
            baseVTSRate: 0,
            maxGracePeriodTime: 0,
            unbackedCommitmentGraceBypassTime: 0,
            unbackedCommitmentGraceBypassThreshold: 0
        });
        cfg = MarketVTSConfiguration({token0: tc, token1: tc, minResidualUnits: 0, unbackedCommitmentGraceBypassBps: 0});
    }
}

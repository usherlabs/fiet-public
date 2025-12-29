// SPDX-License-Identifier: BUSL-1.1
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

    function incrementCoverage(PoolId poolId, uint8 tokenIndex, uint256 coveredAmount) external {
        VTSCommitLib.incrementCoverage(s, poolId, tokenIndex, coveredAmount);
    }

    function commitSignal(IVRLSignalManager mgr, bytes memory sig) external returns (uint256) {
        return VTSCommitLib.commitSignal(s, mgr, sig);
    }

    function renewSignal(IVRLSignalManager mgr, uint256 commitId, bytes memory sig) external {
        VTSCommitLib.renewSignal(s, mgr, commitId, sig);
    }

    function checkpoint(
        IPoolManager poolManager,
        IVRLSignalManager signalManager,
        IOracleHelper oracleHelper,
        address sender,
        uint256 commitId,
        PositionId positionId,
        bytes memory liquiditySignal
    ) external {
        VTSCommitLib.checkpointWithCommitment(
            s, poolManager, signalManager, oracleHelper, sender, commitId, positionId, liquiditySignal
        );
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
                timeOfLastTransition: block.timestamp, isOpen: false, gracePeriodExtension0: 0, gracePeriodExtension1: 0
            })
        });
    }

    function setPositionSettled(PositionId id, uint256 settled0, uint256 settled1) external {
        s.positionAccounting[id].settled.token0 = settled0;
        s.positionAccounting[id].settled.token1 = settled1;
    }

    function setPositionCommitmentDeficit(PositionId id, uint256 deficit0, uint256 deficit1) external {
        s.positionAccounting[id].commitmentDeficit.token0 = deficit0;
        s.positionAccounting[id].commitmentDeficit.token1 = deficit1;
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

    function getCoveragePerDeficitIndexX128(PoolId poolId, uint8 tokenIndex) external view returns (uint256) {
        return tokenIndex == 0
            ? s.poolAccounting[poolId].coveragePerDeficitIndexX128.token0
            : s.poolAccounting[poolId].coveragePerDeficitIndexX128.token1;
    }

    function getCoverageResidualDICE(PoolId poolId, uint8 tokenIndex) external view returns (uint256) {
        return tokenIndex == 0
            ? s.poolAccounting[poolId].coverageResidualDICE.token0
            : s.poolAccounting[poolId].coverageResidualDICE.token1;
    }

    function getCoveragePerSettledIndexX128(PoolId poolId, uint8 tokenIndex) external view returns (uint256) {
        return tokenIndex == 0
            ? s.poolAccounting[poolId].coveragePerSettledIndexX128.token0
            : s.poolAccounting[poolId].coveragePerSettledIndexX128.token1;
    }

    function getCoverageResidualCISE(PoolId poolId, uint8 tokenIndex) external view returns (uint256) {
        return tokenIndex == 0
            ? s.poolAccounting[poolId].coverageResidualCISE.token0
            : s.poolAccounting[poolId].coverageResidualCISE.token1;
    }

    function getPositionCommitmentDeficit(PositionId id) external view returns (uint256 deficit0, uint256 deficit1) {
        return (s.positionAccounting[id].commitmentDeficit.token0, s.positionAccounting[id].commitmentDeficit.token1);
    }

    // ============ Internal Helpers ============

    function _emptyConfig() internal pure returns (MarketVTSConfiguration memory cfg) {
        // Keep the harness independent from MarketTestBase defaults; commit lib doesn't read config.
        TokenConfiguration memory tc =
            TokenConfiguration({gracePeriodTime: 0, seizureUnlockTime: 0, baseVTSRate: 0, maxGracePeriodTime: 0});
        cfg = MarketVTSConfiguration({token0: tc, token1: tc, coverageFeeShare: 0, minResidualUnits: 0});
    }
}


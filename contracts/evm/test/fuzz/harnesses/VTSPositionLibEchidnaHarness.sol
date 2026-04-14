// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSStorage, MarketVTSConfiguration} from "../../../src/types/VTS.sol";
import {PositionId, Position} from "../../../src/types/Position.sol";
import {Pool} from "../../../src/types/Pool.sol";
import {
    SettleParams,
    SettleResult,
    PositionContext,
    TouchPositionParams,
    TouchPositionResult
} from "../../../src/types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {VTSPositionLib} from "../../../src/libraries/VTSPositionLib.sol";
import {VTSLifecycleLinkedLib} from "../../../src/libraries/VTSLifecycleLinkedLib.sol";
import {DynamicCurrencyDelta} from "../../../src/libraries/DynamicCurrencyDelta.sol";
import {IMarketVault} from "../../../src/interfaces/IMarketVault.sol";
import {IMarketFactory} from "../../../src/interfaces/IMarketFactory.sol";
import {ILiquidityHub} from "../../../src/interfaces/ILiquidityHub.sol";
import {IOracleHelper} from "../../../src/interfaces/IOracleHelper.sol";

/// @notice Minimal Echidna-oriented harness that avoids calling `public`/`external` functions on `VTSPositionLib`.
///         This prevents linked-library DELEGATECALLs that cause Echidna/HEVM to attempt RPC bytecode fetches.
contract VTSPositionLibEchidnaHarness {
    VTSStorage internal s;

    constructor() {
        // VTSPositionLib must already be deployed at the EchidnaLinkedLibs address before
        // this harness is constructed. Callers should call EchidnaLinkedLibs.deployVTSPositionLib()
        // before `new VTSPositionLibEchidnaHarness()`.
    }

    // -------------------------------------------------------------------------
    // Setup / internal-library calls (safe: internal functions are inlined)
    // -------------------------------------------------------------------------

    function setupPool(PoolId poolId, MarketVTSConfiguration memory config) external {
        s.pools[poolId] = Pool({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            vtsConfig: config,
            isPaused: false
        });
    }

    function registerPosition(address owner, PoolId poolId, ModifyLiquidityParams calldata params) external {
        VTSPositionLib._registerPosition(s, owner, poolId, params);
    }

    function initPositionSnapshots(IPoolManager poolManager, PositionId id) external {
        VTSPositionLib._initPositionSnapshots(s, poolManager, id);
    }

    // -------------------------------------------------------------------------
    // Storage setters (used by fuzz harness)
    // -------------------------------------------------------------------------

    function setCommitmentMax(PositionId id, uint256 c0, uint256 c1) external {
        s.positionAccounting[id].commitmentMax.token0 = c0;
        s.positionAccounting[id].commitmentMax.token1 = c1;
    }

    function setSettled(PositionId id, uint256 s0, uint256 s1) external {
        s.positionAccounting[id].settled.token0 = s0;
        s.positionAccounting[id].settled.token1 = s1;
    }

    function setPoolTotalSettled(PoolId poolId, uint256 total0, uint256 total1) external {
        s.poolAccounting[poolId].totalSettled.token0 = total0;
        s.poolAccounting[poolId].totalSettled.token1 = total1;
    }

    function setCumulativeDeficit(PositionId id, uint256 d0, uint256 d1) external {
        s.positionAccounting[id].cumulativeDeficit.token0 = d0;
        s.positionAccounting[id].cumulativeDeficit.token1 = d1;
    }

    function setPoolTotalDeficitPrincipal(PoolId poolId, uint256 principal0, uint256 principal1) external {
        s.poolAccounting[poolId].totalDeficitPrincipal.token0 = principal0;
        s.poolAccounting[poolId].totalDeficitPrincipal.token1 = principal1;
    }

    function setPositionActive(PositionId id, bool active) external {
        s.positions[id].isActive = active;
    }

    function setPositionCommitId(PositionId id, uint256 commitId) external {
        s.positions[id].commitId = commitId;
    }

    function setPositionOwner(PositionId id, address owner) external {
        s.positions[id].owner = owner;
    }

    function setPositionLiquidity(PositionId id, uint128 liquidity) external {
        s.positions[id].liquidity = liquidity;
    }

    function setCommitmentDeficit(PositionId id, uint256 deficit0, uint256 deficit1) external {
        s.positionAccounting[id].commitmentDeficit.token0 = deficit0;
        s.positionAccounting[id].commitmentDeficit.token1 = deficit1;
    }

    function setCommitmentDeficitSince(PositionId id, uint256 since0, uint256 since1) external {
        s.positionAccounting[id].commitmentDeficitSince.token0 = since0;
        s.positionAccounting[id].commitmentDeficitSince.token1 = since1;
    }

    function setUnderlyingDelta(Currency currency, address target, int128 delta) external {
        DynamicCurrencyDelta.accountDelta(currency, delta, target);
    }

    function setUnderlyingDeltaAbsolute(Currency currency, address target, int128 desired) external {
        int128 current = getUnderlyingDeltaSigned(currency, target);
        int256 diff = int256(desired) - int256(current);
        if (diff > type(int128).max) diff = type(int128).max;
        if (diff < type(int128).min) diff = type(int128).min;
        if (diff != 0) {
            DynamicCurrencyDelta.accountDelta(currency, int128(diff), target);
        }
    }

    function getUnderlyingDeltaSigned(Currency currency, address target) public view returns (int128) {
        uint256 credit = DynamicCurrencyDelta.getFullCredit(currency, target);
        if (credit > 0) {
            return credit >= uint256(uint128(type(int128).max)) ? type(int128).max : int128(uint128(credit));
        }
        uint256 debt = DynamicCurrencyDelta.getFullDebt(currency, target);
        if (debt == 0) return 0;
        if (debt >= uint256(uint128(type(int128).max))) return type(int128).min;
        return -int128(uint128(debt));
    }

    function getPositionCommitId(PositionId id) external view returns (uint256) {
        return s.positions[id].commitId;
    }

    function getSettled(PositionId id) external view returns (uint256 token0, uint256 token1) {
        token0 = s.positionAccounting[id].settled.token0;
        token1 = s.positionAccounting[id].settled.token1;
    }

    // -------------------------------------------------------------------------
    // RFS (delegate to VTSPositionLib)
    // -------------------------------------------------------------------------

    function getRFS(PositionId positionId) external view returns (bool rfsOpen, BalanceDelta delta) {
        // NOTE: This is safe in Echidna because `getRFS` takes a `VTSStorage storage` pointer,
        // so the compiler inlines it (no linked-library DELEGATECALL).
        return VTSPositionLib.getRFS(s, positionId);
    }

    // -------------------------------------------------------------------------
    // MM settle entrypoint (`VTSLifecycleLinkedLib._executeMMSettleFromParams`)
    // -------------------------------------------------------------------------

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
        Position memory pos = s.positions[positionId];
        if (pos.owner == address(0)) revert("VTSPositionLib: Invalid position");

        SettleParams memory p;
        p.vault = vault;
        p.factory = IMarketFactory(address(0));
        p.poolId = pos.poolId;
        p.positionId = positionId;
        p.lccCurrency0 = lccCurrency0;
        p.lccCurrency1 = lccCurrency1;
        p.delta = delta;
        p.isSeizing = isSeizing;
        p.fromDeltas = fromDeltas;
        SettleResult memory result = VTSLifecycleLinkedLib._executeMMSettleFromParams(s, poolManager, p);
        return (result.settlementDelta, result.rfsOpen, result.seizedLiquidityUnits);
    }

    function touchPosition(PositionContext calldata ctx, TouchPositionParams calldata params)
        external
        returns (Position memory pos, PositionId id, BalanceDelta feeAdj)
    {
        TouchPositionResult memory out = VTSPositionLib.touchPosition(s, ctx, params);
        return (out.pos, out.id, out.feeAdj);
    }

    function buildPositionContext(
        IPoolManager poolManager,
        ILiquidityHub liquidityHub,
        IOracleHelper oracleHelper,
        IMarketVault marketVault
    ) external pure returns (PositionContext memory ctx) {
        ctx = PositionContext({
            poolManager: poolManager, liquidityHub: liquidityHub, oracleHelper: oracleHelper, marketVault: marketVault
        });
    }
}


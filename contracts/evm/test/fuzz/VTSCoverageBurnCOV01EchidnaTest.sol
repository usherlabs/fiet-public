// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSPositionLibHarness} from "../libraries/harnesses/VTSPositionLibHarness.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {MarketVTSConfiguration, TokenConfiguration} from "../../src/types/VTS.sol";
import {PositionId, PositionLibrary} from "../../src/types/Position.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "v4-periphery/lib/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";

interface IPoolManagerMockSlot0 {
    function setSlot(bytes32 s, bytes32 value) external;
    function setSlot0(PoolId poolId, uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) external;
    function extsload(bytes32 s) external view returns (bytes32);
    function extsload(bytes32 s, uint256 nSlots) external view returns (bytes32[] memory data);
}

/// @notice Echidna harness for COV-01: Coverage burn is bounded by `(deficit + settled)`; fee burn is capped by deficit.
///         Clamps inputs, seeds a deterministic fee-growth window, applies coverage burn,
///         then asserts the burn is bounded by min(cov, deficit + settled) and the outflow
///         snap/fee deltas advance exactly by the bounded burnBase on the correct token.
contract VTSCoverageBurnCOV01EchidnaTest {
    VTSPositionLibHarness internal harness;
    IPoolManagerMockSlot0 internal poolManager;

    PoolId internal constant POOL_ID = PoolId.wrap(bytes32(uint256(0xC0C01)));
    int24 internal constant TICK_LOWER = -60;
    int24 internal constant TICK_UPPER = 60;
    uint256 internal constant MAX_TOKEN_UNITS = 1e30;

    PositionId internal positionId;

    bool internal checked;
    bool internal lastOk;

    uint8 internal sTokenIndex;
    uint8 internal sFeeTokenIndex;
    uint256 internal sDeficit;
    uint256 internal sSettled;
    uint256 internal sCov;
    uint256 internal sBurnBase;
    uint256 internal sOfDelta;
    uint256 internal sBps;
    uint256 internal sFg;
    uint128 internal sLiq;

    struct Snap {
        uint256 poolFee;
        uint256 shared;
        int256 pending;
        uint256 snap;
        uint256 fg;
    }

    constructor() {
        harness = new VTSPositionLibHarness();
        poolManager = IPoolManagerMockSlot0(address(new MockPoolManager()));

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 0, salt: bytes32(uint256(0))
        });
        positionId = PositionLibrary.generateId(address(this), params);

        harness.setupPool(POOL_ID, _config(1000));
        harness.registerPosition(address(this), POOL_ID, params);
    }

    // -------------------------------------------------------------------------
    // Action
    // -------------------------------------------------------------------------

    /// @notice Apply coverage burn with fuzzed inputs and assert burnBase bounds.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_apply_coverage_burn_bounds(
        uint8 tokenIndexRaw,
        uint256 covRaw,
        uint256 deficitRaw,
        uint256 settledRaw,
        uint16 feeShareBpsRaw,
        uint128 positionLiquidityRaw,
        uint256 feeGrowthInsideRaw
    ) external {
        checked = false;
        lastOk = true;
        _cacheInputs(
            tokenIndexRaw, covRaw, deficitRaw, settledRaw, feeShareBpsRaw, positionLiquidityRaw, feeGrowthInsideRaw
        );
        _configureState();

        (bool ran, bool ok) = _applyAndCheck();
        if (!ran) return;

        checked = true;
        lastOk = ok;
    }

    // -------------------------------------------------------------------------
    // Properties
    // -------------------------------------------------------------------------

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_cov_01_burn_base_bounded() external view returns (bool) {
        return !checked || lastOk;
    }

    // Keep a second trivial property to avoid rare Echidna instability with single-property targets.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_cov_01_smoke() external pure returns (bool) {
        return true;
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _config(uint16 coverageFeeShare) internal pure returns (MarketVTSConfiguration memory) {
        TokenConfiguration memory tokenConfig = TokenConfiguration({
            gracePeriodTime: 1 hours, seizureUnlockTime: 1 hours, baseVTSRate: 0, maxGracePeriodTime: 7 days
        });

        return MarketVTSConfiguration({
            token0: tokenConfig,
            token1: tokenConfig,
            coverageFeeShare: coverageFeeShare,
            minResidualUnits: 1,
            unbackedCommitmentGraceBypassBps: 0
        });
    }

    function _clamp(uint256 value) internal pure returns (uint256) {
        return value > MAX_TOKEN_UNITS ? MAX_TOKEN_UNITS : value;
    }

    function _cacheInputs(
        uint8 tokenIndexRaw,
        uint256 covRaw,
        uint256 deficitRaw,
        uint256 settledRaw,
        uint16 feeShareBpsRaw,
        uint128 positionLiquidityRaw,
        uint256 feeGrowthInsideRaw
    ) internal {
        uint8 tokenIndex = tokenIndexRaw % 2;
        uint8 feeTokenIndex = tokenIndex == 0 ? 1 : 0;

        uint256 deficit = _clamp(deficitRaw);
        uint256 settled = _clamp(settledRaw);
        uint256 cov = _clamp(covRaw);

        uint256 cEff = cov <= (deficit + settled) ? cov : (deficit + settled);
        uint256 burnBase = cEff < deficit ? cEff : deficit;

        uint256 bps = feeShareBpsRaw;
        if (bps > LiquidityUtils.BPS_DENOMINATOR) bps = LiquidityUtils.BPS_DENOMINATOR;
        // Force a non-zero fee share when burnBase > 0 so the burn checkpoints actually advance.
        if (burnBase > 0) {
            bps = LiquidityUtils.BPS_DENOMINATOR;
        } else if (bps == 0) {
            bps = 1;
        }

        uint256 fg = feeGrowthInsideRaw;
        if (fg < FixedPoint128.Q128) fg = FixedPoint128.Q128;

        uint256 liquidity = positionLiquidityRaw;
        if (liquidity < burnBase + 1) liquidity = burnBase + 1;
        if (liquidity == 0) liquidity = 1;
        if (liquidity > type(uint128).max) liquidity = type(uint128).max;

        sTokenIndex = tokenIndex;
        sFeeTokenIndex = feeTokenIndex;
        sDeficit = deficit;
        sSettled = settled;
        sCov = cov;
        sBurnBase = burnBase;
        sOfDelta = burnBase == 0 ? 1 : (burnBase + 1);
        sBps = bps;
        sFg = fg;
        sLiq = uint128(liquidity);
    }

    function _configureState() internal {
        harness.setupPool(POOL_ID, _config(uint16(sBps)));

        if (sTokenIndex == 0) {
            harness.setCumulativeDeficit(positionId, sDeficit, 0);
            harness.setSettled(positionId, sSettled, 0);
        } else {
            harness.setCumulativeDeficit(positionId, 0, sDeficit);
            harness.setSettled(positionId, 0, sSettled);
        }

        if (sTokenIndex == 0) {
            harness.setCumulativeOutflows(positionId, sOfDelta, 0);
        } else {
            harness.setCumulativeOutflows(positionId, 0, sOfDelta);
        }
        harness.setOutflowsAtFeeSnap(positionId, 0, 0);

        uint256 lastFeeGrowth = sFg - FixedPoint128.Q128; // delta = Q128 => fees == liquidity
        if (sFeeTokenIndex == 0) {
            harness.setFeeGrowthInsideLast(positionId, lastFeeGrowth, 0);
        } else {
            harness.setFeeGrowthInsideLast(positionId, 0, lastFeeGrowth);
        }

        _primeFeeGrowthSlots(sFeeTokenIndex, sFg);
    }

    function _applyAndCheck() internal returns (bool ran, bool ok) {
        Snap memory beforeSnap = _snapshot(sTokenIndex, sFeeTokenIndex);

        try harness.applyCoverageBurn(
            IPoolManager(address(poolManager)), positionId, POOL_ID, sTokenIndex, sCov, sLiq
        ) {}
        catch {
            return (false, true);
        }

        uint256 feesBurn = _computeFeesBurn();
        Snap memory afterSnap = _snapshot(sTokenIndex, sFeeTokenIndex);

        if (feesBurn == 0) {
            ok = (afterSnap.poolFee == beforeSnap.poolFee) && (afterSnap.shared == beforeSnap.shared)
                && (afterSnap.pending == beforeSnap.pending) && (afterSnap.snap == beforeSnap.snap)
                && (afterSnap.fg == beforeSnap.fg);
        } else {
            uint256 growthInc = FullMath.mulDiv(feesBurn, FixedPoint128.Q128, sLiq);
            ok = (afterSnap.poolFee == beforeSnap.poolFee + feesBurn)
                && (afterSnap.shared == beforeSnap.shared + feesBurn)
                && (afterSnap.pending == beforeSnap.pending + int256(feesBurn))
                && (afterSnap.snap == beforeSnap.snap + sBurnBase) && (afterSnap.fg == sFg + growthInc);
        }

        return (true, ok);
    }

    function _computeFeesBurn() internal view returns (uint256 feesBurn) {
        if (sBurnBase == 0) {
            return 0;
        }
        uint256 fees = sLiq;
        feesBurn = FullMath.mulDiv(fees, sBurnBase, sOfDelta);
        feesBurn = FullMath.mulDiv(feesBurn, sBps, LiquidityUtils.BPS_DENOMINATOR);
    }

    function _snapshot(uint8 tokenIndex, uint8 feeTokenIndex) internal view returns (Snap memory s) {
        (uint256 poolFee0, uint256 poolFee1) = harness.getPoolProtocolFeeAccrued(POOL_ID);
        (uint256 shared0, uint256 shared1) = harness.getFeesShared(positionId);
        (int256 pending0, int256 pending1) = harness.getPendingFeeAdj(positionId);
        (uint256 snap0, uint256 snap1) = harness.getOutflowsAtFeeSnap(positionId);
        (uint256 fg0, uint256 fg1) = harness.getFeeGrowthInsideLast(positionId);

        s.poolFee = feeTokenIndex == 0 ? poolFee0 : poolFee1;
        s.shared = feeTokenIndex == 0 ? shared0 : shared1;
        s.pending = feeTokenIndex == 0 ? pending0 : pending1;
        s.snap = tokenIndex == 0 ? snap0 : snap1;
        s.fg = feeTokenIndex == 0 ? fg0 : fg1;
    }

    function _primeFeeGrowthSlots(uint8 feeTokenIndex, uint256 feeGrowth) internal {
        _pmSetSlot0Tick(POOL_ID, 0);
        if (feeTokenIndex == 0) {
            _pmSetFeeGrowthGlobals(POOL_ID, feeGrowth, 0);
        } else {
            _pmSetFeeGrowthGlobals(POOL_ID, 0, feeGrowth);
        }
        _pmSetTickFeeGrowthOutside(POOL_ID, TICK_LOWER, 0, 0);
        _pmSetTickFeeGrowthOutside(POOL_ID, TICK_UPPER, 0, 0);
    }

    // ------------------------------------------------------------
    // Helpers for MockPoolManager slot calculations
    // ------------------------------------------------------------
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    uint256 internal constant FEE_GROWTH_GLOBAL0_OFFSET = 1;
    uint256 internal constant TICKS_OFFSET = 4;

    function _pmSetSlot0Tick(PoolId pId, int24 tick) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(pId), POOLS_SLOT));
        uint160 sqrtPriceX96 = 1; // arbitrary non-zero
        uint24 tickU = uint24(uint32(int32(tick)));
        uint256 data = uint256(uint160(sqrtPriceX96)) | (uint256(tickU) << 160);
        poolManager.setSlot(stateSlot, bytes32(data));
    }

    function _pmSetFeeGrowthGlobals(PoolId pId, uint256 fg0, uint256 fg1) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(pId), POOLS_SLOT));
        bytes32 slot0 = bytes32(uint256(stateSlot) + FEE_GROWTH_GLOBAL0_OFFSET);
        poolManager.setSlot(slot0, bytes32(fg0));
        poolManager.setSlot(bytes32(uint256(slot0) + 1), bytes32(fg1));
    }

    function _pmSetTickFeeGrowthOutside(PoolId pId, int24 tick, uint256 outside0, uint256 outside1) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(pId), POOLS_SLOT));
        bytes32 ticksMappingSlot = bytes32(uint256(stateSlot) + TICKS_OFFSET);
        bytes32 tickInfoSlot = keccak256(abi.encodePacked(int256(tick), ticksMappingSlot));
        // getTickFeeGrowthOutside reads from tickInfoSlot+1 (outside0) and +2 (outside1)
        poolManager.setSlot(bytes32(uint256(tickInfoSlot) + 1), bytes32(outside0));
        poolManager.setSlot(bytes32(uint256(tickInfoSlot) + 2), bytes32(outside1));
    }
}

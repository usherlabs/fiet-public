// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {VTSPositionLibHarness} from "./harnesses/VTSPositionLibHarness.sol";

import {MarketVTSConfiguration, TokenConfiguration} from "../../src/types/VTS.sol";
import {VTSStorage} from "../../src/types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PositionId, PositionLibrary} from "../../src/types/Position.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {VTSPositionLib} from "../../src/libraries/VTSPositionLib.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";

/// @notice Mutation-focused unit tests for VTSPositionLib that do NOT depend on MarketTestBase/_setupMarket.
/// @dev Purpose: avoid fixture panics masking kills. These tests aim to kill meaningful mutants via direct harness state.
contract VTSPositionLibMutationUnitTest is Test {
    VTSPositionLibHarness internal harness;
    VTSPositionLibDeltaClearanceExpose internal clearanceExpose;
    VTSPositionLibResidualFlushExpose internal residualExpose;

    PoolId internal poolId;
    address internal owner;

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;

    // Default VTS configuration (mirrors VTSLibTestBase defaults, but without inheriting it)
    uint256 internal constant DEFAULT_GRACE_PERIOD = 1 hours;
    uint256 internal constant DEFAULT_SEIZURE_UNLOCK = 24 hours;
    uint256 internal constant DEFAULT_BASE_VTS_RATE = 500; // 5% in bps
    uint256 internal constant DEFAULT_MAX_GRACE_PERIOD = 7 days;
    uint16 internal constant DEFAULT_COVERAGE_FEE_SHARE = 1000; // 10% in bps
    uint256 internal constant DEFAULT_MIN_RESIDUAL_UNITS = 1000;

    // -------------------------------------------------------------------------
    // Inventory (from reports/libraries__mutation_tests.csv) — 61 not-killed rows
    //
    // A) Meaningful (should be killable by deterministic unit tests):
    // - Commitment tracking arithmetic: 109, 110
    // - Pool totalSettled accounting: 168
    // - _updateSettlement add/sub: 248
    // - getRFS commitment deficit gate / clamp: 1506, 1508
    // - _registerPosition already-registered guard: 855
    // - _calcDeltaClearance truth table: 1855
    //
    // B) Likely equivalent / unkillable-by-test in current shape:
    // - memory↔storage substitutions on read-only locals (eg Position/Pool/TokenPairUint/GrowthPair locals)
    // - some guards that are redundant due to call-site invariants (eg residual flush guards)
    //
    // C) Masked by fixture panics (should be addressable by the no-fixture suite):
    // - mutants that previously caused MarketTestBase `_setupMarket()` to panic in setUp()
    // -------------------------------------------------------------------------

    function setUp() public {
        harness = new VTSPositionLibHarness();
        clearanceExpose = new VTSPositionLibDeltaClearanceExpose();
        residualExpose = new VTSPositionLibResidualFlushExpose();
        poolId = PoolId.wrap(bytes32(uint256(0xD1CE)));
        owner = address(0xBEEF);
        harness.setupPool(poolId, _defaultCfg());
    }

    function _defaultCfg() internal pure returns (MarketVTSConfiguration memory) {
        TokenConfiguration memory tokenCfg = TokenConfiguration({
            gracePeriodTime: DEFAULT_GRACE_PERIOD,
            seizureUnlockTime: DEFAULT_SEIZURE_UNLOCK,
            baseVTSRate: DEFAULT_BASE_VTS_RATE,
            maxGracePeriodTime: DEFAULT_MAX_GRACE_PERIOD
        });
        return MarketVTSConfiguration({
            token0: tokenCfg,
            token1: tokenCfg,
            coverageFeeShare: DEFAULT_COVERAGE_FEE_SHARE,
            minResidualUnits: DEFAULT_MIN_RESIDUAL_UNITS
        });
    }

    function _register(bytes32 salt, uint128 liquidity)
        internal
        returns (PositionId id, ModifyLiquidityParams memory p)
    {
        p = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: int256(uint256(liquidity)), salt: salt
        });
        harness.registerPosition(owner, poolId, p);
        id = PositionLibrary.generateId(owner, p);
    }

    // ============================================================
    // _trackCommitment: kill add/sub arithmetic mutants (109, 110)
    // ============================================================

    function test_trackCommitment_addLiquidity_matchesCalculatedMaxima() public {
        (PositionId id, ModifyLiquidityParams memory p) = _register(bytes32(uint256(1)), 1);

        uint128 liq = 1e18;
        ModifyLiquidityParams memory add = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: int256(uint256(liq)), salt: p.salt
        });

        (uint256 exp0, uint256 exp1) = LiquidityUtils.calculateCommitmentMaxima(TICK_LOWER, TICK_UPPER, liq);

        harness.trackCommitment(id, add);

        (uint256 c0, uint256 c1,,,,) = harness.getPositionAccounting(id);
        assertEq(c0, exp0, "commitmentMax0 should equal calculated maxima");
        assertEq(c1, exp1, "commitmentMax1 should equal calculated maxima");
    }

    function test_trackCommitment_addTwice_isAdditive() public {
        (PositionId id,) = _register(bytes32(uint256(2)), 1);

        uint128 liqA = 1e18;
        uint128 liqB = 2e18;

        ModifyLiquidityParams memory addA = ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: int256(uint256(liqA)),
            salt: bytes32(uint256(2))
        });
        ModifyLiquidityParams memory addB = ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: int256(uint256(liqB)),
            salt: bytes32(uint256(2))
        });

        (uint256 a0, uint256 a1) = LiquidityUtils.calculateCommitmentMaxima(TICK_LOWER, TICK_UPPER, liqA);
        (uint256 b0, uint256 b1) = LiquidityUtils.calculateCommitmentMaxima(TICK_LOWER, TICK_UPPER, liqB);

        harness.trackCommitment(id, addA);
        harness.trackCommitment(id, addB);

        (uint256 c0, uint256 c1,,,,) = harness.getPositionAccounting(id);
        assertEq(c0, a0 + b0, "commitmentMax0 should be additive across adds");
        assertEq(c1, a1 + b1, "commitmentMax1 should be additive across adds");
    }

    // ============================================================
    // _updateSettlement: kill pool totalSettled accounting mutant (168) and add/sub (248)
    // ============================================================

    function test_updateSettlement_updatesPoolTotalSettled_onDepositAndWithdrawal() public {
        (PositionId id,) = _register(bytes32(uint256(3)), 1);

        harness.setCommitmentMax(id, 1000e18, 0);
        harness.setSettled(id, 100e18, 0);
        harness.setPoolTotalSettled(poolId, 100e18, 0);

        // Deposit +50 => settled 150, pool total 150.
        int256 appliedIn = harness.updateSettlement(id, 0, 50e18);
        assertEq(appliedIn, 50e18, "applied should equal delta when no deficit/commit-deficit netting occurs");

        (,, uint256 settledAfterIn,,,) = harness.getPositionAccounting(id);
        assertEq(settledAfterIn, 150e18, "settled should increase on deposit");
        (uint256 poolTotalAfterIn,) = harness.getPoolTotalSettled(poolId);
        assertEq(poolTotalAfterIn, 150e18, "pool totalSettled should increase on deposit");

        // Withdrawal -25 => settled 125, pool total 125.
        int256 appliedOut = harness.updateSettlement(id, 0, -25e18);
        assertEq(appliedOut, -25e18, "applied should equal delta on withdrawal");

        (,, uint256 settledAfterOut,,,) = harness.getPositionAccounting(id);
        assertEq(settledAfterOut, 125e18, "settled should decrease on withdrawal");
        (uint256 poolTotalAfterOut,) = harness.getPoolTotalSettled(poolId);
        assertEq(poolTotalAfterOut, 125e18, "pool totalSettled should decrease on withdrawal");
    }

    // ============================================================
    // _registerPosition: kill already-registered guard mutant (855)
    // ============================================================

    function test_registerPosition_duplicate_revertsAlreadyRegistered() public {
        bytes32 salt = bytes32(uint256(4));
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: int256(uint256(1)), salt: salt
        });
        PositionId id = PositionLibrary.generateId(owner, p);

        harness.registerPosition(owner, poolId, p);

        vm.expectRevert(abi.encodeWithSelector(Errors.AlreadyRegistered.selector, id));
        harness.registerPosition(owner, poolId, p);
    }

    // ============================================================
    // getRFS: kill commitment deficit gate + clamp mutants (1506, 1508)
    // ============================================================

    function test_getRFS_commitmentDeficitInflatesAndClampsToCommitmentMax() public {
        (PositionId id,) = _register(bytes32(uint256(5)), 1);

        // Choose token1 to exercise the cd1 logic and clamp ternary.
        // c1 = 100e18, base req = 5e18, cd1 huge => need clamps to c1.
        harness.setCommitmentMax(id, 0, 100e18);
        harness.setSettled(id, 0, 0);
        harness.setCumulativeDeficit(id, 0, 0);
        harness.setCommitmentDeficit(id, 0, 1000e18);

        (bool rfsOpen, BalanceDelta delta) = harness.getRFS(id);
        assertTrue(rfsOpen, "RFS should be open when settled < required");

        assertEq(delta.amount1(), int128(int256(100e18)), "token1 RFS delta should clamp to commitmentMax");
    }

    // ============================================================
    // _calcDeltaClearance: kill branch broadening mutant (1855)
    // ============================================================

    function test_calcDeltaClearance_truthTable() public view {
        // delta < 0 && amount < 0 => clearance > 0 (reduces debt)
        assertEq(clearanceExpose.calc(-100, -50), 50, "neg/neg: should clear +50");
        assertEq(clearanceExpose.calc(-50, -100), 50, "neg/neg: should clear +50 (clamped to debt)");

        // delta > 0 && amount > 0 => clearance < 0 (reduces credit)
        assertEq(clearanceExpose.calc(100, 50), -50, "pos/pos: should clear -50");
        assertEq(clearanceExpose.calc(50, 100), -50, "pos/pos: should clear -50 (clamped to credit)");

        // Other quadrants => 0
        assertEq(clearanceExpose.calc(-100, 50), 0, "neg/pos: should clear 0");
        assertEq(clearanceExpose.calc(100, -50), 0, "pos/neg: should clear 0");
        assertEq(clearanceExpose.calc(0, -50), 0, "zero/neg: should clear 0");
        assertEq(clearanceExpose.calc(0, 50), 0, "zero/pos: should clear 0");
    }

    // ============================================================
    // Residual flushers: kill guard broadening mutants (291, 314)
    // ============================================================

    function test_flushCISE_residualPositive_totalSettledZero_isNoop() public {
        PoolId p = PoolId.wrap(bytes32(uint256(0xC15E)));
        residualExpose.setCISE(p, 0, 1e18, 0, 0);

        // Expected: no-op, and must NOT revert.
        residualExpose.flushCISE(p, 0);
        (uint256 idx, uint256 residual, uint256 totalSettled) = residualExpose.getCISE(p, 0);
        assertEq(idx, 0, "CISE index should remain unchanged when totalSettled is zero");
        assertEq(residual, 1e18, "CISE residual should remain when totalSettled is zero");
        assertEq(totalSettled, 0, "CISE totalSettled should remain zero");
    }

    function test_flushCISE_happyPath_updatesIndex_andClearsResidual() public {
        PoolId p = PoolId.wrap(bytes32(uint256(0xC15E2)));
        uint256 residual = 5e18;
        uint256 totalSettled = 20e18;
        residualExpose.setCISE(p, 1, residual, totalSettled, 7);

        residualExpose.flushCISE(p, 1);
        (uint256 idxAfter, uint256 residualAfter,) = residualExpose.getCISE(p, 1);

        uint256 expDelta = FullMath.mulDiv(residual, FixedPoint128.Q128, totalSettled);
        assertEq(idxAfter, 7 + expDelta, "CISE index should advance by residual/totalSettled");
        assertEq(residualAfter, 0, "CISE residual should clear after flush");
    }

    function test_flushDICE_residualPositive_principalZero_isNoop() public {
        PoolId p = PoolId.wrap(bytes32(uint256(0xD1CE)));
        residualExpose.setDICE(p, 0, 1e18, 0, 0);

        // Expected: no-op, and must NOT revert.
        residualExpose.flushDICE(p, 0);
        (uint256 idx, uint256 residual, uint256 principal) = residualExpose.getDICE(p, 0);
        assertEq(idx, 0, "DICE index should remain unchanged when principal is zero");
        assertEq(residual, 1e18, "DICE residual should remain when principal is zero");
        assertEq(principal, 0, "DICE principal should remain zero");
    }

    function test_flushDICE_happyPath_updatesIndex_andClearsResidual() public {
        PoolId p = PoolId.wrap(bytes32(uint256(0xD1CE2)));
        uint256 residual = 3e18;
        uint256 principal = 12e18;
        residualExpose.setDICE(p, 1, residual, principal, 11);

        residualExpose.flushDICE(p, 1);
        (uint256 idxAfter, uint256 residualAfter,) = residualExpose.getDICE(p, 1);

        uint256 expDelta = FullMath.mulDiv(residual, FixedPoint128.Q128, principal);
        assertEq(idxAfter, 11 + expDelta, "DICE index should advance by residual/principal");
        assertEq(residualAfter, 0, "DICE residual should clear after flush");
    }
}

/// @notice Exposes internal VTSPositionLib pure helper for truth-table tests.
contract VTSPositionLibDeltaClearanceExpose {
    function calc(int128 delta, int128 amount) external pure returns (int128) {
        return VTSPositionLib._calcDeltaClearance(delta, amount);
    }
}

/// @notice Exposes internal residual flushers with a minimal standalone VTSStorage.
contract VTSPositionLibResidualFlushExpose {
    VTSStorage internal s;

    function setCISE(PoolId poolId, uint8 tokenIndex, uint256 residual, uint256 totalSettled, uint256 indexNow)
        external
    {
        if (tokenIndex == 0) {
            s.poolAccounting[poolId].coverageResidualCISE.token0 = residual;
            s.poolAccounting[poolId].totalSettled.token0 = totalSettled;
            s.poolAccounting[poolId].coveragePerSettledIndexX128.token0 = indexNow;
        } else {
            s.poolAccounting[poolId].coverageResidualCISE.token1 = residual;
            s.poolAccounting[poolId].totalSettled.token1 = totalSettled;
            s.poolAccounting[poolId].coveragePerSettledIndexX128.token1 = indexNow;
        }
    }

    function getCISE(PoolId poolId, uint8 tokenIndex)
        external
        view
        returns (uint256 indexNow, uint256 residual, uint256 totalSettled)
    {
        if (tokenIndex == 0) {
            indexNow = s.poolAccounting[poolId].coveragePerSettledIndexX128.token0;
            residual = s.poolAccounting[poolId].coverageResidualCISE.token0;
            totalSettled = s.poolAccounting[poolId].totalSettled.token0;
        } else {
            indexNow = s.poolAccounting[poolId].coveragePerSettledIndexX128.token1;
            residual = s.poolAccounting[poolId].coverageResidualCISE.token1;
            totalSettled = s.poolAccounting[poolId].totalSettled.token1;
        }
    }

    function flushCISE(PoolId poolId, uint8 tokenIndex) external {
        VTSPositionLib._flushCISEResidualIfNeeded(s, poolId, tokenIndex);
    }

    function setDICE(PoolId poolId, uint8 tokenIndex, uint256 residual, uint256 principal, uint256 indexNow) external {
        if (tokenIndex == 0) {
            s.poolAccounting[poolId].coverageResidualDICE.token0 = residual;
            s.poolAccounting[poolId].totalDeficitPrincipal.token0 = principal;
            s.poolAccounting[poolId].coveragePerDeficitIndexX128.token0 = indexNow;
        } else {
            s.poolAccounting[poolId].coverageResidualDICE.token1 = residual;
            s.poolAccounting[poolId].totalDeficitPrincipal.token1 = principal;
            s.poolAccounting[poolId].coveragePerDeficitIndexX128.token1 = indexNow;
        }
    }

    function getDICE(PoolId poolId, uint8 tokenIndex)
        external
        view
        returns (uint256 indexNow, uint256 residual, uint256 principal)
    {
        if (tokenIndex == 0) {
            indexNow = s.poolAccounting[poolId].coveragePerDeficitIndexX128.token0;
            residual = s.poolAccounting[poolId].coverageResidualDICE.token0;
            principal = s.poolAccounting[poolId].totalDeficitPrincipal.token0;
        } else {
            indexNow = s.poolAccounting[poolId].coveragePerDeficitIndexX128.token1;
            residual = s.poolAccounting[poolId].coverageResidualDICE.token1;
            principal = s.poolAccounting[poolId].totalDeficitPrincipal.token1;
        }
    }

    function flushDICE(PoolId poolId, uint8 tokenIndex) external {
        VTSPositionLib._flushCoverageResidualIfNeeded(s, poolId, tokenIndex);
    }
}


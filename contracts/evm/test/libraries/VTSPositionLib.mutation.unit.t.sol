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
import {Pool} from "../../src/types/Pool.sol";
import {Position} from "../../src/types/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {RFSCheckpoint} from "../../src/types/Checkpoint.sol";
import {IMarketVault} from "../../src/interfaces/IMarketVault.sol";
import {ILiquidityHub} from "../../src/interfaces/ILiquidityHub.sol";
import {IOracleHelper} from "../../src/interfaces/IOracleHelper.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PositionContext, TouchPositionParams, TouchPositionResult} from "../../src/types/VTS.sol";
import {PositionModificationHookDataLib} from "../../src/types/Position.sol";

/// @notice Mutation-focused unit tests for VTSPositionLib that do NOT depend on MarketTestBase/_setupMarket.
/// @dev Purpose: avoid fixture panics masking kills. These tests aim to kill meaningful mutants via direct harness state.
contract VTSPositionLibMutationUnitTest is Test {
    VTSPositionLibHarness internal harness;
    VTSPositionLibDeltaClearanceExpose internal clearanceExpose;
    VTSPositionLibResidualFlushExpose internal residualExpose;
    MockExtsloadPoolManager internal pm;

    PoolId internal poolId;
    address internal owner;

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;

    // Default VTS configuration (mirrors VTSLibTestBase defaults, but without inheriting it)
    uint256 internal constant DEFAULT_GRACE_PERIOD = 1 hours;
    uint256 internal constant DEFAULT_BASE_VTS_RATE = 500; // 5% in bps
    uint256 internal constant DEFAULT_MAX_GRACE_PERIOD = 7 days;
    uint16 internal constant DEFAULT_COVERAGE_FEE_SHARE = 1000; // 10% in bps
    uint256 internal constant DEFAULT_MIN_RESIDUAL_UNITS = 1000;

    // Seizure test constants (kept as constants to reduce stack pressure in debug profile compilation).
    // NOTE: we keep these as constants rather than locals to avoid "stack too deep" when compiling under
    // FOUNDRY_PROFILE=debug (via_ir=false), but we still want the values to be self-explanatory.
    uint256 internal constant SEIZURE_BASE_VTS_RATE1 = 500; // 5% in bps (token1 floor applied to exposureBps)
    uint256 internal constant SEIZURE_MIN_RESIDUAL_UNITS = 0; // set to 0 to avoid residual-threshold auto-close
    uint256 internal constant SEIZURE_C1 = 101e18 + 1; // token1 commitmentMax used in this rounding-edge case

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
        pm = new MockExtsloadPoolManager();
        poolId = PoolId.wrap(bytes32(uint256(0xD1CE)));
        owner = address(0xBEEF);
        harness.setupPool(poolId, _defaultCfg());
    }

    function _defaultCfg() internal pure returns (MarketVTSConfiguration memory) {
        TokenConfiguration memory tokenCfg = TokenConfiguration({
            gracePeriodTime: DEFAULT_GRACE_PERIOD,
            baseVTSRate: DEFAULT_BASE_VTS_RATE,
            maxGracePeriodTime: DEFAULT_MAX_GRACE_PERIOD,
            unbackedCommitmentGraceBypassTime: 0,
            unbackedCommitmentGraceBypassThreshold: 0
        });
        return MarketVTSConfiguration({
            token0: tokenCfg,
            token1: tokenCfg,
            coverageFeeShare: DEFAULT_COVERAGE_FEE_SHARE,
            minResidualUnits: DEFAULT_MIN_RESIDUAL_UNITS,
            unbackedCommitmentGraceBypassBps: 500
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
    // Deficit growth settlement: kill
    // - `_growthInsideSingle` out-of-range arithmetic mutants (383, 386)
    // - deficitIncrease = add1 - s1 mutant (507)
    // ============================================================
    function test_settlePositionDeficitGrowth_belowRange_accumulatesToken1Deficit_usingOutsideLowerMinusUpper() public {
        // Register a position with non-zero salt so PositionId matches Uniswap position keying.
        (PositionId id, ModifyLiquidityParams memory p) = _register(bytes32(uint256(10)), 1);

        // Keep coverage/fee logic inert for this test.
        harness.setCoverageIndexLastX128(id, 0, 0);
        harness.setCISEIndexLastX128(id, 0, 0);
        harness.setPoolCoveragePerDeficitIndexX128(poolId, 0, 0);
        harness.setPoolCoveragePerSettledIndexX128(poolId, 0, 0);
        harness.setDeficitGrowthGlobal(poolId, 0, 0);
        harness.setInflowGrowthGlobal(poolId, 0, 0);
        harness.setDeficitGrowthInsideLast(id, 0, 0);
        harness.setInflowGrowthInsideLast(id, 0, 0);

        // We want add1 > s1 > 0 so deficitIncrease is non-trivial.
        // Choose Q128-scaled growth so owed = (insideDelta * liq) / Q128 is non-zero and predictable.
        uint128 liq = 1000;
        uint256 outsideLower1 = 10 * FixedPoint128.Q128;
        uint256 outsideUpper1 = 3 * FixedPoint128.Q128;

        // Set outside growth at the ticks used by the position.
        harness.setDeficitGrowthOutside(poolId, p.tickLower, 0, outsideLower1);
        harness.setDeficitGrowthOutside(poolId, p.tickUpper, 0, outsideUpper1);

        // Set poolManager slot0 tickCurrent below tickLower so `_growthInsideSingle` uses:
        // inside = outsideLower - outsideUpper (the mutation flips - to +).
        _pmSetSlot0Tick(poolId, int24(p.tickLower - 100));

        // Provide pool manager's position liquidity for StateLibrary.getPositionLiquidity()
        _pmSetPositionLiquidity(poolId, PositionId.unwrap(id), liq);

        // Seed settled so we exercise deficitIncrease = add1 - s1.
        // Expected add1 = (outsideLower1 - outsideUpper1) * liq / Q128 = 7 * liq
        uint256 s1 = 2000;
        harness.setSettled(id, 0, s1);

        // Run the growth settle (uses StateLibrary for tick and liquidity).
        harness.settlePositionGrowths(IPoolManager(address(pm)), id);

        // inside1 = outsideLower1 - outsideUpper1 (because tickCurrent < tickLower)
        // = (10*Q128 - 3*Q128) = 7*Q128.
        // owed/add1 = (insideDelta * liq) / Q128 = (7*Q128 * liq) / Q128 = 7 * liq.
        //
        // NOTE (units & invariants):
        // - `liq` here is Uniswap "liquidity", NOT a token amount, so it is not directly comparable to `commitmentMax`.
        // - `cumulativeDeficit` is an accounting accumulator of attributed outflows/shortfall over time and is not
        //   clamped to `commitmentMax` at write-time (clamps happen later when computing requirements, e.g. in `getRFS`).
        // - This test intentionally picks Q128-scaled growth values to deterministically exercise the arithmetic and
        //   kill the `-`→`+` mutation in `_growthInsideSingle`, rather than modelling an economically realistic bound.
        uint256 expAdd1 = 7 * uint256(liq);
        uint256 expDeficitIncrease = expAdd1 - s1;

        (,,, uint256 settled1, uint256 d0, uint256 d1) = harness.getPositionAccounting(id);
        assertEq(d0, 0, "token0 deficit should remain unchanged");
        assertEq(d1, expDeficitIncrease, "token1 deficit should increase by add1 - s1");
        assertEq(settled1, 0, "token1 settled should be fully consumed");

        (, uint256 poolPrincipal1) = harness.getPoolTotalDeficitPrincipal(poolId);
        assertEq(poolPrincipal1, expDeficitIncrease, "pool token1 deficit principal should track deficit increase");
    }

    function test_settlePositionDeficitGrowth_aboveRange_accumulatesToken0Deficit_usingOutsideUpperMinusLower() public {
        // Register a position with non-zero salt so PositionId matches Uniswap position keying.
        (PositionId id, ModifyLiquidityParams memory p) = _register(bytes32(uint256(12)), 1);

        // Keep coverage/fee logic inert for this test.
        harness.setCoverageIndexLastX128(id, 0, 0);
        harness.setCISEIndexLastX128(id, 0, 0);
        harness.setPoolCoveragePerDeficitIndexX128(poolId, 0, 0);
        harness.setPoolCoveragePerSettledIndexX128(poolId, 0, 0);
        harness.setDeficitGrowthGlobal(poolId, 0, 0);
        harness.setInflowGrowthGlobal(poolId, 0, 0);
        harness.setDeficitGrowthInsideLast(id, 0, 0);
        harness.setInflowGrowthInsideLast(id, 0, 0);

        // Choose values so inside0 = outsideUpper0 - outsideLower0 is positive.
        uint128 liq = 1000;
        uint256 outsideLower0 = 2 * FixedPoint128.Q128;
        uint256 outsideUpper0 = 9 * FixedPoint128.Q128;

        // Set outside growth at the ticks used by the position.
        harness.setDeficitGrowthOutside(poolId, p.tickLower, outsideLower0, 0);
        harness.setDeficitGrowthOutside(poolId, p.tickUpper, outsideUpper0, 0);

        // Set tickCurrent above tickUpper so `_growthInsideSingle` uses:
        // inside = outsideUpper - outsideLower (the mutation flips - to +).
        _pmSetSlot0Tick(poolId, int24(p.tickUpper + 100));

        // Provide pool manager's position liquidity for StateLibrary.getPositionLiquidity()
        _pmSetPositionLiquidity(poolId, PositionId.unwrap(id), liq);

        // Seed settled token0 to zero so deficit increase is fully attributable.
        harness.setSettled(id, 0, 0);

        harness.settlePositionGrowths(IPoolManager(address(pm)), id);

        // inside0 = outsideUpper0 - outsideLower0 (because tickCurrent >= tickUpper)
        // = (9*Q128 - 2*Q128) = 7*Q128.
        // owed/add0 = (insideDelta * liq) / Q128 = 7 * liq.
        uint256 expAdd0 = 7 * uint256(liq);

        (uint256 settled0,, uint256 d0, uint256 d1) = _getPositionStateLite(id);
        assertEq(d0, expAdd0, "token0 deficit should increase by add0");
        assertEq(d1, 0, "token1 deficit should remain unchanged");
        assertEq(settled0, 0, "token0 settled should remain zero");

        (uint256 poolPrincipal0,) = harness.getPoolTotalDeficitPrincipal(poolId);
        assertEq(poolPrincipal0, expAdd0, "pool token0 deficit principal should track deficit increase");
    }

    // ============================================================
    // Coverage burn: kill `fg - lastFeeGrowth` mutant (595)
    // ============================================================
    function test_applyCoverageBurn_usesFeeGrowthDelta_notSum() public {
        (PositionId id, ModifyLiquidityParams memory p) = _register(bytes32(uint256(11)), 1);

        // Configure fee growth so `StateLibrary.getFeeGrowthInside()` returns a known inside-fee-growth for token1.
        //
        // In-range branch (tickLower <= tickCurrent < tickUpper):
        //   feeGrowthInside1X128 = feeGrowthGlobal1X128 - lowerOutside1X128 - upperOutside1X128
        //
        // Here we set:
        // - tickCurrent = 0 (in-range for [-600, 600])
        // - outside values = 0
        // - feeGrowthGlobal1X128 = 100 * Q128
        //
        // so feeGrowthInside1X128 deterministically equals 100 * Q128.
        _pmSetSlot0Tick(poolId, 0); // set tickCurrent = 0 (in-range)
        uint256 feeGrowthInside1X128 = 100 * FixedPoint128.Q128;
        _pmSetFeeGrowthGlobals(poolId, 0, feeGrowthInside1X128);
        _pmSetTickFeeGrowthOutside(poolId, p.tickLower, 0, 0);
        _pmSetTickFeeGrowthOutside(poolId, p.tickUpper, 0, 0);

        // `feeGrowthInsideLast` is the position's checkpointed baseline (same units: X128/Q128).
        // We pick a non-zero baseline so the delta (current - last) is meaningful.
        uint256 feeGrowthInsideLast1X128 = 40 * FixedPoint128.Q128;
        harness.setFeeGrowthInsideLast(id, 0, feeGrowthInsideLast1X128);

        // Make burnBase and outflow-window non-zero.
        // - `cov` is the requested coverage usage (raw token units, not bps).
        // - `ofDelta` is the "outflow window" (raw token units) used to normalise fee share.
        uint256 cov = 20e18; // burnBase in this test (since deficit == cov)
        uint256 ofDelta = 100e18; // outflows since last fee snap
        harness.setCumulativeDeficit(id, cov, 0);
        harness.setCumulativeOutflows(id, ofDelta, 0);
        harness.setOutflowsAtFeeSnap(id, 0, 0);

        // Run burn. Choose token0 as deficit token => fee token is token1.
        //
        // `positionLiquidity` is Uniswap liquidity units for this position (NOT token units).
        // It's used to translate between per-liquidity fee growth (X128) and absolute token amounts.
        uint256 positionLiquidity = 1e18;
        harness.applyCoverageBurn(IPoolManager(address(pm)), id, poolId, 0, cov, uint128(positionLiquidity));

        // Expected burn is based on fee growth *delta* (fg - lastFeeGrowth), not (fg + lastFeeGrowth).
        uint256 feesBurn =
            _expectedFeesBurnToken1(feeGrowthInside1X128, feeGrowthInsideLast1X128, positionLiquidity, cov, ofDelta);

        {
            // Assert pool + position fee tracking moved by feesBurn on the fee token.
            (, uint256 poolFee1) = harness.getPoolProtocolFeeAccrued(poolId);
            (, uint256 feesShared1) = harness.getFeesShared(id);
            (, int256 pendingAdj1) = harness.getPendingFeeAdj(id);
            assertEq(poolFee1, feesBurn, "protocolFeeAccrued(token1) should equal feesBurn");
            assertEq(feesShared1, feesBurn, "feesShared(token1) should equal feesBurn");
            assertEq(pendingAdj1, int256(feesBurn), "pendingFeeAdj(token1) should equal +feesBurn");
        }

        {
            // Outflow snap should advance by exercised outflow share (cov).
            (uint256 snap0,) = harness.getOutflowsAtFeeSnap(id);
            assertEq(snap0, cov, "outflowsAtFeeSnap(token0) should advance by burnBase");
        }

        {
            // Fee growth baseline should advance to fg + growthInc (fee token only).
            uint256 growthInc = FullMath.mulDiv(feesBurn, FixedPoint128.Q128, positionLiquidity);
            (, uint256 fg1After) = harness.getFeeGrowthInsideLast(id);
            assertEq(
                fg1After,
                feeGrowthInside1X128 + growthInc,
                "feeGrowthInsideLast(token1) should be fgInside1X128 + growthInc"
            );
        }
    }

    function _expectedFeesBurnToken1(
        uint256 feeGrowthInside1X128,
        uint256 feeGrowthInsideLast1X128,
        uint256 positionLiquidity,
        uint256 burnBase,
        uint256 ofDelta
    ) internal pure returns (uint256 feesBurn) {
        // fee delta (X128): current - last
        uint256 feeGrowthDelta1X128 = feeGrowthInside1X128 - feeGrowthInsideLast1X128;

        // fees (raw token units):
        //   fees = feeGrowthDeltaX128 * liquidity / Q128
        uint256 fees = FullMath.mulDiv(feeGrowthDelta1X128, positionLiquidity, FixedPoint128.Q128);

        // feesBurn = fees * (burnBase/ofDelta) * bps/10000
        feesBurn = FullMath.mulDiv(fees, burnBase, ofDelta);
        feesBurn = FullMath.mulDiv(feesBurn, DEFAULT_COVERAGE_FEE_SHARE, LiquidityUtils.BPS_DENOMINATOR);
    }

    // ============================================================
    // CISE (settled-indexed): kill deltaIndex = indexNow - indexLast mutant (771)
    // ============================================================
    function test_settleSettledIndexedCoverageUsage_realisesCISEExposureFromIndexDelta() public {
        VTSPositionLibCISEExpose ex = new VTSPositionLibCISEExpose();
        PoolId p = PoolId.wrap(bytes32(uint256(0xC15E)));
        ex.setupPool(p, _defaultCfg());

        PositionId id = PositionId.wrap(bytes32(uint256(0xB0B)));
        ex.setPosition(id, address(0xCAFE), p, 1000);

        uint256 settled0 = 100e18;
        ex.setSettled(id, settled0, 0);

        uint256 indexLast0 = 2 * FixedPoint128.Q128;
        uint256 indexNow0 = 5 * FixedPoint128.Q128;
        ex.setCISEIndexLastX128(id, indexLast0, 0);
        ex.setPoolCoveragePerSettledIndexX128(p, indexNow0, 0);

        ex.settleSettledIndexedCoverageUsage(id);

        uint256 expExposure0 = FullMath.mulDiv(settled0, (indexNow0 - indexLast0), FixedPoint128.Q128);
        (uint256 exposure0,) = ex.getCISEExposure(id);
        (uint256 poolExposure0,) = ex.getPoolTotalCISEExposure(p);
        assertEq(exposure0, expExposure0, "CISE exposure0 should realise settled * deltaIndex / Q128");
        assertEq(poolExposure0, expExposure0, "pool total CISE exposure0 should track position exposure");
    }

    function test_settlePositionInflowGrowth_positiveAdd0_increasesSettledAndPoolTotalSettled() public {
        (PositionId id, ModifyLiquidityParams memory p) = _register(bytes32(uint256(13)), 1);

        // Keep coverage/deficit logic inert for this test.
        harness.setCoverageIndexLastX128(id, 0, 0);
        harness.setCISEIndexLastX128(id, 0, 0);
        harness.setPoolCoveragePerDeficitIndexX128(poolId, 0, 0);
        harness.setPoolCoveragePerSettledIndexX128(poolId, 0, 0);
        harness.setDeficitGrowthGlobal(poolId, 0, 0);
        harness.setDeficitGrowthInsideLast(id, 0, 0);

        // Configure inflow growth so inside0 = global0 and is positive.
        uint128 liq = 1000;
        uint256 inflowGlobal0 = 5 * FixedPoint128.Q128;
        harness.setInflowGrowthGlobal(poolId, inflowGlobal0, 0);
        harness.setInflowGrowthInsideLast(id, 0, 0);
        harness.setInflowGrowthOutside(poolId, p.tickLower, 0, 0);
        harness.setInflowGrowthOutside(poolId, p.tickUpper, 0, 0);

        _pmSetSlot0Tick(poolId, 0); // in-range
        _pmSetPositionLiquidity(poolId, PositionId.unwrap(id), liq);

        // Ensure settlement can increase without clamping.
        harness.setCommitmentMax(id, type(uint256).max, type(uint256).max);
        harness.setSettled(id, 0, 0);
        harness.setPoolTotalSettled(poolId, 0, 0);

        harness.settlePositionGrowths(IPoolManager(address(pm)), id);

        uint256 expAdd0 = 5 * uint256(liq);
        (uint256 settled0,, uint256 d0, uint256 d1) = _getPositionStateLite(id);
        assertEq(settled0, expAdd0, "token0 settled should increase by inflow add0");
        assertEq(d0, 0, "token0 deficit should remain unchanged");
        assertEq(d1, 0, "token1 deficit should remain unchanged");

        (uint256 poolTotal0,) = harness.getPoolTotalSettled(poolId);
        assertEq(poolTotal0, expAdd0, "pool totalSettled token0 should increase by add0");
    }

    function test_touchPosition_nonMMDecrease_reducesSettledDownToNewCommitmentMax_token1() public {
        MockLCC lcc0 = new MockLCC(address(0xB0));
        MockLCC lcc1 = new MockLCC(address(0xB1));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(lcc0)),
            currency1: Currency.wrap(address(lcc1)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PoolId pId = key.toId();
        harness.setupPool(pId, _defaultCfg());

        // Register a position and seed commitment/settlement.
        ModifyLiquidityParams memory reg = ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: int256(uint256(1000)),
            salt: bytes32(uint256(30))
        });
        harness.registerPosition(owner, pId, reg);
        PositionId id = PositionLibrary.generateId(owner, reg);

        // Prepare commitment max so the decrease step produces known new maxima.
        uint128 liqRemoved = 500;
        (uint256 subC0, uint256 subC1) = LiquidityUtils.calculateCommitmentMaxima(TICK_LOWER, TICK_UPPER, liqRemoved);
        uint256 newC0 = 10e18;
        uint256 newC1 = 20e18;
        harness.setCommitmentMax(id, newC0 + subC0, newC1 + subC1);

        // Settled above the post-decrease maxima so excess is positive.
        harness.setSettled(id, newC0, newC1 + 7e18);
        harness.setPoolTotalSettled(pId, newC0, newC1 + 7e18);
        harness.setCumulativeDeficit(id, 0, 0);
        harness.setCommitmentDeficit(id, 0, 0);

        _pmSetSlot0Tick(pId, 0);
        _pmSetPositionLiquidity(pId, PositionId.unwrap(id), 1000);

        TouchPositionParams memory tp = TouchPositionParams({
            owner: owner,
            poolKey: key,
            params: ModifyLiquidityParams({
                tickLower: reg.tickLower,
                tickUpper: reg.tickUpper,
                liquidityDelta: -int256(uint256(liqRemoved)),
                salt: reg.salt
            }),
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: ""
        });

        PositionContext memory ctx = PositionContext({
            poolManager: IPoolManager(address(pm)),
            liquidityHub: ILiquidityHub(address(0)),
            oracleHelper: IOracleHelper(address(0)),
            marketVault: IMarketVault(address(0))
        });

        harness.touchPosition(ctx, tp);

        (uint256 settled0, uint256 settled1, uint256 d0, uint256 d1) = _getPositionStateLite(id);
        assertEq(settled0, newC0, "token0 settled should remain at new commitment max");
        assertEq(settled1, newC1, "token1 settled should be clamped to new commitment max");
        assertEq(d0, 0, "token0 deficit should remain unchanged");
        assertEq(d1, 0, "token1 deficit should remain unchanged");

        _assertPoolTotalSettled(pId, newC0, newC1);
    }

    function test_touchPosition_nonMMIncrease_setsSettledUpToNewCommitmentMax() public {
        MockLCC lcc0 = new MockLCC(address(0xC0));
        MockLCC lcc1 = new MockLCC(address(0xC1));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(lcc0)),
            currency1: Currency.wrap(address(lcc1)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PoolId pId = key.toId();
        harness.setupPool(pId, _defaultCfg());

        ModifyLiquidityParams memory reg = ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: int256(uint256(1000)),
            salt: bytes32(uint256(31))
        });
        harness.registerPosition(owner, pId, reg);
        PositionId id = PositionLibrary.generateId(owner, reg);

        // Seed a baseline commitment max and a lower settled amount.
        harness.setCommitmentMax(id, 10e18, 20e18);
        harness.setSettled(id, 3e18, 4e18);
        harness.setPoolTotalSettled(pId, 3e18, 4e18);
        harness.setCumulativeDeficit(id, 0, 0);
        harness.setCommitmentDeficit(id, 0, 0);

        _pmSetSlot0Tick(pId, 0);
        _pmSetPositionLiquidity(pId, PositionId.unwrap(id), 1000);

        uint128 liqAdded = 200;
        (uint256 addC0, uint256 addC1) = LiquidityUtils.calculateCommitmentMaxima(TICK_LOWER, TICK_UPPER, liqAdded);
        uint256 expC0 = 10e18 + addC0;
        uint256 expC1 = 20e18 + addC1;

        TouchPositionParams memory tp = TouchPositionParams({
            owner: owner,
            poolKey: key,
            params: ModifyLiquidityParams({
                tickLower: reg.tickLower,
                tickUpper: reg.tickUpper,
                liquidityDelta: int256(uint256(liqAdded)),
                salt: reg.salt
            }),
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: ""
        });

        PositionContext memory ctx = PositionContext({
            poolManager: IPoolManager(address(pm)),
            liquidityHub: ILiquidityHub(address(0)),
            oracleHelper: IOracleHelper(address(0)),
            marketVault: IMarketVault(address(0))
        });

        harness.touchPosition(ctx, tp);

        (uint256 settled0, uint256 settled1, uint256 d0, uint256 d1) = _getPositionStateLite(id);
        assertEq(settled0, expC0, "token0 settled should reach new commitment max");
        assertEq(settled1, expC1, "token1 settled should reach new commitment max");
        assertEq(d0, 0, "token0 deficit should remain unchanged");
        assertEq(d1, 0, "token1 deficit should remain unchanged");

        _assertPoolTotalSettled(pId, expC0, expC1);
    }

    // ============================================================
    // DICE (deficit-indexed): kill deltaIndex = indexNow - indexLast mutant (744)
    // ============================================================
    function test_settleDeficitIndexedCoverageUsage_usesIndexDelta_notSum() public {
        VTSPositionLibDICEExpose ex = new VTSPositionLibDICEExpose();
        PoolId p = PoolId.wrap(bytes32(uint256(0xD1CE0)));
        ex.setupPool(p, _defaultCfg());

        // Set up a position with a non-zero deficit principal on token0.
        PositionId id = PositionId.wrap(bytes32(uint256(0xD1CEB0B)));
        ex.setPosition(id, address(0xD00D), p, 1);
        ex.setCumulativeDeficit(id, 100e18, 0);

        // Set the pool coverage-per-deficit index and position checkpoint such that deltaIndex == 1*Q128.
        uint256 indexLast = 1 * FixedPoint128.Q128;
        uint256 indexNow = 2 * FixedPoint128.Q128;
        ex.setCoverageIndexLastX128(id, indexLast, 0);
        ex.setPoolCoveragePerDeficitIndexX128(p, indexNow, 0);

        // Configure fee growth so `_applyCoverageBurn` can compute a deterministic feesBurn.
        // We'll keep it simple: fgInside for fee token1 is 10*Q128, lastFeeGrowth is 0.
        ex.setFeeGrowthInsideLast(id, 0, 0);
        _pmSetSlot0Tick(p, 0);
        _pmSetFeeGrowthGlobals(p, 0, 10 * FixedPoint128.Q128);
        _pmSetTickFeeGrowthOutside(p, TICK_LOWER, 0, 0);
        _pmSetTickFeeGrowthOutside(p, TICK_UPPER, 0, 0);

        // Ensure StateLibrary.getPositionLiquidity() returns a non-zero value for burn baseline updates.
        _pmSetPositionLiquidity(p, PositionId.unwrap(id), 1e18);

        // Ensure outflow window exists for token0.
        ex.setCumulativeOutflows(id, 100e18, 0);
        ex.setOutflowsAtFeeSnap(id, 0, 0);

        // Run DICE settle (token0 only is meaningful here; token1 has zero deficit).
        ex.settleDeficitIndexedCoverageUsage(IPoolManager(address(pm)), id);

        // Assert some burn happened (protocol fee accrued on fee token1 should be > 0).
        (, uint256 fee1) = ex.getPoolProtocolFeeAccrued(p);
        assertGt(fee1, 0, "DICE settle should burn some fees and accrue protocolFee token1");
    }

    // ============================================================
    // Seizure: kill base-rate floor mutant (1934)
    // ============================================================
    function test_onMMSettle_seizure_usesBaseRateFloor_whenExposureRoundingIsLower() public {
        // Set up a pool config where baseVTSRate is high enough to matter.
        {
            MarketVTSConfiguration memory cfg = _defaultCfg();
            cfg.token1.baseVTSRate = SEIZURE_BASE_VTS_RATE1;
            // Avoid the residual-threshold auto-close path interfering with the partial-seizure expectation.
            // (If minResidualUnits ~= liq, any non-full seizure can be promoted to a full close.)
            cfg.minResidualUnits = SEIZURE_MIN_RESIDUAL_UNITS;
            harness.setupPool(poolId, cfg);
        }

        // Register position and seed commitmentMax for token1 with a rounding edge.
        (PositionId id,) = _register(bytes32(uint256(12)), 1000);
        harness.setCommitmentMax(id, 1e18, 101e18 + 1); // token1 commitment chosen to make exposureBps round down
        harness.setSettled(id, 0, 0);
        harness.setCumulativeDeficit(id, 0, 0);
        harness.setCommitmentDeficit(id, 0, 0);

        // Keep growth/coverage inert.
        harness.setCoverageIndexLastX128(id, 0, 0);
        harness.setCISEIndexLastX128(id, 0, 0);
        harness.setPoolCoveragePerDeficitIndexX128(poolId, 0, 0);
        harness.setPoolCoveragePerSettledIndexX128(poolId, 0, 0);
        harness.setDeficitGrowthGlobal(poolId, 0, 0);
        harness.setInflowGrowthGlobal(poolId, 0, 0);
        harness.setDeficitGrowthInsideLast(id, 0, 0);
        harness.setInflowGrowthInsideLast(id, 0, 0);

        // Make StateLibrary.getPositionLiquidity return 0 so settlePositionGrowths is a no-op.
        _pmSetSlot0Tick(poolId, 0);
        _pmSetPositionLiquidity(poolId, PositionId.unwrap(id), 0);

        // Create LCC currencies with deterministic underlying.
        MockLCC lcc0 = new MockLCC(address(0xA0));
        MockLCC lcc1 = new MockLCC(address(0xA1));

        // IMPORTANT: `_calcSeizure` returns 0 if RFS is *not* open at seizure time.
        // So we must deposit *less than* the pre-settle RFS requirement, leaving a positive remainder.
        // This remainder (r1) is what `_calcSeizure` will use to compute exposureBps, which should be
        // floored by baseVTSRate when rounding makes exposureBps(r1,c1) < baseVTSRate.
        (, BalanceDelta rfsDelta) = harness.getRFS(id);
        uint256 r1Before = uint256(int256(rfsDelta.amount1()));
        assertGt(r1Before, 1e18, "precondition: rfs1 should be > 1e18");

        uint256 deposit1 = r1Before - 1e18; // leave 1e18 requirement so RFS remains open
        BalanceDelta delta = toBalanceDelta(0, -SafeCast.toInt128(deposit1)); // deposit token1

        uint256 seized;
        int128 settleAmount1;
        {
            MockMarketVaultNoop vault = new MockMarketVaultNoop();
            BalanceDelta settlementDelta;
            (settlementDelta,, seized) = harness.onMMSettle(
                IPoolManager(address(pm)),
                IMarketVault(address(vault)),
                id,
                Currency.wrap(address(lcc0)),
                Currency.wrap(address(lcc1)),
                delta,
                true
            );
            settleAmount1 = settlementDelta.amount1();
        }

        {
            // Recompute inputs the same way `_calcSeizure` does *after* settlement.
            (bool rfsOpenAfter, BalanceDelta rfsAfter) = harness.getRFS(id);
            assertTrue(rfsOpenAfter, "precondition: RFS must remain open to compute seizure");

            // Remaining requirement after deposit (what `_calcSeizure` uses).
            uint256 r1 = uint256(int256(rfsAfter.amount1()));
            // Absolute deposited amount (negative means deposit).
            uint256 s1 = uint256(uint128(-settleAmount1));

            uint256 liqUnits = uint256(harness.getPosition(id).liquidity);
            uint256 expected = _expectedSeizedToken1Only(
                liqUnits, SEIZURE_BASE_VTS_RATE1, SEIZURE_C1, r1, s1, SEIZURE_MIN_RESIDUAL_UNITS
            );

            assertEq(seized, expected, "seized liquidity should use base-rate floor when rounding reduces exposureBps");
        }
    }

    function _expectedSeizedToken1Only(
        uint256 liqUnits,
        uint256 baseVTSRate1,
        uint256 c1,
        uint256 r1,
        uint256 s1,
        uint256 minResidualUnits
    ) internal pure returns (uint256 expected) {
        uint256 e1bpsRaw = LiquidityUtils.exposureBps(r1, c1);
        uint256 e1bps = baseVTSRate1 > e1bpsRaw ? baseVTSRate1 : e1bpsRaw;
        uint256 p1bps = LiquidityUtils.settleOfRfsBps(s1, r1);
        expected = LiquidityUtils.seizedUnitsFromBps(liqUnits, e1bps, p1bps);

        // Apply the same residual-threshold logic as `_calcSeizure`.
        uint256 minResidual = minResidualUnits == 0 ? 1 : minResidualUnits;
        if (expected < liqUnits && (liqUnits - expected) < minResidual) {
            expected = liqUnits;
        } else if (expected > liqUnits) {
            expected = liqUnits;
        }
    }

    // ============================================================
    // touchPosition MM decrease: kill feeAdj accounting mutant (1240)
    // ============================================================
    function test_touchPosition_mmDecrease_principalDelta_includesFeeAdj_asFeeComponent() public {
        // We want a deterministic, non-zero feeAdj during touchPosition.
        // Easiest way: use `_applyCoverageBurn` to create a positive pendingFeeAdj on token0,
        // then let `afterTouchPosition()` materialise it into `result.feeAdj`.
        //
        // With feeAdj > 0 (slash), the correct principal delta is:
        //   accruedFeesAfterAdj = feesAccrued - feeAdj
        //   principalDelta      = callerDelta - accruedFeesAfterAdj
        //                     = callerDelta - feesAccrued + feeAdj
        //
        // The mutant flips to `feesAccrued + feeAdj`, which would *reduce* principalDelta by `2*feeAdj`.

        // 1) Create a poolKey and use its derived PoolId everywhere.
        // IMPORTANT: `touchPosition` uses `p.poolKey.toId()` for PoolManager reads, so the PoolId used for
        // registration MUST match the PoolId derived from poolKey (otherwise PoolManager reads hit the wrong pool
        // and can trigger arithmetic panics in active-status commit accounting).
        MockLCC lcc0 = new MockLCC(address(0xA0));
        MockLCC lcc1 = new MockLCC(address(0xA1));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(lcc0)),
            currency1: Currency.wrap(address(lcc1)),
            fee: 0,
            tickSpacing: 60,
            // NOTE: In these unit tests we do not exercise Uniswap hook callbacks.
            // `hooks` only affects the derived PoolId via `poolKey.toId()`, so `address(0)` is fine
            // provided we use the same derived PoolId consistently for:
            // - position registration / harness pool setup, and
            // - mock PoolManager slot data keyed by PoolId.
            hooks: IHooks(address(0))
        });
        PoolId pId = key.toId();
        harness.setupPool(pId, _defaultCfg());

        // Register a position on the same PoolId and make sure RFS is closed before decrease
        // (calcRFS(requireClosedRfS=true) must not revert).
        ModifyLiquidityParams memory reg = ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: int256(uint256(1000)),
            salt: bytes32(uint256(20))
        });
        harness.registerPosition(owner, pId, reg);
        PositionId id = PositionLibrary.generateId(owner, reg);
        harness.setCommitmentMax(id, 1e18, 1e18);
        harness.setSettled(id, 1e18, 1e18);
        harness.setCumulativeDeficit(id, 0, 0);
        harness.setCommitmentDeficit(id, 0, 0);

        // 2) Make it an MM position (touchPosition validates commitId matches stored commitId).
        uint256 commitId = 1;
        harness.setPositionCommitId(id, commitId);

        // Ensure the pool manager reports non-zero current liquidity for this position, otherwise the
        // decrease path treats the position as fully inactive and can produce huge "excess" values.
        _pmSetPositionLiquidity(pId, PositionId.unwrap(id), 1000);

        // 3) Ensure poolManager reads are deterministic:
        // - tickCurrent in-range
        // - feeGrowthInside0X128 == 1*Q128
        _pmSetSlot0Tick(pId, 0);
        _pmSetFeeGrowthGlobals(pId, FixedPoint128.Q128, 0);
        _pmSetTickFeeGrowthOutside(pId, TICK_LOWER, 0, 0);
        _pmSetTickFeeGrowthOutside(pId, TICK_UPPER, 0, 0);

        // 4) Create a small coverage burn on token1 deficit so fee token is token0, producing pendingFeeAdj.token0 > 0.
        // Choose parameters so feesBurn == 1000 (fits in int128 comfortably).
        // - liquidity = 10_000
        // - feeGrowthDelta0X128 = 1*Q128
        // - burnBase/ofDelta = 1
        // - bps = 1000 => burn = 10% of fees
        harness.setFeeGrowthInsideLast(id, 0, 0);
        harness.setCumulativeDeficit(id, 0, 10);
        harness.setCumulativeOutflows(id, 0, 10);
        harness.setOutflowsAtFeeSnap(id, 0, 0);
        harness.applyCoverageBurn(IPoolManager(address(pm)), id, pId, 1, 10, 10_000);

        (int256 pend0,) = harness.getPendingFeeAdj(id);
        assertGt(pend0, 0, "precondition: pendingFeeAdj(token0) should be > 0 to materialise a slash feeAdj");

        // 5) Build a minimal PositionContext with recorders/mocks so we can observe principalDelta effects.
        MockLiquidityHubRecorder hub = new MockLiquidityHubRecorder(address(lcc0), address(lcc1));
        MockMarketVaultPassthrough vault = new MockMarketVaultPassthrough();

        PositionContext memory ctx = PositionContext({
            poolManager: IPoolManager(address(pm)),
            liquidityHub: ILiquidityHub(address(hub)),
            // Not used on the decrease path in these tests.
            oracleHelper: IOracleHelper(address(0)),
            marketVault: IMarketVault(address(vault))
        });

        // 6) Perform an MM decrease touchPosition (non-seizing) so _processMMOperations uses `principalDelta`.
        // Keep requiredSettlementDelta trivial by leaving no excess settled after commitment update.
        TouchPositionParams memory tp = TouchPositionParams({
            owner: owner,
            poolKey: key,
            params: ModifyLiquidityParams({
                tickLower: reg.tickLower,
                tickUpper: reg.tickUpper,
                liquidityDelta: -100, // decrease
                salt: reg.salt
            }),
            callerDelta: toBalanceDelta(int128(int256(5000)), 0),
            feesAccrued: toBalanceDelta(int128(int256(2000)), 0),
            hookData: PositionModificationHookDataLib.encode(commitId, 0, owner)
        });

        harness.touchPosition(ctx, tp);

        // Assert we planned a cancellation on token0 with principalAmount0 == callerDelta - feesAccrued + feeAdj (slash).
        // feeAdj0 should equal the materialised pending adjustment (pend0) under current VTSFeeLib construction.
        uint256 expectedPrincipal0 = uint256(int256(5000 - 2000 + pend0));
        assertEq(hub.lastPrincipalAmount0(), expectedPrincipal0, "principalAmount0 should include +feeAdj for slash");
    }

    // ------------------------------------------------------------
    // Helpers for MockExtsloadPoolManager slot calculations
    // ------------------------------------------------------------
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    uint256 internal constant FEE_GROWTH_GLOBAL0_OFFSET = 1;
    uint256 internal constant TICKS_OFFSET = 4;
    uint256 internal constant POSITIONS_OFFSET = 6;

    function _pmSetSlot0Tick(PoolId pId, int24 tick) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(pId), POOLS_SLOT));
        uint160 sqrtPriceX96 = 1; // arbitrary non-zero
        uint24 tickU = uint24(uint32(int32(tick)));
        uint256 data = uint256(uint160(sqrtPriceX96)) | (uint256(tickU) << 160);
        pm.setSlot(stateSlot, bytes32(data));
    }

    function _pmSetPositionLiquidity(PoolId pId, bytes32 positionId, uint128 liquidity) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(pId), POOLS_SLOT));
        bytes32 positionMapping = bytes32(uint256(stateSlot) + POSITIONS_OFFSET);
        bytes32 slot = keccak256(abi.encodePacked(positionId, positionMapping));
        pm.setSlot(slot, bytes32(uint256(liquidity)));
    }

    function _pmSetFeeGrowthGlobals(PoolId pId, uint256 fg0, uint256 fg1) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(pId), POOLS_SLOT));
        bytes32 slot0 = bytes32(uint256(stateSlot) + FEE_GROWTH_GLOBAL0_OFFSET);
        pm.setSlot(slot0, bytes32(fg0));
        pm.setSlot(bytes32(uint256(slot0) + 1), bytes32(fg1));
    }

    function _pmSetTickFeeGrowthOutside(PoolId pId, int24 tick, uint256 outside0, uint256 outside1) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(pId), POOLS_SLOT));
        bytes32 ticksMappingSlot = bytes32(uint256(stateSlot) + TICKS_OFFSET);
        bytes32 tickInfoSlot = keccak256(abi.encodePacked(int256(tick), ticksMappingSlot));
        // getTickFeeGrowthOutside reads from tickInfoSlot+1 (outside0) and +2 (outside1)
        pm.setSlot(bytes32(uint256(tickInfoSlot) + 1), bytes32(outside0));
        pm.setSlot(bytes32(uint256(tickInfoSlot) + 2), bytes32(outside1));
    }

    function _getPositionStateLite(PositionId id)
        internal
        view
        returns (uint256 settled0, uint256 settled1, uint256 deficit0, uint256 deficit1)
    {
        (,, settled0, settled1, deficit0, deficit1) = harness.getPositionAccounting(id);
    }

    function _assertPoolTotalSettled(PoolId pId, uint256 exp0, uint256 exp1) internal view {
        (uint256 poolTotal0, uint256 poolTotal1) = harness.getPoolTotalSettled(pId);
        assertEq(poolTotal0, exp0, "pool totalSettled token0 should match commitment max");
        assertEq(poolTotal1, exp1, "pool totalSettled token1 should match commitment max");
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

    // ============================================================
    // _touchExistingIncrease MM path: kill Line 1134 mutant (base - s1 → base + s1)
    // Also kills Lines 1133 (excess0 arithmetic) indirectly.
    // ============================================================

    /// @notice Kills mutant at VTSPositionLib.sol:1134 where `baseAmountToSettle1 - s1` is mutated to `+ s1`.
    /// @dev This test verifies that when doing an MM increase with non-zero settled amounts, the
    ///      requiredSettlementDelta is computed as (baseAmountToSettle - settled), not (base + settled).
    ///      Under the mutant, the settlement delta would be far too large.
    function test_touchPosition_mmIncrease_requiredSettlementDelta_isBaseMinusSettled() public {
        PositionId id;

        {
            // 1) Set up a poolKey and derive PoolId from it (touchPosition uses poolKey.toId() for PM reads).
            MockLCC lcc0 = new MockLCC(address(0xB0));
            MockLCC lcc1 = new MockLCC(address(0xB1));
            address lcc0Addr = address(lcc0);
            address lcc1Addr = address(lcc1);
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(lcc0Addr),
                currency1: Currency.wrap(lcc1Addr),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });
            PoolId pId = key.toId();
            harness.setupPool(pId, _defaultCfg());

            // 2) Register an existing position (MM position).
            ModifyLiquidityParams memory reg = ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(1000)),
                salt: bytes32(uint256(40))
            });
            harness.registerPosition(owner, pId, reg);
            id = PositionLibrary.generateId(owner, reg);

            // 3) Set non-zero settled amounts so the delta arithmetic is observable.
            //    commitmentMax = 100e18, settled = 2e18 for both tokens.
            //    With baseVTSRate = 500 (5%), baseAmountToSettle = 100e18 * 0.05 = 5e18.
            //    Expected excess0 = 5e18 - 2e18 = 3e18, excess1 = 5e18 - 2e18 = 3e18.
            //    Under mutant: excess1 = 5e18 + 2e18 = 7e18 (wrong).
            harness.setCommitmentMax(id, 100e18, 100e18);
            harness.setSettled(id, 2e18, 2e18);
            harness.setPoolTotalSettled(pId, 2e18, 2e18);
            harness.setCumulativeDeficit(id, 0, 0);
            harness.setCommitmentDeficit(id, 0, 0);

            // 4) Set up PoolManager mock state.
            _pmSetSlot0Tick(pId, 0);
            _pmSetPositionLiquidity(pId, PositionId.unwrap(id), 1000);
            _pmSetFeeGrowthGlobals(pId, 0, 0);
            _pmSetTickFeeGrowthOutside(pId, TICK_LOWER, 0, 0);
            _pmSetTickFeeGrowthOutside(pId, TICK_UPPER, 0, 0);

            // 5) Make it an MM position.
            uint256 commitId = 1;
            harness.setPositionCommitId(id, commitId);
            harness.setCommitActivePositionCount(commitId, 1);

            // 7) Create a minimal PositionContext with mock LiquidityHub that will capture issue() calls.
            //    For MM increase, LCC issuance happens first, then settlement delta is accounted.
            MockLiquidityHubRecorder hub = new MockLiquidityHubRecorder(lcc0Addr, lcc1Addr);
            MockMarketVaultPassthrough vault = new MockMarketVaultPassthrough();

            PositionContext memory ctx = PositionContext({
                poolManager: IPoolManager(address(pm)),
                liquidityHub: ILiquidityHub(address(hub)),
                oracleHelper: IOracleHelper(address(0)),
                marketVault: IMarketVault(address(vault))
            });

            // 8) Build touchPosition params for a small liquidity increase (MM operation).
            //    liquidityDelta > 0 routes through _touchExistingIncrease.
            TouchPositionParams memory tp = TouchPositionParams({
                owner: owner,
                poolKey: key,
                params: ModifyLiquidityParams({
                    tickLower: reg.tickLower,
                    tickUpper: reg.tickUpper,
                    liquidityDelta: int256(uint256(100)),
                    salt: reg.salt
                }),
                callerDelta: toBalanceDelta(0, 0),
                feesAccrued: toBalanceDelta(0, 0),
                hookData: PositionModificationHookDataLib.encode(commitId, 0, owner)
            });

            // 9) Execute touchPosition and assert liquidity updated.
            TouchPositionResult memory result = harness.touchPosition(ctx, tp);
            // Started at 1000, added 100 => expected 1100.
            assertEq(result.pos.liquidity, 1100, "liquidity should increase by liqAdded");
        }

        // Assert on the *underlying* settlement deltas that were accounted for this MM op.
        // `touchPosition` records the settlement delta via `DynamicCurrencyDelta.accountUnderlyingSettlementDelta`,
        // which maps each LCC currency to its underlying currency (here: 0xB0 and 0xB1).
        //
        // IMPORTANT: `touchPosition` calls `_trackCommitment(...)` on increase, so commitmentMax (and therefore base)
        // can change slightly due to tick math + mulDivRoundingUp. We therefore compute expected excess using the
        // *post-touch* stored commitmentMax and settled amounts, to avoid brittle off-by-one failures.
        //
        // Under correct code: excess1 == baseAmountToSettle1 - s1.
        // Under the mutant at VTSPositionLib.sol:1134: excess1 == baseAmountToSettle1 + s1 (far larger),
        // so the underlying delta for token1 is wrong and this assertion fails (killing the mutant).
        (uint256 cm0, uint256 cm1, uint256 s0, uint256 s1,,) = harness.getPositionAccounting(id);
        (uint256 base0, uint256 base1) =
            LiquidityUtils.getBaseSettlementAmounts(cm0, cm1, DEFAULT_BASE_VTS_RATE, DEFAULT_BASE_VTS_RATE);
        uint256 expectedExcess0 = base0 > s0 ? base0 - s0 : 0;
        uint256 expectedExcess1 = base1 > s1 ? base1 - s1 : 0;

        // requiredSettlementDelta is constructed with `isNegative0=true,isNegative1=true`, so the underlying deltas
        // are negative (debt / amount-to-deposit).
        assertEq(
            harness.getUnderlyingDelta(Currency.wrap(address(0xB0)), owner),
            -int256(expectedExcess0),
            "underlying delta0 should equal (base - settled)"
        );
        assertEq(
            harness.getUnderlyingDelta(Currency.wrap(address(0xB1)), owner),
            -int256(expectedExcess1),
            "underlying delta1 should equal (base - settled)"
        );
    }

    // ============================================================
    // _touchExistingIncrease non-MM path: kill Lines 1137-1138 mutants (commitmentMax - s → + s)
    // ============================================================

    /// @notice Kills mutants at VTSPositionLib.sol:1137-1138 where `commitmentMaxima.tokenX - s{X}` is mutated to `+ s{X}`.
    /// @dev For non-MM increase, the settlement is applied directly via _sUpdateSettlement.
    ///      The delta passed should be (commitmentMax - settled), not (commitmentMax + settled).
    ///      Under the mutant, settled would overshoot commitmentMax.
    function test_touchPosition_nonMMIncrease_settledIsCommitmentMax() public {
        // 1) Set up a poolKey.
        MockLCC lcc0 = new MockLCC(address(0xC0C0));
        MockLCC lcc1 = new MockLCC(address(0xC1C1));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(lcc0)),
            currency1: Currency.wrap(address(lcc1)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PoolId pId = key.toId();
        harness.setupPool(pId, _defaultCfg());

        // 2) Register position.
        ModifyLiquidityParams memory reg = ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: int256(uint256(1000)),
            salt: bytes32(uint256(41))
        });
        harness.registerPosition(owner, pId, reg);
        PositionId id = PositionLibrary.generateId(owner, reg);

        // 3) Set initial state: commitmentMax = 10e18, settled = 3e18.
        //    On increase, new commitmentMax will grow, and settled should reach new commitmentMax.
        harness.setCommitmentMax(id, 10e18, 10e18);
        harness.setSettled(id, 3e18, 3e18);
        harness.setPoolTotalSettled(pId, 3e18, 3e18);
        harness.setCumulativeDeficit(id, 0, 0);
        harness.setCommitmentDeficit(id, 0, 0);

        // 4) Set up PoolManager mock.
        _pmSetSlot0Tick(pId, 0);
        _pmSetPositionLiquidity(pId, PositionId.unwrap(id), 1000);
        _pmSetFeeGrowthGlobals(pId, 0, 0);
        _pmSetTickFeeGrowthOutside(pId, TICK_LOWER, 0, 0);
        _pmSetTickFeeGrowthOutside(pId, TICK_UPPER, 0, 0);

        // 5) Create context (non-MM operation, so no MM hooks used).
        PositionContext memory ctx = PositionContext({
            poolManager: IPoolManager(address(pm)),
            liquidityHub: ILiquidityHub(address(0)),
            oracleHelper: IOracleHelper(address(0)),
            marketVault: IMarketVault(address(0))
        });

        // 6) Build touchPosition params (non-MM: empty hookData).
        uint128 liqAdded = 200;
        TouchPositionParams memory tp = TouchPositionParams({
            owner: owner,
            poolKey: key,
            params: ModifyLiquidityParams({
                tickLower: reg.tickLower,
                tickUpper: reg.tickUpper,
                liquidityDelta: int256(uint256(liqAdded)),
                salt: reg.salt
            }),
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: "" // non-MM
        });

        // 7) Execute.
        harness.touchPosition(ctx, tp);

        // 8) Assert using only contract-derived state:
        // For non-MM increases, the library settles the position up to its *new* `commitmentMax` in storage.
        (uint256 cm0, uint256 cm1, uint256 s0, uint256 s1,,) = harness.getPositionAccounting(id);
        assertEq(s0, cm0, "token0 settled should equal commitmentMax after non-MM increase");
        assertEq(s1, cm1, "token1 settled should equal commitmentMax after non-MM increase");
        _assertPoolTotalSettled(pId, cm0, cm1);
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

/// @notice Minimal PoolManager mock for StateLibrary-backed reads (extsload).
/// @dev Only implements extsload; callers must only use StateLibrary-style reads in tests.
contract MockExtsloadPoolManager {
    mapping(bytes32 => bytes32) internal slots;

    function setSlot(bytes32 slot, bytes32 value) external {
        slots[slot] = value;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return slots[slot];
    }

    function extsload(bytes32 slot, uint256 nSlots) external view returns (bytes32[] memory data) {
        data = new bytes32[](nSlots);
        for (uint256 i = 0; i < nSlots; i++) {
            data[i] = slots[bytes32(uint256(slot) + i)];
        }
    }

    // Minimal PoolManager-style getters used by `touchPosition` / `VTSPositionLib`.
    // These mirror Uniswap v4 storage layout (same as StateLibrary) but are served from our `slots` mapping.
    bytes32 internal constant POOLS_SLOT_LOCAL = bytes32(uint256(6));
    uint256 internal constant POSITIONS_OFFSET_LOCAL = 6;

    function getPositionLiquidity(PoolId poolId, bytes32 positionId) external view returns (uint128 liquidity) {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), POOLS_SLOT_LOCAL));
        bytes32 positionMapping = bytes32(uint256(stateSlot) + POSITIONS_OFFSET_LOCAL);
        bytes32 slot = keccak256(abi.encodePacked(positionId, positionMapping));
        return uint128(uint256(slots[slot]));
    }

    function getSlot0(PoolId poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), POOLS_SLOT_LOCAL));
        bytes32 data = slots[stateSlot];
        assembly ("memory-safe") {
            sqrtPriceX96 := and(data, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            tick := signextend(2, shr(160, data))
            protocolFee := and(shr(184, data), 0xFFFFFF)
            lpFee := and(shr(208, data), 0xFFFFFF)
        }
    }
}

/// @notice Minimal LCC mock for DynamicCurrencyDelta (needs underlying()).
contract MockLCC {
    address internal u;

    constructor(address underlying_) {
        u = underlying_;
    }

    function underlying() external view returns (address) {
        return u;
    }
}

/// @notice Minimal MarketVault mock (only used to satisfy interface; deposits never call it).
contract MockMarketVaultNoop {
    function lccs() external pure returns (address, address) {
        return (address(0), address(0));
    }

    function inMarketBalanceOf(Currency) external pure returns (uint256) {
        return 0;
    }
    function modifyLiquidities(BalanceDelta) external pure {}

    function tryModifyLiquidities(BalanceDelta d) external pure returns (BalanceDelta) {
        return d;
    }

    function tryModifyLiquiditiesWithRecipient(BalanceDelta d, address) external pure returns (BalanceDelta) {
        return d;
    }

    function dryModifyLiquidities(BalanceDelta d) external pure returns (BalanceDelta) {
        return d;
    }
}

/// @notice Passthrough market vault: returns the requested delta as "available" so no queuing occurs.
contract MockMarketVaultPassthrough is IMarketVault {
    function lccs() external pure returns (address, address) {
        return (address(0), address(0));
    }

    function inMarketBalanceOf(Currency) external pure returns (uint256) {
        return 0;
    }
    function modifyLiquidities(BalanceDelta) external pure {}

    function tryModifyLiquidities(BalanceDelta d) external pure returns (BalanceDelta) {
        return d;
    }

    function tryModifyLiquiditiesWithRecipient(BalanceDelta d, address) external pure returns (BalanceDelta) {
        return d;
    }

    function dryModifyLiquidities(BalanceDelta d) external pure returns (BalanceDelta) {
        return d;
    }
}

/// @notice LiquidityHub recorder for mutation tests: captures planCancelWithQueue amounts.
/// @dev Intentionally does NOT implement the full ILiquidityHub interface; we only need selectors that
///      VTSPositionLib calls in the specific test paths (issue + planCancelWithQueue).
contract MockLiquidityHubRecorder {
    address public token0;
    address public token1;
    uint256 public lastPrincipalAmount0;
    uint256 public lastPrincipalAmount1;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function issue(address, address, uint256) external {}

    function planCancelWithQueue(address currency, address, address, uint256 principalAmount, uint256, address)
        external
    {
        if (currency == token0) lastPrincipalAmount0 = principalAmount;
        if (currency == token1) lastPrincipalAmount1 = principalAmount;
    }
}

/// @notice Exposes internal CISE settle with a minimal standalone VTSStorage.
contract VTSPositionLibCISEExpose {
    VTSStorage internal s;

    function setupPool(PoolId poolId, MarketVTSConfiguration memory config) external {
        s.pools[poolId] = Pool({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            vtsConfig: config,
            isPaused: false
        });
    }

    function setPosition(PositionId id, address owner, PoolId poolId, uint128 liq) external {
        s.positions[id] = Position({
            owner: owner,
            poolId: poolId,
            commitId: 0,
            tickLower: -600,
            tickUpper: 600,
            liquidity: liq,
            isActive: true,
            salt: bytes32(0),
            checkpoint: RFSCheckpoint({
                openMask: 0, openSince0: 0, openSince1: 0, gracePeriodExtension0: 0, gracePeriodExtension1: 0
            })
        });
    }

    function setSettled(PositionId id, uint256 s0, uint256 s1) external {
        s.positionAccounting[id].settled.token0 = s0;
        s.positionAccounting[id].settled.token1 = s1;
    }

    function setCISEIndexLastX128(PositionId id, uint256 idx0, uint256 idx1) external {
        s.positionAccounting[id].ciseIndexLastX128.token0 = idx0;
        s.positionAccounting[id].ciseIndexLastX128.token1 = idx1;
    }

    function setPoolCoveragePerSettledIndexX128(PoolId poolId, uint256 idx0, uint256 idx1) external {
        s.poolAccounting[poolId].coveragePerSettledIndexX128.token0 = idx0;
        s.poolAccounting[poolId].coveragePerSettledIndexX128.token1 = idx1;
    }

    function settleSettledIndexedCoverageUsage(PositionId id) external {
        VTSPositionLib._settleSettledIndexedCoverageUsage(s, id);
    }

    function getCISEExposure(PositionId id) external view returns (uint256 e0, uint256 e1) {
        return (
            s.positionAccounting[id].ciseExposureSinceLastMod.token0,
            s.positionAccounting[id].ciseExposureSinceLastMod.token1
        );
    }

    function getPoolTotalCISEExposure(PoolId poolId) external view returns (uint256 e0, uint256 e1) {
        return (
            s.poolAccounting[poolId].totalCISEExposureSinceLastMod.token0,
            s.poolAccounting[poolId].totalCISEExposureSinceLastMod.token1
        );
    }
}

/// @notice Exposes internal DICE settle with a minimal standalone VTSStorage.
contract VTSPositionLibDICEExpose {
    VTSStorage internal s;

    function setupPool(PoolId poolId, MarketVTSConfiguration memory config) external {
        s.pools[poolId] = Pool({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            vtsConfig: config,
            isPaused: false
        });
    }

    function setPosition(PositionId id, address owner, PoolId poolId, uint128 liq) external {
        s.positions[id] = Position({
            owner: owner,
            poolId: poolId,
            commitId: 0,
            tickLower: -600,
            tickUpper: 600,
            liquidity: liq,
            isActive: true,
            salt: bytes32(0),
            checkpoint: RFSCheckpoint({
                openMask: 0, openSince0: 0, openSince1: 0, gracePeriodExtension0: 0, gracePeriodExtension1: 0
            })
        });
    }

    function setCumulativeDeficit(PositionId id, uint256 d0, uint256 d1) external {
        s.positionAccounting[id].cumulativeDeficit.token0 = d0;
        s.positionAccounting[id].cumulativeDeficit.token1 = d1;
    }

    function setCoverageIndexLastX128(PositionId id, uint256 idx0, uint256 idx1) external {
        s.positionAccounting[id].coverageIndexLastX128.token0 = idx0;
        s.positionAccounting[id].coverageIndexLastX128.token1 = idx1;
    }

    function setPoolCoveragePerDeficitIndexX128(PoolId poolId, uint256 idx0, uint256 idx1) external {
        s.poolAccounting[poolId].coveragePerDeficitIndexX128.token0 = idx0;
        s.poolAccounting[poolId].coveragePerDeficitIndexX128.token1 = idx1;
    }

    function setCumulativeOutflows(PositionId id, uint256 o0, uint256 o1) external {
        s.positionAccounting[id].cumulativeOutflows.token0 = o0;
        s.positionAccounting[id].cumulativeOutflows.token1 = o1;
    }

    function setOutflowsAtFeeSnap(PositionId id, uint256 snap0, uint256 snap1) external {
        s.positionAccounting[id].outflowsAtFeeSnap.token0 = snap0;
        s.positionAccounting[id].outflowsAtFeeSnap.token1 = snap1;
    }

    function setFeeGrowthInsideLast(PositionId id, uint256 fg0, uint256 fg1) external {
        s.positionAccounting[id].feeGrowthInsideLast.token0 = fg0;
        s.positionAccounting[id].feeGrowthInsideLast.token1 = fg1;
    }

    function settleDeficitIndexedCoverageUsage(IPoolManager poolManager, PositionId id) external {
        VTSPositionLib._settleDeficitIndexedCoverageUsage(s, poolManager, id);
    }

    function getPoolProtocolFeeAccrued(PoolId poolId) external view returns (uint256 fee0, uint256 fee1) {
        return (s.poolAccounting[poolId].protocolFeeAccrued.token0, s.poolAccounting[poolId].protocolFeeAccrued.token1);
    }
}


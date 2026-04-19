// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {VTSPositionLibHarness} from "./harnesses/VTSPositionLibHarness.sol";

import {MarketVTSConfiguration, TokenConfiguration, VaultSettlementIntent} from "../../src/types/VTS.sol";
import {VTSStorage} from "../../src/types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PositionId, PositionLibrary} from "../../src/types/Position.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {VTSPositionLib} from "../../src/libraries/VTSPositionLib.sol";
import {VTSLifecycleLinkedLib} from "../../src/libraries/VTSLifecycleLinkedLib.sol";
import {VTSFeeLinkedLib} from "../../src/libraries/VTSFeeLib.sol";
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
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PositionContext, TouchPositionParams, TouchPositionResult} from "../../src/types/VTS.sol";
import {PositionModificationHookDataLib} from "../../src/types/Position.sol";
import {IOracleHelper} from "../../src/interfaces/IOracleHelper.sol";
import {MockOracleHelper} from "../fuzz/mocks/MockOracleHelper.sol";

/// @notice Mutation-focused unit tests for VTSPositionLib that do NOT depend on MarketTestBase/_setupMarket.
/// @dev Purpose: avoid fixture panics masking kills. These tests aim to kill meaningful mutants via direct harness state.
contract VTSPositionLibMutationUnitTest is Test {
    using SafeCast for uint256;

    struct MMIncreaseInHookSetup {
        PoolKey key;
        PoolId poolId;
        PositionContext ctx;
        TouchPositionParams tp;
        PositionId positionId;
        Currency underlying0;
        Currency underlying1;
        uint256 required0;
        uint256 required1;
    }

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
        poolId = _poolKey().toId();
        owner = address(0xBEEF);
        harness.setupPool(poolId, _defaultCfg());
    }

    function _poolKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function _defaultPositionContext() internal view returns (PositionContext memory ctx) {
        ctx = PositionContext({
            poolManager: IPoolManager(address(pm)),
            liquidityHub: ILiquidityHub(address(0)),
            oracleHelper: IOracleHelper(address(0)),
            marketVault: IMarketVault(address(0))
        });
    }

    function _directRemoveTouchParams(ModifyLiquidityParams memory params)
        internal
        view
        returns (TouchPositionParams memory tp)
    {
        tp = TouchPositionParams({
            owner: owner,
            poolKey: _poolKey(),
            params: params,
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: ""
        });
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
    // _trackCommitment
    // ============================================================

    function test_trackCommitment_singleLiquidity_matchesCalculatedMaxima() public {
        (PositionId id, ModifyLiquidityParams memory p) = _register(bytes32(uint256(1)), 1);

        uint128 liq = 1e18;

        (uint256 exp0, uint256 exp1) = LiquidityUtils.calculateCommitmentMaxima(TICK_LOWER, TICK_UPPER, liq);

        harness.trackCommitmentFromLiveLiquidity(id, liq);

        (uint256 c0, uint256 c1,,,,) = harness.getPositionAccounting(id);
        assertEq(c0, exp0, "commitmentMax0 should equal calculated maxima");
        assertEq(c1, exp1, "commitmentMax1 should equal calculated maxima");
    }

    function test_trackCommitment_sequentialTotals_matchesSingleShotMaxima() public {
        (PositionId id,) = _register(bytes32(uint256(2)), 1);

        uint128 liqA = 1e18;
        uint128 liqB = 2e18;

        harness.trackCommitmentFromLiveLiquidity(id, liqA);
        (uint256 mid0, uint256 mid1,,,,) = harness.getPositionAccounting(id);
        (uint256 eMid0, uint256 eMid1) = LiquidityUtils.calculateCommitmentMaxima(TICK_LOWER, TICK_UPPER, liqA);
        assertEq(mid0, eMid0);
        assertEq(mid1, eMid1);

        uint128 total = liqA + liqB;
        harness.trackCommitmentFromLiveLiquidity(id, total);
        (uint256 c0, uint256 c1,,,,) = harness.getPositionAccounting(id);
        (uint256 exp0, uint256 exp1) = LiquidityUtils.calculateCommitmentMaxima(TICK_LOWER, TICK_UPPER, total);
        assertEq(c0, exp0, "final maxima must match total live liquidity");
        assertEq(c1, exp1, "final maxima must match total live liquidity");
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

    function test_updateSettlement_firstPostZeroSettlerCannotCaptureHistoricalCISEExposureOrBonus() public {
        uint128 liquidity = 1e18;
        uint256 settledAmount = 100e18;
        uint256 residual = 40e18;

        (PositionId id, ModifyLiquidityParams memory p) = _register(bytes32(uint256(0xC15E)), liquidity);

        harness.setCommitmentMax(id, settledAmount, 0);
        harness.incrementCoverage(poolId, 0, residual);

        _pmSetSlot0Tick(poolId, 0);
        _pmSetPositionLiquidity(poolId, PositionId.unwrap(id), liquidity);

        int256 applied = harness.updateSettlement(id, 0, int256(settledAmount));
        assertEq(applied, int256(settledAmount), "deposit should settle the triggering position");

        (uint256 totalSettled0,) = harness.getPoolTotalSettled(poolId);
        assertEq(totalSettled0, settledAmount, "pool totalSettled should reflect the first depositor");

        (uint256 poolIndex0,) = harness.getPoolCoveragePerSettledIndexX128(poolId);
        assertEq(poolIndex0, 0, "pool CISE index unchanged: zero-settled coverage is not deferred into CISE");

        (uint256 poolExposure0,) = harness.getPoolTotalCISEExposure(poolId);
        assertEq(poolExposure0, 0, "pool CISE denominator unchanged: no dead weight from zero-settled coverage");

        (uint256 ciseIndexLast0,) = harness.getCISEIndexLastX128(id);
        assertEq(ciseIndexLast0, 0, "position CISE checkpoint matches pool index when pool CISE index never moved");

        harness.setPoolSlashedPot(poolId, 0, 777e18);

        harness.settlePositionGrowths(IPoolManager(address(pm)), id);

        {
            (uint256 ciseExposure0, uint256 ciseExposure1) = harness.getCISEExposure(id);
            assertEq(ciseExposure0, 0, "settling growths must not realise CISE from zero-settled coverage epochs");
            assertEq(ciseExposure1, 0, "unaffected token should remain without exposure");
        }

        ModifyLiquidityParams memory pokeParams =
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 0, salt: p.salt});
        harness.touchPosition(_defaultPositionContext(), _directRemoveTouchParams(pokeParams));

        (, uint256 protocolFeeAfter1) = harness.getPoolSlashedPot(poolId);
        assertEq(protocolFeeAfter1, 777e18, "queued fee pot must remain untouched");

        (, int256 pending1) = harness.getPendingFeeAdj(id);
        assertEq(pending1, 0, "touch must not queue a negative pending bonus");
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
        harness.setPoolTotalSettled(poolId, 0, s1);

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
            // Assert position fee tracking moved by feesBurn on the fee token (pool slashedPot materialises on touch).
            (, uint256 poolFee1) = harness.getPoolSlashedPot(poolId);
            (, uint256 feesShared1) = harness.getFeesShared(id);
            (, int256 pendingAdj1) = harness.getPendingFeeAdj(id);
            assertEq(poolFee1, 0, "slashedPot(token1) is not incremented at applyCoverageBurn time");
            assertEq(feesShared1, feesBurn, "feesShared(token1) should equal feesBurn");
            assertEq(pendingAdj1, int256(feesBurn), "pendingFeeAdj(token1) should equal +feesBurn");
        }

        {
            // Outflow snap should advance by exercised outflow share (cov).
            (uint256 snap0,) = harness.getOutflowsAtFeeSnap(id);
            assertEq(snap0, cov, "outflowsAtFeeSnap(token0) should advance by burnBase");
        }

        {
            // Fee growth baseline should advance by the full consumed fee entitlement for the exercised window share.
            uint256 consumedFees = _expectedConsumedFeesToken1(
                feeGrowthInside1X128, feeGrowthInsideLast1X128, positionLiquidity, cov, ofDelta
            );
            uint256 growthInc = FullMath.mulDiv(consumedFees, FixedPoint128.Q128, positionLiquidity);
            (, uint256 fg1After) = harness.getFeeGrowthInsideLast(id);
            assertEq(
                fg1After,
                feeGrowthInsideLast1X128 + growthInc,
                "feeGrowthInsideLast(token1) should be lastCheckpoint + growthInc"
            );
        }
    }

    /// @dev Two partial fee-burn baseline steps with carry must match a single floor on the sum of consumed fees.
    function test_feeBurnGrowthRemainder_twoStepsEqualsSingleShotFloor() public pure {
        uint256 L = 1003;
        uint256 a1 = 100;
        uint256 a2 = 200;
        uint256 carry = 0;
        uint256 totalGrowth;
        uint256 g1;
        uint256 g2;
        (g1, carry) = LiquidityUtils.feeBurnGrowthIncWithRemainder(a1, L, carry);
        totalGrowth += g1;
        (g2, carry) = LiquidityUtils.feeBurnGrowthIncWithRemainder(a2, L, carry);
        totalGrowth += g2;
        uint256 expected = FullMath.mulDiv(a1 + a2, FixedPoint128.Q128, L);
        assertEq(totalGrowth, expected, "carried remainder should close Q128/L dust vs two independent floors");
        assertLt(carry, L, "final remainder must be < L");
    }

    function test_touchPosition_liquidityIncrease_clearsFeeBurnGrowthRemainder() public {
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
            salt: bytes32(uint256(0xFEE))
        });
        harness.registerPosition(owner, pId, reg);
        PositionId id = PositionLibrary.generateId(owner, reg);

        harness.setFeeBurnGrowthRemainder(id, 123, 456);
        (uint256 r0, uint256 r1) = harness.getFeeBurnGrowthRemainder(id);
        assertEq(r0, 123);
        assertEq(r1, 456);

        harness.setCommitmentMax(id, 10e18, 20e18);
        harness.setSettled(id, 3e18, 4e18);
        harness.setPoolTotalSettled(pId, 3e18, 4e18);
        harness.setCumulativeDeficit(id, 0, 0);
        harness.setCommitmentDeficit(id, 0, 0);

        _pmSetSlot0Tick(pId, 0);
        // Seed the live post-modify liquidity that touchPosition observes from PoolManager on increase.
        _pmSetPositionLiquidity(pId, PositionId.unwrap(id), 1200);

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
            hookData: ""
        });

        PositionContext memory ctx = PositionContext({
            poolManager: IPoolManager(address(pm)),
            liquidityHub: ILiquidityHub(address(0)),
            oracleHelper: IOracleHelper(address(0)),
            marketVault: IMarketVault(address(0))
        });

        TouchPositionResult memory result = harness.touchPositionAndFinalizeMM(ctx, tp);

        (r0, r1) = harness.getFeeBurnGrowthRemainder(id);
        assertEq(r0, 0, "liquidity change must reset fee-burn remainder token0");
        assertEq(r1, 0, "liquidity change must reset fee-burn remainder token1");
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

    function _expectedConsumedFeesToken1(
        uint256 feeGrowthInside1X128,
        uint256 feeGrowthInsideLast1X128,
        uint256 positionLiquidity,
        uint256 burnBase,
        uint256 ofDelta
    ) internal pure returns (uint256 consumedFees) {
        uint256 feeGrowthDelta1X128 = feeGrowthInside1X128 - feeGrowthInsideLast1X128;
        uint256 fees = FullMath.mulDiv(feeGrowthDelta1X128, positionLiquidity, FixedPoint128.Q128);
        consumedFees = FullMath.mulDiv(fees, burnBase, ofDelta);
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
        assertEq(poolExposure0, 0, "pool CISE denominator is eager on incrementCoverage/flush, not on position settle");
    }

    /// @notice Regression: repeated `_settleSettledIndexedCoverageUsage` with an unchanged pool index must not double-count CISE.
    function test_settleSettledIndexedCoverageUsage_secondCallNoExtraExposureWhenPoolIndexUnchanged() public {
        VTSPositionLibCISEExpose ex = new VTSPositionLibCISEExpose();
        PoolId p = PoolId.wrap(bytes32(uint256(0xC15E01)));
        ex.setupPool(p, _defaultCfg());

        PositionId id = PositionId.wrap(bytes32(uint256(0xB0B02)));
        ex.setPosition(id, address(0xCAFE), p, 1000);

        uint256 settled0 = 100e18;
        ex.setSettled(id, settled0, 0);

        uint256 indexLast0 = 2 * FixedPoint128.Q128;
        uint256 indexNow0 = 5 * FixedPoint128.Q128;
        ex.setCISEIndexLastX128(id, indexLast0, 0);
        ex.setPoolCoveragePerSettledIndexX128(p, indexNow0, 0);

        ex.settleSettledIndexedCoverageUsage(id);
        (uint256 exposureFirst,) = ex.getCISEExposure(id);

        ex.settleSettledIndexedCoverageUsage(id);
        (uint256 exposureSecond,) = ex.getCISEExposure(id);

        assertEq(exposureSecond, exposureFirst, "second settle with same pool index must not add exposure again");
    }

    function test_reconcileAfterStaleLiquidityMirrorRemove_clampsSettledBeforeLaterCISESettlement() public {
        uint128 liqBefore = 1000;
        uint128 liqAfter = 500;
        (PositionId id, ModifyLiquidityParams memory addParams) = _register(bytes32(uint256(0xAA55E)), liqBefore);

        (uint256 c0Before, uint256 c1Before) =
            LiquidityUtils.calculateCommitmentMaxima(TICK_LOWER, TICK_UPPER, liqBefore);
        harness.setCommitmentMax(id, c0Before, c1Before);
        harness.setSettled(id, c0Before, c1Before);
        harness.setPoolTotalSettled(poolId, c0Before, c1Before);

        // CISE index advanced while the stored liquidity mirror is stale; defer realisation until after reconciliation.
        harness.setCISEIndexLastX128(id, 0, 0);
        harness.setPoolCoveragePerSettledIndexX128(poolId, FixedPoint128.Q128, 0);

        _pmSetSlot0Tick(poolId, 0);
        _pmSetPositionLiquidity(poolId, PositionId.unwrap(id), liqAfter);
        harness.setPositionLiquidityMirror(id, liqBefore);

        ModifyLiquidityParams memory removeParams = ModifyLiquidityParams({
            tickLower: addParams.tickLower,
            tickUpper: addParams.tickUpper,
            liquidityDelta: -int256(uint256(liqBefore - liqAfter)),
            salt: addParams.salt
        });
        harness.touchPosition(_defaultPositionContext(), _directRemoveTouchParams(removeParams));

        (uint256 c0After,, uint256 s0After,,,) = harness.getPositionAccounting(id);
        assertLt(c0After, c0Before, "commitment max should decrease after stale-mirror remove reconcile");
        assertEq(s0After, c0After, "settled should clamp to the post-remove commitment max");

        Position memory posAfter = harness.getPosition(id);
        assertEq(posAfter.liquidity, liqAfter, "liquidity mirror should match live PoolManager liquidity");
        assertTrue(posAfter.isActive, "partially removed position should remain active");

        harness.settlePositionGrowths(IPoolManager(address(pm)), id);
        (uint256 exposure0,) = harness.getCISEExposure(id);
        assertEq(exposure0, s0After, "CISE exposure should realise from clamped settled baseline");
    }

    function test_reconcileAfterStaleLiquidityMirrorRemove_clampsSettledBeforeLaterCISESettlement_token1() public {
        uint128 liqBefore = 1000;
        uint128 liqAfter = 500;
        (PositionId id, ModifyLiquidityParams memory addParams) = _register(bytes32(uint256(0xAA560)), liqBefore);

        (uint256 c0Before, uint256 c1Before) =
            LiquidityUtils.calculateCommitmentMaxima(TICK_LOWER, TICK_UPPER, liqBefore);
        harness.setCommitmentMax(id, c0Before, c1Before);
        harness.setSettled(id, c0Before, c1Before);
        harness.setPoolTotalSettled(poolId, c0Before, c1Before);

        harness.setCISEIndexLastX128(id, 0, 0);
        harness.setPoolCoveragePerSettledIndexX128(poolId, 0, FixedPoint128.Q128);

        _pmSetSlot0Tick(poolId, 0);
        _pmSetPositionLiquidity(poolId, PositionId.unwrap(id), liqAfter);
        harness.setPositionLiquidityMirror(id, liqBefore);

        ModifyLiquidityParams memory removeParams = ModifyLiquidityParams({
            tickLower: addParams.tickLower,
            tickUpper: addParams.tickUpper,
            liquidityDelta: -int256(uint256(liqBefore - liqAfter)),
            salt: addParams.salt
        });
        harness.touchPosition(_defaultPositionContext(), _directRemoveTouchParams(removeParams));

        (, uint256 c1After,, uint256 s1After,,) = harness.getPositionAccounting(id);
        assertLt(c1After, c1Before, "commitment max token1 should decrease after stale-mirror remove reconcile");
        assertEq(s1After, c1After, "settled token1 should clamp to the post-remove commitment max");

        Position memory posAfter = harness.getPosition(id);
        assertEq(posAfter.liquidity, liqAfter, "liquidity mirror should match live PoolManager liquidity");
        assertTrue(posAfter.isActive, "partially removed position should remain active");

        harness.settlePositionGrowths(IPoolManager(address(pm)), id);
        (, uint256 exposure1) = harness.getCISEExposure(id);
        assertEq(exposure1, s1After, "CISE exposure token1 should realise from clamped settled baseline");
    }

    function test_reconcileAfterStaleLiquidityMirrorRemove_fullRemove_zeroesSettledAndMarksInactive() public {
        uint128 liqBefore = 1000;
        (PositionId id, ModifyLiquidityParams memory addParams) = _register(bytes32(uint256(0xAA55F)), liqBefore);

        (uint256 c0Before, uint256 c1Before) =
            LiquidityUtils.calculateCommitmentMaxima(TICK_LOWER, TICK_UPPER, liqBefore);
        harness.setCommitmentMax(id, c0Before, c1Before);
        harness.setSettled(id, c0Before, c1Before);
        harness.setPoolTotalSettled(poolId, c0Before, c1Before);

        _pmSetSlot0Tick(poolId, 0);
        _pmSetPositionLiquidity(poolId, PositionId.unwrap(id), 0);
        harness.setPositionLiquidityMirror(id, liqBefore);

        ModifyLiquidityParams memory removeParams = ModifyLiquidityParams({
            tickLower: addParams.tickLower,
            tickUpper: addParams.tickUpper,
            liquidityDelta: -int256(uint256(liqBefore)),
            salt: addParams.salt
        });
        harness.touchPosition(_defaultPositionContext(), _directRemoveTouchParams(removeParams));

        (uint256 c0After, uint256 c1After, uint256 s0After, uint256 s1After,,) = harness.getPositionAccounting(id);
        Position memory posAfter = harness.getPosition(id);
        (uint256 poolTotal0After, uint256 poolTotal1After) = harness.getPoolTotalSettled(poolId);

        assertEq(c0After, 0, "full remove should clear commitment max token0");
        assertEq(c1After, 0, "full remove should clear commitment max token1");
        assertEq(s0After, 0, "full remove should clear settled token0");
        assertEq(s1After, 0, "full remove should clear settled token1");
        assertEq(poolTotal0After, 0, "pool totalSettled token0 should be reduced");
        assertEq(poolTotal1After, 0, "pool totalSettled token1 should be reduced");
        assertEq(posAfter.liquidity, 0, "liquidity mirror should be zero after full remove");
        assertFalse(posAfter.isActive, "full remove should mark position inactive");
    }

    /// @notice Regression (finding 5): full deactivation clears all commitment-deficit fields (semantic cleanup).
    function test_reconcileAfterStaleLiquidityMirrorRemove_fullRemove_clearsCommitmentDeficitState() public {
        uint128 liqBefore = 1000;
        (PositionId id, ModifyLiquidityParams memory addParams) = _register(bytes32(uint256(0xAA60)), liqBefore);

        (uint256 c0Before, uint256 c1Before) =
            LiquidityUtils.calculateCommitmentMaxima(TICK_LOWER, TICK_UPPER, liqBefore);
        harness.setCommitmentMax(id, c0Before, c1Before);
        harness.setSettled(id, c0Before, c1Before);
        harness.setPoolTotalSettled(poolId, c0Before, c1Before);

        harness.setCommitmentDeficit(id, 42, 99);
        harness.setCommitmentDeficitSince(id, 12345, 67890);
        harness.setCommitmentDeficitBps(id, 500);

        _pmSetSlot0Tick(poolId, 0);
        _pmSetPositionLiquidity(poolId, PositionId.unwrap(id), 0);
        harness.setPositionLiquidityMirror(id, liqBefore);

        ModifyLiquidityParams memory removeParams = ModifyLiquidityParams({
            tickLower: addParams.tickLower,
            tickUpper: addParams.tickUpper,
            liquidityDelta: -int256(uint256(liqBefore)),
            salt: addParams.salt
        });
        harness.touchPosition(_defaultPositionContext(), _directRemoveTouchParams(removeParams));

        (uint256 cd0, uint256 cd1) = harness.getCommitmentDeficit(id);
        assertEq(cd0, 0, "full remove should clear commitmentDeficit token0");
        assertEq(cd1, 0, "full remove should clear commitmentDeficit token1");
        (uint256 since0, uint256 since1) = harness.getCommitmentDeficitSince(id);
        assertEq(since0, 0, "full remove should clear commitmentDeficitSince0");
        assertEq(since1, 0, "full remove should clear commitmentDeficitSince1");
        assertEq(harness.getCommitmentDeficitBps(id), 0, "full remove should clear commitmentDeficitBps");
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

        // Stale stored commitment is irrelevant: touch recomputes from live PoolManager liquidity (post-decrease).
        uint128 liqRemoved = 500;
        uint256 newC0 = 10e18;
        uint256 newC1 = 20e18;
        harness.setCommitmentMax(id, newC0, newC1);

        // Settled above the post-decrease maxima so excess is positive.
        harness.setSettled(id, newC0, newC1 + 7e18);
        harness.setPoolTotalSettled(pId, newC0, newC1 + 7e18);
        harness.setCumulativeDeficit(id, 0, 0);
        harness.setCommitmentDeficit(id, 0, 0);

        _pmSetSlot0Tick(pId, 0);
        // Post-decrease live liquidity as PoolManager reports when CoreHook calls `touchPosition`.
        _pmSetPositionLiquidity(pId, PositionId.unwrap(id), 700);

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

        TouchPositionResult memory result = harness.touchPositionAndFinalizeMM(ctx, tp);

        // Pool reports post-modify liquidity 1200 - 500 == 700; commitmentMax == maxima(700).
        (uint256 expC0, uint256 expC1) = LiquidityUtils.calculateCommitmentMaxima(TICK_LOWER, TICK_UPPER, 700);

        (uint256 settled0, uint256 settled1, uint256 d0, uint256 d1) = _getPositionStateLite(id);
        assertEq(settled0, expC0, "token0 settled should clamp to live commitment max");
        assertEq(settled1, expC1, "token1 settled should clamp to live commitment max");
        assertEq(d0, 0, "token0 deficit should remain unchanged");
        assertEq(d1, 0, "token1 deficit should remain unchanged");

        _assertPoolTotalSettled(pId, expC0, expC1);
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
        // Post-modify live liquidity seen by touchPosition (1000 after +200 from 800).
        _pmSetPositionLiquidity(pId, PositionId.unwrap(id), 1000);

        (uint256 expC0, uint256 expC1) = LiquidityUtils.calculateCommitmentMaxima(TICK_LOWER, TICK_UPPER, 1000);

        TouchPositionParams memory tp = TouchPositionParams({
            owner: owner,
            poolKey: key,
            params: ModifyLiquidityParams({
                tickLower: reg.tickLower, tickUpper: reg.tickUpper, liquidityDelta: int256(uint256(200)), salt: reg.salt
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

        TouchPositionResult memory result = harness.touchPositionAndFinalizeMM(ctx, tp);

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

        // Assert some burn happened — queued as positive pending (slashedPot updates on later fee-processing touch).
        (, uint256 fee1) = ex.getPoolSlashedPot(p);
        (, int256 pending1) = ex.getPendingFeeAdj(id);
        assertEq(fee1, 0, "slashedPot token1 is not incremented during DICE settle accounting");
        assertGt(pending1, 0, "DICE settle should queue positive pendingFeeAdj on fee token1");
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

        // Partial deposit so RFS stays open after settle. Seizure sizing uses **pre-intervention** RFS (`R_pre`) for
        // exposure and φ = S/R_pre; exposureBps(R_pre,c1) may round down below baseVTSRate, so the base floor applies.
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
                true,
                false
            );
            settleAmount1 = settlementDelta.amount1();
        }

        {
            (bool rfsOpenAfter,) = harness.getRFS(id);
            assertTrue(rfsOpenAfter, "precondition: RFS must remain open after partial deposit");

            uint256 s1 = uint256(uint128(-settleAmount1));
            uint256 liqUnits = uint256(harness.getPosition(id).liquidity);
            uint256 expected = _expectedSeizedToken1Only(
                liqUnits, SEIZURE_BASE_VTS_RATE1, SEIZURE_C1, r1Before, s1, SEIZURE_MIN_RESIDUAL_UNITS
            );

            assertEq(seized, expected, "seized liquidity should use base-rate floor when rounding reduces exposureBps");
        }
    }

    /// @param r1Pre Outstanding RFS on token1 **before** the intervention (denominator for φ = S/R_pre).
    function _expectedSeizedToken1Only(
        uint256 liqUnits,
        uint256 baseVTSRate1,
        uint256 c1,
        uint256 r1Pre,
        uint256 s1,
        uint256 minResidualUnits
    ) internal pure returns (uint256 expected) {
        uint256 e1bpsRaw = LiquidityUtils.exposureBps(r1Pre, c1);
        uint256 e1bps = baseVTSRate1 > e1bpsRaw ? baseVTSRate1 : e1bpsRaw;
        uint256 p1bps = LiquidityUtils.settleOfRfsBps(s1, r1Pre);
        expected = LiquidityUtils.seizedUnitsFromBps(liqUnits, e1bps, p1bps);

        // Apply the same residual-threshold logic as `_calcSeizure`.
        uint256 minResidual = minResidualUnits == 0 ? 1 : minResidualUnits;
        if (expected < liqUnits && (liqUnits - expected) < minResidual) {
            expected = liqUnits;
        } else if (expected > liqUnits) {
            expected = liqUnits;
        }
    }

    /// @dev Full RfS close in one seizure settle must yield non-zero seized units (no early return on closed RFS).
    function test_onMMSettle_seizure_nonZero_whenRfSFullyClosedInSameTx_token1() public {
        {
            MarketVTSConfiguration memory cfg = _defaultCfg();
            cfg.token1.baseVTSRate = SEIZURE_BASE_VTS_RATE1;
            cfg.minResidualUnits = SEIZURE_MIN_RESIDUAL_UNITS;
            harness.setupPool(poolId, cfg);
        }

        (PositionId id,) = _register(bytes32(uint256(13)), 1000);
        harness.setCommitmentMax(id, 1e18, SEIZURE_C1);
        // Satisfy token0 lane so only token1 remains overdue; otherwise a token1-only deposit cannot fully close RFS.
        harness.setSettled(id, 1e18, 0);
        harness.setCumulativeDeficit(id, 0, 0);
        harness.setCommitmentDeficit(id, 0, 0);
        harness.setCoverageIndexLastX128(id, 0, 0);
        harness.setCISEIndexLastX128(id, 0, 0);
        harness.setPoolCoveragePerDeficitIndexX128(poolId, 0, 0);
        harness.setPoolCoveragePerSettledIndexX128(poolId, 0, 0);
        harness.setDeficitGrowthGlobal(poolId, 0, 0);
        harness.setInflowGrowthGlobal(poolId, 0, 0);
        harness.setDeficitGrowthInsideLast(id, 0, 0);
        harness.setInflowGrowthInsideLast(id, 0, 0);
        _pmSetSlot0Tick(poolId, 0);
        _pmSetPositionLiquidity(poolId, PositionId.unwrap(id), 0);

        MockLCC lcc0 = new MockLCC(address(0xC0));
        MockLCC lcc1 = new MockLCC(address(0xC1));

        (, BalanceDelta rfsDelta) = harness.getRFS(id);
        uint256 r1Full = uint256(int256(rfsDelta.amount1()));
        assertGt(r1Full, 0, "precondition: token1 RFS open");

        BalanceDelta delta = toBalanceDelta(0, -SafeCast.toInt128(r1Full));
        MockMarketVaultNoop vault = new MockMarketVaultNoop();
        (,, uint256 seized) = harness.onMMSettle(
            IPoolManager(address(pm)),
            IMarketVault(address(vault)),
            id,
            Currency.wrap(address(lcc0)),
            Currency.wrap(address(lcc1)),
            delta,
            true,
            false
        );
        assertGt(seized, 0, "full close should still size seizure from R_pre");
        (bool openAfter,) = harness.getRFS(id);
        assertFalse(openAfter, "RFS fully closed");
    }

    /// @dev Cured fraction uses S/R_pre: half of pre-intervention obligation yields partial seizure, not remainder-based 100%.
    function test_onMMSettle_seizure_phiUsesRPre_halfCure_token1() public {
        {
            MarketVTSConfiguration memory cfg = _defaultCfg();
            cfg.token1.baseVTSRate = 1000;
            cfg.minResidualUnits = SEIZURE_MIN_RESIDUAL_UNITS;
            harness.setupPool(poolId, cfg);
        }

        (PositionId id,) = _register(bytes32(uint256(14)), 1000);
        harness.setCommitmentMax(id, 1e18, 100e18);
        harness.setSettled(id, 0, 0);
        harness.setCumulativeDeficit(id, 0, 0);
        harness.setCommitmentDeficit(id, 0, 0);
        harness.setCoverageIndexLastX128(id, 0, 0);
        harness.setCISEIndexLastX128(id, 0, 0);
        harness.setPoolCoveragePerDeficitIndexX128(poolId, 0, 0);
        harness.setPoolCoveragePerSettledIndexX128(poolId, 0, 0);
        harness.setDeficitGrowthGlobal(poolId, 0, 0);
        harness.setInflowGrowthGlobal(poolId, 0, 0);
        harness.setDeficitGrowthInsideLast(id, 0, 0);
        harness.setInflowGrowthInsideLast(id, 0, 0);
        _pmSetSlot0Tick(poolId, 0);
        _pmSetPositionLiquidity(poolId, PositionId.unwrap(id), 0);

        MockLCC lcc0 = new MockLCC(address(0xD0));
        MockLCC lcc1 = new MockLCC(address(0xD1));

        (, BalanceDelta rfsDelta) = harness.getRFS(id);
        uint256 r1Pre = uint256(int256(rfsDelta.amount1()));
        assertGt(r1Pre, 10, "precondition: token1 RFS");
        uint256 half = r1Pre / 2;

        BalanceDelta delta = toBalanceDelta(0, -SafeCast.toInt128(half));
        MockMarketVaultNoop vault = new MockMarketVaultNoop();
        (,, uint256 seizedHalf) = harness.onMMSettle(
            IPoolManager(address(pm)),
            IMarketVault(address(vault)),
            id,
            Currency.wrap(address(lcc0)),
            Currency.wrap(address(lcc1)),
            delta,
            true,
            false
        );

        // Reset position accounting for apples-to-apples full cure on fresh clone is heavy; compare to closed-form full-lane seizure.
        uint256 liqUnits = uint256(harness.getPosition(id).liquidity);
        uint256 c1 = 100e18;
        uint256 e1bps = LiquidityUtils.exposureBps(r1Pre, c1);
        if (1000 > e1bps) e1bps = 1000;
        uint256 phiHalf = LiquidityUtils.settleOfRfsBps(half, r1Pre);
        uint256 phiFull = LiquidityUtils.settleOfRfsBps(r1Pre, r1Pre);
        uint256 expectHalf = LiquidityUtils.seizedUnitsFromBps(liqUnits, e1bps, phiHalf);
        uint256 expectFull = LiquidityUtils.seizedUnitsFromBps(liqUnits, e1bps, phiFull);
        assertEq(seizedHalf, expectHalf, "half cure should match phi=S/R_pre");
        assertLt(seizedHalf, expectFull, "half cure should seize less than full cure");
    }

    /// @dev Fully curing one lane while the other remains open: only the cured lane contributes; RFS stays open.
    function test_onMMSettle_seizure_oneLaneFullCure_otherLaneStillOpen() public {
        {
            MarketVTSConfiguration memory cfg = _defaultCfg();
            cfg.token0.baseVTSRate = 10_000;
            cfg.token1.baseVTSRate = 10_000;
            cfg.minResidualUnits = 1;
            harness.setupPool(poolId, cfg);
        }

        (PositionId id,) = _register(bytes32(uint256(15)), 1000);
        harness.setCommitmentMax(id, 100, 100);
        harness.setSettled(id, 0, 0);
        harness.setCumulativeDeficit(id, 0, 0);
        harness.setCommitmentDeficit(id, 0, 0);
        harness.setCoverageIndexLastX128(id, 0, 0);
        harness.setCISEIndexLastX128(id, 0, 0);
        harness.setPoolCoveragePerDeficitIndexX128(poolId, 0, 0);
        harness.setPoolCoveragePerSettledIndexX128(poolId, 0, 0);
        harness.setDeficitGrowthGlobal(poolId, 0, 0);
        harness.setInflowGrowthGlobal(poolId, 0, 0);
        harness.setDeficitGrowthInsideLast(id, 0, 0);
        harness.setInflowGrowthInsideLast(id, 0, 0);
        _pmSetSlot0Tick(poolId, 0);
        _pmSetPositionLiquidity(poolId, PositionId.unwrap(id), 0);

        MockLCC lcc0 = new MockLCC(address(0xE0));
        MockLCC lcc1 = new MockLCC(address(0xE1));

        uint256 seized;
        {
            (, BalanceDelta rfsPre) = harness.getRFS(id);
            assertTrue(rfsPre.amount0() > 0 && rfsPre.amount1() > 0, "both lanes need RFS");
            uint256 r0pre = uint256(int256(rfsPre.amount0()));
            BalanceDelta delta = toBalanceDelta(-SafeCast.toInt128(r0pre), int128(0));
            MockMarketVaultNoop vault = new MockMarketVaultNoop();
            (,, seized) = harness.onMMSettle(
                IPoolManager(address(pm)),
                IMarketVault(address(vault)),
                id,
                Currency.wrap(address(lcc0)),
                Currency.wrap(address(lcc1)),
                delta,
                true,
                false
            );
        }

        assertEq(seized, 1000, "single fully cured lane hits full liq (100% exposure, minResidual)");
        (bool stillOpen,) = harness.getRFS(id);
        assertTrue(stillOpen, "token1 lane should keep RFS open");
    }

    // ============================================================
    // touchPosition MM decrease: pool principal must ignore feeAdj (Scan 21 / SETTLE-03)
    // ============================================================
    function test_touchPosition_mmDecrease_principalDelta_isCallerMinusFees_ignoresMaterialisedFeeAdj() public {
        // Non-zero `result.feeAdj` after coverage slash must not change LCC principal for cancel/queue: PoolManager
        // passes hook-time `callerDelta = poolPrincipal + feesAccrued` into the hook; feeAdj is applied only after.
        // Correct principal: `callerDelta - feesAccrued` (not `callerDelta - (feesAccrued - feeAdj)`).
        //
        // We still use `_applyCoverageBurn` so `afterTouchPosition` materialises a positive `feeAdj` on token0, proving
        // the planned-cancel principal ignores that adjustment.

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
        harness.setPoolTotalSettled(pId, 1e18, 1e18);
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

        TouchPositionResult memory result = harness.touchPositionAndFinalizeMM(ctx, tp);
        assertGt(result.feeAdj.amount0(), 0, "precondition: materialised feeAdj(token0) should be > 0");

        int256 caller0 = int256(tp.callerDelta.amount0());
        int256 accrued0 = int256(tp.feesAccrued.amount0());
        uint256 expectedPrincipal0 = uint256(caller0 - accrued0);
        assertEq(
            hub.lastPrincipalAmount0(),
            expectedPrincipal0,
            "planned cancel principal must be pool principal only (callerDelta - feesAccrued)"
        );
    }

    /// @notice Policy B (finding #4): on MM decrease, same-touch positive slash materialises at most `feesAccrued` per leg.
    function test_touchPosition_mmDecrease_positiveSlash_capped_to_feesAccrued() public {
        MockLCC lcc0 = new MockLCC(address(0xA0));
        MockLCC lcc1 = new MockLCC(address(0xA1));
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
            salt: bytes32(uint256(23))
        });
        harness.registerPosition(owner, pId, reg);
        PositionId id = PositionLibrary.generateId(owner, reg);
        harness.setCommitmentMax(id, 1e18, 1e18);
        harness.setSettled(id, 1e18, 1e18);
        harness.setPoolTotalSettled(pId, 1e18, 1e18);
        harness.setCumulativeDeficit(id, 0, 0);
        harness.setCommitmentDeficit(id, 0, 0);

        uint256 commitId = 1;
        harness.setPositionCommitId(id, commitId);

        _pmSetPositionLiquidity(pId, PositionId.unwrap(id), 1000);
        _pmSetSlot0Tick(pId, 0);
        _pmSetFeeGrowthGlobals(pId, FixedPoint128.Q128, 0);
        _pmSetTickFeeGrowthOutside(pId, TICK_LOWER, 0, 0);
        _pmSetTickFeeGrowthOutside(pId, TICK_UPPER, 0, 0);

        harness.setPendingFeeAdj(id, 50_000, 0);

        MockLiquidityHubRecorder hub = new MockLiquidityHubRecorder(address(lcc0), address(lcc1));
        MockMarketVaultPassthrough vault = new MockMarketVaultPassthrough();
        PositionContext memory ctx = PositionContext({
            poolManager: IPoolManager(address(pm)),
            liquidityHub: ILiquidityHub(address(hub)),
            oracleHelper: IOracleHelper(address(0)),
            marketVault: IMarketVault(address(vault))
        });

        TouchPositionParams memory tp = TouchPositionParams({
            owner: owner,
            poolKey: key,
            params: ModifyLiquidityParams({
                tickLower: reg.tickLower, tickUpper: reg.tickUpper, liquidityDelta: -100, salt: reg.salt
            }),
            callerDelta: toBalanceDelta(int128(int256(5000)), 0),
            feesAccrued: toBalanceDelta(int128(int256(2000)), 0),
            hookData: PositionModificationHookDataLib.encode(commitId, 0, owner)
        });

        TouchPositionResult memory result = harness.touchPositionAndFinalizeMM(ctx, tp);

        assertEq(
            uint256(uint128(result.feeAdj.amount0())),
            2000,
            "materialised feeAdj(token0) must be capped to feesAccrued on decrease"
        );
        (int256 pendAfter0,) = harness.getPendingFeeAdj(id);
        assertEq(pendAfter0, 48_000, "excess positive pending must remain banked in pendingFeeAdj");
    }

    /// @notice Policy B applies to non-MM (direct LP) decreases as well: cap materialisation to the fee slice.
    function test_touchPosition_directLpDecrease_positiveSlash_capped_to_feesAccrued() public {
        MockLCC lcc0 = new MockLCC(address(0xA0));
        MockLCC lcc1 = new MockLCC(address(0xA1));
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
            salt: bytes32(uint256(24))
        });
        harness.registerPosition(owner, pId, reg);
        PositionId id = PositionLibrary.generateId(owner, reg);
        harness.setCommitmentMax(id, 1e18, 1e18);
        harness.setSettled(id, 1e18, 1e18);
        harness.setPoolTotalSettled(pId, 1e18, 1e18);
        harness.setCumulativeDeficit(id, 0, 0);
        harness.setCommitmentDeficit(id, 0, 0);

        _pmSetPositionLiquidity(pId, PositionId.unwrap(id), 1000);
        _pmSetSlot0Tick(pId, 0);
        _pmSetFeeGrowthGlobals(pId, FixedPoint128.Q128, 0);
        _pmSetTickFeeGrowthOutside(pId, TICK_LOWER, 0, 0);
        _pmSetTickFeeGrowthOutside(pId, TICK_UPPER, 0, 0);

        harness.setPendingFeeAdj(id, 50_000, 0);

        MockLiquidityHubRecorder hub = new MockLiquidityHubRecorder(address(lcc0), address(lcc1));
        MockMarketVaultPassthrough vault = new MockMarketVaultPassthrough();
        PositionContext memory ctx = PositionContext({
            poolManager: IPoolManager(address(pm)),
            liquidityHub: ILiquidityHub(address(hub)),
            oracleHelper: IOracleHelper(address(0)),
            marketVault: IMarketVault(address(vault))
        });

        TouchPositionParams memory tp = TouchPositionParams({
            owner: owner,
            poolKey: key,
            params: ModifyLiquidityParams({
                tickLower: reg.tickLower, tickUpper: reg.tickUpper, liquidityDelta: -100, salt: reg.salt
            }),
            callerDelta: toBalanceDelta(int128(int256(5000)), 0),
            feesAccrued: toBalanceDelta(int128(int256(2000)), 0),
            hookData: bytes("")
        });

        TouchPositionResult memory result = harness.touchPosition(ctx, tp);

        assertEq(uint256(uint128(result.feeAdj.amount0())), 2000);
        (int256 pendAfter0,) = harness.getPendingFeeAdj(id);
        assertEq(pendAfter0, 48_000);
    }

    /// @notice MM increase: LCC issuance must use `callerDelta - feesAccrued` (pool principal), not net of materialised `feeAdj`.
    function test_touchPosition_mmIncrease_issueAmount_isCallerMinusFees_ignoresMaterialisedFeeAdj() public {
        MockLCC lcc0 = new MockLCC(address(0xA0));
        MockLCC lcc1 = new MockLCC(address(0xA1));
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
            salt: bytes32(uint256(21))
        });
        harness.registerPosition(owner, pId, reg);
        PositionId id = PositionLibrary.generateId(owner, reg);
        harness.setCommitmentMax(id, 1e18, 1e18);
        harness.setSettled(id, 1e18, 1e18);
        harness.setPoolTotalSettled(pId, 1e18, 1e18);
        harness.setCumulativeDeficit(id, 0, 0);
        harness.setCommitmentDeficit(id, 0, 0);

        uint256 commitId = 1;
        harness.setPositionCommitId(id, commitId);

        _pmSetPositionLiquidity(pId, PositionId.unwrap(id), 1000);

        _pmSetSlot0Tick(pId, 0);
        _pmSetFeeGrowthGlobals(pId, FixedPoint128.Q128, 0);
        _pmSetTickFeeGrowthOutside(pId, TICK_LOWER, 0, 0);
        _pmSetTickFeeGrowthOutside(pId, TICK_UPPER, 0, 0);

        harness.setFeeGrowthInsideLast(id, 0, 0);
        harness.setCumulativeDeficit(id, 0, 10);
        harness.setCumulativeOutflows(id, 0, 10);
        harness.setOutflowsAtFeeSnap(id, 0, 0);
        harness.applyCoverageBurn(IPoolManager(address(pm)), id, pId, 1, 10, 10_000);

        MockLiquidityHubRecorder hub = new MockLiquidityHubRecorder(address(lcc0), address(lcc1));
        MockMarketVaultPassthrough vault = new MockMarketVaultPassthrough();
        MockOracleHelper oracle = new MockOracleHelper(address(0));

        PositionContext memory ctx = PositionContext({
            poolManager: IPoolManager(address(pm)),
            liquidityHub: ILiquidityHub(address(hub)),
            oracleHelper: IOracleHelper(address(oracle)),
            marketVault: IMarketVault(address(vault))
        });

        _pmSetPositionLiquidity(pId, PositionId.unwrap(id), 1100);

        TouchPositionParams memory tp = TouchPositionParams({
            owner: owner,
            poolKey: key,
            params: ModifyLiquidityParams({
                tickLower: reg.tickLower, tickUpper: reg.tickUpper, liquidityDelta: 100, salt: reg.salt
            }),
            callerDelta: toBalanceDelta(int128(-1000), 0),
            feesAccrued: toBalanceDelta(int128(2000), 0),
            hookData: PositionModificationHookDataLib.encode(commitId, 0, owner)
        });

        TouchPositionResult memory result = harness.touchPositionAndFinalizeMM(ctx, tp);
        assertGt(result.feeAdj.amount0(), 0, "precondition: materialised feeAdj(token0) should be > 0");

        int256 caller0 = int256(tp.callerDelta.amount0());
        int256 accrued0 = int256(tp.feesAccrued.amount0());
        uint256 expectedIssue0 = uint256(-(caller0 - accrued0));
        assertEq(expectedIssue0, 3000);
        assertEq(
            hub.lastIssueAmount0(),
            expectedIssue0,
            "issue must track pool principal (callerDelta - feesAccrued), not adjusted by feeAdj"
        );
    }

    /// @notice When pending fee slash materialises to a value far larger than `feesAccrued` on the same touch, issuance stays pool-principal-based.
    function test_touchPosition_mmIncrease_feeAdjExceedsFeesAccrued_issueStillPoolPrincipal() public {
        MockLCC lcc0 = new MockLCC(address(0xA0));
        MockLCC lcc1 = new MockLCC(address(0xA1));
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
            salt: bytes32(uint256(22))
        });
        harness.registerPosition(owner, pId, reg);
        PositionId id = PositionLibrary.generateId(owner, reg);
        harness.setCommitmentMax(id, 1e18, 1e18);
        harness.setSettled(id, 1e18, 1e18);
        harness.setPoolTotalSettled(pId, 1e18, 1e18);
        harness.setCumulativeDeficit(id, 0, 0);
        harness.setCommitmentDeficit(id, 0, 0);

        uint256 commitId = 1;
        harness.setPositionCommitId(id, commitId);

        _pmSetPositionLiquidity(pId, PositionId.unwrap(id), 1000);

        _pmSetSlot0Tick(pId, 0);
        _pmSetFeeGrowthGlobals(pId, FixedPoint128.Q128, 0);
        _pmSetTickFeeGrowthOutside(pId, TICK_LOWER, 0, 0);
        _pmSetTickFeeGrowthOutside(pId, TICK_UPPER, 0, 0);

        harness.setFeeGrowthInsideLast(id, 0, 0);
        harness.setCumulativeDeficit(id, 0, 10);
        harness.setCumulativeOutflows(id, 0, 10);
        harness.setOutflowsAtFeeSnap(id, 0, 0);
        harness.applyCoverageBurn(IPoolManager(address(pm)), id, pId, 1, 10, 10_000);
        harness.setPendingFeeAdj(id, 100_000, 0);

        MockLiquidityHubRecorder hub = new MockLiquidityHubRecorder(address(lcc0), address(lcc1));
        MockMarketVaultPassthrough vault = new MockMarketVaultPassthrough();
        MockOracleHelper oracle = new MockOracleHelper(address(0));

        PositionContext memory ctx = PositionContext({
            poolManager: IPoolManager(address(pm)),
            liquidityHub: ILiquidityHub(address(hub)),
            oracleHelper: IOracleHelper(address(oracle)),
            marketVault: IMarketVault(address(vault))
        });

        _pmSetPositionLiquidity(pId, PositionId.unwrap(id), 1100);

        TouchPositionParams memory tp = TouchPositionParams({
            owner: owner,
            poolKey: key,
            params: ModifyLiquidityParams({
                tickLower: reg.tickLower, tickUpper: reg.tickUpper, liquidityDelta: 100, salt: reg.salt
            }),
            callerDelta: toBalanceDelta(int128(-2950), 0),
            feesAccrued: toBalanceDelta(int128(50), 0),
            hookData: PositionModificationHookDataLib.encode(commitId, 0, owner)
        });

        TouchPositionResult memory result = harness.touchPositionAndFinalizeMM(ctx, tp);
        assertGt(
            result.feeAdj.amount0(), 50, "materialised feeAdj should dwarf informational feesAccrued on this touch"
        );
        assertGt(tp.feesAccrued.amount0(), 0);

        int256 caller0 = int256(tp.callerDelta.amount0());
        int256 accrued0 = int256(tp.feesAccrued.amount0());
        uint256 expectedIssue0 = uint256(-(caller0 - accrued0));
        assertEq(expectedIssue0, 3000);
        assertEq(hub.lastIssueAmount0(), expectedIssue0);
    }

    /// @dev Algebraic guard: issued LCC on token0 equals absolute pool principal when that leg is a deposit.
    function testFuzz_mmIncrease_issueAlgebra_callerMinusFees(uint128 poolPrincipal, uint128 feesAccruedAmt) public {
        uint256 P = bound(uint256(poolPrincipal), 100, uint256(int256(type(int128).max)) / 2);
        uint256 F = bound(uint256(feesAccruedAmt), 0, P / 4);
        int256 caller = -int256(P) + int256(F);
        int256 feesI = int256(F);
        int256 principal = caller - feesI;
        assertEq(principal, -int256(P));
        uint256 issue = uint256(-principal);
        assertEq(issue, P);
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

        // delta > 0 && amount > 0 => 0 here: withdrawal-side netting of positive underlying delta is applied
        // earlier in onMMSettle, not via _calcDeltaClearance (phase-4 only calls this for amount < 0).
        assertEq(clearanceExpose.calc(100, 50), 0, "pos/pos: no clearance via _calcDeltaClearance");
        assertEq(clearanceExpose.calc(50, 100), 0, "pos/pos: no clearance via _calcDeltaClearance (clamped row)");

        // Other quadrants => 0
        assertEq(clearanceExpose.calc(-100, 50), 0, "neg/pos: should clear 0");
        assertEq(clearanceExpose.calc(100, -50), 0, "pos/neg: should clear 0");
        assertEq(clearanceExpose.calc(0, -50), 0, "zero/neg: should clear 0");
        assertEq(clearanceExpose.calc(0, 50), 0, "zero/pos: should clear 0");
    }

    // ============================================================
    // Residual flushers: kill guard broadening mutants (291, 314)
    // ============================================================

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
            _pmSetPositionLiquidity(pId, PositionId.unwrap(id), uint128(10e18));
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
            TouchPositionResult memory result = harness.touchPositionAndFinalizeMM(ctx, tp);
            assertEq(
                result.pos.liquidity, uint128(10e18), "position liquidity should mirror post-modify PoolManager read"
            );
        }

        // Assert on the *underlying* settlement deltas that were accounted for this MM op.
        // `touchPosition` records the settlement delta via `OwnerCurrencyDelta.accountUnderlyingSettlementDelta`,
        // which maps each LCC currency to its underlying currency (here: 0xB0 and 0xB1).
        //
        // IMPORTANT: `touchPosition` recomputes `commitmentMax` from live liquidity on increase, so commitmentMax
        // (and therefore base) can change slightly due to tick math + mulDivRoundingUp. We therefore compute expected
        // excess using the *post-touch* stored commitmentMax and settled amounts, to avoid brittle off-by-one failures.
        //
        // Under correct code: excess1 == baseAmountToSettle1 - s1.
        // Under the mutant at VTSPositionLib.sol:1134: excess1 == baseAmountToSettle1 + s1 (far larger),
        // so the underlying delta for token1 is wrong and this assertion fails (killing the mutant).
        // Uses harness-local underlying delta (allowed in this mutation file when no issuance path exists; see project Solidity rules).
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

    function test_touchPosition_mmIncrease_exactProtocolCredit_settlesInHookAndClearsDelta() public {
        MMIncreaseInHookSetup memory setup = _setupMmIncreaseInHookSettlementCase(0, 0);
        setup.tp.hookData = PositionModificationHookDataLib.encodeWithInHookProtocolSettlement(
            1, 0, owner, setup.required0, setup.required1
        );
        harness.setUnderlyingDelta(setup.underlying0, owner, setup.required0.toInt128());
        harness.setUnderlyingDelta(setup.underlying1, owner, setup.required1.toInt128());
        harness.addMarketProducedCredit(setup.ctx.marketVault, setup.underlying0, setup.required0);
        harness.addMarketProducedCredit(setup.ctx.marketVault, setup.underlying1, setup.required1);

        harness.touchPositionAndFinalizeMM(setup.ctx, setup.tp);

        (,, uint256 settled0, uint256 settled1,,) = harness.getPositionAccounting(setup.positionId);
        assertEq(settled0, setup.required0, "token0 settled should increase by exact consumed credit");
        assertEq(settled1, setup.required1, "token1 settled should increase by exact consumed credit");
    }

    function test_touchPosition_mmIncrease_surplusProtocolCredit_leavesOnlyRemainder() public {
        MMIncreaseInHookSetup memory setup = _setupMmIncreaseInHookSettlementCase(0, 0);
        uint256 surplus0 = setup.required0 + 7e18;
        uint256 surplus1 = setup.required1 + 11e18;
        setup.tp.hookData =
            PositionModificationHookDataLib.encodeWithInHookProtocolSettlement(1, 0, owner, surplus0, surplus1);
        harness.setUnderlyingDelta(setup.underlying0, owner, surplus0.toInt128());
        harness.setUnderlyingDelta(setup.underlying1, owner, surplus1.toInt128());
        harness.addMarketProducedCredit(setup.ctx.marketVault, setup.underlying0, surplus0);
        harness.addMarketProducedCredit(setup.ctx.marketVault, setup.underlying1, surplus1);

        harness.touchPositionAndFinalizeMM(setup.ctx, setup.tp);

        (,, uint256 settled0, uint256 settled1,,) = harness.getPositionAccounting(setup.positionId);
        assertEq(settled0, setup.required0, "token0 settled should clamp to required settlement");
        assertEq(settled1, setup.required1, "token1 settled should clamp to required settlement");
    }

    function test_touchPosition_mmIncrease_mixedExactAndSurplus_preservesPerLaneAccounting() public {
        MMIncreaseInHookSetup memory setup = _setupMmIncreaseInHookSettlementCase(0, 0);
        uint256 surplus1 = setup.required1 + 13e18;
        setup.tp.hookData =
            PositionModificationHookDataLib.encodeWithInHookProtocolSettlement(1, 0, owner, setup.required0, surplus1);
        harness.setUnderlyingDelta(setup.underlying0, owner, setup.required0.toInt128());
        harness.setUnderlyingDelta(setup.underlying1, owner, surplus1.toInt128());
        harness.addMarketProducedCredit(setup.ctx.marketVault, setup.underlying0, setup.required0);
        harness.addMarketProducedCredit(setup.ctx.marketVault, setup.underlying1, surplus1);

        harness.touchPositionAndFinalizeMM(setup.ctx, setup.tp);

        (,, uint256 settled0, uint256 settled1,,) = harness.getPositionAccounting(setup.positionId);
        assertEq(settled0, setup.required0, "token0 exact-match credit should fully settle");
        assertEq(settled1, setup.required1, "token1 settled should clamp to the live requirement");
    }

    /// @notice In-hook MM increase: credit that cures `cumulativeDeficit` must not over-clear `requiredSettlementDelta`.
    /// @dev Regression for `_vUpdateSettlement`: `totalApplied` debits underlying credit, but only `settled` delta
    ///      should reduce the MM deposit requirement carried past in-hook settlement.
    function test_touchPosition_mmIncrease_cumulativeDeficit_doesNotOverClearRequiredSettlement() public {
        MMIncreaseInHookSetup memory setup = _setupMmIncreaseInHookSettlementCase(0, 0);
        uint256 d0 = 1e16;
        assertGt(setup.required0, d0, "precondition: token0 requirement must exceed deficit");
        harness.setCumulativeDeficit(setup.positionId, d0, 0);

        setup.tp.hookData = PositionModificationHookDataLib.encodeWithInHookProtocolSettlement(
            1, 0, owner, setup.required0, setup.required1
        );
        harness.setUnderlyingDelta(setup.underlying0, owner, setup.required0.toInt128());
        harness.setUnderlyingDelta(setup.underlying1, owner, setup.required1.toInt128());
        harness.addMarketProducedCredit(setup.ctx.marketVault, setup.underlying0, setup.required0);
        harness.addMarketProducedCredit(setup.ctx.marketVault, setup.underlying1, setup.required1);

        harness.touchPositionAndFinalizeMM(setup.ctx, setup.tp);

        (,, uint256 settled0, uint256 settled1, uint256 cd0After, uint256 cd1After) =
            harness.getPositionAccounting(setup.positionId);
        assertEq(cd0After, 0, "token0 cumulative deficit should be fully cured by credit");
        assertEq(cd1After, 0, "token1 cumulative deficit should remain zero");
        assertEq(settled1, setup.required1, "token1 should settle to requirement when no deficit");
        assertEq(
            settled0,
            setup.required0 - d0,
            "token0 settled should increase only by credit after deficit cure, not full credit"
        );
    }

    /// @notice Deficit lane + surplus credit: in-hook clamps to requirement; surplus remains; shortfall still owed for deficit leg.
    function test_touchPosition_mmIncrease_cumulativeDeficit_surplusProtocolCredit_preservesShortfallAndSurplus()
        public
    {
        MMIncreaseInHookSetup memory setup = _setupMmIncreaseInHookSettlementCase(0, 0);
        uint256 d0 = 1e16;
        assertGt(setup.required0, d0, "precondition: token0 requirement must exceed deficit");
        harness.setCumulativeDeficit(setup.positionId, d0, 0);

        uint256 surplus0 = setup.required0 + 9e18;
        uint256 surplus1 = setup.required1 + 5e18;
        setup.tp.hookData =
            PositionModificationHookDataLib.encodeWithInHookProtocolSettlement(1, 0, owner, surplus0, surplus1);
        harness.setUnderlyingDelta(setup.underlying0, owner, surplus0.toInt128());
        harness.setUnderlyingDelta(setup.underlying1, owner, surplus1.toInt128());
        harness.addMarketProducedCredit(setup.ctx.marketVault, setup.underlying0, surplus0);
        harness.addMarketProducedCredit(setup.ctx.marketVault, setup.underlying1, surplus1);

        harness.touchPositionAndFinalizeMM(setup.ctx, setup.tp);

        (,, uint256 settled0, uint256 settled1, uint256 cd0After, uint256 cd1After) =
            harness.getPositionAccounting(setup.positionId);
        assertEq(cd0After, 0, "token0 cumulative deficit should clear");
        assertEq(cd1After, 0, "token1 cumulative deficit should remain zero");
        assertEq(
            settled0,
            setup.required0 - d0,
            "token0 settled increases by credit after deficit; in-hook credit is clamped to required magnitude"
        );
        assertEq(settled1, setup.required1, "token1 settled should clamp to live requirement");
    }

    /// @notice Mixed lanes: cumulative deficit on token0 only; token1 exact credit — per-lane shortfall and full settle.
    function test_touchPosition_mmIncrease_mixedLane_cumulativeDeficitToken0_exactToken1() public {
        MMIncreaseInHookSetup memory setup = _setupMmIncreaseInHookSettlementCase(0, 0);
        uint256 d0 = 1e16;
        assertGt(setup.required0, d0, "precondition: token0 requirement must exceed deficit");
        harness.setCumulativeDeficit(setup.positionId, d0, 0);

        setup.tp.hookData = PositionModificationHookDataLib.encodeWithInHookProtocolSettlement(
            1, 0, owner, setup.required0, setup.required1
        );
        harness.setUnderlyingDelta(setup.underlying0, owner, setup.required0.toInt128());
        harness.setUnderlyingDelta(setup.underlying1, owner, setup.required1.toInt128());
        harness.addMarketProducedCredit(setup.ctx.marketVault, setup.underlying0, setup.required0);
        harness.addMarketProducedCredit(setup.ctx.marketVault, setup.underlying1, setup.required1);

        harness.touchPositionAndFinalizeMM(setup.ctx, setup.tp);

        (,, uint256 settled0, uint256 settled1, uint256 cd0After, uint256 cd1After) =
            harness.getPositionAccounting(setup.positionId);
        assertEq(cd0After, 0, "token0 deficit should clear");
        assertEq(cd1After, 0, "token1 deficit should stay zero");
        assertEq(settled0, setup.required0 - d0, "token0 settled increases by credit after deficit only");
        assertEq(settled1, setup.required1, "token1 should fully settle with no deficit");
    }

    /// @notice Two MM full burns in one logical batch must accumulate MMPM underlying settlement delta (SETTLE-03 + DELTA-01).
    /// @dev Regression: setter-style `accountUnderlyingSettlementDelta` would drop the first op's credit when a second
    ///      same-owner decrease runs; both positions export the same per-lane settled surplus here.
    ///      Uses harness-local underlying delta (allowed in this mutation file for OwnerCurrencyDelta accumulation regressions).
    function test_touchPosition_twoMmDecreases_sameOwner_accumulatesUnderlyingSettlementDelta() public {
        (PoolKey memory key, PoolId pId, PositionContext memory ctx,,) = _setupTwoMmBurnPositionsForAccumulationTest();

        PositionId idA = PositionLibrary.generateId(
            owner,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(1000)),
                salt: bytes32(uint256(701))
            })
        );
        PositionId idB = PositionLibrary.generateId(
            owner,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(1000)),
                salt: bytes32(uint256(702))
            })
        );

        _pmSetSlot0Tick(pId, 0);
        _pmSetFeeGrowthGlobals(pId, 0, 0);
        _pmSetTickFeeGrowthOutside(pId, TICK_LOWER, 0, 0);
        _pmSetTickFeeGrowthOutside(pId, TICK_UPPER, 0, 0);

        TouchPositionParams memory tpDec = TouchPositionParams({
            owner: owner,
            poolKey: key,
            params: ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: -int256(uint256(1000)),
                salt: bytes32(uint256(701))
            }),
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: PositionModificationHookDataLib.encode(1, 0, owner)
        });

        _pmSetPositionLiquidity(pId, PositionId.unwrap(idA), 0);
        harness.touchPositionAndFinalizeMM(ctx, tpDec);
        assertFalse(harness.getPosition(idA).isActive, "first full burn should deactivate position A");
        assertEq(harness.getCommitActivePositionCount(1), 1, "first full burn should decrement active positions");

        Currency cu0 = Currency.wrap(address(0xD0));
        Currency cu1 = Currency.wrap(address(0xD1));
        harness.snapshotUnderlyingDeltaPair(cu0, cu1, owner);
        (int256 d0, int256 d1) = harness.getLastUnderlyingDeltaSnapshot();
        assertTrue(d0 != 0 || d1 != 0, "first MM decrease should book non-zero underlying");

        _pmSetPositionLiquidity(pId, PositionId.unwrap(idB), 0);
        tpDec.params.salt = bytes32(uint256(702));
        harness.touchPositionAndFinalizeMM(ctx, tpDec);
        assertFalse(harness.getPosition(idB).isActive, "second full burn should deactivate position B");
        assertEq(harness.getCommitActivePositionCount(1), 0, "two full burns should clear active positions");

        harness.snapshotUnderlyingDeltaPair(cu0, cu1, owner);
        (int256 snapshot0, int256 snapshot1) = harness.getLastUnderlyingDeltaSnapshot();
        assertEq(snapshot0, d0 * 2, "token0 underlying delta should accumulate");
        assertEq(snapshot1, d1 * 2, "token1 underlying delta should accumulate");
    }

    function _setupMmIncreaseInHookSettlementCase(uint256 settled0, uint256 settled1)
        internal
        returns (MMIncreaseInHookSetup memory setup)
    {
        MockLCC lcc0 = new MockLCC(address(0xE0));
        MockLCC lcc1 = new MockLCC(address(0xE1));
        setup.key = PoolKey({
            currency0: Currency.wrap(address(lcc0)),
            currency1: Currency.wrap(address(lcc1)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        setup.poolId = setup.key.toId();
        harness.setupPool(setup.poolId, _defaultCfg());

        ModifyLiquidityParams memory reg = ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: int256(uint256(1000)),
            salt: bytes32(uint256(880))
        });
        harness.registerPosition(owner, setup.poolId, reg);
        setup.positionId = PositionLibrary.generateId(owner, reg);

        harness.setCommitmentMax(setup.positionId, 100e18, 100e18);
        harness.setSettled(setup.positionId, settled0, settled1);
        harness.setPoolTotalSettled(setup.poolId, settled0, settled1);
        harness.setCumulativeDeficit(setup.positionId, 0, 0);
        harness.setCommitmentDeficit(setup.positionId, 0, 0);

        _pmSetSlot0Tick(setup.poolId, 0);
        // Large live liquidity so MM base settlement comfortably exceeds typical cumulativeDeficit test amounts.
        _pmSetPositionLiquidity(setup.poolId, PositionId.unwrap(setup.positionId), uint128(10e18));
        _pmSetFeeGrowthGlobals(setup.poolId, 0, 0);
        _pmSetTickFeeGrowthOutside(setup.poolId, TICK_LOWER, 0, 0);
        _pmSetTickFeeGrowthOutside(setup.poolId, TICK_UPPER, 0, 0);

        harness.setPositionCommitId(setup.positionId, 1);
        harness.setCommitActivePositionCount(1, 1);

        setup.ctx = PositionContext({
            poolManager: IPoolManager(address(pm)),
            liquidityHub: ILiquidityHub(address(new MockLiquidityHubRecorder(address(lcc0), address(lcc1)))),
            oracleHelper: IOracleHelper(address(0)),
            marketVault: IMarketVault(address(new MockMarketVaultPassthrough()))
        });

        // PoolManager reports post-modify liquidity before VTS runs; recomputed commitment uses that value.
        uint128 liveAfterModify = uint128(10e18);
        (uint256 cm0, uint256 cm1) = LiquidityUtils.calculateCommitmentMaxima(TICK_LOWER, TICK_UPPER, liveAfterModify);
        (uint256 base0, uint256 base1) =
            LiquidityUtils.getBaseSettlementAmounts(cm0, cm1, DEFAULT_BASE_VTS_RATE, DEFAULT_BASE_VTS_RATE);
        setup.required0 = base0 > settled0 ? base0 - settled0 : 0;
        setup.required1 = base1 > settled1 ? base1 - settled1 : 0;
        setup.underlying0 = Currency.wrap(address(0xE0));
        setup.underlying1 = Currency.wrap(address(0xE1));
        setup.tp = TouchPositionParams({
            owner: owner,
            poolKey: setup.key,
            params: ModifyLiquidityParams({
                tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: int256(uint256(100)), salt: reg.salt
            }),
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: PositionModificationHookDataLib.encode(1, 0, owner)
        });
    }

    function _setupTwoMmBurnPositionsForAccumulationTest()
        internal
        returns (PoolKey memory key, PoolId pId, PositionContext memory ctx, uint256 b0, uint256 b1)
    {
        MockLCC lcc0 = new MockLCC(address(0xD0));
        MockLCC lcc1 = new MockLCC(address(0xD1));
        key = PoolKey({
            currency0: Currency.wrap(address(lcc0)),
            currency1: Currency.wrap(address(lcc1)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        pId = key.toId();
        harness.setupPool(pId, _defaultCfg());
        harness.setCommitExpiresAt(1, block.timestamp + 365 days);
        harness.setCommitActivePositionCount(1, 2);

        uint256 c0;
        uint256 c1;
        (c0, c1) = LiquidityUtils.calculateCommitmentMaxima(TICK_LOWER, TICK_UPPER, 1000);
        (b0, b1) = LiquidityUtils.getBaseSettlementAmounts(c0, c1, DEFAULT_BASE_VTS_RATE, DEFAULT_BASE_VTS_RATE);

        ModifyLiquidityParams memory regA = ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: int256(uint256(1000)),
            salt: bytes32(uint256(701))
        });
        harness.registerPosition(owner, pId, regA);
        PositionId idA = PositionLibrary.generateId(owner, regA);
        harness.initPositionSnapshots(IPoolManager(address(pm)), idA);
        harness.setCommitmentMax(idA, c0, c1);
        harness.setSettled(idA, b0, b1);
        harness.setCumulativeDeficit(idA, 0, 0);
        harness.setCommitmentDeficit(idA, 0, 0);
        harness.setPositionCommitId(idA, 1);

        ModifyLiquidityParams memory regB = ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: int256(uint256(1000)),
            salt: bytes32(uint256(702))
        });
        harness.registerPosition(owner, pId, regB);
        PositionId idB = PositionLibrary.generateId(owner, regB);
        harness.initPositionSnapshots(IPoolManager(address(pm)), idB);
        harness.setCommitmentMax(idB, c0, c1);
        harness.setSettled(idB, b0, b1);
        harness.setCumulativeDeficit(idB, 0, 0);
        harness.setCommitmentDeficit(idB, 0, 0);
        harness.setPositionCommitId(idB, 1);

        harness.setPoolTotalSettled(pId, b0 + b0, b1 + b1);

        MockLiquidityHubRecorder hub = new MockLiquidityHubRecorder(address(lcc0), address(lcc1));
        ctx = PositionContext({
            poolManager: IPoolManager(address(pm)),
            liquidityHub: ILiquidityHub(address(hub)),
            oracleHelper: IOracleHelper(address(0)),
            marketVault: IMarketVault(address(new MockMarketVaultPassthrough()))
        });
    }

    /// @notice Non-seizure MM increases revert while stored commitmentDeficit is non-zero.
    function test_touchPosition_mmIncrease_revertsWhenCommitmentDeficit_nonZero() public {
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

        ModifyLiquidityParams memory reg = ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: int256(uint256(1000)),
            salt: bytes32(uint256(42))
        });
        harness.registerPosition(owner, pId, reg);
        PositionId id = PositionLibrary.generateId(owner, reg);

        harness.setCommitmentMax(id, 100e18, 100e18);
        harness.setSettled(id, 2e18, 2e18);
        harness.setPoolTotalSettled(pId, 2e18, 2e18);
        harness.setCumulativeDeficit(id, 0, 0);
        harness.setCommitmentDeficit(id, 1, 0);

        _pmSetSlot0Tick(pId, 0);
        // Increase path reads live PoolManager liquidity before reverting on the deficit freeze guard.
        _pmSetPositionLiquidity(pId, PositionId.unwrap(id), 1100);
        _pmSetFeeGrowthGlobals(pId, 0, 0);
        _pmSetTickFeeGrowthOutside(pId, TICK_LOWER, 0, 0);
        _pmSetTickFeeGrowthOutside(pId, TICK_UPPER, 0, 0);

        uint256 commitId = 2;
        harness.setPositionCommitId(id, commitId);
        harness.setCommitActivePositionCount(commitId, 1);

        MockLiquidityHubRecorder hub = new MockLiquidityHubRecorder(lcc0Addr, lcc1Addr);
        MockMarketVaultPassthrough vault = new MockMarketVaultPassthrough();

        PositionContext memory ctx = PositionContext({
            poolManager: IPoolManager(address(pm)),
            liquidityHub: ILiquidityHub(address(hub)),
            oracleHelper: IOracleHelper(address(0)),
            marketVault: IMarketVault(address(vault))
        });

        TouchPositionParams memory tp = TouchPositionParams({
            owner: owner,
            poolKey: key,
            params: ModifyLiquidityParams({
                tickLower: reg.tickLower, tickUpper: reg.tickUpper, liquidityDelta: int256(uint256(100)), salt: reg.salt
            }),
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: PositionModificationHookDataLib.encode(commitId, 0, owner)
        });

        vm.expectRevert(abi.encodeWithSelector(Errors.CommitmentDeficitBlocksLiquidityChange.selector, id));
        harness.touchPosition(ctx, tp);
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
        // Seed the live post-modify liquidity that touchPosition observes from PoolManager on increase.
        _pmSetPositionLiquidity(pId, PositionId.unwrap(id), 1200);
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

    /// @notice Regression: `commitmentDeficitBps` clears only when both token deficits are zero (VTSPositionLib ~266-269).
    function test_updateSettlement_clearsCommitmentDeficitBps_whenBothCommitmentDeficitsCured() public {
        (PositionId id,) = _register(bytes32(uint256(51)), 1);
        harness.setCommitmentMax(id, 100e18, 100e18);
        harness.setSettled(id, 0, 0);
        harness.setPoolTotalSettled(poolId, 0, 0);
        harness.setCumulativeDeficit(id, 0, 0);
        harness.setCommitmentDeficit(id, 10e18, 5e18);
        harness.setCommitmentDeficitBps(id, 1234);

        harness.updateSettlement(id, 0, 10e18);
        assertEq(harness.getCommitmentDeficitBps(id), 1234);

        harness.updateSettlement(id, 1, 5e18);
        assertEq(harness.getCommitmentDeficitBps(id), 0);
    }

    /// @notice Regression: curing token0 commitment deficit clears `commitmentDeficitSince` for that side (VTSPositionLib ~257-259).
    function test_updateSettlement_clearsCommitmentDeficitSince_whenTokenDeficitFullyCured() public {
        (PositionId id,) = _register(bytes32(uint256(52)), 1);
        harness.setCommitmentMax(id, 100e18, 100e18);
        harness.setSettled(id, 0, 0);
        harness.setPoolTotalSettled(poolId, 0, 0);
        harness.setCumulativeDeficit(id, 0, 0);
        harness.setCommitmentDeficit(id, 10e18, 0);
        harness.setCommitmentDeficitSince(id, 12345, 0);

        harness.updateSettlement(id, 0, 10e18);
        (uint256 since0,) = harness.getCommitmentDeficitSince(id);
        assertEq(since0, 0);
    }

    /// @notice Regression: live PoolManager liquidity can change without touchPosition (e.g. paused remove); remainder must clear.
    function test_settlePositionGrowths_reconcilesStaleLiquidityMirror_clearsFeeBurnRemainder() public {
        (PositionId id,) = _register(bytes32(uint256(0xD1F7)), 1000);
        _pmSetSlot0Tick(poolId, 0);
        _pmSetPositionLiquidity(poolId, PositionId.unwrap(id), 500);
        harness.setPositionLiquidityMirror(id, 1000);
        harness.setFeeBurnGrowthRemainder(id, 123, 456);

        harness.setCoverageIndexLastX128(id, 0, 0);
        harness.setCISEIndexLastX128(id, 0, 0);
        harness.setPoolCoveragePerDeficitIndexX128(poolId, 0, 0);
        harness.setPoolCoveragePerSettledIndexX128(poolId, 0, 0);
        harness.setDeficitGrowthGlobal(poolId, 0, 0);
        harness.setInflowGrowthGlobal(poolId, 0, 0);
        harness.setDeficitGrowthInsideLast(id, 0, 0);
        harness.setInflowGrowthInsideLast(id, 0, 0);

        harness.settlePositionGrowths(IPoolManager(address(pm)), id);

        // Remainder must clear when mirror != live L; stored `pos.liquidity` is updated on `touchPosition`, not here.
        assertEq(harness.getPosition(id).liquidity, 1000);
        (uint256 r0, uint256 r1) = harness.getFeeBurnGrowthRemainder(id);
        assertEq(r0, 0);
        assertEq(r1, 0);
    }
}

/// @notice Exposes MM delta-clearance pure helper for truth-table tests.
contract VTSPositionLibDeltaClearanceExpose {
    function calc(int128 delta, int128 amount) external pure returns (int128) {
        return VTSLifecycleLinkedLib._calcDeltaClearance(delta, amount);
    }
}

/// @notice Exposes internal residual flushers with a minimal standalone VTSStorage.
contract VTSPositionLibResidualFlushExpose {
    VTSStorage internal s;

    function getPoolTotalCISEExposureSinceLastMod(PoolId poolId, uint8 tokenIndex) external view returns (uint256) {
        return tokenIndex == 0
            ? s.poolAccounting[poolId].totalCISEExposureSinceLastMod.token0
            : s.poolAccounting[poolId].totalCISEExposureSinceLastMod.token1;
    }

    function setDICE(PoolId poolId, uint8 tokenIndex, uint256 residual, uint256 principal, uint256 indexNow) external {
        if (tokenIndex == 0) {
            s.poolAccounting[poolId].coverageResidualDICE.token0 = residual;
            s.poolAccounting[poolId].totalDeficitPrincipal.token0 = principal;
            // `_flushCoverageResidualIfNeeded` advances `coveragePerResidualDeficitIndexX128`, not `coveragePerDeficitIndexX128`.
            s.poolAccounting[poolId].coveragePerResidualDeficitIndexX128.token0 = indexNow;
        } else {
            s.poolAccounting[poolId].coverageResidualDICE.token1 = residual;
            s.poolAccounting[poolId].totalDeficitPrincipal.token1 = principal;
            s.poolAccounting[poolId].coveragePerResidualDeficitIndexX128.token1 = indexNow;
        }
    }

    function getDICE(PoolId poolId, uint8 tokenIndex)
        external
        view
        returns (uint256 indexNow, uint256 residual, uint256 principal)
    {
        if (tokenIndex == 0) {
            indexNow = s.poolAccounting[poolId].coveragePerResidualDeficitIndexX128.token0;
            residual = s.poolAccounting[poolId].coverageResidualDICE.token0;
            principal = s.poolAccounting[poolId].totalDeficitPrincipal.token0;
        } else {
            indexNow = s.poolAccounting[poolId].coveragePerResidualDeficitIndexX128.token1;
            residual = s.poolAccounting[poolId].coverageResidualDICE.token1;
            principal = s.poolAccounting[poolId].totalDeficitPrincipal.token1;
        }
    }

    function flushDICE(PoolId poolId, uint8 tokenIndex) external {
        VTSFeeLinkedLib.flushCoverageResidualIfNeeded(s, poolId, tokenIndex);
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

/// @notice Minimal LCC mock for OwnerCurrencyDelta (needs underlying()).
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

    function tryModifyLiquidities(BalanceDelta balanceDelta) external pure returns (BalanceDelta) {
        return balanceDelta;
    }

    function tryModifyLiquiditiesWithRecipient(BalanceDelta balanceDelta, address)
        external
        pure
        returns (BalanceDelta)
    {
        return balanceDelta;
    }

    function dryModifyLiquidities(BalanceDelta balanceDelta) external pure returns (BalanceDelta) {
        return balanceDelta;
    }
}

/// @notice Passthrough market vault: returns the requested delta as "available" so no queuing occurs.
contract MockCanonicalVaultRef_Mutation {
    address public immutable marketFactory;

    constructor(address _marketFactory) {
        marketFactory = _marketFactory;
    }
}

contract MockMarketVaultPassthrough is IMarketVault {
    address internal immutable canonical = address(new MockCanonicalVaultRef_Mutation(address(this)));

    function marketId() external pure returns (bytes32) {
        return bytes32(0);
    }

    function canonicalVault() external view returns (address) {
        return canonical;
    }

    function lccs() external pure returns (address, address) {
        return (address(0), address(0));
    }

    function inMarketBalanceOf(Currency) external pure returns (uint256) {
        return 0;
    }
    function modifyLiquidities(BalanceDelta) external pure {}

    function modifyLiquidities(VaultSettlementIntent calldata) external pure {}

    function tryModifyLiquidities(BalanceDelta balanceDelta) external pure returns (BalanceDelta) {
        return balanceDelta;
    }

    function tryModifyLiquidities(VaultSettlementIntent calldata settlementIntent)
        external
        pure
        returns (BalanceDelta)
    {
        return settlementIntent.requestedDelta;
    }

    function tryModifyLiquiditiesWithRecipient(BalanceDelta balanceDelta, address)
        external
        pure
        returns (BalanceDelta)
    {
        return balanceDelta;
    }

    function tryModifyLiquiditiesWithRecipient(VaultSettlementIntent calldata settlementIntent, address)
        external
        pure
        returns (BalanceDelta)
    {
        return settlementIntent.requestedDelta;
    }

    function dryModifyLiquidities(BalanceDelta balanceDelta) external pure returns (BalanceDelta) {
        return balanceDelta;
    }

    function dryModifyLiquidities(VaultSettlementIntent calldata settlementIntent)
        external
        pure
        returns (BalanceDelta)
    {
        return settlementIntent.requestedDelta;
    }

    function decreaseLiquidityReserve(Currency, uint256) external pure {}

    function increaseLiquidityReserve(Currency, uint256) external pure {}
}

/// @notice LiquidityHub recorder for mutation tests: captures planCancelWithQueue amounts.
/// @dev Intentionally does NOT implement the full ILiquidityHub interface; we only need selectors that
///      VTSPositionLib calls in the specific test paths (issue + planCancelWithQueue).
contract MockLiquidityHubRecorder {
    address public token0;
    address public token1;
    uint256 public lastPrincipalAmount0;
    uint256 public lastPrincipalAmount1;
    uint256 public lastIssueAmount0;
    uint256 public lastIssueAmount1;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function issue(address lcc, address, uint256 amount) external {
        if (lcc == token0) lastIssueAmount0 = amount;
        if (lcc == token1) lastIssueAmount1 = amount;
    }

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
        VTSFeeLinkedLib.settleSettledIndexedCoverageUsage(s, id);
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
        VTSFeeLinkedLib.settleDeficitIndexedCoverageUsage(s, poolManager, id);
    }

    function getPoolSlashedPot(PoolId poolId) external view returns (uint256 pot0, uint256 pot1) {
        return (s.poolAccounting[poolId].slashedPot.token0, s.poolAccounting[poolId].slashedPot.token1);
    }

    function getPendingFeeAdj(PositionId id) external view returns (int256 adj0, int256 adj1) {
        return (s.positionAccounting[id].pendingFeeAdj.token0, s.positionAccounting[id].pendingFeeAdj.token1);
    }
}


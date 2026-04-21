// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {VTSPositionLibHarness} from "./harnesses/VTSPositionLibHarness.sol";

import {MarketVTSConfiguration, TokenConfiguration} from "../../src/types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PositionId, PositionLibrary} from "../../src/types/Position.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {VTSLifecycleLinkedLib} from "../../src/libraries/VTSLifecycleLinkedLib.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice Mutation-focused unit tests for `VTSPositionLib` paths that remain after fee-disablement.
/// @dev Legacy DICE / CISE / CSI / fee-adjust tests lived in the previous revision of this file.
contract VTSPositionLibMutationUnitTest is Test {
    VTSPositionLibHarness internal harness;
    VTSPositionLibDeltaClearanceExpose internal clearanceExpose;
    MockExtsloadPoolManager internal pm;

    PoolId internal poolId;
    address internal owner = address(0xBEEF);

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;

    uint256 internal constant DEFAULT_GRACE_PERIOD = 1 hours;
    uint256 internal constant DEFAULT_BASE_VTS_RATE = 500;
    uint256 internal constant DEFAULT_MAX_GRACE_PERIOD = 7 days;
    uint256 internal constant DEFAULT_MIN_RESIDUAL_UNITS = 1000;

    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    uint256 internal constant FEE_GROWTH_GLOBAL0_OFFSET = 1;
    uint256 internal constant TICKS_OFFSET = 4;
    uint256 internal constant POSITIONS_OFFSET = 6;

    function setUp() public {
        harness = new VTSPositionLibHarness();
        clearanceExpose = new VTSPositionLibDeltaClearanceExpose();
        pm = new MockExtsloadPoolManager();
        poolId = _poolKey().toId();
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

    function test_trackCommitment_singleLiquidity_matchesCalculatedMaxima() public {
        (PositionId id,) = _register(bytes32(uint256(1)), 1);
        uint128 liq = 1e18;
        (uint256 exp0, uint256 exp1) = LiquidityUtils.calculateCommitmentMaxima(TICK_LOWER, TICK_UPPER, liq);
        harness.trackCommitmentFromLiveLiquidity(id, liq);
        (uint256 c0, uint256 c1,,,,,,) = harness.getPositionAccounting(id);
        assertEq(c0, exp0);
        assertEq(c1, exp1);
    }

    function test_trackCommitment_reopensHeadroom_collapsesOverflowIntoLiveSettled() public {
        (PositionId id,) = _register(bytes32(uint256(77)), 1);
        harness.setCommitmentMax(id, 50e18, 0);
        harness.setSettled(id, 50e18, 0);
        harness.setSettledOverflow(id, 30e18, 0);
        harness.setPoolTotalSettled(poolId, 80e18, 0);

        uint128 baseLiq = 1e18;
        (uint256 baseC0,) = LiquidityUtils.calculateCommitmentMaxima(TICK_LOWER, TICK_UPPER, baseLiq);
        assertGt(baseC0, 0, "base commitment max should be non-zero");
        uint256 targetC0 = 100e18;
        uint128 liqHigh = uint128(FullMath.mulDiv(uint256(baseLiq), targetC0, baseC0));

        harness.trackCommitmentFromLiveLiquidity(id, liqHigh);

        (uint256 c0,, uint256 s0,,,, uint256 o0,) = harness.getPositionAccounting(id);
        assertGe(c0, 80e18, "commitment max should cover full effective settled");
        assertEq(s0, 80e18, "live settled should absorb prior overflow when headroom allows");
        assertEq(o0, 0, "overflow should collapse once effective fits under commitmentMax");
        (uint256 pool0,) = harness.getPoolTotalSettled(poolId);
        assertEq(pool0, 80e18, "pure split normalisation must not change pool totalSettled");
    }

    function test_trackCommitment_zeroLiquidity_movesResidualLiveSettledIntoOverflow() public {
        (PositionId id,) = _register(bytes32(uint256(78)), 1);
        harness.setCommitmentMax(id, 40e18, 0);
        harness.setSettled(id, 25e18, 0);
        harness.setSettledOverflow(id, 15e18, 0);
        harness.setPoolTotalSettled(poolId, 40e18, 0);
        harness.trackCommitmentFromLiveLiquidity(id, 0);
        (uint256 c0, uint256 c1, uint256 s0,, uint256 d0, uint256 d1, uint256 o0, uint256 o1) =
            harness.getPositionAccounting(id);
        assertEq(c0, 0, "commitment max token0 should clear at zero liquidity");
        assertEq(c1, 0, "commitment max token1 should clear at zero liquidity");
        assertEq(s0, 0, "live settled should be zero once commitment max is zero");
        assertEq(o0, 40e18, "all residual effective settled should move into overflow");
        assertEq(o1, 0, "token1 overflow should remain unchanged");
        assertEq(d0, 0, "deficit token0 should remain untouched");
        assertEq(d1, 0, "deficit token1 should remain untouched");
        (uint256 pool0,) = harness.getPoolTotalSettled(poolId);
        assertEq(pool0, 40e18, "canonical split must not disturb pool total settled");
    }

    /// @dev Regression: benign `_trackCommitment` with positive live liquidity must preserve seizure Q128 carry.
    function test_trackCommitment_preservesSeizureLiquidityCarry_whenLiveLiquidityNonZero() public {
        (PositionId id,) = _register(bytes32(uint256(771)), 1);
        uint128 liq = 1e18;
        harness.trackCommitmentFromLiveLiquidity(id, liq);
        harness.setSeizureLiquidityCarry(id, FixedPoint128.Q128 / 3, FixedPoint128.Q128 / 7);

        harness.trackCommitmentFromLiveLiquidity(id, liq);

        (uint256 sc0, uint256 sc1) = harness.getSeizureLiquidityCarry(id);
        assertEq(sc0, FixedPoint128.Q128 / 3);
        assertEq(sc1, FixedPoint128.Q128 / 7);
    }

    /// @dev Regression: recomputing `commitmentMax` from a different positive liquidity must not wipe seizure carry.
    function test_trackCommitment_preservesSeizureLiquidityCarry_onLiquidityChange() public {
        (PositionId id,) = _register(bytes32(uint256(772)), 1);
        harness.trackCommitmentFromLiveLiquidity(id, 1e18);
        harness.setSeizureLiquidityCarry(id, 42, 99);

        harness.trackCommitmentFromLiveLiquidity(id, 2e18);

        (uint256 sc0, uint256 sc1) = harness.getSeizureLiquidityCarry(id);
        assertEq(sc0, 42);
        assertEq(sc1, 99);
    }

    /// @dev Regression: terminal zero-liquidity path clears seizure carry alongside SETTLE-00 canonicalisation.
    function test_trackCommitment_zeroLiquidity_clearsSeizureLiquidityCarry() public {
        (PositionId id,) = _register(bytes32(uint256(773)), 1);
        harness.setCommitmentMax(id, 1000e18, 1000e18);
        harness.setSettled(id, 100e18, 50e18);
        harness.setSettledOverflow(id, 0, 0);
        harness.setSeizureLiquidityCarry(id, FixedPoint128.Q128 - 1, 123);

        harness.trackCommitmentFromLiveLiquidity(id, 0);

        (uint256 sc0, uint256 sc1) = harness.getSeizureLiquidityCarry(id);
        assertEq(sc0, 0);
        assertEq(sc1, 0);

        (uint256 c0, uint256 c1, uint256 s0, uint256 s1,,, uint256 o0, uint256 o1) = harness.getPositionAccounting(id);
        assertEq(c0, 0);
        assertEq(c1, 0);
        assertEq(s0, 0);
        assertEq(s1, 0);
        assertEq(o0, 100e18);
        assertEq(o1, 50e18);
    }

    function test_updateSettlement_updatesPoolTotalSettled_onDepositAndWithdrawal() public {
        (PositionId id,) = _register(bytes32(uint256(3)), 1);
        harness.setCommitmentMax(id, 1000e18, 0);
        harness.setSettled(id, 100e18, 0);
        harness.setPoolTotalSettled(poolId, 100e18, 0);

        assertEq(harness.updateSettlement(id, 0, 50e18), 50e18);
        (,, uint256 settledAfterIn,,,,,) = harness.getPositionAccounting(id);
        assertEq(settledAfterIn, 150e18);
        (uint256 poolTotalAfterIn,) = harness.getPoolTotalSettled(poolId);
        assertEq(poolTotalAfterIn, 150e18);

        assertEq(harness.updateSettlement(id, 0, -25e18), -25e18);
        (,, uint256 settledAfterOut,,,,,) = harness.getPositionAccounting(id);
        assertEq(settledAfterOut, 125e18);
        (uint256 poolTotalAfterOut,) = harness.getPoolTotalSettled(poolId);
        assertEq(poolTotalAfterOut, 125e18);
    }

    function test_updateSettlement_positiveDelta_routesHeadroomIntoSettledAndRemainderIntoOverflow() public {
        (PositionId id,) = _register(bytes32(uint256(31)), 1);
        harness.setCommitmentMax(id, 100e18, 0);
        harness.setSettled(id, 95e18, 0);
        harness.setPoolTotalSettled(poolId, 95e18, 0);

        assertEq(harness.updateSettlement(id, 0, int256(20e18)), int256(20e18));
        (,, uint256 settled0,,,, uint256 ov0,) = harness.getPositionAccounting(id);
        assertEq(settled0, 100e18);
        assertEq(ov0, 15e18);
        (uint256 pool0,) = harness.getPoolTotalSettled(poolId);
        assertEq(pool0, 115e18);
    }

    function test_updateSettlement_negativeDelta_drainsOverflowBeforeLiveSettled() public {
        (PositionId id,) = _register(bytes32(uint256(32)), 1);
        harness.setCommitmentMax(id, 50e18, 0);
        harness.setSettled(id, 50e18, 0);
        harness.setSettledOverflow(id, 30e18, 0);
        harness.setPoolTotalSettled(poolId, 80e18, 0);

        assertEq(harness.updateSettlement(id, 0, -40e18), -40e18);
        (,, uint256 settled0,,,, uint256 ov0,) = harness.getPositionAccounting(id);
        assertEq(settled0, 40e18);
        assertEq(ov0, 0);
        (uint256 pool0,) = harness.getPoolTotalSettled(poolId);
        assertEq(pool0, 40e18);
    }

    function test_updateSettlement_positiveDelta_netsCumulativeDeficitBeforeIncreasingSettled() public {
        (PositionId id,) = _register(bytes32(uint256(33)), 1);
        harness.setCommitmentMax(id, 100e18, 0);
        harness.setSettled(id, 10e18, 0);
        harness.setCumulativeDeficit(id, 20e18, 0);
        harness.setPoolTotalSettled(poolId, 10e18, 0);
        harness.setPoolTotalDeficitPrincipal(poolId, 20e18, 0);

        assertEq(harness.updateSettlement(id, 0, int256(15e18)), int256(15e18));

        (,, uint256 settled0,, uint256 deficit0,,, uint256 ov1) = harness.getPositionAccounting(id);
        assertEq(settled0, 10e18, "live settled should not grow until cumulative deficit is covered");
        assertEq(deficit0, 5e18, "cumulative deficit should be reduced first");
        assertEq(ov1, 0, "untouched lane state should remain zero");
        (uint256 poolSettled0,) = harness.getPoolTotalSettled(poolId);
        assertEq(poolSettled0, 10e18, "pool total settled should stay flat while only covering deficit");
        (uint256 poolPrincipal0,) = harness.getPoolTotalDeficitPrincipal(poolId);
        assertEq(poolPrincipal0, 5e18, "pool deficit principal should shrink by the covered amount");
    }

    function test_updateSettlement_positiveDelta_clearsCommitmentDeficitAndBpsOnlyWhenBothLanesResolved() public {
        (PositionId id,) = _register(bytes32(uint256(34)), 1);
        harness.setCommitmentMax(id, 100e18, 0);
        harness.setCommitmentDeficit(id, 30e18, 4e18);
        harness.setCommitmentDeficitSince(id, 123, 456);
        harness.setCommitmentDeficitBps(id, 777);

        assertEq(harness.updateSettlement(id, 0, int256(30e18)), int256(30e18));

        (uint256 cd0, uint256 cd1) = harness.getCommitmentDeficit(id);
        assertEq(cd0, 0, "token0 commitment deficit should clear");
        assertEq(cd1, 4e18, "token1 commitment deficit should remain outstanding");
        (uint256 since0, uint256 since1) = harness.getCommitmentDeficitSince(id);
        assertEq(since0, 0, "cleared lane should reset its timer");
        assertEq(since1, 456, "uncleared lane should keep its timer");
        assertEq(harness.getCommitmentDeficitBps(id), 777, "bps should persist while another lane remains insolvent");
    }

    function test_updateSettlement_positiveDelta_clearsCommitmentDeficitBpsOnceAllLanesResolved() public {
        (PositionId id,) = _register(bytes32(uint256(35)), 1);
        harness.setCommitmentMax(id, 100e18, 0);
        harness.setCommitmentDeficit(id, 30e18, 0);
        harness.setCommitmentDeficitSince(id, 123, 0);
        harness.setCommitmentDeficitBps(id, 777);

        assertEq(harness.updateSettlement(id, 0, int256(30e18)), int256(30e18));

        (uint256 cd0, uint256 cd1) = harness.getCommitmentDeficit(id);
        assertEq(cd0, 0);
        assertEq(cd1, 0);
        (uint256 since0, uint256 since1) = harness.getCommitmentDeficitSince(id);
        assertEq(since0, 0);
        assertEq(since1, 0);
        assertEq(harness.getCommitmentDeficitBps(id), 0, "bps should clear when both commitment-deficit lanes are zero");
    }

    function test_updateSettlement_inactiveRemnantCount_tracksCreateSteadyStateAndDrain() public {
        (PositionId id,) = _register(bytes32(uint256(36)), 1);
        uint256 commitId = 77;
        harness.setPositionCommitId(id, commitId);
        harness.setPositionActive(id, false);
        harness.setCommitmentMax(id, 100e18, 0);

        assertEq(harness.inactiveRemnantCount(commitId), 0, "count should start empty");

        assertEq(harness.updateSettlement(id, 0, int256(10e18)), int256(10e18));
        assertEq(harness.inactiveRemnantCount(commitId), 1, "first inactive remnant should increment count");

        assertEq(harness.updateSettlement(id, 0, int256(5e18)), int256(5e18));
        assertEq(
            harness.inactiveRemnantCount(commitId), 1, "additional settled while remnant exists should not double-count"
        );

        assertEq(harness.updateSettlement(id, 0, -int256(15e18)), -int256(15e18));
        assertEq(harness.inactiveRemnantCount(commitId), 0, "draining the last inactive remnant should decrement count");
        (,, uint256 settled0,,,, uint256 overflow0,) = harness.getPositionAccounting(id);
        assertEq(settled0, 0, "live settled should clamp to zero after full drain");
        assertEq(overflow0, 0, "overflow should clamp to zero after full drain");
    }

    function test_updateSettlement_twoChunksMatchesSingleStep_effectiveSplit() public {
        VTSPositionLibHarness h1 = new VTSPositionLibHarness();
        h1.setupPool(poolId, _defaultCfg());
        ModifyLiquidityParams memory p1 = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 1, salt: bytes32(uint256(41))
        });
        h1.registerPosition(owner, poolId, p1);
        PositionId id1 = PositionLibrary.generateId(owner, p1);
        h1.setCommitmentMax(id1, 100e18, 0);
        h1.setSettled(id1, 90e18, 0);
        h1.setPoolTotalSettled(poolId, 90e18, 0);
        h1.updateSettlement(id1, 0, 15e18);
        h1.updateSettlement(id1, 0, 15e18);
        (,, uint256 s1,,,, uint256 o1,) = h1.getPositionAccounting(id1);

        VTSPositionLibHarness h2 = new VTSPositionLibHarness();
        h2.setupPool(poolId, _defaultCfg());
        ModifyLiquidityParams memory p2 = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 1, salt: bytes32(uint256(42))
        });
        h2.registerPosition(owner, poolId, p2);
        PositionId id2 = PositionLibrary.generateId(owner, p2);
        h2.setCommitmentMax(id2, 100e18, 0);
        h2.setSettled(id2, 90e18, 0);
        h2.setPoolTotalSettled(poolId, 90e18, 0);
        h2.updateSettlement(id2, 0, 30e18);
        (,, uint256 s2,,,, uint256 o2,) = h2.getPositionAccounting(id2);

        assertEq(s1, s2);
        assertEq(o1, o2);
        assertEq(s1 + o1, 120e18);
    }

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

    function test_getRFS_commitmentDeficitInflatesAndClampsToCommitmentMax() public {
        (PositionId id,) = _register(bytes32(uint256(5)), 1);
        harness.setCommitmentMax(id, 0, 100e18);
        harness.setSettled(id, 0, 0);
        harness.setCumulativeDeficit(id, 0, 0);
        harness.setCommitmentDeficit(id, 0, 1000e18);
        (bool rfsOpen, BalanceDelta delta) = harness.getRFS(id);
        assertTrue(rfsOpen);
        assertEq(delta.amount1(), int128(int256(100e18)));
    }

    function test_initPositionSnapshots_clears_deficit_and_inflow_growth_carries() public {
        (PositionId id,) = _register(bytes32(uint256(42)), 1000);
        _pmSetSlot0Tick(poolId, 0);
        _pmSetPositionLiquidity(poolId, PositionId.unwrap(id), 1000);

        harness.setDeficitGrowthCarry(id, FixedPoint128.Q128 - 1, 123);
        harness.setInflowGrowthCarry(id, 456, FixedPoint128.Q128 / 2);

        harness.initPositionSnapshots(IPoolManager(address(pm)), id);

        (uint256 dc0, uint256 dc1) = harness.getDeficitGrowthCarry(id);
        (uint256 ic0, uint256 ic1) = harness.getInflowGrowthCarry(id);
        assertEq(dc0, 0);
        assertEq(dc1, 0);
        assertEq(ic0, 0);
        assertEq(ic1, 0);
    }

    function test_settlePositionDeficitGrowth_belowRange_accumulatesToken1Deficit_usingOutsideLowerMinusUpper() public {
        (PositionId id, ModifyLiquidityParams memory p) = _register(bytes32(uint256(10)), 1);
        harness.setDeficitGrowthGlobal(poolId, 0, 0);
        harness.setInflowGrowthGlobal(poolId, 0, 0);
        harness.setDeficitGrowthInsideLast(id, 0, 0);
        harness.setInflowGrowthInsideLast(id, 0, 0);

        uint128 liq = 1000;
        uint256 outsideLower1 = 10 * FixedPoint128.Q128;
        uint256 outsideUpper1 = 3 * FixedPoint128.Q128;
        harness.setDeficitGrowthOutside(poolId, p.tickLower, 0, outsideLower1);
        harness.setDeficitGrowthOutside(poolId, p.tickUpper, 0, outsideUpper1);
        _pmSetSlot0Tick(poolId, int24(p.tickLower - 100));
        _pmSetPositionLiquidity(poolId, PositionId.unwrap(id), liq);

        uint256 s1 = 2000;
        harness.setSettled(id, 0, s1);
        harness.setPoolTotalSettled(poolId, 0, s1);

        harness.settlePositionGrowths(IPoolManager(address(pm)), id);

        uint256 expAdd1 = 7 * uint256(liq);
        uint256 expDeficitIncrease = expAdd1 - s1;
        (,,, uint256 settled1, uint256 d0, uint256 d1,,) = harness.getPositionAccounting(id);
        assertEq(d0, 0);
        assertEq(d1, expDeficitIncrease);
        assertEq(settled1, 0);
        (, uint256 poolPrincipal1) = harness.getPoolTotalDeficitPrincipal(poolId);
        assertEq(poolPrincipal1, expDeficitIncrease);
    }

    function test_calcDeltaClearance_truthTable() public view {
        assertEq(clearanceExpose.calc(-100, -50), 50);
        assertEq(clearanceExpose.calc(-50, -100), 50);
        assertEq(clearanceExpose.calc(100, 50), 0);
        assertEq(clearanceExpose.calc(50, 100), 0);
        assertEq(clearanceExpose.calc(-100, 50), 0);
        assertEq(clearanceExpose.calc(100, -50), 0);
        assertEq(clearanceExpose.calc(0, -50), 0);
        assertEq(clearanceExpose.calc(0, 50), 0);
    }

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
        assertEq(totalGrowth, expected);
        assertLt(carry, L);
    }

    function _pmSetSlot0Tick(PoolId pId, int24 tick) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(pId), POOLS_SLOT));
        uint160 sqrtPriceX96 = 1;
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
}

contract VTSPositionLibDeltaClearanceExpose {
    function calc(int128 delta, int128 amount) external pure returns (int128) {
        return VTSLifecycleLinkedLib._calcDeltaClearance(delta, amount);
    }
}

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

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSLibTestBase} from "../base/VTSLibTestBase.sol";

import {VTSSwapLib} from "../../src/libraries/VTSSwapLib.sol";
import {VTSStorage} from "../../src/types/VTS.sol";

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";

import {TickUtils} from "../../src/libraries/TickUtils.sol";

/// @notice Small harness so we can assert reverts from internal library functions (via an external call frame).
contract VTSSwapLibHarness {
    VTSStorage internal s;

    function flipOutside(PoolId poolId, int24 tick, uint8 token, uint8 growthType) external {
        VTSSwapLib._flipOutside(s, poolId, tick, token, growthType);
    }
}

/// @notice Unit tests for VTSSwapLib branch coverage.
contract VTSSwapLibTest is VTSLibTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    VTSStorage internal s;
    VTSSwapLibHarness internal harness;

    struct ExpectedGrowth {
        uint256 deficit0;
        uint256 deficit1;
        uint256 inflow0;
        uint256 inflow1;
    }

    function _globalGrowth(PoolId poolId) internal view returns (ExpectedGrowth memory g) {
        g.deficit0 = s.poolAccounting[poolId].deficitGrowthGlobal.token0;
        g.deficit1 = s.poolAccounting[poolId].deficitGrowthGlobal.token1;
        g.inflow0 = s.poolAccounting[poolId].inflowGrowthGlobal.token0;
        g.inflow1 = s.poolAccounting[poolId].inflowGrowthGlobal.token1;
    }

    // TODO: May we wiser to try use native Uniswap v4 libs where this logic derives to harness... as this is a reimplementation of core/source logic.

    struct SimState {
        uint160 sqrtCurrent;
        uint128 segmentLiquidity;
        int24 stepTick;
    }

    struct SimIter {
        int24 boundedNext;
        bool initialized;
        uint160 sqrtTarget;
    }

    function _boundTick(int24 tick) internal pure returns (int24 bounded) {
        bounded = tick;
        if (bounded <= TickMath.MIN_TICK) return TickMath.MIN_TICK;
        if (bounded >= TickMath.MAX_TICK) return TickMath.MAX_TICK;
    }

    function _nextIter(PoolId poolId, int24 stepTick, int24 tickSpacing, bool zeroForOne, uint160 sqrtPAfter)
        internal
        view
        returns (SimIter memory it)
    {
        (int24 next, bool initialized) =
            TickUtils.nextInitializedTickWithinOneWord(manager, poolId, stepTick, tickSpacing, zeroForOne);
        it.initialized = initialized;
        it.boundedNext = _boundTick(next);

        uint160 sqrtNext = TickMath.getSqrtPriceAtTick(it.boundedNext);
        it.sqrtTarget = zeroForOne
            ? (sqrtPAfter > sqrtNext ? sqrtPAfter : sqrtNext)  // max(sqrtPAfter, sqrtNext)
            : (sqrtPAfter < sqrtNext ? sqrtPAfter : sqrtNext); // min(sqrtPAfter, sqrtNext)
    }

    function _applyLiquidityNet(PoolId poolId, uint128 segmentLiquidity, int24 boundedNext, bool zeroForOne)
        internal
        view
        returns (uint128 nextLiquidity)
    {
        (, int128 liquidityNet) = StateLibrary.getTickLiquidity(manager, poolId, boundedNext);
        if (zeroForOne) liquidityNet = -liquidityNet;

        nextLiquidity = segmentLiquidity;
        unchecked {
            if (liquidityNet < 0) {
                nextLiquidity = uint128(uint256(nextLiquidity) - uint256(uint128(-liquidityNet)));
            } else if (liquidityNet > 0) {
                nextLiquidity = uint128(uint256(nextLiquidity) + uint256(uint128(liquidityNet)));
            }
        }
    }

    function setUp() public override {
        // Use smaller liquidity to make tick-crossing swaps reliable and cheap in unit tests.
        initialLiquidity = 10e18;
        super.setUp();
        harness = new VTSSwapLibHarness();
    }

    function test_flipOutside_deficit_and_inflow_token0_and_token1() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(0xBEEF)));
        int24 tick = 60;

        // Deficit growth: token0
        s.poolAccounting[poolId].deficitGrowthGlobal.token0 = 1000;
        s.deficitGrowthOutside[poolId][tick].token0 = 111;
        VTSSwapLib._flipOutside(s, poolId, tick, 0, 0);
        assertEq(s.deficitGrowthOutside[poolId][tick].token0, 1000 - 111, "deficit outside token0 flip");

        // Deficit growth: token1
        s.poolAccounting[poolId].deficitGrowthGlobal.token1 = 2000;
        s.deficitGrowthOutside[poolId][tick].token1 = 222;
        VTSSwapLib._flipOutside(s, poolId, tick, 1, 0);
        assertEq(s.deficitGrowthOutside[poolId][tick].token1, 2000 - 222, "deficit outside token1 flip");

        // Inflow growth: token0
        s.poolAccounting[poolId].inflowGrowthGlobal.token0 = 3000;
        s.inflowGrowthOutside[poolId][tick].token0 = 333;
        VTSSwapLib._flipOutside(s, poolId, tick, 0, 1);
        assertEq(s.inflowGrowthOutside[poolId][tick].token0, 3000 - 333, "inflow outside token0 flip");

        // Inflow growth: token1
        s.poolAccounting[poolId].inflowGrowthGlobal.token1 = 4000;
        s.inflowGrowthOutside[poolId][tick].token1 = 444;
        VTSSwapLib._flipOutside(s, poolId, tick, 1, 1);
        assertEq(s.inflowGrowthOutside[poolId][tick].token1, 4000 - 444, "inflow outside token1 flip");
    }

    /// @notice VTSSwapLib._flipOutside(...) must be a strict no-op when called with an invalid token index (token > 1).
    function test_flipOutside_tokenIndexGt1_isNoop() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(0xCAFE)));
        int24 tick = -60;

        // Seed both globals and outside slots so accidental writes are observable.
        s.poolAccounting[poolId].deficitGrowthGlobal.token0 = 123;
        s.poolAccounting[poolId].deficitGrowthGlobal.token1 = 456;
        s.poolAccounting[poolId].inflowGrowthGlobal.token0 = 789;
        s.poolAccounting[poolId].inflowGrowthGlobal.token1 = 101112;

        s.deficitGrowthOutside[poolId][tick].token0 = 11;
        s.deficitGrowthOutside[poolId][tick].token1 = 22;
        s.inflowGrowthOutside[poolId][tick].token0 = 33;
        s.inflowGrowthOutside[poolId][tick].token1 = 44;

        // token > 1 should early return (no writes), for both growth types.
        uint8 tokenIndex = 2;
        VTSSwapLib._flipOutside(s, poolId, tick, tokenIndex, 0);
        VTSSwapLib._flipOutside(s, poolId, tick, tokenIndex, 1);

        assertEq(s.deficitGrowthOutside[poolId][tick].token0, 11, "deficit outside token0 unchanged");
        assertEq(s.deficitGrowthOutside[poolId][tick].token1, 22, "deficit outside token1 unchanged");
        assertEq(s.inflowGrowthOutside[poolId][tick].token0, 33, "inflow outside token0 unchanged");
        assertEq(s.inflowGrowthOutside[poolId][tick].token1, 44, "inflow outside token1 unchanged");
    }

    function test_flipOutside_invalidGrowthType_reverts() public {
        vm.expectRevert(bytes("VTSSwapLib: Invalid growthType"));
        harness.flipOutside(PoolId.wrap(bytes32(uint256(0xDEAD))), 0, 0, 2);
    }

    function test_accrueGlobalGrowth_skipsOnInvalidInputs_andAccruesOnValid() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(0xF00D)));

        // Deficit: invalid token index
        s.poolAccounting[poolId].deficitGrowthGlobal.token0 = 1;
        VTSSwapLib._accrueDeficitGlobalGrowth(s, poolId, 2, 1, 1);
        assertEq(s.poolAccounting[poolId].deficitGrowthGlobal.token0, 1, "invalid token should no-op");

        // Deficit: amount == 0
        VTSSwapLib._accrueDeficitGlobalGrowth(s, poolId, 0, 0, 1);
        assertEq(s.poolAccounting[poolId].deficitGrowthGlobal.token0, 1, "zero amount should no-op");

        // Deficit: liquidity == 0
        VTSSwapLib._accrueDeficitGlobalGrowth(s, poolId, 0, 1, 0);
        assertEq(s.poolAccounting[poolId].deficitGrowthGlobal.token0, 1, "zero liquidity should no-op");

        // Deficit: valid accrual
        VTSSwapLib._accrueDeficitGlobalGrowth(s, poolId, 0, 2e18, 10e18);
        assertGt(s.poolAccounting[poolId].deficitGrowthGlobal.token0, 1, "deficit growth should increase");

        // Inflow: invalid token index
        s.poolAccounting[poolId].inflowGrowthGlobal.token1 = 7;
        VTSSwapLib._accrueInflowGlobalGrowth(s, poolId, 3, 1, 1);
        assertEq(s.poolAccounting[poolId].inflowGrowthGlobal.token1, 7, "invalid token should no-op (inflow)");

        // Inflow: amount == 0
        VTSSwapLib._accrueInflowGlobalGrowth(s, poolId, 1, 0, 1);
        assertEq(s.poolAccounting[poolId].inflowGrowthGlobal.token1, 7, "zero amount should no-op (inflow)");

        // Inflow: liquidity == 0
        VTSSwapLib._accrueInflowGlobalGrowth(s, poolId, 1, 1, 0);
        assertEq(s.poolAccounting[poolId].inflowGrowthGlobal.token1, 7, "zero liquidity should no-op (inflow)");

        // Inflow: valid accrual
        VTSSwapLib._accrueInflowGlobalGrowth(s, poolId, 1, 3e18, 10e18);
        assertGt(s.poolAccounting[poolId].inflowGrowthGlobal.token1, 7, "inflow growth should increase");
    }

    function _expectedSegmentGrowth(bool zeroForOne, uint160 sqrtCurrent, uint160 sqrtTarget, uint128 liquidity)
        internal
        pure
        returns (ExpectedGrowth memory eg)
    {
        if (liquidity == 0 || sqrtTarget == sqrtCurrent) return eg;

        uint256 outSeg = zeroForOne
            ? SqrtPriceMath.getAmount1Delta(sqrtTarget, sqrtCurrent, liquidity, false)
            : SqrtPriceMath.getAmount0Delta(sqrtCurrent, sqrtTarget, liquidity, false);
        uint256 inNoFee = zeroForOne
            ? SqrtPriceMath.getAmount0Delta(sqrtCurrent, sqrtTarget, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(sqrtTarget, sqrtCurrent, liquidity, true);

        if (outSeg > 0) {
            uint256 dG = FullMath.mulDiv(outSeg, FixedPoint128.Q128, uint256(liquidity));
            if (zeroForOne) eg.deficit1 += dG;
            else eg.deficit0 += dG;
        }
        if (inNoFee > 0) {
            uint256 dG = FullMath.mulDiv(inNoFee, FixedPoint128.Q128, uint256(liquidity));
            if (zeroForOne) eg.inflow0 += dG;
            else eg.inflow1 += dG;
        }
    }

    function _simulateExpectedGrowthFromSwap(
        PoolId poolId,
        uint160 sqrtPBefore,
        uint160 sqrtPAfter,
        uint128 liqBefore,
        int24 tickSpacing
    )
        internal
        view
        returns (ExpectedGrowth memory eg, bool multiTick, bool zeroForOne, int24 tickBefore, int24 tickAfter)
    {
        tickBefore = TickMath.getTickAtSqrtPrice(sqrtPBefore);
        tickAfter = TickMath.getTickAtSqrtPrice(sqrtPAfter);
        multiTick = tickAfter != tickBefore;
        zeroForOne = tickAfter < tickBefore;

        if (!multiTick) {
            eg = _expectedSegmentGrowth(zeroForOne, sqrtPBefore, sqrtPAfter, liqBefore);
            return (eg, multiTick, zeroForOne, tickBefore, tickAfter);
        }

        SimState memory st = SimState({sqrtCurrent: sqrtPBefore, segmentLiquidity: liqBefore, stepTick: tickBefore});

        while (true) {
            SimIter memory it = _nextIter(poolId, st.stepTick, tickSpacing, zeroForOne, sqrtPAfter);

            if (st.segmentLiquidity > 0 && it.sqrtTarget != st.sqrtCurrent) {
                ExpectedGrowth memory seg =
                    _expectedSegmentGrowth(zeroForOne, st.sqrtCurrent, it.sqrtTarget, st.segmentLiquidity);
                eg.deficit0 += seg.deficit0;
                eg.deficit1 += seg.deficit1;
                eg.inflow0 += seg.inflow0;
                eg.inflow1 += seg.inflow1;
                st.sqrtCurrent = it.sqrtTarget;
            }

            if (it.sqrtTarget == sqrtPAfter) break;

            if (it.initialized) {
                st.segmentLiquidity = _applyLiquidityNet(poolId, st.segmentLiquidity, it.boundedNext, zeroForOne);
            }

            if (zeroForOne) {
                st.stepTick = it.boundedNext > TickMath.MIN_TICK ? (it.boundedNext - 1) : TickMath.MIN_TICK;
            } else {
                st.stepTick = it.boundedNext;
            }
        }

        return (eg, multiTick, zeroForOne, tickBefore, tickAfter);
    }

    function test_processSwap_intraTick_accrues_growth_and_direction_is_correct() public {
        PoolId poolId = corePoolKey.toId();

        uint160 sqrtPBefore;
        uint128 liqBefore;
        SwapParams memory params;
        BalanceDelta delta;

        {
            // Snapshot before-swap state.
            // IMPORTANT: if we start exactly on a tick boundary (e.g. sqrt == sqrtAtTick(0)), then *any* move
            // in the zeroForOne direction will immediately move to tick-1 (Uniswap tick rounding at boundaries).
            // To guarantee an intra-tick move, first "nudge" the price into the interior of the current tick.
            (sqrtPBefore,,,) = manager.getSlot0(poolId);
            int24 tickBefore = TickMath.getTickAtSqrtPrice(sqrtPBefore);
            uint160 sqrtLowerBound = TickMath.getSqrtPriceAtTick(tickBefore);
            if (sqrtPBefore == sqrtLowerBound) {
                // Nudge price up a hair (oneForZero) but keep it within the same tick.
                // Choose a limit just below the next tick's boundary so we can't cross it.
                uint160 sqrtUpperBound = TickMath.getSqrtPriceAtTick(tickBefore + 1);
                uint160 nudgeLimit = sqrtUpperBound - 1;
                SwapParams memory nudge =
                    SwapParams({zeroForOne: false, amountSpecified: -1e6, sqrtPriceLimitX96: nudgeLimit});
                swapRouter.swap(
                    corePoolKey,
                    nudge,
                    PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                    ZERO_BYTES
                );
                (sqrtPBefore,,,) = manager.getSlot0(poolId);
                tickBefore = TickMath.getTickAtSqrtPrice(sqrtPBefore);
                sqrtLowerBound = TickMath.getSqrtPriceAtTick(tickBefore);
                assertTrue(sqrtPBefore > sqrtLowerBound, "nudge must move price into tick interior");
            }

            liqBefore = manager.getLiquidity(poolId);

            // Pick a sqrtPriceLimit strictly within the current tick, so tick stays constant but sqrt moves.
            // For zeroForOne, price decreases (sqrt decreases), so set limit just above the tick's lower boundary.
            uint160 sqrtLimit = sqrtLowerBound + 1;
            require(sqrtLimit < sqrtPBefore, "invariant: must have room to move left without crossing tick");

            // Large exact input to drive price to the limit within the same tick.
            params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: sqrtLimit});
            delta = swapRouter.swap(
                corePoolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ZERO_BYTES
            );

            // Confirm the swap stayed intra-tick but moved price.
            (uint160 sqrtPAfter,,,) = manager.getSlot0(poolId);
            int24 tickAfter = TickMath.getTickAtSqrtPrice(sqrtPAfter);
            assertEq(tickAfter, tickBefore, "must remain intra-tick");
            assertTrue(sqrtPAfter != sqrtPBefore, "must move sqrt price to test intra-tick accrual");
        }

        ExpectedGrowth memory beforeGrowth = _globalGrowth(poolId);

        VTSSwapLib.processSwap(s, manager, corePoolKey, params, delta, sqrtPBefore, liqBefore);

        // For zeroForOne:
        // - output token is token1 => deficit accrues to token1
        // - input token is token0 (net of fees) => inflow accrues to token0
        ExpectedGrowth memory afterGrowth = _globalGrowth(poolId);
        assertEq(afterGrowth.deficit0, beforeGrowth.deficit0, "deficit token0 unchanged");
        assertGt(afterGrowth.deficit1, beforeGrowth.deficit1, "deficit token1 should accrue");
        assertGt(afterGrowth.inflow0, beforeGrowth.inflow0, "inflow token0 should accrue");
        assertEq(afterGrowth.inflow1, beforeGrowth.inflow1, "inflow token1 unchanged");
    }

    function test_processSwap_multiTick_crosses_and_accrues_growth() public {
        PoolId poolId = corePoolKey.toId();

        // Add extra liquidity ranges so we can cross:
        // - tick 60 with positive liquidityNet,
        // - tick 120 with zero liquidityNet (netting upper of one range with lower of the next),
        // - tick 180 with negative liquidityNet (upper tick of final range).
        // This improves branch coverage for VTSSwapLib's internal liquidity-net application.
        {
            int256 L = int256(initialLiquidity);
            modifyLiquidityRouter.modifyLiquidity(
                corePoolKey,
                ModifyLiquidityParams({
                    tickLower: 60, tickUpper: 120, liquidityDelta: 2 * L, salt: bytes32(uint256(1))
                }),
                ZERO_BYTES
            );
            modifyLiquidityRouter.modifyLiquidity(
                corePoolKey,
                ModifyLiquidityParams({
                    tickLower: 120, tickUpper: 180, liquidityDelta: 2 * L, salt: bytes32(uint256(2))
                }),
                ZERO_BYTES
            );
        }

        // Capture before-swap state
        (uint160 sqrtPBefore,,,) = manager.getSlot0(poolId);
        uint128 liqBefore = manager.getLiquidity(poolId);

        // Perform a large swap that should cross multiple initialised ticks (moving right).
        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: -1e18, sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT});
        BalanceDelta delta = swapRouter.swap(
            corePoolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ZERO_BYTES
        );

        (uint160 sqrtPAfter,,,) = manager.getSlot0(poolId);
        ExpectedGrowth memory expected;
        int24 tickAfter;
        {
            (ExpectedGrowth memory eg, bool multiTick, bool zf1, int24 tickBefore, int24 _tickAfter) =
                _simulateExpectedGrowthFromSwap(poolId, sqrtPBefore, sqrtPAfter, liqBefore, corePoolKey.tickSpacing);
            assertTrue(multiTick, "expected multi-tick swap");
            assertTrue(!zf1, "expected oneForZero (moving right)");
            assertTrue(_tickAfter > tickBefore, "expected tick to move right");
            expected = eg;
            tickAfter = _tickAfter;
        }

        // Emulate CoreHook.afterSwap calling VTSSwapLib with the before-swap snapshot.
        ExpectedGrowth memory beforeGrowth = _globalGrowth(poolId);
        VTSSwapLib.processSwap(s, manager, corePoolKey, params, delta, sqrtPBefore, liqBefore);

        // Exact expected global growth deltas (Q128 per liquidity) to kill arithmetic / liquidityNet mutants.
        ExpectedGrowth memory afterGrowth = _globalGrowth(poolId);
        assertEq(afterGrowth.deficit0, beforeGrowth.deficit0 + expected.deficit0, "deficit0 exact");
        assertEq(afterGrowth.deficit1, beforeGrowth.deficit1 + expected.deficit1, "deficit1 exact");
        assertEq(afterGrowth.inflow0, beforeGrowth.inflow0 + expected.inflow0, "inflow0 exact");
        assertEq(afterGrowth.inflow1, beforeGrowth.inflow1 + expected.inflow1, "inflow1 exact");

        // Also assert tick-cross outside flips are exercised for token=1 (kills missing _onTickCross(..., token=1)).
        // This test's liquidity configuration should cross tick 60 when moving right.
        int24 crossTick = 60;
        assertTrue(tickAfter >= crossTick, "must cross tick 60");
        assertTrue(s.inflowGrowthOutside[poolId][crossTick].token1 != 0, "inflow outside token1 must flip on cross");
    }

    function test_processSwap_intraTick_path_executes() public {
        PoolId poolId = corePoolKey.toId();

        // Force the intra-tick branch by calling with "before" == "after".
        // This is intentionally synthetic and exists to cover the intra-tick branch reliably.
        (uint160 sqrtPNow,,,) = manager.getSlot0(poolId);
        uint128 liq = manager.getLiquidity(poolId);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: 1, sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT});
        BalanceDelta delta = BalanceDelta.wrap(0);

        ExpectedGrowth memory beforeGrowth = _globalGrowth(poolId);

        // tickBefore == tickAfter and sqrtPBefore == sqrtPAfter, so intra-tick branch is taken and it exits early.
        VTSSwapLib.processSwap(s, manager, corePoolKey, params, delta, sqrtPNow, liq);

        // With sqrtPAfter == sqrtPNow and sqrtPBefore == sqrtPAtTick (close), growth may or may not accrue,
        // but we at least ensure the call succeeds and the branch is executed without reverting.
        ExpectedGrowth memory afterGrowth = _globalGrowth(poolId);
        assertEq(afterGrowth.deficit0, beforeGrowth.deficit0, "no unexpected deficit token0 change");
        assertEq(afterGrowth.deficit1, beforeGrowth.deficit1, "no unexpected deficit token1 change");
        assertEq(afterGrowth.inflow0, beforeGrowth.inflow0, "no unexpected inflow token0 change");
        assertEq(afterGrowth.inflow1, beforeGrowth.inflow1, "no unexpected inflow token1 change");
    }

    function test_processSwap_multiTick_zeroForOne_exactGrowth() public {
        PoolId poolId = corePoolKey.toId();

        // Add symmetric ranges on the left so we can cross negative ticks moving left (zeroForOne=true).
        {
            int256 L = int256(initialLiquidity);
            modifyLiquidityRouter.modifyLiquidity(
                corePoolKey,
                ModifyLiquidityParams({
                    tickLower: -180, tickUpper: -120, liquidityDelta: 2 * L, salt: bytes32(uint256(3))
                }),
                ZERO_BYTES
            );
            modifyLiquidityRouter.modifyLiquidity(
                corePoolKey,
                ModifyLiquidityParams({
                    tickLower: -120, tickUpper: -60, liquidityDelta: 2 * L, salt: bytes32(uint256(4))
                }),
                ZERO_BYTES
            );
        }

        (uint160 sqrtPBefore,,,) = manager.getSlot0(poolId);
        uint128 liqBefore = manager.getLiquidity(poolId);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT});
        BalanceDelta delta = swapRouter.swap(
            corePoolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ZERO_BYTES
        );

        (uint160 sqrtPAfter,,,) = manager.getSlot0(poolId);
        ExpectedGrowth memory expected;
        {
            (ExpectedGrowth memory eg, bool multiTick, bool zf1,,) =
                _simulateExpectedGrowthFromSwap(poolId, sqrtPBefore, sqrtPAfter, liqBefore, corePoolKey.tickSpacing);
            assertTrue(multiTick, "expected multi-tick swap");
            assertTrue(zf1, "expected zeroForOne (moving left)");
            expected = eg;
        }

        ExpectedGrowth memory beforeGrowth = _globalGrowth(poolId);
        VTSSwapLib.processSwap(s, manager, corePoolKey, params, delta, sqrtPBefore, liqBefore);

        ExpectedGrowth memory afterGrowth = _globalGrowth(poolId);
        assertEq(afterGrowth.deficit0, beforeGrowth.deficit0 + expected.deficit0, "deficit0 exact");
        assertEq(afterGrowth.deficit1, beforeGrowth.deficit1 + expected.deficit1, "deficit1 exact");
        assertEq(afterGrowth.inflow0, beforeGrowth.inflow0 + expected.inflow0, "inflow0 exact");
        assertEq(afterGrowth.inflow1, beforeGrowth.inflow1 + expected.inflow1, "inflow1 exact");
    }

    function test_onTickCross_flips_deficit_and_inflow_outside_for_both_tokens() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(0xB0B)));
        int24 tick = 120;

        // Seed globals and outside with non-zero values so flips are observable.
        s.poolAccounting[poolId].deficitGrowthGlobal.token0 = 100;
        s.poolAccounting[poolId].deficitGrowthGlobal.token1 = 200;
        s.poolAccounting[poolId].inflowGrowthGlobal.token0 = 300;
        s.poolAccounting[poolId].inflowGrowthGlobal.token1 = 400;

        s.deficitGrowthOutside[poolId][tick].token0 = 11;
        s.deficitGrowthOutside[poolId][tick].token1 = 22;
        s.inflowGrowthOutside[poolId][tick].token0 = 33;
        s.inflowGrowthOutside[poolId][tick].token1 = 44;

        VTSSwapLib._onTickCross(s, poolId, tick, 0);
        VTSSwapLib._onTickCross(s, poolId, tick, 1);

        // Flip rule: outside := global - outside
        assertEq(s.deficitGrowthOutside[poolId][tick].token0, 100 - 11, "deficit outside token0 flip");
        assertEq(s.deficitGrowthOutside[poolId][tick].token1, 200 - 22, "deficit outside token1 flip");
        assertEq(s.inflowGrowthOutside[poolId][tick].token0, 300 - 33, "inflow outside token0 flip");
        assertEq(s.inflowGrowthOutside[poolId][tick].token1, 400 - 44, "inflow outside token1 flip");
    }
}


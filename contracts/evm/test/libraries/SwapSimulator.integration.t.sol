// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

/**
 * @title SwapSimulator integration tests (grounding / realism)
 * @notice These tests intentionally use a real Uniswap v4 `PoolManager` (via `Deployers`) to ensure
 * `SwapSimulator.simulateSwap` is grounded in “real scenario” pool state and matches actual swap behaviour.
 *
 * Why this file exists:
 * - The unit tests (`SwapSimulator.t.sol`) are coverage-driven and use an `extsload` stub to deterministically
 *   hit branch edges. That’s great for coverage but it doesn’t prove the simulator matches a real v4 pool.
 * - This file focuses on correctness/grounding by running:
 *   1) `SwapSimulator.simulateSwap(...)` against the real `PoolManager` state
 *   2) an actual swap via `PoolSwapTest.swap(...)`
 *   3) comparing deltas and end-state (price/tick/liquidity)
 *
 * Scope:
 * - Keep scenarios small and robust (no hooks, standard fee, standard tick spacing).
 * - This file is *not* responsible for full branch coverage.
 */

import {SwapSimulator} from "../../src/libraries/SwapSimulator.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract SwapSimulatorIntegrationTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    function setUp() public {
        // Deploy a fresh v4 manager + routers, then initialise a pool with liquidity.
        // This is the “grounding” bit: we want real PoolManager state, tick bitmaps, liquidity, etc.
        initializeManagerRoutersAndPoolsWithLiq(IHooks(address(0)));
    }

    function test_simulateSwap_matches_realSwap_exactInput_zeroForOne() public {
        // Arrange
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -10_000, sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        // Act (simulate)
        (BalanceDelta simDelta,, uint24 simFee, SwapSimulator.SwapResult memory simResult) =
            SwapSimulator.simulateSwap(manager, key, params);

        // Act (real swap)
        BalanceDelta realDelta = swapRouter.swap(
            key,
            params,
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Assert (core delta equivalence)
        assertEq(realDelta.amount0(), simDelta.amount0(), "amount0 delta mismatch");
        assertEq(realDelta.amount1(), simDelta.amount1(), "amount1 delta mismatch");

        // Assert (end-state equivalence)
        // Note: `PoolSwapTest.swap` doesn't return the post-swap state; we read it from the manager.
        (uint160 sqrtAfter, int24 tickAfter,,) = manager.getSlot0(key.toId());
        uint128 liqAfter = manager.getLiquidity(key.toId());

        // For a default Deployers pool, protocol fees are disabled so swapFee should equal the static LP fee.
        assertEq(uint256(simFee), uint256(key.fee), "swapFee mismatch");
        assertEq(sqrtAfter, simResult.sqrtPriceX96, "sqrtPrice mismatch");
        assertEq(tickAfter, simResult.tick, "tick mismatch");
        assertEq(liqAfter, simResult.liquidity, "liquidity mismatch");
    }

    function test_simulateSwap_matches_realSwap_exactInput_oneForZero() public {
        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: -10_000, sqrtPriceLimitX96: MAX_PRICE_LIMIT});

        (BalanceDelta simDelta,, uint24 simFee, SwapSimulator.SwapResult memory simResult) =
            SwapSimulator.simulateSwap(manager, key, params);

        BalanceDelta realDelta = swapRouter.swap(
            key,
            params,
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        assertEq(realDelta.amount0(), simDelta.amount0(), "amount0 delta mismatch");
        assertEq(realDelta.amount1(), simDelta.amount1(), "amount1 delta mismatch");

        (uint160 sqrtAfter, int24 tickAfter,,) = manager.getSlot0(key.toId());
        uint128 liqAfter = manager.getLiquidity(key.toId());

        assertEq(uint256(simFee), uint256(key.fee), "swapFee mismatch");
        assertEq(sqrtAfter, simResult.sqrtPriceX96, "sqrtPrice mismatch");
        assertEq(tickAfter, simResult.tick, "tick mismatch");
        assertEq(liqAfter, simResult.liquidity, "liquidity mismatch");
    }

    function test_simulateSwap_matches_realSwap_exactOutput_zeroForOne() public {
        // Exact output is represented by amountSpecified > 0 (Uniswap v4 convention)
        // We choose a small exact-out amount to keep this test stable across liquidity ranges.
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: int256(100), sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        (BalanceDelta simDelta,, , SwapSimulator.SwapResult memory simResult) =
            SwapSimulator.simulateSwap(manager, key, params);

        BalanceDelta realDelta = swapRouter.swap(
            key,
            params,
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        assertEq(realDelta.amount0(), simDelta.amount0(), "amount0 delta mismatch");
        assertEq(realDelta.amount1(), simDelta.amount1(), "amount1 delta mismatch");

        (uint160 sqrtAfter, int24 tickAfter,,) = manager.getSlot0(key.toId());
        uint128 liqAfter = manager.getLiquidity(key.toId());

        assertEq(sqrtAfter, simResult.sqrtPriceX96, "sqrtPrice mismatch");
        assertEq(tickAfter, simResult.tick, "tick mismatch");
        assertEq(liqAfter, simResult.liquidity, "liquidity mismatch");
    }
}



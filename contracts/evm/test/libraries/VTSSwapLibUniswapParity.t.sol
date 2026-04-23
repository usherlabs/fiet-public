// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSSwapLibTest} from "./VTSSwapLib.t.sol";
import {SwapSimulator} from "../utils/SwapSimulator.sol";

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice Formal Uniswap v4 grounding for swap outcomes used by VTSSwapLib parity tests (`VTS-REF` in INVARIANTS.md).
/// @dev Confirms `SwapSimulator` (which mirrors `Pool.swap` from v4-core `Pool.sol`) matches real `PoolManager` swaps on the deployed core pool.
contract VTSSwapLibUniswapParityTest is VTSSwapLibTest {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function test_swapSimulator_matches_poolManager_after_real_swap_exactInput_zeroForOne() public {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -50_000, sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT});

        (BalanceDelta simDelta,, uint24 simFee, SwapSimulator.SwapResult memory simRes) =
            SwapSimulator.simulateSwap(manager, corePoolKey, params);

        BalanceDelta realDelta = swapRouter.swap(
            corePoolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ZERO_BYTES
        );

        assertEq(realDelta.amount0(), simDelta.amount0(), "delta0 sim");
        assertEq(realDelta.amount1(), simDelta.amount1(), "delta1 sim");

        PoolId pid0 = corePoolKey.toId();
        (uint160 sqrtAfter0, int24 tickAfter0,,) = manager.getSlot0(pid0);
        uint128 liqAfter0 = manager.getLiquidity(pid0);

        assertEq(sqrtAfter0, simRes.sqrtPriceX96, "sqrt parity");
        assertEq(tickAfter0, simRes.tick, "tick parity");
        assertEq(liqAfter0, simRes.liquidity, "liq parity");
        assertEq(uint256(simFee), uint256(corePoolKey.fee), "fee tier");
    }

    function test_swapSimulator_matches_poolManager_after_real_swap_exactInput_oneForZero() public {
        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: -50_000, sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT});

        (BalanceDelta simDelta,, uint24 simFee, SwapSimulator.SwapResult memory simRes) =
            SwapSimulator.simulateSwap(manager, corePoolKey, params);

        BalanceDelta realDelta = swapRouter.swap(
            corePoolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ZERO_BYTES
        );

        assertEq(realDelta.amount0(), simDelta.amount0(), "delta0 sim");
        assertEq(realDelta.amount1(), simDelta.amount1(), "delta1 sim");

        PoolId pid1 = corePoolKey.toId();
        (uint160 sqrtAfter1, int24 tickAfter1,,) = manager.getSlot0(pid1);
        uint128 liqAfter1 = manager.getLiquidity(pid1);

        assertEq(sqrtAfter1, simRes.sqrtPriceX96, "sqrt parity");
        assertEq(tickAfter1, simRes.tick, "tick parity");
        assertEq(liqAfter1, simRes.liquidity, "liq parity");
        assertEq(uint256(simFee), uint256(corePoolKey.fee), "fee tier");
    }
}

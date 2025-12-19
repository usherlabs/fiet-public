// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {UnsafeMath} from "@uniswap/v4-core/src/libraries/UnsafeMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickUtils} from "./TickUtils.sol";
import {Errors} from "./Errors.sol";
/**
 * @title SwapSimulator
 * @notice Simulates Uniswap V4 swaps without executing them to predict outcomes
 * @dev This library replicates the core swap logic from Pool.sol for simulation purposes
 *
 * Key Features:
 * - Simulates exact input/output swaps
 * - Handles concentrated liquidity across multiple ticks
 * - Calculates fees (LP + protocol)
 * - Tracks price movements and liquidity changes
 * - Supports price limits and slippage protection
 */

library SwapSimulator {
    using SafeCast for uint256;
    using SafeCast for int256;

    /**
     * @notice Result of a simulated swap
     * @param sqrtPriceX96 The final sqrt price after the swap (Q64.96 format)
     * @param tick The final tick position after the swap
     * @param liquidity The final liquidity available after the swap
     */
    struct SwapResult {
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
    }

    /**
     * @notice Computations for each swap step
     * @param sqrtPriceStartX96 Starting price for this step
     * @param sqrtPriceNextX96 Target price for this step (next tick or limit)
     * @param tickNext Next initialized tick to potentially cross
     * @param initialized Whether the next tick has liquidity
     * @param amountIn Amount of input tokens consumed in this step
     * @param amountOut Amount of output tokens produced in this step
     * @param feeAmount Total fees collected in this step
     * @param feeGrowthGlobalX128 Accumulated fee growth for this step
     */
    struct StepComputations {
        uint160 sqrtPriceStartX96;
        uint160 sqrtPriceNextX96;
        int24 tickNext;
        bool initialized;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
        uint256 feeGrowthGlobalX128;
    }

    /// @dev Internal state for swap simulation to reduce stack depth
    struct SimulationState {
        int256 amountSpecifiedRemaining;
        int256 amountCalculated;
        uint256 protocolFee;
        uint256 amountToProtocol;
        bool zeroForOne;
    }

    // ============ ERRORS ============

    // ============ CORE FUNCTIONS ============

    /**
     * @notice Simulates a complete swap and returns the expected outcome
     * @param poolManager The Uniswap V4 PoolManager contract
     * @param corePoolKey The key of the pool to simulate the swap in
     * @param params The swap parameters (direction, amount, price limits)
     * @return swapDelta The expected balance changes for the swap
     * @return amountToProtocol The amount of fees that would go to protocol
     * @return swapFee The total swap fee (LP + protocol)
     * @return result The final state after the swap (price, tick, liquidity)
     *
     * @dev This function replicates the exact logic from Pool.sol's swap function
     * but operates on a copy of the pool state without modifying it
     */
    function simulateSwap(IPoolManager poolManager, PoolKey memory corePoolKey, SwapParams memory params)
        internal
        view
        returns (BalanceDelta swapDelta, uint256 amountToProtocol, uint24 swapFee, SwapResult memory result)
    {
        SimulationState memory state;
        
        // Initialize result and state from pool
        (result, swapFee, state) = _initializeSimulation(poolManager, corePoolKey, params);

        // Early return for zero amount swaps
        if (params.amountSpecified == 0) {
            return (toBalanceDelta(0, 0), 0, swapFee, result);
        }

        // Execute swap loop
        _executeSwapLoop(poolManager, corePoolKey, params, swapFee, result, state);

        // Calculate final delta
        swapDelta = _calculateFinalDelta(params, state);
        amountToProtocol = state.amountToProtocol;
    }

    /// @dev Initializes simulation state from pool storage
    function _initializeSimulation(
        IPoolManager poolManager,
        PoolKey memory corePoolKey,
        SwapParams memory params
    ) private view returns (SwapResult memory result, uint24 swapFee, SimulationState memory state) {
        // Get current pool state from storage
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) =
            StateLibrary.getSlot0(poolManager, corePoolKey.toId());

        // Initialize result
        result.sqrtPriceX96 = sqrtPriceX96;
        result.tick = tick;
        result.liquidity = uint128(StateLibrary.getLiquidity(poolManager, corePoolKey.toId()));

        // Initialize state
        state.zeroForOne = params.zeroForOne;
        state.protocolFee = protocolFee;
        state.amountSpecifiedRemaining = params.amountSpecified;
        state.amountCalculated = 0;
        state.amountToProtocol = 0;

        // Calculate swap fee
        swapFee = protocolFee == 0 ? lpFee : ProtocolFeeLibrary.calculateSwapFee(uint16(protocolFee), lpFee);

        // Validate fees for exact output swaps
        if (swapFee >= SwapMath.MAX_SWAP_FEE && params.amountSpecified > 0) {
            revert Errors.InvalidFeeForExactOut();
        }

        // Validate price limits (skip for zero amount)
        if (params.amountSpecified != 0) {
            _validatePriceLimits(state.zeroForOne, sqrtPriceX96, params.sqrtPriceLimitX96);
        }
    }

    /// @dev Executes the main swap loop
    function _executeSwapLoop(
        IPoolManager poolManager,
        PoolKey memory corePoolKey,
        SwapParams memory params,
        uint24 swapFee,
        SwapResult memory result,
        SimulationState memory state
    ) private view {
        while (!(state.amountSpecifiedRemaining == 0 || result.sqrtPriceX96 == params.sqrtPriceLimitX96)) {
            _executeSwapStep(poolManager, corePoolKey, params, swapFee, result, state);
        }
    }

    /// @dev Executes a single swap step
    function _executeSwapStep(
        IPoolManager poolManager,
        PoolKey memory corePoolKey,
        SwapParams memory params,
        uint24 swapFee,
        SwapResult memory result,
        SimulationState memory state
    ) private view {
        StepComputations memory step;
        step.sqrtPriceStartX96 = result.sqrtPriceX96;

        // Find next initialized tick
        (step.tickNext, step.initialized) = TickUtils.nextInitializedTickWithinOneWord(
            poolManager, corePoolKey.toId(), result.tick, corePoolKey.tickSpacing, state.zeroForOne
        );

        // Clamp tick to valid bounds
        if (step.tickNext <= TickMath.MIN_TICK) step.tickNext = TickMath.MIN_TICK;
        if (step.tickNext >= TickMath.MAX_TICK) step.tickNext = TickMath.MAX_TICK;

        step.sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(step.tickNext);

        // Compute swap step
        (result.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
            result.sqrtPriceX96,
            SwapMath.getSqrtPriceTarget(state.zeroForOne, step.sqrtPriceNextX96, params.sqrtPriceLimitX96),
            result.liquidity,
            state.amountSpecifiedRemaining,
            swapFee
        );

        // Update amounts
        if (params.amountSpecified > 0) {
            unchecked {
                state.amountSpecifiedRemaining -= step.amountOut.toInt256();
                state.amountCalculated -= (step.amountIn + step.feeAmount).toInt256();
            }
        } else {
            unchecked {
                state.amountSpecifiedRemaining += (step.amountIn + step.feeAmount).toInt256();
                state.amountCalculated += step.amountOut.toInt256();
            }
        }

        // Handle protocol fee
        if (state.protocolFee > 0) {
            uint256 delta = (swapFee == state.protocolFee)
                ? step.feeAmount
                : ((step.amountIn + step.feeAmount) * state.protocolFee) / ProtocolFeeLibrary.PIPS_DENOMINATOR;
            step.feeAmount -= delta;
            state.amountToProtocol += delta;
        }

        // Handle tick transition
        if (result.sqrtPriceX96 == step.sqrtPriceNextX96) {
            if (step.initialized) {
                (, int128 liquidityNet) =
                    StateLibrary.getTickLiquidity(poolManager, corePoolKey.toId(), step.tickNext);
                if (state.zeroForOne) liquidityNet = -liquidityNet;
                result.liquidity = LiquidityMath.addDelta(result.liquidity, liquidityNet);
            }
            unchecked {
                result.tick = state.zeroForOne ? step.tickNext - 1 : step.tickNext;
            }
        } else if (result.sqrtPriceX96 != step.sqrtPriceStartX96) {
            result.tick = TickMath.getTickAtSqrtPrice(result.sqrtPriceX96);
        }
    }

    /// @dev Calculates the final balance delta
    function _calculateFinalDelta(
        SwapParams memory params,
        SimulationState memory state
    ) private pure returns (BalanceDelta) {
        if (state.zeroForOne != (params.amountSpecified < 0)) {
            return toBalanceDelta(
                state.amountCalculated.toInt128(),
                (params.amountSpecified - state.amountSpecifiedRemaining).toInt128()
            );
        } else {
            return toBalanceDelta(
                (params.amountSpecified - state.amountSpecifiedRemaining).toInt128(),
                state.amountCalculated.toInt128()
            );
        }
    }

    // ============ HELPER FUNCTIONS ============

    /**
     * @notice Validates that price limits are achievable for the given swap direction
     * @param zeroForOne Whether the swap is Token0 -> Token1 (true) or Token1 -> Token0 (false)
     * @param currentPrice The current pool price
     * @param priceLimit The user-specified price limit
     * @dev Reverts if price limits are invalid or already exceeded
     */
    function _validatePriceLimits(bool zeroForOne, uint160 currentPrice, uint160 priceLimit) private pure {
        if (zeroForOne) {
            // For Token0 -> Token1, price should decrease
            if (priceLimit >= currentPrice) {
                revert Errors.PriceLimitAlreadyExceeded(currentPrice, priceLimit);
            }
            if (priceLimit <= TickMath.MIN_SQRT_PRICE) {
                revert Errors.PriceLimitOutOfBounds(priceLimit);
            }
        } else {
            // For Token1 -> Token0, price should increase
            if (priceLimit <= currentPrice) {
                revert Errors.PriceLimitAlreadyExceeded(currentPrice, priceLimit);
            }
            if (priceLimit >= TickMath.MAX_SQRT_PRICE) {
                revert Errors.PriceLimitOutOfBounds(priceLimit);
            }
        }
    }
}

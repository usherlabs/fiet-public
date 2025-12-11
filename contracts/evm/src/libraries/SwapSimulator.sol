// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

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
        // ============ INITIALIZATION ============

        // Get current pool state from storage
        (uint160 _sqrtPriceX96, int24 _tick, uint24 _protocolFee, uint24 _lpFee) =
            StateLibrary.getSlot0(poolManager, corePoolKey.toId());

        // Get current pool liquidity
        uint256 poolLiquidity = StateLibrary.getLiquidity(poolManager, corePoolKey.toId());

        // Extract swap direction and protocol fee
        bool zeroForOne = params.zeroForOne;
        uint256 protocolFee = _protocolFee;

        // Initialize tracking variables for the simulation
        int256 amountSpecifiedRemaining = params.amountSpecified; // How much input/output remains
        int256 amountCalculated = 0; // How much has been processed
        result.sqrtPriceX96 = _sqrtPriceX96; // Starting price
        result.tick = _tick; // Starting tick
        result.liquidity = uint128(poolLiquidity); // Starting liquidity

        // ============ FEE CALCULATION ============

        // Calculate total swap fee (LP fee + protocol fee if enabled)
        swapFee = protocolFee == 0 ? _lpFee : ProtocolFeeLibrary.calculateSwapFee(uint16(protocolFee), _lpFee);

        // Validate that fees aren't too high for exact output swaps
        if (swapFee >= SwapMath.MAX_SWAP_FEE) {
            if (params.amountSpecified > 0) {
                revert Errors.InvalidFeeForExactOut();
            }
        }

        // Early return for zero amount swaps
        if (params.amountSpecified == 0) {
            return (toBalanceDelta(0, 0), 0, swapFee, result);
        }

        // ============ PRICE LIMIT VALIDATION ============

        // Ensure price limits are valid and achievable
        _validatePriceLimits(zeroForOne, _sqrtPriceX96, params.sqrtPriceLimitX96);

        // ============ FEE GROWTH INITIALIZATION ============

        // Get global fee growth for the pool
        // (uint256 _feeGrowthGlobal0, uint256 _feeGrowthGlobal1) = StateLibrary.getFeeGrowthGlobals(poolManager, corePoolKey.toId());
        // uint256 feeGrowthGlobalX128 = zeroForOne ? _feeGrowthGlobal0 : _feeGrowthGlobal1;

        // ============ SWAP EXECUTION LOOP ============

        // Continue swapping until we've used all input/output or hit price limits
        while (!(amountSpecifiedRemaining == 0 || result.sqrtPriceX96 == params.sqrtPriceLimitX96)) {
            // ============ STEP INITIALIZATION ============

            StepComputations memory step;
            step.sqrtPriceStartX96 = result.sqrtPriceX96;

            // Find the next initialized tick in the swap direction
            (step.tickNext, step.initialized) = TickUtils.nextInitializedTickWithinOneWord(
                poolManager, corePoolKey.toId(), result.tick, corePoolKey.tickSpacing, zeroForOne
            );

            // Ensure we don't go beyond valid tick bounds
            if (step.tickNext <= TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            }
            if (step.tickNext >= TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // Calculate the price at the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(step.tickNext);

            // ============ SWAP STEP COMPUTATION ============

            // Compute how much we can swap in this step
            // This determines the price movement and amounts for this step
            // i.e extract as much liquidity as you can between this tick and the next tick
            (result.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                // Current price
                result.sqrtPriceX96,
                // Target price
                SwapMath.getSqrtPriceTarget(zeroForOne, step.sqrtPriceNextX96, params.sqrtPriceLimitX96),
                // Available liquidity
                result.liquidity,
                // Remaining amount to swap
                amountSpecifiedRemaining,
                // Total fee rate
                swapFee
            );

            // ============ AMOUNT TRACKING ============

            // Update remaining amounts based on swap type
            if (params.amountSpecified > 0) {
                // Exact output swap: reduce remaining output, track calculated input
                unchecked {
                    amountSpecifiedRemaining -= step.amountOut.toInt256();
                    amountCalculated -= (step.amountIn + step.feeAmount).toInt256();
                }
            } else {
                // Exact input swap: reduce remaining input, track calculated output
                unchecked {
                    amountSpecifiedRemaining += (step.amountIn + step.feeAmount).toInt256();
                    amountCalculated += step.amountOut.toInt256();
                }
            }

            // ============ PROTOCOL FEE HANDLING ============

            // If protocol fees are enabled, calculate and track them
            if (protocolFee > 0) {
                uint256 delta = (swapFee == protocolFee)  // Entire fee goes to protocol if LP fee is 0
                    ? step.feeAmount
                    : ((step.amountIn + step.feeAmount) * protocolFee) / ProtocolFeeLibrary.PIPS_DENOMINATOR;

                // Reduce LP fee by protocol portion
                step.feeAmount -= delta;
                // Track protocol fee
                amountToProtocol += delta;
            }

            // ============ FEE GROWTH UPDATES ============

            // Update global fee growth tracker for this step
            if (result.liquidity > 0) {
                step.feeGrowthGlobalX128 += UnsafeMath.simpleMulDiv(
                    step.feeAmount, FixedPoint128.Q128, result.liquidity
                );
            }

            // ============ TICK TRANSITION HANDLING ============

            // Check if we've reached the next tick boundary
            if (result.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // We've hit a tick boundary, handle liquidity changes
                if (step.initialized) {
                    // Get liquidity change at this tick
                    (, int128 liquidityNet) =
                        StateLibrary.getTickLiquidity(poolManager, corePoolKey.toId(), step.tickNext);

                    // For leftward movement (zeroForOne), flip the sign of liquidity change
                    if (zeroForOne) liquidityNet = -liquidityNet;

                    // Apply liquidity change
                    result.liquidity = LiquidityMath.addDelta(result.liquidity, liquidityNet);
                }

                // Update tick position
                unchecked {
                    result.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
                }
            } else if (result.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // Price changed but didn't hit tick boundary, recalculate tick
                result.tick = TickMath.getTickAtSqrtPrice(result.sqrtPriceX96);
            }
        }

        // ============ FINAL DELTA CALCULATION ============

        // Calculate the final balance delta based on swap direction and type
        if (zeroForOne != (params.amountSpecified < 0)) {
            // For exact input swaps: positive input, negative output
            swapDelta = toBalanceDelta(
                amountCalculated.toInt128(), (params.amountSpecified - amountSpecifiedRemaining).toInt128()
            );
        } else {
            // For exact output swaps: negative input, positive output
            swapDelta = toBalanceDelta(
                (params.amountSpecified - amountSpecifiedRemaining).toInt128(), amountCalculated.toInt128()
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

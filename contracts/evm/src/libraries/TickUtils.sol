// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";

/// @title TickUtils
/// @notice Utility functions for tick calculations and validation
library TickUtils {
    // Reference: https://github.com/Uniswap/v4-core/blob/cd989b470f1e3cb89d07da428e3785dd00b32a32/src/libraries/TickBitmap.sol#L85
    /**
     * @notice Finds the next initialized tick within one word of the tick bitmap
     * @param poolManager The PoolManager contract
     * @param poolId The pool ID
     * @param tick The current tick position
     * @param tickSpacing The spacing between valid ticks
     * @param lte Whether to search leftward (true) or rightward (false)
     * @return next The next initialized tick position
     * @return initialized Whether the next tick has liquidity
     * @dev This function navigates the tick bitmap to find the next tick with liquidity
     */
    function nextInitializedTickWithinOneWord(
        IPoolManager poolManager,
        PoolId poolId,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        unchecked {
            // Compress the tick to fit in the bitmap word
            int24 compressed = TickBitmap.compress(tick, tickSpacing);

            if (lte) {
                // Search leftward (decreasing ticks)
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);

                // Create mask for bits at or to the right of current position
                uint256 mask = type(uint256).max >> (uint256(type(uint8).max) - bitPos);
                uint256 masked = StateLibrary.getTickBitmap(poolManager, poolId, wordPos) & mask;

                // Check if there are initialized ticks in this direction
                initialized = masked != 0;

                // Calculate next tick position
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
            } else {
                // Search rightward (increasing ticks)
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(++compressed);

                // Create mask for bits at or to the left of current position
                // forge-lint: disable-next-line(incorrect-shift)
                uint256 mask = ~((1 << bitPos) - 1);
                uint256 masked = StateLibrary.getTickBitmap(poolManager, poolId, wordPos) & mask;

                // Check if there are initialized ticks in this direction
                initialized = masked != 0;

                // Calculate next tick position
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
            }
        }
    }
}

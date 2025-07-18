// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract CalculateInitialSqrtPrice is Script {
    function run() external view {
        uint256 bid = vm.envUint("BID");
        uint256 ask = vm.envUint("ASK");

        require(bid > 0 && ask > 0 && ask >= bid, "Invalid bid/ask values");

        // Compute geometric mean with reduced precision to avoid overflow
        // No reduction, assume bid/ask are small
        uint256 product = bid * ask;
        uint256 sqrtProduct = sqrt(product);
        uint256 geometric = sqrtProduct;

        // Compute sqrt(geometric) which has 9 decimals
        uint256 sqrtMid = sqrt(geometric);

        // sqrtPriceX96 = sqrtMid * 2^96 / 10^9
        uint256 sqrtPriceX96 = (sqrtMid * (1 << 96));

        // Validate it's within bounds
        require(
            sqrtPriceX96 >= TickMath.MIN_SQRT_PRICE && sqrtPriceX96 <= TickMath.MAX_SQRT_PRICE,
            "Calculated price out of bounds"
        );

        console.log("Calculated initial sqrtPriceX96: %s", sqrtPriceX96);
    }

    // Babylonian method for square root
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;

        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}

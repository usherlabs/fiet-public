// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySortHelper} from "../libraries/CurrencySortHelper.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface IERC20 {
    function decimals() external view returns (uint8);
}

contract CalculateSqrtPrice is Script {
    function run() external view {
        uint256 quote_dec = vm.envOr("QUOTE_DECIMALS", uint256(0));

        require(quote_dec <= 18, "QUOTE_DECIMALS too large for precision");

        address tokenA;
        address tokenB;
        try vm.envAddress("TOKEN_A") returns (address _tokenA) {
            tokenA = _tokenA;
        } catch {}
        try vm.envAddress("TOKEN_B") returns (address _tokenB) {
            tokenB = _tokenB;
        } catch {}

        uint256 decA = tokenA == address(0) ? 18 : IERC20(tokenA).decimals();
        uint256 decB = tokenB == address(0) ? 18 : IERC20(tokenB).decimals();

        (Currency currency0, Currency currency1) = CurrencySortHelper.sortAddresses(tokenA, tokenB);

        uint256 dec0 = Currency.unwrap(currency0) == tokenA ? decA : decB;
        uint256 dec1 = Currency.unwrap(currency1) == tokenB ? decB : decA;

        uint256 bid = vm.envUint("BID");
        uint256 ask = vm.envUint("ASK");

        require(bid > 0 && ask > 0 && ask >= bid, "Invalid bid/ask values");

        uint256 product = bid * ask;
        uint256 geometric = sqrt(product);

        int256 mid_exp = 18 - int256(quote_dec);
        uint256 mid_internal;
        if (mid_exp >= 0) {
            mid_internal = geometric * (10 ** uint256(mid_exp));
        } else {
            mid_internal = geometric / (10 ** uint256(-mid_exp));
        }

        int256 adj_exp = int256(dec1) - int256(dec0);
        uint256 adjusted_internal;
        if (adj_exp >= 0) {
            adjusted_internal = mid_internal * (10 ** uint256(adj_exp));
        } else {
            adjusted_internal = mid_internal / (10 ** uint256(-adj_exp));
        }

        require(adjusted_internal > 0, "Adjusted price too small");

        uint256 scaled_adjusted = adjusted_internal * 1_000_000_000_000_000_000;
        uint256 sqrtMid = sqrt(scaled_adjusted);

        uint256 sqrtPriceX96 = (sqrtMid * (1 << 96)) / 1_000_000_000_000_000_000;

        require(
            sqrtPriceX96 >= TickMath.MIN_SQRT_PRICE && sqrtPriceX96 <= TickMath.MAX_SQRT_PRICE,
            "Calculated price out of bounds"
        );

        console.log("Calculated sqrtPriceX96: %s", sqrtPriceX96);
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

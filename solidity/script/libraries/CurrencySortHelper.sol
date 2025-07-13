// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library CurrencySortHelper {
    function sortAddresses(address tokenA, address tokenB)
        internal
        pure
        returns (Currency currency0, Currency currency1)
    {
        require(tokenA != tokenB, "CurrencySortHelper: IDENTICAL_ADDRESSES");
        require(tokenA != address(0) && tokenB != address(0), "CurrencySortHelper: ZERO_ADDRESS");

        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        currency0 = Currency.wrap(token0);
        currency1 = Currency.wrap(token1);
    }

    function sortTokens(IERC20 tokenA, IERC20 tokenB) internal pure returns (Currency currency0, Currency currency1) {
        return sortAddresses(address(tokenA), address(tokenB));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/**
 * @title IMarketVault
 * @notice Interface for th ProxyHook contract
 */
interface IMarketVault {
    function inMarketBalanceOf(
        Currency currency
    ) external view returns (uint256);
}

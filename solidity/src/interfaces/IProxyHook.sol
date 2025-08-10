// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/**
 * @title IProxyHook
 * @notice Interface for th ProxyHook contract
 */
interface IProxyHook {
    function activate() external;

    function getCorePoolId() external view returns (PoolId);

    function getProxyHookAvailableLiquidity(Currency currency) external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/**
 * @title IHookCommon
 * @notice Interface for the CoreHook and ProxyHook contract that provides common hook functionality.
 */
interface IProxyHook {
    function activate() external;

    function getCorePoolId() external view returns (PoolId);

    function getProxyHookAvailableLiquidity(Currency currency) external view returns (uint256);
}

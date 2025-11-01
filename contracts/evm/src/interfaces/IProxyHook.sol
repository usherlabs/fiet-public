// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/**
 * @title IProxyHook
 * @notice Interface for th ProxyHook contract
 */
interface IProxyHook {
    function activate() external;

    function getCorePoolId() external view returns (PoolId);

    function onMMLiquidityModify(BalanceDelta balanceDelta) external;
}

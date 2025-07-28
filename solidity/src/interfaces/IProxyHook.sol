// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IHookCommon
 * @notice Interface for the CoreHook and ProxyHook contract that provides common hook functionality.
 */
interface IProxyHook {
    function activate() external;
}

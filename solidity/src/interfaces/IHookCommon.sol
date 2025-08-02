// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IHookCommon
 * @notice Interface for the CoreHook and ProxyHook contract that provides common hook functionality.
 */
interface IHookCommon {
    /**
     * @notice Enum defining different types of liquidity actions
     */
    enum ActionType {
        DirectLPAddLiquidity,
        DirectLPRemoveLiquidity
    }
}

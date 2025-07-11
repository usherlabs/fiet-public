// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IHookCommon
 * @notice Shared definitions for hooks across the protocol
 */
interface IHookCommon {
    /**
     * @notice Enum defining different types of liquidity actions
     */
    enum ActionType {
        DirectLPAddLiquidity,
        DirectLPRemoveLiquidity
    }

    function activate() external;
}

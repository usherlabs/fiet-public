// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IActionTypes
 * @notice Shared enum definitions for action types across the protocol
 */
interface IActionTypes {
    /**
     * @notice Enum defining different types of liquidity actions
     */
    enum ActionType {
        DirectLPAddLiquidity,
        DirectLPRemoveLiquidity
    }
}

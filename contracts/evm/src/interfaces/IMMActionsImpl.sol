// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title IMMActionsImpl
/// @notice Interface for the MMPositionManager actions implementation contract
/// @dev Called via delegatecall from MMPositionManager to handle position action execution
interface IMMActionsImpl {
    /// @notice Handle a action with the given parameters
    /// @dev Called via delegatecall, shares storage context with MMPositionManager
    /// @dev Only handles (eg. position) operations (eg. actions < 0x20)
    /// @param action The action type to execute
    /// @param params The encoded parameters for the action
    function handleAction(uint256 action, bytes calldata params) external;
}


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IMMPMActionsImpl
/// @notice Interface for the MMPositionManager actions implementation contract
/// @dev Called via delegatecall from MMPositionManager to handle action execution
interface IMMPMActionsImpl {
    /// @notice Handle an action with the given parameters
    /// @dev Called via delegatecall, shares storage context with MMPositionManager
    /// @param action The action type to execute
    /// @param params The encoded parameters for the action
    function handleAction(uint256 action, bytes calldata params) external;

    /// @notice Hook called before entry point execution
    /// @dev Handles native value and deadline checks
    /// @param deadline The deadline timestamp (type(uint256).max for no deadline)
    function beforeEntrypoint(uint256 deadline) external;

    /// @notice Hook called after entry point execution
    /// @dev Performs assertions and cleanup
    function afterEntrypoint() external;
}


// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title DelegateCallGuard
/// @notice Abstract module providing delegatecall protection
/// @dev Prevents direct calls to implementation contracts
abstract contract DelegateCallGuard {
    /// @dev Address of this contract at deployment - used to detect delegatecall
    address private immutable __self = address(this);

    /// @notice Error thrown when contract is called directly instead of via delegatecall
    error OnlyDelegateCall();

    /// @notice Modifier that ensures function is only called via delegatecall
    /// @dev Reverts if called directly on the implementation contract
    modifier onlyDelegateCall() {
        if (address(this) == __self) revert OnlyDelegateCall();
        _;
    }
}


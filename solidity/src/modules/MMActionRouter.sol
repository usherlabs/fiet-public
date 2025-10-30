// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * Direct clone of v4-periphery BaseActionsRouter with explicit edits:
 * - Adds a per-batch finaliser hook `_finaliseBatch()` invoked at the end of both batch entrypoints.
 * - Removes helper utilities `_mapRecipient` and `_mapPayer` (not used by MMPositionManager).
 * - Keeps the same SafeCallback unlock flow and action dispatch contract.
 */
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {CalldataDecoder} from "v4-periphery/src/libraries/CalldataDecoder.sol";

abstract contract MMActionRouter is SafeCallback {
    using CalldataDecoder for bytes;

    error InputLengthMismatch();
    error UnsupportedAction(uint256 action);

    constructor(IPoolManager _poolManager) SafeCallback(_poolManager) {}

    /// @notice internal function that triggers the execution of a set of actions on v4
    /// @dev inheriting contracts should call this function to trigger execution
    function _executeActions(bytes calldata unlockData) internal {
        poolManager.unlock(unlockData);
    }

    /// @notice function that is called by the PoolManager through the SafeCallback.unlockCallback
    /// @param data Abi encoding of (bytes actions, bytes[] params)
    /// where params[i] is the encoded parameters for actions[i]
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (bytes calldata actions, bytes[] calldata params) = data.decodeActionsRouterParams();
        _executeActionsWithoutUnlock(actions, params);
        return "";
    }

    function _executeActionsWithoutUnlock(bytes calldata actions, bytes[] calldata params) internal {
        uint256 numActions = actions.length;
        if (numActions != params.length) revert InputLengthMismatch();

        for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
            uint256 action = uint8(actions[actionIndex]);
            _handleAction(action, params[actionIndex]);
        }

        _finaliseBatch();
    }

    /// @notice function to handle the parsing and execution of an action and its parameters
    function _handleAction(uint256 action, bytes calldata params) internal virtual;

    /// @notice function that returns address considered executor of the actions
    function msgSender() public view virtual returns (address);

    /// @notice batch finaliser invoked after each batch executes
    function _finaliseBatch() internal virtual;
}

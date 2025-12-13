// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";

/// @title Native Wrapper
/// @notice Used for wrapping and unwrapping native
///
/// @notice Forked from v4-periphery/contracts/base/NativeWrapper.sol (@NativeWrapper.sol)
/// EDIT: Added virtual to receive() external payable to allow for MarketVault to send ETH to this.
abstract contract NativeWrapper is ImmutableState {
    /// @notice The address for WETH9
    IWETH9 public immutable WETH9;

    /// @notice Thrown when an unexpected address sends ETH to this contract
    error InvalidEthSender();

    constructor(IWETH9 _weth9) {
        WETH9 = _weth9;
    }

    /// @dev The amount should already be <= the current balance in this contract.
    function _wrap(uint256 amount) internal {
        if (amount > 0) WETH9.deposit{value: amount}();
    }

    /// @dev The amount should already be <= the current balance in this contract.
    function _unwrap(uint256 amount) internal {
        if (amount > 0) WETH9.withdraw(amount);
    }

    receive() external payable virtual {
        if (msg.sender != address(WETH9) && msg.sender != address(poolManager)) revert InvalidEthSender();
    }
}

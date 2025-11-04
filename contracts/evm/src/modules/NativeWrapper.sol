// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {NativeWrapper as UniNativeWrapper} from "v4-periphery/src/base/NativeWrapper.sol";

/// @title NativeWrapper
/// @notice Used for wrapping and unwrapping native assets in PositionManagers.
contract NativeWrapper is UniNativeWrapper {
    constructor(address _weth9) UniNativeWrapper(_weth9) {}

    function _vaultToCurrencyPair(address vault) internal view virtual returns (address[2] memory);
    function _validateToken(address token, address[2] memory currencies) internal view virtual returns (uint8);

    function _assertValidEthSender() internal view {
        if (msg.sender != address(WETH9) && msg.sender != address(poolManager)) {
            revert InvalidEthSender();
        }
        address[2] memory currencies = _vaultToCurrencyPair(msg.sender);
        _validateToken(msg.sender, currencies);
    }

    // Best practice: be explicit about intent
    // Only executes on plain transaction (no selector) (ie. poolManager or WETH9 transfer of assets) to the MarketVault.
    // Plain transactions are performed by the pool manager or external contracts in native asset routes.
    // ie. Only be executed if the msg.sender is the market vault in route: PM -> MV -> LH
    // This functin replaces NativeWrapper.sol receive() function to include MarketVault..
    receive() external payable {
        _assertValidEthSender();
    }
}

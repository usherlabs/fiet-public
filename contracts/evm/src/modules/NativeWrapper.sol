// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {NativeWrapper as UniNativeWrapper} from "../forks/NativeWrapper.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

/// @title NativeWrapper
/// @notice Used for wrapping and unwrapping native assets in PositionManagers.
/// @dev This contract extends UniNativeWrapper. When used with MarketHandler via multiple inheritance
///      (e.g., in MMPositionManager), the _vaultToCurrencyPair and _validateToken functions from
///      MarketHandler will be available through the inheritance chain.
abstract contract NativeWrapper is UniNativeWrapper {
    constructor(IWETH9 _weth9) UniNativeWrapper(_weth9) {}

    /// @notice Validates that the ETH sender is either WETH9, poolManager, or a valid MarketVault
    /// @dev Uses _vaultToCurrencyPair and _validateToken which must be provided by MarketHandler
    ///      via multiple inheritance in the final contract (e.g., MMPositionManager)
    function _assertValidEthSender() internal view {
        if (msg.sender != address(WETH9) && msg.sender != address(poolManager)) {
            revert InvalidEthSender();
        }
        // These functions will be resolved from MarketHandler via multiple inheritance
        address[2] memory currencies = _vaultToCurrencyPair(msg.sender);
        _validateToken(msg.sender, currencies);
    }

    /// @notice Must be implemented by MarketHandler or a contract that inherits from MarketHandler
    /// @dev This function signature matches MarketHandler._vaultToCurrencyPair
    function _vaultToCurrencyPair(address vault) internal view virtual returns (address[2] memory);

    /// @notice Must be implemented by MarketHandler or a contract that inherits from MarketHandler
    /// @dev This function signature matches MarketHandler._validateToken
    function _validateToken(address token, address[2] memory currencies) internal view virtual returns (uint8);

    // Best practice: be explicit about intent
    // Only executes on plain transaction (no selector) (ie. poolManager or WETH9 transfer of assets) to MarketVault.
    // Plain transactions are performed by the pool manager or external contracts in native asset routes.
    // ie. Only be executed if the msg.sender is the market vault in route: PM -> MV -> LH
    // This functin replaces NativeWrapper.sol receive() function to include MarketVault..
    receive() external payable override {
        _assertValidEthSender();
    }
}

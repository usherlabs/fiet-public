// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {NativeWrapper as UniNativeWrapper} from "../forks/NativeWrapper.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {ImmutableMarketState} from "./ImmutableMarketState.sol";
import {MarketHandlerLib} from "../libraries/MarketHandlerLib.sol";

/// @title NativeWrapper
/// @notice Used for wrapping and unwrapping native assets in PositionManagers.
/// @dev This contract extends UniNativeWrapper. When used with ImmutableMarketState via multiple inheritance
///      (e.g., in MMPositionManager), the marketFactory will be available through the inheritance chain.
abstract contract NativeWrapper is UniNativeWrapper, ImmutableMarketState {
    constructor(IWETH9 _weth9) UniNativeWrapper(_weth9) {}

    /// @notice Validates that the ETH sender is either WETH9, poolManager, or a valid MarketVault
    /// @dev Uses MarketHandlerLib functions to validate the sender
    function _assertValidEthSender() internal view {
        // If sender is WETH9 or poolManager, allow it (these are trusted sources)
        if (msg.sender == address(WETH9) || msg.sender == address(poolManager)) {
            return;
        }
        // otherwise check if the caller is a valid MarketVault
        address[2] memory currencies = MarketHandlerLib.vaultToCurrencyPair(marketFactory, msg.sender);
        MarketHandlerLib.validateToken(msg.sender, currencies);
    }

    // Best practice: be explicit about intent
    // Only executes on plain transaction (no selector) (ie. poolManager or WETH9 transfer of assets) to MarketVault.
    // Plain transactions are performed by the pool manager or external contracts in native asset routes.
    // ie. Only be executed if the msg.sender is the market vault in route: PM -> MV -> LH
    // This functin replaces NativeWrapper.sol receive() function to include MarketVault..
    receive() external payable override {
        _assertValidEthSender();
    }
}

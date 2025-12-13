// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {NativeWrapper as UniNativeWrapper} from "../forks/NativeWrapper.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {Errors} from "../libraries/Errors.sol";
import {IMarketVault} from "../interfaces/IMarketVault.sol";
import {ILCC} from "../interfaces/ILCC.sol";

/// @title NativeWrapper
/// @notice Used for wrapping and unwrapping native assets in PositionManagers.
abstract contract NativeWrapper is UniNativeWrapper {
    constructor(IWETH9 _weth9) UniNativeWrapper(_weth9) {}

    /// @notice Validates that the ETH sender is either WETH9, poolManager, or a valid MarketVault
    /// @dev Validates MarketVault by checking its LCC tokens and verifying at least one underlying is native ETH
    function _assertValidEthSender() internal view {
        // If sender is WETH9 or poolManager, allow it (these are trusted sources)
        if (msg.sender == address(WETH9) || msg.sender == address(poolManager)) {
            return;
        }

        // otherwise check if the caller is a valid MarketVault with native ETH support
        IMarketVault marketVault = IMarketVault(msg.sender);

        // Check if lccs() function exists by attempting to call it
        (bool success, bytes memory returnData) =
            address(marketVault).staticcall(abi.encodeWithSelector(IMarketVault.lccs.selector));

        if (!success) {
            revert Errors.InvalidSender();
        }

        (address lccToken0, address lccToken1) = abi.decode(returnData, (address, address));
        address underlying0 = ILCC(lccToken0).underlying();
        address underlying1 = ILCC(lccToken1).underlying();
        // Validate that at least one underlying is native ETH (address(0))
        if (underlying0 != address(0) && underlying1 != address(0)) {
            revert Errors.InvalidSender();
        }
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

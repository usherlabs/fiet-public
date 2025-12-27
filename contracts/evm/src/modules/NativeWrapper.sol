// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {NativeWrapper as UniNativeWrapper} from "../forks/NativeWrapper.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {Errors} from "../libraries/Errors.sol";
import {IMarketVault} from "../interfaces/IMarketVault.sol";
import {ILCC} from "../interfaces/ILCC.sol";

/// @title FietNativeWrapper
/// @notice Used for wrapping and unwrapping native assets in PositionManagers.
/// @dev Named to avoid colliding with the forked `NativeWrapper` contract name in this codebase.
abstract contract FietNativeWrapper is UniNativeWrapper {
    constructor(IWETH9 _weth9) UniNativeWrapper(_weth9) {}

    /// @notice Validates that the ETH sender is either WETH9, poolManager, or a valid MarketVault
    /// @dev Validates MarketVault by checking its LCC tokens and verifying at least one underlying is native ETH
    function _assertValidEthSender() internal view {
        // If sender is WETH9 or poolManager, allow it (these are trusted sources)
        if (msg.sender == address(WETH9) || msg.sender == address(poolManager)) {
            return;
        }

        address sender = msg.sender;
        if (sender.code.length == 0) {
            revert Errors.InvalidEthSender();
        }

        address lccToken0;
        address lccToken1;
        // Prefer typed call + try/catch over low-level staticcall probing.
        try IMarketVault(sender).lccs() returns (address _lcc0, address _lcc1) {
            lccToken0 = _lcc0;
            lccToken1 = _lcc1;
        } catch {
            revert Errors.InvalidEthSender();
        }

        address underlying0;
        address underlying1;
        // Defensive: if the returned tokens don't implement ILCC properly, treat as invalid sender.
        try ILCC(lccToken0).underlying() returns (address u0) {
            underlying0 = u0;
        } catch {
            revert Errors.InvalidEthSender();
        }
        try ILCC(lccToken1).underlying() returns (address u1) {
            underlying1 = u1;
        } catch {
            revert Errors.InvalidEthSender();
        }
        // Validate that at least one underlying is native ETH (address(0))
        if (underlying0 != address(0) && underlying1 != address(0)) {
            revert Errors.InvalidEthSender();
        }
    }

    // Best practice: be explicit about intent
    // Only executes on plain transaction (no selector) (ie. poolManager or WETH9 transfer of assets) to MarketVault.
    // Plain transactions are performed by the pool manager or external contracts in native asset routes.
    // ie. Only be executed if the msg.sender is the market vault in route: PM -> MV -> LH
    // This function replaces the forked NativeWrapper receive() to include MarketVault.
    receive() external payable override {
        _assertValidEthSender();
    }
}

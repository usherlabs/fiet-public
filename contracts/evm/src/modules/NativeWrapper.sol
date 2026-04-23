// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {NativeWrapper as UniNativeWrapper} from "../forks/NativeWrapper.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {Errors} from "../libraries/Errors.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";

/// @title FietNativeWrapper
/// @notice Used for wrapping and unwrapping native assets in PositionManagers.
/// @dev Named to avoid colliding with the forked `NativeWrapper` contract name in this codebase.
abstract contract FietNativeWrapper is UniNativeWrapper {
    constructor(IWETH9 _weth9) UniNativeWrapper(_weth9) {}

    /// @dev Implemented by inheritors that already bind a canonical MarketFactory namespace.
    function _canonicalMarketFactory() internal view virtual returns (IMarketFactory);
    /// @dev Implemented by inheritors with canonical LiquidityHub binding.
    function _liquidityHub() internal view virtual returns (ILiquidityHub);

    /// @dev Bound `MMQueueCustodian` sending native after Hub `unwrap` / release. Inheritors (e.g. `MMPositionManager`) registry-match `beneficiary` to `custodianFor`.
    function _isCustodian(address) internal view virtual returns (bool) {
        return false;
    }

    /// @notice Validates that the ETH sender is either WETH9, poolManager, canonical LiquidityHub, or a canonical native vault
    /// @dev Uses MarketFactory registry data to avoid interface-probing based sender spoofing.
    function _assertValidEthSender() internal view {
        // If sender is WETH9 or poolManager, allow it (these are trusted sources)
        if (msg.sender == address(WETH9) || msg.sender == address(poolManager)) {
            return;
        }

        // Allow canonical Hub-native payouts (e.g. native LCC unwrap-to-self in MMPM).
        if (msg.sender == address(_liquidityHub())) {
            return;
        }

        // Native-backed LCC unwrap: bound `MMQueueCustodian` forwards immediate ETH from Hub to this manager for delta credit.
        if (_isCustodian(msg.sender)) {
            return;
        }

        IMarketFactory factory = _canonicalMarketFactory();
        address sender = msg.sender;
        if (sender.code.length == 0) {
            revert Errors.InvalidEthSender();
        }

        // Canonical vault lookup by sender address; unknown senders map to [0,0].
        address[2] memory underlyingPair = factory.proxyHookToCurrencyPair(sender);
        bool native0 = underlyingPair[0] == address(0);
        bool native1 = underlyingPair[1] == address(0);

        // Require exactly one native leg. This rejects unknown senders ([0,0]) and non-native markets.
        if (native0 == native1) {
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

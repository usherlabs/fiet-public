// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSCurrencyDelta} from "../../../src/modules/VTSCurrencyDelta.sol";
import {VTSStorage} from "../../../src/types/VTS.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {DynamicCurrencyDelta} from "../../../src/libraries/DynamicCurrencyDelta.sol";
import {CurrencyDelta} from "v4-periphery/lib/v4-core/src/libraries/CurrencyDelta.sol";

/// @title VTSCurrencyDeltaHarness
/// @notice Exposes VTSCurrencyDelta functions for unit testing
/// @dev Manages its own VTSStorage and provides helpers for transient storage manipulation
contract VTSCurrencyDeltaHarness is VTSCurrencyDelta {
    using CurrencyDelta for Currency;

    /// @notice Internal VTSStorage for testing
    VTSStorage internal s;

    /// @inheritdoc VTSCurrencyDelta
    function _vtsStorage() internal view override returns (VTSStorage storage) {
        return s;
    }

    // ============ Test Setup Helpers ============

    /// @notice Sets up a currency delta for a target (uses transient storage)
    /// @dev Uses DynamicCurrencyDelta.accountDelta to properly manage NonzeroDeltaCount
    /// @param currency The currency to set delta for
    /// @param target The address to set delta for
    /// @param delta The delta amount (positive = credit, negative = debt)
    function setDelta(Currency currency, address target, int128 delta) external {
        DynamicCurrencyDelta.accountDelta(currency, delta, target);
    }

    /// @notice Gets raw delta for a target from transient storage
    /// @param currency The currency to check
    /// @param target The address to check delta for
    /// @return The raw delta value (can be positive, negative, or zero)
    function getDelta(Currency currency, address target) external view returns (int256) {
        return currency.getDelta(target);
    }

    /// @notice Accounts a delta change using the library directly
    /// @dev Wrapper for DynamicCurrencyDelta.accountDelta
    function accountDelta(Currency currency, int128 delta, address target) external {
        DynamicCurrencyDelta.accountDelta(currency, delta, target);
    }
}


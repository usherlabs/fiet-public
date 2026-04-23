// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Errors} from "./Errors.sol";

/// @title MarketCurrencyDelta
/// @notice Factory-prefixed transient settlement namespace for produced same-underlying credit.
/// @dev This library deliberately tracks only produced-credit state in the preferred architecture.
///      Market-scoped withdrawal reservations should not be added unless a concrete semantic blocker
///      forces them back into the design.
library MarketCurrencyDelta {
    using TransientSlot for *;

    bytes32 internal constant PENDING_COUNT_NAMESPACE = keccak256("MARKET_CURRENCY_DELTA_PENDING_COUNT");
    bytes32 internal constant PRODUCED_NAMESPACE = keccak256("MARKET_CURRENCY_DELTA_PRODUCED");

    function _pendingCountSlot(address factory) private pure returns (bytes32) {
        return EfficientHashLib.hash(abi.encodePacked(PENDING_COUNT_NAMESPACE, factory));
    }

    function _producedSlot(address factory, Currency underlyingCurrency) private pure returns (bytes32) {
        return EfficientHashLib.hash(abi.encodePacked(PRODUCED_NAMESPACE, factory, Currency.unwrap(underlyingCurrency)));
    }

    function _trackNonZeroTransition(address factory, bytes32 slot, uint256 nextValue) private {
        uint256 previous = TransientSlot.asUint256(slot).tload();
        if (previous == nextValue) return;

        bytes32 countSlot = _pendingCountSlot(factory);
        uint256 count = TransientSlot.asUint256(countSlot).tload();
        if (previous == 0 && nextValue > 0) {
            TransientSlot.asUint256(countSlot).tstore(count + 1);
        } else if (previous > 0 && nextValue == 0) {
            TransientSlot.asUint256(countSlot).tstore(count - 1);
        }

        TransientSlot.asUint256(slot).tstore(nextValue);
    }

    function addProduced(address factory, Currency underlyingCurrency, uint256 amount) internal {
        if (amount == 0) return;
        bytes32 slot = _producedSlot(factory, underlyingCurrency);
        uint256 current = TransientSlot.asUint256(slot).tload();
        _trackNonZeroTransition(factory, slot, current + amount);
    }

    function consumeProduced(address factory, Currency underlyingCurrency, uint256 amount) internal {
        if (amount == 0) return;
        bytes32 slot = _producedSlot(factory, underlyingCurrency);
        uint256 current = TransientSlot.asUint256(slot).tload();
        if (current < amount) revert Errors.InvariantViolated("MarketCurrencyDelta produced underflow");
        _trackNonZeroTransition(factory, slot, current - amount);
    }

    function produced(address factory, Currency underlyingCurrency) internal view returns (uint256) {
        return TransientSlot.asUint256(_producedSlot(factory, underlyingCurrency)).tload();
    }

    function pendingCount(address factory) internal view returns (uint256) {
        return TransientSlot.asUint256(_pendingCountSlot(factory)).tload();
    }

    function assertResolved(address factory) internal view {
        if (pendingCount(factory) > 0) revert Errors.CurrencyNotSettled();
    }
}

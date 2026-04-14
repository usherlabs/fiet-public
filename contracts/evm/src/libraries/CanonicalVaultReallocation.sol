// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Errors} from "./Errors.sol";

/// @notice Tracks factory-wide same-underlying credit reallocations during a batch.
library CanonicalVaultReallocation {
    using TransientSlot for *;

    bytes32 internal constant PENDING_COUNT_SLOT = keccak256("CANONICAL_VAULT_PENDING_COUNT");
    bytes32 internal constant PRODUCED_NAMESPACE = keccak256("CANONICAL_VAULT_PRODUCED");
    bytes32 internal constant WITHDRAW_NAMESPACE = keccak256("CANONICAL_VAULT_WITHDRAW");

    function _producedSlot(Currency underlyingCurrency) private pure returns (bytes32) {
        return EfficientHashLib.hash(abi.encodePacked(PRODUCED_NAMESPACE, Currency.unwrap(underlyingCurrency)));
    }

    function _withdrawSlot(bytes32 marketId, Currency underlyingCurrency) private pure returns (bytes32) {
        return
            EfficientHashLib.hash(abi.encodePacked(WITHDRAW_NAMESPACE, marketId, Currency.unwrap(underlyingCurrency)));
    }

    function _trackNonZeroTransition(bytes32 slot, uint256 nextValue) private {
        uint256 previous = TransientSlot.asUint256(slot).tload();
        if (previous == nextValue) return;

        uint256 count = TransientSlot.asUint256(PENDING_COUNT_SLOT).tload();
        if (previous == 0 && nextValue > 0) {
            TransientSlot.asUint256(PENDING_COUNT_SLOT).tstore(count + 1);
        } else if (previous > 0 && nextValue == 0) {
            TransientSlot.asUint256(PENDING_COUNT_SLOT).tstore(count - 1);
        }
        TransientSlot.asUint256(slot).tstore(nextValue);
    }

    function addProduced(Currency underlyingCurrency, uint256 amount) internal {
        if (amount == 0) return;
        bytes32 slot = _producedSlot(underlyingCurrency);
        uint256 current = TransientSlot.asUint256(slot).tload();
        _trackNonZeroTransition(slot, current + amount);
    }

    function consumeProduced(Currency underlyingCurrency, uint256 amount) internal {
        if (amount == 0) return;
        bytes32 slot = _producedSlot(underlyingCurrency);
        uint256 current = TransientSlot.asUint256(slot).tload();
        if (current < amount) revert Errors.InvariantViolated("CanonicalVault produced underflow");
        _trackNonZeroTransition(slot, current - amount);
    }

    function produced(Currency underlyingCurrency) internal view returns (uint256) {
        return TransientSlot.asUint256(_producedSlot(underlyingCurrency)).tload();
    }

    function stageWithdrawal(bytes32 marketId, Currency underlyingCurrency, uint256 amount) internal {
        if (amount == 0) return;
        consumeProduced(underlyingCurrency, amount);
        bytes32 slot = _withdrawSlot(marketId, underlyingCurrency);
        uint256 current = TransientSlot.asUint256(slot).tload();
        _trackNonZeroTransition(slot, current + amount);
    }

    function takeStagedWithdrawal(bytes32 marketId, Currency underlyingCurrency, uint256 maxAmount)
        internal
        returns (uint256 amount)
    {
        if (maxAmount == 0) return 0;
        bytes32 slot = _withdrawSlot(marketId, underlyingCurrency);
        uint256 current = TransientSlot.asUint256(slot).tload();
        amount = current > maxAmount ? maxAmount : current;
        if (amount == 0) return 0;
        _trackNonZeroTransition(slot, current - amount);
    }

    function stagedWithdrawal(bytes32 marketId, Currency underlyingCurrency) internal view returns (uint256) {
        return TransientSlot.asUint256(_withdrawSlot(marketId, underlyingCurrency)).tload();
    }

    function pendingCount() internal view returns (uint256) {
        return TransientSlot.asUint256(PENDING_COUNT_SLOT).tload();
    }

    function assertResolved() internal view {
        if (pendingCount() > 0) revert Errors.CurrencyNotSettled();
    }
}

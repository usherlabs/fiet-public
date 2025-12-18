// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {CurrencyDelta} from "v4-periphery/lib/v4-core/src/libraries/CurrencyDelta.sol";
import {NonzeroDeltaCount} from "@uniswap/v4-core/src/libraries/NonzeroDeltaCount.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ILCC} from "../interfaces/ILCC.sol";
import {Errors} from "./Errors.sol";
import {console} from "forge-std/console.sol";

/// @title DynamicCurrencyDelta
/// @notice Library for managing currency deltas and underlying settlement in VTS
/// @dev Operates on VTSStorage, uses transient storage for deltas.
///      Follows Uniswap v4 PoolManager patterns for delta accounting.
/// @author Fiet Protocol
library DynamicCurrencyDelta {
    using CurrencyDelta for Currency;

    // ============================================================
    // Core Delta Accounting (mirrors PoolManager._accountDelta)
    // ============================================================

    /// @notice Accounts a delta for a currency and target address
    /// @dev Increments or decrements the nonzero delta count based on the previous and next deltas.
    ///      Early returns if delta is zero for gas optimisation.
    /// @param currency The currency to account the delta for
    /// @param delta The delta to account
    /// @param target The target address to account the delta for
    function accountDelta(Currency currency, int128 delta, address target) internal {
        if (delta == 0) return;
        (int256 previous, int256 next) = currency.applyDelta(target, delta);
        if (next == 0) {
            NonzeroDeltaCount.decrement();
        } else if (previous == 0) {
            NonzeroDeltaCount.increment();
        }

        console.log("accountDelta: currency", Currency.unwrap(currency));
        console.log("accountDelta: next delta", next);
        console.log("accountDelta: target", target);
    }

    /// @notice Gets the full positive delta (credit) for a currency and target
    /// @param currency The currency to check
    /// @param target The target address to check delta for
    /// @return The positive delta amount, or 0 if delta is not positive
    function getFullCredit(Currency currency, address target) internal view returns (uint256) {
        int256 delta = currency.getDelta(target);
        return (delta > 0) ? uint256(delta) : 0;
    }

    /// @notice Gets the full negative delta (debt) for a currency and target
    /// @param currency The currency to check
    /// @param target The target address to check delta for
    /// @return The negative delta amount as uint256, or 0 if delta is not negative
    function getFullDebt(Currency currency, address target) internal view returns (uint256) {
        int256 delta = currency.getDelta(target);
        return (delta < 0) ? uint256(-delta) : 0;
    }

    // ============================================================
    // LCC / Underlying Currency Helpers
    // ============================================================

    /// @notice Converts an LCC currency to its underlying currency
    /// @param lccCurrency The LCC currency to convert
    /// @return The underlying currency
    function lccToUnderlyingCurrency(Currency lccCurrency) internal view returns (Currency) {
        return Currency.wrap(ILCC(Currency.unwrap(lccCurrency)).underlying());
    }

    /// @notice Gets the underlying settlement delta for a sender
    /// @param sender The address to get the settlement delta for
    /// @param lccCurrency0 The first LCC currency
    /// @param lccCurrency1 The second LCC currency
    /// @return settlementDelta The settlement delta for the sender
    function getUnderlyingDeltaPair(address sender, Currency lccCurrency0, Currency lccCurrency1)
        internal
        view
        returns (BalanceDelta settlementDelta)
    {
        Currency uCurrency0 = lccToUnderlyingCurrency(lccCurrency0);
        Currency uCurrency1 = lccToUnderlyingCurrency(lccCurrency1);
        int256 uDelta0 = uCurrency0.getDelta(sender);
        int256 uDelta1 = uCurrency1.getDelta(sender);
        return toBalanceDelta(SafeCast.toInt128(uDelta0), SafeCast.toInt128(uDelta1));
    }

    // ============================================================
    // Settlement Helpers
    // ============================================================

    /// @notice Takes up to maxAmount from target's positive delta, capping to available credit
    /// @dev Takes min(target's positive delta, maxAmount) and nets the delta
    /// @param currency The currency to take
    /// @param target The address whose delta to take from
    /// @param maxAmount The maximum amount to take (use 0 for full available)
    function take(Currency currency, address target, uint256 maxAmount) internal returns (uint256) {
        int256 delta = currency.getDelta(target);

        if (delta <= 0) return 0; // No positive delta (credit) available

        // Cap to min of positive delta and maxAmount
        uint256 availableCredit = uint256(delta);
        uint256 amountToTake = maxAmount == 0 ? availableCredit : Math.min(availableCredit, maxAmount);

        // Net the delta by accounting the negative amount taken
        // amountToTake is either a portion, or total available credit.
        accountDelta(currency, -SafeCast.toInt128(amountToTake), target);

        return amountToTake;
    }

    // ============================================================
    // Delta Accounting Helpers
    // ============================================================

    /// @notice Accounts settlement delta change on underlying currencies for a target address
    /// @dev Converts LCC currencies to their underlying currencies and accounts the delta.
    ///      Used to track what underlying assets are owed/credited during settlement operations.
    /// @param target The address to account the delta for
    /// @param targetSettlementDelta The settlement delta to account (negative = deposit, positive = withdrawal)
    /// @param lccCurrency0 The first LCC currency
    /// @param lccCurrency1 The second LCC currency
    function accountUnderlyingSettlementDelta(
        address target,
        BalanceDelta targetSettlementDelta,
        Currency lccCurrency0,
        Currency lccCurrency1
    ) internal {
        Currency underlyingCurrency0 = lccToUnderlyingCurrency(lccCurrency0);
        Currency underlyingCurrency1 = lccToUnderlyingCurrency(lccCurrency1);

        // Read current currency deltas
        int256 currentDelta0 = underlyingCurrency0.getDelta(target);
        int256 currentDelta1 = underlyingCurrency1.getDelta(target);

        // Calculate the delta of delta (the change): targetSettlementDelta - currentDelta
        int128 changeDelta0 = targetSettlementDelta.amount0() - SafeCast.toInt128(currentDelta0);
        int128 changeDelta1 = targetSettlementDelta.amount1() - SafeCast.toInt128(currentDelta1);

        // Account the delta of delta (the change)
        if (changeDelta0 != 0) {
            accountDelta(underlyingCurrency0, changeDelta0, target);
        }
        if (changeDelta1 != 0) {
            accountDelta(underlyingCurrency1, changeDelta1, target);
        }
    }

    /// @notice Asserts that there are no nonzero deltas
    function assertNonZeroDeltas() internal view {
        if (NonzeroDeltaCount.read() > 0) {
            revert Errors.CurrencyNotSettled();
        }
    }

    // ============================================================
    // Balance-to-Delta Sync
    // ============================================================

    /// @notice Syncs balance accumulation as credit in the delta system
    /// @dev Only handles balance increases (accumulation), not decreases (consumption).
    ///      If balance exceeds current positive delta, increases delta to match balance,
    ///      establishing credit. Also reduces debt if balance is available and delta is negative.
    ///      This is useful after wrap/unwrap operations where balance increases occur outside
    ///      of normal delta accounting flows.
    /// @param currency The currency to sync
    /// @param owner The address whose balance to check (e.g., MMPM which holds the tokens)
    /// @param target The address whose delta to credit (e.g., locker/msgSender)
    /// @return deltaChange The amount by which the delta was adjusted (0 if no change)
    function syncBalanceAsCredit(Currency currency, address owner, address target)
        internal
        returns (int128 deltaChange)
    {
        uint256 balance = currency.balanceOf(owner);
        int256 currentDelta = currency.getDelta(target);

        // Case 1: Owner has balance and target's current delta is non-negative
        // Increase target's delta to match owner's balance if balance exceeds delta
        if (balance > 0 && currentDelta >= 0) {
            uint256 currentDeltaUint = uint256(currentDelta);
            if (balance > currentDeltaUint) {
                uint256 diff = balance - currentDeltaUint;
                deltaChange = SafeCast.toInt128(diff);
                accountDelta(currency, deltaChange, target);
            }
        }
        // Case 2: Owner has balance and target owes (negative delta)
        // Use owner's balance to reduce target's debt
        else if (balance > 0 && currentDelta < 0) {
            uint256 debt = uint256(-currentDelta);
            uint256 reduction = balance < debt ? balance : debt;
            deltaChange = SafeCast.toInt128(reduction);
            accountDelta(currency, deltaChange, target);
        }
        // Case 3: No balance - cannot establish credit from nothing
        // (No action needed)
    }
}

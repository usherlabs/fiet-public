// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {CurrencyDelta} from "v4-periphery/lib/v4-core/src/libraries/CurrencyDelta.sol";
import {NonzeroDeltaCount} from "@uniswap/v4-core/src/libraries/NonzeroDeltaCount.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {LiquidityUtils} from "./LiquidityUtils.sol";
import {ILCC} from "../interfaces/ILCC.sol";
import {VTSStorage} from "../types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {console} from "forge-std/console.sol";

/// @title DynamicCurrencyDelta
/// @notice Library for managing currency deltas and underlying settlement in VTS
/// @dev Operates on VTSStorage for persistent credits, uses transient storage for deltas.
///      Follows Uniswap v4 PoolManager patterns for delta accounting.
/// @author Fiet Protocol
library DynamicCurrencyDelta {
    using CurrencyDelta for Currency;
    using CurrencyLibrary for Currency;

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
    // Persistent Credit Management
    // ============================================================

    /// @notice Primes persistent underlying credits from contract-held balances
    /// @dev Loads min(persistent credit for sender, contract balance) as positive delta to sender (credit)
    ///      representing deduction from contract to sender (flash accounting)
    /// @param s The VTS storage
    /// @param sender The address to prime credits for
    /// @param lccCurrency The LCC currency to prime credits for
    /// @param self The contract address (address(this) of caller)
    function primeUnderlyingCredits(VTSStorage storage s, address sender, Currency lccCurrency, address self) internal {
        Currency underlyingCurrency = lccToUnderlyingCurrency(lccCurrency);
        address ua = Currency.unwrap(underlyingCurrency);

        uint256 persistentCredit = s.persistentUnderlyingCredits[sender][ua];
        if (persistentCredit > 0) {
            uint256 balance = underlyingCurrency.balanceOfSelf();
            uint256 load = Math.min(persistentCredit, balance);
            if (load > 0) {
                // Load positive delta to sender (credit) representing deduction from contract
                accountDelta(underlyingCurrency, SafeCast.toInt128(load), sender);
                s.persistentUnderlyingCredits[sender][ua] = persistentCredit - load;
            }
        }
    }

    /// @notice Persists unavailable underlying credits to persistent storage for a new owner
    /// @dev Only persists the difference between the target's delta and balance (unavailable portion).
    ///      Clears the target's transient delta and persists unavailable credits to newOwner.
    /// @param s The VTS storage
    /// @param target The address whose delta/balance to read (e.g., MMPM)
    /// @param newOwner The address to persist unavailable credits against (e.g., locker)
    /// @param lccCurrency0 The currency of the first LCC
    /// @param lccCurrency1 The currency of the second LCC
    function persistUnavailableUnderlyingCredits(
        VTSStorage storage s,
        address target,
        address newOwner,
        Currency lccCurrency0,
        Currency lccCurrency1
    ) internal {
        Currency uCurrency0 = lccToUnderlyingCurrency(lccCurrency0);
        Currency uCurrency1 = lccToUnderlyingCurrency(lccCurrency1);

        // Get current transient deltas for target
        int256 uaDelta0 = uCurrency0.getDelta(target);
        int256 uaDelta1 = uCurrency1.getDelta(target);

        // Get target's balance
        uint256 balance0 = uCurrency0.balanceOf(target);
        uint256 balance1 = uCurrency1.balanceOf(target);

        // Calculate unavailable amounts (delta - balance, only positive deltas)
        // If delta > balance, the difference is unavailable and needs to be persisted
        if (uaDelta0 > 0) {
            uint256 delta0Uint = uint256(uaDelta0);
            uint256 unavailable0 = delta0Uint > balance0 ? delta0Uint - balance0 : 0;

            if (unavailable0 > 0) {
                address ua0 = Currency.unwrap(uCurrency0);
                s.persistentUnderlyingCredits[newOwner][ua0] += unavailable0;
            }
            // Clear target's transient delta
            accountDelta(uCurrency0, -SafeCast.toInt128(uaDelta0), target);
        }

        if (uaDelta1 > 0) {
            uint256 delta1Uint = uint256(uaDelta1);
            uint256 unavailable1 = delta1Uint > balance1 ? delta1Uint - balance1 : 0;

            if (unavailable1 > 0) {
                address ua1 = Currency.unwrap(uCurrency1);
                s.persistentUnderlyingCredits[newOwner][ua1] += unavailable1;
            }
            // Clear target's transient delta
            accountDelta(uCurrency1, -SafeCast.toInt128(uaDelta1), target);
        }
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
    function accountUnderlyingSettlementDeltaChange(
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
            // TODO: include revert after clamping deltas is implemented
            // revert Errors.CurrencyNotSettled();
            console.log("assertNonZeroDeltas: CurrencyNotSettled", NonzeroDeltaCount.read());
        }
    }

    // ============================================================
    // Balance-to-Delta Sync
    // ============================================================

    /// @notice Syncs the delta for a given currency and owner based on their balance accumulation
    /// @dev Adjusts delta to reflect actual balance held. If balance exceeds current positive delta,
    ///      increases delta to match balance, establishing credit for the locker to take.
    ///      This is useful after wrap/unwrap operations where balance changes occur outside
    ///      of normal delta accounting flows.
    /// @param currency The currency to sync
    /// @param owner The address whose balance/delta to sync
    /// @return deltaChange The amount by which the delta was adjusted (0 if no change)
    function syncBalanceToDeltas(Currency currency, address owner) internal returns (int128 deltaChange) {
        uint256 balance = currency.balanceOf(owner);
        int256 currentDelta = currency.getDelta(owner);

        // Case 1: Owner has balance and current delta is non-negative
        // Increase delta to match balance if balance exceeds delta
        if (balance > 0 && currentDelta >= 0) {
            uint256 currentDeltaUint = uint256(currentDelta);
            if (balance > currentDeltaUint) {
                uint256 diff = balance - currentDeltaUint;
                deltaChange = SafeCast.toInt128(diff);
                accountDelta(currency, deltaChange, owner);
            }
        }
        // Case 2: Owner has balance and owes (negative delta)
        // Use balance to reduce debt
        else if (balance > 0 && currentDelta < 0) {
            uint256 debt = uint256(-currentDelta);
            uint256 reduction = balance < debt ? balance : debt;
            deltaChange = SafeCast.toInt128(reduction);
            accountDelta(currency, deltaChange, owner);
        }
        // Case 3: No balance - cannot establish credit from nothing
        // (No action needed)
    }
}

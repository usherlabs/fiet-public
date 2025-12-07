// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {CurrencyDelta} from "v4-periphery/lib/v4-core/src/libraries/CurrencyDelta.sol";
import {NonzeroDeltaCount} from "@uniswap/v4-core/src/libraries/NonzeroDeltaCount.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {CurrencyTransfer} from "./CurrencyTransfer.sol";
import {LiquidityUtils} from "./LiquidityUtils.sol";
import {ILCC} from "../interfaces/ILCC.sol";
import {IMarketVault} from "../interfaces/IMarketVault.sol";
import {VTSStorage} from "../types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title DynamicCurrencyDelta
/// @notice Library for managing currency deltas and underlying settlement in VTS
/// @dev Operates on VTSStorage for persistent credits, uses transient storage for deltas.
///      Follows Uniswap v4 PoolManager patterns for delta accounting.
/// @author Fiet Protocol
library DynamicCurrencyDelta {
    using CurrencyDelta for Currency;
    using CurrencyTransfer for Currency;
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

    /// @notice Gets the raw delta for a currency and target
    /// @param currency The currency to check
    /// @param target The target address to check delta for
    /// @return The raw delta value
    function getDelta(Currency currency, address target) internal view returns (int256) {
        return currency.getDelta(target);
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
    function primeUnderlyingDelta(VTSStorage storage s, address sender, Currency lccCurrency, address self) internal {
        Currency underlyingCurrency = lccToUnderlyingCurrency(lccCurrency);
        address ua = Currency.unwrap(underlyingCurrency);

        uint256 persistentCredit = s.persistentUnderlyingCredits[sender][ua];
        if (persistentCredit > 0) {
            uint256 balance = underlyingCurrency.balanceOfSelf();
            uint256 load = Math.min(persistentCredit, balance);
            if (load > 0) {
                // Load positive delta to sender (credit) representing deduction from contract
                accountDelta(underlyingCurrency, SafeCast.toInt128(load), sender);
                accountDelta(underlyingCurrency, -SafeCast.toInt128(load), self);
                s.persistentUnderlyingCredits[sender][ua] = persistentCredit - load;
            }
        }
    }

    /// @notice Persists unsettled underlying credits to persistent storage
    /// @dev Persists any positive underlying deltas (protocol owes credits) to persistent mapping and clears transient deltas
    /// @param s The VTS storage
    /// @param sender The address initiating the settlement
    /// @param settlementDelta The settlement delta to persist
    /// @param lccCurrency0 The currency of the first LCC
    /// @param lccCurrency1 The currency of the second LCC
    function persistUnderlyingDelta(
        VTSStorage storage s,
        address sender,
        BalanceDelta settlementDelta,
        Currency lccCurrency0,
        Currency lccCurrency1
    ) internal {
        Currency uCurrency0 = lccToUnderlyingCurrency(lccCurrency0);
        Currency uCurrency1 = lccToUnderlyingCurrency(lccCurrency1);

        // Get current transient deltas if settlementDelta is zero
        if (LiquidityUtils.isZeroDelta(settlementDelta)) {
            int256 uaDelta0 = uCurrency0.getDelta(sender);
            int256 uaDelta1 = uCurrency1.getDelta(sender);
            settlementDelta = toBalanceDelta(SafeCast.toInt128(uaDelta0), SafeCast.toInt128(uaDelta1));
        }

        // Persist positive deltas (protocol owes credits) to persistent storage
        int128 amount0 = settlementDelta.amount0();
        int128 amount1 = settlementDelta.amount1();

        if (amount0 > 0) {
            address ua0 = Currency.unwrap(uCurrency0);
            s.persistentUnderlyingCredits[sender][ua0] += LiquidityUtils.safeInt128ToUint256(amount0);
            accountDelta(uCurrency0, -amount0, sender); // Clear transient delta
        }
        if (amount1 > 0) {
            address ua1 = Currency.unwrap(uCurrency1);
            s.persistentUnderlyingCredits[sender][ua1] += LiquidityUtils.safeInt128ToUint256(amount1);
            accountDelta(uCurrency1, -amount1, sender); // Clear transient delta
        }
    }

    // ============================================================
    // Settlement with MarketVault
    // ============================================================

    /// @notice Settles underlying assets between caller and MarketVault
    /// @dev This function bridges the flow of underlying assets between caller and MarketVault (proxy hook):
    ///      - For deposits (negative delta): Transfers underlying tokens from caller -> MarketVault
    ///      - For withdrawals (positive delta): Transfers underlying tokens from MarketVault -> caller
    /// @param sender The address initiating the settlement
    /// @param marketVault The market vault address
    /// @param settlementDelta The balance delta for underlying asset settlement
    /// @param lccCurrency0 The currency of the first LCC
    /// @param lccCurrency1 The currency of the second LCC
    /// @param self The contract address (address(this) of caller)
    /// @return usedDelta The actual delta used after vault processing
    function settleUnderlying(
        address sender,
        address marketVault,
        BalanceDelta settlementDelta,
        Currency lccCurrency0,
        Currency lccCurrency1,
        address self
    ) internal returns (BalanceDelta usedDelta) {
        Currency underlyingCurrency0 = lccToUnderlyingCurrency(lccCurrency0);
        Currency underlyingCurrency1 = lccToUnderlyingCurrency(lccCurrency1);
        int128 amount0 = settlementDelta.amount0();
        int128 amount1 = settlementDelta.amount1();

        // Step A: Consume any self positive deltas first (withdrawals from contract → sender)
        // This prioritises contract-held balances that were primed at batch start
        int256 selfDelta0 = underlyingCurrency0.getDelta(self);
        int256 selfDelta1 = underlyingCurrency1.getDelta(self);

        if (selfDelta0 > 0 && amount0 > 0) {
            uint256 take0 = Math.min(uint256(selfDelta0), LiquidityUtils.safeInt128ToUint256(amount0));
            if (take0 > 0) {
                // Transfer directly from contract to sender (satisfying primed credit)
                underlyingCurrency0.transfer(sender, take0);
                accountDelta(underlyingCurrency0, -SafeCast.toInt128(take0), sender);
                accountDelta(underlyingCurrency0, SafeCast.toInt128(take0), self);
                amount0 -= SafeCast.toInt128(take0);
            }
        }

        if (selfDelta1 > 0 && amount1 > 0) {
            uint256 take1 = Math.min(uint256(selfDelta1), LiquidityUtils.safeInt128ToUint256(amount1));
            if (take1 > 0) {
                // Transfer directly from contract to sender (satisfying primed credit)
                underlyingCurrency1.transfer(sender, take1);
                accountDelta(underlyingCurrency1, -SafeCast.toInt128(take1), sender);
                accountDelta(underlyingCurrency1, SafeCast.toInt128(take1), self);
                amount1 -= SafeCast.toInt128(take1);
            }
        }

        // Process deposits first (amount < 0), then notify vault, then process withdrawals (amount > 0)
        // This ensures the vault is funded before withdrawals
        if (amount0 < 0) {
            _settleUnderlyingCurrencyWithVault(underlyingCurrency0, amount0, sender, marketVault);
        }
        if (amount1 < 0) {
            _settleUnderlyingCurrencyWithVault(underlyingCurrency1, amount1, sender, marketVault);
        }

        // Notify the MarketVault (proxy hook) of the settled underlying tokens
        // A positive balance delta means withdrawing underlying tokens, negative balance means depositing underlying tokens,
        // Call after deposits (so MV is funded), but before withdrawals.
        // To prevent failure when liquidity in market is insufficient to cover the withdrawal, we tryModifyLiquidities and account LCCs for excess.
        // TODO: Move this back into MMPM - ensuring that funds transfer MMPM <-> MV <-> LiqHub - where VTSO is used for delta management / authentication.
        usedDelta = IMarketVault(marketVault).tryModifyLiquidities(LiquidityUtils.safeToBalanceDelta(amount0, amount1));

        if (usedDelta.amount0() > 0) {
            _settleUnderlyingCurrencyWithVault(underlyingCurrency0, usedDelta.amount0(), sender, marketVault);
        }
        if (usedDelta.amount1() > 0) {
            _settleUnderlyingCurrencyWithVault(underlyingCurrency1, usedDelta.amount1(), sender, marketVault);
        }
    }

    /// @notice Clamps the settlement delta by the available liquidities in the vault
    /// @param marketVault The market vault address
    /// @param settlementDelta The settlement delta to clamp
    /// @return clampedDelta The clamped settlement delta
    function clampSettlementDeltaByAvailableLiquidities(address marketVault, BalanceDelta settlementDelta)
        internal
        returns (BalanceDelta clampedDelta)
    {
        return IMarketVault(marketVault).dryModifyLiquidities(settlementDelta);
    }

    // ============================================================
    // Take / Transfer Helpers
    // ============================================================

    /// @notice Takes up to maxAmount from contract's balance of currency to 'to', capping to caller's positive delta
    /// @dev Takes min(caller's positive delta, maxAmount) from contract's balance and nets the delta
    /// @param currency The currency to take
    /// @param sender The address initiating the take
    /// @param to The recipient address
    /// @param maxAmount The maximum amount to take (use 0 for full available)
    function take(Currency currency, address sender, address to, uint256 maxAmount) internal {
        int256 delta = currency.getDelta(sender);

        if (delta < 0) return; // No positive delta (credit) available

        // Cap to min of positive delta and maxAmount
        uint256 availableCredit = uint256(delta);
        uint256 amountToTake = maxAmount == 0 ? availableCredit : Math.min(availableCredit, maxAmount);

        // Net the delta by accounting the negative amount taken
        int128 deltaToAccount = (delta > 0 && SafeCast.toInt256(amountToTake) > delta)
            ? SafeCast.toInt128(-delta)
            : -SafeCast.toInt128(amountToTake);
        accountDelta(currency, deltaToAccount, sender);

        // Transfer the amount from contract's balance to 'to'
        currency.transfer(to, amountToTake);
    }

    // ============================================================
    // Internal Helpers
    // ============================================================

    /// @notice Settles a single underlying currency based on the settlement amount
    /// @dev Handles both deposits (amount < 0) and withdrawals (amount > 0) with proper delta accounting.
    /// @param currency The currency to settle
    /// @param amount The settlement amount (negative for deposits, positive for withdrawals)
    /// @param sender The address initiating the settlement
    /// @param marketVault The market vault address for transfers
    function _settleUnderlyingCurrencyWithVault(Currency currency, int128 amount, address sender, address marketVault)
        private
    {
        if (amount == 0) return;

        int256 delta = currency.getDelta(sender);

        if (amount < 0) {
            // Deposit: transfer FROM caller TO vault
            // If delta is negative (caller owes protocol) and amount < delta (deposit exceeds debt),
            // net the delta to zero. Otherwise, account the full amount.
            int128 deltaToAccount = (delta < 0 && int256(amount) < delta) ? SafeCast.toInt128(-delta) : -amount;
            accountDelta(currency, deltaToAccount, sender);
            currency.transferFrom(sender, marketVault, LiquidityUtils.safeInt128ToUint256(amount));
        } else {
            // Withdrawal: transfer FROM vault TO caller
            // Reduce sender's credit (positive delta) by the withdrawal amount
            // If delta is positive (protocol owes caller) and amount > delta (withdrawal exceeds credit),
            // net the delta to zero. Otherwise account the full (negative) amount to reduce credit.
            int128 deltaToAccount = (delta > 0 && int256(amount) > delta) ? SafeCast.toInt128(-delta) : -amount;
            accountDelta(currency, deltaToAccount, sender);
            currency.transfer(sender, LiquidityUtils.safeInt128ToUint256(amount));
        }
    }

    /// @notice Asserts that there are no nonzero deltas
    /// @param s The VTS storage
    function assertNonZeroDeltas() internal view {
        if (NonzeroDeltaCount.read() > 0) {
            // TODO: include revert after clamping deltas is implemented
            // revert Errors.CurrencyNotSettled();
            console.log("assertNonZeroDeltas: CurrencyNotSettled", NonzeroDeltaCount.read());
        }
    }
}

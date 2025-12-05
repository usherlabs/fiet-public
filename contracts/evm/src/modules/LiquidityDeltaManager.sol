// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-periphery/lib/v4-core/src/libraries/LPFeeLibrary.sol";
import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {Errors} from "../libraries/Errors.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {MarketHandler} from "./MarketHandler.sol";
import {CurrencyTransfer} from "../libraries/CurrencyTransfer.sol";
import {IMarketVault} from "../interfaces/IMarketVault.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityUtils} from "../libraries/LiquidityUtils.sol";
import {ILCC} from "../interfaces/ILCC.sol";
import {CurrencyDelta} from "v4-periphery/lib/v4-core/src/libraries/CurrencyDelta.sol";
import {NonzeroDeltaCount} from "@uniswap/v4-core/src/libraries/NonzeroDeltaCount.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {TransientSlots} from "../libraries/TransientSlots.sol";
import {NativeWrapper} from "./NativeWrapper.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

/**
 * @title LiquidityDeltaManager
 * @notice Abstract contract that bridges liquidity operations between MMPositionManager and the Uniswap V4
 *         PoolManager/MarketVault.
 * @dev This contract acts as a bridge/router that:
 *      - Handles liquidity modifications with the PoolManager (adding/removing liquidity from Uniswap V4 pools)
 *      - Manages settlement flows of underlying assets between MMPositionManager (MMP) and MarketVault (MV)
 *      - Coordinates the transfer of underlying tokens for deposits and withdrawals
 *
 * Flow:
 *   VTSOrchestrator (VTSO) / LiquidityDeltaManager <-> MarketVault (MV)
 *
 *   - For position modifications: Router -> PM (via _modifyPositionLiquidity)
 *   - For underlying settlement: Router <-> MV (via _settleUnderlying)
 *
 * Note: This contract is inherited by MMPositionManager, which provides the concrete implementation
 *       including the msgSender() override to identify the caller.
 * Note: LCCs are never settled in. MMP is responsible for issuing/cancelling (ie. mint/burn) LCCs per positions based on (out-of-protocol) liquidity signals.
 *       However, LCC acrrued as fees can be taken from the MMP.
 */
abstract contract LiquidityDeltaManager is ImmutableState, MarketHandler, NativeWrapper {
    using CurrencySettler for Currency;
    using CurrencyTransfer for Currency;
    using CurrencyLibrary for Currency;
    using CurrencyDelta for Currency;
    using Hooks for IHooks;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    // Persistent storage to track unsettled underlying credits owed by MMP to users
    mapping(address target => mapping(address underlying => uint256 credit)) internal _persistentUnderlyingCredits;

    /**
     * @notice Constructs the LiquidityDeltaManager
     * @param _weth9 Address of the WETH9 contract
     */
    constructor(address _marketFactory, IWETH9 _weth9) MarketHandler(_marketFactory) NativeWrapper(_weth9) {}

    /**
     * @notice Primes persistent underlying credits from MMP-held balances
     * @dev Loads min(persistent credit for sender, MMP contract balance) as positive delta to sender (credit)
     *      representing deduction from address(this) to sender (flash accounting)
     * @param sender The address to prime credits for
     * @param lccCurrency The LCC currency to prime credits for
     */
    function _primeUnderlyingDelta(address sender, Currency lccCurrency) internal {
        Currency underlyingCurrency = _lccToUnderlyingCurrency(lccCurrency);
        address ua = Currency.unwrap(underlyingCurrency);

        uint256 persistentCredit = _persistentUnderlyingCredits[sender][ua];
        if (persistentCredit > 0) {
            uint256 balance = underlyingCurrency.balanceOfSelf();
            uint256 load = Math.min(persistentCredit, balance);
            if (load > 0) {
                // Load positive delta to sender (credit) representing deduction from MMP
                // TODO: Revise how we prime these deltas to address(this);
                _accountDelta(underlyingCurrency, SafeCast.toInt128(load), sender);
                _accountDelta(underlyingCurrency, -SafeCast.toInt128(load), address(this)); // indicate (negative) from this to (positive) to sender
                _persistentUnderlyingCredits[sender][ua] = persistentCredit - load;
            }
        }
    }

    /**
     * @notice Settles underlying assets between MMPositionManager and MarketVault based on
     *         protocol-defined settlement rules
     * @dev This function bridges the flow of underlying assets between MMP and MarketVault (proxy hook):
     *      - For deposits (positive delta): Transfers underlying tokens from MMP -> MarketVault
     *      - For withdrawals (negative delta): Transfers underlying tokens from MarketVault -> MMP
     *
     * The settlementDelta represents the actual settled amounts determined by protocol rules (via VTSManager),
     * which may differ from the modifyDelta due to clamping or adjustments.
     *
     * Flow:
     *   1. Consume any sender positive deltas first (withdrawals from MMP → sender)
     *   2. Deposits: MMP -> Router -> MarketVault (via transferFrom)
     *   3. Notify MarketVault of liquidity changes (via modifyLiquidities)
     *   4. Withdrawals: MarketVault -> Router -> MMP (via transfer)
     *
     * @param sender The address initiating the settlement
     * @param poolId The pool ID associated with the position
     * @param settlementDelta The balance delta for underlying asset settlement. Positive means depositing to MV,
     *                        negative means withdrawing from MV to MMP
     * @param lccCurrency0 The currency of the first LCC
     * @param lccCurrency1 The currency of the second LCC
     */
    function _settleUnderlying(
        address sender,
        PoolId poolId,
        BalanceDelta settlementDelta,
        Currency lccCurrency0,
        Currency lccCurrency1
    ) internal returns (BalanceDelta usedDelta) {
        address marketVault = _getVault(poolId);
        Currency underlyingCurrency0 = _lccToUnderlyingCurrency(lccCurrency0);
        Currency underlyingCurrency1 = _lccToUnderlyingCurrency(lccCurrency1);
        int128 amount0 = settlementDelta.amount0();
        int128 amount1 = settlementDelta.amount1();

        // Step A: Consume any self negative deltas first (withdrawals from MMP → sender)
        // This prioritises MMP-held balances that were primed at batch start
        int256 selfDelta0 = underlyingCurrency0.getDelta(address(this));
        int256 selfDelta1 = underlyingCurrency1.getDelta(address(this));

        if (selfDelta0 > 0 && amount0 > 0) {
            uint256 take0 = Math.min(uint256(selfDelta0), LiquidityUtils.safeInt128ToUint256(amount0));
            if (take0 > 0) {
                // Transfer directly from MMP to sender (satisfying primed credit)
                underlyingCurrency0.transfer(sender, take0);
                _accountDelta(underlyingCurrency0, -SafeCast.toInt128(take0), sender);
                _accountDelta(underlyingCurrency0, SafeCast.toInt128(take0), address(this));
                amount0 -= SafeCast.toInt128(take0);
            }
        }

        if (selfDelta1 > 0 && amount1 > 0) {
            uint256 take1 = Math.min(uint256(selfDelta1), LiquidityUtils.safeInt128ToUint256(amount1));
            if (take1 > 0) {
                // Transfer directly from MMP to sender (satisfying primed credit)
                underlyingCurrency1.transfer(sender, take1);
                _accountDelta(underlyingCurrency1, -SafeCast.toInt128(take1), sender);
                _accountDelta(underlyingCurrency1, SafeCast.toInt128(take1), address(this));
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
        // ---- eg. Failure on mass unwrap of LCCs, settled liquidity is used as coverage, then burn position.
        // ---- Basically, on decrease, return assets to the caller as LCCs in excess of usedDelta.
        usedDelta = IMarketVault(marketVault).tryModifyLiquidities(LiquidityUtils.safeToBalanceDelta(amount0, amount1));

        if (usedDelta.amount0() > 0) {
            _settleUnderlyingCurrencyWithVault(underlyingCurrency0, usedDelta.amount0(), sender, marketVault);
        }
        if (usedDelta.amount1() > 0) {
            _settleUnderlyingCurrencyWithVault(underlyingCurrency1, usedDelta.amount1(), sender, marketVault);
        }
    }

    /**
     * @notice Gets the underlying settlement delta for a sender
     * @param sender The address initiating the settlement
     * @param lccCurrency0 The first LCC currency
     * @param lccCurrency1 The second LCC currency
     * @return settlementDelta The settlement delta for the sender
     */
    function _getUnderlyingSettlementDelta(address sender, Currency lccCurrency0, Currency lccCurrency1)
        internal
        view
        returns (BalanceDelta)
    {
        Currency uCurrency0 = _lccToUnderlyingCurrency(lccCurrency0);
        Currency uCurrency1 = _lccToUnderlyingCurrency(lccCurrency1);
        int256 uDelta0 = uCurrency0.getDelta(sender);
        int256 uDelta1 = uCurrency1.getDelta(sender);
        return toBalanceDelta(SafeCast.toInt128(uDelta0), SafeCast.toInt128(uDelta1));
    }

    /**
     * @notice Clamps the settlement delta by the available liquidities
     * @param poolId The pool ID
     * @param settlementDelta The settlement delta to clamp
     * @return clampedDelta The clamped settlement delta
     */
    function _clampSettlementDeltaByAvailableLiquidities(PoolId poolId, BalanceDelta settlementDelta)
        internal
        returns (BalanceDelta)
    {
        address marketVault = _getVault(poolId);
        return IMarketVault(marketVault).dryModifyLiquidities(settlementDelta);
    }

    /**
     * @notice Persists unsettled underlying credits to persistent storage
     * @dev Persists any positive underlying deltas (MMP owes credits) to persistent mapping and clears transient deltas
     * @param sender The address initiating the settlement
     * @param settlementDelta The settlement delta to persist
     * @param lccCurrency0 The currency of the first LCC
     * @param lccCurrency1 The currency of the second LCC
     */
    function _persistUnderlyingDelta(
        address sender,
        BalanceDelta settlementDelta,
        Currency lccCurrency0,
        Currency lccCurrency1
    ) internal {
        Currency uCurrency0 = _lccToUnderlyingCurrency(lccCurrency0);
        Currency uCurrency1 = _lccToUnderlyingCurrency(lccCurrency1);

        // Get current transient deltas if settlementDelta is zero
        if (LiquidityUtils.isZeroDelta(settlementDelta)) {
            int256 uaDelta0 = uCurrency0.getDelta(sender);
            int256 uaDelta1 = uCurrency1.getDelta(sender);
            settlementDelta = toBalanceDelta(SafeCast.toInt128(uaDelta0), SafeCast.toInt128(uaDelta1));
        }

        // Persist positive deltas (MMP owes credits) to persistent storage
        int128 amount0 = settlementDelta.amount0();
        int128 amount1 = settlementDelta.amount1();

        if (amount0 > 0) {
            address ua0 = Currency.unwrap(uCurrency0);
            _persistentUnderlyingCredits[sender][ua0] += LiquidityUtils.safeInt128ToUint256(amount0);
            _accountDelta(uCurrency0, -amount0, sender); // Clear transient delta
        }
        if (amount1 > 0) {
            address ua1 = Currency.unwrap(uCurrency1);
            _persistentUnderlyingCredits[sender][ua1] += LiquidityUtils.safeInt128ToUint256(amount1);
            _accountDelta(uCurrency1, -amount1, sender); // Clear transient delta
        }
    }

    /**
     * @notice Settles a single underlying currency based on the settlement amount
     * @dev Handles both deposits (amount < 0) and withdrawals (amount > 0) with proper delta accounting.
     *      For deposits: If delta is negative (caller owes) and amount < delta (deposit exceeds debt),
     *                    nets the delta to zero. Otherwise accounts the full amount.
     *      For withdrawals: If delta is positive (protocol owes) and amount > delta (withdrawal exceeds credit),
     *                      nets the delta to zero. Otherwise accounts the full amount.
     * @param currency The currency to settle
     * @param amount The settlement amount (negative for deposits, positive for withdrawals)
     * @param sender The address initiating the settlement
     * @param marketVault The market vault address for transfers
     */
    function _settleUnderlyingCurrencyWithVault(Currency currency, int128 amount, address sender, address marketVault)
        private
    {
        if (amount == 0) return;

        int256 delta = currency.getDelta(sender);

        if (amount < 0) {
            // Deposit: transfer FROM caller TO vault
            // If delta is negative (caller owes protocol) and amount < delta (deposit exceeds debt),
            // net the delta to zero. Otherwise, account the full amount.
            // * This allows settlement above what is required.
            int128 deltaToAccount = (delta < 0 && int256(amount) < delta) ? SafeCast.toInt128(-delta) : -amount;
            _accountDelta(currency, deltaToAccount, sender);
            currency.transferFrom(sender, marketVault, LiquidityUtils.safeInt128ToUint256(amount));
        } else {
            // Withdrawal: transfer FROM vault TO caller
            // Reduce sender's credit (positive delta) by the withdrawal amount
            // If delta is positive (protocol owes caller) and amount > delta (withdrawal exceeds credit),
            // net the delta to zero. Otherwise account the full (negative) amount to reduce credit.
            int128 deltaToAccount = (delta > 0 && int256(amount) > delta) ? SafeCast.toInt128(-delta) : -amount;
            _accountDelta(currency, deltaToAccount, sender);
            currency.transfer(sender, LiquidityUtils.safeInt128ToUint256(amount));
        }
    }

    /**
     * @notice Accounts a delta for a currency and target address
     * @dev Increments or decrements the nonzero delta count based on the previous and next deltas.
     *      Early returns if delta is zero for gas optimisation.
     * @param currency The currency to account the delta for
     * @param delta The delta to account
     * @param target The target address to account the delta for
     */
    function _accountDelta(Currency currency, int128 delta, address target) internal {
        if (delta == 0) return; // Gas optimisation: no-op for zero delta
        (int256 previous, int256 next) = currency.applyDelta(target, delta);
        if (next == 0) {
            NonzeroDeltaCount.decrement();
        } else if (previous == 0) {
            NonzeroDeltaCount.increment();
        }
    }

    /**
     * @notice Accounts the change in settlement delta for underlying currencies
     * @dev Reads the current currency delta, calculates the change needed to reach the target settlement delta,
     *      and accounts that change (delta of delta)
     * @param sender The address initiating the settlement
     * @param targetSettlementDelta The target settlement delta to reach
     * @param currency0 The first currency to account the delta change for
     * @param currency1 The second currency to account the delta change for
     */
    function _accountUnderlyingSettlementDeltaChange(
        address sender,
        BalanceDelta targetSettlementDelta,
        Currency currency0,
        Currency currency1
    ) internal {
        Currency underlyingCurrency0 = _lccToUnderlyingCurrency(currency0);
        Currency underlyingCurrency1 = _lccToUnderlyingCurrency(currency1);

        // Read current currency deltas
        int256 currentDelta0 = underlyingCurrency0.getDelta(sender);
        int256 currentDelta1 = underlyingCurrency1.getDelta(sender);

        // Calculate the delta of delta (the change): targetSettlementDelta - currentDelta
        int128 changeDelta0 = targetSettlementDelta.amount0() - SafeCast.toInt128(currentDelta0);
        int128 changeDelta1 = targetSettlementDelta.amount1() - SafeCast.toInt128(currentDelta1);

        // Account the delta of delta (the change)
        _accountDelta(underlyingCurrency0, changeDelta0, sender);
        _accountDelta(underlyingCurrency1, changeDelta1, sender);
    }

    /**
     * @notice Takes up to maxAmount from MMP's balance of currency to 'to', capping to caller's positive delta
     * @dev Takes min(caller's positive delta, maxAmount) from MMP's balance and nets the delta
     * @param currency The currency to take
     * @param sender The address initiating the take
     * @param to The recipient address
     * @param maxAmount The maximum amount to take (use type(uint256).max for full available)
     */
    function _take(Currency currency, address sender, address to, uint256 maxAmount) internal {
        int256 delta = currency.getDelta(sender);

        if (delta < 0) return; // No positive delta (credit) available

        // Cap to min of positive delta and maxAmount
        uint256 availableCredit = uint256(delta);
        uint256 amountToTake = maxAmount == 0 ? availableCredit : Math.min(availableCredit, maxAmount);

        // Net the delta by accounting the negative amount taken
        // Mirror logic from lines 257-262: if amount > delta, net to zero, otherwise account full amount
        int128 deltaToAccount = (delta > 0 && SafeCast.toInt256(amountToTake) > delta)
            ? SafeCast.toInt128(-delta)
            : -SafeCast.toInt128(amountToTake);
        _accountDelta(currency, deltaToAccount, sender);

        // Transfer the amount from MMP's balance to 'to' (assumes MMP holds the tokens)
        currency.transfer(to, amountToTake);
    }

    /**
     * @notice Gets the full positive delta (credit) for a currency and target address
     * @param currency The currency to check
     * @param target The target address to check delta for
     * @return The positive delta amount, or 0 if delta is not positive
     */
    function _getFullCredit(Currency currency, address target) internal view returns (uint256) {
        int256 delta = currency.getDelta(target);
        return (delta > 0) ? uint256(delta) : 0;
    }

    /**
     * @notice Converts an LCC currency to its underlying currency
     * @param lccCurrency The LCC currency to convert
     * @return The underlying currency
     */
    function _lccToUnderlyingCurrency(Currency lccCurrency) internal view returns (Currency) {
        return Currency.wrap(ILCC(Currency.unwrap(lccCurrency)).underlying());
    }

    /**
     * @notice Handles the native value for a sender
     * @dev Reads from cache to determine if native msg.value has been factored into currencyDelta.
     * @dev This is essentially a "credit full amount once, debit as needed" pattern.
     * @param sender The address initiating the settlement
     */
    function _handleNativeValue(address sender) internal {
        uint256 nativeValue = TransientSlots.readMsgValueOnce();
        if (nativeValue > 0) {
            _accountDelta(CurrencyLibrary.ADDRESS_ZERO, SafeCast.toInt128(nativeValue), sender);
        }
    }

    /**
     * @notice Wraps native assets into WETH
     * @dev Wraps native assets into WETH into this contract
     * @param sender The address initiating the wrap
     * @param amount The amount of native assets to wrap
     */
    function _wrapNative(address sender, uint256 amount) internal {
        int256 nativeDelta = CurrencyLibrary.ADDRESS_ZERO.getDelta(sender);
        if (nativeDelta < 0) {
            // if the native delta is negative, then the caller is in debt to protocol. Tx will fail.
            revert Errors.InvalidAmount(amount, 0);
        }
        uint256 wrapAmt = amount > uint256(nativeDelta) ? uint256(nativeDelta) : amount;
        if (wrapAmt > 0) {
            _wrap(wrapAmt); // deposit ETH to WETH into this contract
            _accountDelta(CurrencyLibrary.ADDRESS_ZERO, -SafeCast.toInt128(wrapAmt), sender);
            _accountDelta(Currency.wrap(address(WETH9)), SafeCast.toInt128(wrapAmt), sender);
        }
    }

    /**
     * @notice Unwraps WETH into native assets
     * @dev Unwraps WETH into native assets from this contract
     * @param sender The address initiating the unwrap
     * @param amount The amount of WETH to unwrap
     */
    function _unwrapNative(address sender, uint256 amount) internal {
        Currency weth = Currency.wrap(address(WETH9));
        int256 wethDelta = weth.getDelta(sender);
        if (wethDelta < 0) {
            // if the WETH delta is negative, then the caller is in debt to protocol. Tx will fail.
            revert Errors.InvalidAmount(amount, 0);
        }
        uint256 unwrapAmt = amount > uint256(wethDelta) ? uint256(wethDelta) : amount;
        if (unwrapAmt > 0) {
            _unwrap(unwrapAmt); // withdraw WETH to ETH into this contract
            _accountDelta(weth, -SafeCast.toInt128(unwrapAmt), sender);
            _accountDelta(CurrencyLibrary.ADDRESS_ZERO, SafeCast.toInt128(unwrapAmt), sender);
        }
    }
}

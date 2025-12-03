// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {Errors} from "./Errors.sol";
import {CurrencyTransfer} from "../libraries/CurrencyTransfer.sol";
import {CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {CurrencyDelta} from "v4-periphery/lib/v4-core/src/libraries/CurrencyDelta.sol";
import {NonzeroDeltaCount} from "@uniswap/v4-core/src/libraries/NonzeroDeltaCount.sol";
import {ILCC} from "../interfaces/ILCC.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {PoolId} from "../types/Pool.sol";
import {LiquidityUtils} from "../libraries/LiquidityUtils.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {Hooks} from "v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-periphery/lib/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {IMarketVault} from "../interfaces/IMarketVault.sol";
import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {TransientSlots} from "../libraries/TransientSlots.sol";

/// @title MMLiquidityLib
/// @notice Library for managing MM-managed liquidity

library MMLiquidityLib {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using CurrencyTransfer for Currency;
    using CurrencyLibrary for Currency;
    using CurrencyDelta for Currency;
    using Hooks for IHooks;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    function _modifyPositionLiquidity(
        IPoolManager poolManager,
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        bytes memory hookData
    ) public returns (BalanceDelta delta, BalanceDelta feesAccrued) {
        bool settleUsingBurn = false;
        bool takeClaims = false;

        // Note: Pool manager must already be unlocked by the caller (MMPositionManager handles this)
        address self = address(this);

        // Get liquidity state before modification for validation
        (uint128 liquidityBefore,,) =
            poolManager.getPositionInfo(key.toId(), self, params.tickLower, params.tickUpper, params.salt);

        // PoolManager returns two deltas:
        // - delta (callerDelta): principal liquidity change plus any immediate fee/hook deltas applied
        //   to the caller
        // - feesAccrued: informational delta of fee growth in the modified range for this call
        // Downstream, MMPositionManager treats principal vs feesAccrued differently: principal maps
        // to LCC issue/cancel, while feesAccrued (originating from trader flows, wrapped into LCCs)
        // must remain wrapped until explicitly unwrapped.
        (delta, feesAccrued) = poolManager.modifyLiquidity(key, params, hookData);

        // Get liquidity state after modification for validation
        (uint128 liquidityAfter,,) =
            poolManager.getPositionInfo(key.toId(), self, params.tickLower, params.tickUpper, params.salt);

        // Get net currency deltas from PoolManager
        // currencyDelta is a net including fee accrual plus any hook-side fee-sharing that's already
        // been applied at modification time.

        // Note: Prior actions in a batch don't accumulate here because each _modifyLiquidity call
        // immediately settles its deltas, resetting currencyDelta to 0 before the next
        // action. The delta read here reflects only the current modification's effect (including hook
        // adjustments like feeAdj from CoreHook). Other actions (e.g., SETTLE_POSITION) account deltas
        // to the hook contract, not to MMPositionManager, so they don't affect this currencyDelta.
        int256 delta0 = poolManager.currencyDelta(self, key.currency0);
        int256 delta1 = poolManager.currencyDelta(self, key.currency1);

        // Validate that liquidity change matches expected delta
        if (int128(liquidityBefore) + params.liquidityDelta != int128(liquidityAfter)) {
            revert Errors.InvariantViolated("liquidity change incorrect");
        }

        // Validate currency delta direction matches liquidity operation type
        if (params.liquidityDelta < 0) {
            // Removing liquidity: PoolManager owes tokens to the LP (positive delta)
            assert(delta0 > 0 || delta1 > 0);
            assert(!(delta0 < 0 || delta1 < 0));
        } else if (params.liquidityDelta > 0) {
            // Adding liquidity: LP owes tokens to PoolManager (negative delta)
            assert(delta0 < 0 || delta1 < 0);
            assert(!(delta0 > 0 || delta1 > 0));
        }

        // Settle negative deltas: pay tokens owed to PoolManager (LP is depositing)
        if (delta0 < 0) {
            key.currency0.settle(poolManager, self, uint256(-delta0), settleUsingBurn);
        }
        if (delta1 < 0) {
            key.currency1.settle(poolManager, self, uint256(-delta1), settleUsingBurn);
        }

        // Take positive deltas: receive tokens owed from PoolManager (LP is withdrawing)
        if (delta0 > 0) {
            key.currency0.take(poolManager, self, uint256(delta0), takeClaims);
        }
        if (delta1 > 0) {
            key.currency1.take(poolManager, self, uint256(delta1), takeClaims);
        }
    }

    function _lccToUnderlyingCurrency(Currency lccCurrency) internal view returns (Currency) {
        return Currency.wrap(ILCC(Currency.unwrap(lccCurrency)).underlying());
    }

    function _primeUnderlyingDelta(
        mapping(address target => mapping(address underlying => uint256 credit)) storage _persistentUnderlyingCredits,
        Currency currency,
        address sender
    ) internal {
        Currency underlyingCurrency = _lccToUnderlyingCurrency(currency);
        address ua = Currency.unwrap(underlyingCurrency);

        uint256 persistentCredit = _persistentUnderlyingCredits[sender][ua];
        if (persistentCredit > 0) {
            uint256 balance = underlyingCurrency.balanceOfSelf();
            uint256 load = Math.min(persistentCredit, balance);
            if (load > 0) {
                // Load positive delta to sender (credit) representing deduction from MMP
                _accountDelta(underlyingCurrency, SafeCast.toInt128(load), sender);
                _accountDelta(underlyingCurrency, -SafeCast.toInt128(load), address(this)); // indicate (negative) from this to (positive) to sender
                _persistentUnderlyingCredits[sender][ua] = persistentCredit - load;
            }
        }
    }

    function _settleUnderlyingDelta(
        IMarketFactory marketFactory,
        address sender,
        PoolId poolId,
        BalanceDelta settlementDelta,
        Currency lccCurrency0,
        Currency lccCurrency1
    ) internal returns (BalanceDelta usedDelta) {
        address marketVault = marketFactory.corePoolToProxyHook(poolId);
        Currency underlyingCurrency0 = _lccToUnderlyingCurrency(lccCurrency0);
        Currency underlyingCurrency1 = _lccToUnderlyingCurrency(lccCurrency1);
        int128 amount0 = settlementDelta.amount0();
        int128 amount1 = settlementDelta.amount1();

        // Step A: Consume any self negative deltas first (withdrawals from MMP → sender)
        // This prioritises MMP-held balances that were primed at batch start
        int256 selfDelta0 = underlyingCurrency0.getDelta(address(this));
        int256 selfDelta1 = underlyingCurrency1.getDelta(address(this));

        // ? should this be amount0 < 0?
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
        // ? should this be amount0 < 0?
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

    function _settleUnderlyingCurrencyWithVault(Currency currency, int128 amount, address sender, address marketVault)
        internal
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
            // If delta is positive (protocol owes caller) and amount > delta (withdrawal exceeds credit),

            // Avoid delta net, to prevent withdrawal of more than is credited to the caller.
            // log the delta of the currency
            _accountDelta(currency, -amount, sender);
            currency.transfer(sender, LiquidityUtils.safeInt128ToUint256(amount));
        }
    }

    function _accountDelta(Currency currency, int128 delta, address target) internal {
        (int256 previous, int256 next) = currency.applyDelta(target, delta);

        // do nothing if both previous and next are zero ie there was no change/transition in the delta
        if (previous == 0 && next == 0) {
            return;
        }
        if (next == 0) {
            NonzeroDeltaCount.decrement();
        } else if (previous == 0) {
            NonzeroDeltaCount.increment();
        }
    }

    function _persistUnderlyingDelta(
        mapping(address target => mapping(address underlying => uint256 credit)) storage _persistentUnderlyingCredits,
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

    function _getFullCredit(Currency currency, address target) internal view returns (uint256) {
        int256 delta = currency.getDelta(target);
        return (delta > 0) ? uint256(delta) : 0;
    }

    function _handleNativeValue(address sender) internal {
        uint256 nativeValue = TransientSlots.readMsgValueOnce();
        if (nativeValue > 0) {
            _accountDelta(CurrencyLibrary.ADDRESS_ZERO, SafeCast.toInt128(nativeValue), sender);
        }
    }

    function _wrapNative(address weth9, address sender, uint256 amount) internal returns (uint256) {
        int256 nativeDelta = CurrencyLibrary.ADDRESS_ZERO.getDelta(sender);
        if (nativeDelta < 0) {
            // if the native delta is negative, then the caller is in debt to protocol. Tx will fail.
            revert Errors.InvalidAmount(amount, 0);
        }
        uint256 wrapAmt = amount > uint256(nativeDelta) ? uint256(nativeDelta) : amount;
        if (wrapAmt > 0) {
            // _wrap(wrapAmt); // deposit ETH to WETH into this contract
            _accountDelta(CurrencyLibrary.ADDRESS_ZERO, -SafeCast.toInt128(wrapAmt), sender);
            _accountDelta(Currency.wrap(weth9), SafeCast.toInt128(wrapAmt), sender);
        }

        return wrapAmt;
    }

    function _unwrapNative(address weth9, address sender, uint256 amount) internal returns (uint256) {
        Currency weth = Currency.wrap(weth9);
        int256 wethDelta = weth.getDelta(sender);
        if (wethDelta < 0) {
            // if the WETH delta is negative, then the caller is in debt to protocol. Tx will fail.
            revert Errors.InvalidAmount(amount, 0);
        }
        uint256 unwrapAmt = amount > uint256(wethDelta) ? uint256(wethDelta) : amount;
        if (unwrapAmt > 0) {
            // _unwrap(unwrapAmt); // withdraw WETH to ETH into this contract
            _accountDelta(weth, -SafeCast.toInt128(unwrapAmt), sender);
            _accountDelta(CurrencyLibrary.ADDRESS_ZERO, SafeCast.toInt128(unwrapAmt), sender);
        }

        return unwrapAmt;
    }
}

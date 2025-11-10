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

/**
 * @title LiquidityRouter
 * @notice Abstract contract that bridges liquidity operations between MMPositionManager and the Uniswap V4
 *         PoolManager/MarketVault.
 * @dev This contract acts as a bridge/router that:
 *      - Handles liquidity modifications with the PoolManager (adding/removing liquidity from Uniswap V4 pools)
 *      - Manages settlement flows of underlying assets between MMPositionManager (MMP) and MarketVault (MV)
 *      - Coordinates the transfer of underlying tokens for deposits and withdrawals
 *
 * Flow:
 *   MMPositionManager (MMP) / LiquidityRouter <-> PoolManager (PM) || MarketVault (MV)
 *
 *   - For position modifications: Router -> PM (via _modifyPositionLiquidity)
 *   - For underlying settlement: Router <-> MV (via _settleUnderlying)
 *
 * Note: This contract is inherited by MMPositionManager, which provides the concrete implementation
 *       including the msgSender() override to identify the caller.
 * Note: LCCs are never settled in. MMP is responsible for issuing/cancelling (ie. mint/burn) LCCs per positions based on (out-of-protocol) liquidity signals.
 *       However, LCC acrrued as fees can be taken from the MMP.
 */
abstract contract LiquidityRouter is ImmutableState, MarketHandler, NativeWrapper {
    using CurrencySettler for Currency;
    using CurrencyTransfer for Currency;
    using CurrencyLibrary for Currency;
    using CurrencyDelta for Currency;
    using Hooks for IHooks;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /**
     * @notice Constructs the LiquidityRouter
     * @param _marketFactory Address of the MarketFactory contract
     */
    constructor(address _marketFactory, IWETH9 _weth9) MarketHandler(_marketFactory) NativeWrapper(_weth9) {}

    /**
     * @notice Modifies liquidity parameters of LCC-based position in a Uniswap V4 pool via the PoolManager
     * @dev This function bridges liquidity modifications from MMPositionManager to the PoolManager:
     *      - Calls PoolManager.modifyLiquidity() to add or remove liquidity
     *      - Validates the liquidity change matches expected delta
     *      - Handles currency settlement (paying owed amounts) and claims (receiving owed amounts)
     *      - Returns both principal delta and fees accrued (which are treated differently downstream)
     *
     * @param key The pool key identifying the pool to modify
     * @param params Parameters for the liquidity modification (tick range, delta, salt)
     * @return delta The principal balance delta (callerDelta) - includes liquidity change plus immediate
     *               fee/hook deltas
     * @return feesAccrued Informational delta of fee growth in the modified range for this call
     *
     * Note: The pool manager must already be unlocked by the caller before calling this function.
     */
    function _modifyPositionLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        internal
        virtual
        returns (BalanceDelta delta, BalanceDelta feesAccrued)
    {
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
     *   1. Deposits: MMP -> Router -> MarketVault (via transferFrom)
     *   2. Notify MarketVault of liquidity changes (via modifyLiquidities)
     *   3. Withdrawals: MarketVault -> Router -> MMP (via transfer)
     *
     * @param poolId The pool ID associated with the position
     * @param settlementDelta The balance delta for underlying asset settlement. Positive means depositing to MV,
     *                        negative means withdrawing from MV to MMP
     * @param ua0 The address of underlying asset 0
     * @param ua1 The address of underlying asset 1
     */
    function _settleUnderlying(address sender, PoolId poolId, BalanceDelta settlementDelta, address ua0, address ua1)
        internal
        returns (BalanceDelta usedDelta)
    {
        address marketVault = _getVault(poolId);

        Currency currency0 = Currency.wrap(ua0);
        Currency currency1 = Currency.wrap(ua1);
        int128 amount0 = settlementDelta.amount0();
        int128 amount1 = settlementDelta.amount1();

        // Process deposits first (amount < 0), then notify vault, then process withdrawals (amount > 0)
        // This ensures the vault is funded before withdrawals
        if (amount0 < 0) {
            _settleUnderlyingCurrency(currency0, amount0, sender, marketVault);
        }
        if (amount1 < 0) {
            _settleUnderlyingCurrency(currency1, amount1, sender, marketVault);
        }

        // Notify the MarketVault (proxy hook) of the settled underlying tokens
        // A positive balance delta means withdrawing underlying tokens, negative balance means depositing underlying tokens,
        // Call after deposits (so MV is funded), but before withdrawals.
        // To prevent failure when liquidity in market is insufficient to cover the withdrawal, we tryModifyLiquidities and account LCCs for excess.
        // ---- eg. Failure on mass unwrap of LCCs, settled liquidity is used as coverage, then burn position.
        // ---- Basically, on decrease, return assets to the caller as LCCs in excess of usedDelta.
        BalanceDelta usedDelta =
            IMarketVault(marketVault).tryModifyLiquidities(LiquidityUtils.safeToBalanceDelta(amount0, amount1));

        if (usedDelta.amount0() > 0) {
            _settleUnderlyingCurrency(currency0, usedDelta.amount0(), sender, marketVault);
        }
        if (usedDelta.amount1() > 0) {
            _settleUnderlyingCurrency(currency1, usedDelta.amount1(), sender, marketVault);
        }

        return usedDelta;
    }

    /**
     * @notice Clamps the settlement delta by the available vault liquidities
     * @param poolId The pool ID associated with the position
     * @param settlementDelta The balance delta for underlying asset settlement. Positive means depositing to MV,
     *                        negative means withdrawing from MV to MMP
     * @return availableDelta The available balance delta that can be used for the settlement
     */
    function _clampDeltaByAvailableVaultLiquidities(PoolId poolId, BalanceDelta settlementDelta)
        internal
        returns (BalanceDelta)
    {
        address marketVault = _getVault(poolId);
        return IMarketVault(marketVault).dryModifyLiquidities(settlementDelta);
    }

    function _convertSettleUnderlyingToLcc(address sender, BalanceDelta settlementDelta, address lcc0, address lcc1)
        internal
        returns (BalanceDelta)
    {
        address ua0 = ILCC(lcc0).underlying();
        address ua1 = ILCC(lcc1).underlying();
        if (LiquidityUtils.isZeroDelta(settlementDelta)) {
            int256 uaDelta0 = Currency.wrap(ua0).getDelta(sender);
            int256 uaDelta1 = Currency.wrap(ua1).getDelta(sender);
            settlementDelta = toBalanceDelta(uaDelta0.toInt128(), uaDelta1.toInt128());
        }
        // Inverse the current delta of the underlying assets to the sender
        _accountDelta(Currency.wrap(ua0), -settlementDelta.amount0(), sender);
        _accountDelta(Currency.wrap(ua1), -settlementDelta.amount1(), sender);
        // Apply the deltas to LCCs
        _accountDelta(Currency.wrap(lcc0), settlementDelta.amount0(), sender);
        _accountDelta(Currency.wrap(lcc1), settlementDelta.amount1(), sender);
        return settlementDelta;
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
    function _settleUnderlyingCurrency(Currency currency, int128 amount, address sender, address marketVault) private {
        if (amount == 0) return;

        int256 delta = currency.getDelta(sender);
        int128 deltaToAccount = 0;

        if (amount < 0) {
            // Deposit: transfer FROM caller TO vault
            // If delta is negative (caller owes protocol) and amount < delta (deposit exceeds debt),
            // net the delta to zero. Otherwise, account the full amount.
            deltaToAccount += (delta < 0 && int256(amount) < delta) ? SafeCast.toInt128(-delta) : -amount;
            _accountDelta(currency, deltaToAccount, sender);
            currency.transferFrom(sender, marketVault, LiquidityUtils.safeInt128ToUint256(amount));
        } else {
            // Withdrawal: transfer FROM vault TO caller
            // If delta is positive (protocol owes caller) and amount > delta (withdrawal exceeds credit),
            // net the delta to zero. Otherwise, account the full amount.
            deltaToAccount = (delta > 0 && int256(amount) > delta) ? SafeCast.toInt128(-delta) : -amount;
            _accountDelta(currency, deltaToAccount, sender);
            currency.transfer(sender, LiquidityUtils.safeInt128ToUint256(amount));
        }
    }

    /**
     * @notice Accounts a delta for a currency and target address
     * @dev Increments or decrements the nonzero delta count based on the previous and next deltas
     * @param currency The currency to account the delta for
     * @param delta The delta to account
     * @param target The target address to account the delta for
     */
    function _accountDelta(Currency currency, int128 delta, address target) internal {
        (int256 previous, int256 next) = currency.applyDelta(target, delta);
        if (next == 0) {
            NonzeroDeltaCount.decrement();
        } else if (previous == 0) {
            NonzeroDeltaCount.increment();
        }
    }

    /**
     * @notice Accounts a settlement delta for a currency and target address
     * @dev Increments or decrements the nonzero delta count based on the previous and next deltas
     * @param sender The address initiating the settlement
     * @param settlementDelta The settlement delta to account
     * @param currency0 The first currency to account the delta for
     * @param currency1 The second currency to account the delta for
     */
    function _accountUnderlyingSettlementDelta(
        address sender,
        BalanceDelta settlementDelta,
        Currency currency0,
        Currency currency1
    ) internal {
        _accountDelta(_lccToUnderlyingCurrency(currency0), settlementDelta.amount0(), sender);
        _accountDelta(_lccToUnderlyingCurrency(currency1), settlementDelta.amount1(), sender);
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

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
import {Errors} from "./libraries/Errors.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {MarketHandler} from "./modules/MarketHandler.sol";
import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
import {IMarketVault} from "./interfaces/IMarketVault.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {CurrencyDelta} from "v4-periphery/lib/v4-core/src/libraries/CurrencyDelta.sol";
import {NonzeroDeltaCount} from "@uniswap/v4-core/src/libraries/NonzeroDeltaCount.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {TransientSlots} from "./libraries/TransientSlots.sol";
import {NativeWrapper} from "./modules/NativeWrapper.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {console} from "forge-std/console.sol";
import {MMLiquidityLib} from "./libraries/MMLiquidityLib.sol";
import {PositionId} from "./types/Position.sol";

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
contract NewLiquidityRouter is ImmutableState, MarketHandler, NativeWrapper {
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
     * @notice Constructs the LiquidityRouter
     * @param _poolManager Address of the PoolManager contract
     * @param _marketFactory Address of the MarketFactory contract
     * @param _weth9 Address of the WETH9 contract
     */
    constructor(address _poolManager, address _marketFactory, IWETH9 _weth9) ImmutableState(IPoolManager(_poolManager)) MarketHandler(_marketFactory) NativeWrapper(_weth9) {}

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
        public
        virtual
        returns (BalanceDelta delta, BalanceDelta feesAccrued)
    {
        (delta, feesAccrued) = MMLiquidityLib._modifyPositionLiquidity(poolManager, key, params, hookData);
    }

    /**
     * @notice Primes persistent underlying credits from MMP-held balances
     * @dev Loads min(persistent credit for sender, MMP contract balance) as positive delta to sender (credit)
     *      representing deduction from address(this) to sender (flash accounting)
     * @param sender The address to prime credits for
     * @param lccCurrency The LCC currency to prime credits for
     */
    function _primeUnderlyingDelta(address sender, Currency lccCurrency) public {
        MMLiquidityLib._primeUnderlyingDelta(_persistentUnderlyingCredits, lccCurrency, sender);
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
    ) public returns (BalanceDelta usedDelta) {
        usedDelta = MMLiquidityLib._settleUnderlyingDelta(
            marketFactory, sender, poolId, settlementDelta, lccCurrency0, lccCurrency1
        );
    }

    /**
     * @notice Gets the underlying settlement delta for a sender
     * @param sender The address initiating the settlement
     * @param lccCurrency0 The first LCC currency
     * @param lccCurrency1 The second LCC currency
     * @return settlementDelta The settlement delta for the sender
     */
    function _getUnderlyingSettlementDelta(address sender, Currency lccCurrency0, Currency lccCurrency1)
        public
        view
        returns (BalanceDelta)
    {
        return MMLiquidityLib._getUnderlyingSettlementDelta(sender, lccCurrency0, lccCurrency1);
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
    ) public {
        MMLiquidityLib._persistUnderlyingDelta(
            _persistentUnderlyingCredits, sender, settlementDelta, lccCurrency0, lccCurrency1
        );
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
        MMLiquidityLib._settleUnderlyingCurrencyWithVault(currency, amount, sender, marketVault);
    }

    /**
     * @notice Accounts a delta for a currency and target address
     * @dev Increments or decrements the nonzero delta count based on the previous and next deltas
     * @param currency The currency to account the delta for
     * @param delta The delta to account
     * @param target The target address to account the delta for
     */
    function _accountDelta(Currency currency, int128 delta, address target) public {
        MMLiquidityLib._accountDelta(currency, delta, target);
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
    ) public {
        MMLiquidityLib._accountUnderlyingSettlementDeltaChange(sender, targetSettlementDelta, currency0, currency1);
    }

    /**
     * @notice Takes up to maxAmount from MMP's balance of currency to 'to', capping to caller's positive delta
     * @dev Takes min(caller's positive delta, maxAmount) from MMP's balance and nets the delta
     * @param currency The currency to take
     * @param sender The address initiating the take
     * @param to The recipient address
     * @param maxAmount The maximum amount to take (use type(uint256).max for full available)
     */
    function _take(Currency currency, address sender, address to, uint256 maxAmount) public {
        MMLiquidityLib._take(currency, sender, to, maxAmount);
    }

    /**
     * @notice Gets the full positive delta (credit) for a currency and target address
     * @param currency The currency to check
     * @param target The target address to check delta for
     * @return The positive delta amount, or 0 if delta is not positive
     */
    function _getFullCredit(Currency currency, address target) public view returns (uint256) {
        return MMLiquidityLib._getFullCredit(currency, target);
    }

    /**
     * @notice Converts an LCC currency to its underlying currency
     * @param lccCurrency The LCC currency to convert
     * @return The underlying currency
     */
    function _lccToUnderlyingCurrency(Currency lccCurrency) internal view returns (Currency) {
        return MMLiquidityLib._lccToUnderlyingCurrency(lccCurrency);
    }

    /**
     * @notice Handles the native value for a sender
     * @dev Reads from cache to determine if native msg.value has been factored into currencyDelta.
     * @dev This is essentially a "credit full amount once, debit as needed" pattern.
     * @param sender The address initiating the settlement
     */
    function _handleNativeValue(address sender) public {
        return MMLiquidityLib._handleNativeValue(sender);
    }

    /**
     * @notice Wraps native assets into WETH
     * @dev Wraps native assets into WETH into this contract
     * @param sender The address initiating the wrap
     * @param amount The amount of native assets to wrap
     */
    function _wrapNative(address sender, uint256 amount) public {
        uint256 wrapAmt = MMLiquidityLib._wrapNative(address(WETH9), sender, amount);
        if (wrapAmt > 0) {
            _wrap(wrapAmt); // deposit ETH to WETH into this contract
        }
    }

    /**
     * @notice Unwraps WETH into native assets
     * @dev Unwraps WETH into native assets from this contract
     * @param sender The address initiating the unwrap
     * @param amount The amount of WETH to unwrap
     */
    function _unwrapNative(address sender, uint256 amount) public {
        uint256 unwrapAmt = MMLiquidityLib._unwrapNative(address(WETH9), sender, amount);
        if (unwrapAmt > 0) {
            _unwrap(unwrapAmt); // withdraw WETH to ETH into this contract
        }
    }
}

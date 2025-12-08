// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
import {Errors} from "../libraries/Errors.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {ImmutableVTSState} from "./ImmutableVTSState.sol";
import {CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {TransientSlots} from "../libraries/TransientSlots.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";

/**
 * @title PositionManagerBase
 * @notice Abstract contract that handles liquidity modifications with Uniswap V4 PoolManager.
 * @dev This contract provides a single function to modify liquidity and settle in one call.
 *      The flow is:
 *      1. Call poolManager.modifyLiquidity (triggers CoreHook -> VTSOrchestrator)
 *      2. Immediately settle/take tokens with the PoolManager
 *
 *      VTSOrchestrator.touchAndProcessPosition handles all delta management:
 *      - Fee accounting
 *      - LCC issuance/cancellation
 *      - Position linking
 *      - Settlement delta accounting
 *
 *      This contract expects `poolManager` to be provided by the inheriting contract
 *      (e.g., via BaseActionsRouter or ImmutableState).
 */
abstract contract PositionManagerBase is ImmutableState, ImmutableVTSState {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    constructor(address _vtsOrchestrator) ImmutableVTSState(_vtsOrchestrator) {}

    /// @dev This function is used to check if the batch is ended and assert that there are no zero deltas
    modifier assertNonZeroDeltas() {
        _;
        vtsOrchestrator.assertNonZeroDeltas();
    }

    // ------------------------------------------------------------------------------------------------
    // ABSTRACT FUNCTIONS (must be implemented by inheriting contracts)
    // ------------------------------------------------------------------------------------------------

    /// @notice Returns the locker address (original caller of the batch)
    /// @dev Must be implemented by inheriting contracts (e.g., via BaseActionsRouter._getLocker())
    function msgSender() public view virtual returns (address);

    /// @notice Returns the LiquidityHub contract
    /// @dev Must be implemented by inheriting contracts
    function _liquidityHub() internal view virtual returns (ILiquidityHub);

    // ------------------------------------------------------------------------------------------------
    // CURRENCY TYPE DETECTION
    // ------------------------------------------------------------------------------------------------

    /// @notice Checks if a currency is an LCC token
    /// @param currency The currency to check
    /// @return True if the currency is a valid LCC token
    function _isLCC(Currency currency) internal view returns (bool) {
        address token = Currency.unwrap(currency);
        if (token == address(0)) return false;
        return _liquidityHub().isLCC(token);
    }

    /**
     * @dev Internal helper to convert LCC currency to underlying currency
     */
    function _lccToUnderlyingCurrency(Currency lcc) internal view returns (Currency) {
        return Currency.wrap(ILCC(Currency.unwrap(lcc)).underlying());
    }

    // ------------------------------------------------------------------------------------------------
    // CREDIT HELPERS
    // ------------------------------------------------------------------------------------------------

    /**
     * @dev Internal helper to get full credit from VTSOrchestrator
     */
    function _getFullCredit(Currency currency, address owner) internal view returns (uint256) {
        return vtsOrchestrator.getFullCredit(currency, owner);
    }

    /**
     * @dev Internal helper to get full credit from VTSOrchestrator
     */
    function _getFullCreditPair(Currency currency0, Currency currency1, address owner)
        internal
        view
        returns (uint256, uint256)
    {
        return vtsOrchestrator.getFullCreditPair(currency0, currency1, owner);
    }

    /**
     * @dev This function is used to get the liquidity (L) from deltas of underlying currencies. ie. how much to mint/increase from what is owed.
     * @param poolKey The pool key for the position
     * @param tickLower The lower tick of the position
     * @param tickUpper The upper tick of the position
     * @return liquidity The liquidity from deltas
     */
    function _getLiquidityFromDeltas(PoolKey memory poolKey, address owner, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 liquidity)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        (uint256 credit0, uint256 credit1) = _getFullCreditPair(
            _lccToUnderlyingCurrency(poolKey.currency0), _lccToUnderlyingCurrency(poolKey.currency1), owner
        );
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            credit0,
            credit1
        );
    }

    // ------------------------------------------------------------------------------------------------
    // Balance-to-Delta Sync Helpers
    // ------------------------------------------------------------------------------------------------

    /**
     * @notice Syncs balance to delta for a single currency
     * @dev Syncs to locker delta (msgSender), not MMPM. This ensures balance syncs
     *      from wrap/unwrap operations create takeable credits on the locker.
     * @param currency The currency to sync balance for
     */
    function _syncBalanceToDeltas(Currency currency) internal {
        vtsOrchestrator.syncFor(currency, msgSender());
    }

    /**
     * @notice Syncs balance to delta for a currency pair
     * @dev Syncs to locker delta (msgSender), not MMPM.
     * @param currency0 The first currency to sync
     * @param currency1 The second currency to sync
     */
    function _syncPairBalanceToDeltas(Currency currency0, Currency currency1) internal {
        vtsOrchestrator.syncPairFor(currency0, currency1, msgSender());
    }

    // ------------------------------------------------------------------------------------------------
    // Liquidity Flow/Modification Handlers
    // ------------------------------------------------------------------------------------------------

    /**
     * @notice Modifies liquidity in a Uniswap V4 pool and immediately settles the deltas
     * @dev This function:
     *      1. Reads liquidity state before modification
     *      2. Calls poolManager.modifyLiquidity (triggers CoreHook -> VTSOrchestrator.touchAndProcessPosition)
     *      3. Reads resulting deltas
     *      4. Settles/takes tokens with PoolManager
     *
     *      All delta management (fees, LCCs, settlement accounting) is handled by VTSOrchestrator
     *      via the hook callback, so this function only needs to handle the PoolManager settlement.
     *
     * @param key The pool key identifying the pool to modify
     * @param params Parameters for the liquidity modification (tick range, delta, salt)
     * @param hookData Arbitrary data to pass to hooks (contains PositionModificationHookData)
     * @return callerDelta The principal balance delta - includes liquidity change plus immediate fee/hook deltas
     * @return feesAccrued Informational delta of fee growth in the modified range for this call
     */
    function _modifySyntheticLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        internal
        virtual
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        address self = address(this);

        // Get liquidity state before modification for validation
        (uint128 liquidityBefore,,) =
            poolManager.getPositionInfo(key.toId(), self, params.tickLower, params.tickUpper, params.salt);

        // PoolManager returns two deltas:
        // - callerDelta: principal liquidity change plus any immediate fee/hook deltas applied to the caller
        // - feesAccrued: informational delta of fee growth in the modified range for this call
        // This call triggers CoreHook -> VTSOrchestrator.processPosition which handles all delta management
        (callerDelta, feesAccrued) = poolManager.modifyLiquidity(key, params, hookData);

        // Get liquidity state after modification for validation
        (uint128 liquidityAfter,,) =
            poolManager.getPositionInfo(key.toId(), self, params.tickLower, params.tickUpper, params.salt);

        // Validate that liquidity change matches expected delta
        if (int128(liquidityBefore) + params.liquidityDelta != int128(liquidityAfter)) {
            revert Errors.InvariantViolated("liquidity change incorrect");
        }

        // Use callerDelta directly for settlement - this is exactly what PoolManager applied to our
        // transient storage via _accountPoolBalanceDelta(key, callerDelta, msg.sender) in modifyLiquidity.
        // The callerDelta includes: principalDelta + feesAccrued, adjusted by any hookDelta returned.
        int128 delta0 = callerDelta.amount0();
        int128 delta1 = callerDelta.amount1();

        // Settle negative deltas: pay tokens owed to PoolManager (LP is depositing)
        if (delta0 < 0) {
            key.currency0.settle(poolManager, self, uint256(uint128(-delta0)), false);
        }
        if (delta1 < 0) {
            key.currency1.settle(poolManager, self, uint256(uint128(-delta1)), false);
        }

        // Take positive deltas: receive tokens owed from PoolManager (LP is withdrawing)
        if (delta0 > 0) {
            key.currency0.take(poolManager, self, uint256(uint128(delta0)), false);
        }
        if (delta1 > 0) {
            key.currency1.take(poolManager, self, uint256(uint128(delta1)), false);
        }
    }

    /// @notice Takes currency from delta and transfers to recipient
    /// @dev Split model by currency type:
    ///      - LCC: Delta on MMPM, held as ERC-6909 claims on PoolManager
    ///             Flow: burn claims -> take actual ERC20 -> debit MMPM delta
    ///      - Underlying: Delta on locker, held as ERC20 by MMPM
    ///             Flow: debit locker delta -> direct ERC20 transfer
    /// @param currency The currency to take
    /// @param to The recipient address
    /// @param maxAmount The maximum amount to take (0 = take full available credit)
    function _take(Currency currency, address to, uint256 maxAmount) internal {
        if (_isLCC(currency)) {
            // LCC: held as ERC-6909 claims on PoolManager, delta on MMPM
            uint256 credit = _getFullCredit(currency, address(this));
            uint256 takeAmount = maxAmount == 0 ? credit : Math.min(credit, maxAmount);

            if (takeAmount > 0) {
                // 1. Burn ERC-6909 claims (releases LCC from PoolManager custody)
                currency.settle(poolManager, address(this), takeAmount, true);

                // 2. Take actual ERC20 LCC tokens from PoolManager
                currency.take(poolManager, to, takeAmount, false);

                // 3. Debit MMPM delta
                vtsOrchestrator.take(currency, address(this), takeAmount);
            }
        } else {
            // Underlying: held as ERC20 by MMPM, delta on locker
            address locker = msgSender();
            uint256 trueMaxAmount = Math.min(maxAmount, currency.balanceOfSelf());
            uint256 takeAmount = vtsOrchestrator.take(currency, locker, trueMaxAmount);

            if (to != address(this)) {
                currency.transfer(to, takeAmount);
            }
        }
    }
}


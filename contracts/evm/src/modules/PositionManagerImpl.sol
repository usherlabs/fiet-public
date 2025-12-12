// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
import {Errors} from "../libraries/Errors.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {LiquidityUtils} from "../libraries/LiquidityUtils.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {PositionManagerBase} from "./PositionManagerBase.sol";

/**
 * @title PositionManagerImpl
 * @notice Base contract providing implementation-specific functionality
 * @dev Contains functions used only by MMPositionActionsImpl
 * @dev Inherits ImmutableState to access poolManager
 */
abstract contract PositionManagerImpl is PositionManagerBase, ImmutableState {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    constructor(IPoolManager _poolManager, address _vtsOrchestrator)
        ImmutableState(_poolManager)
        PositionManagerBase(_vtsOrchestrator)
    {}

    // ------------------------------------------------------------------------------------------------
    // CREDIT HELPERS
    // ------------------------------------------------------------------------------------------------

    /// @notice Gets full credit for a single currency from VTSOrchestrator
    /// @param currency The currency to get credit for
    /// @param owner The owner address
    /// @return The full credit amount
    function _getFullCredit(Currency currency, address owner) internal view returns (uint256) {
        return vtsOrchestrator.getFullCredit(currency, owner);
    }

    /// @notice Gets full credit pair from VTSOrchestrator
    /// @param currency0 The first currency
    /// @param currency1 The second currency
    /// @param owner The owner address
    /// @return credit0 The credit for currency0
    /// @return credit1 The credit for currency1
    function _getFullCreditPair(Currency currency0, Currency currency1, address owner)
        internal
        view
        returns (uint256, uint256)
    {
        return vtsOrchestrator.getFullCreditPair(currency0, currency1, owner);
    }

    /// @notice Gets liquidity from deltas of underlying currencies
    /// @dev Calculates how much liquidity to mint/increase from what is owed
    /// @param poolKey The pool key for the position
    /// @param owner The owner address
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @return liquidity The liquidity from deltas
    function _getLiquidityFromDeltas(PoolKey memory poolKey, address owner, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 liquidity, uint256 credit0, uint256 credit1)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        (credit0, credit1) = _getFullCreditPair(
            _lccToUnderlyingCurrency(poolKey.currency0), _lccToUnderlyingCurrency(poolKey.currency1), owner
        );
        if (credit0 == 0 && credit1 == 0) {
            revert Errors.InvalidDelta(0, 0);
        }
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
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

    /// @notice Syncs balance accumulation as credit for a currency pair
    /// @dev Only handles balance increases (accumulation), not decreases (consumption).
    ///      Syncs to locker delta (msgSender), not MMPM.
    /// @param currency0 The first currency to sync
    /// @param currency1 The second currency to sync
    function _syncPairBalanceToDeltas(Currency currency0, Currency currency1) internal {
        vtsOrchestrator.syncPairFor(currency0, currency1, msgSender());
    }

    // ------------------------------------------------------------------------------------------------
    // Liquidity Flow/Modification Handlers
    // ------------------------------------------------------------------------------------------------

    /// @notice Modifies liquidity in a Uniswap V4 pool and immediately settles the deltas
    /// @dev This function:
    ///      1. Reads liquidity state before modification
    ///      2. Calls poolManager.modifyLiquidity (triggers CoreHook -> VTSOrchestrator.touchAndProcessPosition)
    ///      3. Reads resulting deltas
    ///      4. Settles/takes tokens with PoolManager
    ///
    ///      All delta management (fees, LCCs, settlement accounting) is handled by VTSOrchestrator
    ///      via the hook callback, so this function only needs to handle the PoolManager settlement.
    /// @param key The pool key identifying the pool to modify
    /// @param params Parameters for the liquidity modification (tick range, delta, salt)
    /// @param hookData Arbitrary data to pass to hooks (contains PositionModificationHookData)
    /// @return callerDelta The principal balance delta - includes liquidity change plus immediate fee/hook deltas
    /// @return feesAccrued Informational delta of fee growth in the modified range for this call
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
            key.currency0.settle(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta0), false);
        }
        if (delta1 < 0) {
            key.currency1.settle(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta1), false);
        }

        // Take positive deltas: receive tokens owed from PoolManager (LP is withdrawing)
        if (delta0 > 0) {
            key.currency0.take(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta0), false);
        }
        if (delta1 > 0) {
            key.currency1.take(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta1), false);
        }
    }
}


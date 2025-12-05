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

/**
 * @title PositionManagerLiquidity
 * @notice Abstract contract that handles liquidity modifications with Uniswap V4 PoolManager.
 * @dev This contract separates the concerns of:
 *      1. Calling poolManager.modifyLiquidity and computing deltas
 *      2. Settling/taking tokens with the PoolManager
 *
 *      Inheriting contracts can call _modifyPositionLiquidity to get deltas,
 *      then perform intermediate operations (like LCC issuance), and finally
 *      call _settleModifiedLiquidities to complete the settlement.
 *
 *      This contract expects `poolManager` to be provided by the inheriting contract
 *      (e.g., via BaseActionsRouter or ImmutableState).
 */
abstract contract PositionManagerLiquidity is ImmutableState {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    /**
     * @notice Modifies liquidity in a Uniswap V4 pool and returns the deltas
     * @dev This function ONLY calls poolManager.modifyLiquidity and reads the resulting deltas.
     *      It does NOT settle or take tokens - that must be done separately via _settleModifiedLiquidities.
     *
     *      Flow:
     *      1. Read liquidity state before modification
     *      2. Call poolManager.modifyLiquidity
     *      3. Read liquidity state after and validate
     *      4. Return deltas for caller to process
     *
     * @param key The pool key identifying the pool to modify
     * @param params Parameters for the liquidity modification (tick range, delta, salt)
     * @param hookData Arbitrary data to pass to hooks
     * @return callerDelta The principal balance delta - includes liquidity change plus immediate fee/hook deltas
     * @return feesAccrued Informational delta of fee growth in the modified range for this call
     * @return currencyDelta The net currency delta from PoolManager perspective (BalanceDelta)
     */
    function _modifyPositionLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        internal
        virtual
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued, BalanceDelta currencyDelta)
    {
        address self = address(this);

        // Get liquidity state before modification for validation
        (uint128 liquidityBefore,,) =
            poolManager.getPositionInfo(key.toId(), self, params.tickLower, params.tickUpper, params.salt);

        // PoolManager returns two deltas:
        // - callerDelta: principal liquidity change plus any immediate fee/hook deltas applied to the caller
        // - feesAccrued: informational delta of fee growth in the modified range for this call
        (callerDelta, feesAccrued) = poolManager.modifyLiquidity(key, params, hookData);

        // Get liquidity state after modification for validation
        (uint128 liquidityAfter,,) =
            poolManager.getPositionInfo(key.toId(), self, params.tickLower, params.tickUpper, params.salt);

        // Get net currency deltas from PoolManager
        // currencyDelta is a net including fee accrual plus any hook-side fee-sharing that's already
        // been applied at modification time.
        //
        // Note: Prior actions in a batch don't accumulate here because each _modifyLiquidity call
        // immediately settles its deltas, resetting currencyDelta to 0 before the next
        // action. The delta read here reflects only the current modification's effect (including hook
        // adjustments like feeAdj from CoreHook). Other actions (e.g., SETTLE_POSITION) account deltas
        // to the hook contract, not to this contract, so they don't affect this currencyDelta.
        int256 delta0 = poolManager.currencyDelta(self, key.currency0);
        int256 delta1 = poolManager.currencyDelta(self, key.currency1);
        currencyDelta = toBalanceDelta(SafeCast.toInt128(delta0), SafeCast.toInt128(delta1));

        // Validate that liquidity change matches expected delta
        if (int128(liquidityBefore) + params.liquidityDelta != int128(liquidityAfter)) {
            revert Errors.InvariantViolated("liquidity change incorrect");
        }

        // Validate currency delta direction matches liquidity operation type
        if (params.liquidityDelta < 0) {
            // Removing liquidity: PoolManager owes tokens to the LP (positive delta)
            assert(currencyDelta.amount0() > 0 || currencyDelta.amount1() > 0);
            assert(!(currencyDelta.amount0() < 0 || currencyDelta.amount1() < 0));
        } else if (params.liquidityDelta > 0) {
            // Adding liquidity: LP owes tokens to PoolManager (negative delta)
            assert(currencyDelta.amount0() < 0 || currencyDelta.amount1() < 0);
            assert(!(currencyDelta.amount0() > 0 || currencyDelta.amount1() > 0));
        }
    }

    /**
     * @notice Settles the deltas from a liquidity modification with the PoolManager
     * @dev This function handles the actual token transfers:
     *      - Negative deltas: LP owes tokens to PoolManager (settle/pay)
     *      - Positive deltas: PoolManager owes tokens to LP (take/receive)
     *
     *      This should be called AFTER any intermediate operations (like LCC issuance)
     *      that need to happen between computing deltas and settling.
     *
     * @param key The pool key (for currency references)
     * @param currencyDelta The currency delta to settle (negative = pay, positive = receive)
     */
    function _settleModifiedLiquidities(PoolKey memory key, BalanceDelta currencyDelta) internal virtual {
        address self = address(this);
        int128 delta0 = currencyDelta.amount0();
        int128 delta1 = currencyDelta.amount1();

        // Settle negative deltas: pay tokens owed to PoolManager (LP is depositing)
        if (delta0 < 0) {
            key.currency0.settle(poolManager, self, uint256(-int256(delta0)), false);
        }
        if (delta1 < 0) {
            key.currency1.settle(poolManager, self, uint256(-int256(delta1)), false);
        }

        // Take positive deltas: receive tokens owed from PoolManager (LP is withdrawing)
        if (delta0 > 0) {
            key.currency0.take(poolManager, self, uint256(int256(delta0)), false);
        }
        if (delta1 > 0) {
            key.currency1.take(poolManager, self, uint256(int256(delta1)), false);
        }
    }
}


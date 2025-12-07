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

/**
 * @title PositionManagerLiquidity
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
abstract contract PositionManagerLiquidity is ImmutableState, ImmutableVTSState {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    constructor(address _vtsOrchestrator) ImmutableVTSState(_vtsOrchestrator) {}

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

    function _take(Currency currency, address sender, address to, uint256 maxAmount) internal {
        uint256 amountTaken = vtsOrchestrator.take(currency, sender, to, maxAmount);
        // Transfer the amount from contract's balance to 'to'
        currency.transfer(to, amountTaken);
    }
}


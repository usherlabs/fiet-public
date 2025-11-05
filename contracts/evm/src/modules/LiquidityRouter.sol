// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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
 *   MMPositionManager (MMP) <-> LiquidityRouter <-> PoolManager (PM) / MarketVault (MV)
 *
 *   - For liquidity modifications: MMP -> Router -> PM (via _modifyLiquidity)
 *   - For underlying settlement: MMP <-> Router <-> MV (via _settleUnderlying)
 *
 * Note: This contract is inherited by MMPositionManager, which provides the concrete implementation
 *       including the msgSender() override to identify the caller.
 */

import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
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

// * Used by MM Position Manager to modify liquidity and settle underlying assets
abstract contract LiquidityRouter is ImmutableState, MarketHandler {
    using CurrencySettler for Currency;
    using CurrencyTransfer for Currency;
    using CurrencyLibrary for Currency;
    using Hooks for IHooks;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /**
     * @notice Constructs the LiquidityRouter
     * @param _marketFactory Address of the MarketFactory contract
     */
    constructor(address _marketFactory) MarketHandler(_marketFactory) {}

    /**
     * @notice Returns the address that should be treated as the caller for liquidity operations
     * @dev Must be overridden by the inheriting contract to return the appropriate sender
     *      (e.g., MMPositionManager returns the actual caller, not the contract itself)
     * @return The address to use as the sender for transfers and operations
     */
    function msgSender() public view virtual returns (address);

    /**
     * @notice Modifies liquidity in a Uniswap V4 pool via the PoolManager
     * @dev This function bridges liquidity modifications from MMPositionManager to the PoolManager:
     *      - Calls PoolManager.modifyLiquidity() to add or remove liquidity
     *      - Validates the liquidity change matches expected delta
     *      - Handles currency settlement (paying owed amounts) and claims (receiving owed amounts)
     *      - Returns both principal delta and fees accrued (which are treated differently downstream)
     *
     * @param key The pool key identifying the pool to modify
     * @param params Parameters for the liquidity modification (tick range, delta, salt)
     * @param hookData Additional data to pass to pool hooks
     * @return delta The principal balance delta (callerDelta) - includes liquidity change plus immediate
     *               fee/hook deltas
     * @return feesAccrued Informational delta of fee growth in the modified range for this call
     *
     * Note: The pool manager must already be unlocked by the caller before calling this function.
     */
    function _modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        internal
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
        // TODO: this doesn't consider prior actions relative caller, that could cause the
        // currencyDelta > modifyLiquidity[tokenIndex]
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

        // Note: Dust guard for native ETH is commented out
        // If needed, forward any stray native ETH held by the router (e.g. native-currency pools,
        // or flows that momentarily leave ETH on the router) back to the logical caller at the end of the action.
        // If you keep it, send to your router's logical caller (your msgSender() override), not raw msg.sender.
        // uint256 nativeBalance = address(this).balance;
        // if (nativeBalance > 0) {
        //     CurrencyLibrary.ADDRESS_ZERO.transfer(msgSender(), nativeBalance);
        // }
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
    function _settleUnderlying(PoolId poolId, BalanceDelta settlementDelta, address ua0, address ua1) internal {
        address sender = msgSender();
        address marketVault = _getVault(poolId);

        // For deposits: transfer underlying tokens from MMP to MarketVault (proxy hook)
        if (settlementDelta.amount0() > 0) {
            Currency.wrap(ua0)
                .transferFrom(sender, marketVault, LiquidityUtils.safeInt128ToUint256(settlementDelta.amount0()));
        }
        if (settlementDelta.amount1() > 0) {
            Currency.wrap(ua1)
                .transferFrom(sender, marketVault, LiquidityUtils.safeInt128ToUint256(settlementDelta.amount1()));
        }

        // Notify the proxy hook (MarketVault) of the settled underlying tokens
        // A positive balance delta means settling underlying tokens to the proxy hook,
        // negative means withdrawing to the MMP.
        // Call after deposits, but before withdrawals.
        IMarketVault(marketVault).modifyLiquidities(settlementDelta);

        // For withdrawals: transfer underlying tokens from MarketVault to MMP (caller/sender)
        if (settlementDelta.amount0() < 0) {
            Currency.wrap(ua0).transfer(sender, LiquidityUtils.safeInt128ToUint256(settlementDelta.amount0()));
        }
        if (settlementDelta.amount1() < 0) {
            Currency.wrap(ua1).transfer(sender, LiquidityUtils.safeInt128ToUint256(settlementDelta.amount1()));
        }
    }
}

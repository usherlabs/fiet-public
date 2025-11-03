// SPDX-License-Identifier: MIT
// This contract is inherited by the Market Maker position manager contract which acts as a liquidity router for the market maker positions
pragma solidity ^0.8.0;

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
import {IImmutableState} from "v4-periphery/src/interfaces/IImmutableState.sol";
import {Errors} from "../libraries/Errors.sol";

abstract contract LiquidityRouter is IImmutableState {
    using CurrencySettler for Currency;
    using Hooks for IHooks;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function msgSender() public view virtual returns (address);

    function _pm() internal view returns (IPoolManager) {
        return IImmutableState(address(this)).poolManager();
    }

    /// unlock the pool manager and use the callback to modify the liquidity
    function _modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        internal
        returns (BalanceDelta delta, BalanceDelta feesAccrued)
    {
        IPoolManager poolManager = _pm();
        bool settleUsingBurn = false;
        bool takeClaims = false;

        // ? already unlocked in new action dispatcher MMP structure

        address self = address(this);

        (uint128 liquidityBefore,,) =
            poolManager.getPositionInfo(key.toId(), self, params.tickLower, params.tickUpper, params.salt);

        // PoolManager returns two deltas:
        // - delta (callerDelta): principal liquidity change plus any immediate fee/hook deltas applied to the caller
        // - feesAccrued: informational delta of fee growth in the modified range for this call
        // Downstream, MMPositionManager treats principal vs feesAccrued differently: principal maps to LCC issue/cancel, while
        // feesAccrued (originating from trader flows, wrapped into LCCs) must remain wrapped until explicitly unwrapped.
        (delta, feesAccrued) = poolManager.modifyLiquidity(key, params, hookData);

        (uint128 liquidityAfter,,) =
            poolManager.getPositionInfo(key.toId(), self, params.tickLower, params.tickUpper, params.salt);

        // currencyDelta is a net including fee accrual plus any hook-side fee-sharing that’s already been applied at modification time.
        // TODO: this doesn't consider prior actions relative caller, that could cause the currencyDelta > modifyLiquidity[tokenIndex]
        int256 delta0 = poolManager.currencyDelta(self, key.currency0);
        int256 delta1 = poolManager.currencyDelta(self, key.currency1);

        if (int128(liquidityBefore) + params.liquidityDelta != int128(liquidityAfter)) {
            revert Errors.InvariantViolated("liquidity change incorrect");
        }

        if (params.liquidityDelta < 0) {
            // If negative liquidity (removing liquidity), then delta is positive - PoolManager owes the LP.
            assert(delta0 > 0 || delta1 > 0);
            assert(!(delta0 < 0 || delta1 < 0));
        } else if (params.liquidityDelta > 0) {
            // If positive liquidity (adding liquidity), then delta is negative - LP owes the PoolManager.
            assert(delta0 < 0 || delta1 < 0);
            assert(!(delta0 > 0 || delta1 > 0));
        }

        if (delta0 < 0) {
            key.currency0.settle(poolManager, self, uint256(-delta0), settleUsingBurn);
        }
        if (delta1 < 0) {
            key.currency1.settle(poolManager, self, uint256(-delta1), settleUsingBurn);
        }
        if (delta0 > 0) {
            key.currency0.take(poolManager, self, uint256(delta0), takeClaims);
        }
        if (delta1 > 0) {
            key.currency1.take(poolManager, self, uint256(delta1), takeClaims);
        }

        // Dust guard
        // forward any stray native ETH held by the router (e.g. native-currency pools, or flows that momentarily leave ETH on the router) back to the logical caller at the end of the action.
        // If you keep it, send to your router’s logical caller (your msgSender() override), not raw msg.sender.
        uint256 nativeBalance = address(this).balance;
        if (nativeBalance > 0) {
            CurrencyLibrary.ADDRESS_ZERO.transfer(msgSender(), nativeBalance);
        }
    }
}

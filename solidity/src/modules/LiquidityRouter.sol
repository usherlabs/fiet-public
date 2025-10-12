// SPDX-License-Identifier: MIT
// This contract is inherited by the Market Maker position manager contract which acts as a liquidity router for the market maker positions
pragma solidity ^0.8.0;

import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {PoolTestBase} from "v4-periphery/lib/v4-core/src/test/PoolTestBase.sol";
import {IHooks} from "v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-periphery/lib/v4-core/src/libraries/LPFeeLibrary.sol";
import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {IUnlockCallback} from "v4-periphery/lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {ILCC} from "../interfaces/ILCC.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {MarketMaker} from "../libraries/MarketMaker.sol";
import {LiquiditySignal} from "../types/Position.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {FixedPoint96} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "v4-periphery/lib/v4-core/src/libraries/SqrtPriceMath.sol";
import {toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {LiquidityUtils} from "../libraries/LiquidityUtils.sol";

abstract contract LiquidityRouter is IUnlockCallback {
    using SafeCast for *;
    using CurrencySettler for Currency;
    using Hooks for IHooks;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    constructor(address _manager) {
        manager = IPoolManager(_manager);
    }

    struct CallbackData {
        address sender;
        PoolKey key;
        ModifyLiquidityParams params;
        bytes hookData;
        bool settleUsingBurn;
        bool takeClaims;
    }

    /// callback function to modify the liquidity of the pool after the pool manager is unlocked
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        address self = address(this);

        (uint128 liquidityBefore,,) = manager.getPositionInfo(
            data.key.toId(), self, data.params.tickLower, data.params.tickUpper, data.params.salt
        );

        (BalanceDelta delta,) = manager.modifyLiquidity(data.key, data.params, data.hookData);

        (uint128 liquidityAfter,,) = manager.getPositionInfo(
            data.key.toId(), self, data.params.tickLower, data.params.tickUpper, data.params.salt
        );

        (, int256 delta0) = _fetchBalances(data.key.currency0, self);
        (, int256 delta1) = _fetchBalances(data.key.currency1, self);

        require(
            int128(liquidityBefore) + data.params.liquidityDelta == int128(liquidityAfter), "liquidity change incorrect"
        );

        if (data.params.liquidityDelta < 0) {
            assert(delta0 > 0 || delta1 > 0);
            assert(!(delta0 < 0 || delta1 < 0));
        } else if (data.params.liquidityDelta > 0) {
            assert(delta0 < 0 || delta1 < 0);
            assert(!(delta0 > 0 || delta1 > 0));
        }

        if (delta0 < 0) {
            data.key.currency0.settle(manager, self, uint256(-delta0), data.settleUsingBurn);
        }
        if (delta1 < 0) {
            data.key.currency1.settle(manager, self, uint256(-delta1), data.settleUsingBurn);
        }
        if (delta0 > 0) {
            data.key.currency0.take(manager, self, uint256(delta0), data.takeClaims);
        }
        if (delta1 > 0) {
            data.key.currency1.take(manager, self, uint256(delta1), data.takeClaims);
        }

        return abi.encode(delta);
    }

    /// unlock the pool manager and use the callback to modify the liquidity
    function _modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        internal
        returns (BalanceDelta delta)
    {
        bool settleUsingBurn = false;
        bool takeClaims = false;

        delta = abi.decode(
            manager.unlock(abi.encode(CallbackData(msg.sender, key, params, hookData, settleUsingBurn, takeClaims))),
            (BalanceDelta)
        );
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, ethBalance);
        }
    }

    /// fetch the balances of the user and the pool
    function _fetchBalances(Currency currency, address deltaHolder)
        internal
        view
        returns (uint256 poolBalance, int256 delta)
    {
        poolBalance = currency.balanceOf(address(manager));
        delta = manager.currencyDelta(deltaHolder, currency);
    }
}

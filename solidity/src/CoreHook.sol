// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IHookCommon} from "./interfaces/IHookCommon.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";

import {ProxyHook} from "./ProxyHook.sol";
import {LiquidityCommitmentCertificate} from "./LCC.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {console} from "forge-std/console.sol";

/**
 * Core Pool should be aware of Positions.
 *     This way it can calculate and manage Liquidity Commitments (C_A(r)) for each Position.
 *     Furthermore, we need to know when Direct LP occurs, as this determines whether the underlying native tokens are settled to the Pool Manager.
 */
contract CoreHook is BaseHook, IHookCommon {
    using CurrencySettler for Currency;

    error InvalidInitialiser();
    error InvalidSender();

    address public immutable marketFactory;

    address public proxyHook;

    modifier onlyFactory() {
        if (msg.sender != marketFactory) {
            revert InvalidSender();
        }
        _;
    }

    // Owner will be set to MarketFactory
    constructor(
        address _poolManager,
        address _marketFactory
    ) BaseHook(IPoolManager(_poolManager)) {
        marketFactory = _marketFactory;
    }

    function activate() external onlyFactory {
        proxyHook = IMarketFactory(marketFactory).getProxyHook();
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true, // Validate and set global parameters
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: true, // Intercept liquidity modifications
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: true, // Intercept liquidity modifications
                beforeSwap: false,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function _beforeInitialize(
        address sender,
        PoolKey calldata,
        uint160
    ) internal view virtual override returns (bytes4) {
        if (sender != marketFactory) {
            revert InvalidInitialiser();
        }
        return this.beforeInitialize.selector;
    }

    // function _afterInitialize(address, PoolKey calldata key, uint160, bytes calldata)
    //     internal
    //     virtual
    //     override
    //     returns (bytes4)
    // {
    //     return this._afterInitialize.selector;
    // }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {
        ProxyHook(proxyHook).onDirectLP(
            key,
            delta,
            ActionType.DirectLPAddLiquidity
        );

        return (
            this.afterAddLiquidity.selector,
            BalanceDeltaLibrary.ZERO_DELTA
        );
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {
        ProxyHook(proxyHook).onDirectLP(
            key,
            delta,
            ActionType.DirectLPRemoveLiquidity
        );

        return (
            this.afterRemoveLiquidity.selector,
            BalanceDeltaLibrary.ZERO_DELTA
        );
    }
}

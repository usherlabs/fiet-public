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
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PausablePool} from "./libraries/PausablePool.sol";
import {ProxySwapFlag} from "./libraries/ProxySwapFlag.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {console} from "forge-std/console.sol";

/**
 * Core Pool should be aware of Positions.
 *     This way it can calculate and manage Liquidity Commitments (C_A(r)) for each Position.
 *     Furthermore, we need to know when Direct LP occurs, as this determines whether the underlying native tokens are settled to the Pool Manager.
 */
contract CoreHook is BaseHook, IHookCommon, PausablePool {
    using CurrencySettler for Currency;

    error InvalidInitialiser();
    error InvalidSender();

    address public immutable marketFactory;

    modifier onlyFactory() {
        if (msg.sender != marketFactory) {
            revert InvalidSender();
        }
        _;
    }

    // Owner will be set to MarketFactory
    constructor(address _poolManager, address _marketFactory) BaseHook(IPoolManager(_poolManager)) {
        marketFactory = _marketFactory;
    }

    function pause(PoolId poolId) external onlyFactory {
        _pause(poolId);
    }

    function unpause(PoolId poolId) external onlyFactory {
        _unpause(poolId);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // Validate and set global parameters
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true, // Intercept liquidity modifications
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true, // Intercept liquidity modifications
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address sender, PoolKey calldata, uint160)
        internal
        view
        virtual
        override
        returns (bytes4)
    {
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

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        internal
        virtual
        override
        whenNotPaused(key.toId())
        returns (bytes4, int128)
    {
        ProxyHook(_getProxyHook(key)).onCorePoolSwap(delta);

        return (this.afterSwap.selector, 0);
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal virtual override whenNotPaused(key.toId()) returns (bytes4, BalanceDelta) {
        // TODO: Filter the sender address to determine whether it's MMPositionManager or DirectLP.
        address proxyHook = _getProxyHook(key);

        ProxyHook(proxyHook).onDirectLP(key, delta, ActionType.DirectLPAddLiquidity);

        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {
        // Allow removal of liquidity even when the market is paused.
        // TODO: Filter the sender address to determine whether it's MMPositionManager or DirectLP.
        // TODO dynamically get proxyhook from market factory

        address proxyHook = _getProxyHook(key);
        ProxyHook(proxyHook).onDirectLP(key, delta, ActionType.DirectLPRemoveLiquidity);

        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // Helper function to get the proxy hook address from the core pool key
    function _getProxyHook(PoolKey calldata corePoolKey) internal view returns (address) {
        PoolId corePoolId = corePoolKey.toId();
        PoolId proxyPoolId = IMarketFactory(marketFactory).coreToProxy(corePoolId);

        return IMarketFactory(marketFactory).proxyToHook(proxyPoolId);
    }
}

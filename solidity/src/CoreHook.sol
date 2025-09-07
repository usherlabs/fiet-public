// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {ProxyHook} from "./ProxyHook.sol";
import {LiquidityCommitmentCertificate} from "./LCC.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PausablePool} from "./modules/PausablePool.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {Exttload} from "v4-periphery/lib/v4-core/src/Exttload.sol";
import {IExttload} from "v4-periphery/lib/v4-core/src/interfaces/IExttload.sol";
import {ProxySwapFlag} from "./libraries/ProxySwapFlag.sol";
import {TransientSlots} from "./libraries/TransientSlots.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
import {console} from "forge-std/console.sol";
import {VTSManager} from "./modules/VTSManager.sol";

/**
 * Core Pool should be aware of Positions.
 * This way it can calculate and manage Liquidity Commitments (C_A(r)) for each Position.
 * Furthermore, we need to know when Direct LP occurs, as this determines whether the underlying native tokens are settled to the Pool Manager.
 */
contract CoreHook is BaseHook, PausablePool, Exttload, VTSManager {
    using CurrencySettler for Currency;

    error InvalidInitialiser();
    error InvalidSender();

    address public immutable marketFactory;
    address public immutable mmPositionManager;

    modifier onlyFactory() {
        if (msg.sender != marketFactory) {
            revert InvalidSender();
        }
        _;
    }

    // Owner will be set to MarketFactory
    constructor(address _poolManager, address _marketFactory, address _mmPositionManager)
        BaseHook(IPoolManager(_poolManager))
        VTSManager(_marketFactory, _mmPositionManager)
    {
        marketFactory = _marketFactory;
        mmPositionManager = _mmPositionManager;
    }

    function getMMPositionManager() public view returns (address) {
        return IMarketFactory(marketFactory).mmPositionManager();
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
        address proxyHook = _getProxyHook(key);

        // Check if this is a direct core pool swap, and if it is, call the proxy hook
        if (IExttload(proxyHook).exttload(TransientSlots.PROXY_SWAP_FLAG_SLOT) == bytes32(0)) {
            ProxyHook(proxyHook).onCorePoolDirectSwap(delta);
        }

        _triggerInternalTracingFlag(key.toId());
        _recordOutflow(key.toId(), delta);
        return (this.afterSwap.selector, 0);
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal virtual override whenNotPaused(key.toId()) returns (bytes4, BalanceDelta) {
        // only add direct liquidity  if the sender is not the market maker position manager/router
        if (sender != address(mmPositionManager)) {
            address proxyHook = _getProxyHook(key);
            ProxyHook(proxyHook).onDirectLP(key, delta, LiquidityUtils.ActionType.DirectLPAddLiquidity);
        }

        if (sender == address(mmPositionManager)) {
            // Track maximum potemtial commitment for both tokens in the position
            _trackMaxPotentialCommitment(key, sender, params, delta);
        }

        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {
        // Allow removal of liquidity even when the market is paused.
        // only remove direct liquidity  if the sender is the pool manager
        if (sender != address(mmPositionManager)) {
            address proxyHook = _getProxyHook(key);
            ProxyHook(proxyHook).onDirectLP(key, delta, LiquidityUtils.ActionType.DirectLPRemoveLiquidity);
        }

        if (sender == address(mmPositionManager)) {
            // Track maximum potemtial commitment for both tokens in the position
            _trackMaxPotentialCommitment(key, sender, params, delta);
        }

        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // Helper function to get the proxy hook address from the core pool key
    function _getProxyHook(PoolKey calldata corePoolKey) internal view returns (address) {
        PoolId corePoolId = corePoolKey.toId();
        PoolId proxyPoolId = IMarketFactory(marketFactory).coreToProxy(corePoolId);

        return IMarketFactory(marketFactory).proxyToHook(proxyPoolId);
    }

    /**
     * @notice Trigger the internal tracing flags that would be read by lcc tokens
     * @dev This is used to indicate that a swap has occurred and the current market is the core pool
     * @dev In order to help the lcc track markets transfers came from
     * @param corePoolId The core pool id
     */
    function _triggerInternalTracingFlag(PoolId corePoolId) internal {
        // Trigger flag within the core hook to indicate that a swap has occurred
        // Set some variables that would be read by the corresponding recipient LCC contract
        bytes32 tracingFlagSlot = TransientSlots.TRACING_FLAG_SLOT;
        bytes32 currentMarketSlot = TransientSlots.CURRENT_MARKET_SLOT;
        // bytes32 swapDeltaSlot = TransientSlots.SWAP_DELTA_SLOT;

        assembly ("memory-safe") {
            tstore(tracingFlagSlot, 1) // true
            tstore(currentMarketSlot, corePoolId)
        }
    }
}

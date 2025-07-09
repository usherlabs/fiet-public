// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencyDelta} from "@uniswap/v4-core/src/libraries/CurrencyDelta.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {LiquidityCommitmentCertificate} from "./LCC.sol";
import {ProxyHook} from "./ProxyHook.sol";

import "forge-std/console.sol";

/**
 * Core Pool should be aware of Positions.
 *     This way it can calculate and manage Liquidity Commitments (C_A(r)) for each Position.
 *     Furthermore, we need to know when Direct LP occurs, as this determines whether the underlying native tokens are settled to the Pool Manager.
 */
contract CoreHook is BaseHook, Ownable {
    error InvalidUnderlyingAsset();
    error InvalidInitialiser();

    address public immutable marketFactory;
    PoolKey public corePoolKey;

    // Owner will be set to MarketFactory
    constructor(address _poolManager, address _marketFactory) BaseHook(IPoolManager(_poolManager)) {
        marketFactory = _marketFactory;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
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

    function _beforeInitialize(address sender, PoolKey calldata key, uint160)
        internal
        pure
        virtual
        override
        returns (bytes4)
    {
        if (sender != marketFactory) {
            revert InvalidInitialiser();
        }
        return this._beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        internal
        virtual
        override
        returns (bytes4)
    {
        // Store the core pool key
        corePoolKey = key;

        // TODO: Create the Proxy Pool...
        return this._afterInitialize.selector;
    }

    /**
     * @notice Returns the core pool key for use by ProxyHook
     * @return The core pool key
     */
    function getCorePoolKey() external view returns (PoolKey memory) {
        return corePoolKey;
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal pure virtual override returns (bytes4) {
        if (sender == address(poolManager)) {
            // Handle Direct LP
            // Notify the Proxy Hook to settle underlying tokens as liquidity to the Pool Manager.
        }

        return this._afterAddLiquidity.selector;
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal pure virtual override returns (bytes4) {
        return this._afterRemoveLiquidity.selector;
    }
}

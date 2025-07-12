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
        // Get LCC tokens from key
        LiquidityCommitmentCertificate lccToken0 = LiquidityCommitmentCertificate(
                Currency.unwrap(key.currency0)
            );
        LiquidityCommitmentCertificate lccToken1 = LiquidityCommitmentCertificate(
                Currency.unwrap(key.currency1)
            );

        // Get underlying currencies
        Currency uaCurrency0 = Currency.wrap(lccToken0.underlyingAsset());
        Currency uaCurrency1 = Currency.wrap(lccToken1.underlyingAsset());

        // Calculate absolute amounts from delta (assuming positive for add)
        uint256 amount0 = delta.amount0() > 0
            ? uint256(uint128(delta.amount0()))
            : uint256(uint128(-delta.amount0()));
        uint256 amount1 = delta.amount1() > 0
            ? uint256(uint128(delta.amount1()))
            : uint256(uint128(-delta.amount1()));

        // Add liquidity to the core pool

        // Settle `amount` of each currency from the sender
        // i.e. Create a debit of `amount` of each currency with the Pool Manager
        uaCurrency0.settle(
            IPoolManager(poolManager),
            address(lccToken0),
            amount0,
            false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
        );
        uaCurrency1.settle(
            IPoolManager(poolManager),
            address(lccToken1),
            amount1,
            false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
        );

        // Since we didn't go through the regular "modify liquidity" flow,
        // the PM just has a debit of `amount` of each currency from us
        // We can, in exchange, get back ERC-6909 claim tokens for `amount`
        // to create a credit of `amount` of each currency to us that balances out the debit

        // We will store those claim tokens with the hook, so when swaps take place
        // liquidity from our CSMM can be used by minting/burning claim tokens the hook owns
        uaCurrency0.take(
            IPoolManager(poolManager),
            proxyHook,
            amount0,
            true // `mint` = `true` i.e. we're minting claim tokens for the hook, equivalent to money we just deposited to the PM
        );
        uaCurrency1.take(
            IPoolManager(poolManager),
            proxyHook,
            amount1,
            true // `mint` = `true` i.e. we're minting claim tokens for the hook, equivalent to money we just deposited to the PM
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
        // Get LCC tokens from key
        LiquidityCommitmentCertificate lccToken0 = LiquidityCommitmentCertificate(
                Currency.unwrap(key.currency0)
            );
        LiquidityCommitmentCertificate lccToken1 = LiquidityCommitmentCertificate(
                Currency.unwrap(key.currency1)
            );

        // Get underlying currencies
        Currency uaCurrency0 = Currency.wrap(lccToken0.underlyingAsset());
        Currency uaCurrency1 = Currency.wrap(lccToken1.underlyingAsset());

        // Calculate absolute amounts from delta (assuming positive for add)
        uint256 amount0 = delta.amount0() > 0
            ? uint256(uint128(delta.amount0()))
            : uint256(uint128(-delta.amount0()));
        uint256 amount1 = delta.amount1() > 0
            ? uint256(uint128(delta.amount1()))
            : uint256(uint128(-delta.amount1()));

        // Remove liquidity from the core pool
        uaCurrency0.settle(
            IPoolManager(poolManager),
            proxyHook,
            amount0,
            true // `burn` = `true` i.e. we're  burning ERC-6909 Claim Tokens
        );
        uaCurrency1.settle(
            IPoolManager(poolManager),
            proxyHook,
            amount1,
            true // `burn` = `true` i.e. we're  burning ERC-6909 Claim Tokens
        );
        uaCurrency0.take(
            IPoolManager(poolManager),
            address(lccToken0), // Send native liquidity back to LCC
            amount0,
            false // mint` = `true` i.e. we're  claiming erc20
        );
        uaCurrency1.take(
            IPoolManager(poolManager),
            address(lccToken1),
            amount1,
            false // mint` = `true` i.e. we're  claiming erc20
        );

        return (
            this.afterRemoveLiquidity.selector,
            BalanceDeltaLibrary.ZERO_DELTA
        );
    }
}

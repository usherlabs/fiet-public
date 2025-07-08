// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CurrencyDelta} from "@uniswap/v4-core/src/libraries/CurrencyDelta.sol";
import {BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import "forge-std/console.sol";

import {IToken} from "./IToken.sol";

contract ProxyHook is BaseHook {
    using CurrencySettler for Currency;

    error AddLiquidityThroughHook();

    // router of the swap
    // v4 pool id
    event HookSwap(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
    );

    // v4 pool id
    // router address
    event HookModifyLiquidity(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1
    );

    // store pool identifiers for the core and proxy pool
    PoolKey corePoolKey;
    PoolKey proxyPoolKey;

    // Map of NATIVE => LCC.
    mapping(Currency => Currency) tokenMapping;

    constructor(
        IPoolManager poolManager,
        PoolKey memory _corePoolKey
    ) BaseHook(poolManager) {
        corePoolKey = _corePoolKey;

        // // ? Could have just saved uToken0 and uToken1 to storage, instead of a mapping of two.
        // // ? Mapping makes more sense if Proxy Hook Smart Contract allows many Proxy Pools => Core Pools.

        // This is currently just a map of NATIVE => LCC.
        Currency underlyingToken0 = Currency.wrap(
            IToken(Currency.unwrap(_corePoolKey.currency0)).underlyingAsset()
        );
        tokenMapping[underlyingToken0] = _corePoolKey.currency0;
        Currency underlyingToken1 = Currency.wrap(
            IToken(Currency.unwrap(_corePoolKey.currency1)).underlyingAsset()
        );
        tokenMapping[underlyingToken1] = _corePoolKey.currency1;

        // Assume lcc-ETH/lcc-USDC core pool has token1 as lcc-ETH, whereas proxypool has ETH as token0.
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true, // On initialization we shouls
                afterInitialize: false,
                beforeAddLiquidity: true, // Don't allow adding liquidity normally
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true, // Override how swaps are done
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true, // Allow beforeSwap to return a custom delta
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal virtual override returns (bytes4) {
        proxyPoolKey = key;
        return this.beforeInitialize.selector;
    }

    // Disable adding liquidity to the proxy pool
    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure virtual override returns (bytes4) {
        revert AddLiquidityThroughHook();
    }

    // Before swap we make sure to provide enough delta
    // to ensure that the user gets a debit of amount specified
    // and we disable the core swap mechanism
    // and proxy the swap through the core pool
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        {
            console.log("=== DIRECTIONAL SETTLEMENT DEBUG ===");
            console.log("zeroForOne:", params.zeroForOne);

            console.log(
                "Core pool: ",
                IERC20Metadata(Currency.unwrap(corePoolKey.currency0)).name(),
                IERC20Metadata(Currency.unwrap(corePoolKey.currency1)).name()
            );
            console.log(
                "Proxy pool: ",
                IERC20Metadata(Currency.unwrap(proxyPoolKey.currency0)).name(),
                IERC20Metadata(Currency.unwrap(proxyPoolKey.currency1)).name()
            );
        }

        // unwrap the output amount of the recieved token to get the underlying asset added to balance
        Currency coreOutputCurrency;
        Currency coreInputCurrency;
        Currency proxyInputCurrency;
        Currency proxyOutputCurrency;

        if (params.zeroForOne) {
            proxyInputCurrency = key.currency0;
            coreInputCurrency = tokenMapping[key.currency0];

            proxyOutputCurrency = key.currency1;
            coreOutputCurrency = tokenMapping[key.currency1];
        } else {
            proxyInputCurrency = key.currency1;
            coreInputCurrency = tokenMapping[key.currency1];

            proxyOutputCurrency = key.currency0;
            coreOutputCurrency = tokenMapping[key.currency0];
        }
        {
            console.log(
                "coreInputCurrency: ",
                IERC20Metadata(Currency.unwrap(coreInputCurrency)).name(),
                " to: ",
                IERC20Metadata(Currency.unwrap(coreOutputCurrency)).name()
            );
            console.log(
                "proxyInputCurrency: ",
                IERC20Metadata(Currency.unwrap(proxyInputCurrency)).name(),
                " to: ",
                IERC20Metadata(Currency.unwrap(proxyOutputCurrency)).name()
            );
        }
        console.log(" ");
        IToken iOutToken = IToken(Currency.unwrap(coreOutputCurrency));

        //iOutToken.checkForRFS(); // dead code

        address recipient = abi.decode(hookData, (address)); // TODO: Should not exist.

        /// The desired input amount if negative (exactIn), or the desired output amount if positive (exactOut)
        uint256 amountInOutPositive = params.amountSpecified > 0
            ? uint256(params.amountSpecified)
            : uint256(-params.amountSpecified);

        // disable swap mechanism

        // TODO: Really... the i/o on the contract should be determined by the i/o on the core pool.
        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(
            params.amountSpecified > 0
                ? int128(0)
                : int128(-params.amountSpecified),
            params.amountSpecified > 0
                ? int128(params.amountSpecified)
                : int128(0)
        );
        console.log("params.amountSpecified: ", params.amountSpecified);
        console.log(
            "beforeSwapDelta (specified): ",
            BeforeSwapDeltaLibrary.getSpecifiedDelta(beforeSwapDelta)
        );
        console.log(
            "beforeSwapDelta (unspecified): ",
            BeforeSwapDeltaLibrary.getUnspecifiedDelta(beforeSwapDelta)
        );
        console.log("amountInOutPositive: ", amountInOutPositive);
        // Update delta
        // poolManager is in negative delta and this hook is in positive in case zeroforone == true
        proxyInputCurrency.take(
            poolManager,
            address(this),
            amountInOutPositive,
            true
        );

        // poolManager is in negative delta and this hook is in positive in case zeroforone == true
        // wrap the provided token to use as input token or token specified
        // TODO: The parameters provided to the Core Pool might have a different zeroForOne than the Proxy Pool.
        (, uint256 outputAmount) = swapAndSettleBalances(
            corePoolKey,
            params,
            coreInputCurrency,
            coreOutputCurrency
        );

        // unwrap the response/provided token
        // approve the iToken to take amount to be unwrapped from the hook
        iOutToken.approve(address(iOutToken), outputAmount);

        // unwrap the tokens
        address underlyingAsset = iOutToken.underlyingAsset();
        IERC20(underlyingAsset).approve(address(iOutToken), outputAmount);
        // this essentially transfers the underlying asset from the hook to the recipient
        iOutToken.unwrap(recipient, outputAmount); // TODO: Should not exist.
        _handleProxySettlement(
            proxyInputCurrency,
            uint128(amountInOutPositive)
        );

        // TODO: We should be returning the delta produced by the swap.
        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }

    function _handleProxySettlement(
        Currency proxyInputCurrency,
        uint128 amountIn
    ) internal {
        _settle(proxyInputCurrency, amountIn);
    }

    // use this helper to perform a swap and settle operation on the core pool
    function swapAndSettleBalances(
        PoolKey memory key,
        SwapParams memory params,
        Currency coreInputCurrency,
        Currency coreOutputCurrency
    ) internal returns (BalanceDelta, uint256) {
        // Conduct the swap inside the Pool Manager
        BalanceDelta delta = poolManager.swap(key, params, bytes(""));
        uint256 outputAmount = 0;
        console.log("amount 0 delta: ", delta.amount0());
        console.log("amount 1 delta: ", delta.amount1());
        console.log(" ");
        // If we just did a zeroForOne swap
        // We need to send Token 0 to PM, and receive Token 1 from PM
        if (params.zeroForOne) {
            console.log("test 1");
            // Negative Value => Money leaving user's wallet
            // Promise Mint some tokens in order to settle with the pool manager
            // Settle with PoolManager
            if (delta.amount0() < 0) {
                // Minting lcc token - proxyPoolKey.currency0 to hook.
                IToken(Currency.unwrap(coreInputCurrency)).custodianMint(
                    uint256(int256(-delta.amount0()))
                );
                // We transfer above minted lcc tokens to PM.
                // Now PM has 10 lcc tokens
                _settle(coreInputCurrency, uint128(-delta.amount0()));
            }

            // Positive Value => Money coming into user's wallet
            // Take from PM
            if (delta.amount1() > 0) {
                _take(coreOutputCurrency, uint128(delta.amount1()));
                outputAmount = uint256(uint128(delta.amount1()));
            }
        } else {
            console.log("test 2");
            if (delta.amount1() < 0) {
                // Promise Mint some tokens in order to settle with the pool manager
                // Settle with PoolManager
                IToken(Currency.unwrap(corePoolKey.currency1)).custodianMint(
                    uint256(int256(-delta.amount1()))
                );
                _settle(key.currency1, uint128(-delta.amount1()));
            }

            if (delta.amount0() > 0) {
                _take(key.currency0, uint128(delta.amount0()));
                outputAmount = uint256(uint128(delta.amount0()));
            }
        }

        return (delta, outputAmount);
    }

    // Helper function to transfer and settle a debt with the pool manager
    function _settle(Currency currency, uint128 amount) internal {
        // Transfer tokens to PM and let it know
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    // helper function to help take a particular currency from the pool manager
    function _take(Currency currency, uint128 amount) internal {
        // Take tokens out of PM to our hook contract
        poolManager.take(currency, address(this), amount);
    }
}

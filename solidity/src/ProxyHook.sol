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
    event HookModifyLiquidity(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1);

    // As per https://github.com/Uniswap/v4-core/blob/main/src/libraries/TickMath.sol#L10
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    // store pool identifiers for the core and proxy pool
    PoolKey corePoolKey;
    PoolKey proxyPoolKey;

    // Map of NATIVE => LCC.
    mapping(Currency => Currency) tokenMapping;

    constructor(IPoolManager poolManager, PoolKey memory _corePoolKey) BaseHook(poolManager) {
        corePoolKey = _corePoolKey;

        // // ? Could have just saved uToken0 and uToken1 to storage, instead of a mapping of two.
        // // ? Mapping makes more sense if Proxy Hook Smart Contract allows many Proxy Pools => Core Pools.

        // This is currently just a map of NATIVE => LCC.
        Currency underlyingToken0 = Currency.wrap(IToken(Currency.unwrap(_corePoolKey.currency0)).underlyingAsset());
        tokenMapping[underlyingToken0] = _corePoolKey.currency0;
        Currency underlyingToken1 = Currency.wrap(IToken(Currency.unwrap(_corePoolKey.currency1)).underlyingAsset());
        tokenMapping[underlyingToken1] = _corePoolKey.currency1;

        // Assume lcc-ETH/lcc-USDC core pool has token1 as lcc-ETH, whereas proxypool has ETH as token0.
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
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

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
        proxyPoolKey = key;
        return this.beforeInitialize.selector;
    }

    // Disable adding liquidity to the proxy pool
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        virtual
        override
        returns (bytes4)
    {
        revert AddLiquidityThroughHook();
    }

    // Before swap we make sure to provide enough delta
    // to ensure that the user gets a debit of amount specified
    // and we disable the core swap mechanism
    // and proxy the swap through the core pool
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
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

        bool zeroForOne_core;

        // Establish native -> lcc mapping
        if (params.zeroForOne) {
            proxyInputCurrency = key.currency0;
            coreInputCurrency = tokenMapping[key.currency0];

            proxyOutputCurrency = key.currency1;
            coreOutputCurrency = tokenMapping[key.currency1];

            // Core Pool is zeroForOne if Proxy Pool is zeroForOne, AND Proxy token0 = Core token0
            zeroForOne_core = coreInputCurrency == corePoolKey.currency0;
        } else {
            proxyInputCurrency = key.currency1;
            coreInputCurrency = tokenMapping[key.currency1];

            proxyOutputCurrency = key.currency0;
            coreOutputCurrency = tokenMapping[key.currency0];

            // Core Pool is NOT zeroForOne if Proxy Pool is NOT zeroForOne, AND Proxy token1 = Core token1
            zeroForOne_core = coreInputCurrency == corePoolKey.currency1;
        }

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

        // BalanceDelta is a packed value of (currency0Amount, currency1Amount)

        // BeforeSwapDelta varies such that it is not sorted by token0 and token1
        // Instead, it is sorted by "specifiedCurrency" and "unspecifiedCurrency"

        // Specified Currency => The currency in which the user is specifying the amount they're swapping for
        // Unspecified Currency => The other currency

        // Calculate the correct sqrtPriceLimitX96 for the core pool
        // uint160 sqrtPriceLimitX96_core = params.sqrtPriceLimitX96;
        // if (params.zeroForOne != zeroForOne_core) {
        //     if (sqrtPriceLimitX96_core == 0) {
        //         // When a zeroForOne swap has a limit of 0, it is unbounded. The reciprocal is infinity.
        //         // An unbounded oneForZero swap has a limit of type(uint160).max.
        //         sqrtPriceLimitX96_core = MAX_SQRT_PRICE;
        //     } else {
        //         // The price is inverted, so the limit must be inverted too.
        //         sqrtPriceLimitX96_core = uint160((uint256(1) << 192) / sqrtPriceLimitX96_core);
        //     }
        // }

        // Conduct the swap inside the Pool Manager
        BalanceDelta delta = poolManager.swap(
            corePoolKey,
            SwapParams({
                zeroForOne: zeroForOne_core,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            }),
            bytes("")
        );

        console.log(
            "Core Pool Delta amount0: ",
            // uint256(int256(delta.amount0()))
            delta.amount0()
        );
        console.log(
            "Core Pool Delta amount1: ",
            // uint256(int256(delta.amount1()))
            delta.amount1()
        );

        /// The desired input amount if negative (exactIn), or the desired output amount if positive (exactOut)
        uint256 amountIn;
        uint256 amountOut;
        bool isExactInput = params.amountSpecified < 0;
        if (isExactInput) {
            amountIn = uint256(-params.amountSpecified);
            if (params.zeroForOne == zeroForOne_core) {
                amountOut = uint256(int256(-delta.amount1()));
            } else {
                amountOut = uint256(int256(-delta.amount0()));
            }
        } else {
            if (params.zeroForOne == zeroForOne_core) {
                amountIn = uint256(int256(-delta.amount0()));
            } else {
                amountIn = uint256(int256(-delta.amount1()));
            }
            amountOut = uint256(params.amountSpecified);
        }

        console.log("amountIn: ", amountIn);
        console.log("amountOut: ", amountOut);

        // ? Liquidity is managed inside of the Proxy Hook
        IToken lccToken0 = IToken(Currency.unwrap(tokenMapping[key.currency0]));
        IToken lccToken1 = IToken(Currency.unwrap(tokenMapping[key.currency1]));

        if (params.zeroForOne) {
            // If user is selling Token 0 and buying Token 1

            // They will be sending Token 0 to the PM, creating a debit of Token 0 in the PM
            // We will take Token 0 from the PM and keep it in the hook
            key.currency0.take(poolManager, address(this), amountIn, true);

            // If we're taking Token 0, then we're wrapping it into an LCC
            lccToken0.custodianMint(amountIn);

            // We then need to settle Token 0 LCC to the PM
            // No claims tokens here, because the Hook does not manage LCC tokens after they're settled back into the PM (Core Pool)
            tokenMapping[key.currency0].settle(poolManager, address(this), amountIn, false);

            // Now we need to receive LCC of Token 1 from Core Pool from the PM.
            tokenMapping[key.currency1].take(poolManager, address(this), amountOut, false);

            // Theoretically, we should unwrap LCC of Token 1 from the PM now... Hook should already house the underlying liquidity for the LCC ...
            // Therefore all we need to do is burn the LCC tokens from the hook.
            lccToken1.unwrap(
                // address(this), // TODO: This is correct, however, for now:
                address(poolManager), // TODO: TEMPORARY: burn it from the poolManager...
                amountOut
            );

            // Finally, Trader will be receiving Token 1 from the PM, creating a credit of Token 1 in the PM
            // We will burn claim tokens for Token 1 from the hook so PM can pay the user
            // and create an equivalent debit for Token 1 since it is ours!

            // TODO: As per bug detailed in https://github.com/usherlabs/fiet-protocol/blob/586d63bbef0847b78c251bffcf340f28f75f1dec/solidity/src/IToken.sol#L155
            // We'll need to dynamically adjust the settlement here based on the amount of native token that can actually be settled...
            key.currency1.settle(poolManager, address(this), amountOut, true);
        } else {
            // If user is selling Token 1 and buying Token 0
            key.currency1.take(poolManager, address(this), amountIn, true);

            // If we're taking Token 1, then we're wrapping it into an LCC
            lccToken1.custodianMint(amountIn);

            // We then need to settle Token 1 LCC to the PM
            // No claims tokens here, because the Hook does not manage LCC tokens after they're settled back into the PM (Core Pool)
            tokenMapping[key.currency1].settle(poolManager, address(this), amountIn, false);

            // Now we need to receive LCC of Token 0 from Core Pool from the PM.
            tokenMapping[key.currency0].take(poolManager, address(this), amountOut, false);

            // Theoretically, we should unwrap LCC of Token 1 from the PM now... Hook should already house the underlying liquidity for the LCC ...
            // Therefore all we need to do is burn the LCC tokens from the hook.
            lccToken0.unwrap(
                // address(this), // TODO: This is correct, however, for now:
                address(poolManager), // TODO: TEMPORARY: burn it from the poolManager...
                amountOut
            );

            // Finally, Trader will be receiving Token 1 from the PM, creating a credit of Token 1 in the PM
            // We will burn claim tokens for Token 1 from the hook so PM can pay the user
            // and create an equivalent debit for Token 1 since it is ours!
            key.currency0.settle(poolManager, address(this), amountOut, true);
        }

        BeforeSwapDelta newDelta;
        if (params.zeroForOne == zeroForOne_core) {
            newDelta = toBeforeSwapDelta(delta.amount0(), delta.amount1());
        } else {
            newDelta = toBeforeSwapDelta(delta.amount1(), delta.amount0());
        }

        return (this.beforeSwap.selector, newDelta, 0);
    }
}

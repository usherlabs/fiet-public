// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {IToken} from "./IToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "forge-std/console.sol";

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

    struct CallbackData {
        Currency currency0;
        Currency currency1;
    }

    // store pool identifiers for the core and proxy pool
    PoolKey corePoolKey;
    PoolKey proxyPoolKey;

    constructor(
        IPoolManager poolManager,
        PoolKey memory _corePoolKey
    ) BaseHook(poolManager) {
        corePoolKey = _corePoolKey;
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

    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) external override returns (bytes4) {
        proxyPoolKey = key;
        return this.beforeInitialize.selector;
    }

    // Disable adding liquidity to the proxy pool
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert AddLiquidityThroughHook();
    }

    // Before swap we make sure to provide enough delta
    // to ensure that the user gets a debit of amount specified
    // and we disable the core swap mechanism
    // and proxy the swap through the core pool
    function beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        // unwrap the output amount of the recieved token to get the underlying asset added to balance
        Currency outputCurrency = params.zeroForOne
            ? corePoolKey.currency1
            : corePoolKey.currency0;

        IToken iOutToken = IToken(Currency.unwrap(outputCurrency));
        //iOutToken.checkForRFS(); // dead code

        address recipient = abi.decode(hookData, (address));

        uint256 amountInOutPositive = params.amountSpecified > 0
            ? uint256(params.amountSpecified)
            : uint256(-params.amountSpecified);

        // disable swap mechanism
        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(
            params.amountSpecified > 0
                ? int128(0)
                : int128(-params.amountSpecified),
            params.amountSpecified > 0
                ? int128(params.amountSpecified)
                : int128(0)
        );

        // take deposit from the pool manager
        Currency takeCurrency = params.zeroForOne
            ? key.currency0
            : key.currency1;

        takeCurrency.take(
            poolManager,
            address(this),
            amountInOutPositive,
            true
        );

        // wrap the provided token to use as input token or token specified
        (, uint256 outputAmount) = swapAndSettleBalances(corePoolKey, params);

        // unwrap the response/provided token
        // approve the iToken to take amount to be unwrapped from the hook
        iOutToken.approve(address(iOutToken), outputAmount);

        // unwrap the tokens
        address underlyingAsset = iOutToken.underlyingAsset();
        IERC20(underlyingAsset).approve(address(iOutToken), outputAmount);
        // this essentially transfers the underlying asset from the hook to the recipient
        iOutToken.unwrap(recipient, outputAmount);

        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }

    // use this helper to perform a swap and settle operation on the core pool
    function swapAndSettleBalances(
        PoolKey memory key,
        SwapParams memory params
    ) internal returns (BalanceDelta, uint256) {
        // Conduct the swap inside the Pool Manager
        BalanceDelta delta = poolManager.swap(key, params, bytes(""));
        uint256 outputAmount = 0;

        // If we just did a zeroForOne swap
        // We need to send Token 0 to PM, and receive Token 1 from PM
        if (params.zeroForOne) {
            // Negative Value => Money leaving user's wallet
            // Promise Mint some tokens in order to settle with the pool manager
            // Settle with PoolManager
            if (delta.amount0() < 0) {
                IToken(Currency.unwrap(corePoolKey.currency0)).custodianMint(
                    uint256(int256(-delta.amount0()))
                );
                _settle(key.currency0, uint128(-delta.amount0()));
            }

            // Positive Value => Money coming into user's wallet
            // Take from PM
            if (delta.amount1() > 0) {
                _take(key.currency1, uint128(delta.amount1()));
                outputAmount = uint256(uint128(delta.amount1()));
            }
        } else {
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

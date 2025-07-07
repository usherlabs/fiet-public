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
    mapping(Currency => Currency) tokenMapping;

    constructor(
        IPoolManager poolManager,
        PoolKey memory _corePoolKey
    ) BaseHook(poolManager) {
        corePoolKey = _corePoolKey;
        Currency underlyingToken0 = Currency.wrap(
            IToken(Currency.unwrap(_corePoolKey.currency0)).underlyingAsset()
        );
        tokenMapping[underlyingToken0] = _corePoolKey.currency0;
        Currency underlyingToken1 = Currency.wrap(
            IToken(Currency.unwrap(_corePoolKey.currency1)).underlyingAsset()
        );
        tokenMapping[underlyingToken1] = _corePoolKey.currency1;
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
        console.log("=== DIRECTIONAL SETTLEMENT DEBUG ===");
        console.log("zeroForOne:", params.zeroForOne);

        // unwrap the output amount of the recieved token to get the underlying asset added to balance
        Currency coreOutputCurrency;
        Currency coreInputCurrency;
        Currency proxyInputCurrency;
        Currency proxyOutputCurrency;

        if (params.zeroForOne) {
            coreOutputCurrency = tokenMapping[key.currency1];
            coreInputCurrency = tokenMapping[key.currency0];
            proxyOutputCurrency = key.currency1;
            proxyInputCurrency = key.currency0;
        } else {
            coreOutputCurrency = tokenMapping[key.currency0];
            coreInputCurrency = tokenMapping[key.currency1];
            proxyOutputCurrency = key.currency0;
            proxyInputCurrency = key.currency1;
        }
        console.log(
            "coreInputCurrency: ",
            IERC20Metadata(Currency.unwrap(coreInputCurrency)).name(),
            " from coreOutputCurrency to: ",
            IERC20Metadata(Currency.unwrap(coreOutputCurrency)).name()
        );
        console.log(
            "proxyInputCurrency: ",
            IERC20Metadata(Currency.unwrap(proxyInputCurrency)).name(),
            " from coreOutputCurrency to: ",
            IERC20Metadata(Currency.unwrap(proxyOutputCurrency)).name()
        );
        console.log(" ");
        IToken iOutToken = IToken(Currency.unwrap(coreOutputCurrency));
        IToken iInToken = IToken(Currency.unwrap(coreInputCurrency));
        IERC20 proxyTokenIn = IERC20(Currency.unwrap(proxyInputCurrency));
        IERC20 proxyTokenOut = IERC20(Currency.unwrap(proxyOutputCurrency));
        //iOutToken.checkForRFS(); // dead code

        {
            console.log("=== Initial balance check DEBUG ===");
            uint initialBalanceCoreIn = iInToken.balanceOf(address(this));
            uint initialBalanceCoreOut = iOutToken.balanceOf(address(this));
            console.log(
                "initialBalanceCoreIn: ",
                initialBalanceCoreIn / 1e18,
                "initialBalanceCoreOut",
                initialBalanceCoreOut / 1e18
            );
            uint initialBalanceProxyIn = proxyTokenIn.balanceOf(address(this));
            uint initialBalanceProxyOut = proxyTokenOut.balanceOf(
                address(this)
            );
            console.log(
                "initialBalanceProxyIn: ",
                initialBalanceProxyIn / 1e18,
                "initialBalanceProxyout: ",
                initialBalanceProxyOut / 1e18
            );
            console.log(" ");
        }

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
        // Takes underflying token from proxyPool
        proxyInputCurrency.take(
            poolManager,
            address(this),
            amountInOutPositive,
            true
        );

        console.log("=== Test 1 balance check DEBUG ===");
        uint initialBalanceCoreIn1 = iInToken.balanceOf(address(this));
        uint initialBalanceCoreOut1 = iOutToken.balanceOf(address(this));
        console.log(
            "initialBalanceCoreIn: ",
            initialBalanceCoreIn1 / 1e18,
            "initialBalanceCoreOut",
            initialBalanceCoreOut1 / 1e18
        );
        uint initialBalanceProxyIn1 = proxyTokenIn.balanceOf(address(this));
        uint initialBalanceProxyOut1 = proxyTokenOut.balanceOf(address(this));
        console.log(
            "initialBalanceProxyIn: ",
            initialBalanceProxyIn1 / 1e18,
            "initialBalanceProxyout: ",
            initialBalanceProxyOut1 / 1e18
        );
        console.log(" ");

        // wrap the provided token to use as input token or token specified
        (, uint256 outputAmount) = swapAndSettleBalances(corePoolKey, params);

        {
            console.log("=== Test 2 balance check DEBUG ===");
            uint initialBalanceCoreIn2 = iInToken.balanceOf(address(this));
            uint initialBalanceCoreOut2 = iOutToken.balanceOf(address(this));
            console.log(
                "initialBalanceCoreIn: ",
                initialBalanceCoreIn2 / 1e18,
                "initialBalanceCoreOut",
                initialBalanceCoreOut2 / 1e18
            );
            uint initialBalanceProxyIn2 = proxyTokenIn.balanceOf(address(this));
            uint initialBalanceProxyOut2 = proxyTokenOut.balanceOf(
                address(this)
            );
            console.log(
                "initialBalanceProxyIn: ",
                initialBalanceProxyIn2 / 1e18,
                "initialBalanceProxyout: ",
                initialBalanceProxyOut2 / 1e18
            );
            console.log(" ");
        }
        // unwrap the response/provided token
        // approve the iToken to take amount to be unwrapped from the hook
        iOutToken.approve(address(iOutToken), outputAmount);

        // unwrap the tokens
        address underlyingAsset = iOutToken.underlyingAsset();
        IERC20(underlyingAsset).approve(address(iOutToken), outputAmount);
        // this essentially transfers the underlying asset from the hook to the recipient
        iOutToken.unwrap(recipient, outputAmount);

        {
            console.log("=== Test 3 balance check DEBUG ===");
            uint initialBalanceCoreIn3 = iInToken.balanceOf(address(this));
            uint initialBalanceCoreOut3 = iOutToken.balanceOf(address(this));
            console.log(
                "initialBalanceCoreIn: ",
                initialBalanceCoreIn3 / 1e18,
                "initialBalanceCoreOut",
                initialBalanceCoreOut3 / 1e18
            );
            uint initialBalanceProxyIn3 = proxyTokenIn.balanceOf(address(this));
            uint initialBalanceProxyOut3 = proxyTokenOut.balanceOf(
                address(this)
            );
            console.log(
                "initialBalanceProxyIn: ",
                initialBalanceProxyIn3 / 1e18,
                "initialBalanceProxyout: ",
                initialBalanceProxyOut3 / 1e18
            );
            console.log(" ");
        }
        //_settle(proxyOutputCurrency, uint128(outputAmount));

        {
            console.log("=== Test 4 balance check DEBUG ===");
            uint initialBalanceCoreIn4 = iInToken.balanceOf(address(this));
            uint initialBalanceCoreOut4 = iOutToken.balanceOf(address(this));
            console.log(
                "initialBalanceCoreIn: ",
                initialBalanceCoreIn4,
                "initialBalanceCoreOut",
                initialBalanceCoreOut4
            );
            uint initialBalanceProxyIn4 = proxyTokenIn.balanceOf(address(this));
            uint initialBalanceProxyOut4 = proxyTokenOut.balanceOf(
                address(this)
            );
            console.log(
                "initialBalanceProxyIn: ",
                initialBalanceProxyIn4,
                "initialBalanceProxyout: ",
                initialBalanceProxyOut4
            );
            console.log(" ");
        }

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
        console.log("amount 0 delta: ", delta.amount0());
        console.log("amount 1 delta: ", delta.amount1());
        console.log(" ");
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

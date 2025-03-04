// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {LimitedERC20} from "./LimitedERC20.sol";
import "forge-std/console.sol";

// A CSMM is a pricing curve that follows the invariant `x + y = k`
// instead of the invariant `x * y = k`

contract CSMM is BaseHook, ERC20 {
    using CurrencySettler for Currency;

    error AddLiquidityThroughHook();
    error CannotTransferVRL(address recipient, uint256 amount);

    struct CallbackData {
        uint256 amountEach;
        Currency currency0;
        Currency currency1;
        address sender;
    }

    constructor(
        IPoolManager _manager
    ) BaseHook(_manager) ERC20("Liquidity Delta", "LD", 18) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
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

    // Disable adding liquidity through the PM
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert AddLiquidityThroughHook();
    }

    // Custom add liquidity function
    function addLiquidity(PoolKey calldata key, uint256 amountEach) external {
        poolManager.unlock(
            abi.encode(
                CallbackData(
                    amountEach,
                    key.currency0,
                    key.currency1,
                    msg.sender
                )
            )
        );
    }

    function _unlockCallback(
        bytes calldata data
    ) internal override returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        // There should be two tokens in the pool
        // one should be this token which is the hook contract
        // and the other should be the token that will be used to inject liquidity
        // We make a check to make sure we take the token that is not 'LD' i.e the stable coin deposited

        // Settle `amountEach` of stablecoin from the sender
        // i.e. Create a debit of `amountEach` of the stable coin with the Pool Manager

        // Since we didn't go through the regular "modify liquidity" flow,
        // the PM just has a debit of `amountEach` of the stable currency from us
        // We can, in exchange, get back ERC-6909 claim tokens for `amountEach` of each currency
        // to create a credit of `amountEach` of each currency to us
        // that balances out the debit

        // We will store those claim tokens with the hook, so when swaps take place
        // liquidity from our CSMM can be used by minting/burning claim tokens the hook owns

        if (Currency.unwrap(callbackData.currency0) == address(this)) {
            callbackData.currency1.settle(
                poolManager,
                callbackData.sender,
                callbackData.amountEach,
                false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
            );

            callbackData.currency1.take(
                poolManager,
                address(this),
                callbackData.amountEach,
                true // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
            );
        } else {
            callbackData.currency0.settle(
                poolManager,
                callbackData.sender,
                callbackData.amountEach,
                false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
            );

            callbackData.currency0.take(
                poolManager,
                address(this),
                callbackData.amountEach,
                true // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
            );
        }

        return "";
    }

    // // Swapping
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes memory hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        // check if it is a crypto => fiat swap or fiat => crypto swap
        // i.e isFiatToCrypto if it is a zeroForOneSwap and the zero currency is this address of the LD(FIAT represented) token
        // i.e isFiatToCrypto if it is a OneForZeroSwap and the one currency is this address of the LD(FIAT represented) token
        bool isFiatToCrypto = params.zeroForOne
            ? Currency.unwrap(key.currency0) == address(this)
            : Currency.unwrap(key.currency1) == address(this);

        // get the absolute value of the provided amount
        int256 amountInOutPositive = params.amountSpecified > 0
            ? int256(params.amountSpecified)
            : int256(-params.amountSpecified);

        uint256 aamountInOutPositive = params.amountSpecified > 0
            ? uint256(params.amountSpecified)
            : uint256(-params.amountSpecified);

        (Currency fiat, Currency crypto) = Currency.unwrap(key.currency0) ==
            address(this)
            ? (key.currency0, key.currency1)
            : (key.currency1, key.currency0);

        // define the swap delta variable to be assigned depending on the direction of the swap
        BeforeSwapDelta beforeSwapDelta;

        if (isFiatToCrypto) {
            crypto.settle(
                poolManager,
                address(this),
                aamountInOutPositive,
                true
            );

            // fiat to crypto swap
            beforeSwapDelta = toBeforeSwapDelta(
                int128(0),
                int128(-amountInOutPositive)
            );
        }else{
            beforeSwapDelta = toBeforeSwapDelta(
                int128(amountInOutPositive),
                int128(0)
            );

            crypto.take(
                poolManager,
                address(this),
                aamountInOutPositive,
                true
            );
        }

        // decode the hook data
        // (string memory currency, address recipient) = abi.decode(
        //     hookData,
        //     (string, address)
        // );
        // First check the VRL Manager Contract
        // uint256 LD = surety.getLiquidityDepth(hashCurrency(currency));
        // require(LD >= amountInOutPositive);
        // Make sure that for a given currency, there is not enough available VRL

        // TODO: Fee rebating and stuff and JIT liquidity pools

        // if (params.zeroForOne) {
        //     // They will be sending Token 0 to the PM, creating a debit of Token 0 in the PM
        //     // We will take claim tokens for that Token 0 from the PM and keep it in the hook
        //     // and create an equivalent credit for that Token 0 since it is ours!
        //     // we cannot take from the pm
        //     // key.currency0.take(
        //     //     poolManager,
        //     //     address(this),
        //     //     amountInOutPositive,
        //     //     true
        //     // );
        // } else {
        //     // key.currency1.take(
        //     //     poolManager,
        //     //     address(this),
        //     //     amountInOutPositive,
        //     //     true
        //     // );
        // }

        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }

    // function afterSwap(
    //     address sender,
    //     PoolKey calldata key,
    //     IPoolManager.SwapParams calldata params,
    //     BalanceDelta delta,
    //     bytes memory hookData
    // ) external override returns (bytes4, BeforeSwapDelta, uint24) {
    //     // decode the hook data
    //     (string memory currency, address recipient) = abi.decode(
    //         hookData,
    //         (string, address)
    //     );

    //     // pass this value to the VRL manager to decrease the locked supply and update user balance
    //     surety.withdraw(
    //         recipient,
    //         params.amountSpecified,
    //         currency
    //     );
    // }

    // helper function to hash the currency
    function hashCurrency(
        string memory currency
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(currency));
    }

    // helper function to get hook data
    function getHookData(
        bytes32 currencyHash,
        bytes calldata signature,
        address userAddress
    ) public pure returns (bytes memory) {
        return abi.encode(currencyHash, signature, userAddress);
    }
}

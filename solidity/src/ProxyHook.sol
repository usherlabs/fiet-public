// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// import {BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import "forge-std/console.sol";

import {LiquidityCommitmentCertificate} from "./LCC.sol";
import {IHookCommon} from "./interfaces/IHookCommon.sol";

contract ProxyHook is BaseHook, IHookCommon {
    using CurrencySettler for Currency;

    error AddLiquidityThroughHookNotAllowed();
    error UnsafeInt128ToUint256Conversion(int128 value);
    error InvalidInitialiser();
    error InvalidSender();

    struct LiquidityCallbackData {
        uint256 amount0;
        uint256 amount1;
        Currency currency0;
        Currency currency1;
        address poolManager;
        ActionType actionType;
    }

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

    address public immutable marketFactory;

    address public immutable coreHook; // specific to proxy hook.

    mapping(PoolId => PoolKey) public corePoolKey;

    modifier onlyCoreHook() {
        if (msg.sender != coreHook) {
            revert InvalidSender();
        }
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != marketFactory) {
            revert InvalidSender();
        }
        _;
    }

    /**
     * @dev Safely converts int128 to uint256, handling negative values by taking absolute value
     * @param value The int128 value to convert
     * @return The uint256 representation (absolute value)
     */
    function _safeInt128ToUint256(
        int128 value
    ) internal pure returns (uint256) {
        if (value < 0) {
            return uint256(uint128(-value));
        }
        return uint256(uint128(value));
    }

    constructor(
        address _poolManager,
        address _marketFactory
    ) BaseHook(IPoolManager(_poolManager)) {
        marketFactory = _marketFactory;
    }

    function activate() external onlyFactory {
        coreHook = IMarketFactory(marketFactory).getCoreHook();
    }

    /**
     * @dev Updates the core pool key with the actual core pool configuration
     * @param _corePoolKey The actual core pool key to set
     */
    function setCorePoolKey(
        PoolId thisPoolId,
        PoolKey calldata _corePoolKey
    ) external onlyFactory {
        corePoolKey[thisPoolId] = _corePoolKey;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true, // Ensure that markets are only created by MarketFactory
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
        address sender,
        PoolKey calldata key,
        uint160
    ) internal pure virtual override returns (bytes4) {
        if (sender != marketFactory) {
            revert InvalidInitialiser();
        }

        // initialise the counterparty hook -- proxy pool is created after the core pool.
        // Note: This is a placeholder for future implementation
        // The core hook reference is already set in constructor

        return this._beforeInitialize.selector;
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure virtual override returns (bytes4) {
        revert AddLiquidityThroughHookNotAllowed();
    }

    function unlockCallback(
        bytes calldata data
    ) external override onlyPoolManager returns (bytes memory) {
        LiquidityCallbackData memory callbackData = abi.decode(
            data,
            (LiquidityCallbackData)
        );
        if (callbackData.actionType == ActionType.DirectLPAddLiquidity) {
            // Add liquidity to the core pool

            // Settle `callbackData.amount` of each currency from the sender
            // i.e. Create a debit of `callbackData.amount` of each currency with the Pool Manager
            callbackData.currency0.settle(
                IPoolManager(callbackData.poolManager),
                Currency.unwrap(callbackData.currency0),
                callbackData.amount0,
                false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
            );
            callbackData.currency1.settle(
                IPoolManager(callbackData.poolManager),
                Currency.unwrap(callbackData.currency1),
                callbackData.amount1,
                false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
            );

            // Since we didn't go through the regular "modify liquidity" flow,
            // the PM just has a debit of `callbackData.amount` of each currency from us
            // We can, in exchange, get back ERC-6909 claim tokens for `callbackData.amount`
            // to create a credit of `callbackData.amount` of each currency to us that balances out the debit

            // We will store those claim tokens with the hook, so when swaps take place
            // liquidity from our CSMM can be used by minting/burning claim tokens the hook owns
            callbackData.currency0.take(
                IPoolManager(callbackData.poolManager),
                address(this),
                callbackData.amount0,
                true // `mint` = `true` i.e. we're minting claim tokens for the hook, equivalent to money we just deposited to the PM
            );
            callbackData.currency1.take(
                IPoolManager(callbackData.poolManager),
                address(this),
                callbackData.amount1,
                true // `mint` = `true` i.e. we're minting claim tokens for the hook, equivalent to money we just deposited to the PM
            );
        } else if (
            callbackData.actionType == ActionType.DirectLPRemoveLiquidity
        ) {
            // Remove liquidity from the core pool

            callbackData.currency0.settle(
                IPoolManager(callbackData.poolManager),
                address(this),
                callbackData.amount0,
                true // `burn` = `true` i.e. we're  burning ERC-6909 Claim Tokens
            );
            callbackData.currency1.settle(
                IPoolManager(callbackData.poolManager),
                address(this),
                callbackData.amount1,
                true // `burn` = `true` i.e. we're  burning ERC-6909 Claim Tokens
            );

            callbackData.currency0.take(
                IPoolManager(callbackData.poolManager),
                Currency.unwrap(callbackData.currency0), // Send native liquidity back to LCC
                callbackData.amount0,
                false // mint` = `true` i.e. we're  claiming erc20
            );
            callbackData.currency1.take(
                IPoolManager(callbackData.poolManager),
                Currency.unwrap(callbackData.currency1),
                callbackData.amount1,
                false // mint` = `true` i.e. we're  claiming erc20
            );
        }
    }

    // Method called by the Core Hook notifying that Direct Liquidity Provision occurred.
    // We notify the Proxy Hook so that the BeforeSwapDelta can facilitate liquidity management of native underlying tokens.
    function onDirectLP(
        PoolKey calldata corePoolkey,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        ActionType actionType
    ) external virtual nonReentrant onlyCoreHook returns (uint256) {
        // require(block.timestamp <= deadline, "Deadline not met");

        // Get the LCC tokens for the core pool
        LiquidityCommitmentCertificate lccToken0 = Currency.unwrap(
            corePoolkey.currency0
        );
        LiquidityCommitmentCertificate lccToken1 = Currency.unwrap(
            corePoolkey.currency1
        );

        IPoolManager(self.poolManager).unlock(
            abi.encode(
                LiquidityCallbackData(
                    delta.amount0(),
                    delta.amount1(),
                    Currency.wrap(lccToken0.underlyingAsset()),
                    Currency.wrap(lccToken1.underlyingAsset()),
                    self.poolManager,
                    actionType
                )
            )
        );
    }

    // Before swap we make sure to provide enough delta
    // to ensure that the user gets a debit of amount specified
    // and we disable the core swap mechanism
    // and proxy the swap through the core pool
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        bool coreZeroForOne;
        PoolKey memory coreKey = corePoolKey[key.toId()];

        LiquidityCommitmentCertificate lccToken0 = LiquidityCommitmentCertificate(
                Currency.unwrap(coreKey.currency0)
            );
        LiquidityCommitmentCertificate lccToken1 = LiquidityCommitmentCertificate(
                Currency.unwrap(coreKey.currency1)
            );

        if (params.zeroForOne) {
            // If tokens match order, then coreZeroForOne is true
            coreZeroForOne =
                Currency.unwrap(key.currency0) == lccToken0.underlyingAsset();
        } else {
            // If tokens match order, then coreZeroForOne is false
            coreZeroForOne =
                Currency.unwrap(key.currency1) == lccToken1.underlyingAsset();
        }

        // If zeroForOne match, then lccTokenForCurrency0 is lccToken0 and lccTokenForCurrency1 is lccToken1
        // If zeroForOne does not match, then lccTokenForCurrency0 is lccToken1 and lccTokenForCurrency1 is lccToken0
        LiquidityCommitmentCertificate lccTokenForCurrency0 = params
            .zeroForOne == coreZeroForOne
            ? lccToken0
            : lccToken1;
        LiquidityCommitmentCertificate lccTokenForCurrency1 = params
            .zeroForOne == coreZeroForOne
            ? lccToken1
            : lccToken0;
        Currency lccCurrencyForCurrency0 = Currency.wrap(
            address(lccTokenForCurrency0)
        );
        Currency lccCurrencyForCurrency1 = Currency.wrap(
            address(lccTokenForCurrency1)
        );

        // BalanceDelta is a packed value of (currency0Amount, currency1Amount)

        // BeforeSwapDelta varies such that it is not sorted by token0 and token1
        // Instead, it is sorted by "specifiedCurrency" and "unspecifiedCurrency"

        // Specified Currency => The currency in which the user is specifying the amount they're swapping for
        // Unspecified Currency => The other currency

        // Calculate the correct sqrtPriceLimitX96 for the core pool
        // uint160 sqrtPriceLimitX96_core = params.sqrtPriceLimitX96;
        // if (params.zeroForOne != coreZeroForOne) {
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
            coreKey,
            SwapParams({
                zeroForOne: coreZeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            }),
            bytes("")
        );

        console.log("Core Pool Delta amount0: ", delta.amount0());
        console.log("Core Pool Delta amount1: ", delta.amount1());
        console.log("coreZeroForOne: ", coreZeroForOne);
        console.log("params.zeroForOne: ", params.zeroForOne);

        /// The desired input amount if negative (exactIn), or the desired output amount if positive (exactOut)
        uint256 amountIn;
        uint256 amountOut;
        bool isExactInput = params.amountSpecified < 0;
        if (isExactInput) {
            amountIn = uint256(-params.amountSpecified);
            if (params.zeroForOne == coreZeroForOne) {
                amountOut = _safeInt128ToUint256(delta.amount1());
            } else {
                amountOut = _safeInt128ToUint256(delta.amount0());
            }
        } else {
            if (params.zeroForOne == coreZeroForOne) {
                amountIn = _safeInt128ToUint256(delta.amount0());
            } else {
                amountIn = _safeInt128ToUint256(delta.amount1());
            }
            amountOut = uint256(params.amountSpecified);
        }

        console.log("amountIn: ", amountIn);
        console.log("amountOut: ", amountOut);

        if (params.zeroForOne) {
            // If user is selling Token 0 and buying Token 1
            // First mint LCC tokens for the input amount
            lccTokenForCurrency0.mint(address(this), amountIn);

            // Settle LCC tokens to the PoolManager
            // Accounts for LCC of 0 IN for the Core Pool Swap
            lccCurrencyForCurrency0.settle(
                poolManager,
                address(this),
                amountIn,
                false
            );

            // Now take the underlying tokens from PoolManager to the LCC
            // This will allow unwrap with liquidity from trader deposits.
            poolManager.take(
                key.currency0,
                address(lccTokenForCurrency0),
                amountIn
            );

            // Take LCC tokens of Token 1 from PoolManager
            // Accounts for LCC of 1 OUT for the Core Pool Swap
            lccCurrencyForCurrency1.take(
                poolManager,
                address(this),
                amountOut,
                false
            );

            // Unwrap and Burn the LCC of Token 1 from the PM... might need to be executed elsewhere...
            lccTokenForCurrency1.burnOnSettle(amountOut);
            // Once Uniswap conducts fund settlement, it'll burn this amountOut from the LCC.
        } else {
            // If user is selling Token 1 (IN) and buying Token 0 (OUT)
            // First mint LCC tokens for the input amount
            lccTokenForCurrency1.mint(address(this), amountIn);

            // Settle LCC tokens to the PoolManager
            lccCurrencyForCurrency1.settle(
                poolManager,
                address(this),
                amountIn,
                false
            );

            // Now take the underlying tokens from PoolManager to the LCC
            // This will allow unwrap with liquidity from trader deposits.
            poolManager.take(
                key.currency1,
                address(lccTokenForCurrency1),
                amountIn
            );

            // Take LCC tokens of Token 0 from PoolManager
            // Accounts for LCC of 0 OUT for the Core Pool Swap
            lccCurrencyForCurrency0.take(
                poolManager,
                address(this),
                amountOut,
                false
            );

            // Unwrap and Burn the LCC of Token 0 from the PM
            lccTokenForCurrency0.burnOnSettle(amountOut);
            // Once Uniswap conducts fund settlement, it'll burn this amountOut from the LCC.
        }

        // pay the output token, to the PoolManager from Proxy Hook.
        // the credit will be forwarded to the swap router, which then forwards it to the swapper
        poolManager.sync(params.zeroForOne ? key.currency1 : key.currency0);
        poolManager.settle();

        // TODO: Consider scenario where LCC has insufficient liquidity.
        // ie. less from here for token OUT, and more from core Token OUT.
        BeforeSwapDelta newDelta;
        if (params.zeroForOne == coreZeroForOne) {
            newDelta = toBeforeSwapDelta(delta.amount0(), delta.amount1());
        } else {
            newDelta = toBeforeSwapDelta(delta.amount1(), delta.amount0());
        }

        return (this.beforeSwap.selector, newDelta, 0);
    }
}

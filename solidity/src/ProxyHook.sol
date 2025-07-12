// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
// import {BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import "forge-std/console.sol";

import {LiquidityCommitmentCertificate} from "./LCC.sol";
import {IHookCommon} from "./interfaces/IHookCommon.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract ProxyHook is BaseHook, IHookCommon {
    using CurrencySettler for Currency;

    error AddLiquidityThroughHookNotAllowed();
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

    address public coreHook; // specific to proxy hook.

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
        PoolKey calldata,
        uint160
    ) internal view virtual override returns (bytes4) {
        if (sender != marketFactory) {
            revert InvalidInitialiser();
        }

        // initialise the counterparty hook -- proxy pool is created after the core pool.
        // Note: This is a placeholder for future implementation
        // The core hook reference is already set in constructor

        return this.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure virtual override returns (bytes4) {
        revert AddLiquidityThroughHookNotAllowed();
    }

    // Method called by the Core Hook notifying that Direct Liquidity Provision occurred.
    // Liquidity is managed by the Proxy Hook here to ensure PM credits the Proxy Hook (msg.sender) with relevant Currency Delta.
    // THIS IS ALREADY UNLOCKED FOR DIRECT LP ON CORE POOL.
    function onDirectLP(
        PoolKey calldata corePoolkey,
        BalanceDelta delta,
        ActionType actionType
    ) external virtual onlyCoreHook {
        LiquidityCommitmentCertificate lccToken0 = LiquidityCommitmentCertificate(
                Currency.unwrap(corePoolkey.currency0)
            );
        LiquidityCommitmentCertificate lccToken1 = LiquidityCommitmentCertificate(
                Currency.unwrap(corePoolkey.currency1)
            );
        Currency uaCurrency0 = Currency.wrap(lccToken0.underlyingAsset());
        Currency uaCurrency1 = Currency.wrap(lccToken1.underlyingAsset());
        uint256 amount0 = _safeInt128ToUint256(delta.amount0());
        uint256 amount1 = _safeInt128ToUint256(delta.amount1());

        if (actionType == ActionType.DirectLPAddLiquidity) {
            // Add liquidity to the core pool

            // Settle `amount` of each currency from the sender
            // i.e. Create a debit of `amount` of each currency with the Pool Manager
            lccToken0.prepareSettle(amount0);
            lccToken1.prepareSettle(amount1);
            uaCurrency0.settle(
                poolManager,
                address(lccToken0),
                amount0,
                false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
            );
            uaCurrency1.settle(
                poolManager,
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
                poolManager,
                address(this),
                amount0,
                true // `mint` = `true` i.e. we're minting claim tokens for the hook, equivalent to money we just deposited to the PM
            );
            uaCurrency1.take(
                poolManager,
                address(this),
                amount1,
                true // `mint` = `true` i.e. we're minting claim tokens for the hook, equivalent to money we just deposited to the PM
            );
        } else if (actionType == ActionType.DirectLPRemoveLiquidity) {
            // Remove liquidity from the core pool
            uaCurrency0.settle(
                poolManager,
                address(this),
                amount0,
                true // `burn` = `true` i.e. we're  burning ERC-6909 Claim Tokens
            );
            uaCurrency1.settle(
                poolManager,
                address(this),
                amount1,
                true // `burn` = `true` i.e. we're  burning ERC-6909 Claim Tokens
            );
            uaCurrency0.take(
                poolManager,
                address(lccToken0), // Send native liquidity back to LCC
                amount0,
                false // mint` = `true` i.e. we're  claiming erc20
            );
            uaCurrency1.take(
                poolManager,
                address(lccToken1),
                amount1,
                false // mint` = `true` i.e. we're  claiming erc20
            );
        }
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

        if (
            Currency.unwrap(key.currency0) == lccToken0.underlyingAsset() &&
            Currency.unwrap(key.currency1) == lccToken1.underlyingAsset()
        ) {
            // If tokens match order, then Proxy matches Core
            coreZeroForOne = params.zeroForOne;
        } else {
            // If tokens do not match order, then Proxy inverts Core
            coreZeroForOne = !params.zeroForOne;
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
        uint160 sqrtPriceLimitX96_core = params.sqrtPriceLimitX96;
        bool flipped = params.zeroForOne != coreZeroForOne;
        if (flipped) {
            if (sqrtPriceLimitX96_core == TickMath.MIN_SQRT_PRICE + 1) {
                sqrtPriceLimitX96_core = TickMath.MAX_SQRT_PRICE - 1;
            } else if (sqrtPriceLimitX96_core == TickMath.MAX_SQRT_PRICE - 1) {
                sqrtPriceLimitX96_core = TickMath.MIN_SQRT_PRICE + 1;
            } else if (sqrtPriceLimitX96_core != 0) {
                sqrtPriceLimitX96_core = uint160(
                    (uint256(1) << 192) / sqrtPriceLimitX96_core
                );
            } else {
                // If somehow 0 (though router overrides), set unbounded for flipped
                sqrtPriceLimitX96_core = TickMath.MAX_SQRT_PRICE - 1;
            }
        }

        // Conduct the swap inside the Pool Manager
        BalanceDelta delta = poolManager.swap(
            coreKey,
            SwapParams({
                zeroForOne: coreZeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96_core // Use adjusted limit
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

            // Take the underlying tokens from PoolManager as Claim Tokens... the underlying liquidity remains in the Pool Manager...
            key.currency0.take(poolManager, address(this), amountIn, true);

            // Mint LCC tokens for the input amount
            // These LCC tokens are collateralised by liquidity that remains in the Pool Manager.
            lccTokenForCurrency0.issue(amountIn);

            // Settle minted LCC tokens to the PoolManager
            // Accounts for LCC of 0 IN for the Core Pool Swap
            lccCurrencyForCurrency0.settle(
                poolManager,
                address(this),
                amountIn,
                false
            );

            // Take LCC tokens of Token 1 from PoolManager
            // Accounts for LCC of 1 OUT for the Core Pool Swap
            lccCurrencyForCurrency1.take(
                poolManager,
                address(this),
                amountOut,
                false
            );

            // Unwrap and Burn the LCC of Token 1 after taking from PM
            (uint256 cancelledAmount, uint256 deficit) = lccTokenForCurrency1
                .cancel(amountOut);

            console.log("cancelledAmount: ", cancelledAmount);
            console.log("deficit: ", deficit);

            // Once Uniswap conducts fund settlement, it'll burn this amountOut from the LCC.

            // Settle the output token to the PoolManager
            // Burn claim tokens to release output token to the Trader from the PoolManager.
            // ? amountOut can be greater than total amount of underlying asset in PoolManager.
            // ? In this case, there is insufficient liquidity to settle amountOut of output token.
            // TODO: Solve for this case.
            key.currency1.settle(
                poolManager,
                address(this),
                cancelledAmount,
                true
            );
        } else {
            key.currency1.take(poolManager, address(this), amountIn, true);

            // If user is selling Token 1 (IN) and buying Token 0 (OUT)
            // First mint LCC tokens for the input amount
            lccTokenForCurrency1.issue(amountIn);

            // Settle LCC tokens to the PoolManager
            lccCurrencyForCurrency1.settle(
                poolManager,
                address(this),
                amountIn,
                false
            );

            // Take LCC tokens of Token 0 from PoolManager
            // Accounts for LCC of 0 OUT for the Core Pool Swap
            lccCurrencyForCurrency0.take(
                poolManager,
                address(this),
                amountOut,
                false
            );

            // Cancel (Unwrap/Burn) the LCC of Token 0 after taking from PM
            (uint256 cancelledAmount, uint256 deficit) = lccTokenForCurrency0
                .cancel(amountOut);

            console.log("cancelledAmount: ", cancelledAmount);
            console.log("deficit: ", deficit);

            // Settle the output token to the PoolManager
            // Burn claim tokens to release output token to the Trader from the PoolManager.
            // TODO: Solve for above case.
            key.currency0.settle(
                poolManager,
                address(this),
                cancelledAmount,
                true
            );
        }

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

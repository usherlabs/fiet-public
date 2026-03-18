// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

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
import {ILCC} from "./interfaces/ILCC.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {VaultCoreActionHandler} from "./modules/VaultCoreActionHandler.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {IMsgSender} from "v4-periphery/src/interfaces/IMsgSender.sol";
import {Errors} from "./libraries/Errors.sol";
import {MarketHandlerLib} from "./libraries/MarketHandlerLib.sol";

contract ProxyHook is BaseHook, VaultCoreActionHandler {
    using CurrencySettler for Currency;
    address internal constant RECIPIENT_LOCKER = address(1);
    address internal constant RECIPIENT_ROUTER = address(2);

    /// @dev Context for proxy swap operations to reduce stack depth
    struct ProxySwapContext {
        bool coreZeroForOne;
        ILCC lccTokenForCurrency0;
        ILCC lccTokenForCurrency1;
        Currency lccCurrencyForCurrency0;
        Currency lccCurrencyForCurrency1;
        uint160 sqrtPriceLimitX96Core;
    }

    address public coreHook; // specific to proxy hook.

    PoolKey public corePoolKey;

    PoolKey public proxyPoolKey;

    constructor(address _poolManager, address _marketFactory)
        BaseHook(IPoolManager(_poolManager))
        VaultCoreActionHandler(_marketFactory)
    {}

    function _underlying() internal view override returns (Currency currency0, Currency currency1) {
        return (proxyPoolKey.currency0, proxyPoolKey.currency1);
    }

    function _lccs() internal view override returns (ILCC lccToken0, ILCC lccToken1) {
        return (ILCC(Currency.unwrap(corePoolKey.currency0)), ILCC(Currency.unwrap(corePoolKey.currency1)));
    }

    function _marketId() internal view override returns (bytes32) {
        return PoolId.unwrap(corePoolKey.toId());
    }

    function _corePoolKey() internal view override returns (PoolKey memory) {
        return corePoolKey;
    }

    function _coreHook() internal view override returns (address) {
        return coreHook;
    }

    function activate() external onlyFactory {
        if (coreHook == address(0)) {
            coreHook = MarketHandlerLib.getCoreHook(marketFactory);
        }
    }

    /**
     * @dev Updates the core pool key with the actual core pool configuration
     * @param newCorePoolKey The actual core pool key to set
     */
    function setCorePoolKey(PoolKey calldata newCorePoolKey) external onlyFactory {
        // An uninitialised PoolKey encodes to a non-zero id via keccak256,
        // so we must not use toId() to detect initialisation. Instead, rely on hooks address.
        if (address(corePoolKey.hooks) != address(0)) {
            revert Errors.CorePoolKeyAlreadySet();
        }
        corePoolKey = newCorePoolKey;
    }

    /**
     * @dev Returns the core pool id
     * @return The core pool id
     */
    function getCorePoolId() public view returns (PoolId) {
        return corePoolKey.toId();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
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

    function _beforeInitialize(address sender, PoolKey calldata key, uint160)
        internal
        virtual
        override
        onlyFactoryWithSender(sender)
        returns (bytes4)
    {
        proxyPoolKey = key;
        // initialise the counterparty hook -- proxy pool is created after the core pool.
        // Note: This is a placeholder for future implementation
        // The core hook reference is already set in constructor

        return this.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        virtual
        override
        returns (bytes4)
    {
        revert Errors.AddLiquidityThroughHookNotAllowed();
    }

    /// @dev Builds the proxy swap context (LCC mappings and direction)
    function _buildSwapContext(PoolKey calldata key, bool paramsZeroForOne)
        private
        view
        returns (ProxySwapContext memory ctx)
    {
        PoolKey memory coreKey = corePoolKey;
        ILCC coreLccToken0 = ILCC(Currency.unwrap(coreKey.currency0));
        ILCC coreLccToken1 = ILCC(Currency.unwrap(coreKey.currency1));

        // Determine if proxy direction matches core direction
        // Safe because `key` is provided by PoolManager for *this* proxy pool, whose currencies are the two
        // underlyings of the core LCC pair (sorted by Uniswap PoolKey rules). Therefore `key.currency0/1` must be
        // either (u0,u1) or (u1,u0) for (coreLccToken0.underlying(), coreLccToken1.underlying()).
        ctx.coreZeroForOne = (Currency.unwrap(key.currency0) == coreLccToken0.underlying()
                    && Currency.unwrap(key.currency1) == coreLccToken1.underlying())
            ? paramsZeroForOne
            : !paramsZeroForOne;

        // Map LCC tokens based on direction alignment
        bool aligned = paramsZeroForOne == ctx.coreZeroForOne;
        ctx.lccTokenForCurrency0 = aligned ? coreLccToken0 : coreLccToken1;
        ctx.lccTokenForCurrency1 = aligned ? coreLccToken1 : coreLccToken0;
        ctx.lccCurrencyForCurrency0 = Currency.wrap(address(ctx.lccTokenForCurrency0));
        ctx.lccCurrencyForCurrency1 = Currency.wrap(address(ctx.lccTokenForCurrency1));
    }

    /// @dev Calculates the adjusted sqrt price limit for the core pool when direction is flipped.
    ///      The mapped value is clamped into the strict open interval expected by v4 core.
    function _calcCoreSqrtPriceLimit(uint160 sqrtPriceLimitX96, bool flipped, bool coreZeroForOne)
        internal
        pure
        returns (uint160)
    {
        if (!flipped) return sqrtPriceLimitX96;

        uint160 minValid = TickMath.MIN_SQRT_PRICE + 1;
        uint160 maxValid = TickMath.MAX_SQRT_PRICE - 1;

        // Direction-aware "no limit" default in flipped markets.
        if (sqrtPriceLimitX96 == 0) return coreZeroForOne ? minValid : maxValid;

        // Preserve canonical extreme mapping exactly.
        if (sqrtPriceLimitX96 == minValid) return maxValid;
        if (sqrtPriceLimitX96 == maxValid) return minValid;

        uint160 inverted = uint160((uint256(1) << 192) / sqrtPriceLimitX96);
        if (inverted < minValid) return minValid;
        if (inverted > maxValid) return maxValid;
        return inverted;
    }

    /// @dev Handles LCC settlement for zeroForOne swap direction
    function _settleZeroForOne(
        PoolKey calldata key,
        ProxySwapContext memory ctx,
        uint256 amountIn,
        uint256 amountOut,
        address excessRecipient
    ) private returns (uint256 amountToSettle) {
        // Take underlying tokens from PoolManager as Claim Tokens
        key.currency0.take(poolManager, address(this), amountIn, true);

        // Mint and settle LCC tokens for input
        // Note: Proxy-routed issuance still does not mobilise reserve because ProxyHook issues pure market-derived LCC via LiquidityHub.issue().
        liquidityHub.issue(address(ctx.lccTokenForCurrency0), address(this), amountIn);
        ctx.lccCurrencyForCurrency0.settle(poolManager, address(this), amountIn, false);

        // Take LCC tokens for output
        ctx.lccCurrencyForCurrency1.take(poolManager, address(this), amountOut, false);

        // Cancel LCC with deficit handling
        amountToSettle = _cancelLCCWithDeficit(key.toId(), ctx.lccTokenForCurrency1, amountOut, excessRecipient);

        // Settle output token
        key.currency1.settle(poolManager, address(this), amountToSettle, true);

        // Settle obligations
        _settleObligationsForLCC(ctx.lccTokenForCurrency0);
    }

    /// @dev Handles LCC settlement for oneForZero swap direction
    function _settleOneForZero(
        PoolKey calldata key,
        ProxySwapContext memory ctx,
        uint256 amountIn,
        uint256 amountOut,
        address excessRecipient
    ) private returns (uint256 amountToSettle) {
        // Take underlying tokens from PoolManager
        key.currency1.take(poolManager, address(this), amountIn, true);

        // Mint and settle LCC tokens for input
        liquidityHub.issue(address(ctx.lccTokenForCurrency1), address(this), amountIn);
        ctx.lccCurrencyForCurrency1.settle(poolManager, address(this), amountIn, false);

        // Take LCC tokens for output
        ctx.lccCurrencyForCurrency0.take(poolManager, address(this), amountOut, false);

        // Cancel LCC with deficit handling
        amountToSettle = _cancelLCCWithDeficit(key.toId(), ctx.lccTokenForCurrency0, amountOut, excessRecipient);

        // Settle output token
        key.currency0.settle(poolManager, address(this), amountToSettle, true);

        // Settle obligations
        _settleObligationsForLCC(ctx.lccTokenForCurrency1);
    }

    // Proxy swaps route through the core pool and return a delta that cancels proxy `amountToSwap` to zero.
    // This enforces the MKT-05 invariant that the proxy pool AMM curve is never executed.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        noCoreAction
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _assertSupportedExactInputAmount(params.amountSpecified);

        (address excessRecipient, bool recipientResolved) = _determineExcessRecipient(sender, hookData);

        // Build swap context with LCC mappings
        ProxySwapContext memory ctx = _buildSwapContext(key, params.zeroForOne);

        // Calculate adjusted sqrt price limit
        ctx.sqrtPriceLimitX96Core = _calcCoreSqrtPriceLimit(
            params.sqrtPriceLimitX96, params.zeroForOne != ctx.coreZeroForOne, ctx.coreZeroForOne
        );

        uint256 maxOutputAvailable = inMarketBalanceOf(params.zeroForOne ? key.currency1 : key.currency0);

        (uint256 amountIn, uint256 amountToSettle) =
            _executeProxySwap(key, params, ctx, excessRecipient, recipientResolved, maxOutputAvailable);

        // Build return delta
        BeforeSwapDelta newDelta = (params.amountSpecified < 0)
            ? toBeforeSwapDelta(SafeCast.toInt128(amountIn), -SafeCast.toInt128(amountToSettle))
            : toBeforeSwapDelta(-SafeCast.toInt128(amountToSettle), SafeCast.toInt128(amountIn));

        return (this.beforeSwap.selector, newDelta, 0);
    }

    function _assertSupportedExactInputAmount(int256 amountSpecified) private pure {
        if (amountSpecified < 0) {
            int256 minSupported = -int256(type(int128).max);
            if (amountSpecified < minSupported) {
                revert Errors.UnsupportedExactInputAmount(amountSpecified, minSupported, -1);
            }
        }
    }

    function _executeProxySwap(
        PoolKey calldata key,
        SwapParams calldata params,
        ProxySwapContext memory ctx,
        address excessRecipient,
        bool recipientResolved,
        uint256 maxOutputAvailable
    ) private returns (uint256 amountIn, uint256 amountToSettle) {
        // Option A default: execute full core swap (no capping / scaling).
        SwapParams memory coreSwapParams = SwapParams({
            zeroForOne: ctx.coreZeroForOne,
            amountSpecified: params.amountSpecified,
            sqrtPriceLimitX96: ctx.sqrtPriceLimitX96Core
        });

        _assertExactOutputAvailable(params.amountSpecified, maxOutputAvailable);

        uint256 amountOut;
        (amountIn, amountOut) = _executeCoreSwap(coreSwapParams, ctx.coreZeroForOne);

        _assertExactInputAfterCoreSwap(
            params.amountSpecified, recipientResolved, amountIn, amountOut, maxOutputAvailable
        );

        // Handle LCC settlement based on direction.
        address deficitRecipient = recipientResolved ? excessRecipient : address(0);
        amountToSettle = _settleFromCoreSwap(key, params.zeroForOne, ctx, amountIn, amountOut, deficitRecipient);

        if (params.amountSpecified > 0 && amountToSettle != uint256(params.amountSpecified)) {
            revert Errors.InsufficientLiquidity(uint256(params.amountSpecified), amountToSettle);
        }
    }

    function _assertExactOutputAvailable(int256 amountSpecified, uint256 maxOutputAvailable) private pure {
        // Strict exact-output behaviour: if underlying output cannot be delivered in full, revert.
        if (amountSpecified > 0) {
            uint256 requestedOutput = uint256(amountSpecified);
            if (requestedOutput > maxOutputAvailable) {
                revert Errors.InsufficientLiquidity(requestedOutput, maxOutputAvailable);
            }
        }
    }

    function _executeCoreSwap(SwapParams memory coreSwapParams, bool coreZeroForOne)
        private
        returns (uint256 amountIn, uint256 amountOut)
    {
        BalanceDelta delta = poolManager.swap(corePoolKey, coreSwapParams, bytes(""));
        amountIn = LiquidityUtils.safeInt128ToUint256(coreZeroForOne ? delta.amount0() : delta.amount1());
        amountOut = LiquidityUtils.safeInt128ToUint256(coreZeroForOne ? delta.amount1() : delta.amount0());
    }

    function _assertExactInputAfterCoreSwap(
        int256 amountSpecified,
        bool recipientResolved,
        uint256 amountIn,
        uint256 amountOut,
        uint256 maxOutputAvailable
    ) private pure {
        // Enforce no residual proxy AMM swap path (`amountToSwap == 0` via specified-delta cancellation).
        if (amountSpecified < 0) {
            if (amountIn != uint256(-amountSpecified)) {
                revert Errors.InvariantViolated("ProxyHook: exact-input core fill mismatch");
            }

            // If locker cannot be resolved, only allow swaps that can settle fully into underlying (no deficit path).
            if (!recipientResolved && amountOut > maxOutputAvailable) {
                revert Errors.InsufficientLiquidity(amountOut, maxOutputAvailable);
            }
        }
    }

    function _settleFromCoreSwap(
        PoolKey calldata key,
        bool paramsZeroForOne,
        ProxySwapContext memory ctx,
        uint256 amountIn,
        uint256 amountOut,
        address deficitRecipient
    ) private returns (uint256 amountToSettle) {
        return paramsZeroForOne
            ? _settleZeroForOne(key, ctx, amountIn, amountOut, deficitRecipient)
            : _settleOneForZero(key, ctx, amountIn, amountOut, deficitRecipient);
    }

    /**
     * @notice Extracts the expected output amount from a swap simulation delta
     * @param swapDelta The balance delta from swap simulation
     * @param zeroForOne The swap direction
     * @return expectedOutput The expected output amount
     */
    function _getExpectedOutputFromDelta(BalanceDelta swapDelta, bool zeroForOne)
        internal
        pure
        returns (uint256 expectedOutput)
    {
        if (zeroForOne) {
            // Token0 -> Token1: output is amount1 (positive in delta)
            expectedOutput = LiquidityUtils.safeInt128ToUint256(swapDelta.amount1());
        } else {
            // Token1 -> Token0: output is amount0 (positive in delta)
            expectedOutput = LiquidityUtils.safeInt128ToUint256(swapDelta.amount0());
        }
    }

    function _getExpectedInputFromDelta(BalanceDelta swapDelta, bool zeroForOne)
        internal
        pure
        returns (uint256 expectedInput)
    {
        if (zeroForOne) {
            expectedInput = LiquidityUtils.safeInt128ToUint256(-swapDelta.amount0());
        } else {
            expectedInput = LiquidityUtils.safeInt128ToUint256(-swapDelta.amount1());
        }
    }

    // Determine the excess recipient for a given swap with overflow.
    // Defaults to locker when hookData is empty or explicitly encodes address(0)/address(1).
    function _determineExcessRecipient(address sender, bytes calldata hookData)
        internal
        view
        returns (address recipient, bool resolved)
    {
        recipient = hookData.length == 0 ? RECIPIENT_LOCKER : abi.decode(hookData, (address));

        if (recipient == address(0) || recipient == RECIPIENT_LOCKER) {
            return _resolveLocker(sender);
        }
        if (recipient == RECIPIENT_ROUTER) {
            return (sender, sender != address(0));
        }
        return (recipient, true);
    }

    function _resolveLocker(address sender) internal view returns (address locker, bool resolved) {
        if (sender == address(0)) return (address(0), false);
        (bool ok, bytes memory data) = sender.staticcall(abi.encodeWithSelector(IMsgSender.msgSender.selector));
        if (!ok || data.length < 32) return (address(0), false);
        address got = abi.decode(data, (address));
        if (got == address(0)) return (address(0), false);
        return (got, true);
    }
}

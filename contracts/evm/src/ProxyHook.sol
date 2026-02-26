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
import {MarketVault} from "./modules/MarketVault.sol";
import {ProxySwapFlag} from "./libraries/ProxySwapFlag.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {Exttload} from "v4-periphery/lib/v4-core/src/Exttload.sol";
import {IMsgSender} from "v4-periphery/src/interfaces/IMsgSender.sol";
import {Errors} from "./libraries/Errors.sol";
import {MarketHandlerLib} from "./libraries/MarketHandlerLib.sol";

contract ProxyHook is BaseHook, MarketVault, Exttload {
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

    modifier onlyCoreHook() {
        MarketHandlerLib.assertCoreHook(marketFactory, msg.sender);
        _;
    }

    /**
     * @notice Modifier to automatically handle proxy swap flag management
     * @dev Sets the flag at the start and clears it at the end of the function
     */
    modifier withProxySwapFlag() {
        ProxySwapFlag.setProxySwapFlag();
        _;
        ProxySwapFlag.clearProxySwapFlag();
    }

    constructor(address _poolManager, address _marketFactory)
        BaseHook(IPoolManager(_poolManager))
        MarketVault(_marketFactory)
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

    function activate() external onlyFactory {
        if (coreHook == address(0)) {
            coreHook = MarketHandlerLib.getCoreHook(marketFactory);
        }
    }

    /**
     * @dev Updates the core pool key with the actual core pool configuration
     * @param _corePoolKey The actual core pool key to set
     */
    function setCorePoolKey(PoolKey calldata _corePoolKey) external onlyFactory {
        // An uninitialised PoolKey encodes to a non-zero id via keccak256,
        // so we must not use toId() to detect initialisation. Instead, rely on hooks address.
        if (address(corePoolKey.hooks) != address(0)) {
            revert Errors.CorePoolKeyAlreadySet();
        }
        corePoolKey = _corePoolKey;
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

    /**
     * @notice Called by `CoreHook` after direct liquidity is added to the CORE pool.
     * @dev This is only required for DIRECT-LP ADDS (not removes). We settle underlying from Hub -> Vault so that
     *      subsequent proxy-pool swaps can source underlying at a 1:1 against LCC.
     *      Direct-LP REMOVES are handled via the unwrap pathway (market-derived LCC unwrap calls market liquidity).
     */
    function onDirectLP(BalanceDelta delta) external virtual onlyCoreHook {
        ILCC lccToken0 = ILCC(Currency.unwrap(corePoolKey.currency0));
        ILCC lccToken1 = ILCC(Currency.unwrap(corePoolKey.currency1));

        uint256 amount0 = LiquidityUtils.safeInt128ToUint256(delta.amount0());
        uint256 amount1 = LiquidityUtils.safeInt128ToUint256(delta.amount1());

        // Settle underlying liquidity to the vault from the LCCs that were acquired.
        if (amount0 > 0) {
            _settleUnderlyingToVaultFromHub(lccToken0, amount0);
        }
        if (amount1 > 0) {
            _settleUnderlyingToVaultFromHub(lccToken1, amount1);
        }

        // Best-effort: take what is available within the total settlement deficit amount from the vault to LiquidityHub.
        // This fulfils some accounting mechanics when DirectLPs add liquidity.
        _settleObligations(corePoolKey);
    }

    /**
     * @dev This function is called by the CoreHook to handle a direct swap i.e a swap on the core pool that was not initiated from the proxy pool
     *      This ensures that the underlying liquidity is moved from the LCC's to the proxy pool at a 1:1 ratio
     * @param delta The delta of the swap
     */
    function onCorePoolDirectSwap(BalanceDelta delta) external virtual onlyCoreHook {
        // If this flag is set, then the swap was initiated by ProxyHook (proxy-pool swap),
        // and CoreHook's afterSwap notification must not recurse into this handler.
        bool isDirectSwap = ProxySwapFlag.isDirectSwap();
        if (!isDirectSwap) {
            return;
        }

        // Check if this is a zero one swap or one for zero swap
        bool isZeroForOne = delta.amount0() < 0;

        // Get the amount of the token that is being swapped in based on if this is a zero one swap or one for zero swap
        uint256 amount0 = LiquidityUtils.safeInt128ToUint256(delta.amount0());
        uint256 amount1 = LiquidityUtils.safeInt128ToUint256(delta.amount1());

        // Get the LCC tokens for the core pool
        ILCC lccToken0 = ILCC(Currency.unwrap(corePoolKey.currency0));
        ILCC lccToken1 = ILCC(Currency.unwrap(corePoolKey.currency1));

        // Handle Token IN liquidity (move underlying from Hub -> Vault/PoolManager).
        ILCC lccTokenIn = isZeroForOne ? lccToken0 : lccToken1;
        uint256 amountIn = isZeroForOne ? amount0 : amount1;
        _settleUnderlyingToVaultFromHub(lccTokenIn, amountIn);

        // Underlying liquidity for token-out is sourced on unwrap via market liquidity.

        // New liquidity in pool, so we try and settle the outstanding obligations, if any
        _settleObligationsForLCC(lccTokenIn);
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

    /// @dev Calculates the adjusted sqrt price limit for the core pool when direction is flipped
    function _calcCoreSqrtPriceLimit(uint160 sqrtPriceLimitX96, bool flipped) internal pure returns (uint160) {
        if (!flipped) return sqrtPriceLimitX96;

        if (sqrtPriceLimitX96 == TickMath.MIN_SQRT_PRICE + 1) {
            return TickMath.MAX_SQRT_PRICE - 1;
        } else if (sqrtPriceLimitX96 == TickMath.MAX_SQRT_PRICE - 1) {
            return TickMath.MIN_SQRT_PRICE + 1;
        } else if (sqrtPriceLimitX96 != 0) {
            return uint160((uint256(1) << 192) / sqrtPriceLimitX96);
        } else {
            return TickMath.MAX_SQRT_PRICE - 1;
        }
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
        withProxySwapFlag
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (address excessRecipient, bool recipientResolved) = _determineExcessRecipient(sender, hookData);

        // Build swap context with LCC mappings
        ProxySwapContext memory ctx = _buildSwapContext(key, params.zeroForOne);

        // Calculate adjusted sqrt price limit
        ctx.sqrtPriceLimitX96Core =
            _calcCoreSqrtPriceLimit(params.sqrtPriceLimitX96, params.zeroForOne != ctx.coreZeroForOne);

        uint256 maxOutputAvailable = inMarketBalanceOf(params.zeroForOne ? key.currency1 : key.currency0);

        (uint256 amountIn, uint256 amountToSettle) =
            _executeProxySwap(key, params, ctx, excessRecipient, recipientResolved, maxOutputAvailable);

        // Build return delta
        BeforeSwapDelta newDelta = (params.amountSpecified < 0)
            ? toBeforeSwapDelta(SafeCast.toInt128(amountIn), -SafeCast.toInt128(amountToSettle))
            : toBeforeSwapDelta(-SafeCast.toInt128(amountToSettle), SafeCast.toInt128(amountIn));

        return (this.beforeSwap.selector, newDelta, 0);
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

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
import {ILCC} from "./interfaces/ILCC.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {UnsafeMath} from "@uniswap/v4-core/src/libraries/UnsafeMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {SwapSimulator} from "./libraries/SwapSimulator.sol";
import {MarketVault} from "./modules/MarketVault.sol";
import {ProxySwapFlag} from "./libraries/ProxySwapFlag.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {Exttload} from "v4-periphery/lib/v4-core/src/Exttload.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {PositionId} from "./types/Position.sol";
import {IVTSManager} from "./interfaces/IVTSManager.sol";
import {console} from "forge-std/console.sol";

contract ProxyHook is BaseHook, MarketVault, Exttload {
    using CurrencySettler for Currency;

    error AddLiquidityThroughHookNotAllowed();
    error InvalidInitialiser();
    error InvalidCurrency(address currency);
    error InvalidDeficitRecipient();

    struct LiquidityCallbackData {
        uint256 amount0;
        uint256 amount1;
        Currency currency0;
        Currency currency1;
        address poolManager;
        LiquidityUtils.ActionType actionType;
    }

    event SwapDeficit(
        PoolId indexed poolId, PoolId corePoolId, address lccToken, address deficitRecipient, uint256 deficitAmount
    );

    address public immutable marketFactory;

    address public coreHook; // specific to proxy hook.

    PoolKey public corePoolKey;

    PoolKey public proxyPoolKey;

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
        MarketVault(IPoolManager(_poolManager))
    {
        marketFactory = _marketFactory;
    }

    function activate() external onlyFactory {
        coreHook = IMarketFactory(marketFactory).getCoreHook();
    }

    /**
     * @dev Updates the core pool key with the actual core pool configuration
     * @param _corePoolKey The actual core pool key to set
     */
    function setCorePoolKey(PoolKey calldata _corePoolKey) external onlyFactory {
        corePoolKey = _corePoolKey;
    }

    /**
     * @dev This is what the ProxyHook can actually withdraw from the pool manager (its "credits")
     * @dev It is our account balance against a currency in the pool manager
     */
    function _getCurrencyAvailableLiquidity(Currency currency) internal view returns (uint256) {
        // ProxyHook's ERC-6909 claim token balance for this currency
        return poolManager.balanceOf(address(this), currency.toId());
    }

    /**
     * @dev This is what the ProxyHook can actually withdraw from the pool manager (its "credits")
     * @dev It is our account balance against a currency in the pool manager
     */
    function getAvailableLiquidity(address currencyAddress) external view returns (uint256) {
        // ProxyHook's ERC-6909 claim token balance for this currency
        return _getCurrencyAvailableLiquidity(Currency.wrap(currencyAddress));
    }

    /**
     * @dev Returns the core pool id
     * @return The core pool id
     */
    function getCorePoolId() external view returns (PoolId) {
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
        returns (bytes4)
    {
        if (sender != marketFactory) {
            revert InvalidInitialiser();
        }
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
        revert AddLiquidityThroughHookNotAllowed();
    }

    // Method called by the Core Hook notifying that Direct Liquidity Provision occurred.
    // Liquidity is managed by the Proxy Hook here to ensure PM credits the Proxy Hook (msg.sender) with relevant Currency Delta.
    // THIS IS ALREADY UNLOCKED FOR DIRECT LP ON CORE POOL.
    function onDirectLP(BalanceDelta delta, LiquidityUtils.ActionType actionType) external virtual onlyCoreHook {
        ILCC lccToken0 = ILCC(payable(Currency.unwrap(corePoolKey.currency0)));
        ILCC lccToken1 = ILCC(payable(Currency.unwrap(corePoolKey.currency1)));

        uint256 amount0 = LiquidityUtils.safeInt128ToUint256(delta.amount0());
        uint256 amount1 = LiquidityUtils.safeInt128ToUint256(delta.amount1());

        if (actionType == LiquidityUtils.ActionType.DirectLPAddLiquidity) {
            // Add liquidity to the core pool
            // Since we didn't go through the regular "modify liquidity" flow,
            // the PM just has a debit of `amount` of each currency from us
            // We can, in exchange, get back ERC-6909 claim tokens for `amount`
            // to create a credit of `amount` of each currency to us that balances out the debit

            // We will store those claim tokens with the hook, so when swaps take place
            // liquidity from our CSMM can be used by minting/burning claim tokens the hook owns

            // Settle underlying liquidity to the vault from the LCCs that were acquired.
            _settleFromLCCToVault(lccToken0, amount0);
            _settleFromLCCToVault(lccToken1, amount1);

            // Then we take what is available within the total settlement deficit amount from the vault to LCCs.
            // This fulfils some accounting mechanics when DirectLPs add liquidity.
            _settleObligations(corePoolKey);
        } else if (actionType == LiquidityUtils.ActionType.DirectLPRemoveLiquidity) {
            // 1. Remove LCCs from the Core Pool
            // 2. Move the underlying tokens from the vault to the LCCs
            // 3. Notify the LCCs about the new balance

            // Try take from vault to LCCs. If there's a deficit, it will surface in settlement queue to the DirectLP on LCC unwrap.
            bytes32 marketId = PoolId.unwrap(corePoolKey.toId());
            _tryTakeFromVaultToLCC(marketId, lccToken0, amount0);
            _tryTakeFromVaultToLCC(marketId, lccToken1, amount1);
        }
    }

    /**
     * @dev This function is called by the MMPositionManager to add liquidity directly to the vault
     * @param currency0 The currency0 to add to the vault
     * @param currency1 The currency1 to add to the vault
     * @param balanceDelta The balance delta of the currency0 and currency1
     */
    function onMMLiquidityModify(address currency0, address currency1, BalanceDelta balanceDelta) external {
        address mmpmAddr = IMarketFactory(marketFactory).mmPositionManager();
        if (msg.sender != mmpmAddr) {
            revert InvalidSender();
        }
        // make sure both currencies are valid for this proxy hook
        // i.e make sure both currencies are either currency0 or currency1 of the proxy pool key
        // to ensure we do not add liquidity to the vault with an invalid currency
        if (
            Currency.unwrap(proxyPoolKey.currency0) != currency0 && Currency.unwrap(proxyPoolKey.currency1) != currency0
        ) {
            revert InvalidCurrency(currency0);
        }
        if (
            Currency.unwrap(proxyPoolKey.currency0) != currency1 && Currency.unwrap(proxyPoolKey.currency1) != currency1
        ) {
            revert InvalidCurrency(currency1);
        }
        // add the assets to the pool manager and claim the underlying tokens for the proxy hook
        _modifyVaultLiquidity(currency0, currency1, balanceDelta);
        // if there was an addition, then settle the obligations to the lcc tokens
        if (balanceDelta.amount0() > 0 || balanceDelta.amount1() > 0) {
            _settleObligations(corePoolKey);
        }
    }

    /**
     * @dev This function is called by the CoreHook to handle a direct swap i.e a swap on the core pool that was not initiated from the proxy pool
     *      This ensures that the underlying liquidity is moved from the LCC's to the proxy pool at a 1:1 ratio
     * @param delta The delta of the swap
     */
    function onCorePoolDirectSwap(BalanceDelta delta) external virtual onlyCoreHook {
        // if this flag is not set, then it means that this is a direct swap
        bool isDirectSwap = ProxySwapFlag.isDirectSwap();
        // if this is not a direct swap, then we need to return because we dont want to touch swaps initiated by the proxy hook
        // ? the way the flag is set up, every swap is a direct swap by default, unless the ProxySwapFlag flag is set by the proxy hook to indicate it has an ongoing swap
        // ? it is currently set in the _beforeSwap function of the proxy hook making sure it is set and cleared during a swap initiated by the proxy hook
        if (!isDirectSwap) {
            return;
        }

        // if this is a direct swap, then we need to run the direct swap logic
        // this is a direct swap logic
        // 1. take the underlying tokens from the pool manager
        // 2. mint the lcc tokens for the input amount (this is the input amount)
        // 3. settle the lcc tokens to the pool manager
        // 4. take the lcc tokens of the output amount from the pool manager
        // 5. cancel the lcc tokens of the output amount
        // 6. settle the output token to the pool manager
        // 7. return the output token to the user
        // Handle LCC underlying liquidity management for direct swaps
        // LCC underlying liquidity for Token IN is moved "in-market" — to the PoolManager via Proxy Hook
        // LCC underlying liquidity for Token OUT attempts to move from "in-market" into relevant LCC

        // Check if this is a zero one swap or one for zero swap
        bool isZeroForOne = delta.amount0() < 0;

        // Get the amount of the token that is being swapped in based on if this is a zero one swap or one for zero swap
        uint256 amount0 = LiquidityUtils.safeInt128ToUint256(delta.amount0());
        uint256 amount1 = LiquidityUtils.safeInt128ToUint256(delta.amount1());

        // Get the LCC tokens for the core pool
        ILCC lccToken0 = ILCC(payable(Currency.unwrap(corePoolKey.currency0)));
        ILCC lccToken1 = ILCC(payable(Currency.unwrap(corePoolKey.currency1)));

        // Handle Token IN liquidity (move to PoolManager from lcc token)
        ILCC lccTokenIn = isZeroForOne ? lccToken0 : lccToken1;
        // Get the amount of the token that is being swapped in based on if this is a zero one swap or one for zero swap
        uint256 amountIn = isZeroForOne ? amount0 : amount1;
        // Deposit underlying liquidity to pool manager from lcc token
        _settleFromLCCToVault(lccTokenIn, amountIn);

        // Handle Token OUT liquidity (move from PoolManager into LCC token) or add to queue when there is not enough liquidity
        ILCC lccTokenOut = isZeroForOne ? lccToken1 : lccToken0;
        // Get the amount of the token that is being swapped in based on if this is a zero one swap or one for zero swap
        uint256 amountOut = isZeroForOne ? amount1 : amount0;

        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());
        _tryTakeFromVaultToLCC(marketId, lccTokenOut, amountOut);

        // New liquidity in pool, so we try and settle the outstanding obligations, if any
        _settleObligations(corePoolKey);
    }

    // Before swap we make sure to provide enough delta
    // to ensure that the user gets a debit of amount specified
    // and we disable the core swap mechanism
    // and proxy the swap through the core pool
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        withProxySwapFlag
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address excessRecipient = _determineExcessRecipient(hookData);
        bool isHookExcessRecipientSpecified = excessRecipient != address(0);

        uint256 maxOutputTokenAvailable =
            _getCurrencyAvailableLiquidity(params.zeroForOne ? key.currency1 : key.currency0);
        // console.log("Max token output available: ", maxOutputTokenAvailable);

        bool coreZeroForOne;
        PoolKey memory coreKey = corePoolKey;

        ILCC lccToken0 = ILCC(payable(Currency.unwrap(coreKey.currency0)));
        ILCC lccToken1 = ILCC(payable(Currency.unwrap(coreKey.currency1)));

        if (
            Currency.unwrap(key.currency0) == lccToken0.underlyingAsset()
                && Currency.unwrap(key.currency1) == lccToken1.underlyingAsset()
        ) {
            // If tokens match order, then Proxy matches Core
            coreZeroForOne = params.zeroForOne;
        } else {
            // If tokens do not match order, then Proxy inverts Core
            coreZeroForOne = !params.zeroForOne;
        }

        // If zeroForOne match, then lccTokenForCurrency0 is lccToken0 and lccTokenForCurrency1 is lccToken1
        // If zeroForOne does not match, then lccTokenForCurrency0 is lccToken1 and lccTokenForCurrency1 is lccToken0
        ILCC lccTokenForCurrency0 = params.zeroForOne == coreZeroForOne ? lccToken0 : lccToken1;
        ILCC lccTokenForCurrency1 = params.zeroForOne == coreZeroForOne ? lccToken1 : lccToken0;
        Currency lccCurrencyForCurrency0 = Currency.wrap(address(lccTokenForCurrency0));
        Currency lccCurrencyForCurrency1 = Currency.wrap(address(lccTokenForCurrency1));

        // Calculate the correct sqrtPriceLimitX96 for the core pool
        uint160 sqrtPriceLimitX96_core = params.sqrtPriceLimitX96;
        bool flipped = params.zeroForOne != coreZeroForOne;
        if (flipped) {
            if (sqrtPriceLimitX96_core == TickMath.MIN_SQRT_PRICE + 1) {
                sqrtPriceLimitX96_core = TickMath.MAX_SQRT_PRICE - 1;
            } else if (sqrtPriceLimitX96_core == TickMath.MAX_SQRT_PRICE - 1) {
                sqrtPriceLimitX96_core = TickMath.MIN_SQRT_PRICE + 1;
            } else if (sqrtPriceLimitX96_core != 0) {
                sqrtPriceLimitX96_core = uint160((uint256(1) << 192) / sqrtPriceLimitX96_core);
            } else {
                // If somehow 0 (though router overrides), set unbounded for flipped
                sqrtPriceLimitX96_core = TickMath.MAX_SQRT_PRICE - 1;
            }
        }

        // Conduct the swap inside the Pool Manager

        // ? The wisest approach is to only swap what is settled by default.
        // ? If hookData exists, then we can swap the full amount specified.
        // As per V4Router.sol - if we settle excess LCC from this hook, there's no guarantee it'll be taken by the msgSender()/Locker
        // Further, once the lock settles, then the deltas renew an the PoolManager will have excess LCC that has not been settled.

        // We could technically attempt to send the excess LCC to the msgSender()/Locker... but this will not work if Action.TAKE uses a custom recipient.
        // However, if recipient is passed inside of the hookData, then we send the excess there?
        // Problem here is that if hookData is not passed, then the Router will receive the excess LCC.
        // Therefore by default we just refund unless the hookData recipient exists...
        // https://github.com/Uniswap/v4-periphery/blob/444c526b77d804590f0d7bc5a481af5a3277c952/src/V4Router.sol#L71
        // Any caller that is aware of LCCs will execute a swap directly on the core pool...

        // That will affect the return delta of the core pool, and therefore the values downstream.
        // ? This problem could be solved through transient storage.

        SwapParams memory coreSwapParams;
        if (isHookExcessRecipientSpecified) {
            coreSwapParams = SwapParams({
                zeroForOne: coreZeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96_core
            });
        } else {
            // * If not excess recipient, then perform restricted swap on native (underlying asset) liquidity
            // Fast-path bound check at current price to avoid simulation when clearly safe
            uint256 outUpper = _upperBoundOutAtCurrentPrice(coreKey, params.amountSpecified, coreZeroForOne);
            if (outUpper <= maxOutputTokenAvailable) {
                coreSwapParams = SwapParams({
                    zeroForOne: coreZeroForOne,
                    amountSpecified: params.amountSpecified,
                    sqrtPriceLimitX96: sqrtPriceLimitX96_core
                });
            } else {
                coreSwapParams = _adjustSwapParamsForAvailableLiquidity(
                    SwapParams({
                        zeroForOne: coreZeroForOne,
                        amountSpecified: params.amountSpecified,
                        sqrtPriceLimitX96: sqrtPriceLimitX96_core
                    }),
                    corePoolKey,
                    maxOutputTokenAvailable
                );
            }
        }

        BalanceDelta delta = poolManager.swap(coreKey, coreSwapParams, bytes(""));

        // console.log("Core Pool Delta amount0: ", delta.amount0());
        // console.log("Core Pool Delta amount1: ", delta.amount1());
        // console.log("coreZeroForOne: ", coreZeroForOne);
        // console.log("params.zeroForOne: ", params.zeroForOne);

        /// The desired input amount and output amount
        // the deltas should be the source of truth since input and output amounts are potentially modified if no hook data is provided
        uint256 amountIn = LiquidityUtils.safeInt128ToUint256(coreZeroForOne ? delta.amount0() : delta.amount1());
        uint256 amountOut = LiquidityUtils.safeInt128ToUint256(coreZeroForOne ? delta.amount1() : delta.amount0());
        bool isExactInput = params.amountSpecified < 0;

        // console.log("amountIn: ", amountIn / 1e18);
        // console.log("amountOut: ", amountOut / 1e18);

        uint256 amountToSettle;

        if (params.zeroForOne) {
            // If user is selling Token 0 and buying Token 1

            // Take the underlying tokens from PoolManager as Claim Tokens... the underlying liquidity remains in the Pool Manager...
            key.currency0.take(poolManager, address(this), amountIn, true);

            // Mint LCC tokens for the input amount
            // These LCC tokens are collateralised by liquidity that remains in the Pool Manager.
            lccTokenForCurrency0.issue(amountIn);

            // Settle minted LCC tokens to the PoolManager
            // Accounts for LCC of 0 IN for the Core Pool Swap
            lccCurrencyForCurrency0.settle(poolManager, address(this), amountIn, false);

            // if amount out greateer
            // Take LCC tokens of Token 1 from PoolManager
            // Accounts for LCC of 1 OUT for the Core Pool Swap
            lccCurrencyForCurrency1.take(poolManager, address(this), amountOut, false);

            // Unwrap and Burn the LCC of Token 1 after taking from PM

            // * With excess LCC: Trader always deposits correct amount of params.amountSpecified. However, the counterparty side could have insufficent liquidity.
            // * In this case, the deficit is the amount of LCC that the counterparty side does not have.
            // * This deficit is then distributed to the excessRecipient.
            // * The excessRecipient is either specified, the Locker or the msg.sender.
            // This excess functionality is Proxy Pool specific.
            amountToSettle = _cancelLCCWithDeficit(key, lccTokenForCurrency1, amountOut, excessRecipient);

            // Settle the output token to the PoolManager
            // Burn claim tokens to release output token to the Trader from the PoolManager.
            // ? amountOut can be greater than total amount of underlying asset in PoolManager.
            // ? In this case, there is insufficient liquidity to settle amountOut of output token.
            key.currency1.settle(poolManager, address(this), amountToSettle, true);
        } else {
            key.currency1.take(poolManager, address(this), amountIn, true);

            // If user is selling Token 1 (IN) and buying Token 0 (OUT)
            // First mint LCC tokens for the input amount
            lccTokenForCurrency1.issue(amountIn);

            // Settle LCC tokens to the PoolManager
            lccCurrencyForCurrency1.settle(poolManager, address(this), amountIn, false);

            // Take LCC tokens of Token 0 from PoolManager
            // Accounts for LCC of 0 OUT for the Core Pool Swap
            lccCurrencyForCurrency0.take(poolManager, address(this), amountOut, false);

            // Cancel (Unwrap/Burn) the LCC of Token 0 after taking from PM
            amountToSettle = _cancelLCCWithDeficit(key, lccTokenForCurrency0, amountOut, excessRecipient);

            // Settle the output token to the PoolManager
            // Burn claim tokens to release output token to the Trader from the PoolManager.
            key.currency0.settle(poolManager, address(this), amountToSettle, true);
        }

        // BalanceDelta is a packed value of (currency0Amount, currency1Amount)

        // BeforeSwapDelta varies such that it is not sorted by token0 and token1
        // Instead, it is sorted by "specifiedCurrency" and "unspecifiedCurrency"

        // Specified Currency => The currency in which the user is specifying the amount they're swapping for
        // Unspecified Currency => The other currency

        BeforeSwapDelta newDelta;

        if (isExactInput) {
            newDelta = toBeforeSwapDelta(
                // exactIn = positive, exactOut = negative - as hook takes input, and releases output.
                SafeCast.toInt128(amountIn),
                -SafeCast.toInt128(amountToSettle)
            );
        } else {
            newDelta = toBeforeSwapDelta(-SafeCast.toInt128(amountToSettle), SafeCast.toInt128(amountIn));
        }

        return (this.beforeSwap.selector, newDelta, 0); // last param is lpFeeOverride
    }

    function _cancelLCCWithDeficit(PoolKey calldata key, ILCC lccToken, uint256 amount, address deficitRecipient)
        internal
        returns (uint256 amountToCancel)
    {
        uint256 deficitAmount = 0;
        uint256 inCustody = _getCurrencyAvailableLiquidity(Currency.wrap(lccToken.underlyingAsset()));
        if (amount > inCustody) {
            amountToCancel = inCustody; // amount to cancel becomes what ever is in custody.
            deficitAmount = amount - inCustody; // deficit amount becomes the difference between the amount to cancel and the amount in custody.
        } else {
            amountToCancel = amount;
        }

        lccToken.cancel(amountToCancel); // we only cancel what native asset we distribute via the swap mechanism.

        if (deficitAmount > 0 && deficitRecipient != address(0)) {
            // ? we do not need to mint the full amount... because the ProxyHook will have already taken the full LCC amount from the PoolManager.
            // Furthermore, if we simply transfer to recipient, tracing should be triggered via the flag on afterSwap on Core Hook executed by the Proxy Hook.
            lccToken.toERC20().transfer(deficitRecipient, deficitAmount);
            emit SwapDeficit(key.toId(), corePoolKey.toId(), address(lccToken), deficitRecipient, deficitAmount);
        }
        // if deficit recipient is not specified, but a deficit > 0, then excess will accumulate. This means prior swap amount restriction must therefore be broken, which should never happen...
    }

    // Adjust the swap params to execute the swap to fully execute with the available liquidity
    // get the max underlying liquidity available on the market(proxyhook) for both currencies
    // simulate the swap and get the output and input from the returning deltas
    // if it is an exact output swap, then we need to check if the expected output is greater than the max output available for the currency
    // if it is an exact input swap, then we need to check if the expected output(from simulation) is greater than the max output available for the currency
    // if it is then we need to calcualte the exact input amount that is needed to get the max output available for the currency
    // then that would be the input amount for the swap to ensure we do not ever get more than the max liquidity available
    function _adjustSwapParamsForAvailableLiquidity(
        SwapParams memory params,
        PoolKey memory poolKey,
        uint256 outputAvailable
    ) internal view returns (SwapParams memory adjustedParams) {
        uint256 maxOutputAvailable = outputAvailable;
        bool isExactInput = params.amountSpecified < 0;
        uint256 originalAmount = uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified);

        // Exact output: no simulation needed, cap directly to available liquidity
        if (!isExactInput) {
            uint256 cappedOutput = Math.min(originalAmount, maxOutputAvailable);
            adjustedParams = SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: int256(cappedOutput),
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            });
            return adjustedParams;
        }

        // Exact input: single simulation to estimate output, then linear scale if needed
        (BalanceDelta swapDelta,,,) = SwapSimulator.simulateSwap(poolManager, poolKey, params);
        uint256 expectedOutput = _getExpectedOutputFromDelta(swapDelta, params.zeroForOne);

        if (expectedOutput > maxOutputAvailable) {
            uint256 scaledIn = Math.mulDiv(originalAmount, maxOutputAvailable, expectedOutput);
            // Optional conservative haircut to ensure we stay under available even with non-linearity
            if (scaledIn > 0) {
                scaledIn = (scaledIn * 999_000) / 1_000_000;
            }
            adjustedParams = SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: -int256(scaledIn),
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            });
        } else {
            adjustedParams = params;
        }
    }

    // Fast-path bound: upper bound on output at current price (ignoring tick crossing)
    function _upperBoundOutAtCurrentPrice(PoolKey memory coreKey, int256 amountSpecified, bool zeroForOne)
        internal
        view
        returns (uint256 outUpper)
    {
        // For exact output, the requested output itself is the bound
        if (amountSpecified > 0) {
            return uint256(amountSpecified);
        }

        (uint160 sqrtP,, uint24 protocolFee, uint24 lpFee) = StateLibrary.getSlot0(poolManager, coreKey.toId());
        uint24 swapFee = protocolFee == 0 ? lpFee : ProtocolFeeLibrary.calculateSwapFee(uint16(protocolFee), lpFee);
        uint256 feeDenom = ProtocolFeeLibrary.PIPS_DENOMINATOR;
        uint256 oneMinusFee = feeDenom - swapFee;
        uint256 absIn = uint256(-amountSpecified);

        // Start with fee-adjusted input
        uint256 adjIn = Math.mulDiv(absIn, oneMinusFee, feeDenom);
        uint256 Q96 = uint256(1) << 96;

        if (zeroForOne) {
            // out <= in * price => multiply by sqrtP twice, dividing by Q96 each time
            outUpper = Math.mulDiv(adjIn, uint256(sqrtP), Q96);
            outUpper = Math.mulDiv(outUpper, uint256(sqrtP), Q96);
        } else {
            // out <= in / price => divide by sqrtP twice, multiplying by Q96 each time
            outUpper = Math.mulDiv(adjIn, Q96, uint256(sqrtP));
            outUpper = Math.mulDiv(outUpper, Q96, uint256(sqrtP));
        }
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

    /**
     * @notice Calculates the input amount needed for a specific output amount
     * @param desiredOutput The desired output amount
     * @param zeroForOne The swap direction
     * @return inputNeeded The input amount needed as a positive number
     */
    function _calculateInputForExactOutput(
        IPoolManager pm,
        PoolKey memory poolKey,
        uint256 desiredOutput,
        bool zeroForOne
    ) internal view returns (uint256 inputNeeded) {
        // Create a swap simulation with the desired output
        SwapParams memory outputParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(desiredOutput), // Positive for exact output
            sqrtPriceLimitX96: zeroForOne ? LiquidityUtils.ZERO_FOR_ONE_LIMIT : LiquidityUtils.ONE_FOR_ZERO_LIMIT // No price limit for this calculation
        });

        // Simulate the swap to see how much input is needed
        (BalanceDelta swapDelta,,,) = SwapSimulator.simulateSwap(pm, poolKey, outputParams);

        // For Token0 -> Token1, input is amount0 (negative in delta)
        inputNeeded = LiquidityUtils.safeInt128ToUint256(zeroForOne ? -swapDelta.amount0() : -swapDelta.amount1());
    }

    // Determine the excess recipient for a given swap with overflow
    function _determineExcessRecipient(bytes calldata hookData) internal view returns (address) {
        if (hookData.length == 0) {
            return address(0); // Default to null address
        }

        address recipient = abi.decode(hookData, (address));

        if (recipient == address(0)) {
            return address(1); // Locker
        } else if (recipient == address(1)) {
            return address(1); // Locker
        } else if (recipient == address(2)) {
            return msg.sender; // Router
        } else {
            return recipient; // Custom recipient
        }
    }
}

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
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityCommitmentCertificate} from "./LCC.sol";
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

    struct LiquidityCallbackData {
        uint256 amount0;
        uint256 amount1;
        Currency currency0;
        Currency currency1;
        address poolManager;
        LiquidityUtils.ActionType actionType;
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
    event HookModifyLiquidity(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1);

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
    function onDirectLP(PoolKey calldata corePoolkey, BalanceDelta delta, LiquidityUtils.ActionType actionType)
        external
        virtual
        onlyCoreHook
    {
        LiquidityCommitmentCertificate lccToken0 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolkey.currency0)));
        LiquidityCommitmentCertificate lccToken1 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolkey.currency1)));

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

            _settleFromLCCToVault(lccToken0, amount0);
            _settleFromLCCToVault(lccToken1, amount1);

            _settleObligationsToLCC(corePoolkey);
        } else if (actionType == LiquidityUtils.ActionType.DirectLPRemoveLiquidity) {
            // Remove liquidity from the core pool
            // Remove the underlying tokens from the vault to the LCCs
            // and notify the LCCs about the new balance
            _takeFromVaultToLCC(lccToken0, amount0);
            _takeFromVaultToLCC(lccToken1, amount1);
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
        // try settle the obligations to the lcc tokens since we potentially added assets to the vault
        _settleObligationsToLCC(corePoolKey);
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
        LiquidityCommitmentCertificate lccToken0 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency0)));
        LiquidityCommitmentCertificate lccToken1 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency1)));

        // Handle Token IN liquidity (move to PoolManager from lcc token)
        LiquidityCommitmentCertificate lccTokenIn = isZeroForOne ? lccToken0 : lccToken1;
        // Get the amount of the token that is being swapped in based on if this is a zero one swap or one for zero swap
        uint256 amountIn = isZeroForOne ? amount0 : amount1;
        // Deposit underlying liquidity to pool manager from lcc token
        _settleFromLCCToVault(lccTokenIn, amountIn);

        // Handle Token OUT liquidity (move from PoolManager into LCC token) or add to queue when there is not enough liquidity
        LiquidityCommitmentCertificate lccTokenOut = isZeroForOne ? lccToken1 : lccToken0;
        // Get the amount of the token that is being swapped in based on if this is a zero one swap or one for zero swap
        uint256 amountOut = isZeroForOne ? amount1 : amount0;

        uint256 deficit = _tryTakeFromVaultToLCC(lccTokenOut, amountOut);

        // New liquidity in pool, so we try and settle the outstanding obligations, if any
        _settleObligationsToLCC(corePoolKey);
        if (deficit > 0) {
            // TODO: NOTHING TO DO HERE
        }
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
        bool isHookRecipientSpecified = hookData.length > 0;

        uint256 maxOutputTokenAvailable =
            _getCurrencyAvailableLiquidity(params.zeroForOne ? key.currency1 : key.currency0);
        // console.log("Max token output available: ", maxOutputTokenAvailable);

        bool coreZeroForOne;
        PoolKey memory coreKey = corePoolKey;

        LiquidityCommitmentCertificate lccToken0 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(coreKey.currency0)));
        LiquidityCommitmentCertificate lccToken1 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(coreKey.currency1)));

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
        LiquidityCommitmentCertificate lccTokenForCurrency0 =
            params.zeroForOne == coreZeroForOne ? lccToken0 : lccToken1;
        LiquidityCommitmentCertificate lccTokenForCurrency1 =
            params.zeroForOne == coreZeroForOne ? lccToken1 : lccToken0;
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

        // TODO: The wisest approach is to only swap what is settled by default.
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

        SwapParams memory coreSwapParams = isHookRecipientSpecified
            ? SwapParams({
                zeroForOne: coreZeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96_core // Use adjusted limit
            })
            : _adjustSwapParamsForAvailableLiquidity(
                SwapParams({
                    zeroForOne: coreZeroForOne,
                    amountSpecified: params.amountSpecified,
                    sqrtPriceLimitX96: sqrtPriceLimitX96_core // Use adjusted limit
                }),
                corePoolKey,
                maxOutputTokenAvailable
            );

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
            (uint256 cancelledAmount,) = lccTokenForCurrency1.cancel(amountOut, _determineExcessRecipient(hookData));

            // console.log("cancelledAmount: ", cancelledAmount / 1e18);
            // console.log("deficit: ", deficit / 1e18);

            amountToSettle = cancelledAmount;

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
            (uint256 cancelledAmount,) = lccTokenForCurrency0.cancel(amountOut, _determineExcessRecipient(hookData));

            // console.log("cancelledAmount: ", cancelledAmount / 1e18);
            // console.log("deficit: ", deficit / 1e18);

            amountToSettle = cancelledAmount;

            // Settle the output token to the PoolManager
            // Burn claim tokens to release output token to the Trader from the PoolManager.
            key.currency0.settle(poolManager, address(this), amountToSettle, true);
        }

        // BalanceDelta is a packed value of (currency0Amount, currency1Amount)

        // BeforeSwapDelta varies such that it is not sorted by token0 and token1
        // Instead, it is sorted by "specifiedCurrency" and "unspecifiedCurrency"

        // Specified Currency => The currency in which the user is specifying the amount they're swapping for
        // Unspecified Currency => The other currency

        // TODO: Consider scenario where LCC has insufficient liquidity.
        // ie. less from here for token OUT, and more from core Token OUT.

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
        uint256 inputNeededForAvailableOutput;
        // ? we could add a buffer to not completely exhaust the liquidity
        // uint256 outputNeededForAvailableInput = outputAvailable * 90/100;
        uint256 maxOutputAvailable = outputAvailable;
        // simulate the swap and derive the expected output and input amounts respectively from the returning deltas
        (BalanceDelta swapDelta,,,) = SwapSimulator.simulateSwap(poolManager, poolKey, params);

        bool isExactInput = params.amountSpecified < 0;
        uint256 originalAmount = uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified);

        // console.log("Original swap amount: ", originalAmount);
        // console.log("Is exact input: ", isExactInput);

        uint256 expectedOutput = _getExpectedOutputFromDelta(swapDelta, params.zeroForOne);
        // console.log("Expected output from simulation: ", expectedOutput);

        // if it is an exact input swap, then we need to check if the expected output(from simulation) is greater than the max output available for the currency
        if (isExactInput) {
            if (expectedOutput > maxOutputAvailable) {
                // console.log(
                //     "Output exceeds available liquidity, capping to: ",
                //     maxOutputAvailable
                // );

                // if it is then we need to calcualte the exact input amount that is needed to get the max output available for the currency
                inputNeededForAvailableOutput =
                    _calculateInputForExactOutput(poolManager, poolKey, maxOutputAvailable, params.zeroForOne);

                // console.log(
                //     "Input needed for available output: ",
                //     inputNeededForAvailableOutput
                // );

                // adjust the swap params to use the input needed for max output
                adjustedParams = SwapParams({
                    zeroForOne: params.zeroForOne,
                    // negative for exact input swap
                    // this exact input swap would give us the maximum output available for the currency
                    amountSpecified: -int256(inputNeededForAvailableOutput),
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96
                });
            } else {
                // Output is within limits, no adjustment needed
                // adjusted params is the same as the original params
                // original amount is the amount needed to get the expected output
                // swap will continue as normal
                adjustedParams = params;
                inputNeededForAvailableOutput = originalAmount;
            }
        }
        // if it is an exact output swap, then we need to check if the expected output is greater than the max output available for the currency
        else {
            // Token0 -> Token1 or Token1 -> Token0:
            // check if output token exceeds available liquidity
            // if we have enough liquidity swap will continue as normal
            // if we dont have enough liquidity, we need to cap the output to the max output available for the currency
            uint256 cappedOutput = Math.min(originalAmount, maxOutputAvailable);

            // Cap the output to available liquidity
            adjustedParams = SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: int256(cappedOutput), // Positive for exact output
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            });
            // ? optional calculation,  as input amount is not needed for exact output swap
            // ? but is usefull for debugging and consistency
            // and calculate the input needed to get the max output available for the currency
            // and adjust the swap params to use the input needed for max output
            // and swap will continue as normal
            inputNeededForAvailableOutput =
                _calculateInputForExactOutput(poolManager, poolKey, cappedOutput, params.zeroForOne);
            // console.log(
            //     "Input needed for available output: ",
            //     inputNeededForAvailableOutput
            // );
        }

        // console.log(
        //     "Adjusted params amount: ",
        //     uint256(
        //         adjustedParams.amountSpecified < 0
        //             ? -adjustedParams.amountSpecified
        //             : adjustedParams.amountSpecified
        //     )
        // );
        // console.log("Final max output available: ", maxOutputAvailable);
        // console.log(
        //     "Final input needed for max output: ",
        //     inputNeededForAvailableOutput
        // );
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
            return address(1); // Default to locker
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

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

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "forge-std/console.sol";

import {LiquidityCommitmentCertificate} from "./LCC.sol";

contract ProxyHook is BaseHook {
    using CurrencySettler for Currency;

    error AddLiquidityThroughHookNotAllowed();
    error UnsafeInt128ToUint256Conversion(int128 value);
    error InvalidInitialiser();
    error InvalidSender();

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

    address public immutable counterpartHook; // if this is core hook, then proxy hook -- otherwise, if this is proxy hook, then core hook

    modifier onlyCounterpartHook(PoolId thisPoolId) {
        if (msg.sender != getCounterpartHook(thisPoolId)) {
            revert InvalidSender();
        }
        _;
    }

    modifier _onlyCounterpartHook() {
        if (msg.sender != _getCounterpartHook()) {
            revert InvalidSender();
        }
        _;
    }

    /**
     * @dev Safely converts int128 to uint256, handling negative values by taking absolute value
     * @param value The int128 value to convert
     * @return The uint256 representation (absolute value)
     */
    function _safeInt128ToUint256(int128 value) internal pure returns (uint256) {
        if (value < 0) {
            return uint256(uint128(-value));
        }
        return uint256(uint128(value));
    }

    constructor(address _poolManager, address _marketFactory) BaseHook(IPoolManager(_poolManager)) {
        marketFactory = _marketFactory;
    }

    /**
     * @dev Updates the core pool key with the actual core pool configuration
     * @param _corePoolKey The actual core pool key to set
     */
    function updateCorePoolKey(PoolKey calldata _corePoolKey) external {
        // Only the CoreHook can update the core pool key
        require(msg.sender == address(this), "ProxyHook: only self can update core pool key");
        corePoolKey = _corePoolKey;

        // Update the token mapping with the actual LCC tokens
        Currency underlyingToken0 =
            Currency.wrap(LiquidityCommitmentCertificate(Currency.unwrap(_corePoolKey.currency0)).underlyingAsset());
        tokenMapping[underlyingToken0] = _corePoolKey.currency0;

        Currency underlyingToken1 =
            Currency.wrap(LiquidityCommitmentCertificate(Currency.unwrap(_corePoolKey.currency1)).underlyingAsset());
        tokenMapping[underlyingToken1] = _corePoolKey.currency1;
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
        pure
        virtual
        override
        returns (bytes4)
    {
        if (sender != marketFactory) {
            revert InvalidInitialiser();
        }

        // initialise the counterparty hook -- proxy pool is created after the core pool.
        getCounterpartHook(key.toId());

        return this._beforeInitialize.selector;
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

    struct LiquidityCallbackData {
        uint256 amount;
        Currency currency;
        address sender;
        address poolManager;
        bool isAdd;
    }

    // Method called by the Core Hook notifying that Direct Liquidity Provision occurred.
    function onDirectLP(PoolKey calldata corePoolkey, ModifyLiquidityParams calldata params, BalanceDelta delta)
        external
        virtual
        nonReentrant
        _onlyCounterpartHook
        returns (uint256)
    {
        // require(block.timestamp <= deadline, "Deadline not met");

        // TODO: We need to settle... no need to manage keys here.
        // PoolId corePoolId = corePoolkey.toId();
        // IMarketFactory mf = IMarketFactory(marketFactory);
        // PoolId id = mf.proxyToCore(thisPoolId);
        // counterpartHook = mf.getHook(id);

        IPoolManager(self.poolManager).unlock(
            abi.encode(
                LiquidityCallbackData(amounts[i], CurrencyLibrary.fromId(currentId), msg.sender, self.poolManager, true)
            )
        );
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

            // TODO: We need to determine zeroForOne on the core...
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

        console.log("Core Pool Delta amount0: ", delta.amount0());
        console.log("Core Pool Delta amount1: ", delta.amount1());
        console.log("zeroForOne_core: ", zeroForOne_core);
        console.log("params.zeroForOne: ", params.zeroForOne);

        /// The desired input amount if negative (exactIn), or the desired output amount if positive (exactOut)
        uint256 amountIn;
        uint256 amountOut;
        bool isExactInput = params.amountSpecified < 0;
        if (isExactInput) {
            amountIn = uint256(-params.amountSpecified);
            if (params.zeroForOne == zeroForOne_core) {
                amountOut = _safeInt128ToUint256(delta.amount1());
            } else {
                amountOut = _safeInt128ToUint256(delta.amount0());
            }
        } else {
            if (params.zeroForOne == zeroForOne_core) {
                amountIn = _safeInt128ToUint256(delta.amount0());
            } else {
                amountIn = _safeInt128ToUint256(delta.amount1());
            }
            amountOut = uint256(params.amountSpecified);
        }

        console.log("amountIn: ", amountIn);
        console.log("amountOut: ", amountOut);

        // ? Liquidity is managed inside of the Proxy Hook
        IMarketFactory mf = IMarketFactory(marketFactory);
        LiquidityCommitmentCertificate lccToken0 = mf.getLCC(Currency.unwrap(key.currency0));
        LiquidityCommitmentCertificate lccToken1 = mf.getLCC(Currency.unwrap(key.currency1));

        if (params.zeroForOne) {
            // If user is selling Token 0 and buying Token 1
            // First mint LCC tokens for the input amount
            lccToken0.custodianMint(amountIn);

            // Settle LCC tokens to the PoolManager (this gives PM the underlying tokens)
            tokenMapping[key.currency0].settle(poolManager, address(this), amountIn, false);

            // Now take the underlying tokens from PoolManager to the Hook
            poolManager.take(key.currency0, address(this), amountIn);

            // Take LCC tokens of Token 1 from Core Pool via PoolManager
            tokenMapping[key.currency1].take(poolManager, address(this), amountOut, false);

            // Theoretically, we should unwrap LCC of Token 1 from the PM now... Hook should already house the underlying liquidity for the LCC ...
            // Therefore all we need to do is burn the LCC tokens from the hook.

            // TODO: Unwrap and Burn the LCC tokens from the PM... might need to be executed elsewhere...
            // lccToken1.unwrap(address(this), amountOut);
        } else {
            // If user is selling Token 1 and buying Token 0
            // First mint LCC tokens for the input amount
            lccToken1.custodianMint(amountIn);

            // Settle LCC tokens to the PoolManager (this gives PM the underlying tokens)
            tokenMapping[key.currency1].settle(poolManager, address(this), amountIn, false);

            // Now take the underlying tokens from PoolManager to the Hook
            poolManager.take(key.currency1, address(this), amountIn);

            // Take LCC tokens of Token 0 from Core Pool via PoolManager
            tokenMapping[key.currency0].take(poolManager, address(this), amountOut, false);

            // Theoretically, we should unwrap LCC of Token 1 from the PM now... Hook should already house the underlying liquidity for the LCC ...
            // Therefore all we need to do is burn the LCC tokens from the hook.
            // TODO: Unwrap and Burn the LCC tokens from the PM... might need to be executed elsewhere...
            // lccToken0.unwrap(
            //     address(this), // TODO: This is correct, however, for now:
            //     amountOut
            // );
        }

        // TODO: This Proxy Hook will need to draw on liquidity from the PositionManager that MMs engage.

        // pay the output token, to the PoolManager from Proxy Hook.
        // the credit will be forwarded to the swap router, which then forwards it to the swapper
        poolManager.sync(params.zeroForOne ? key.currency1 : key.currency0);
        poolManager.settle();

        BeforeSwapDelta newDelta;
        if (params.zeroForOne == zeroForOne_core) {
            newDelta = toBeforeSwapDelta(delta.amount0(), delta.amount1());
        } else {
            newDelta = toBeforeSwapDelta(delta.amount1(), delta.amount0());
        }

        return (this.beforeSwap.selector, newDelta, 0);
    }

    function getCounterpartHook(PoolId thisPoolId) internal returns (address) {
        if (counterpartHook == address(0)) {
            IMarketFactory mf = IMarketFactory(marketFactory);
            PoolId id = mf.proxyToCore(thisPoolId);
            counterpartHook = mf.getHook(id);
        }
        return counterpartHook;
    }

    function _getCounterpartHook() internal returns (address) {
        if (counterpartHook == address(0)) {
            revert CounterpartHookNotSet();
        }
        return counterpartHook;
    }
}

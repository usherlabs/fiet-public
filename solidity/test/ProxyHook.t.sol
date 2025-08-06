// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySortHelper} from "../script/libraries/CurrencySortHelper.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {CoreHook} from "../src/CoreHook.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {IHookCommon} from "../src/interfaces/IHookCommon.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {console} from "forge-std/console.sol";
import {HookFlags} from "../script/constants/HookFlags.sol";

contract ProxyHookTest is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    ProxyHook hook;
    Currency internal _currency0;
    Currency internal _currency1;
    Currency internal _currency2;
    Currency internal _currency3;

    uint160 constant ZERO_FOR_ONE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant ONE_FOR_ZERO_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    PoolKey corePoolKey;
    PoolKey proxyPoolKey;

    address marketFactory;
    address coreHookAddress;

    function deployAndApproveLCC(address underlyingAsset, address hookAddr) internal returns (Currency currency) {
        address[] memory issuers = new address[](2);
        issuers[0] = hookAddr;
        issuers[1] = address(this);

        LiquidityCommitmentCertificate token =
            new LiquidityCommitmentCertificate(underlyingAsset, issuers, marketFactory);

        address[10] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter),
            address(manager)
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            token.approve(toApprove[i], Constants.MAX_UINT256);
            IERC20Minimal(underlyingAsset).approve(toApprove[i], Constants.MAX_UINT256);
        }

        IERC20Minimal(underlyingAsset).approve(address(token), Constants.MAX_UINT256);
        return Currency.wrap(address(token));
    }

    function deployCurrencies(address hookAddr) internal {
        Currency _currencyA = deployMintAndApproveCurrency();
        Currency _currencyB = deployMintAndApproveCurrency();

        Currency _currencyC = deployAndApproveLCC(Currency.unwrap(_currencyA), hookAddr);
        Currency _currencyD = deployAndApproveLCC(Currency.unwrap(_currencyB), hookAddr);

        (_currency0, _currency1) =
            CurrencySortHelper.sortAddresses(Currency.unwrap(_currencyA), Currency.unwrap(_currencyB));

        (_currency2, _currency3) =
            CurrencySortHelper.sortAddresses(Currency.unwrap(_currencyC), Currency.unwrap(_currencyD));
    }

    function deployCorePool() internal {
        Currency currencyA = _currency2;
        Currency currencyB = _currency3;
        if (Currency.unwrap(currencyA) > Currency.unwrap(currencyB)) {
            (currencyA, currencyB) = (currencyB, currencyA);
        }
        corePoolKey = PoolKey(currencyA, currencyB, 3000, 60, IHooks(coreHookAddress));
        vm.prank(marketFactory);
        manager.initialize(corePoolKey, SQRT_PRICE_1_1);
    }

    function deployProxyPool(address proxyHookAddress) internal {
        // Deployment and activation moved to setUp
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        marketFactory = makeAddr("marketFactory");

        // Compute core hook address
        uint160 coreFlags = HookFlags.CORE_HOOK_FLAGS;
        coreHookAddress = address(coreFlags);

        // Deploy CoreHook
        deployCodeTo("CoreHook.sol", abi.encode(manager, marketFactory), coreHookAddress);

        // Compute proxy hook address
        uint160 proxyFlags = HookFlags.PROXY_HOOK_FLAGS;
        address proxyHookAddress = address(proxyFlags);

        // Deploy ProxyHook
        deployCodeTo("ProxyHook.sol", abi.encode(manager, marketFactory), proxyHookAddress);
        hook = ProxyHook(proxyHookAddress);

        // Mock factory calls
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.getCoreHook.selector), abi.encode(coreHookAddress)
        );
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.proxyHookToCurrencyPair.selector),
            abi.encode(Currency.unwrap(_currency2), Currency.unwrap(_currency3))
        );

        // Activate proxy hooks
        vm.prank(marketFactory);
        hook.activate();

        deployCurrencies(proxyHookAddress);
        deployCorePool();

        // Initialize proxy pool
        Currency currencyA = _currency0;
        Currency currencyB = _currency1;
        if (Currency.unwrap(currencyA) > Currency.unwrap(currencyB)) {
            (currencyA, currencyB) = (currencyB, currencyA);
        }
        proxyPoolKey = PoolKey(currencyA, currencyB, 3000, 60, IHooks(proxyHookAddress));
        vm.prank(marketFactory);
        manager.initialize(proxyPoolKey, SQRT_PRICE_1_1);

        // Set core pool key against the proxy pool key id.
        vm.prank(marketFactory);
        hook.setCorePoolKey(corePoolKey);

        // Provide initial liquidity to core pool
        uint256 initialLiquidity = 10000e18;

        LiquidityCommitmentCertificate lcc0 = LiquidityCommitmentCertificate(Currency.unwrap(_currency2));
        LiquidityCommitmentCertificate lcc1 = LiquidityCommitmentCertificate(Currency.unwrap(_currency3));

        _currency0.transfer(address(this), initialLiquidity);
        _currency1.transfer(address(this), initialLiquidity);

        IERC20Minimal(lcc0.underlyingAsset()).approve(address(lcc0), initialLiquidity);
        lcc0.wrap(initialLiquidity);

        IERC20Minimal(lcc1.underlyingAsset()).approve(address(lcc1), initialLiquidity);
        lcc1.wrap(initialLiquidity);

        // Mock factory calls made by CoreHook when liquidity is added or removed.
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.coreToProxy.selector), abi.encode(proxyPoolKey.toId())
        );
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.proxyToHook.selector), abi.encode(proxyHookAddress)
        );

        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(initialLiquidity),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_cannotModifyLiquidityOfProxyHook() public {
        vm.prank(address(manager));
        vm.expectRevert(ProxyHook.AddLiquidityThroughHookNotAllowed.selector);
        hook.beforeAddLiquidity(
            address(1),
            proxyPoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000e18, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function test_canModifyLiquidityOfCorePool() public {
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function test_swap_exactInput_zeroForOneOnProxy() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();

        uint256 swapAmount = 1e18;
        BalanceDelta delta = swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            settings,
            ZERO_BYTES
        );

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey.currency1.balanceOfSelf();

        console.log("selfBalanceOfTokenABefore:", selfBalanceOfTokenABefore);
        console.log("selfBalanceOfTokenAAfter:", selfBalanceOfTokenAAfter);
        console.log("selfBalanceOfTokenBBefore:", selfBalanceOfTokenBBefore);
        console.log("selfBalanceOfTokenBAfter:", selfBalanceOfTokenBAfter);
        console.log("swap delta 0:", delta.amount0());
        console.log("swap delta 1:", delta.amount1());

        assertEq(selfBalanceOfTokenABefore - selfBalanceOfTokenAAfter, swapAmount);
        assertGt(selfBalanceOfTokenBAfter, selfBalanceOfTokenBBefore);
    }

    function test_swap_exactInput_oneForZeroOnProxy() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();

        uint256 swapAmount = 100;
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT}),
            settings,
            ZERO_BYTES
        );

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey.currency1.balanceOfSelf();

        assertEq(selfBalanceOfTokenBBefore - selfBalanceOfTokenBAfter, swapAmount);
        assertGt(selfBalanceOfTokenAAfter, selfBalanceOfTokenABefore);
    }

    function test_swap_exactOutput_zeroForOneOnProxy() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();

        uint256 swapAmount = 100;
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(swapAmount), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            settings,
            ZERO_BYTES
        );

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey.currency1.balanceOfSelf();

        assertLt(selfBalanceOfTokenAAfter, selfBalanceOfTokenABefore);
        assertEq(selfBalanceOfTokenBAfter, selfBalanceOfTokenBBefore + swapAmount);
    }

    function test_swap_exactOutput_oneForZeroOnProxy() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();

        uint256 swapAmount = 100;
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(swapAmount), sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT}),
            settings,
            ZERO_BYTES
        );

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey.currency1.balanceOfSelf();

        assertLt(selfBalanceOfTokenBAfter, selfBalanceOfTokenBBefore);
        assertEq(selfBalanceOfTokenAAfter, selfBalanceOfTokenABefore + swapAmount);
    }

    function test_swap_exactOutput_ZeroForOneOnCore() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // get balances of underlying token of the pool manager and lcc contracts
        // get the underlying asset of the lcc token A
        address underlyingAssetLCC0 =
            LiquidityCommitmentCertificate(Currency.unwrap(corePoolKey.currency0)).underlyingAsset();
        address underlyingAssetLCC1 =
            LiquidityCommitmentCertificate(Currency.unwrap(corePoolKey.currency1)).underlyingAsset();

        console.log("underlyingAsset-LCC0", underlyingAssetLCC0);
        console.log("underlyingAsset-LCC1", underlyingAssetLCC1);

        uint256 preBalanceOfToken0UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC0).balanceOf(address(manager));
        uint256 preBalanceOfToken1UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC1).balanceOf(address(manager));

        uint256 preBalanceOfToken0UnderlyingAssetInLCC =
            Currency.wrap(underlyingAssetLCC0).balanceOf(Currency.unwrap(corePoolKey.currency0));
        uint256 preBalanceOfToken1UnderlyingAssetInLCC =
            Currency.wrap(underlyingAssetLCC1).balanceOf(Currency.unwrap(corePoolKey.currency1));

        console.log("preBalanceOfToken0UnderlyingAssetInPM", preBalanceOfToken0UnderlyingAssetInPM);
        console.log("preBalanceOfToken1UnderlyingAssetInPM", preBalanceOfToken1UnderlyingAssetInPM);
        console.log("preBalanceOfToken0UnderlyingAssetInLCC", preBalanceOfToken0UnderlyingAssetInLCC);
        console.log("preBalanceOfToken1UnderlyingAssetInLCC", preBalanceOfToken1UnderlyingAssetInLCC);

        int256 swapAmount = -100;
        BalanceDelta delta = swapRouter.swap(
            corePoolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(swapAmount), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            settings,
            ZERO_BYTES
        );

        uint256 deltaAmount0 = _safeInt128ToUint256(delta.amount0());
        uint256 deltaAmount1 = _safeInt128ToUint256(delta.amount1());

        console.log("delta 0:", delta.amount0());
        console.log("delta 1:", delta.amount1());

        uint256 postBalanceOfToken0UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC0).balanceOf(address(manager));
        uint256 postBalanceOfToken1UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC1).balanceOf(address(manager));

        uint256 postBalanceOfToken0UnderlyingAssetInLCC =
            Currency.wrap(underlyingAssetLCC0).balanceOf(Currency.unwrap(corePoolKey.currency0));
        uint256 postBalanceOfToken1UnderlyingAssetInLCC =
            Currency.wrap(underlyingAssetLCC1).balanceOf(Currency.unwrap(corePoolKey.currency1));

        console.log("postBalanceOfToken0UnderlyingAssetInPM", postBalanceOfToken0UnderlyingAssetInPM);
        console.log("postBalanceOfToken1UnderlyingAssetInPM", postBalanceOfToken1UnderlyingAssetInPM);
        console.log("postBalanceOfToken0UnderlyingAssetInLCC", postBalanceOfToken0UnderlyingAssetInLCC);
        console.log("postBalanceOfToken1UnderlyingAssetInLCC", postBalanceOfToken1UnderlyingAssetInLCC);

        // validate liquidity of token-in(token0) in the lcc token is lower after the swap
        // because liquidity will move 'from lcc' token 'to pool-manager' as it enters the pool during a zero for one swap
        assertEq(preBalanceOfToken0UnderlyingAssetInLCC - postBalanceOfToken0UnderlyingAssetInLCC, deltaAmount0);
        // validate liquidity of token-in(token0) in the pool manager is higher after the swap
        // becase liquidity of the underlying tokens will be moved from lcc token to pool manager
        // so the pool manager's underlying balance should increase by the amount of token-in(token0) swapped into the pool
        assertEq(postBalanceOfToken0UnderlyingAssetInPM - preBalanceOfToken0UnderlyingAssetInPM, deltaAmount0);
        // validate liquidity of token-out(token1) in the lcc token is higher after the swap
        // because liquidity will move 'from pool-manager' token 'to lcc' token as it exits the pool during a zero for one swap
        assertEq(postBalanceOfToken1UnderlyingAssetInLCC - preBalanceOfToken1UnderlyingAssetInLCC, deltaAmount1);
        // validate liquidity of token-out(token1) in the pool manager is lower after the swap
        // because liquidity of the underlying tokens will be moved from lcc token to pool manager
        // so the pool manager's underlying balance should decrease by the amount of token-out(token1) swapped out of the pool
        assertEq(preBalanceOfToken1UnderlyingAssetInPM - postBalanceOfToken1UnderlyingAssetInPM, deltaAmount1);
    }

    function test_swap_exactOutput_OneForZeroOnCore() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // get balances of underlying token of the pool manager and lcc contracts
        // get the underlying asset of the lcc token A
        address underlyingAssetLCC0 =
            LiquidityCommitmentCertificate(Currency.unwrap(corePoolKey.currency0)).underlyingAsset();
        address underlyingAssetLCC1 =
            LiquidityCommitmentCertificate(Currency.unwrap(corePoolKey.currency1)).underlyingAsset();

        console.log("underlyingAsset-LCC0", underlyingAssetLCC0);
        console.log("underlyingAsset-LCC1", underlyingAssetLCC1);

        uint256 preBalanceOfToken0UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC0).balanceOf(address(manager));
        uint256 preBalanceOfToken1UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC1).balanceOf(address(manager));

        uint256 preBalanceOfToken0UnderlyingAssetInLCC =
            Currency.wrap(underlyingAssetLCC0).balanceOf(Currency.unwrap(corePoolKey.currency0));
        uint256 preBalanceOfToken1UnderlyingAssetInLCC =
            Currency.wrap(underlyingAssetLCC1).balanceOf(Currency.unwrap(corePoolKey.currency1));

        console.log("preBalanceOfToken0UnderlyingAssetInPM", preBalanceOfToken0UnderlyingAssetInPM);
        console.log("preBalanceOfToken1UnderlyingAssetInPM", preBalanceOfToken1UnderlyingAssetInPM);
        console.log("preBalanceOfToken0UnderlyingAssetInLCC", preBalanceOfToken0UnderlyingAssetInLCC);
        console.log("preBalanceOfToken1UnderlyingAssetInLCC", preBalanceOfToken1UnderlyingAssetInLCC);

        int256 swapAmount = 100;
        BalanceDelta delta = swapRouter.swap(
            corePoolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(swapAmount), sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT}),
            settings,
            ZERO_BYTES
        );

        uint256 deltaAmount0 = LiquidityUtils.safeInt128ToUint256(delta.amount0());
        uint256 deltaAmount1 = LiquidityUtils.safeInt128ToUint256(delta.amount1());

        console.log("swap delta 0:", delta.amount0());
        console.log("swap delta 1:", delta.amount1());

        uint256 postBalanceOfToken0UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC0).balanceOf(address(manager));
        uint256 postBalanceOfToken1UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC1).balanceOf(address(manager));

        uint256 postBalanceOfToken0UnderlyingAssetInLCC =
            Currency.wrap(underlyingAssetLCC0).balanceOf(Currency.unwrap(corePoolKey.currency0));
        uint256 postBalanceOfToken1UnderlyingAssetInLCC =
            Currency.wrap(underlyingAssetLCC1).balanceOf(Currency.unwrap(corePoolKey.currency1));

        console.log("postBalanceOfToken0UnderlyingAssetInPM", postBalanceOfToken0UnderlyingAssetInPM);
        console.log("postBalanceOfToken1UnderlyingAssetInPM", postBalanceOfToken1UnderlyingAssetInPM);
        console.log("postBalanceOfToken0UnderlyingAssetInLCC", postBalanceOfToken0UnderlyingAssetInLCC);
        console.log("postBalanceOfToken1UnderlyingAssetInLCC", postBalanceOfToken1UnderlyingAssetInLCC);

        // validate liquidity of token-out(token0) in the lcc token is higher after the swap
        // because liquidity will move 'from pool-manager' token 'to LCC' token as it exits the pool during a one for zero swap
        assertEq(postBalanceOfToken0UnderlyingAssetInLCC - preBalanceOfToken0UnderlyingAssetInLCC, deltaAmount0);
        // validate liquidity of token-out(token0) in the pool manager is lower after the swap
        // becase liquidity of the underlying tokens will be moved from the pool-manager to LCC token
        // so the pool manager's underlying balance should decrease by the amount of token-out(token0) swapped out of the pool
        assertEq(preBalanceOfToken0UnderlyingAssetInPM - postBalanceOfToken0UnderlyingAssetInPM, deltaAmount0);
        // validate liquidity of token-in(token1) in the lcc token is lower after the swap
        // because liquidity will move 'from lcc' tokens 'to pool-manager' as it enters the pool during a one for zero swap
        assertEq(preBalanceOfToken1UnderlyingAssetInLCC - postBalanceOfToken1UnderlyingAssetInLCC, deltaAmount1);
        // validate liquidity of token-in(token1) in the pool manager is higher after the swap
        // because liquidity of the underlying tokens will be moved from LCC token to pool-manager
        // so the pool manager's underlying balance should increase by the amount of token-in(token1) swapped into of the pool
        assertEq(postBalanceOfToken1UnderlyingAssetInPM - preBalanceOfToken1UnderlyingAssetInPM, deltaAmount1);
    }

    // Additional tests

    function test_beforeInitialize_revertIfNotFactory() public {
        PoolKey memory testKey =
            PoolKey({currency0: _currency0, currency1: _currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(hook)});

        vm.prank(address(manager));
        vm.expectRevert(ProxyHook.InvalidInitialiser.selector);
        hook.beforeInitialize(address(1), testKey, SQRT_PRICE_1_1);
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

    // More tests can be added for onDirectLP, unlockCallback, etc.
}

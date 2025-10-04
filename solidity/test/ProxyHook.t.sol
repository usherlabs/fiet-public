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
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {console} from "forge-std/console.sol";
import {HookFlags} from "../script/constants/HookFlags.sol";
// inherit from the MarketTestBase contract
import {MarketTestBase} from "./modules/MarketTestBase.sol";
import {SwapSimulator} from "../src/libraries/SwapSimulator.sol";
import {IMarketVault} from "../src/interfaces/IMarketVault.sol";

contract ProxyHookTest is MarketTestBase {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    LiquidityCommitmentCertificate lcc0;
    LiquidityCommitmentCertificate lcc1;

    function setUp() public {
        _setupMarket();

        lcc0 = LiquidityCommitmentCertificate(
            payable(Currency.unwrap(_currency2))
        );
        lcc1 = LiquidityCommitmentCertificate(
            payable(Currency.unwrap(_currency3))
        );
    }

    function test_cannotModifyLiquidityOfProxyHook() public {
        vm.prank(address(manager));
        vm.expectRevert(ProxyHook.AddLiquidityThroughHookNotAllowed.selector);
        proxyHook.beforeAddLiquidity(
            address(1),
            proxyPoolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000e18,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_canModifyLiquidityOfCorePool() public {
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1e18,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_swap_exactInput_zeroForOneOnProxy() public {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        uint256 selfBalanceOfTokenABefore = proxyPoolKey
            .currency0
            .balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey
            .currency1
            .balanceOfSelf();

        uint256 swapAmount = 1e18;
        BalanceDelta delta = swapRouter.swap(
            proxyPoolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT
            }),
            settings,
            ZERO_BYTES
        );

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey
            .currency0
            .balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey
            .currency1
            .balanceOfSelf();

        console.log("selfBalanceOfTokenABefore:", selfBalanceOfTokenABefore);
        console.log("selfBalanceOfTokenAAfter:", selfBalanceOfTokenAAfter);
        console.log("selfBalanceOfTokenBBefore:", selfBalanceOfTokenBBefore);
        console.log("selfBalanceOfTokenBAfter:", selfBalanceOfTokenBAfter);
        console.log("swap delta 0:", delta.amount0());
        console.log("swap delta 1:", delta.amount1());

        assertEq(
            selfBalanceOfTokenABefore - selfBalanceOfTokenAAfter,
            swapAmount
        );
        assertGt(selfBalanceOfTokenBAfter, selfBalanceOfTokenBBefore);
    }

    function test_swap_exactInput_oneForZeroOnProxy() public {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        uint256 selfBalanceOfTokenABefore = proxyPoolKey
            .currency0
            .balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey
            .currency1
            .balanceOfSelf();
        // proxy balance of tokens
        uint256 balanceOfTokenA = mv.inMarketBalanceOf(proxyPoolKey.currency0);
        uint256 balanceOfTokenB = mv.inMarketBalanceOf(proxyPoolKey.currency1);
        console.log("balanceOfTokenA", balanceOfTokenA);
        console.log("balanceOfTokenB", balanceOfTokenB);

        uint256 swapAmount = 100;
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT
            }),
            settings,
            ZERO_BYTES
        );

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey
            .currency0
            .balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey
            .currency1
            .balanceOfSelf();

        assertEq(
            selfBalanceOfTokenBBefore - selfBalanceOfTokenBAfter,
            swapAmount
        );
        assertGt(selfBalanceOfTokenAAfter, selfBalanceOfTokenABefore);
    }

    function test_swap_exactOutput_zeroForOneOnProxy() public {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        uint256 selfBalanceOfTokenABefore = proxyPoolKey
            .currency0
            .balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey
            .currency1
            .balanceOfSelf();

        uint256 swapAmount = 100;
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(swapAmount),
                sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT
            }),
            settings,
            ZERO_BYTES
        );

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey
            .currency0
            .balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey
            .currency1
            .balanceOfSelf();

        assertLt(selfBalanceOfTokenAAfter, selfBalanceOfTokenABefore);
        assertEq(
            selfBalanceOfTokenBAfter,
            selfBalanceOfTokenBBefore + swapAmount
        );
    }

    function test_swap_exactOutput_oneForZeroOnProxy() public {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        uint256 selfBalanceOfTokenABefore = proxyPoolKey
            .currency0
            .balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey
            .currency1
            .balanceOfSelf();

        uint256 swapAmount = 100;
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: int256(swapAmount),
                sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT
            }),
            settings,
            ZERO_BYTES
        );

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey
            .currency0
            .balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey
            .currency1
            .balanceOfSelf();

        assertLt(selfBalanceOfTokenBAfter, selfBalanceOfTokenBBefore);
        assertEq(
            selfBalanceOfTokenAAfter,
            selfBalanceOfTokenABefore + swapAmount
        );
    }

    // Tests that after a direct swap on the underlying liquidity of the lcc tokens are moved accordingly
    function test_swap_exactOutput_zeroForOneOnCore() public {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // get balances of underlying token of the pool manager and lcc contracts
        // get the underlying asset of the lcc token A
        address underlyingAssetLCC0 = LiquidityCommitmentCertificate(
            payable(Currency.unwrap(corePoolKey.currency0))
        ).underlyingAsset();
        address underlyingAssetLCC1 = LiquidityCommitmentCertificate(
            payable(Currency.unwrap(corePoolKey.currency1))
        ).underlyingAsset();

        console.log("underlyingAsset-LCC0", underlyingAssetLCC0);
        console.log("underlyingAsset-LCC1", underlyingAssetLCC1);

        uint256 preBalanceOfToken0UnderlyingAssetInPM = Currency
            .wrap(underlyingAssetLCC0)
            .balanceOf(address(manager));
        uint256 preBalanceOfToken1UnderlyingAssetInPM = Currency
            .wrap(underlyingAssetLCC1)
            .balanceOf(address(manager));

        uint256 preBalanceOfToken0UnderlyingAssetInLCC = Currency
            .wrap(underlyingAssetLCC0)
            .balanceOf(Currency.unwrap(corePoolKey.currency0));
        uint256 preBalanceOfToken1UnderlyingAssetInLCC = Currency
            .wrap(underlyingAssetLCC1)
            .balanceOf(Currency.unwrap(corePoolKey.currency1));

        console.log(
            "preBalanceOfToken0UnderlyingAssetInPM",
            preBalanceOfToken0UnderlyingAssetInPM
        );
        console.log(
            "preBalanceOfToken1UnderlyingAssetInPM",
            preBalanceOfToken1UnderlyingAssetInPM
        );
        console.log(
            "preBalanceOfToken0UnderlyingAssetInLCC",
            preBalanceOfToken0UnderlyingAssetInLCC
        );
        console.log(
            "preBalanceOfToken1UnderlyingAssetInLCC",
            preBalanceOfToken1UnderlyingAssetInLCC
        );

        int256 swapAmount = -100;
        BalanceDelta delta = swapRouter.swap(
            corePoolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(swapAmount),
                sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT
            }),
            settings,
            ZERO_BYTES
        );

        uint256 deltaAmount0 = LiquidityUtils.safeInt128ToUint256(
            delta.amount0()
        );
        uint256 deltaAmount1 = LiquidityUtils.safeInt128ToUint256(
            delta.amount1()
        );

        console.log("delta 0:", delta.amount0());
        console.log("delta 1:", delta.amount1());

        uint256 postBalanceOfToken0UnderlyingAssetInPM = Currency
            .wrap(underlyingAssetLCC0)
            .balanceOf(address(manager));
        uint256 postBalanceOfToken1UnderlyingAssetInPM = Currency
            .wrap(underlyingAssetLCC1)
            .balanceOf(address(manager));

        uint256 postBalanceOfToken0UnderlyingAssetInLCC = Currency
            .wrap(underlyingAssetLCC0)
            .balanceOf(Currency.unwrap(corePoolKey.currency0));
        uint256 postBalanceOfToken1UnderlyingAssetInLCC = Currency
            .wrap(underlyingAssetLCC1)
            .balanceOf(Currency.unwrap(corePoolKey.currency1));

        console.log(
            "postBalanceOfToken0UnderlyingAssetInPM",
            postBalanceOfToken0UnderlyingAssetInPM
        );
        console.log(
            "postBalanceOfToken1UnderlyingAssetInPM",
            postBalanceOfToken1UnderlyingAssetInPM
        );
        console.log(
            "postBalanceOfToken0UnderlyingAssetInLCC",
            postBalanceOfToken0UnderlyingAssetInLCC
        );
        console.log(
            "postBalanceOfToken1UnderlyingAssetInLCC",
            postBalanceOfToken1UnderlyingAssetInLCC
        );

        // validate liquidity of token-in(token0) in the lcc token is lower after the swap
        // because liquidity will move 'from lcc' token 'to pool-manager' as it enters the pool during a zero for one swap
        assertEq(
            preBalanceOfToken0UnderlyingAssetInLCC -
                postBalanceOfToken0UnderlyingAssetInLCC,
            deltaAmount0
        );
        // validate liquidity of token-in(token0) in the pool manager is higher after the swap
        // becase liquidity of the underlying tokens will be moved from lcc token to pool manager
        // so the pool manager's underlying balance should increase by the amount of token-in(token0) swapped into the pool
        assertEq(
            postBalanceOfToken0UnderlyingAssetInPM -
                preBalanceOfToken0UnderlyingAssetInPM,
            deltaAmount0
        );
        // validate liquidity of token-out(token1) in the lcc token is higher after the swap
        // because liquidity will move 'from pool-manager' token 'to lcc' token as it exits the pool during a zero for one swap
        assertEq(
            postBalanceOfToken1UnderlyingAssetInLCC -
                preBalanceOfToken1UnderlyingAssetInLCC,
            deltaAmount1
        );
        // validate liquidity of token-out(token1) in the pool manager is lower after the swap
        // because liquidity of the underlying tokens will be moved from lcc token to pool manager
        // so the pool manager's underlying balance should decrease by the amount of token-out(token1) swapped out of the pool
        assertEq(
            preBalanceOfToken1UnderlyingAssetInPM -
                postBalanceOfToken1UnderlyingAssetInPM,
            deltaAmount1
        );
    }

    // Tests that after a direct swap on the underlying liquidity of the lcc tokens are moved accordingly
    function test_swap_exactOutput_oneForZeroOnCore() public {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // get balances of underlying token of the pool manager and lcc contracts
        // get the underlying asset of the lcc token A
        address underlyingAssetLCC0 = LiquidityCommitmentCertificate(
            Currency.unwrap(corePoolKey.currency0)
        ).underlyingAsset();
        address underlyingAssetLCC1 = LiquidityCommitmentCertificate(
            Currency.unwrap(corePoolKey.currency1)
        ).underlyingAsset();

        console.log("underlyingAsset-LCC0", underlyingAssetLCC0);
        console.log("underlyingAsset-LCC1", underlyingAssetLCC1);

        uint256 preBalanceOfToken0UnderlyingAssetInPM = Currency
            .wrap(underlyingAssetLCC0)
            .balanceOf(address(manager));
        uint256 preBalanceOfToken1UnderlyingAssetInPM = Currency
            .wrap(underlyingAssetLCC1)
            .balanceOf(address(manager));

        uint256 preBalanceOfToken0UnderlyingAssetInLCC = Currency
            .wrap(underlyingAssetLCC0)
            .balanceOf(Currency.unwrap(corePoolKey.currency0));
        uint256 preBalanceOfToken1UnderlyingAssetInLCC = Currency
            .wrap(underlyingAssetLCC1)
            .balanceOf(Currency.unwrap(corePoolKey.currency1));

        console.log(
            "preBalanceOfToken0UnderlyingAssetInPM",
            preBalanceOfToken0UnderlyingAssetInPM
        );
        console.log(
            "preBalanceOfToken1UnderlyingAssetInPM",
            preBalanceOfToken1UnderlyingAssetInPM
        );
        console.log(
            "preBalanceOfToken0UnderlyingAssetInLCC",
            preBalanceOfToken0UnderlyingAssetInLCC
        );
        console.log(
            "preBalanceOfToken1UnderlyingAssetInLCC",
            preBalanceOfToken1UnderlyingAssetInLCC
        );

        int256 swapAmount = 100;
        BalanceDelta delta = swapRouter.swap(
            corePoolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: int256(swapAmount),
                sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT
            }),
            settings,
            ZERO_BYTES
        );

        uint256 deltaAmount0 = LiquidityUtils.safeInt128ToUint256(
            delta.amount0()
        );
        uint256 deltaAmount1 = LiquidityUtils.safeInt128ToUint256(
            delta.amount1()
        );

        console.log("swap delta 0:", delta.amount0());
        console.log("swap delta 1:", delta.amount1());

        uint256 postBalanceOfToken0UnderlyingAssetInPM = Currency
            .wrap(underlyingAssetLCC0)
            .balanceOf(address(manager));
        uint256 postBalanceOfToken1UnderlyingAssetInPM = Currency
            .wrap(underlyingAssetLCC1)
            .balanceOf(address(manager));

        uint256 postBalanceOfToken0UnderlyingAssetInLCC = Currency
            .wrap(underlyingAssetLCC0)
            .balanceOf(Currency.unwrap(corePoolKey.currency0));
        uint256 postBalanceOfToken1UnderlyingAssetInLCC = Currency
            .wrap(underlyingAssetLCC1)
            .balanceOf(Currency.unwrap(corePoolKey.currency1));

        console.log(
            "postBalanceOfToken0UnderlyingAssetInPM",
            postBalanceOfToken0UnderlyingAssetInPM
        );
        console.log(
            "postBalanceOfToken1UnderlyingAssetInPM",
            postBalanceOfToken1UnderlyingAssetInPM
        );
        console.log(
            "postBalanceOfToken0UnderlyingAssetInLCC",
            postBalanceOfToken0UnderlyingAssetInLCC
        );
        console.log(
            "postBalanceOfToken1UnderlyingAssetInLCC",
            postBalanceOfToken1UnderlyingAssetInLCC
        );

        // validate liquidity of token-out(token0) in the lcc token is higher after the swap
        // because liquidity will move 'from pool-manager' token 'to LCC' token as it exits the pool during a one for zero swap
        assertEq(
            postBalanceOfToken0UnderlyingAssetInLCC -
                preBalanceOfToken0UnderlyingAssetInLCC,
            deltaAmount0
        );
        // validate liquidity of token-out(token0) in the pool manager is lower after the swap
        // becase liquidity of the underlying tokens will be moved from the pool-manager to LCC token
        // so the pool manager's underlying balance should decrease by the amount of token-out(token0) swapped out of the pool
        assertEq(
            preBalanceOfToken0UnderlyingAssetInPM -
                postBalanceOfToken0UnderlyingAssetInPM,
            deltaAmount0
        );
        // validate liquidity of token-in(token1) in the lcc token is lower after the swap
        // because liquidity will move 'from lcc' tokens 'to pool-manager' as it enters the pool during a one for zero swap
        assertEq(
            preBalanceOfToken1UnderlyingAssetInLCC -
                postBalanceOfToken1UnderlyingAssetInLCC,
            deltaAmount1
        );
        // validate liquidity of token-in(token1) in the pool manager is higher after the swap
        // because liquidity of the underlying tokens will be moved from LCC token to pool-manager
        // so the pool manager's underlying balance should increase by the amount of token-in(token1) swapped into of the pool
        assertEq(
            postBalanceOfToken1UnderlyingAssetInPM -
                preBalanceOfToken1UnderlyingAssetInPM,
            deltaAmount1
        );
    }

    // Test that a swap with limited liquidity on the proxy pool works as expected
    // when no hook data is provided, the swap with adjust the swap params to use the max available liquidity
    function test_swap_exactInput_oneForZeroOnProxy_withLimitedLiquidity_noHookData()
        public
    {
        // Mock limited available liquidity for output token in PM credits
        uint256 mockAvailableLiquidity = 50;
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(
                manager.balanceOf.selector,
                address(proxyHook),
                _currency1.toId()
            ),
            abi.encode(mockAvailableLiquidity)
        );
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        uint256 selfBalanceOfTokenABefore = proxyPoolKey
            .currency0
            .balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey
            .currency1
            .balanceOfSelf();

        console.log("selfBalanceOfTokenABefore", selfBalanceOfTokenABefore);
        console.log("selfBalanceOfTokenBBefore", selfBalanceOfTokenBBefore);

        uint256 swapAmount = 100;

        BalanceDelta swapDelta = swapRouter.swap(
            proxyPoolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT
            }),
            settings,
            ZERO_BYTES
        );

        console.log("====== actual deltas =======");
        console.log("delta 0:", swapDelta.amount0());
        console.log("delta 1:", swapDelta.amount1());

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey
            .currency0
            .balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey
            .currency1
            .balanceOfSelf();

        console.log("selfBalanceOfTokenAAfter", selfBalanceOfTokenAAfter);
        console.log("selfBalanceOfTokenBAfter", selfBalanceOfTokenBAfter);

        // diff
        console.log(
            "diff0",
            int256(selfBalanceOfTokenAAfter) - int256(selfBalanceOfTokenABefore)
        );
        console.log(
            "diff1",
            int256(selfBalanceOfTokenBAfter) - int256(selfBalanceOfTokenBBefore)
        );

        // With no hookData, params are adjusted so output <= available; there should be no deficit minted
        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());
        LiquidityCommitmentCertificate lccOut = lcc1.underlyingAsset() ==
            Currency.unwrap(_currency1)
            ? lcc1
            : lcc0;
        assertEq(lccOut.getMarketTotalSettlementDeficit(marketId), 0);
        // Locker (address(1)) should not hold LCC because no deficit
        assertEq(lccOut.balanceOf(address(1)), 0);

        vm.clearMockedCalls();
    }

    // Test that a swap with limited liquidity on the proxy pool works as expected
    // when no hook data is provided, the swap with adjust the swap params to use the max available liquidity
    function test_swap_exactInput_oneForZeroOnProxy_withLimitedLiquidity_withHookData()
        public
    {
        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());
        address lcc_recipient = makeAddr("lcc_recipient");
        console.log("lcc_recipient", lcc_recipient);
        console.log("marketId");
        console.logBytes32(marketId);

        uint256 mockAvailableLiquidity = 50;

        // use  mock call to make poolmanager balance of currency1 return a mock value
        // this way it appears as if there is no liquidity in the pool manager for output token
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(
                // to do
                manager.balanceOf.selector,
                address(proxyHook),
                _currency1.toId()
            ),
            abi.encode(mockAvailableLiquidity) // Return 0 liquidity
        );

        uint256 ua0Balance = mv.inMarketBalanceOf(proxyPoolKey.currency0);
        console.log("ua0Balance", ua0Balance);
        console.log(
            "proxyPoolKey.currency0",
            Currency.unwrap(proxyPoolKey.currency0)
        );
        uint256 ua1Balance = mv.inMarketBalanceOf(proxyPoolKey.currency1);
        console.log("ua1Balance", ua1Balance);
        console.log(
            "proxyPoolKey.currency1",
            Currency.unwrap(proxyPoolKey.currency1)
        );

        uint256 ua2balance = mv.inMarketBalanceOf(proxyPoolKey.currency1);
        console.log("ua2balance", ua2balance);
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        uint256 selfBalanceOfTokenABefore = proxyPoolKey
            .currency0
            .balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey
            .currency1
            .balanceOfSelf();

        console.log("selfBalanceOfTokenABefore", selfBalanceOfTokenABefore);
        console.log("selfBalanceOfTokenBBefore", selfBalanceOfTokenBBefore);

        uint256 swapAmount = 100;
        bytes memory hookData = abi.encode(lcc_recipient);
        console.log("hookData");
        console.logBytes(hookData);
        (BalanceDelta simulatedSwapDelta, , , ) = SwapSimulator.simulateSwap(
            manager,
            corePoolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT
            })
        );

        console.log("====== simulated deltas =======");
        console.log("delta 0:", simulatedSwapDelta.amount0());
        console.log("delta 1:", simulatedSwapDelta.amount1());
        uint256 expectedOutput = LiquidityUtils.safeInt128ToUint256(
            simulatedSwapDelta.amount1()
        );

        BalanceDelta swapDelta = swapRouter.swap(
            proxyPoolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT
            }),
            settings,
            hookData
        );
        console.log("====== actual deltas =======");
        console.log("delta 0:", swapDelta.amount0());
        console.log("delta 1:", swapDelta.amount1());

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey
            .currency0
            .balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey
            .currency1
            .balanceOfSelf();

        console.log("selfBalanceOfTokenAAfter", selfBalanceOfTokenAAfter);
        console.log("selfBalanceOfTokenBAfter", selfBalanceOfTokenBAfter);

        // diff
        console.log(
            "diff0",
            int256(selfBalanceOfTokenAAfter) - int256(selfBalanceOfTokenABefore)
        );
        console.log(
            "diff1",
            int256(selfBalanceOfTokenBAfter) - int256(selfBalanceOfTokenBBefore)
        );

        // check settlement queue for lcc_recipient in LCC token
        LiquidityCommitmentCertificate lccOut = lcc1.underlyingAsset() ==
            Currency.unwrap(_currency1)
            ? lcc1
            : lcc0;

        // validate user got lcc tokens and a pending settlement from this market
        uint256 deficit = expectedOutput - mockAvailableLiquidity;
        console.log("deficit", deficit);
        assertEq(
            lccOut.getSettlementAmountOwedTo(marketId, lcc_recipient),
            deficit
        );
        assertEq(lccOut.getMarketTotalSettlementDeficit(marketId), deficit);
        assertEq(lccOut.balanceOf(lcc_recipient), deficit);

        assertEq(_currency1.balanceOf(lcc_recipient), 0);

        // add some liquidity to the core pool to attempt to clear pending settlements
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1e18,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        assertEq(lccOut.getSettlementAmountOwedTo(marketId, lcc_recipient), 0);
        assertEq(lccOut.getMarketTotalSettlementDeficit(marketId), 0);
        assertEq(lccOut.balanceOf(lcc_recipient), 0);
        //confirm recippient got ua
        assertEq(_currency1.balanceOf(lcc_recipient), deficit);

        vm.clearMockedCalls();
    }

    // Additional tests

    function test_beforeInitialize_revertIfNotFactory() public {
        PoolKey memory testKey = PoolKey({
            currency0: _currency0,
            currency1: _currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(proxyHook)
        });

        vm.prank(address(manager));
        vm.expectRevert(ProxyHook.InvalidInitialiser.selector);
        proxyHook.beforeInitialize(address(1), testKey, SQRT_PRICE_1_1);
    }

    // More tests can be added for onDirectLP, unlockCallback, etc.
}

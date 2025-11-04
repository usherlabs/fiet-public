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
import {HookFlags} from "../src/libraries/HookFlags.sol";
// inherit from the MarketTestBase contract
import {MarketTestBase} from "./modules/MarketTestBase.sol";
import {SwapSimulator} from "../src/libraries/SwapSimulator.sol";
import {IMarketVault} from "../src/interfaces/IMarketVault.sol";

/**
 * 22nd October 2025 - ProxyHookTest.sol
 *     - Fail signature shows wrapper from ProxyHook address. With verbosity logs earlier, we saw SenderNotIssuer when ProxyHook called LCC.unwrapFromVault due to proxyHookToCurrencyPair returning 0,0 — we’ve corrected that in MarketTestBase to map to the LCCs’ underlying asset addresses. After that change, the suite progressed further but setUp moved to passing and individual proxy swap tests still revert.
 *     - The remaining Proxy swap test reverts are thrown by ProxyHook, likely on deficit recipient or flow guards. But the error selector in the latest runs shows generic revert without decoded custom error. We’ll address them next by ensuring the excess-recipient hookData is valid or by letting swaps operate without overflow. Given determineExcessRecipient returns address(0) by default, ProxyHook’s logic already guards to not emit and not set deficit recipient. The more likely culprit is insufficient available inMarket balances causing internal steps to underflow flow constraints.
 *     - We already mocked proxyHookToCurrencyPair correctly and MarketVault is active; next fix is to ensure balances in ProxyHook’s MarketVault are sufficient before proxy swaps. In these tests, initial inMarket balances exist via initial core LP providing LCC backing and on-direct LP path; however, ProxyHook’s settlement path first calls settleFromLCCToVault on direct LP events only. The proxy swap tests don’t perform direct LP and rely on pre-seeded inMarket balances from the setup. The harness has lcc0.wrap/lcc1.wrap(initialLiquidity) followed by core pool add-liquidity and ProxyHook._onDirectLP crediting vault from LCC on direct LP. That flow is working for “core” swap tests (they pass), but proxy swap is still reverting.
 */
contract ProxyHookTest is MarketTestBase {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    LiquidityCommitmentCertificate lcc0;
    LiquidityCommitmentCertificate lcc1;

    function setUp() public {
        _setupMarket();

        lcc0 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency2)));
        lcc1 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency3)));
    }

    function test_cannotModifyLiquidityOfProxyHook() public {
        vm.prank(address(manager));
        vm.expectRevert(ProxyHook.AddLiquidityThroughHookNotAllowed.selector);
        proxyHook.beforeAddLiquidity(
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
        console.log("====== test_swap_exactInput_zeroForOneOnProxy =======");

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
        console.log("====== test_swap_exactInput_oneForZeroOnProxy =======");

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();
        // proxy balance of tokens
        uint256 balanceOfTokenA = mv.inMarketBalanceOf(proxyPoolKey.currency0);
        uint256 balanceOfTokenB = mv.inMarketBalanceOf(proxyPoolKey.currency1);
        console.log("balanceOfTokenA", balanceOfTokenA);
        console.log("balanceOfTokenB", balanceOfTokenB);

        uint256 swapAmount = 100;
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT
            }),
            settings,
            ZERO_BYTES
        );

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey.currency1.balanceOfSelf();

        assertEq(selfBalanceOfTokenBBefore - selfBalanceOfTokenBAfter, swapAmount);
        assertGt(selfBalanceOfTokenAAfter, selfBalanceOfTokenABefore);
    }

    function test_swap_exactOutput_zeroForOneOnProxy() public {
        console.log("====== test_swap_exactOutput_zeroForOneOnProxy =======");

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

    // Tests that after a direct swap on the underlying liquidity of the lcc tokens are moved accordingly
    function test_swap_exactOutput_zeroForOneOnCore() public {
        console.log("====== test_swap_exactOutput_zeroForOneOnCore =======");

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // get balances of underlying token of the pool manager and lcc contracts
        // get the underlying asset of the lcc token A
        address underlyingAssetLCC0 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency0))).underlying();
        address underlyingAssetLCC1 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency1))).underlying();

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

        uint256 deltaAmount0 = LiquidityUtils.safeInt128ToUint256(delta.amount0());
        uint256 deltaAmount1 = LiquidityUtils.safeInt128ToUint256(delta.amount1());

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

    // Tests that after a direct swap on the underlying liquidity of the lcc tokens are moved accordingly
    function test_swap_exactOutput_oneForZeroOnCore() public {
        console.log("====== test_swap_exactOutput_oneForZeroOnCore =======");

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // get balances of underlying token of the pool manager and lcc contracts
        // get the underlying asset of the lcc token A
        address underlyingAssetLCC0 =
            LiquidityCommitmentCertificate(Currency.unwrap(corePoolKey.currency0)).underlying();
        address underlyingAssetLCC1 =
            LiquidityCommitmentCertificate(Currency.unwrap(corePoolKey.currency1)).underlying();

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

    // Test that a swap with limited liquidity on the proxy pool works as expected
    // when no hook data is provided, the swap with adjust the swap params to use the max available liquidity
    function test_swap_exactInput_oneForZeroOnProxy_withLimitedLiquidity_noHookData() public {
        console.log("====== test_swap_exactInput_oneForZeroOnProxy_withLimitedLiquidity_noHookData =======");

        // Mock limited available liquidity for output token in PM credits
        uint256 mockAvailableLiquidity = 50;
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(manager.balanceOf.selector, address(proxyHook), _currency1.toId()),
            abi.encode(mockAvailableLiquidity)
        );
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();

        console.log("selfBalanceOfTokenABefore", selfBalanceOfTokenABefore);
        console.log("selfBalanceOfTokenBBefore", selfBalanceOfTokenBBefore);

        uint256 swapAmount = 100;

        // Simulate what the full swap would produce
        (BalanceDelta simulatedSwapDelta,,,) = SwapSimulator.simulateSwap(
            manager,
            corePoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT})
        );
        uint256 expectedFullOutput = LiquidityUtils.safeInt128ToUint256(simulatedSwapDelta.amount1());
        console.log("Expected full output if unrestricted:", expectedFullOutput);

        BalanceDelta swapDelta = swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            settings,
            ZERO_BYTES
        );

        console.log("====== actual deltas =======");
        console.log("delta 0:", swapDelta.amount0());
        console.log("delta 1:", swapDelta.amount1());
        uint256 actualOutput = LiquidityUtils.safeInt128ToUint256(swapDelta.amount1());

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey.currency1.balanceOfSelf();

        console.log("selfBalanceOfTokenAAfter", selfBalanceOfTokenAAfter);
        console.log("selfBalanceOfTokenBAfter", selfBalanceOfTokenBAfter);

        // diff
        console.log("diff0", int256(selfBalanceOfTokenAAfter) - int256(selfBalanceOfTokenABefore));
        console.log("diff1", int256(selfBalanceOfTokenBAfter) - int256(selfBalanceOfTokenBBefore));

        // KEY BEHAVIOR: With no hookData, swap should be restricted to available liquidity
        // The actual output should be <= available liquidity, not the full expected output
        assertLe(actualOutput, mockAvailableLiquidity, "Output should be restricted to available liquidity");
        // The swap should use less input than requested if restricted
        uint256 actualInput = LiquidityUtils.safeInt128ToUint256(-swapDelta.amount0());
        assertLe(actualInput, swapAmount, "Input should be reduced when swap is restricted");

        // With no hookData, params are adjusted so output <= available; there should be no deficit minted
        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());
        LiquidityCommitmentCertificate lccOut = lcc1.underlying() == Currency.unwrap(_currency1) ? lcc1 : lcc0;
        assertEq(lccOut.getMarketTotalSettlementDeficit(marketId), 0, "No deficit should be created without recipient");
        // Locker (address(1)) should not hold LCC because no deficit
        assertEq(lccOut.balanceOf(address(1)), 0, "Locker should not receive LCC");

        vm.clearMockedCalls();
    }

    // Test that a swap with limited liquidity on the proxy pool works as expected
    // when hookData with recipient IS provided, the swap should NOT be restricted and excess LCC should go to recipient
    function test_swap_exactInput_zeroForOneOnProxy_withLimitedLiquidity_withHookData() public {
        console.log("====== test_swap_exactInput_zeroForOneOnProxy_withLimitedLiquidity_withHookData =======");

        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());
        address lcc_recipient = makeAddr("lcc_recipient");
        // mock the call to the factory to return false for protocol bound
        // i.e make sure that in this function the lcc_recipient is not marked as a protocol bound address
        // this would enable market tracing for lcc gotten
        vm.mockCall(
            address(marketFactory),
            abi.encodeWithSelector(IMarketFactory.bounds.selector, lcc_recipient),
            abi.encode(false)
        );
        console.log("excess lcc_recipient", lcc_recipient);
        console.log("marketId:");
        console.logBytes32(marketId);

        // this means we are mocking the available liquidity of the output token to be 50
        // i.e less than output swap amount in order to simulate the liquidity queue functionality
        uint256 mockAvailableOutputLiquidity = 50;

        // use mock call to make poolmanager balance of currency1 return a mock value
        // this way it appears as if there is little liquidity in the pool manager for output token
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(manager.balanceOf.selector, address(proxyHook), _currency1.toId()),
            abi.encode(mockAvailableOutputLiquidity)
        );

        uint256 ua0Balance = mv.inMarketBalanceOf(proxyPoolKey.currency0);
        console.log("ua0Balance", ua0Balance);
        console.log("proxyPoolKey.currency0", Currency.unwrap(proxyPoolKey.currency0));
        uint256 ua1Balance = mv.inMarketBalanceOf(proxyPoolKey.currency1);
        console.log("ua1Balance", ua1Balance);
        console.log("proxyPoolKey.currency1", Currency.unwrap(proxyPoolKey.currency1));

        uint256 ua2balance = mv.inMarketBalanceOf(proxyPoolKey.currency1);
        console.log("ua2balance", ua2balance);
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();

        console.log("selfBalanceOfTokenABefore", selfBalanceOfTokenABefore);
        console.log("selfBalanceOfTokenBBefore", selfBalanceOfTokenBBefore);

        uint256 swapAmount = 100;
        bytes memory hookData = abi.encode(lcc_recipient);
        (BalanceDelta simulatedSwapDelta,,,) = SwapSimulator.simulateSwap(
            manager,
            corePoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT})
        );

        console.log("====== simulated deltas =======");
        console.log("delta 0:", simulatedSwapDelta.amount0());
        console.log("delta 1:", simulatedSwapDelta.amount1());
        uint256 expectedOutput = LiquidityUtils.safeInt128ToUint256(simulatedSwapDelta.amount1());
        uint256 expectedInput = LiquidityUtils.safeInt128ToUint256(-simulatedSwapDelta.amount0());

        BalanceDelta swapDelta = swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            settings,
            hookData
        );

        console.log("====== actual deltas =======");
        console.log("delta 0:", swapDelta.amount0());
        console.log("delta 1:", swapDelta.amount1());
        uint256 actualOutput = LiquidityUtils.safeInt128ToUint256(swapDelta.amount1());
        uint256 actualInput = LiquidityUtils.safeInt128ToUint256(-swapDelta.amount0());

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey.currency1.balanceOfSelf();

        console.log("selfBalanceOfTokenAAfter", selfBalanceOfTokenAAfter);
        console.log("selfBalanceOfTokenBAfter", selfBalanceOfTokenBAfter);

        // check how much the balance of the tokens have changed
        // this should be equal to the swap amount
        console.log("diff0", int256(selfBalanceOfTokenAAfter) - int256(selfBalanceOfTokenABefore));
        // validate that the balance of the output token has increased by the output of the swap
        console.log("diff1", int256(selfBalanceOfTokenBAfter) - int256(selfBalanceOfTokenBBefore));

        // KEY BEHAVIOR: With hookData recipient provided, swap should NOT be restricted
        // The actual output should match the expected full output, not be limited to available liquidity
        assertEq(actualOutput, expectedOutput, "Output should NOT be restricted when recipient is provided");
        assertEq(actualInput, expectedInput, "Input should match full swap when recipient is provided");
        assertGt(
            actualOutput,
            mockAvailableOutputLiquidity,
            "Output should exceed available liquidity when recipient provided"
        );

        // check settlement queue for lcc_recipient in LCC token
        LiquidityCommitmentCertificate lccOut = lcc1.underlying() == Currency.unwrap(_currency1) ? lcc1 : lcc0;

        // validate user got lcc tokens and a pending settlement from this market
        uint256 deficit = expectedOutput - mockAvailableOutputLiquidity;

        // KEY BEHAVIOR: Excess LCC should be minted to the recipient
        assertGt(deficit, 0, "Deficit should exist when output exceeds available liquidity");
        // validate the market tracking logic works and the lcc is mapped to the current market
        uint256 marketBalance = lccOut.getBalanceOfUserFromMarket(lcc_recipient, marketId);
        assertEq(marketBalance, deficit, "Recipient should receive LCC equal to deficit");

        // mock as the lcc recipient
        // unwrap the lcc tokens to get the underlying asseet
        vm.prank(lcc_recipient);
        lccOut.unwrap(deficit);
        vm.stopPrank();

        // get amount owed to this particular recipient
        uint256 amountOwedToRecipient = lccOut.getSettlementAmountOwedTo(marketId, lcc_recipient);

        // validate the amount owed to the recipient is the attempted unwrap amount
        // and that the user still has their LCC tokens
        assertEq(amountOwedToRecipient, deficit, "Amount owed should equal deficit");
        assertEq(lccOut.balanceOf(lcc_recipient), deficit, "Recipient should hold LCC tokens");

        // add some liquidity to the core pool to attempt to clear pending settlements
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            ZERO_BYTES
        );

        assertEq(lccOut.getSettlementAmountOwedTo(marketId, lcc_recipient), 0);
        assertEq(lccOut.getMarketTotalSettlementDeficit(marketId), 0);
        assertEq(lccOut.balanceOf(lcc_recipient), 0);
        //confirm recippient got ua
        assertEq(_currency1.balanceOf(lcc_recipient), deficit);

        vm.clearMockedCalls();
    }

    /**
     * @notice Comprehensive test demonstrating the fork in behavior based on recipient presence
     * @dev This test explicitly compares:
     *  1. Without recipient: Swap is restricted to available liquidity, no deficit created
     *  2. With recipient: Swap executes full amount, excess LCC minted to recipient
     */
    function test_swapBehaviorFork_withAndWithoutRecipient() public {
        console.log("====== test_swapBehaviorFork_withAndWithoutRecipient =======");

        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());
        uint256 mockAvailableLiquidity = 50;
        uint256 swapAmount = 100;

        // Simulate what the full swap would produce
        (BalanceDelta simulatedSwapDelta,,,) = SwapSimulator.simulateSwap(
            manager,
            corePoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT})
        );
        uint256 expectedFullOutput = LiquidityUtils.safeInt128ToUint256(simulatedSwapDelta.amount1());
        uint256 expectedFullInput = LiquidityUtils.safeInt128ToUint256(-simulatedSwapDelta.amount0());

        // Mock limited available liquidity
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(manager.balanceOf.selector, address(proxyHook), _currency1.toId()),
            abi.encode(mockAvailableLiquidity)
        );

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        LiquidityCommitmentCertificate lccOut = lcc1.underlying() == Currency.unwrap(_currency1) ? lcc1 : lcc0;

        // ===== TEST 1: WITHOUT RECIPIENT (restricted swap) =====
        uint256 balanceBeforeNoRecipient = proxyPoolKey.currency0.balanceOfSelf();
        BalanceDelta deltaNoRecipient = swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            settings,
            ZERO_BYTES
        );
        uint256 outputNoRecipient = LiquidityUtils.safeInt128ToUint256(deltaNoRecipient.amount1());
        uint256 inputNoRecipient = LiquidityUtils.safeInt128ToUint256(-deltaNoRecipient.amount0());

        // Verify restricted behavior
        assertLe(outputNoRecipient, mockAvailableLiquidity, "Without recipient: output should be restricted");
        assertLe(inputNoRecipient, swapAmount, "Without recipient: input should be reduced");
        assertLt(outputNoRecipient, expectedFullOutput, "Without recipient: output should be less than full swap");
        assertEq(lccOut.getMarketTotalSettlementDeficit(marketId), 0, "Without recipient: no deficit should be created");

        // ===== TEST 2: WITH RECIPIENT (unrestricted swap) =====
        address recipient = makeAddr("recipient");
        vm.mockCall(
            address(marketFactory), abi.encodeWithSelector(IMarketFactory.bounds.selector, recipient), abi.encode(false)
        );

        // Reset mock for second swap
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(manager.balanceOf.selector, address(proxyHook), _currency1.toId()),
            abi.encode(mockAvailableLiquidity)
        );

        uint256 balanceBeforeWithRecipient = proxyPoolKey.currency0.balanceOfSelf();
        BalanceDelta deltaWithRecipient = swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            settings,
            abi.encode(recipient)
        );
        uint256 outputWithRecipient = LiquidityUtils.safeInt128ToUint256(deltaWithRecipient.amount1());
        uint256 inputWithRecipient = LiquidityUtils.safeInt128ToUint256(-deltaWithRecipient.amount0());

        // Verify unrestricted behavior
        assertEq(outputWithRecipient, expectedFullOutput, "With recipient: output should NOT be restricted");
        assertEq(inputWithRecipient, expectedFullInput, "With recipient: input should match full swap");
        assertGt(
            outputWithRecipient, mockAvailableLiquidity, "With recipient: output should exceed available liquidity"
        );

        // Verify excess LCC goes to recipient
        uint256 deficit = expectedFullOutput - mockAvailableLiquidity;
        assertGt(deficit, 0, "Deficit should exist");
        uint256 recipientBalance = lccOut.getBalanceOfUserFromMarket(recipient, marketId);
        assertEq(recipientBalance, deficit, "Recipient should receive LCC equal to deficit");
        assertEq(lccOut.balanceOf(recipient), deficit, "Recipient should hold LCC tokens");

        // Verify market deficit is tracked
        assertEq(lccOut.getMarketTotalSettlementDeficit(marketId), deficit, "Market deficit should be tracked");

        vm.clearMockedCalls();
    }

    // Additional tests
    function test_beforeInitialize_revertIfNotFactory() public {
        PoolKey memory testKey = PoolKey({
            currency0: _currency0, currency1: _currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(proxyHook)
        });

        vm.prank(address(manager));
        vm.expectRevert(ProxyHook.InvalidInitialiser.selector);
        proxyHook.beforeInitialize(address(1), testKey, SQRT_PRICE_1_1);
    }

    // More tests can be added for onDirectLP, unlockCallback, etc.
}

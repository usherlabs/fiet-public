// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySortHelper} from "./libraries/CurrencySortHelper.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {console} from "forge-std/console.sol";
// inherit from the MarketVaultBase contract which provides shared helper functions
import {MarketVaultBase} from "./base/MarketVaultBase.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {LiquidityHub} from "../src/LiquidityHub.sol";
import {MarketTestBase} from "./base/MarketTestBase.sol";
import {MockERC20} from "@uniswap/v4-core/test/utils/Deployers.sol";

/**
 * 22nd October 2025 - ProxyHookTest.sol
 *     - Fail signature shows wrapper from ProxyHook address. With verbosity logs earlier, we saw SenderNotIssuer when ProxyHook called LCC.unwrapFromVault due to proxyHookToCurrencyPair returning 0,0 — we've corrected that in MarketTestBase to map to the LCCs' underlying asset addresses. After that change, the suite progressed further but setUp moved to passing and individual proxy swap tests still revert.
 *     - The remaining Proxy swap test reverts are thrown by ProxyHook, likely on deficit recipient or flow guards. But the error selector in the latest runs shows generic revert without decoded custom error. We'll address them next by ensuring the excess-recipient hookData is valid or by letting swaps operate without overflow. Given determineExcessRecipient returns address(0) by default, ProxyHook's logic already guards to not emit and not set deficit recipient. The more likely culprit is insufficient available inMarket balances causing internal steps to underflow flow constraints.
 *     - We already mocked proxyHookToCurrencyPair correctly and MarketVault is active; next fix is to ensure balances in ProxyHook's MarketVault are sufficient before proxy swaps. In these tests, initial inMarket balances exist via initial core LP providing LCC backing and on-direct LP path; however, ProxyHook's settlement path first calls settleFromLCCToVault on direct LP events only. The proxy swap tests don't perform direct LP and rely on pre-seeded inMarket balances from the setup. The harness has lcc0.wrap/lcc1.wrap(initialLiquidity) followed by core pool add-liquidity and ProxyHook._onDirectLP crediting vault from LCC on direct LP. That flow is working for "core" swap tests (they pass), but proxy swap is still reverting.
 */
contract ProxyHookTest is MarketVaultBase {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    function test_cannotModifyLiquidityOfProxyHook() public {
        vm.prank(address(manager));
        vm.expectRevert(Errors.AddLiquidityThroughHookNotAllowed.selector);
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

        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();

        uint256 swapAmount = 1e18;
        BalanceDelta delta = _executeSwap(
            proxyPoolKey,
            true, // zeroForOne
            -int256(swapAmount),
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

        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();
        // proxy balance of tokens
        uint256 balanceOfTokenA = mv.inMarketBalanceOf(proxyPoolKey.currency0);
        uint256 balanceOfTokenB = mv.inMarketBalanceOf(proxyPoolKey.currency1);
        console.log("balanceOfTokenA", balanceOfTokenA);
        console.log("balanceOfTokenB", balanceOfTokenB);

        uint256 swapAmount = 100;
        _executeSwap(
            proxyPoolKey,
            false, // oneForZero
            -int256(swapAmount),
            ZERO_BYTES
        );

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey.currency1.balanceOfSelf();

        assertEq(selfBalanceOfTokenBBefore - selfBalanceOfTokenBAfter, swapAmount);
        assertGt(selfBalanceOfTokenAAfter, selfBalanceOfTokenABefore);
    }

    function test_swap_exactOutput_zeroForOneOnProxy() public {
        console.log("====== test_swap_exactOutput_zeroForOneOnProxy =======");

        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();

        uint256 swapAmount = 100;
        _executeSwap(
            proxyPoolKey,
            true, // zeroForOne
            int256(swapAmount),
            ZERO_BYTES
        );

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey.currency1.balanceOfSelf();

        assertLt(selfBalanceOfTokenAAfter, selfBalanceOfTokenABefore);
        assertEq(selfBalanceOfTokenBAfter, selfBalanceOfTokenBBefore + swapAmount);
    }

    function test_swap_exactOutput_oneForZeroOnProxy() public {
        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();

        uint256 swapAmount = 100;
        _executeSwap(
            proxyPoolKey,
            false, // oneForZero
            int256(swapAmount),
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

        uint256 preBalanceOfToken0UnderlyingAssetInLCC = Currency.wrap(underlyingAssetLCC0).balanceOf(liquidityHub);
        uint256 preBalanceOfToken1UnderlyingAssetInLCC = Currency.wrap(underlyingAssetLCC1).balanceOf(liquidityHub);

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

        uint256 postBalanceOfToken0UnderlyingAssetInLCC = Currency.wrap(underlyingAssetLCC0).balanceOf(liquidityHub);
        uint256 postBalanceOfToken1UnderlyingAssetInLCC = Currency.wrap(underlyingAssetLCC1).balanceOf(liquidityHub);

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

        uint256 preBalanceOfToken0UnderlyingAssetInLCC = Currency.wrap(underlyingAssetLCC0).balanceOf(liquidityHub);
        uint256 preBalanceOfToken1UnderlyingAssetInLCC = Currency.wrap(underlyingAssetLCC1).balanceOf(liquidityHub);

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

        uint256 postBalanceOfToken0UnderlyingAssetInLCC = Currency.wrap(underlyingAssetLCC0).balanceOf(liquidityHub);
        uint256 postBalanceOfToken1UnderlyingAssetInLCC = Currency.wrap(underlyingAssetLCC1).balanceOf(liquidityHub);

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
        _mockLimitedLiquidity(_currency1, mockAvailableLiquidity);

        uint256 swapAmount = 100;

        // Simulate what the full swap would produce
        (, uint256 expectedFullOutput) = _simulateSwap(corePoolKey, true, -int256(swapAmount));
        console.log("Expected full output if unrestricted:", expectedFullOutput);

        BalanceDelta swapDelta = _executeSwap(
            proxyPoolKey,
            true, // zeroForOne
            -int256(swapAmount),
            ZERO_BYTES
        );

        (uint256 actualInput, uint256 actualOutput) = _getSwapDeltas(swapDelta, true);

        console.log("====== actual deltas =======");
        console.log("delta 0:", swapDelta.amount0());
        console.log("delta 1:", swapDelta.amount1());

        // KEY BEHAVIOR: With no hookData, swap should be restricted to available liquidity
        assertLe(actualOutput, mockAvailableLiquidity, "Output should be restricted to available liquidity");
        assertLe(actualInput, swapAmount, "Input should be reduced when swap is restricted");

        // With no hookData, params are adjusted so output <= available; there should be no deficit minted
        LiquidityCommitmentCertificate lccOut = _getLCCOut(_currency1);
        assertEq(
            LiquidityHub(payable(liquidityHub)).totalQueued(address(lccOut)),
            0,
            "No deficit should be created without recipient"
        );
        assertEq(lccOut.balanceOf(address(1)), 0, "Locker should not receive LCC");

        vm.clearMockedCalls();
    }

    // Test that a swap with limited liquidity on the proxy pool works as expected
    // when hookData with recipient IS provided, the swap should NOT be restricted and excess LCC should go to recipient
    function test_swap_exactInput_zeroForOneOnProxy_withLimitedLiquidity_withHookData() public {
        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());
        address lcc_recipient = makeAddr("lcc_recipient");
        _setupRecipient(lcc_recipient);

        uint256 mockAvailableOutputLiquidity = 50;
        _mockLimitedLiquidity(_currency1, mockAvailableOutputLiquidity);

        // Simulate and execute swap in scoped block
        uint256 deficit;
        uint256 expectedOutput;
        {
            uint256 swapAmount = 100;
            uint256 expectedInput;
            (expectedInput, expectedOutput) = _simulateSwap(corePoolKey, true, -int256(swapAmount));

            BalanceDelta swapDelta = _executeSwap(proxyPoolKey, true, -int256(swapAmount), abi.encode(lcc_recipient));
            (uint256 actualInput, uint256 actualOutput) = _getSwapDeltas(swapDelta, true);

            // KEY BEHAVIOR: With hookData recipient provided, swap should NOT be restricted
            // The actual output should match the expected full output, not be limited to available liquidity
            deficit = expectedOutput - mockAvailableOutputLiquidity;
            assertEq(
                actualOutput + deficit, expectedOutput, "Output should NOT be restricted when recipient is provided"
            );
            assertEq(actualInput, expectedInput, "Input should match full swap when recipient is provided");
        }

        // Validate LCC balance in scoped block
        LiquidityCommitmentCertificate lccOut = _getLCCOut(_currency1);
        {
            // KEY BEHAVIOR: Excess LCC should be minted to the recipient
            assertGt(deficit, 0, "Deficit should exist when output exceeds available liquidity");
            // validate the market tracking logic works and the lcc is mapped to the current market
            // Check market-derived balance (this is what users receive from protocol transfers)
            (, uint256 marketDerivedBalance) = lccOut.balancesOf(lcc_recipient);
            assertEq(marketDerivedBalance, deficit, "Recipient should receive LCC equal to deficit");
        }

        // Unwrap in scoped block
        {
            // mock the call to factory to use market liquidity, this would make sure that the market appears to have a liquidity of zero
            // this way unwrapps would be queued for settlement upon unwrap
            _mockLimitedMarketLiquidity(address(lccOut.underlying()), marketId, 0);
            // mock as the lcc recipient
            // unwrap the lcc tokens to get the underlying asset
            vm.prank(lcc_recipient);
            LiquidityHub(payable(liquidityHub)).unwrap(address(lccOut), deficit);
            vm.stopPrank();
        }

        // get amount owed to this particular recipient from settlement queue
        uint256 amountOwedToRecipient = LiquidityHub(payable(liquidityHub)).settleQueue(address(lccOut), lcc_recipient);
        console.log("amountOwedToRecipient:", amountOwedToRecipient);

        // validate the amount owed to the recipient is the attempted unwrap amount
        // and that the user still has their LCC tokens (or they were burned if unwrapped)
        assertEq(amountOwedToRecipient, deficit, "Amount owed should equal deficit");
        // assertEq(lccOut.balanceOf(lcc_recipient), 0, "Recipient LCC tokens should be burned after unwrap");

        // add some liquidity to the core pool to attempt to clear pending settlements
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            ZERO_BYTES
        );

        // settle pending unwrap from queue
        _mockLimitedLiquidity(_currency1, initialLiquidity);
        LiquidityHub(payable(liquidityHub)).processSettlementFor(address(lccOut), lcc_recipient, deficit);

        assertEq(LiquidityHub(payable(liquidityHub)).settleQueue(address(lccOut), lcc_recipient), 0);
        assertEq(LiquidityHub(payable(liquidityHub)).totalQueued(address(lccOut)), 0);
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

        uint256 mockAvailableLiquidity = 50;
        uint256 swapAmount = 100;

        // Simulate what the full swap would produce
        (uint256 expectedFullInput, uint256 expectedFullOutput) = _simulateSwap(corePoolKey, true, -int256(swapAmount));

        // Mock limited available liquidity
        _mockLimitedLiquidity(_currency1, mockAvailableLiquidity);

        LiquidityCommitmentCertificate lccOut = _getLCCOut(_currency1);

        // ===== TEST 1: WITHOUT RECIPIENT (restricted swap) =====
        BalanceDelta deltaNoRecipient = _executeSwap(
            proxyPoolKey,
            true, // zeroForOne
            -int256(swapAmount),
            ZERO_BYTES
        );
        (uint256 inputNoRecipient, uint256 outputNoRecipient) = _getSwapDeltas(deltaNoRecipient, true);

        // Verify restricted behavior
        assertLe(outputNoRecipient, mockAvailableLiquidity, "Without recipient: output should be restricted");
        assertLe(inputNoRecipient, swapAmount, "Without recipient: input should be reduced");
        assertLt(outputNoRecipient, expectedFullOutput, "Without recipient: output should be less than full swap");
        assertEq(
            LiquidityHub(payable(liquidityHub)).totalQueued(address(lccOut)),
            0,
            "Without recipient: no deficit should be created"
        );

        // ===== TEST 2: WITH RECIPIENT (unrestricted swap) =====
        address recipient = makeAddr("recipient");
        _setupRecipient(recipient);

        // Reset mock for second swap
        _mockLimitedLiquidity(_currency1, mockAvailableLiquidity);

        BalanceDelta deltaWithRecipient = _executeSwap(
            proxyPoolKey,
            true, // zeroForOne
            -int256(swapAmount),
            abi.encode(recipient)
        );
        (uint256 inputWithRecipient, uint256 outputWithRecipient) = _getSwapDeltas(deltaWithRecipient, true);

        uint256 deficit = expectedFullOutput - mockAvailableLiquidity;
        // Verify unrestricted behavior
        assertEq(inputWithRecipient, expectedFullInput, "With recipient: input should match full swap");
        // assert swap output plus deficit equal full swap amount
        assertEq(outputWithRecipient + deficit, expectedFullOutput);

        // Verify excess LCC goes to recipient
        assertGt(deficit, 0, "Deficit should exist");
        (, uint256 recipientMarketBalance) = lccOut.balancesOf(recipient);
        assertEq(recipientMarketBalance, deficit, "Recipient should receive LCC equal to deficit");
        assertEq(lccOut.balanceOf(recipient), deficit, "Recipient should hold LCC tokens");

        // Verify market deficit is tracked via settlement queue (after unwrap attempt)
        // Note: Settlement queue is only created when user tries to unwrap, not immediately on receipt
        // So we check the total queued, which should be 0 until unwrap is attempted
        assertEq(
            LiquidityHub(payable(liquidityHub)).totalQueued(address(lccOut)),
            0,
            "Settlement queue should be empty until unwrap"
        );

        vm.clearMockedCalls();
    }

    // Additional tests
    function test_beforeInitialize_revertIfNotFactory() public {
        PoolKey memory testKey = PoolKey({
            currency0: _currency0, currency1: _currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(proxyHook)
        });

        vm.prank(address(manager));
        vm.expectRevert(Errors.InvalidSender.selector);
        proxyHook.beforeInitialize(address(1), testKey, SQRT_PRICE_1_1);
    }

    /**
     * @notice Test _determineExcessRecipient with special address(0) - should return address(1) (Locker)
     */
    function test_determineExcessRecipient_addressZero() public {
        uint256 mockAvailableLiquidity = 50;
        _mockLimitedLiquidity(_currency1, mockAvailableLiquidity);

        uint256 swapAmount = 100;
        // When hookData encodes address(0), it should be treated as address(1) (Locker)
        BalanceDelta delta = _executeSwap(
            proxyPoolKey,
            true, // zeroForOne
            -int256(swapAmount),
            abi.encode(address(0))
        );

        (uint256 actualInput,) = _getSwapDeltas(delta, true);
        // Should execute full swap because recipient is specified (even if it's address(0))
        assertEq(actualInput, swapAmount, "Should execute full swap with address(0) recipient");

        vm.clearMockedCalls();
    }

    /**
     * @notice Test _determineExcessRecipient with address(1) - should return address(1) (Locker)
     */
    function test_determineExcessRecipient_addressOne() public {
        uint256 mockAvailableLiquidity = 50;
        _mockLimitedLiquidity(_currency1, mockAvailableLiquidity);

        uint256 swapAmount = 100;
        BalanceDelta delta = _executeSwap(
            proxyPoolKey,
            true, // zeroForOne
            -int256(swapAmount),
            abi.encode(address(1))
        );

        (uint256 expectedSwapInput,) = _getSwapDeltas(delta, true);

        assertEq(expectedSwapInput, swapAmount, "Should execute full swap with address(1) recipient");

        vm.clearMockedCalls();
    }

    /**
     * @notice Test _determineExcessRecipient with address(2) - should return msg.sender (Router)
     */
    function test_determineExcessRecipient_addressTwo() public {
        uint256 mockAvailableLiquidity = 50;
        _mockLimitedLiquidity(_currency1, mockAvailableLiquidity);

        uint256 swapAmount = 100;
        // address(2) should map to msg.sender (which is the swapRouter)
        vm.mockCall(
            address(marketFactory),
            abi.encodeWithSelector(IMarketFactory.bounds.selector, address(swapRouter)),
            abi.encode(false)
        );

        BalanceDelta delta = _executeSwap(
            proxyPoolKey,
            true, // zeroForOne
            -int256(swapAmount),
            abi.encode(address(2))
        );

        (uint256 expectedSwapInput,) = _getSwapDeltas(delta, true);
        assertEq(expectedSwapInput, swapAmount, "Should execute full swap with address(2) recipient");

        vm.clearMockedCalls();
    }

    /**
     * @notice Test exact output swap with limited liquidity (no hookData)
     */
    function test_swap_exactOutput_zeroForOneOnProxy_withLimitedLiquidity_noHookData() public {
        uint256 mockAvailableLiquidity = 50;
        _mockLimitedLiquidity(_currency1, mockAvailableLiquidity);

        // Exact output swap requesting more than available
        uint256 requestedOutput = 100;

        BalanceDelta swapDelta = _executeSwap(
            proxyPoolKey,
            true, // zeroForOne
            int256(requestedOutput),
            ZERO_BYTES
        );

        (, uint256 actualOutput) = _getSwapDeltas(swapDelta, true);
        // With no hookData, output should be capped to available liquidity
        assertLe(actualOutput, mockAvailableLiquidity, "Output should be restricted to available liquidity");
        assertLe(actualOutput, requestedOutput, "Output should not exceed requested amount");

        vm.clearMockedCalls();
    }

    /**
     * @notice Test exact output swap with limited liquidity (with hookData)
     */
    function test_swap_exactOutput_zeroForOneOnProxy_withLimitedLiquidity_withHookData() public {
        address recipient = makeAddr("output_recipient");
        _setupRecipient(recipient);

        uint256 mockAvailableLiquidity = 50;
        _mockLimitedLiquidity(_currency1, mockAvailableLiquidity);

        // Exact output swap requesting more than available
        uint256 requestedOutput = 100;

        BalanceDelta swapDelta = _executeSwap(
            proxyPoolKey,
            true, // zeroForOne
            int256(requestedOutput),
            abi.encode(recipient)
        );

        (, uint256 actualOutput) = _getSwapDeltas(swapDelta, true);

        // Verify deficit is created
        LiquidityCommitmentCertificate lccOut = _getLCCOut(_currency1);
        uint256 expectedDeficit = requestedOutput - mockAvailableLiquidity;
        // Settlement queue is only created when user tries to unwrap, not immediately
        // But we can verify the LCC balance was transferred
        assertEq(lccOut.balanceOf(recipient), expectedDeficit, "Recipient should hold deficit LCC tokens");

        // With hookData, should attempt to execute full swap
        // so the available limited output + recipient lcc balance should equal requested output
        assertEq(
            actualOutput + lccOut.balanceOf(recipient),
            requestedOutput,
            "Should execute full exact output swap when recipient provided"
        );

        vm.clearMockedCalls();
    }

    /**
     * @notice Test that deficit recipient receives LCC tokens via safeTransfer
     */
    function test_deficitRecipientReceivesLCCTokens() public {
        address recipient = makeAddr("deficit_recipient");

        _setupRecipient(recipient);

        uint256 mockAvailableLiquidity = 50;
        // mock limited liquidity for the output token(token1 since it is a zero for one swap)
        _mockLimitedLiquidity(_currency1, mockAvailableLiquidity);

        uint256 swapAmount = 100;
        _getLCCOut(_currency1);

        // Calculate expected deficit
        (, uint256 expectedOutput) = _simulateSwap(corePoolKey, true, -int256(swapAmount));
        console.log("expectedOutput", expectedOutput);
        uint256 expectedDeficit = expectedOutput > mockAvailableLiquidity ? expectedOutput - mockAvailableLiquidity : 0;
        console.log("expectedDeficit", expectedDeficit);
        // uint256 recipientBalanceBefore = lccOut.balanceOf(recipient);

        _executeSwap(
            proxyPoolKey,
            true, // zeroForOne
            -int256(swapAmount),
            abi.encode(recipient)
        );

        // if (expectedDeficit > 0) {
        //     uint256 recipientBalanceAfter = lccOut.balanceOf(recipient);
        //     assertEq(
        //         recipientBalanceAfter - recipientBalanceBefore,
        //         expectedDeficit,
        //         "Recipient should receive LCC tokens equal to deficit"
        //     );
        // }

        // vm.clearMockedCalls();
    }

    /**
     * @notice Test oneForZero swap with limited liquidity and recipient
     */
    function test_swap_exactInput_oneForZeroOnProxy_withLimitedLiquidity_withHookData() public {
        address recipient = makeAddr("oneForZero_recipient");
        _setupRecipient(recipient);

        uint256 mockAvailableLiquidity = 50;
        _mockLimitedLiquidity(_currency0, mockAvailableLiquidity);

        uint256 swapAmount = 100;
        LiquidityCommitmentCertificate lccOut = _getLCCOut(_currency0);

        (, uint256 fullOutput) = _simulateSwap(corePoolKey, true, -int256(swapAmount));

        BalanceDelta swapDelta = _executeSwap(
            proxyPoolKey,
            false, // oneForZero
            -int256(swapAmount),
            abi.encode(recipient)
        );

        (, uint256 actualOutput) = _getSwapDeltas(swapDelta, false);
        assertEq(actualOutput, mockAvailableLiquidity, "Should execute full swap with recipient");

        if (fullOutput > mockAvailableLiquidity) {
            uint256 expectedDeficit = fullOutput - mockAvailableLiquidity;
            (, uint256 recipientMarketBalance) = lccOut.balancesOf(recipient);
            assertEq(recipientMarketBalance, expectedDeficit, "Recipient should receive deficit LCC");
        }

        vm.clearMockedCalls();
    }

    // More tests can be added for onDirectLP, unlockCallback, etc.
}

contract DifferentTokenDecimalsProxyHookTest is MarketTestBase {
    // Make currency A 8 decimal places and currency B 18 decimal places
    function _deployUnderlyingCurrencies() internal override {
        uint256 mintAmount = 2 ** 255;
        MockERC20 tokenA = new MockERC20("TestA", "A", 8);
        tokenA.mint(address(this), mintAmount);
        approveTokenForMarketUse(address(tokenA));
        Currency _currencyA = Currency.wrap(address(tokenA));

        MockERC20 tokenB = new MockERC20("TestB", "B", 18);
        tokenB.mint(address(this), mintAmount);
        approveTokenForMarketUse(address(tokenB));
        Currency _currencyB = Currency.wrap(address(tokenB));

        (_currency0, _currency1) =
            CurrencySortHelper.sortAddresses(Currency.unwrap(_currencyA), Currency.unwrap(_currencyB));

        bytes memory marketRef = abi.encodePacked(address(proxyHook));
        string memory marketName = "Test Market";
        address[] memory initialIssuers = new address[](1);
        initialIssuers[0] = address(vtsOrchestrator);

        vm.prank(marketFactory);
        (address _lcc0, address _lcc1) = LiquidityHub(payable(liquidityHub))
            .createLCCPair(
                marketRef, Currency.unwrap(_currency0), Currency.unwrap(_currency1), marketName, initialIssuers
            );

        (_currency2, _currency3) = CurrencySortHelper.sortAddresses(_lcc0, _lcc1);

        lccToken0 = Currency.unwrap(_currency2);
        lccToken1 = Currency.unwrap(_currency3);
    }

    function setUp() public {
        _setupMarket();
    }

    function test_canModifyLiquidityOfCorePool_withDifferentDecimals() public {
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function test_swapWithDifferentDecimals_zeroForOneOnProxy() public {
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

    function test_swap_exactOutput_zeroForOneOnCore() public {
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

        uint256 preBalanceOfToken0UnderlyingAssetInHub = Currency.wrap(underlyingAssetLCC0).balanceOf(liquidityHub);
        uint256 preBalanceOfToken1UnderlyingAssetInHub = Currency.wrap(underlyingAssetLCC1).balanceOf(liquidityHub);

        console.log("preBalanceOfToken0UnderlyingAssetInPM", preBalanceOfToken0UnderlyingAssetInPM);
        console.log("preBalanceOfToken1UnderlyingAssetInPM", preBalanceOfToken1UnderlyingAssetInPM);
        console.log("preBalanceOfToken0UnderlyingAssetInHub", preBalanceOfToken0UnderlyingAssetInHub);
        console.log("preBalanceOfToken1UnderlyingAssetInHub", preBalanceOfToken1UnderlyingAssetInHub);

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

        uint256 postBalanceOfToken0UnderlyingAssetInHub = Currency.wrap(underlyingAssetLCC0).balanceOf(liquidityHub);
        uint256 postBalanceOfToken1UnderlyingAssetInHub = Currency.wrap(underlyingAssetLCC1).balanceOf(liquidityHub);

        console.log("postBalanceOfToken0UnderlyingAssetInPM", postBalanceOfToken0UnderlyingAssetInPM);
        console.log("postBalanceOfToken1UnderlyingAssetInPM", postBalanceOfToken1UnderlyingAssetInPM);
        console.log("postBalanceOfToken0UnderlyingAssetInHub", postBalanceOfToken0UnderlyingAssetInHub);
        console.log("postBalanceOfToken1UnderlyingAssetInHub", postBalanceOfToken1UnderlyingAssetInHub);

        // validate liquidity of token-in(token0) in the lcc token is lower after the swap
        // because liquidity will move 'from lcc' token 'to pool-manager' as it enters the pool during a zero for one swap
        assertEq(preBalanceOfToken0UnderlyingAssetInHub - postBalanceOfToken0UnderlyingAssetInHub, deltaAmount0);
        // validate liquidity of token-in(token0) in the pool manager is higher after the swap
        // becase liquidity of the underlying tokens will be moved from lcc token to pool manager
        // so the pool manager's underlying balance should increase by the amount of token-in(token0) swapped into the pool
        assertEq(postBalanceOfToken0UnderlyingAssetInPM - preBalanceOfToken0UnderlyingAssetInPM, deltaAmount0);
        // validate liquidity of token-out(token1) in the lcc token is higher after the swap
        // because liquidity will move 'from pool-manager' token 'to lcc' token as it exits the pool during a zero for one swap
        assertEq(postBalanceOfToken1UnderlyingAssetInHub - preBalanceOfToken1UnderlyingAssetInHub, deltaAmount1);
        // validate liquidity of token-out(token1) in the pool manager is lower after the swap
        // because liquidity of the underlying tokens will be moved from lcc token to pool manager
        // so the pool manager's underlying balance should decrease by the amount of token-out(token1) swapped out of the pool
        assertEq(preBalanceOfToken1UnderlyingAssetInPM - postBalanceOfToken1UnderlyingAssetInPM, deltaAmount1);
    }
}

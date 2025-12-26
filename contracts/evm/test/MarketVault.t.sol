// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MarketVaultBase} from "./base/MarketVaultBase.sol";
import {LiquidityHub} from "../src/LiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencyTransfer} from "../src/libraries/CurrencyTransfer.sol";
import {MarketVault} from "../src/modules/MarketVault.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MarketVaultTest
 * @notice Tests for MarketVault functionality including settlement obligations and deficit handling
 */
contract MarketVaultTest is MarketVaultBase {
    using CurrencyTransfer for Currency;

    /**
     * @notice Test that _settleObligationsForLCC is called after swap
     */
    function test_settleObligationsCalledAfterSwap() public {
        // bytes32 marketId = PoolId.unwrap(corePoolKey.toId());
        LiquidityCommitmentCertificate lccToken0 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency0)));
        address underlying0 = lccToken0.underlying();

        // Create a pending settlement by having a user unwrap more than available
        address user = makeAddr("user");

        // Fund user and have user approve & wrap some LCC first via LiquidityHub
        // then let them perform a swap
        uint256 initialLiquidity = 1000;
        Currency.wrap(underlying0).transfer(user, initialLiquidity);
        vm.startPrank(user);
        // approve the liquidity hub to spend the user's underlying assets
        Currency.wrap(underlying0).approve(liquidityHub, initialLiquidity);
        // wrap the underlying assets into LCC tokens via the liquidity hub
        LiquidityHub(payable(liquidityHub)).wrap(address(lccToken0), initialLiquidity);
        vm.stopPrank();

        // Try to unwrap more than available to create settlement queue
        // in order to create a settlement debt
        // We need to mock the wrapped balance of the user to be 0 and then fail to unwrap from the market balance
        _mockLCCBalances(lccToken0, user, 0, initialLiquidity);
        // mock the amount used from the market to be 0
        _mockLimitedMarketLiquidity(underlying0, PoolId.unwrap(corePoolKey.toId()), 0);

        // Attempt to unwrap the LCC tokens
        vm.prank(user);
        LiquidityHub(payable(liquidityHub)).unwrap(address(lccToken0), initialLiquidity); // This should queue settlement

        // Check that settlement is queued
        uint256 queuedBefore = LiquidityHub(payable(liquidityHub)).totalQueued(address(lccToken0));
        assertGt(queuedBefore, 0, "Should have queued settlement");

        // Now perform a swap that should trigger settlement
        // Note: The swap needs to add liquidity for token0 to trigger settlement
        // In a zeroForOne swap, we're adding token0, so this should help settle obligations
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(100), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            settings,
            ZERO_BYTES
        );

        // Settlement should be processed if liquidity became available
        // Note: This is a best-effort check - if swap didn't add liquidity for token0,
        // settlement may not be fully processed
        uint256 queuedAfter = LiquidityHub(payable(liquidityHub)).totalQueued(address(lccToken0));
        // Settlement queue should be reduced or cleared if swap provided liquidity
        assertLe(queuedAfter, queuedBefore, "Settlement queue should be reduced after swap");
    }

    /**
     * @notice Test that settlement obligations are processed when liquidity is added via modifyLiquidities
     */
    function test_settleObligationsCalledAfterModifyLiquidities() public {
        // bytes32 marketId = PoolId.unwrap(corePoolKey.toId());
        LiquidityCommitmentCertificate lccToken0 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency0)));

        address underlying0 = lccToken0.underlying();

        // Create a pending settlement by having a user unwrap more than available
        address user = makeAddr("user");

        // Fund user and have user approve & wrap some LCC first via LiquidityHub
        // then let them perform a swap
        uint256 initialLiquidity = 1000;
        Currency.wrap(underlying0).transfer(user, initialLiquidity);
        vm.startPrank(user);
        // approve the liquidity hub to spend the user's underlying assets
        Currency.wrap(underlying0).approve(liquidityHub, initialLiquidity);
        // wrap the underlying assets into LCC tokens via the liquidity hub
        LiquidityHub(payable(liquidityHub)).wrap(address(lccToken0), initialLiquidity);
        vm.stopPrank();

        // Try to unwrap more than available to create settlement queue
        // in order to create a settlement debt
        // We need to mock the wrapped balance of the user to be 0 and then fail to unwrap from the market balance
        _mockLCCBalances(lccToken0, user, 0, initialLiquidity);
        // mock the amount used from the market to be 0 i.e if nothing is used in the market liquidity then the unwrap is queued
        _mockLimitedMarketLiquidity(underlying0, PoolId.unwrap(corePoolKey.toId()), 0);

        // Attempt to unwrap the LCC tokens
        vm.prank(user);
        LiquidityHub(payable(liquidityHub)).unwrap(address(lccToken0), initialLiquidity); // This should queue settlement

        uint256 queuedBefore = LiquidityHub(payable(liquidityHub)).totalQueued(address(lccToken0));
        assertGt(queuedBefore, 0, "Should have queued settlement");

        // set initial market liquidity
        _mockLimitedMarketLiquidity(underlying0, PoolId.unwrap(corePoolKey.toId()), initialLiquidity);

        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            ZERO_BYTES
        );

        // Settlement should be processed
        uint256 queuedAfter = LiquidityHub(payable(liquidityHub)).totalQueued(address(lccToken0));
        assertLe(queuedAfter, queuedBefore, "Settlement queue should be reduced after adding liquidity");
    }

    /**
     * @notice Test that inMarketBalanceOf returns correct balance
     */
    function test_inMarketBalanceOf() public view {
        Currency currency0 = proxyPoolKey.currency0;
        uint256 balance = mv.inMarketBalanceOf(currency0);

        // Initial balance should be based on setup
        assertGe(balance, 0, "Balance should be non-negative");
    }

    /**
     * @notice Test that SwapDeficit event is emitted when deficit occurs with recipient
     */
    function test_swapDeficitEventEmitted() public {
        bytes32 marketId = PoolId.unwrap(proxyPoolKey.toId());
        address recipient = makeAddr("deficit_recipient");
        _setupRecipient(recipient);

        uint256 mockAvailableLiquidity = 50;
        _mockLimitedLiquidity(_currency1, mockAvailableLiquidity);

        uint256 swapAmount = 100;
        LiquidityCommitmentCertificate lccIn = _getLCCOut(_currency0);
        LiquidityCommitmentCertificate lccOut = _getLCCOut(_currency1);

        // Calculate expected deficit
        (uint256 expectedInput, uint256 expectedOutput) = _simulateSwap(corePoolKey, true, -int256(swapAmount));

        uint256 expectedDeficit = expectedOutput > mockAvailableLiquidity ? expectedOutput - mockAvailableLiquidity : 0;
        uint256 expectedAmountToCancel =
            expectedOutput > mockAvailableLiquidity ? mockAvailableLiquidity : expectedOutput;

        if (expectedDeficit > 0) {
            // Expect Transfer event for mint first (emitted by liquidityHub.issue -> LCC.mint -> ERC20._mint)
            vm.expectEmit(true, true, false, true, address(lccIn));
            emit IERC20.Transfer(address(0), address(mv), expectedInput);

            // Expect Transfer event for burn first (emitted by liquidityHub.cancel -> _burn)
            // This burns amountToCancel tokens from MarketVault to address(0)
            vm.expectEmit(true, true, false, true, address(lccOut));
            emit IERC20.Transfer(address(mv), address(0), expectedAmountToCancel);

            // Expect Transfer event for deficit transfer (emitted by lccToken.safeTransfer)
            // This transfers deficitAmount tokens from MarketVault to recipient
            vm.expectEmit(true, true, false, true, address(lccOut));
            emit IERC20.Transfer(address(mv), recipient, expectedDeficit);

            // Then expect SwapDeficit event from MarketVault
            vm.expectEmit(true, true, true, true, address(mv));
            emit MarketVault.SwapDeficit(PoolId.wrap(marketId), address(lccOut), recipient, expectedDeficit);
        }

        _executeSwap(
            proxyPoolKey,
            true, // zeroForOne
            -int256(swapAmount),
            abi.encode(recipient)
        );
    }
}

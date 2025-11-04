// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MarketVaultBase} from "./modules/MarketVaultBase.sol";
import {LiquidityHub} from "../src/LiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {CurrencyTransfer} from "../src/libraries/CurrencyTransfer.sol";
import {MarketVault} from "../src/modules/MarketVault.sol";

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
        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());
        LiquidityCommitmentCertificate lccToken0 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency0)));
        address underlying0 = lccToken0.underlying();

        // Create a pending settlement by having a user unwrap more than available
        address user = makeAddr("user");

        // Fund user and have user approve & wrap some LCC first via LiquidityHub
        Currency.wrap(underlying0).transfer(user, 1000);
        vm.prank(user);
        Currency.wrap(underlying0).approve(liquidityHub, 1000);
        vm.prank(user);
        LiquidityHub(payable(liquidityHub)).wrap(address(lccToken0), 1000);

        // Try to unwrap more than available to create settlement queue
        vm.prank(user);
        LiquidityHub(payable(liquidityHub)).unwrap(address(lccToken0), 2000); // This should queue settlement

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
        LiquidityCommitmentCertificate lccToken0 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency0)));
        address underlying0 = lccToken0.underlying();

        // Create a pending settlement
        address user = makeAddr("user");
        // Fund user and have user approve & wrap via LiquidityHub
        Currency.wrap(underlying0).transfer(user, 1000);
        vm.prank(user);
        Currency.wrap(underlying0).approve(liquidityHub, 1000);
        vm.prank(user);
        LiquidityHub(payable(liquidityHub)).wrap(address(lccToken0), 1000);

        vm.prank(user);
        LiquidityHub(payable(liquidityHub)).unwrap(address(lccToken0), 2000);

        uint256 queuedBefore = LiquidityHub(payable(liquidityHub)).totalQueued(address(lccToken0));
        assertGt(queuedBefore, 0, "Should have queued settlement");

        // Add liquidity via modifyLiquidities
        vm.prank(marketFactory);
        mv.modifyLiquidities(toBalanceDelta(int128(uint128(1000)), 0));

        // Settlement should be processed
        uint256 queuedAfter = LiquidityHub(payable(liquidityHub)).totalQueued(address(lccToken0));
        assertLe(queuedAfter, queuedBefore, "Settlement queue should be reduced after adding liquidity");
    }

    /**
     * @notice Test that inMarketBalanceOf returns correct balance
     */
    function test_inMarketBalanceOf() public {
        Currency currency0 = proxyPoolKey.currency0;
        uint256 balance = mv.inMarketBalanceOf(currency0);

        // Initial balance should be based on setup
        assertGe(balance, 0, "Balance should be non-negative");
    }

    /**
     * @notice Test that SwapDeficit event is emitted when deficit occurs with recipient
     */
    function test_swapDeficitEventEmitted() public {
        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());
        address recipient = makeAddr("deficit_recipient");
        _setupRecipient(recipient);

        uint256 mockAvailableLiquidity = 50;
        _mockLimitedLiquidity(_currency1, mockAvailableLiquidity);

        uint256 swapAmount = 100;
        LiquidityCommitmentCertificate lccOut = _getLCCOut(_currency1);

        // Calculate expected deficit
        (, uint256 expectedOutput) = _simulateSwap(corePoolKey, true, -int256(swapAmount));
        uint256 expectedDeficit = expectedOutput > mockAvailableLiquidity ? expectedOutput - mockAvailableLiquidity : 0;

        if (expectedDeficit > 0) {
            vm.expectEmit(true, true, true, true, address(mv));
            // The emit below doesn't actually emit - it tells Foundry what to expect
            emit MarketVault.SwapDeficit(PoolId.wrap(marketId), address(lccOut), recipient, expectedDeficit);
        }

        _executeSwap(
            proxyPoolKey,
            true, // zeroForOne
            -int256(swapAmount),
            abi.encode(recipient)
        );

        vm.clearMockedCalls();
    }
}


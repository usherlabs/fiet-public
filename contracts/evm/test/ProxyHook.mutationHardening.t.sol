// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {MarketVaultBase} from "./base/MarketVaultBase.sol";

import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {ProxyHook} from "../src/ProxyHook.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {SwapSimulator} from "../src/libraries/SwapSimulator.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

/**
 * @notice Mutation hardening tests for ProxyHook.
 * @dev Focused assertions to kill known survivors in `src/ProxyHook.sol` without running the full ProxyHook suite.
 */
contract ProxyHookMutationHardeningTest is MarketVaultBase {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    function test_proxySwap_capsUsingOutputCurrencyLiquidity_zeroForOne() public {
        // Survivor targets:
        // - inMarketBalanceOf(params.zeroForOne ? key.currency1 : key.currency0) currency selection
        // - outUpper <= maxOutputAvailable guard (missing cap if inverted)
        uint256 swapAmount = 250e18;
        (, uint256 expectedOutput) = _simulateSwap(corePoolKey, true, -int256(swapAmount));
        uint256 smallAvailable = expectedOutput / 4;
        assertGt(expectedOutput, smallAvailable, "precondition: expected output must exceed available");

        // For zeroForOne swaps, output currency is token1 (key.currency1).
        _mockLimitedLiquidity(proxyPoolKey.currency1, smallAvailable);
        // Set other currency high to catch incorrect selection.
        _mockLimitedLiquidity(proxyPoolKey.currency0, type(uint256).max);

        BalanceDelta swapDelta = _executeSwap(proxyPoolKey, true, -int256(swapAmount), bytes(""));
        (, uint256 actualOutput) = _getSwapDeltas(swapDelta, true);

        assertLe(actualOutput, smallAvailable, "output should be capped using currency1 liquidity");

        vm.clearMockedCalls();
    }

    function test_proxySwap_capsUsingOutputCurrencyLiquidity_oneForZero() public {
        uint256 swapAmount = 250e18;
        (, uint256 expectedOutput) = _simulateSwap(corePoolKey, false, -int256(swapAmount));
        uint256 smallAvailable = expectedOutput / 4;
        assertGt(expectedOutput, smallAvailable, "precondition: expected output must exceed available");

        // For oneForZero swaps, output currency is token0 (key.currency0).
        _mockLimitedLiquidity(proxyPoolKey.currency0, smallAvailable);
        _mockLimitedLiquidity(proxyPoolKey.currency1, type(uint256).max);

        BalanceDelta swapDelta = _executeSwap(proxyPoolKey, false, -int256(swapAmount), bytes(""));
        (, uint256 actualOutput) = _getSwapDeltas(swapDelta, false);

        assertLe(actualOutput, smallAvailable, "output should be capped using currency0 liquidity");

        vm.clearMockedCalls();
    }

    function test_harness_upperBoundOutAtCurrentPrice_respectsDirectionalProtocolFee_andBranching() public {
        // Survivor target:
        // - `if (zeroForOne)` direction flip in `_upperBoundOutAtCurrentPrice`
        ProxyHookHarness harness = new ProxyHookHarness(address(manager), address(marketFactory));

        // Make protocol fee asymmetric so direction matters: zf1=500, ofz=0.
        uint24 zf1 = 500;
        uint24 ofz = 0;
        uint24 packed = uint24(zf1 | (ofz << 12));

        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(corePoolKey, packed);

        int256 amountSpecified = -int256(1e18);
        (uint160 sqrtP,, uint24 protocolFee, uint24 lpFee) = StateLibrary.getSlot0(manager, corePoolKey.toId());

        // --- zeroForOne expected ---
        {
            uint16 protocolFeeDir = uint16(protocolFee & 0xfff);
            uint24 swapFee = protocolFeeDir == 0 ? lpFee : ProtocolFeeLibrary.calculateSwapFee(protocolFeeDir, lpFee);
            uint256 oneMinusFee = ProtocolFeeLibrary.PIPS_DENOMINATOR - swapFee;
            uint256 absIn = uint256(-amountSpecified);
            uint256 adjIn = Math.mulDiv(absIn, oneMinusFee, ProtocolFeeLibrary.PIPS_DENOMINATOR);
            uint256 Q96 = uint256(1) << 96;
            uint256 expected = Math.mulDiv(Math.mulDiv(adjIn, uint256(sqrtP), Q96), uint256(sqrtP), Q96);

            uint256 got = harness.exposed_upperBoundOutAtCurrentPrice(corePoolKey, amountSpecified, true);
            assertEq(got, expected, "zeroForOne upper bound mismatch");
        }

        // --- oneForZero expected ---
        {
            uint16 protocolFeeDir = uint16(protocolFee >> 12);
            uint24 swapFee = protocolFeeDir == 0 ? lpFee : ProtocolFeeLibrary.calculateSwapFee(protocolFeeDir, lpFee);
            uint256 oneMinusFee = ProtocolFeeLibrary.PIPS_DENOMINATOR - swapFee;
            uint256 absIn = uint256(-amountSpecified);
            uint256 adjIn = Math.mulDiv(absIn, oneMinusFee, ProtocolFeeLibrary.PIPS_DENOMINATOR);
            uint256 Q96 = uint256(1) << 96;
            uint256 expected = Math.mulDiv(Math.mulDiv(adjIn, Q96, uint256(sqrtP)), Q96, uint256(sqrtP));

            uint256 got = harness.exposed_upperBoundOutAtCurrentPrice(corePoolKey, amountSpecified, false);
            assertEq(got, expected, "oneForZero upper bound mismatch");
        }
    }
}

contract ProxyHookHarness is ProxyHook {
    constructor(address _poolManager, address _marketFactory) ProxyHook(_poolManager, _marketFactory) {}

    /// @dev Disable hook-address flag validation for harness deployments in unit tests.
    function validateHookAddress(BaseHook) internal pure override {}

    function exposed_upperBoundOutAtCurrentPrice(PoolKey memory coreKey, int256 amountSpecified, bool zeroForOne)
        external
        view
        returns (uint256 outUpper)
    {
        outUpper = _upperBoundOutAtCurrentPrice(coreKey, amountSpecified, zeroForOne);
    }
}


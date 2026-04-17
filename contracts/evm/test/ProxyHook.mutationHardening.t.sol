// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {MarketVaultBase} from "./base/MarketVaultBase.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {IMsgSender} from "v4-periphery/src/interfaces/IMsgSender.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LiquidityHub} from "../src/LiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";

/// @dev Unwrap must run under `PoolManager.unlock` when the manager is already locked.
contract UnwrapInUnlockRunnerMutation {
    IPoolManager internal immutable pm;
    address internal immutable hub;

    constructor(IPoolManager pm_, address hub_) {
        pm = pm_;
        hub = hub_;
    }

    function run(address lcc, uint256 amt) external {
        pm.unlock(abi.encode(lcc, amt));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address lcc, uint256 amt) = abi.decode(data, (address, uint256));
        LiquidityHub(payable(hub)).unwrap(lcc, amt);
        return bytes("");
    }
}

/**
 * @notice Mutation hardening tests for ProxyHook under Option A + MKT-05 semantics.
 * @dev Focused checks that guard against regressions in strict revert policy and proxy no-op behaviour.
 */
contract ProxyHookMutationHardeningTest is MarketVaultBase {
    function _fundRunnerWithMarketDerivedLCC(
        UnwrapInUnlockRunnerMutation runner,
        LiquidityCommitmentCertificate lcc,
        uint256 amount
    ) internal {
        address ua = lcc.underlying();
        require(ua != address(0), "mutation liveness tests require ERC20 underlyings");
        vm.prank(address(proxyHook));
        LiquidityHub(payable(liquidityHub)).issue(address(lcc), address(runner), amount);
    }

    function _unwrapMarketDerivedFromVault(LiquidityCommitmentCertificate lcc, uint256 amount) internal {
        UnwrapInUnlockRunnerMutation runner =
            new UnwrapInUnlockRunnerMutation(IPoolManager(address(manager)), liquidityHub);
        _fundRunnerWithMarketDerivedLCC(runner, lcc, amount);
        runner.run(address(lcc), amount);
    }

    function _stripSelector(bytes memory revertData) internal pure returns (bytes memory tail) {
        require(revertData.length >= 4, "missing revert selector");
        tail = new bytes(revertData.length - 4);
        for (uint256 i = 0; i < tail.length; i++) {
            tail[i] = revertData[i + 4];
        }
    }

    function _assertWrappedReason(bytes memory revertData, bytes memory expectedReason) internal pure {
        bytes4 sel;
        assembly ("memory-safe") {
            sel := mload(add(revertData, 0x20))
        }
        assertEq(sel, CustomRevert.WrappedError.selector, "expected WrappedError selector");

        (,, bytes memory reason,) = abi.decode(_stripSelector(revertData), (address, bytes4, bytes, bytes));
        assertEq(keccak256(reason), keccak256(expectedReason), "unexpected wrapped revert reason");
    }

    /// @dev Real prior unwrap depletion; assert precise WrappedError payload for exact-input unresolved recipient.
    function test_proxyLiveness_priorUnwrap_exactInputUnresolved_wrappedInsufficientLiquidityReason() public {
        Currency currencyOut = proxyPoolKey.currency1;
        LiquidityCommitmentCertificate lccOut = _getLCCOut(currencyOut);

        uint256 beforeVault = mv.inMarketBalanceOf(currencyOut);
        assertGt(beforeVault, 10_000, "pre: need vault liquidity");

        uint256 leaveInVault = 1000;
        uint256 drain = beforeVault > leaveInVault ? beforeVault - leaveInVault : 0;
        assertGt(drain, 0, "pre: need drainable vault balance");
        _unwrapMarketDerivedFromVault(lccOut, drain);

        uint256 afterVault = mv.inMarketBalanceOf(currencyOut);
        assertLe(afterVault, leaveInVault, "post: output lane should be nearly depleted");

        uint256 swapAmount = 1e18;
        (, uint256 expectedOutput) = _simulateCoreSwapAsProxy(proxyPoolKey, true, -int256(swapAmount));
        assertGt(expectedOutput, afterVault, "simulated core output should exceed remaining vault");

        bytes memory expectedReason =
            abi.encodeWithSelector(Errors.InsufficientLiquidity.selector, expectedOutput, afterVault);

        try swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            _getSwapSettings(),
            bytes("")
        ) {
            fail();
        } catch (bytes memory data) {
            _assertWrappedReason(data, expectedReason);
        }
    }

    function test_proxySwap_exactOutput_revertsWhenInsufficientLiquidity_zeroForOne() public {
        _mockLimitedLiquidity(proxyPoolKey.currency1, 50);
        bytes memory expectedReason =
            abi.encodeWithSelector(Errors.InsufficientLiquidity.selector, uint256(100), uint256(50));

        try swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(100), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            _getSwapSettings(),
            bytes("")
        ) {
            fail();
        } catch (bytes memory data) {
            _assertWrappedReason(data, expectedReason);
        }
    }

    function test_proxySwap_exactOutput_revertsWhenInsufficientLiquidity_oneForZero() public {
        _mockLimitedLiquidity(proxyPoolKey.currency0, 50);
        bytes memory expectedReason =
            abi.encodeWithSelector(Errors.InsufficientLiquidity.selector, uint256(100), uint256(50));

        try swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(100), sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT}),
            _getSwapSettings(),
            bytes("")
        ) {
            fail();
        } catch (bytes memory data) {
            _assertWrappedReason(data, expectedReason);
        }
    }

    /// @notice Strict exact-output even when hookData resolves a deficit recipient (regression: MKT-05).
    function test_proxySwap_exactOutput_revertsWhenInsufficientLiquidity_zeroForOne_withResolvedRecipient() public {
        address recipient = makeAddr("mkt05_exact_out_recipient");
        _mockLimitedLiquidity(proxyPoolKey.currency1, 50);
        bytes memory expectedReason =
            abi.encodeWithSelector(Errors.InsufficientLiquidity.selector, uint256(100), uint256(50));

        try swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(100), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            _getSwapSettings(),
            abi.encode(recipient)
        ) {
            fail();
        } catch (bytes memory data) {
            _assertWrappedReason(data, expectedReason);
        }
    }

    function test_proxySwap_exactOutput_revertsWhenInsufficientLiquidity_oneForZero_withResolvedRecipient() public {
        address recipient = makeAddr("mkt05_exact_out_recipient_ofz");
        _mockLimitedLiquidity(proxyPoolKey.currency0, 50);
        bytes memory expectedReason =
            abi.encodeWithSelector(Errors.InsufficientLiquidity.selector, uint256(100), uint256(50));

        try swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(100), sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT}),
            _getSwapSettings(),
            abi.encode(recipient)
        ) {
            fail();
        } catch (bytes memory data) {
            _assertWrappedReason(data, expectedReason);
        }
    }

    function test_proxySwap_exactInput_revertsOnCoreFillMismatch_withTightPriceLimit() public {
        // Avoid insufficiency-related reverts and isolate the exact-input fill-mismatch guard.
        _mockLimitedLiquidity(proxyPoolKey.currency0, type(uint256).max);
        _mockLimitedLiquidity(proxyPoolKey.currency1, type(uint256).max);

        (uint160 sqrtP,,,) = StateLibrary.getSlot0(manager, proxyPoolKey.toId());
        uint160 limit = sqrtP - 1;
        if (limit <= TickMath.MIN_SQRT_PRICE + 1) {
            limit = TickMath.MIN_SQRT_PRICE + 1;
        }

        bytes memory expectedReason =
            abi.encodeWithSelector(Errors.InvariantViolated.selector, "ProxyHook: exact-input core fill mismatch");

        try swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1e18), sqrtPriceLimitX96: limit}),
            _getSwapSettings(),
            bytes("")
        ) {
            fail();
        } catch (bytes memory data) {
            _assertWrappedReason(data, expectedReason);
        }
    }

    function test_proxySwap_exactInput_revertsWhenAmountSpecifiedIsInt256Min() public {
        int256 minSupported = -int256(type(int128).max);
        bytes memory expectedReason =
            abi.encodeWithSelector(Errors.UnsupportedExactInputAmount.selector, type(int256).min, minSupported, -1);

        try swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: type(int256).min, sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            _getSwapSettings(),
            bytes("")
        ) {
            fail();
        } catch (bytes memory data) {
            _assertWrappedReason(data, expectedReason);
        }
    }

    function test_proxySwap_exactInput_revertsWhenAmountSpecifiedBelowSupportedRange() public {
        int256 minSupported = -int256(type(int128).max);
        int256 unsupported = minSupported - 1;
        bytes memory expectedReason =
            abi.encodeWithSelector(Errors.UnsupportedExactInputAmount.selector, unsupported, minSupported, -1);

        try swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: unsupported, sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            _getSwapSettings(),
            bytes("")
        ) {
            fail();
        } catch (bytes memory data) {
            _assertWrappedReason(data, expectedReason);
        }
    }

    function test_proxySwap_keepsProxySlot0Unchanged() public {
        (uint160 sqrtBefore, int24 tickBefore,,) = StateLibrary.getSlot0(manager, proxyPoolKey.toId());

        _executeSwap(proxyPoolKey, true, -int256(1e18), bytes(""));
        _executeSwap(proxyPoolKey, false, int256(100), bytes(""));

        (uint160 sqrtAfter, int24 tickAfter,,) = StateLibrary.getSlot0(manager, proxyPoolKey.toId());
        assertEq(sqrtAfter, sqrtBefore, "proxy sqrtPrice should remain unchanged");
        assertEq(tickAfter, tickBefore, "proxy tick should remain unchanged");
    }

    function test_recipientRouting_routerAndLockerSentinels() public {
        ProxyHookHarness harness = new ProxyHookHarness(address(manager), address(marketFactory));

        address sender = makeAddr("router_sender");
        (address gotRouter, bool routerResolved) =
            harness.exposed_determineExcessRecipient(sender, abi.encode(address(2)));
        assertTrue(routerResolved, "router sentinel should resolve");
        assertEq(gotRouter, sender, "router sentinel should map to sender");

        MockMsgSender lockerSender = new MockMsgSender(makeAddr("locker"));
        (address gotLocker, bool lockerResolved) =
            harness.exposed_determineExcessRecipient(address(lockerSender), abi.encode(address(1)));
        assertTrue(lockerResolved, "locker sentinel should resolve");
        assertEq(gotLocker, lockerSender.msgSender(), "locker sentinel should map via IMsgSender(sender).msgSender()");
    }

    /// @dev Non-sentinel hookData recipient uses explicit address with `resolved == true` (`ProxyHook` branch).
    function test_determineExcessRecipient_explicitRecipient_resolves() public {
        ProxyHookHarness harness = new ProxyHookHarness(address(manager), address(marketFactory));
        address custom = makeAddr("explicit_deficit_recipient");
        (address got, bool resolved) =
            harness.exposed_determineExcessRecipient(makeAddr("swap_sender"), abi.encode(custom));
        assertTrue(resolved, "explicit recipient should be resolved");
        assertEq(got, custom, "should return decoded recipient");
    }

    /// @dev Mutation-suite mirror of `ProxyHook.t.sol::test_harness_calcCoreSqrtPriceLimit_branches` (price-limit inversion).
    function test_mutationHarness_calcCoreSqrtPriceLimit_reciprocalAndDefaults() public {
        ProxyHookHarness harness = new ProxyHookHarness(address(manager), address(marketFactory));

        assertEq(harness.exposed_calcCoreSqrtPriceLimit(uint160(42), false, false), uint160(42));

        uint160 minB = TickMath.MIN_SQRT_PRICE + 1;
        uint160 maxB = TickMath.MAX_SQRT_PRICE - 1;
        assertEq(harness.exposed_calcCoreSqrtPriceLimit(minB, true, false), maxB);
        assertEq(harness.exposed_calcCoreSqrtPriceLimit(maxB, true, true), minB);

        uint256 q192 = uint256(1) << 192;
        uint160 mid = 79228162514264337593543950337;
        uint160 ceilP = uint160((q192 + uint256(mid) - 1) / uint256(mid));
        uint160 floorP = uint160(q192 / uint256(mid));
        assertEq(harness.exposed_calcCoreSqrtPriceLimit(mid, true, true), ceilP);
        assertEq(harness.exposed_calcCoreSqrtPriceLimit(mid, true, false), floorP);

        assertEq(harness.exposed_calcCoreSqrtPriceLimit(0, true, false), maxB);
        assertEq(harness.exposed_calcCoreSqrtPriceLimit(0, true, true), minB);
    }
}

contract ProxyHookHarness is ProxyHook {
    constructor(address _poolManager, address _marketFactory) ProxyHook(_poolManager, _marketFactory) {}

    /// @dev Disable hook-address flag validation for harness deployments in unit tests.
    function validateHookAddress(BaseHook) internal pure override {}

    function exposed_calcCoreSqrtPriceLimit(uint160 sqrtPriceLimitX96, bool flipped, bool coreZeroForOne)
        external
        pure
        returns (uint160)
    {
        return _calcCoreSqrtPriceLimit(sqrtPriceLimitX96, flipped, coreZeroForOne);
    }

    function exposed_determineExcessRecipient(address sender, bytes calldata hookData)
        external
        view
        returns (address recipient, bool resolved)
    {
        return _determineExcessRecipient(sender, hookData);
    }
}

contract MockMsgSender is IMsgSender {
    address internal immutable _ms;

    constructor(address ms) {
        _ms = ms;
    }

    function msgSender() external view returns (address) {
        return _ms;
    }
}


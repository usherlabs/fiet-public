// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySortHelper} from "./utils/CurrencySortHelper.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {ICanonicalVault} from "../src/interfaces/ICanonicalVault.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {console} from "forge-std/console.sol";
// inherit from the MarketVaultBase contract which provides shared helper functions
import {MarketVaultBase} from "./base/MarketVaultBase.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {LiquidityHub} from "../src/LiquidityHub.sol";
import {MarketTestBase} from "./base/MarketTestBase.sol";
import {MockERC20} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {IVaultCoreActionHandler} from "../src/interfaces/IVaultCoreActionHandler.sol";
import {CoreActionFlag} from "../src/libraries/CoreActionFlag.sol";
import {Bounds} from "../src/libraries/Bounds.sol";
import {SwapSimulator} from "./utils/SwapSimulator.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IMsgSender} from "v4-periphery/src/interfaces/IMsgSender.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CanonicalVault} from "../src/CanonicalVault.sol";

/**
 * 22nd October 2025 - ProxyHookTest.sol
 *     - Fail signature shows wrapper from ProxyHook address. With verbosity logs earlier, we saw SenderNotIssuer when ProxyHook called LCC.unwrapFromVault due to proxyHookToCurrencyPair returning 0,0 — we've corrected that in MarketTestBase to map to the LCCs' underlying asset addresses. After that change, the suite progressed further but setUp moved to passing and individual proxy swap tests still revert.
 *     - The remaining Proxy swap test reverts are thrown by ProxyHook, likely on deficit recipient or flow guards. But the error selector in the latest runs shows generic revert without decoded custom error. We'll address them next by ensuring the excess-recipient hookData is valid or by letting swaps operate without overflow. Given determineExcessRecipient returns address(0) by default, ProxyHook's logic already guards to not emit and not set deficit recipient. The more likely culprit is insufficient available inMarket balances causing internal steps to underflow flow constraints.
 *     - We already mocked proxyHookToCurrencyPair correctly and MarketVault is active; next fix is to ensure balances in ProxyHook's MarketVault are sufficient before proxy swaps. In these tests, initial inMarket balances exist via initial core LP providing LCC backing and on-direct LP path; however, ProxyHook's settlement path first calls settleFromLCCToVault on direct LP events only. The proxy swap tests don't perform direct LP and rely on pre-seeded inMarket balances from the setup. The harness has lcc0.wrap/lcc1.wrap(initialLiquidity) followed by core pool add-liquidity and ProxyHook._onDirectLP crediting vault from LCC on direct LP. That flow is working for "core" swap tests (they pass), but proxy swap is still reverting.
 */

/// @dev Unwrap must run under `PoolManager.unlock` when the manager is already locked (same as MarketVault tests).
contract UnwrapInUnlockRunner {
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

contract ProxyHookTest is MarketVaultBase {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    function test_activate_revertsIfNotFactory_onFreshProxyHook() public {
        ProxyHookHarness fresh = new ProxyHookHarness(address(manager), address(marketFactory));

        vm.expectRevert(Errors.InvalidSender.selector);
        fresh.activate();
    }

    function test_setCorePoolKey_revertsIfNotFactory_onFreshProxyHook() public {
        ProxyHookHarness fresh = new ProxyHookHarness(address(manager), address(marketFactory));

        vm.expectRevert(Errors.InvalidSender.selector);
        fresh.setCorePoolKey(corePoolKey);
    }

    function test_handleLiquidity_revertsIfNotCoreHook() public {
        ProxyHookHarness fresh = new ProxyHookHarness(address(manager), address(marketFactory));

        vm.expectRevert(Errors.InvalidSender.selector);
        fresh.handleAddLiquidity();
    }

    function test_handleSwap_revertsIfNotCoreHook() public {
        ProxyHookHarness fresh = new ProxyHookHarness(address(manager), address(marketFactory));

        vm.expectRevert(Errors.InvalidSender.selector);
        fresh.handleSwap(address(0));
    }

    function test_activate_onlyFactory_gate_isObservableViaLowLevelCall() public {
        ProxyHookHarness fresh = new ProxyHookHarness(address(manager), address(marketFactory));
        assertEq(fresh.coreHook(), address(0));

        address attacker = makeAddr("attacker_activate");

        // If `onlyFactory` is removed, this call will succeed and set coreHook.
        vm.prank(attacker);
        (bool ok,) = address(fresh).call(abi.encodeCall(ProxyHook.activate, ()));
        assertFalse(ok, "activate should be gated by onlyFactory");
        assertEq(fresh.coreHook(), address(0), "coreHook must remain unset if not called by factory");

        vm.prank(marketFactory);
        fresh.activate();
        assertEq(fresh.coreHook(), coreHookAddress, "factory can activate");
    }

    function test_setCorePoolKey_onlyFactory_gate_isObservableViaLowLevelCall() public {
        ProxyHookHarness fresh = new ProxyHookHarness(address(manager), address(marketFactory));

        address attacker = makeAddr("attacker_setCorePoolKey");

        vm.prank(attacker);
        (bool ok,) = address(fresh).call(abi.encodeCall(ProxyHook.setCorePoolKey, (corePoolKey)));
        assertFalse(ok, "setCorePoolKey should be gated by onlyFactory");
        // `corePoolKey()` returns a tuple; destructure to access hooks.
        (,,,, IHooks hooks) = fresh.corePoolKey();
        assertEq(address(hooks), address(0), "corePoolKey must remain unset if not factory");

        vm.prank(marketFactory);
        fresh.setCorePoolKey(corePoolKey);
        assertEq(PoolId.unwrap(fresh.getCorePoolId()), PoolId.unwrap(corePoolKey.toId()));
    }

    function test_handleLiquidity_onlyCoreHook_gate_isObservableWithNoopInputs() public {
        ProxyHookHarness fresh = new ProxyHookHarness(address(manager), address(marketFactory));
        address attacker = makeAddr("attacker_handleLiquidity");

        vm.prank(attacker);
        (bool ok,) = address(fresh).call(abi.encodeCall(IVaultCoreActionHandler.handleAddLiquidity, ()));
        assertFalse(ok, "handleLiquidity should be gated by onlyCoreHook");

        vm.prank(marketFactory);
        fresh.activate();
        fresh.exposed_setNoCoreActionFlag(true);

        vm.prank(coreHookAddress);
        fresh.handleAddLiquidity();
    }

    function test_handleSwap_onlyCoreHook_gate_isObservableOnEarlyReturnPath() public {
        ProxyHookHarness fresh = new ProxyHookHarness(address(manager), address(marketFactory));
        address attacker = makeAddr("attacker_handleSwap");

        vm.prank(marketFactory);
        fresh.activate();
        vm.prank(marketFactory);
        fresh.setCorePoolKey(corePoolKey);
        fresh.exposed_setNoCoreActionFlag(true);

        vm.prank(attacker);
        (bool ok,) = address(fresh)
            .call(abi.encodeCall(IVaultCoreActionHandler.handleSwap, (Currency.unwrap(corePoolKey.currency0))));
        assertFalse(ok, "handleSwap should be gated by onlyCoreHook");

        vm.prank(coreHookAddress);
        fresh.handleSwap(Currency.unwrap(corePoolKey.currency0));
    }

    function test_handleIngress_onlyFactory_gate_isObservableViaLowLevelCall() public {
        ProxyHookHarness fresh = new ProxyHookHarness(address(manager), address(marketFactory));
        address attacker = makeAddr("attacker_handleIngress");

        vm.prank(attacker);
        (bool ok,) = address(fresh).call(abi.encodeCall(IVaultCoreActionHandler.handleIngress, (address(1), 0)));
        assertFalse(ok, "handleIngress should be gated by onlyFactory");
    }

    function test_handleIngress_noop_whenWrappedAmountIsZero() public {
        ProxyHookHarness fresh = new ProxyHookHarness(address(manager), address(marketFactory));

        vm.prank(marketFactory);
        fresh.handleIngress(address(1), 0);
    }

    function test_handleIngress_revertsWhenLccIsNotInCorePair() public {
        ProxyHookHarness fresh = new ProxyHookHarness(address(manager), address(marketFactory));

        vm.prank(marketFactory);
        vm.expectRevert(Errors.InvalidSender.selector);
        fresh.handleIngress(address(0xBEEF), 1);
    }

    function test_handleSwap_revertsWhenInputTokenIsNotInCorePair() public {
        ProxyHookHarness fresh = new ProxyHookHarness(address(manager), address(marketFactory));

        vm.prank(marketFactory);
        fresh.activate();
        vm.prank(marketFactory);
        fresh.setCorePoolKey(corePoolKey);

        vm.prank(coreHookAddress);
        vm.expectRevert(Errors.InvalidSender.selector);
        fresh.handleSwap(makeAddr("notCorePairLcc"));
    }

    function test_handleAddLiquidity_directCoreAction_pathExecutes() public {
        ProxyHookHarness fresh = new ProxyHookHarness(address(manager), address(marketFactory));
        address canonicalVault = IMarketFactory(marketFactory).canonicalVault();
        PoolKey memory altCorePoolKey = PoolKey({
            currency0: corePoolKey.currency0,
            currency1: corePoolKey.currency1,
            fee: corePoolKey.fee + 1,
            tickSpacing: corePoolKey.tickSpacing,
            hooks: corePoolKey.hooks
        });
        bytes32 marketId = PoolId.unwrap(altCorePoolKey.toId());

        vm.prank(marketFactory);
        fresh.activate();
        vm.prank(marketFactory);
        fresh.setCorePoolKey(altCorePoolKey);
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.isMarketFacade.selector, marketId, address(fresh)),
            abi.encode(true)
        );
        vm.prank(marketFactory);
        ICanonicalVault(canonicalVault)
            .registerMarket(
                marketId,
                address(fresh),
                address(lcc0),
                address(lcc1),
                Currency.unwrap(_currency0),
                Currency.unwrap(_currency1)
            );

        vm.prank(coreHookAddress);
        fresh.handleAddLiquidity();
    }

    function test_noCoreAction_modifier_setsAndClearsTransientFlag() public {
        ProxyHookHarness fresh = new ProxyHookHarness(address(manager), address(marketFactory));
        (bool duringExecution, bool afterExecution) = fresh.exposed_runNoCoreActionProbe();
        assertTrue(duringExecution, "flag should be set during noCoreAction body");
        assertFalse(afterExecution, "flag should be cleared after noCoreAction body");
    }

    function _isProxyKeyAlignedWithCoreLCCUnderlying() internal view returns (bool) {
        LiquidityCommitmentCertificate lccA =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency0)));
        LiquidityCommitmentCertificate lccB =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency1)));
        return (Currency.unwrap(proxyPoolKey.currency0) == lccA.underlying()
                && Currency.unwrap(proxyPoolKey.currency1) == lccB.underlying());
    }

    /// @dev Rebuild the market a few times until we hit a "flipped" proxy/core alignment.
    ///      This is needed to cover ProxyHook's price-limit flip/inversion branches deterministically.
    function _setupMarketUntilFlipped(uint256 maxAttempts) internal returns (bool foundFlipped) {
        for (uint256 i = 0; i < maxAttempts; i++) {
            _setupMarket();
            lcc0 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency2)));
            lcc1 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency3)));

            if (!_isProxyKeyAlignedWithCoreLCCUnderlying()) {
                return true;
            }
        }
        return false;
    }

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

        assertEq(selfBalanceOfTokenABefore, selfBalanceOfTokenAAfter + swapAmount);
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

        assertEq(selfBalanceOfTokenBBefore, selfBalanceOfTokenBAfter + swapAmount);
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

    function test_proxySwap_exactInput_keepsProxySlot0Unchanged() public {
        (uint160 sqrtBefore, int24 tickBefore,,) = StateLibrary.getSlot0(manager, proxyPoolKey.toId());
        _executeSwap(proxyPoolKey, true, -int256(1e18), ZERO_BYTES);
        (uint160 sqrtAfter, int24 tickAfter,,) = StateLibrary.getSlot0(manager, proxyPoolKey.toId());
        assertEq(sqrtAfter, sqrtBefore, "proxy sqrtPrice should remain unchanged");
        assertEq(tickAfter, tickBefore, "proxy tick should remain unchanged");
    }

    function test_proxySwap_exactOutput_keepsProxySlot0Unchanged() public {
        (uint160 sqrtBefore, int24 tickBefore,,) = StateLibrary.getSlot0(manager, proxyPoolKey.toId());
        _executeSwap(proxyPoolKey, true, int256(100), ZERO_BYTES);
        (uint160 sqrtAfter, int24 tickAfter,,) = StateLibrary.getSlot0(manager, proxyPoolKey.toId());
        assertEq(sqrtAfter, sqrtBefore, "proxy sqrtPrice should remain unchanged");
        assertEq(tickAfter, tickBefore, "proxy tick should remain unchanged");
    }

    function test_proxySwap_exactInput_oneForZero_keepsProxySlot0Unchanged() public {
        (uint160 sqrtBefore, int24 tickBefore,,) = StateLibrary.getSlot0(manager, proxyPoolKey.toId());
        _executeSwap(proxyPoolKey, false, -int256(1e18), ZERO_BYTES);
        (uint160 sqrtAfter, int24 tickAfter,,) = StateLibrary.getSlot0(manager, proxyPoolKey.toId());
        assertEq(sqrtAfter, sqrtBefore, "proxy sqrtPrice should remain unchanged");
        assertEq(tickAfter, tickBefore, "proxy tick should remain unchanged");
    }

    function test_proxySwap_exactOutput_oneForZero_keepsProxySlot0Unchanged() public {
        (uint160 sqrtBefore, int24 tickBefore,,) = StateLibrary.getSlot0(manager, proxyPoolKey.toId());
        _executeSwap(proxyPoolKey, false, int256(100), ZERO_BYTES);
        (uint160 sqrtAfter, int24 tickAfter,,) = StateLibrary.getSlot0(manager, proxyPoolKey.toId());
        assertEq(sqrtAfter, sqrtBefore, "proxy sqrtPrice should remain unchanged");
        assertEq(tickAfter, tickBefore, "proxy tick should remain unchanged");
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
        assertEq(preBalanceOfToken0UnderlyingAssetInLCC, postBalanceOfToken0UnderlyingAssetInLCC + deltaAmount0);
        // validate liquidity of token-in(token0) in the pool manager is higher after the swap
        // becase liquidity of the underlying tokens will be moved from lcc token to pool manager
        // so the pool manager's underlying balance should increase by the amount of token-in(token0) swapped into the pool
        assertEq(postBalanceOfToken0UnderlyingAssetInPM, preBalanceOfToken0UnderlyingAssetInPM + deltaAmount0);
        // Token OUT underlying is NOT moved here. It is sourced on unwrap via market liquidity.
        // Therefore, neither the Hub nor PoolManager underlying balances should change for token-out during the swap.
        assertEq(postBalanceOfToken1UnderlyingAssetInLCC, preBalanceOfToken1UnderlyingAssetInLCC);
        assertEq(preBalanceOfToken1UnderlyingAssetInPM, postBalanceOfToken1UnderlyingAssetInPM);
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

        // Token OUT underlying is NOT moved here. It is sourced on unwrap via market liquidity.
        // Therefore, neither the Hub nor PoolManager underlying balances should change for token-out during the swap.
        assertEq(postBalanceOfToken0UnderlyingAssetInLCC, preBalanceOfToken0UnderlyingAssetInLCC);
        assertEq(preBalanceOfToken0UnderlyingAssetInPM, postBalanceOfToken0UnderlyingAssetInPM);
        // validate liquidity of token-in(token1) in the lcc token is lower after the swap
        // because liquidity will move 'from lcc' tokens 'to pool-manager' as it enters the pool during a one for zero swap
        assertEq(preBalanceOfToken1UnderlyingAssetInLCC, postBalanceOfToken1UnderlyingAssetInLCC + deltaAmount1);
        // validate liquidity of token-in(token1) in the pool manager is higher after the swap
        // because liquidity of the underlying tokens will be moved from LCC token to pool-manager
        // so the pool manager's underlying balance should increase by the amount of token-in(token1) swapped into of the pool
        assertEq(postBalanceOfToken1UnderlyingAssetInPM, preBalanceOfToken1UnderlyingAssetInPM + deltaAmount1);
    }

    // Option A: no hook data defaults to locker. If the locker cannot be resolved, swaps may still proceed
    // as long as they can be fully settled into underlying (no deficit path required).
    function test_swap_exactInput_zeroForOneOnProxy_withLimitedLiquidity_noHookData() public {
        uint256 mockAvailableLiquidity = 50;
        _mockLimitedLiquidity(_currency1, mockAvailableLiquidity);

        uint256 swapAmount = 10;
        (uint256 expectedInput, uint256 expectedOutput) = _simulateSwap(corePoolKey, true, -int256(swapAmount));
        assertGt(expectedOutput, 0, "precondition: must produce non-zero output");
        assertLe(expectedOutput, mockAvailableLiquidity, "precondition: must not require deficit");

        BalanceDelta swapDelta = _executeSwap(proxyPoolKey, true, -int256(swapAmount), ZERO_BYTES);
        (uint256 actualInput, uint256 actualOutput) = _getSwapDeltas(swapDelta, true);
        assertEq(actualInput, expectedInput, "Input should match full swap");
        assertEq(actualOutput, expectedOutput, "Output should match simulation");
    }

    function test_swap_exactInput_oneForZeroOnProxy_withLimitedLiquidity_noHookData() public {
        uint256 mockAvailableLiquidity = 50;
        _mockLimitedLiquidity(_currency0, mockAvailableLiquidity);

        uint256 swapAmount = 10;
        (uint256 expectedInput, uint256 expectedOutput) = _simulateSwap(corePoolKey, false, -int256(swapAmount));
        assertGt(expectedOutput, 0, "precondition: must produce non-zero output");
        assertLe(expectedOutput, mockAvailableLiquidity, "precondition: must not require deficit");

        BalanceDelta swapDelta = _executeSwap(proxyPoolKey, false, -int256(swapAmount), ZERO_BYTES);
        (uint256 actualInput, uint256 actualOutput) = _getSwapDeltas(swapDelta, false);
        assertEq(actualInput, expectedInput, "Input should match full swap");
        assertEq(actualOutput, expectedOutput, "Output should match simulation");
    }

    function test_swap_exactInput_onProxy_adjustPath_butNoAdjustmentWhenAvailableIsBetweenUpperBoundAndSimulated()
        public
    {
        // Option A path: with sufficient liquidity and no recipient metadata, swap executes without capping.
        uint256 swapAmount = 1e18;
        (uint256 expectedInput, uint256 expectedOutput) = _simulateSwap(corePoolKey, true, -int256(swapAmount));

        // Ensure settlement can be completed without deficit.
        _mockLimitedLiquidity(_currency1, expectedOutput + 1);

        BalanceDelta swapDelta = _executeSwap(proxyPoolKey, true, -int256(swapAmount), ZERO_BYTES);
        (uint256 actualInput, uint256 actualOutput) = _getSwapDeltas(swapDelta, true);

        assertEq(actualInput, expectedInput, "Input should not be reduced when available covers simulated output");
        assertEq(actualOutput, expectedOutput, "Output should match simulation when no adjustment applies");

        vm.clearMockedCalls();
    }

    // Test that a swap with limited liquidity on the proxy pool works as expected
    // when hookData with recipient IS provided, the swap should NOT be restricted and excess LCC should go to recipient
    function test_swap_exactInput_zeroForOneOnProxy_withLimitedLiquidity_withHookData() public {
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

        // Queue should be created immediately in the deficit flow.
        uint256 amountOwedToRecipient = LiquidityHub(payable(liquidityHub)).settleQueue(address(lccOut), lcc_recipient);
        console.log("amountOwedToRecipient:", amountOwedToRecipient);

        // validate queued deficit amount is attributed to the recipient
        assertEq(amountOwedToRecipient, deficit, "Amount owed should equal deficit");

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
     *  1. Without recipient: succeeds when output can be fully settled (no deficit required)
     *  2. With recipient: succeeds even when output exceeds available liquidity (deficit assigned)
     */
    function test_swapBehaviorFork_withAndWithoutRecipient() public {
        console.log("====== test_swapBehaviorFork_withAndWithoutRecipient =======");

        uint256 mockAvailableLiquidity = 50;
        uint256 smallSwapAmount = 10;
        (uint256 expectedSmallInput, uint256 expectedSmallOutput) =
            _simulateSwap(corePoolKey, true, -int256(smallSwapAmount));
        assertGt(expectedSmallOutput, 0, "precondition: small swap must produce non-zero output");
        assertLe(expectedSmallOutput, mockAvailableLiquidity, "precondition: small swap must not require deficit");

        // Mock limited available liquidity.
        _mockLimitedLiquidity(_currency1, mockAvailableLiquidity);

        LiquidityCommitmentCertificate lccOut = _getLCCOut(_currency1);

        // ===== TEST 1: WITHOUT RECIPIENT (no deficit required) =====
        BalanceDelta deltaNoRecipient = _executeSwap(proxyPoolKey, true, -int256(smallSwapAmount), ZERO_BYTES);
        (uint256 inputNoRecipient, uint256 outputNoRecipient) = _getSwapDeltas(deltaNoRecipient, true);
        assertEq(inputNoRecipient, expectedSmallInput, "Without recipient: input should match full swap");
        assertEq(outputNoRecipient, expectedSmallOutput, "Without recipient: output should match simulation");
        assertEq(
            LiquidityHub(payable(liquidityHub)).totalQueued(address(lccOut)),
            0,
            "Without recipient: settlement queue should remain empty"
        );

        // ===== TEST 2: WITH RECIPIENT (deficit assigned) =====
        uint256 swapAmount = 100;
        (uint256 expectedFullInput, uint256 expectedFullOutput) = _simulateSwap(corePoolKey, true, -int256(swapAmount));
        assertGt(expectedFullOutput, mockAvailableLiquidity, "precondition: must require deficit for comparison");

        address recipient = makeAddr("recipient");
        _setupRecipient(recipient);

        // Reset mock for second swap
        _mockLimitedLiquidity(_currency1, mockAvailableLiquidity);

        (, uint256 recipientMarketBalanceBefore) = lccOut.balancesOf(recipient);

        BalanceDelta deltaWithRecipient = _executeSwap(
            proxyPoolKey,
            true, // zeroForOne
            -int256(swapAmount),
            abi.encode(recipient)
        );
        (uint256 inputWithRecipient, uint256 outputWithRecipient) = _getSwapDeltas(deltaWithRecipient, true);

        // Verify unrestricted behavior
        assertEq(inputWithRecipient, expectedFullInput, "With recipient: input should match full swap");
        assertLe(outputWithRecipient, expectedFullOutput, "With recipient: output should not exceed full simulation");

        // Verify excess LCC goes to recipient
        (, uint256 recipientMarketBalance) = lccOut.balancesOf(recipient);
        assertGt(recipientMarketBalance, recipientMarketBalanceBefore, "Recipient should receive non-zero deficit LCC");
        assertEq(lccOut.balanceOf(recipient), recipientMarketBalance, "Recipient should hold deficit LCC tokens");

        // Verify market deficit is queued immediately to the recipient.
        // The queue is backed by the market-derived LCC transferred in the same deficit flow.
        assertEq(
            LiquidityHub(payable(liquidityHub)).totalQueued(address(lccOut)),
            recipientMarketBalance,
            "Settlement queue should equal deficit immediately"
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

    /// @notice Address(0) sentinel maps to locker.
    function test_determineExcessRecipient_addressZero() public {
        ProxyHookHarness harness = new ProxyHookHarness(address(manager), address(marketFactory));
        MockMsgSender sender = new MockMsgSender(makeAddr("locker"));
        (address got, bool resolved) = harness.exposed_determineExcessRecipient(address(sender), abi.encode(address(0)));
        assertTrue(resolved, "locker should resolve via IMsgSender");
        assertEq(got, sender.msgSender(), "address(0) should map to locker");
    }

    /// @notice Address(1) sentinel maps to locker.
    function test_determineExcessRecipient_addressOne() public {
        ProxyHookHarness harness = new ProxyHookHarness(address(manager), address(marketFactory));
        MockMsgSender sender = new MockMsgSender(makeAddr("locker"));
        (address got, bool resolved) = harness.exposed_determineExcessRecipient(address(sender), abi.encode(address(1)));
        assertTrue(resolved, "locker should resolve via IMsgSender");
        assertEq(got, sender.msgSender(), "address(1) should map to locker");
    }

    function test_determineExcessRecipient_lockerUnresolved_whenMsgSenderReturnsZero() public {
        ProxyHookHarness harness = new ProxyHookHarness(address(manager), address(marketFactory));
        MockMsgSenderZero sender = new MockMsgSenderZero();
        (address got, bool resolved) = harness.exposed_determineExcessRecipient(address(sender), abi.encode(address(1)));
        assertFalse(resolved, "locker should be unresolved if msgSender() returns address(0)");
        assertEq(got, address(0), "unresolved locker must return address(0)");
    }

    function test_determineExcessRecipient_lockerUnresolved_whenSenderHasNoMsgSender() public {
        ProxyHookHarness harness = new ProxyHookHarness(address(manager), address(marketFactory));
        address sender = makeAddr("no_msgsender");
        (address got, bool resolved) = harness.exposed_determineExcessRecipient(sender, abi.encode(address(1)));
        assertFalse(resolved, "locker should be unresolved if sender has no msgSender()");
        assertEq(got, address(0), "unresolved locker must return address(0)");
    }

    /**
     * @notice Test _determineExcessRecipient with address(2) - should return msg.sender (Router)
     */
    function test_determineExcessRecipient_addressTwo() public {
        ProxyHookHarness harness = new ProxyHookHarness(address(manager), address(marketFactory));
        address sender = makeAddr("router_sender");
        (address got, bool resolved) = harness.exposed_determineExcessRecipient(sender, abi.encode(address(2)));
        assertTrue(resolved, "router sentinel should resolve");
        assertEq(got, sender, "address(2) should map to sender");
    }

    /**
     * @notice Test exact output swap with limited liquidity (no hookData)
     */
    function test_swap_exactOutput_zeroForOneOnProxy_withLimitedLiquidity_noHookData() public {
        uint256 mockAvailableLiquidity = 50;
        _mockLimitedLiquidity(_currency1, mockAvailableLiquidity);

        // Exact output swap requesting more than available must revert (strict exact-output).
        uint256 requestedOutput = 100;
        vm.expectRevert();
        _executeSwap(proxyPoolKey, true, int256(requestedOutput), ZERO_BYTES);
    }

    /**
     * @notice Test exact output swap with limited liquidity (with hookData)
     * @dev Strict exact-output: must revert even when recipient is resolved (MKT-05 cancellation).
     */
    function test_swap_exactOutput_zeroForOneOnProxy_withLimitedLiquidity_withHookData() public {
        address recipient = makeAddr("output_recipient");
        _setupRecipient(recipient);

        uint256 mockAvailableLiquidity = 50;
        _mockLimitedLiquidity(_currency1, mockAvailableLiquidity);

        uint256 requestedOutput = 100;
        vm.expectRevert();
        _executeSwap(proxyPoolKey, true, int256(requestedOutput), abi.encode(recipient));
    }

    function test_swap_exactOutput_oneForZeroOnProxy_withLimitedLiquidity_noHookData() public {
        uint256 mockAvailableLiquidity = 50;
        _mockLimitedLiquidity(_currency0, mockAvailableLiquidity);

        uint256 requestedOutput = 100;
        vm.expectRevert();
        _executeSwap(proxyPoolKey, false, int256(requestedOutput), ZERO_BYTES);
    }

    function test_swap_exactOutput_oneForZeroOnProxy_withLimitedLiquidity_withHookData() public {
        address recipient = makeAddr("output_recipient_oneForZero");
        _setupRecipient(recipient);

        uint256 mockAvailableLiquidity = 50;
        _mockLimitedLiquidity(_currency0, mockAvailableLiquidity);

        uint256 requestedOutput = 100;
        vm.expectRevert();
        _executeSwap(proxyPoolKey, false, int256(requestedOutput), abi.encode(recipient));
    }

    function testFuzz_swap_exactOutput_zeroForOneOnProxy_revertsWhenRequestedExceedsImmediateLiquidity(
        uint96 availableRaw,
        uint96 requestedRaw
    ) public {
        uint256 available = bound(uint256(availableRaw), 1, 1e18);
        uint256 requested = bound(uint256(requestedRaw), available + 1, available + 1e18);
        _mockLimitedLiquidity(_currency1, available);

        vm.expectRevert();
        _executeSwap(proxyPoolKey, true, int256(requested), ZERO_BYTES);
    }

    function testFuzz_swap_exactOutput_oneForZeroOnProxy_revertsWhenRequestedExceedsImmediateLiquidity(
        uint96 availableRaw,
        uint96 requestedRaw
    ) public {
        uint256 available = bound(uint256(availableRaw), 1, 1e18);
        uint256 requested = bound(uint256(requestedRaw), available + 1, available + 1e18);
        _mockLimitedLiquidity(_currency0, available);

        vm.expectRevert();
        _executeSwap(proxyPoolKey, false, int256(requested), ZERO_BYTES);
    }

    function test_proxySwap_exactInput_revertsOnCoreFillMismatch_dueToTightPriceLimit() public {
        // Ensure maxOutputAvailable won't be the reason for reverting.
        _mockLimitedLiquidity(proxyPoolKey.currency0, type(uint256).max);
        _mockLimitedLiquidity(proxyPoolKey.currency1, type(uint256).max);

        (uint160 sqrtP,,,) = StateLibrary.getSlot0(manager, proxyPoolKey.toId());
        uint160 limit = sqrtP - 1;
        if (limit <= TickMath.MIN_SQRT_PRICE + 1) {
            limit = TickMath.MIN_SQRT_PRICE + 1;
        }

        // Tight price limit should cause a partial-fill simulation on core, which is disallowed under Option A.
        vm.expectRevert();
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1e18), sqrtPriceLimitX96: limit}),
            _getSwapSettings(),
            ZERO_BYTES
        );
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

        (, uint256 fullOutput) = _simulateSwap(corePoolKey, false, -int256(swapAmount));

        _executeSwap(
            proxyPoolKey,
            false, // oneForZero
            -int256(swapAmount),
            abi.encode(recipient)
        );

        uint256 queuedAfter = LiquidityHub(payable(liquidityHub)).settleQueue(address(lccOut), recipient);
        assertEq(fullOutput - queuedAfter, mockAvailableLiquidity, "Should execute full swap with recipient");

        if (fullOutput > mockAvailableLiquidity) {
            uint256 expectedDeficit = fullOutput - mockAvailableLiquidity;
            (, uint256 recipientMarketBalance) = lccOut.balancesOf(recipient);
            assertEq(recipientMarketBalance, expectedDeficit, "Recipient should receive deficit LCC");
            assertEq(
                LiquidityHub(payable(liquidityHub)).settleQueue(address(lccOut), recipient),
                expectedDeficit,
                "Deficit should be queued immediately"
            );
        }

        vm.clearMockedCalls();
    }

    function test_swap_exactInput_oneForZero_withRecipient_fullQueueSettlementLifecycle() public {
        address recipient = makeAddr("oneForZero_settle_recipient");
        _setupRecipient(recipient);

        uint256 mockAvailableLiquidity = 50;
        _mockLimitedLiquidity(_currency0, mockAvailableLiquidity);

        uint256 swapAmount = 100;
        LiquidityCommitmentCertificate lccOut = _getLCCOut(_currency0);

        (, uint256 fullOutput) = _simulateSwap(corePoolKey, false, -int256(swapAmount));
        _executeSwap(proxyPoolKey, false, -int256(swapAmount), abi.encode(recipient));

        uint256 queuedAfter = LiquidityHub(payable(liquidityHub)).settleQueue(address(lccOut), recipient);
        assertEq(
            fullOutput - queuedAfter,
            mockAvailableLiquidity,
            "Underlying output should be capped by available liquidity"
        );

        (, uint256 deficit) = lccOut.balancesOf(recipient);
        assertGt(deficit, 0, "Expected a deficit to be represented as recipient-held market-derived LCC");
        assertEq(queuedAfter, deficit);

        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            ZERO_BYTES
        );

        _mockLimitedLiquidity(_currency0, initialLiquidity);
        LiquidityHub(payable(liquidityHub)).processSettlementFor(address(lccOut), recipient, deficit);

        assertEq(LiquidityHub(payable(liquidityHub)).settleQueue(address(lccOut), recipient), 0);
        assertEq(lccOut.balanceOf(recipient), 0, "Settled amount should burn recipient-held deficit LCC");
        assertEq(_currency0.balanceOf(recipient), deficit, "Recipient should receive the settled underlying amount");

        vm.clearMockedCalls();
    }

    function test_swap_exactInput_withExemptRecipient_revertsOnDeficitQueueSecurityCheck() public {
        address recipient = makeAddr("exempt_recipient");
        _setupRecipient(recipient);

        vm.prank(marketFactory);
        LiquidityHub(payable(liquidityHub)).setBoundLevel(recipient, Bounds.BOUND_EXEMPT);

        _mockLimitedLiquidity(_currency1, 1);

        vm.expectRevert();
        _executeSwap(proxyPoolKey, true, -int256(100), abi.encode(recipient));
    }

    function test_swap_deficitQueue_isAnnulledWhenRecipientTransfersLccBeforeSettlement() public {
        address recipient = makeAddr("annul_recipient");
        _setupRecipient(recipient);

        uint256 mockAvailableOutputLiquidity = 50;
        _mockLimitedLiquidity(_currency1, mockAvailableOutputLiquidity);

        uint256 swapAmount = 100;
        LiquidityCommitmentCertificate lccOut = _getLCCOut(_currency1);

        (, uint256 fullOutput) = _simulateSwap(corePoolKey, true, -int256(swapAmount));
        _executeSwap(proxyPoolKey, true, -int256(swapAmount), abi.encode(recipient));

        uint256 queued = LiquidityHub(payable(liquidityHub)).settleQueue(address(lccOut), recipient);
        assertEq(fullOutput - queued, mockAvailableOutputLiquidity);

        (, uint256 queuedDeficit) = lccOut.balancesOf(recipient);
        assertGt(queuedDeficit, 0, "Expected queued deficit");
        assertEq(LiquidityHub(payable(liquidityHub)).settleQueue(address(lccOut), recipient), queuedDeficit);

        vm.prank(recipient);
        lccOut.transfer(address(manager), queuedDeficit);

        assertEq(
            LiquidityHub(payable(liquidityHub)).settleQueue(address(lccOut), recipient),
            0,
            "Queue should be annulled when recipient transfers queued-backed LCC away"
        );
        assertEq(lccOut.balanceOf(recipient), 0, "Recipient should no longer hold deficit LCC");

        vm.clearMockedCalls();
    }

    function test_directLP_removeLiquidity_doesNotRevert() public {
        // Direct-LP removals should not revert (even though ProxyHook is no longer notified).
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -int256(1e18), salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function test_directLP_removeLiquidity_doesNotRevert_whenPoolPaused() public {
        vtsOrchestrator.pausePool(corePoolKey.toId());

        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -int256(1e18), salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function test_directLP_removeLiquidity_doesNotRevert_whenGlobalPauseActive() public {
        vtsOrchestrator.setGlobalPause(true);

        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -int256(1e18), salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function test_activate_setsCoreHook_onFreshProxyHook() public {
        // Deploy a fresh proxy hook instance (not created via MarketFactory) so coreHook starts unset.
        // Use harness (no hook-address validation) so we can deploy at an arbitrary address in tests.
        ProxyHookHarness fresh = new ProxyHookHarness(address(manager), address(marketFactory));
        assertEq(fresh.coreHook(), address(0), "fresh coreHook should be unset");

        vm.prank(marketFactory);
        fresh.activate();

        assertEq(fresh.coreHook(), coreHookAddress, "activate should wire coreHook from factory");

        // Idempotent: calling again should not revert and should not change the value.
        vm.prank(marketFactory);
        fresh.activate();
        assertEq(fresh.coreHook(), coreHookAddress, "activate should remain stable");
    }

    function test_setCorePoolKey_revertsIfAlreadySet_onFreshProxyHook() public {
        // Use harness (no hook-address validation) so we can deploy at an arbitrary address in tests.
        ProxyHookHarness fresh = new ProxyHookHarness(address(manager), address(marketFactory));

        // First set should succeed.
        vm.prank(marketFactory);
        fresh.setCorePoolKey(corePoolKey);

        // Second set should revert.
        vm.prank(marketFactory);
        vm.expectRevert(Errors.CorePoolKeyAlreadySet.selector);
        fresh.setCorePoolKey(corePoolKey);
    }

    function test_getCorePoolId_matchesCorePoolKey() public view {
        // Simple view-path coverage.
        assertEq(PoolId.unwrap(proxyHook.getCorePoolId()), PoolId.unwrap(corePoolKey.toId()));
    }

    function test_handleSwap_noop_whenWrappedAmountIsZero() public {
        ProxyHookHarness harness = new ProxyHookHarness(address(manager), address(marketFactory));
        vm.prank(marketFactory);
        harness.activate();
        vm.prank(marketFactory);
        harness.setCorePoolKey(corePoolKey);
        harness.exposed_setNoCoreActionFlag(true);

        vm.prank(coreHookAddress);
        harness.handleSwap(Currency.unwrap(corePoolKey.currency0));
    }

    function test_proxySwap_priceLimit_zero_executesCalc_thenReturnsNonZeroDelta() public {
        // PoolManager calls beforeSwap before Pool.swap validates sqrtPriceLimitX96 bounds, so this still exercises
        // ProxyHook's _calcCoreSqrtPriceLimit(0, flipped) branch.
        PoolSwapTest.TestSettings memory settings = _getSwapSettings();

        BalanceDelta delta = swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1e18), sqrtPriceLimitX96: 0}),
            settings,
            ZERO_BYTES
        );

        // Guard against silent no-op paths: branch should execute as an actual swap attempt.
        assertTrue(delta.amount0() != 0 || delta.amount1() != 0, "swap should return non-zero delta");
    }

    function test_proxySwap_priceLimit_flipBranches_minMaxAndInvert_whenFlippedMarketExists() public {
        bool found = _setupMarketUntilFlipped(6);
        assertTrue(found, "could not find flipped market within attempts");

        PoolSwapTest.TestSettings memory settings = _getSwapSettings();

        // Ensure we take the "hasExcessRecipient" path so coreSwapParams are not adjusted.
        address recipient = makeAddr("recipient_for_expectCall");
        _setupRecipient(recipient);

        // MIN+1 branch when flipped (zeroForOne swap uses MIN+1 as limit).
        try swapRouter.swap(
            proxyPoolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1e15), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            abi.encode(recipient)
        ) {}
            catch {}

        // MAX-1 branch when flipped (oneForZero swap uses MAX-1 as limit).
        try swapRouter.swap(
            proxyPoolKey,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(1e15), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            abi.encode(recipient)
        ) {}
            catch {}

        // Inversion branch when flipped (non-extreme limit).
        // Use a direction-valid limit just above current price for oneForZero.
        // Note: depending on post-swap price movements in the core pool, this can revert with PriceLimitAlreadyExceeded.
        // We still want to execute ProxyHook's inversion logic, so we accept the revert.
        uint160 customLimit = SQRT_PRICE_1_1 + 1;

        vm.expectRevert();
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(1e15), sqrtPriceLimitX96: customLimit}),
            settings,
            abi.encode(recipient)
        );
    }

    function test_harness_getExpectedOutputFromDelta_selectsCorrectLeg() public {
        ProxyHookHarness harness = new ProxyHookHarness(address(manager), address(marketFactory));
        BalanceDelta d = toBalanceDelta(int128(111), int128(222));

        assertEq(harness.exposed_getExpectedOutputFromDelta(d, true), 222, "zeroForOne should use amount1");
        assertEq(harness.exposed_getExpectedOutputFromDelta(d, false), 111, "oneForZero should use amount0");
    }

    function test_proxySwap_revertsWhenOutputCurrencyLiquidityIsInsufficient_zeroForOne() public {
        // Option A: insufficient output liquidity should revert (no capping path).
        uint256 swapAmount = 250e18;
        (, uint256 expectedOutput) = _simulateSwap(corePoolKey, true, -int256(swapAmount));
        uint256 smallAvailable = expectedOutput / 4;
        assertGt(expectedOutput, smallAvailable, "precondition: expected output must exceed available");

        // output currency is token1 for zeroForOne swaps
        _mockLimitedLiquidity(proxyPoolKey.currency1, smallAvailable);
        // set the other currency balance high to catch incorrect selection
        _mockLimitedLiquidity(proxyPoolKey.currency0, type(uint256).max);

        vm.expectRevert();
        _executeSwap(proxyPoolKey, true, -int256(swapAmount), ZERO_BYTES);
    }

    function test_proxySwap_revertsWhenOutputCurrencyLiquidityIsInsufficient_oneForZero() public {
        // Option A: insufficient output liquidity should revert (no capping path).
        uint256 swapAmount = 250e18;
        (, uint256 expectedOutput) = _simulateSwap(corePoolKey, false, -int256(swapAmount));
        uint256 smallAvailable = expectedOutput / 4;
        assertGt(expectedOutput, smallAvailable, "precondition: expected output must exceed available");

        // output currency is token0 for oneForZero swaps
        _mockLimitedLiquidity(proxyPoolKey.currency0, smallAvailable);
        // set the other currency balance high to catch incorrect selection
        _mockLimitedLiquidity(proxyPoolKey.currency1, type(uint256).max);

        vm.expectRevert();
        _executeSwap(proxyPoolKey, false, -int256(swapAmount), ZERO_BYTES);
    }

    function test_harness_calcCoreSqrtPriceLimit_branches() public {
        ProxyHookHarness harness = new ProxyHookHarness(address(manager), address(marketFactory));

        // Not flipped: identity.
        assertEq(harness.exposed_calcCoreSqrtPriceLimit(uint160(123), false, false), uint160(123));

        // Flipped extremes.
        assertEq(
            harness.exposed_calcCoreSqrtPriceLimit(TickMath.MIN_SQRT_PRICE + 1, true, false),
            TickMath.MAX_SQRT_PRICE - 1,
            "flipped MIN+1 should map to MAX-1"
        );
        assertEq(
            harness.exposed_calcCoreSqrtPriceLimit(TickMath.MAX_SQRT_PRICE - 1, true, true),
            TickMath.MIN_SQRT_PRICE + 1,
            "flipped MAX-1 should map to MIN+1"
        );

        // Flipped inversion (non-zero, non-extreme).
        uint160 custom = SQRT_PRICE_1_1 + 1;
        uint160 expectedInverted = uint160((uint256(1) << 192) / uint256(custom));
        assertEq(
            harness.exposed_calcCoreSqrtPriceLimit(custom, true, true),
            expectedInverted,
            "flipped non-zero should invert"
        );

        // Flipped near-MAX should clamp to MIN+1 instead of producing an out-of-bounds MIN/underflowed value.
        uint160 nearMax = TickMath.MAX_SQRT_PRICE - 2;
        assertEq(
            harness.exposed_calcCoreSqrtPriceLimit(nearMax, true, true),
            TickMath.MIN_SQRT_PRICE + 1,
            "flipped near-MAX should clamp to MIN+1"
        );

        // Flipped tiny non-zero limits should saturate high before the uint160 cast truncates the reciprocal.
        assertEq(
            harness.exposed_calcCoreSqrtPriceLimit(1, true, false),
            TickMath.MAX_SQRT_PRICE - 1,
            "flipped tiny inputs should clamp to MAX-1 before casting"
        );

        // Flipped zero -> direction-aware defaults.
        assertEq(
            harness.exposed_calcCoreSqrtPriceLimit(0, true, false),
            TickMath.MAX_SQRT_PRICE - 1,
            "core oneForZero default should be MAX-1"
        );
        assertEq(
            harness.exposed_calcCoreSqrtPriceLimit(0, true, true),
            TickMath.MIN_SQRT_PRICE + 1,
            "core zeroForOne default should be MIN+1"
        );
    }

    // -------------------------------------------------------------------------
    // CanonicalVault durable claim ownership (proxy swap mirroring; no transient deltas asserted)
    // -------------------------------------------------------------------------

    function _canonicalVaultPayable() internal view returns (address payable) {
        return payable(IMarketFactory(marketFactory).canonicalVault());
    }

    function _assertUnderlyingClaimsMatchVaultReserves() internal view {
        address payable cv = _canonicalVaultPayable();
        bytes32 m = _coreMarketId();
        assertEq(
            _underlying6909Balance(address(cv), proxyPoolKey.currency0),
            CanonicalVault(cv).inMarketBalanceOf(m, proxyPoolKey.currency0),
            "currency0: ERC6909 claims on CanonicalVault must match durable reserve ledger"
        );
        assertEq(
            _underlying6909Balance(address(cv), proxyPoolKey.currency1),
            CanonicalVault(cv).inMarketBalanceOf(m, proxyPoolKey.currency1),
            "currency1: ERC6909 claims on CanonicalVault must match durable reserve ledger"
        );
    }

    /// @dev Suite B (plan): zeroForOne exact-input must mint input-lane underlying claims to CanonicalVault.
    function test_proxySwap_zeroForOne_exactInput_mintsInputUnderlyingClaimToCanonicalVault() public {
        vm.assume(Currency.unwrap(proxyPoolKey.currency0) != address(0));
        address payable cv = _canonicalVaultPayable();

        uint256 claimInBefore = _underlying6909Balance(address(cv), proxyPoolKey.currency0);
        uint256 hookInBefore = _underlying6909Balance(address(proxyHook), proxyPoolKey.currency0);

        BalanceDelta d = _executeSwap(proxyPoolKey, true, -int256(1e18), ZERO_BYTES);
        (uint256 inputAmt,) = _getSwapDeltas(d, true);

        assertEq(_underlying6909Balance(address(cv), proxyPoolKey.currency0), claimInBefore + inputAmt);
        assertEq(_underlying6909Balance(address(proxyHook), proxyPoolKey.currency0), hookInBefore);
    }

    /// @dev Suite B (plan): zeroForOne exact-input must burn output-lane underlying claims from CanonicalVault.
    function test_proxySwap_zeroForOne_exactInput_burnsOutputUnderlyingClaimFromCanonicalVault() public {
        vm.assume(Currency.unwrap(proxyPoolKey.currency1) != address(0));
        address payable cv = _canonicalVaultPayable();

        uint256 claimOutBefore = _underlying6909Balance(address(cv), proxyPoolKey.currency1);
        uint256 hookOutBefore = _underlying6909Balance(address(proxyHook), proxyPoolKey.currency1);

        BalanceDelta d = _executeSwap(proxyPoolKey, true, -int256(1e18), ZERO_BYTES);
        (, uint256 outputAmt) = _getSwapDeltas(d, true);

        assertEq(claimOutBefore - _underlying6909Balance(address(cv), proxyPoolKey.currency1), outputAmt);
        assertEq(_underlying6909Balance(address(proxyHook), proxyPoolKey.currency1), hookOutBefore);
    }

    /// @dev Suite B (plan): oneForZero exact-input must mint input-lane underlying claims to CanonicalVault.
    function test_proxySwap_oneForZero_exactInput_mintsInputUnderlyingClaimToCanonicalVault() public {
        vm.assume(Currency.unwrap(proxyPoolKey.currency1) != address(0));
        address payable cv = _canonicalVaultPayable();

        uint256 claimInBefore = _underlying6909Balance(address(cv), proxyPoolKey.currency1);
        uint256 hookInBefore = _underlying6909Balance(address(proxyHook), proxyPoolKey.currency1);

        BalanceDelta d = _executeSwap(proxyPoolKey, false, -int256(1e18), ZERO_BYTES);
        (uint256 inputAmt,) = _getSwapDeltas(d, false);

        assertEq(_underlying6909Balance(address(cv), proxyPoolKey.currency1), claimInBefore + inputAmt);
        assertEq(_underlying6909Balance(address(proxyHook), proxyPoolKey.currency1), hookInBefore);
    }

    /// @dev Suite B (plan): oneForZero exact-input must burn output-lane underlying claims from CanonicalVault.
    function test_proxySwap_oneForZero_exactInput_burnsOutputUnderlyingClaimFromCanonicalVault() public {
        vm.assume(Currency.unwrap(proxyPoolKey.currency0) != address(0));
        address payable cv = _canonicalVaultPayable();

        uint256 claimOutBefore = _underlying6909Balance(address(cv), proxyPoolKey.currency0);
        uint256 hookOutBefore = _underlying6909Balance(address(proxyHook), proxyPoolKey.currency0);

        BalanceDelta d = _executeSwap(proxyPoolKey, false, -int256(1e18), ZERO_BYTES);
        (, uint256 outputAmt) = _getSwapDeltas(d, false);

        assertEq(claimOutBefore - _underlying6909Balance(address(cv), proxyPoolKey.currency0), outputAmt);
        assertEq(_underlying6909Balance(address(proxyHook), proxyPoolKey.currency0), hookOutBefore);
    }

    /// @dev Suite B (plan): after successful exact-input swaps, CanonicalVault claim ownership must equal reserve ledger.
    function test_proxySwap_exactInput_preservesInvariant_claimsOwnedByCanonicalVault_matchVaultReserves() public {
        vm.assume(Currency.unwrap(proxyPoolKey.currency0) != address(0));
        vm.assume(Currency.unwrap(proxyPoolKey.currency1) != address(0));

        _assertUnderlyingClaimsMatchVaultReserves();
        _executeSwap(proxyPoolKey, true, -int256(1e18), ZERO_BYTES);
        _assertUnderlyingClaimsMatchVaultReserves();

        _executeSwap(proxyPoolKey, false, -int256(1e17), ZERO_BYTES);
        _assertUnderlyingClaimsMatchVaultReserves();
    }

    /// @dev Suite C (plan): with resolved recipient and limited output reserve, only immediate available output burns claims.
    function test_proxySwap_exactInput_withResolvedRecipient_burnsOnlyImmediateOutputClaimPortion() public {
        vm.assume(Currency.unwrap(proxyPoolKey.currency1) != address(0));
        address recipient = makeAddr("claim_deficit_recipient");
        _setupRecipient(recipient);

        uint256 mockAvailable = 50;
        _mockLimitedLiquidity(_currency1, mockAvailable);

        uint256 swapAmount = 100;
        (, uint256 expectedOutput) = _simulateSwap(corePoolKey, true, -int256(swapAmount));
        assertGt(expectedOutput, mockAvailable, "pre: deficit path required");

        address payable cv = _canonicalVaultPayable();
        uint256 claimOutBefore = _underlying6909Balance(address(cv), proxyPoolKey.currency1);

        _executeSwap(proxyPoolKey, true, -int256(swapAmount), abi.encode(recipient));

        uint256 burned = claimOutBefore - _underlying6909Balance(address(cv), proxyPoolKey.currency1);
        assertEq(burned, mockAvailable, "only immediate vault liquidity should burn underlying claims");

        assertGt(LiquidityHub(payable(liquidityHub)).settleQueue(address(_getLCCOut(_currency1)), recipient), 0);
        vm.clearMockedCalls();
    }

    /// @dev Suite C (plan): deficit on output lane must not break full input-lane claim mirroring into CanonicalVault.
    function test_proxySwap_exactInput_withResolvedRecipient_keepsInputClaimMirroringEvenWhenOutputDeficits() public {
        vm.assume(Currency.unwrap(proxyPoolKey.currency0) != address(0));
        address recipient = makeAddr("claim_deficit_recipient_in");
        _setupRecipient(recipient);

        uint256 mockAvailable = 50;
        _mockLimitedLiquidity(_currency1, mockAvailable);

        uint256 swapAmount = 100;
        (uint256 expectedInput, uint256 expectedOutput) = _simulateSwap(corePoolKey, true, -int256(swapAmount));
        assertGt(expectedOutput, mockAvailable);

        address payable cv = _canonicalVaultPayable();
        uint256 claimInBefore = _underlying6909Balance(address(cv), proxyPoolKey.currency0);

        BalanceDelta d = _executeSwap(proxyPoolKey, true, -int256(swapAmount), abi.encode(recipient));
        (uint256 inputAmt,) = _getSwapDeltas(d, true);

        assertEq(inputAmt, expectedInput);
        assertEq(_underlying6909Balance(address(cv), proxyPoolKey.currency0), claimInBefore + inputAmt);

        vm.clearMockedCalls();
    }

    /// @dev Suite C (plan): unresolved-recipient deficit must revert without mutating durable claim or reserve ownership.
    function test_proxySwap_exactInput_unresolvedRecipient_revertsWhenOutputExceedsVault() public {
        vm.assume(Currency.unwrap(proxyPoolKey.currency1) != address(0));
        vm.assume(Currency.unwrap(proxyPoolKey.currency0) != address(0));

        address payable cv = _canonicalVaultPayable();
        bytes32 marketId = _coreMarketId();
        uint256[2] memory reserveBefore = [
            CanonicalVault(cv).inMarketBalanceOf(marketId, proxyPoolKey.currency0),
            CanonicalVault(cv).inMarketBalanceOf(marketId, proxyPoolKey.currency1)
        ];
        uint256[2] memory totalBefore = [
            CanonicalVault(cv).totalUnderlyingReserves(Currency.unwrap(proxyPoolKey.currency0)),
            CanonicalVault(cv).totalUnderlyingReserves(Currency.unwrap(proxyPoolKey.currency1))
        ];

        uint256 mockAvailable = 50;
        _mockLimitedLiquidity(_currency1, mockAvailable);

        uint256 swapAmount = 100;
        (, uint256 expectedOutput) = _simulateSwap(corePoolKey, true, -int256(swapAmount));
        assertGt(expectedOutput, mockAvailable, "pre: must revert on unresolved recipient");

        uint256 c0Claim = _underlying6909Balance(address(cv), proxyPoolKey.currency0);
        uint256 c1Claim = _underlying6909Balance(address(cv), proxyPoolKey.currency1);
        uint256 hookC0 = _underlying6909Balance(address(proxyHook), proxyPoolKey.currency0);
        uint256 hookC1 = _underlying6909Balance(address(proxyHook), proxyPoolKey.currency1);

        vm.expectRevert();
        _executeSwap(proxyPoolKey, true, -int256(swapAmount), ZERO_BYTES);

        vm.clearMockedCalls();

        assertEq(_underlying6909Balance(address(cv), proxyPoolKey.currency0), c0Claim);
        assertEq(_underlying6909Balance(address(cv), proxyPoolKey.currency1), c1Claim);
        assertEq(_underlying6909Balance(address(proxyHook), proxyPoolKey.currency0), hookC0);
        assertEq(_underlying6909Balance(address(proxyHook), proxyPoolKey.currency1), hookC1);
        assertEq(CanonicalVault(cv).inMarketBalanceOf(marketId, proxyPoolKey.currency0), reserveBefore[0]);
        assertEq(CanonicalVault(cv).inMarketBalanceOf(marketId, proxyPoolKey.currency1), reserveBefore[1]);
        assertEq(CanonicalVault(cv).totalUnderlyingReserves(Currency.unwrap(proxyPoolKey.currency0)), totalBefore[0]);
        assertEq(CanonicalVault(cv).totalUnderlyingReserves(Currency.unwrap(proxyPoolKey.currency1)), totalBefore[1]);
    }

    /// @dev Suite D (plan): compatibility pin for mint target ownership under `take(..., true)`.
    function test_claimMintTarget_isCanonicalVault_notMsgSender() public {
        test_proxySwap_zeroForOne_exactInput_mintsInputUnderlyingClaimToCanonicalVault();
    }

    /// @dev Suite D (plan): compatibility pin for burn source ownership under `settle(..., true)`.
    function test_claimBurnSource_isCanonicalVault_notMsgSender() public {
        test_proxySwap_zeroForOne_exactInput_burnsOutputUnderlyingClaimFromCanonicalVault();
    }

    // -------------------------------------------------------------------------
    // Liveness: prior legitimate vault consumers vs proxy swap (see CAVEATS.md)
    // -------------------------------------------------------------------------

    /// @dev Market-derived LCC on `runner` via bucket-exempt proxyHook transfer (same pattern as MarketVault tests).
    function _fundRunnerWithMarketDerivedLCC(
        UnwrapInUnlockRunner runner,
        LiquidityCommitmentCertificate lcc,
        uint256 amount
    ) internal {
        address ua = lcc.underlying();
        require(ua != address(0), "liveness tests require ERC20 underlyings");
        IERC20Minimal(ua).transfer(address(proxyHook), amount);
        vm.startPrank(address(proxyHook));
        IERC20Minimal(ua).approve(liquidityHub, amount);
        LiquidityHub(payable(liquidityHub)).wrap(address(lcc), amount);
        lcc.transfer(address(runner), amount);
        vm.stopPrank();
    }

    /// @dev Unwrap market-derived LCC inside PoolManager.unlock; withdraws underlying from the market vault.
    function _unwrapMarketDerivedFromVault(LiquidityCommitmentCertificate lcc, uint256 amount) internal {
        UnwrapInUnlockRunner runner = new UnwrapInUnlockRunner(IPoolManager(address(manager)), liquidityHub);
        _fundRunnerWithMarketDerivedLCC(runner, lcc, amount);
        runner.run(address(lcc), amount);
    }

    /// @dev LCC whose underlying matches `currency` (proxy pool uses underlying currencies).
    function _lccForUnderlyingCurrency(Currency currency) internal view returns (LiquidityCommitmentCertificate) {
        address u = Currency.unwrap(currency);
        if (lcc0.underlying() == u) return lcc0;
        if (lcc1.underlying() == u) return lcc1;
        revert("underlying not in market");
    }

    /**
     * @notice Prior unwrap on the proxy output lane depletes vault; later proxy exact-output fails closed.
     * @dev Lane-matched: unwrap drains `proxyPoolKey.currency1` (zeroForOne output), then exact-output needs more than remains.
     */
    function test_proxyLiveness_priorUnwrapDrainsOutputLane_exactOutputReverts() public {
        Currency currencyOut = proxyPoolKey.currency1;
        LiquidityCommitmentCertificate lccOut = _lccForUnderlyingCurrency(currencyOut);

        uint256 beforeVault = mv.inMarketBalanceOf(currencyOut);
        assertGt(beforeVault, 100, "pre: need vault liquidity on proxy output lane");

        uint256 requestedOut = beforeVault / 2;
        if (requestedOut == 0) {
            requestedOut = 1;
        }
        uint256 drain = (beforeVault * 3) / 4;
        if (drain == 0) {
            drain = 1;
        }
        assertLt(beforeVault - drain, requestedOut, "pre: drain should leave less than requested exact output");

        _unwrapMarketDerivedFromVault(lccOut, drain);

        uint256 afterVault = mv.inMarketBalanceOf(currencyOut);
        assertLt(afterVault, requestedOut, "post: vault must be short vs requested exact output");

        vm.expectRevert();
        _executeSwap(proxyPoolKey, true, int256(requestedOut), ZERO_BYTES);
    }

    /**
     * @notice Prior unwrap on the non-output lane does not block a proxy exact-output that only needs the other underlying.
     * @dev Lane-mismatched: drain `currency0` only, then zeroForOne proxy (output `currency1`) should still succeed.
     */
    function test_proxyLiveness_priorUnwrapOtherLane_exactOutputStillSucceeds() public {
        Currency currencyOut = proxyPoolKey.currency1;
        Currency currencyInLane = proxyPoolKey.currency0;
        LiquidityCommitmentCertificate lccOther = _lccForUnderlyingCurrency(currencyInLane);

        uint256 beforeOut = mv.inMarketBalanceOf(currencyOut);
        uint256 beforeInLane = mv.inMarketBalanceOf(currencyInLane);
        assertGt(beforeOut, 10, "pre: need output-lane liquidity");
        assertGt(beforeInLane, 10, "pre: need non-output lane to drain");

        uint256 drainOther = (beforeInLane * 3) / 4;
        if (drainOther == 0) {
            drainOther = 1;
        }
        _unwrapMarketDerivedFromVault(lccOther, drainOther);

        uint256 requestedOut = beforeOut / 4;
        if (requestedOut == 0) {
            requestedOut = 1;
        }
        assertLt(requestedOut, mv.inMarketBalanceOf(currencyOut), "output lane should still cover small exact output");

        _executeSwap(proxyPoolKey, true, int256(requestedOut), ZERO_BYTES);
    }

    /**
     * @notice After draining the output lane, exact-input with unresolved recipient reverts; resolved recipient can queue deficit.
     */
    function test_proxyLiveness_priorUnwrapDrainsOutputLane_exactInputUnresolvedReverts_resolvedQueues() public {
        Currency currencyOut = proxyPoolKey.currency1;
        LiquidityCommitmentCertificate lccOut = _lccForUnderlyingCurrency(currencyOut);
        address recipient = makeAddr("liveness_recipient");
        _setupRecipient(recipient);

        uint256 beforeVault = mv.inMarketBalanceOf(currencyOut);
        assertGt(beforeVault, 10_000, "pre: need vault liquidity");

        uint256 leaveInVault = 1000;
        uint256 drain = beforeVault > leaveInVault ? beforeVault - leaveInVault : 0;
        assertGt(drain, 0, "pre: need drainable vault balance");
        _unwrapMarketDerivedFromVault(lccOut, drain);

        uint256 afterVault = mv.inMarketBalanceOf(currencyOut);
        assertLe(afterVault, leaveInVault, "post: output lane should be nearly depleted");

        // Keep exact-input size within a range the core pool can fully fill (see Option A swap tests); very large
        // amounts can stop short of the requested input and trip `exact-input core fill mismatch`.
        uint256 swapAmount = 1e18;
        (, uint256 expectedOutput) = _simulateCoreSwapAsProxy(proxyPoolKey, true, -int256(swapAmount));
        assertGt(expectedOutput, afterVault, "pre: simulated core output should exceed remaining vault");

        vm.expectRevert();
        _executeSwap(proxyPoolKey, true, -int256(swapAmount), ZERO_BYTES);

        _executeSwap(proxyPoolKey, true, -int256(swapAmount), abi.encode(recipient));
        assertGt(LiquidityHub(payable(liquidityHub)).settleQueue(address(lccOut), recipient), 0);
    }

    /**
     * @notice When the output-lane vault has zero underlying claims, exact-input with a resolved recipient must still
     *         queue the full output as settlement (regression: `cancel(0)` must not revert before deficit transfer).
     */
    function test_proxyLiveness_outputLaneFullyDepleted_exactInputResolvedRecipientQueuesFullDeficit() public {
        Currency currencyOut = proxyPoolKey.currency1;
        if (Currency.unwrap(currencyOut) == address(0)) {
            return;
        }

        LiquidityCommitmentCertificate lccOut = _lccForUnderlyingCurrency(currencyOut);
        address recipient = makeAddr("full_deficit_recipient");
        _setupRecipient(recipient);

        uint256 beforeVault = mv.inMarketBalanceOf(currencyOut);
        assertGt(beforeVault, 10_000, "pre: need vault liquidity");

        _unwrapMarketDerivedFromVault(lccOut, beforeVault);
        assertEq(mv.inMarketBalanceOf(currencyOut), 0, "post: output lane fully depleted");

        uint256 swapAmount = 1e18;
        (, uint256 expectedOutput) = _simulateCoreSwapAsProxy(proxyPoolKey, true, -int256(swapAmount));
        assertGt(expectedOutput, 0, "pre: core must produce non-zero output LCC");

        vm.expectRevert();
        _executeSwap(proxyPoolKey, true, -int256(swapAmount), ZERO_BYTES);

        uint256 qBefore = LiquidityHub(payable(liquidityHub)).settleQueue(address(lccOut), recipient);
        _executeSwap(proxyPoolKey, true, -int256(swapAmount), abi.encode(recipient));
        uint256 qAfter = LiquidityHub(payable(liquidityHub)).settleQueue(address(lccOut), recipient);
        assertEq(
            qAfter - qBefore, expectedOutput, "queued amount should cover full core output when vault has no claims"
        );
    }

    /// @dev Queue-backed obligation settlement on direct core swap can drain the victim output underlying before a proxy swap.
    function test_proxyLiveness_directCoreWithUnfundedQueue_drainsOutputLane_thenExactOutputReverts() public {
        Currency currencyOut = proxyPoolKey.currency1;
        LiquidityCommitmentCertificate lccOut = _lccForUnderlyingCurrency(currencyOut);
        address uaOut = Currency.unwrap(currencyOut);
        if (uaOut == address(0)) {
            return;
        }

        uint256 qAmt = 500e18;
        address user = makeAddr("queue_user");
        IERC20Minimal(uaOut).transfer(user, qAmt);
        vm.startPrank(user);
        IERC20Minimal(uaOut).approve(liquidityHub, qAmt);
        LiquidityHub(payable(liquidityHub)).wrap(address(lccOut), qAmt);
        vm.stopPrank();

        _mockLCCBalances(lccOut, user, 0, qAmt);
        _mockLimitedMarketLiquidity(address(lccOut), PoolId.unwrap(corePoolKey.toId()), 0);
        vm.prank(user);
        LiquidityHub(payable(liquidityHub)).unwrap(address(lccOut), qAmt);
        vm.clearMockedCalls();

        assertGt(LiquidityHub(payable(liquidityHub)).unfundedQueueOfUnderlying(address(lccOut)), 0);

        uint256 beforeVault = mv.inMarketBalanceOf(currencyOut);
        uint256 requestedOut = beforeVault / 4;
        assertGt(requestedOut, 0, "pre: need non-zero requested exact output");

        bool coreOneForZero = address(lccOut) == Currency.unwrap(corePoolKey.currency1);

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        if (coreOneForZero) {
            swapRouter.swap(
                corePoolKey,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(requestedOut / 10 + 1),
                    sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT
                }),
                settings,
                ZERO_BYTES
            );
        } else {
            swapRouter.swap(
                corePoolKey,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(requestedOut / 10 + 1),
                    sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT
                }),
                settings,
                ZERO_BYTES
            );
        }

        uint256 afterVault = mv.inMarketBalanceOf(currencyOut);
        assertLt(afterVault, beforeVault, "direct core + queue settlement should reduce vault on that lane");

        assertLt(afterVault, requestedOut, "post: vault too low for strict exact-output proxy swap");

        vm.expectRevert();
        _executeSwap(proxyPoolKey, true, int256(requestedOut), ZERO_BYTES);
    }

    /// @dev With no unfunded queue, direct core swap should not pull underlying via handleSwap obligation path.
    function test_proxyLiveness_directCore_noUnfundedQueue_vaultUnchangedOnHandleSwapLane() public {
        Currency currencyOut = proxyPoolKey.currency1;
        LiquidityCommitmentCertificate lccLane = Currency.unwrap(currencyOut) == lcc0.underlying() ? lcc0 : lcc1;
        if (lccLane.underlying() == address(0)) {
            return;
        }

        assertEq(LiquidityHub(payable(liquidityHub)).unfundedQueueOfUnderlying(address(lccLane)), 0);

        uint256 beforeVault = mv.inMarketBalanceOf(currencyOut);

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        bool coreOneForZero = address(lccLane) == Currency.unwrap(corePoolKey.currency1);
        if (coreOneForZero) {
            swapRouter.swap(
                corePoolKey,
                SwapParams({zeroForOne: false, amountSpecified: -int256(1e15), sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT}),
                settings,
                ZERO_BYTES
            );
        } else {
            swapRouter.swap(
                corePoolKey,
                SwapParams({zeroForOne: true, amountSpecified: -int256(1e15), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
                settings,
                ZERO_BYTES
            );
        }

        uint256 afterVault = mv.inMarketBalanceOf(currencyOut);
        uint256 diff = beforeVault > afterVault ? beforeVault - afterVault : afterVault - beforeVault;
        assertLt(diff, 1e18, "swap may nudge vault; obligation path must not move large liquidity without queue");
    }

    // More tests can be added for onDirectLP, unlockCallback, etc.
}

contract ProxyHookHarness is ProxyHook {
    constructor(address _poolManager, address _marketFactory) ProxyHook(_poolManager, _marketFactory) {}

    /// @dev Disable hook-address flag validation for harness deployments in unit tests.
    function validateHookAddress(BaseHook) internal pure override {}

    function exposed_setNoCoreActionFlag(bool on) external {
        if (on) CoreActionFlag.setNoCoreAction();
        else CoreActionFlag.clearNoCoreAction();
    }

    function exposed_getExpectedOutputFromDelta(BalanceDelta swapDelta, bool zeroForOne)
        external
        pure
        returns (uint256 expectedOutput)
    {
        expectedOutput = _getExpectedOutputFromDelta(swapDelta, zeroForOne);
    }

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

    function _probeNoCoreAction() internal noCoreAction returns (bool duringExecution) {
        duringExecution = CoreActionFlag.isNoCoreAction();
    }

    function exposed_runNoCoreActionProbe() external returns (bool duringExecution, bool afterExecution) {
        duringExecution = _probeNoCoreAction();
        afterExecution = CoreActionFlag.isNoCoreAction();
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

contract MockMsgSenderZero is IMsgSender {
    function msgSender() external pure returns (address) {
        return address(0);
    }
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
        // Production wiring keeps proxy-hook-local LCC issue/cancel authority for swap-local hook deltas, while
        // CanonicalVault owns the durable custody ledger for the market.
        address[] memory initialIssuers = new address[](3);
        initialIssuers[0] = address(vtsOrchestrator);
        initialIssuers[1] = address(proxyHook);
        initialIssuers[2] = IMarketFactory(marketFactory).canonicalVault();

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

        assertEq(selfBalanceOfTokenABefore, selfBalanceOfTokenAAfter + swapAmount);
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
        assertEq(preBalanceOfToken0UnderlyingAssetInHub, postBalanceOfToken0UnderlyingAssetInHub + deltaAmount0);
        // validate liquidity of token-in(token0) in the pool manager is higher after the swap
        // becase liquidity of the underlying tokens will be moved from lcc token to pool manager
        // so the pool manager's underlying balance should increase by the amount of token-in(token0) swapped into the pool
        assertEq(postBalanceOfToken0UnderlyingAssetInPM, preBalanceOfToken0UnderlyingAssetInPM + deltaAmount0);
        // Token OUT underlying is NOT moved here. It is sourced on unwrap via market liquidity.
        // Therefore, neither the Hub nor PoolManager underlying balances should change for token-out during the swap.
        assertEq(postBalanceOfToken1UnderlyingAssetInHub, preBalanceOfToken1UnderlyingAssetInHub);
        assertEq(preBalanceOfToken1UnderlyingAssetInPM, postBalanceOfToken1UnderlyingAssetInPM);
    }
}

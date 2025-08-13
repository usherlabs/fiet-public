// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
// Sets up the market and the core and proxy pools for testing

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

import {CurrencySortHelper} from "../../script/libraries/CurrencySortHelper.sol";
import {ProxyHook} from "../../src/ProxyHook.sol";
import {CoreHook} from "../../src/CoreHook.sol";
import {LiquidityCommitmentCertificate} from "../../src/LCC.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {console} from "forge-std/console.sol";
import {HookFlags} from "../../src/libraries/HookFlags.sol";

abstract contract MarketTestBase is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    // Provide initial liquidity to core pool
    uint256 initialLiquidity = 10000e18;

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

    function ApproveLCCForMarketUse(LiquidityCommitmentCertificate token) internal returns (Currency currency) {
        address underlyingAsset = token.underlyingAsset();
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

    function deployAndApproveLCC(address underlyingAsset, address hookAddr) internal returns (Currency currency) {
        address[] memory issuers = new address[](2);
        issuers[0] = hookAddr;
        issuers[1] = address(this);

        LiquidityCommitmentCertificate token =
            new LiquidityCommitmentCertificate(underlyingAsset, issuers, marketFactory);

        ApproveLCCForMarketUse(token);

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

    function _setupMarket() internal {
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
        // LCC makes a call onTransfer to check if transfer is within bounds
        // set it to true i.e Market Tracking would be disabled since we do not track addresses that are within bounds
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector), abi.encode(true));
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

        LiquidityCommitmentCertificate lcc0 = LiquidityCommitmentCertificate(Currency.unwrap(_currency2));
        LiquidityCommitmentCertificate lcc1 = LiquidityCommitmentCertificate(Currency.unwrap(_currency3));

        _currency0.transfer(address(this), initialLiquidity);
        _currency1.transfer(address(this), initialLiquidity);

        IERC20Minimal(lcc0.underlyingAsset()).approve(address(lcc0), initialLiquidity);
        lcc0.wrap(initialLiquidity);

        IERC20Minimal(lcc1.underlyingAsset()).approve(address(lcc1), initialLiquidity);
        lcc1.wrap(initialLiquidity);

        // Mock factory calls made by LCC contract when it is transferred to a non-protocol bound address and tracking is activated
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.coreToProxy.selector), abi.encode(proxyPoolKey.toId())
        );
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.corePoolToCurrencyPair.selector),
            abi.encode(Currency.unwrap(_currency2), Currency.unwrap(_currency3))
        );

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
}

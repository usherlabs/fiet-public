// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySortHelper} from "../script/CurrencySortHelper.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {IHookCommon} from "../src/interfaces/IHookCommon.sol";

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
    address coreHookAddr;

    function deployAndApproveLCC(
        address underlyingAsset,
        address hookAddr
    ) internal returns (Currency currency) {
        address[] memory issuers = new address[](2);
        issuers[0] = hookAddr;
        issuers[1] = address(this);

        LiquidityCommitmentCertificate token = new LiquidityCommitmentCertificate(
                underlyingAsset,
                issuers,
                marketFactory,
                address(0) // poolManager
            );

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
        }

        IERC20Minimal(underlyingAsset).approve(
            address(token),
            Constants.MAX_UINT256
        );
        return Currency.wrap(address(token));
    }

    function deployCurrencies(address hookAddr) internal {
        Currency _currencyA = deployMintAndApproveCurrency();
        Currency _currencyB = deployMintAndApproveCurrency();

        Currency _currencyC = deployAndApproveLCC(
            Currency.unwrap(_currencyA),
            hookAddr
        );
        Currency _currencyD = deployAndApproveLCC(
            Currency.unwrap(_currencyB),
            hookAddr
        );

        (_currency0, _currency1) = CurrencySortHelper.sortAddresses(
            Currency.unwrap(_currencyA),
            Currency.unwrap(_currencyB)
        );

        (_currency2, _currency3) = CurrencySortHelper.sortAddresses(
            Currency.unwrap(_currencyC),
            Currency.unwrap(_currencyD)
        );
    }

    function deployCorePool() internal {
        (corePoolKey, ) = initPool(
            _currency2,
            _currency3,
            IHooks(address(0)),
            3000,
            SQRT_PRICE_1_1
        );
    }

    function deployProxyPool(address hookAddress) internal {
        deployCodeTo(
            "ProxyHook.sol",
            abi.encode(manager, marketFactory),
            hookAddress
        );
        hook = ProxyHook(hookAddress);

        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.getCoreHook.selector),
            abi.encode(coreHookAddr)
        );

        vm.prank(marketFactory);
        hook.activate();

        vm.prank(marketFactory);
        hook.setCorePoolKey(corePoolKey.toId(), corePoolKey);

        vm.prank(marketFactory);
        (proxyPoolKey, ) = initPool(
            _currency0,
            _currency1,
            IHooks(hook),
            3000,
            SQRT_PRICE_1_1
        );
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        marketFactory = makeAddr("marketFactory");
        coreHookAddr = makeAddr("coreHook");

        address hookAddress = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            )
        );

        deployCurrencies(hookAddress);
        deployCorePool();
        deployProxyPool(hookAddress);

        // Provide initial liquidity to core pool
        uint256 initialLiquidity = 10000e18;

        LiquidityCommitmentCertificate lcc0 = LiquidityCommitmentCertificate(
            Currency.unwrap(_currency2)
        );
        LiquidityCommitmentCertificate lcc1 = LiquidityCommitmentCertificate(
            Currency.unwrap(_currency3)
        );

        _currency0.transfer(address(this), initialLiquidity);
        _currency1.transfer(address(this), initialLiquidity);

        IERC20Minimal(lcc0.underlyingAsset()).approve(
            address(lcc0),
            initialLiquidity
        );
        lcc0.wrap(initialLiquidity);

        IERC20Minimal(lcc1.underlyingAsset()).approve(
            address(lcc1),
            initialLiquidity
        );
        lcc1.wrap(initialLiquidity);

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
        vm.expectRevert(ProxyHook.AddLiquidityThroughHookNotAllowed.selector);
        modifyLiquidityRouter.modifyLiquidity(
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

        uint256 swapAmount = 100;
        swapRouter.swap(
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

    // Additional tests

    function test_beforeInitialize_revertIfNotFactory() public {
        PoolKey memory testKey = PoolKey({
            currency0: _currency0,
            currency1: _currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.expectRevert(ProxyHook.InvalidInitialiser.selector);
        vm.prank(address(1));
        manager.initialize(testKey, SQRT_PRICE_1_1);
    }

    // More tests can be added for onDirectLP, unlockCallback, etc.
}

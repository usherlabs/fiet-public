// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookFlags} from "../src/libraries/HookFlags.sol";
import {MarketTestBase} from "./modules/MarketTestBase.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {IMarketVault} from "../src/interfaces/IMarketVault.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {MarketMakerTestBase} from "./modules/MMTestBase.sol";

import {CurrencySortHelper} from "../script/libraries/CurrencySortHelper.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MarketMaker} from "../src/libraries/MarketMaker.sol";
import {MMPositionManager} from "../src/MMPositionManager.sol";
import {MarketVTSConfiguration} from "../src/types/VTS.sol";
import {IVTSManager} from "../src/interfaces/IVTSManager.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {IOracleHelper} from "../src/interfaces/IOracleHelper.sol";
import {PositionMeta} from "../src/types/Position.sol";

contract NativeETHMarket is MarketTestBase, MarketMakerTestBase {
    using SafeCast for *;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using MarketMaker for MarketMaker.State;

    MMPositionManager internal positionManager;
    MarketVTSConfiguration internal marketVTSConfiguration;

    ILCC internal lcc0;
    ILCC internal lcc1;

    ILCC internal lccNativeETH;
    ILCC internal lccERC20;

    address guarantor = makeAddr("guarantor");
    uint256 guarantorInitialBalance = 10000e18;

    function _deployCurrencies(address hookAddr) internal override {
        Currency _currencyA = Currency.wrap(address(0));
        Currency _currencyB = deployMintAndApproveCurrency();

        Currency _currencyC = deployAndApproveLCC(Currency.unwrap(_currencyA), hookAddr);
        Currency _currencyD = deployAndApproveLCC(Currency.unwrap(_currencyB), hookAddr);

        (_currency0, _currency1) =
            CurrencySortHelper.sortAddresses(Currency.unwrap(_currencyA), Currency.unwrap(_currencyB));

        (_currency2, _currency3) =
            CurrencySortHelper.sortAddresses(Currency.unwrap(_currencyC), Currency.unwrap(_currencyD));
    }

    function setUpNativeMarket() public {
        _deployFreshManagerAndRouters();
        _deployHooks();
        _deployCurrencies(address(proxyHook));
        _deployCorePool(SQRT_PRICE_1_1);
        _deployProxyPool(SQRT_PRICE_1_1);

        // Set core pool key against the proxy pool key id.
        vm.prank(marketFactory);
        proxyHook.setCorePoolKey(corePoolKey);

        // wrap enough lcc tokens by providing the underlying asset to the lcc contract as 'collateral'
        lcc0 = LiquidityCommitmentCertificate(Currency.unwrap(_currency2));
        lcc1 = LiquidityCommitmentCertificate(Currency.unwrap(_currency3));

        // get which lcc token represents lcc-eth
        (lccNativeETH, lccERC20) = lcc0.underlying() == address(0) ? (lcc0, lcc1) : (lcc1, lcc0);

        IERC20Minimal(lccERC20.underlying()).approve(address(lccERC20), initialLiquidity);
        lccERC20.wrap(initialLiquidity);

        lccNativeETH.wrap{value: initialLiquidity}(initialLiquidity);

        _mockFactoryCalls();

        // add liquidity to the core pool
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({
                tickLower: -60, tickUpper: 60, liquidityDelta: int256(initialLiquidity), salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function setUp() public {
        setUpNativeMarket();
        _setUpMM();

        // set up mocks for the mmposition manager
        console.log("setUP() mmPositionManager", address(mmPositionManager));
        positionManager = MMPositionManager(mmPositionManager);
        lcc0 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency2)));
        lcc1 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency3)));

        marketVTSConfiguration = IVTSManager(coreHookAddress).getMarketVTSConfiguration(corePoolKey.toId());

        // approve the lccs to the mmPositionManager to be able to route tokens to the pool manager
        // lcc0.approve(address(mmPositionManager), Constants.MAX_UINT256);
        // lcc1.approve(address(mmPositionManager), Constants.MAX_UINT256);
        // Mock the proxyHookToCurrencyPair function in order to make this caller appear to be an issuer
        // when deploying the factory the mmposiiton manager will be provided and thus whitelsited
        // but since we are mocking the factory, we need to mock a way to return the mmposition manager as an issuer
        address[2] memory mockCurrencies = [address(lcc0.underlying()), address(lcc1.underlying())];
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.proxyHookToCurrencyPair.selector, address(mmPositionManager)),
            abi.encode(mockCurrencies)
        );
        // mock the factory to return the right core hook
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.coreToProxy.selector), abi.encode(proxyPoolKey.toId())
        );
        // mock the factory to return the right proxy hook
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.proxyToHook.selector), abi.encode(proxyHook));

        // mock the signal manager to return the right total usd value
        vm.mockCall(
            address(oracleHelper), abi.encodeWithSelector(IOracleHelper.getLCCMarketUSDValue.selector), abi.encode(1)
        );
        vm.mockCall(
            address(oracleHelper), abi.encodeWithSelector(IOracleHelper.getTotalUsdValue.selector), abi.encode(2)
        );

        console.log("lcc0", address(lcc0));
        console.log("lcc1", address(lcc1));
        console.log("lcc0 underlying asset", lcc0.underlying());
        console.log("lcc1 underlying asset", lcc1.underlying());
    }

    function test_canAddLiquidityToPoolWithNativeAsUnderlyingAsset() public {
        // add liquidity to the core pool
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({
                tickLower: -60, tickUpper: 60, liquidityDelta: int256(initialLiquidity), salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_swapWithNativeAsUnderlyingAsset_zeroForOne() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();

        uint256 swapAmount = 1e18;
        BalanceDelta delta = swapRouter.swap{
            value: swapAmount
        }(
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

    function test_swapWithNativeAsUnderlyingAsset_oneForZero() public {
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

    function test_swapWithNativeAsUnderlyingAsset_CanCommitPosition_withRefund() public {
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        bytes memory liquiditySignal = abi.encode(liquiditySignal);

        // Get the amount of LCC tokens that will be minted
        (uint256 token0AmountMinted, uint256 token1AmountMinted) =
            LiquidityUtils.calculateTokenAmountsFromPositionParams(manager, corePoolKey, liquidityParams);

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) =
            LiquidityUtils.getBaseSettlementAmounts(liquidityParams, marketVTSConfiguration);

        // Approve
        ERC20(lccERC20.underlying()).approve(address(mmPositionManager), underlyingLiquidityFraction0);
        // ERC20(lcc1.underlying()).approve(address(mmPositionManager), underlyingLiquidityFraction1);

        uint256 pmLcc0BalanceBefore = ERC20(address(lcc0)).balanceOf(address(manager));
        uint256 pmLcc1BalanceBefore = ERC20(address(lcc1)).balanceOf(address(manager));

        uint256 proxyCurrency0BalanceBefore = manager.balanceOf(address(proxyHook), proxyPoolKey.currency0.toId());
        uint256 proxyCurrency1BalanceBefore = manager.balanceOf(address(proxyHook), proxyPoolKey.currency1.toId());

        uint256 lcc0UnderlyingAssetBalanceBefore = Currency.wrap(lcc0.underlying()).balanceOfSelf();
        uint256 lcc1UnderlyingAssetBalanceBefore = Currency.wrap(lcc1.underlying()).balanceOfSelf();

        // get the amount of ETH to send over
        // eth is zero address, so it will always be token0
        uint256 ethAmount = underlyingLiquidityFraction0;
        console.log("ethAmount", ethAmount);
        console.log("underlyingLiquidityFraction0", underlyingLiquidityFraction0);
        console.log("underlyingLiquidityFraction1", underlyingLiquidityFraction1);
        console.log("self eth balance", address(this).balance);
        // send the entire balance of ETH to the position manager
        // we should get a refund of the left over ETH
        positionManager.commit{
            value: address(this).balance
        }(
            corePoolKey,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            liquidityParams.liquidityDelta,
            liquiditySignal
        );
        // First commit mints the first NFT
        uint256 tokenId = 1;
        PositionMeta memory m = positionManager.getPosition(tokenId, 0);

        uint256 pmLcc0BalanceAfter = ERC20(address(lcc0)).balanceOf(address(manager));
        uint256 pmLcc1BalanceAfter = ERC20(address(lcc1)).balanceOf(address(manager));

        // get user balances of underlying assets

        uint256 lcc0UnderlyingAssetBalanceAfter = Currency.wrap(lcc0.underlying()).balanceOfSelf();
        uint256 lcc1UnderlyingAssetBalanceAfter = Currency.wrap(lcc1.underlying()).balanceOfSelf();

        console.log("lcc0UnderlyingAssetBalanceBefore", lcc0UnderlyingAssetBalanceBefore);
        console.log("lcc0UnderlyingAssetBalanceAfter", lcc0UnderlyingAssetBalanceAfter);
        console.log("lcc1UnderlyingAssetBalanceBefore", lcc1UnderlyingAssetBalanceBefore);
        console.log("lcc1UnderlyingAssetBalanceAfter", lcc1UnderlyingAssetBalanceAfter);

        // validate lcc liquidity has been taken from user's balance
        assertEq(lcc0UnderlyingAssetBalanceAfter, lcc0UnderlyingAssetBalanceBefore - underlyingLiquidityFraction0);
        assertEq(lcc1UnderlyingAssetBalanceAfter, lcc1UnderlyingAssetBalanceBefore - underlyingLiquidityFraction1);

        // validate lcc liquidity has been added to the core pool
        assertEq(pmLcc0BalanceAfter, pmLcc0BalanceBefore + token0AmountMinted);
        assertEq(pmLcc1BalanceAfter, pmLcc1BalanceBefore + token1AmountMinted);

        // validate underlying tokens have been transferred to proxy pool
        // and proxy hook has claim tokens
        uint256 proxyCurrency0BalanceAfter = manager.balanceOf(address(proxyHook), proxyPoolKey.currency0.toId());
        uint256 proxyCurrency1BalanceAfter = manager.balanceOf(address(proxyHook), proxyPoolKey.currency1.toId());

        assertEq(proxyCurrency0BalanceAfter, proxyCurrency0BalanceBefore + underlyingLiquidityFraction0);
        assertEq(proxyCurrency1BalanceAfter, proxyCurrency1BalanceBefore + underlyingLiquidityFraction1);

        assertEq(PoolId.unwrap(m.poolId), PoolId.unwrap(corePoolKey.toId()));
        assertEq(m.tickLower, liquidityParams.tickLower);
        assertEq(m.tickUpper, liquidityParams.tickUpper);
        assertEq(m.liquidity, liquidityParams.liquidityDelta);
        // Position owner is the manager contract
        assertEq(m.owner, address(mmPositionManager));
        assertEq(m.isActive, true);
    }
}

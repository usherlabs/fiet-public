// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MarketTestBase} from "./base/MarketTestBase.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {MarketMakerTestBase} from "./base/MMTestBase.sol";

import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MarketMaker} from "../src/libraries/MarketMaker.sol";
import {IMMPositionManager} from "../src/interfaces/IMMPositionManager.sol";
import {ICanonicalVault} from "../src/interfaces/ICanonicalVault.sol";
import {MarketVTSConfiguration} from "../src/types/VTS.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {IOracleHelper} from "../src/interfaces/IOracleHelper.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {CurrencyTransfer} from "../src/libraries/CurrencyTransfer.sol";
import {Position, PositionId} from "../src/types/Position.sol";
import {MMActionAdapter as MMA} from "./utils/MMActionAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LiquidityHub} from "../src/LiquidityHub.sol";

contract NativeQueueNonPayableRecipient {}

contract NativeQueueCounterfactualDeployer {
    function predict(bytes32 salt) external view returns (address predicted) {
        bytes32 bytecodeHash = keccak256(type(NativeQueueNonPayableRecipient).creationCode);
        bytes32 digest = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash));
        predicted = address(uint160(uint256(digest)));
    }

    function deploy(bytes32 salt) external returns (address deployed) {
        deployed = address(new NativeQueueNonPayableRecipient{salt: salt}());
    }
}

contract NativeETHMarket is MarketTestBase, MarketMakerTestBase {
    using SafeCast for *;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using CurrencyTransfer for Currency;
    using MarketMaker for MarketMaker.State;
    using StateLibrary for IPoolManager;

    IMMPositionManager internal positionManager;
    MarketVTSConfiguration internal marketVTSConfiguration;

    ILCC internal lcc0;
    ILCC internal lcc1;

    address guarantor = makeAddr("guarantor");
    uint256 guarantorInitialBalance = 10000e18;

    // ETH price in USD (scaled by 1e18) - approximately $3200
    uint256 constant ETH_PRICE_USD = 3200e18;
    // ERC20 token price in USD (scaled by 1e18) - assuming stablecoin or similar at $1
    uint256 constant TOKEN_PRICE_USD = 1e18;

    // Override the _deployCurrencyA function to return a currency with native ETH as underlying
    function _deployCurrencyA() internal pure override returns (Currency currency) {
        return Currency.wrap(address(0));
    }

    function setUp() public {
        // Fund this test contract with ETH for native operations
        // Need at least initialLiquidity (10000e18) + extra for test operations
        vm.deal(address(this), 20000 ether);

        _setupMarket();
        _setUpMM();

        // set up mocks for the mmposition manager
        positionManager = IMMPositionManager(payable(mmPositionManager));

        // Determine which LCC has native ETH as underlying by checking the underlying assets
        // _currency2 and _currency3 are the sorted LCC token addresses
        ILCC _lcc2 = ILCC(payable(Currency.unwrap(_currency2)));
        ILCC _lcc3 = ILCC(payable(Currency.unwrap(_currency3)));

        // Assign lcc0 to native ETH underlying and lcc1 to ERC20 underlying for clarity
        if (_lcc2.underlying() == address(0)) {
            lcc0 = _lcc2;
            lcc1 = _lcc3;
        } else {
            lcc0 = _lcc3;
            lcc1 = _lcc2;
        }

        marketVTSConfiguration = vtsOrchestrator.getMarketVTSConfiguration(corePoolKey.toId());

        // Mock the proxyHookToCurrencyPair function in order to make this caller appear to be an issuer
        // when deploying the factory the mmposiiton manager will be provided and thus whitelisted
        // but since we are mocking the factory, we need to mock a way to return the mmposition manager as an issuer
        address[2] memory mockCurrencies = [lcc0.underlying(), lcc1.underlying()];
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.proxyHookToCurrencyPair.selector, address(proxyHook)),
            abi.encode(mockCurrencies)
        );
        // mock the factory to return the right core hook
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.coreToProxy.selector), abi.encode(proxyPoolKey.toId())
        );
        // mock the factory to return the right proxy hook
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.proxyToHook.selector), abi.encode(proxyHook));

        // Mock the oracle helper to return realistic ETH price (~$3200) and token price (~$1)
        // The order depends on which LCC is currency0 vs currency1 in the core pool
        address corePoolCurrency0Underlying = ILCC(payable(Currency.unwrap(corePoolKey.currency0))).underlying();

        // Set prices based on which underlying is native ETH
        uint256 price0 = corePoolCurrency0Underlying == address(0) ? ETH_PRICE_USD : TOKEN_PRICE_USD;
        uint256 price1 = corePoolCurrency0Underlying == address(0) ? TOKEN_PRICE_USD : ETH_PRICE_USD;

        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector),
            abi.encode(price0, price1)
        );
        // Mock getTotalValue to return a reasonable value scaled for the prices
        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getTotalValue.selector),
            abi.encode(ETH_PRICE_USD)
        );
        {
            string[] memory tickers = new string[](2);
            tickers[0] = "BTC";
            tickers[1] = "USDT";
            uint256[] memory amounts = new uint256[](2);
            amounts[0] = 1e20;
            amounts[1] = 5e18;
            vm.mockCall(
                address(oracleHelper),
                abi.encodeWithSelector(IOracleHelper.getTotalValue.selector, tickers, amounts),
                abi.encode(ETH_PRICE_USD)
            );
        }
        address mmLocker = liquiditySignal.mmState.advancer;
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, mmLocker), abi.encode(true));
        vm.deal(mmLocker, 100_000 ether);

        _wireTestQueueCustodianFor(address(mmPositionManager), liquiditySignal.mmState.advancer);
        _wireAllUtilityTestQueueCustodians(address(mmPositionManager));

        console.log("=== Native ETH Market Setup ===");
        console.log("lcc0 (native ETH underlying)", address(lcc0));
        console.log("lcc1 (ERC20 underlying)", address(lcc1));
        console.log("lcc0 underlying asset", lcc0.underlying());
        console.log("lcc1 underlying asset", lcc1.underlying());
        console.log("ETH price (USD)", ETH_PRICE_USD);
        console.log("Token price (USD)", TOKEN_PRICE_USD);
    }

    function test_canAddLiquidityToPoolWithNativeAsunderlying() public {
        // add liquidity to the core pool
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({
                tickLower: -60, tickUpper: 60, liquidityDelta: int256(initialLiquidity), salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_swapWithNativeAsUnderlyingAsset_zeroForOneOnProxyPool() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();

        (uint160 sqrtBefore, int24 tickBefore,,) = manager.getSlot0(proxyPoolKey.toId());

        uint256 swapAmount = 1e10;
        BalanceDelta delta = swapRouter.swap{
            value: swapAmount
        }(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            settings,
            ZERO_BYTES
        );

        (uint160 sqrtAfter, int24 tickAfter,,) = manager.getSlot0(proxyPoolKey.toId());
        assertEq(sqrtAfter, sqrtBefore, "proxy slot0 sqrtPrice should not change");
        assertEq(tickAfter, tickBefore, "proxy slot0 tick should not change");

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

    function test_swapWithNativeAsUnderlyingAsset_oneForZeroOnProxyPool() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();
        // proxy balance of tokens
        uint256 balanceOfTokenA = mv.inMarketBalanceOf(proxyPoolKey.currency0);
        uint256 balanceOfTokenB = mv.inMarketBalanceOf(proxyPoolKey.currency1);
        console.log("balanceOfTokenA", balanceOfTokenA);
        console.log("balanceOfTokenB", balanceOfTokenB);

        (uint160 sqrtBefore, int24 tickBefore,,) = manager.getSlot0(proxyPoolKey.toId());

        uint256 swapAmount = 100;
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT
            }),
            settings,
            ZERO_BYTES
        );

        (uint160 sqrtAfter, int24 tickAfter,,) = manager.getSlot0(proxyPoolKey.toId());
        assertEq(sqrtAfter, sqrtBefore, "proxy slot0 sqrtPrice should not change");
        assertEq(tickAfter, tickBefore, "proxy slot0 tick should not change");

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey.currency1.balanceOfSelf();

        assertEq(selfBalanceOfTokenBBefore - selfBalanceOfTokenBAfter, swapAmount);
        assertGt(selfBalanceOfTokenAAfter, selfBalanceOfTokenABefore);
    }

    function test_swapWithNativeAsUnderlyingAsset_exactOutputOnProxyPool_revertsWhenInsufficientUnderlying() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // For zeroForOne exact-output swaps, available output liquidity is tracked on CanonicalVault's market reserve,
        // not on the proxy hook's local PoolManager claims.
        address canonical = mv.canonicalVault();
        bytes32 marketId = mv.marketId();
        uint256 available = mv.inMarketBalanceOf(proxyPoolKey.currency1);
        vm.prank(address(proxyHook));
        ICanonicalVault(canonical).decreaseLiquidityReserve(marketId, proxyPoolKey.currency1, available);

        bytes memory expectedReason =
            abi.encodeWithSelector(Errors.InsufficientLiquidity.selector, uint256(1e10), uint256(0));

        try swapRouter.swap{
            value: 1 ether
        }(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(1e10), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            settings,
            ZERO_BYTES
        ) {
            fail();
        } catch (bytes memory data) {
            _assertWrappedReason(data, expectedReason);
        }
    }

    function test_canonicalVaultDeficit_nativeRecipientFallsBackToWethAfterCounterfactualDeployment() public {
        NativeQueueCounterfactualDeployer deployer = new NativeQueueCounterfactualDeployer();
        bytes32 salt = keccak256("native-canonical-deficit-counterfactual");
        address recipient = deployer.predict(salt);

        address canonical = mv.canonicalVault();
        bytes32 marketId = mv.marketId();
        uint256 amount = 7e18;

        vm.prank(marketFactory);
        LiquidityHub(payable(liquidityHub)).setBoundLevel(canonical, 1);

        vm.prank(address(proxyHook));
        LiquidityHub(payable(liquidityHub)).issue(address(lcc0), canonical, amount);

        uint256 available = mv.inMarketBalanceOf(proxyPoolKey.currency0);
        if (available > 0) {
            vm.prank(address(proxyHook));
            ICanonicalVault(canonical).decreaseLiquidityReserve(marketId, proxyPoolKey.currency0, available);
        }

        vm.prank(address(proxyHook));
        ICanonicalVault(canonical).cancelLCCWithDeficit(marketId, address(lcc0), amount, recipient);
        assertEq(LiquidityHub(payable(liquidityHub)).settleQueue(address(lcc0), recipient), amount);

        uint256 reserveBefore = LiquidityHub(payable(liquidityHub)).reserveOfUnderlying(address(lcc0));
        uint256 neededHubBalance = reserveBefore + amount;
        if (address(liquidityHub).balance < neededHubBalance) {
            vm.deal(liquidityHub, neededHubBalance);
        }
        vm.prank(address(proxyHook));
        LiquidityHub(payable(liquidityHub)).confirmTake(address(lcc0), amount, false);

        deployer.deploy(salt);
        assertGt(recipient.code.length, 0, "recipient should now be non-payable contract");

        address weth = address(LiquidityHub(payable(liquidityHub)).weth9());
        LiquidityHub(payable(liquidityHub)).processSettlementFor(address(lcc0), recipient, amount);

        assertEq(LiquidityHub(payable(liquidityHub)).settleQueue(address(lcc0), recipient), 0);
        assertEq(IERC20(weth).balanceOf(recipient), amount);
        assertEq(recipient.balance, 0);
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

    function test_swapWithNativeAsUnderlyingAsset_zeroForOneOnCore() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // get balances of underlying token of the pool manager and lcc contracts
        // get the underlying asset of the lcc token A
        address underlyingAssetLCC0 = ILCC(payable(Currency.unwrap(corePoolKey.currency0))).underlying();
        address underlyingAssetLCC1 = ILCC(payable(Currency.unwrap(corePoolKey.currency1))).underlying();

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
        assertEq(preBalanceOfToken0UnderlyingAssetInHub - postBalanceOfToken0UnderlyingAssetInHub, deltaAmount0);
        // validate liquidity of token-in(token0) in the pool manager is higher after the swap
        // becase liquidity of the underlying tokens will be moved from lcc token to pool manager
        // so the pool manager's underlying balance should increase by the amount of token-in(token0) swapped into the pool
        assertEq(postBalanceOfToken0UnderlyingAssetInPM - preBalanceOfToken0UnderlyingAssetInPM, deltaAmount0);
        // token-out is delivered as LCC (a claim), not as underlying.
        // Underlying token1 therefore does NOT move between LiquidityHub and PoolManager in this pathway.
        assertEq(postBalanceOfToken1UnderlyingAssetInHub - preBalanceOfToken1UnderlyingAssetInHub, 0);
        assertEq(preBalanceOfToken1UnderlyingAssetInPM - postBalanceOfToken1UnderlyingAssetInPM, 0);
    }

    function test_swapWithNativeAsUnderlyingAsset_oneForZeroOnCore() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // get balances of underlying token of the pool manager and lcc contracts
        // get the underlying asset of the lcc token A
        address underlyingAssetLCC0 = ILCC(payable(Currency.unwrap(corePoolKey.currency0))).underlying();
        address underlyingAssetLCC1 = ILCC(payable(Currency.unwrap(corePoolKey.currency1))).underlying();
        console.log("underlyingAsset-LCC0", underlyingAssetLCC0);
        console.log("underlyingAsset-LCC1", underlyingAssetLCC1);

        uint256 preBalanceOfToken0UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC0).balanceOf(address(manager));
        uint256 preBalanceOfToken1UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC1).balanceOf(address(manager));

        uint256 preBalanceOfToken0UnderlyingAssetInHub = Currency.wrap(underlyingAssetLCC0).balanceOf(liquidityHub);
        uint256 preBalanceOfToken1UnderlyingAssetInHub = Currency.wrap(underlyingAssetLCC1).balanceOf(liquidityHub);

        int256 swapAmount = 100;
        BalanceDelta delta;
        try swapRouter.swap(
            corePoolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(swapAmount), sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT}),
            settings,
            ZERO_BYTES
        ) returns (
            BalanceDelta d
        ) {
            delta = d;
        } catch (bytes memory err) {
            assembly {
                revert(add(err, 0x20), mload(err))
            }
        }

        uint256 deltaAmount1 = LiquidityUtils.safeInt128ToUint256(delta.amount1());

        console.log("swap delta 0:", delta.amount0());
        console.log("swap delta 1:", delta.amount1());

        uint256 postBalanceOfToken0UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC0).balanceOf(address(manager));
        uint256 postBalanceOfToken1UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC1).balanceOf(address(manager));

        uint256 postBalanceOfToken0UnderlyingAssetInHub = Currency.wrap(underlyingAssetLCC0).balanceOf(liquidityHub);
        uint256 postBalanceOfToken1UnderlyingAssetInHub = Currency.wrap(underlyingAssetLCC1).balanceOf(liquidityHub);

        console.log("postBalanceOfToken0UnderlyingAssetInPM", postBalanceOfToken0UnderlyingAssetInPM);
        console.log("postBalanceOfToken1UnderlyingAssetInPM", postBalanceOfToken1UnderlyingAssetInPM);
        console.log("postBalanceOfToken0UnderlyingAssetInHub", postBalanceOfToken0UnderlyingAssetInHub);
        console.log("postBalanceOfToken1UnderlyingAssetInHub", postBalanceOfToken1UnderlyingAssetInHub);

        // token-out is delivered as LCC (a claim), not as underlying.
        // Underlying token0 therefore does NOT move between LiquidityHub and PoolManager in this pathway.
        assertEq(postBalanceOfToken0UnderlyingAssetInHub - preBalanceOfToken0UnderlyingAssetInHub, 0);
        assertEq(preBalanceOfToken0UnderlyingAssetInPM - postBalanceOfToken0UnderlyingAssetInPM, 0);
        // validate liquidity of token-in(token1) in the lcc token is lower after the swap
        // because liquidity will move 'from lcc' tokens 'to pool-manager' as it enters the pool during a one for zero swap
        assertEq(preBalanceOfToken1UnderlyingAssetInHub - postBalanceOfToken1UnderlyingAssetInHub, deltaAmount1);
        // validate liquidity of token-in(token1) in the pool manager is higher after the swap
        // because liquidity of the underlying tokens will be moved from LCC token to pool-manager
        // so the pool manager's underlying balance should increase by the amount of token-in(token1) swapped into of the pool
        assertEq(postBalanceOfToken1UnderlyingAssetInPM - preBalanceOfToken1UnderlyingAssetInPM, deltaAmount1);
    }

    /// @dev Balance snapshot struct to reduce stack depth
    struct BalanceSnapshot {
        uint256 lockerEth;
        uint256 pmLcc0;
        uint256 pmLcc1;
        uint256 canonicalCurrency0;
        uint256 canonicalCurrency1;
        uint256 lcc1UnderlyingLocker;
    }

    function _assertPmAndCanonicalAfterNativeCommit(
        int24 tickLower,
        int24 tickUpper,
        uint256 liqDeltaU,
        BalanceSnapshot memory balancesBefore,
        BalanceSnapshot memory balancesAfter,
        uint256 requiredSettlementAmount0,
        uint256 requiredSettlementAmount1
    ) internal view {
        (uint160 sqrtPriceX96, int24 currentTick,,) = manager.getSlot0(corePoolKey.toId());
        (uint256 token0EffectiveLiquidity, uint256 token1EffectiveLiquidity) = LiquidityUtils.calculateEffectiveTokenAmounts(
            sqrtPriceX96, currentTick, tickLower, tickUpper, int256(liqDeltaU)
        );

        assertEq(
            balancesAfter.lcc1UnderlyingLocker,
            balancesBefore.lcc1UnderlyingLocker - requiredSettlementAmount1,
            "Token1 settlement amount mismatch"
        );

        assertEq(balancesAfter.pmLcc0, balancesBefore.pmLcc0 + token0EffectiveLiquidity, "LCC0 balance mismatch");
        assertEq(balancesAfter.pmLcc1, balancesBefore.pmLcc1 + token1EffectiveLiquidity, "LCC1 balance mismatch");

        assertEq(
            balancesAfter.canonicalCurrency0,
            balancesBefore.canonicalCurrency0 + requiredSettlementAmount0,
            "Canonical currency0 balance mismatch"
        );
        assertEq(
            balancesAfter.canonicalCurrency1,
            balancesBefore.canonicalCurrency1 + requiredSettlementAmount1,
            "Canonical currency1 balance mismatch"
        );
    }

    /// @notice Tests creating a position in a native ETH market via MMPM with excess msg.value refund
    /// @dev Verifies that when sending more ETH than required for the position, the excess is refunded
    function test_swapWithNativeAsUnderlyingAsset_CanCommitPosition_withRefund() public {
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});
        int24 tickLower = liquidityParams.tickLower;
        int24 tickUpper = liquidityParams.tickUpper;
        uint256 liqDeltaU = uint256(liquidityParams.liquidityDelta);

        bytes memory signalBytes = abi.encode(liquiditySignal);

        // Calculate and store settlement amounts
        uint256 requiredSettlementAmount0;
        uint256 requiredSettlementAmount1;
        {
            (requiredSettlementAmount0, requiredSettlementAmount1) =
                _calculateSettlementAmounts(liquidityParams, marketVTSConfiguration);
        }

        // Calculate ETH amounts
        uint256 ethToSend = requiredSettlementAmount0 + 1 ether;

        address locker = liquiditySignal.mmState.advancer;
        deal(lcc1.underlying(), locker, requiredSettlementAmount1);

        // Record balances before the operation
        BalanceSnapshot memory balancesBefore;
        {
            balancesBefore.lockerEth = locker.balance;
            balancesBefore.pmLcc0 = IERC20(address(lcc0)).balanceOf(address(manager));
            balancesBefore.pmLcc1 = IERC20(address(lcc1)).balanceOf(address(manager));
            balancesBefore.canonicalCurrency0 = manager.balanceOf(mv.canonicalVault(), proxyPoolKey.currency0.toId());
            balancesBefore.canonicalCurrency1 = manager.balanceOf(mv.canonicalVault(), proxyPoolKey.currency1.toId());
            balancesBefore.lcc1UnderlyingLocker = IERC20(lcc1.underlying()).balanceOf(locker);
        }

        // Setup approvals and transfer counterparty asset to MMPM in scoped block
        vm.startPrank(locker);
        {
            Currency underlyingCurrency1 = Currency.wrap(lcc1.underlying());
            underlyingCurrency1.approve(address(vtsOrchestrator), requiredSettlementAmount1);
            underlyingCurrency1.transfer(address(positionManager), requiredSettlementAmount1);
        }

        // Prepare and execute actions in scoped block
        {
            MMA.PreparedAction[] memory actions = _commitMintSettleFromPositionManager(
                signalBytes, liquidityParams, requiredSettlementAmount0, requiredSettlementAmount1
            );
            (bytes memory actionsBytes, bytes[] memory params) = MMA.concatPrepared(actions);
            positionManager.modifyLiquidities{
                value: ethToSend
            }(abi.encode(actionsBytes, params), block.timestamp + 3600);
        }
        vm.stopPrank();

        // Record balances after the operation
        BalanceSnapshot memory balancesAfter;
        {
            balancesAfter.lockerEth = locker.balance;
            balancesAfter.pmLcc0 = IERC20(address(lcc0)).balanceOf(address(manager));
            balancesAfter.pmLcc1 = IERC20(address(lcc1)).balanceOf(address(manager));
            balancesAfter.canonicalCurrency0 = manager.balanceOf(mv.canonicalVault(), proxyPoolKey.currency0.toId());
            balancesAfter.canonicalCurrency1 = manager.balanceOf(mv.canonicalVault(), proxyPoolKey.currency1.toId());
            balancesAfter.lcc1UnderlyingLocker = IERC20(lcc1.underlying()).balanceOf(locker);
        }

        // Validate ETH refund
        assertEq(
            balancesAfter.lockerEth,
            balancesBefore.lockerEth - requiredSettlementAmount0,
            "Excess ETH should be refunded"
        );

        _assertPmAndCanonicalAfterNativeCommit(
            tickLower,
            tickUpper,
            liqDeltaU,
            balancesBefore,
            balancesAfter,
            requiredSettlementAmount0,
            requiredSettlementAmount1
        );

        // Validate position was created
        (Position memory position,) = positionManager.getPosition(1, 0);
        {
            assertEq(position.isActive, true, "Position should be active");
            assertEq(PoolId.unwrap(position.poolId), PoolId.unwrap(corePoolKey.toId()), "Pool ID mismatch");
            assertEq(position.tickLower, tickLower, "Tick lower mismatch");
            assertEq(position.tickUpper, tickUpper, "Tick upper mismatch");
            assertEq(position.liquidity, uint128(liqDeltaU), "Liquidity mismatch");
            assertEq(position.owner, address(mmPositionManager), "Position owner mismatch");
        }
    }

    /// @dev Helper to prepare actions for native ETH position
    function _commitMintSettleFromPositionManager(
        bytes memory signalBytes,
        ModifyLiquidityParams memory liquidityParams,
        uint256 requiredSettlementAmount0,
        uint256 requiredSettlementAmount1
    ) internal view returns (MMA.PreparedAction[] memory actions) {
        // Prepare actions using the adapter pattern:
        // 1. Commit the signal
        // 2. Mint the position
        // 3. Sync the counterparty asset balance as credit to locker (so it can be used for settlement)
        // 4. Settle the underlying into the position (consumes deltas)
        // 5. Take excess native ETH back to sender

        Currency underlyingCurrency1 = Currency.wrap(lcc1.underlying());
        actions = new MMA.PreparedAction[](5);
        actions[0] = MMA.prepareCommit(signalBytes);
        actions[1] = MMA.prepareMint(
            corePoolKey,
            1,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            uint256(liquidityParams.liquidityDelta)
        );
        // Sync the counterparty asset balance in MMPM as credit to locker
        actions[2] = MMA.prepareSync(underlyingCurrency1);
        // Settle underlying currencies into the position (payerIsUser=false uses locker's credits)
        // shouldTake=false means deposit both currencies (not withdraw)
        // ! DO NOT SETTLE FROM DELTAS HERE - IT WILL SETTLE THE FULL ETH AMOUNT SYNCED INTO THE POSITION, WHICH IS NOT WHAT WE WANT

        actions[3] = MMA.prepareSettle(
            corePoolKey, 1, 0, -requiredSettlementAmount0.toInt128(), -requiredSettlementAmount1.toInt128(), true
        );
        // Take any remaining native ETH delta back to the MM locker (advancer EOA).
        actions[4] = MMA.prepareTake(CurrencyLibrary.ADDRESS_ZERO, liquiditySignal.mmState.advancer, 0);
    }

    // @notice Tests creating a position in a native ETH market via MMPM with excess msg.value refund
    /// @dev Verifies that when sending more ETH than required for the position, the excess is refunded
    function test_swapWithNativeAsUnderlyingAsset_CanSettleFromDeltas_withRefund() public {
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        bytes memory signalBytes = abi.encode(liquiditySignal);
        address locker = liquiditySignal.mmState.advancer;

        // Calculate settlement amounts based on commitment maxima
        (, uint256 requiredSettlementAmount1) = _calculateSettlementAmounts(liquidityParams, marketVTSConfiguration);

        (uint256 c0,) = LiquidityUtils.calculateCommitmentMaxima(
            liquidityParams.tickLower, liquidityParams.tickUpper, uint128(uint256(liquidityParams.liquidityDelta))
        );

        uint256 excessEth = 1 ether;
        uint256 ethToSend = c0 + excessEth;

        uint256 selfEthBalanceBefore = locker.balance;
        deal(lcc1.underlying(), locker, requiredSettlementAmount1);

        vm.startPrank(locker);
        // Approve token1 (non-native) to the vtsOrchestrator
        Currency underlyingCurrency1 = Currency.wrap(lcc1.underlying());
        underlyingCurrency1.approve(address(vtsOrchestrator), requiredSettlementAmount1);
        // Transfer counterparty asset (token1 underlying) to MMPM so that payerIsUser = false
        // (usePositionManagerBalance) functions as expected. This allows settlement to use
        // MMPM's balance instead of requiring user to transfer during settlement.
        underlyingCurrency1.transfer(address(positionManager), requiredSettlementAmount1);

        // Prepare actions using the adapter pattern:
        // 1. Commit the signal
        // 2. Mint the position
        // 3. Sync the counterparty asset balance as credit to locker (so it can be used for settlement)
        // 4. Settle the underlying into the position (consumes deltas)
        // 5. Take excess native ETH back to sender
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](5);
        actions[0] = MMA.prepareCommit(signalBytes);
        actions[1] = MMA.prepareMint(
            corePoolKey,
            1,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            uint256(liquidityParams.liquidityDelta)
        );
        // Sync the counterparty asset balance in MMPM as credit to locker
        // owner=MMPM (address(this)), target=locker (msgSender())
        actions[2] = MMA.prepareSync(underlyingCurrency1);
        actions[3] = MMA.prepareSettleFromDeltas(corePoolKey, 1, 0, false, false);
        // Take any remaining native ETH delta back to locker (0 = max available)
        actions[4] = MMA.prepareTake(CurrencyLibrary.ADDRESS_ZERO, locker, 0);

        // Execute with unlock, sending excess ETH to test the refund
        (bytes memory actionsBytes, bytes[] memory params) = MMA.concatPrepared(actions);
        bytes memory unlockData = abi.encode(actionsBytes, params);
        positionManager.modifyLiquidities{value: ethToSend}(unlockData, block.timestamp + 3600);
        vm.stopPrank();

        _assertLockerEthSpendMatchesNativeEffectiveSettled(selfEthBalanceBefore, locker, 1, 0);
    }

    function _assertLockerEthSpendMatchesNativeEffectiveSettled(
        uint256 lockerEthBalanceBefore,
        address locker,
        uint256 tokenId,
        uint256 positionIndex
    ) internal view {
        uint256 lockerEthBalanceAfter = locker.balance;
        (, PositionId positionId) = positionManager.getPosition(tokenId, positionIndex);
        (uint256 settled0, uint256 settled1) = vtsOrchestrator.getPositionSettledAmounts(positionId);
        bool nativeIsToken0 = Currency.unwrap(corePoolKey.currency0) == address(lcc0);
        uint256 nativeEffectiveSettled = nativeIsToken0 ? settled0 : settled1;

        assertEq(
            lockerEthBalanceAfter,
            lockerEthBalanceBefore - nativeEffectiveSettled,
            "locker ETH spend should equal native effective settled backing"
        );
    }

    /// @dev Reduces stack depth in `test_settle_nativeNegativeDelta_usePositionManagerBalanceFalse_reverts_andDoesNotDrainMmpmEth`.
    function _setupNativeNegativeDeltaPosition(
        bytes memory signalBytes,
        ModifyLiquidityParams memory liquidityParams,
        address locker
    ) internal returns (uint256 mmpmEthBefore, bytes memory unlockData) {
        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) =
            _calculateSettlementAmounts(liquidityParams, marketVTSConfiguration);

        deal(lcc1.underlying(), locker, requiredSettlementAmount1);

        vm.startPrank(locker);
        Currency underlyingCurrency1 = Currency.wrap(lcc1.underlying());
        underlyingCurrency1.approve(address(vtsOrchestrator), requiredSettlementAmount1);
        underlyingCurrency1.transfer(address(positionManager), requiredSettlementAmount1);

        MMA.PreparedAction[] memory setupActions = _commitMintSettleFromPositionManager(
            signalBytes, liquidityParams, requiredSettlementAmount0, requiredSettlementAmount1
        );
        (bytes memory setupActionsBytes, bytes[] memory setupParams) = MMA.concatPrepared(setupActions);
        positionManager.modifyLiquidities{
            value: requiredSettlementAmount0
        }(abi.encode(setupActionsBytes, setupParams), block.timestamp + 3600);
        vm.stopPrank();

        vm.deal(address(positionManager), 1 ether);
        mmpmEthBefore = address(positionManager).balance;

        address underlying0 = ILCC(payable(Currency.unwrap(corePoolKey.currency0))).underlying();
        bool nativeIsToken0 = underlying0 == address(0);
        int128 amount0 = nativeIsToken0 ? -int128(int256(1)) : int128(0);
        int128 amount1 = nativeIsToken0 ? int128(0) : -int128(int256(1));

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareSettle(corePoolKey, 1, 0, amount0, amount1, false);
        (bytes memory actionsBytes, bytes[] memory params) = MMA.concatPrepared(actions);
        unlockData = abi.encode(actionsBytes, params);
    }

    function test_settle_nativeNegativeDelta_usePositionManagerBalanceFalse_reverts_andDoesNotDrainMmpmEth() public {
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});
        bytes memory signalBytes = abi.encode(liquiditySignal);
        address locker = liquiditySignal.mmState.advancer;

        (uint256 mmpmEthBefore, bytes memory unlockData) =
            _setupNativeNegativeDeltaPosition(signalBytes, liquidityParams, locker);

        vm.startPrank(locker);
        vm.expectPartialRevert(Errors.NativeTransferFromUnsupported.selector);
        positionManager.modifyLiquidities(unlockData, block.timestamp + 3600);
        vm.stopPrank();

        assertEq(address(positionManager).balance, mmpmEthBefore, "MMPM ETH should not be drained on unsupported path");
    }

    function test_currencyTransfer_nativeTransferFrom_revertsWhenFromIsNotSelf() public {
        address nonSelfFrom = makeAddr("nonSelfFrom");
        vm.expectRevert(abi.encodeWithSelector(Errors.NativeTransferFromUnsupported.selector, nonSelfFrom));
        this.callNativeTransferFrom(nonSelfFrom, address(this), 1);
    }

    function callNativeTransferFrom(address from, address to, uint256 amount) external {
        Currency.wrap(address(0)).transferFrom(from, to, amount);
    }
}

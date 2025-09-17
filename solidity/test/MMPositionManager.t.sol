// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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
import {CurrencySortHelper} from "../script/libraries/CurrencySortHelper.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {CoreHook} from "../src/CoreHook.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {console} from "forge-std/console.sol";
import {HookFlags} from "../script/constants/HookFlags.sol";
import {MarketTestBase} from "./modules/MarketTestBase.sol";
import {MMPositionManager} from "../src/MMPositionManager.sol";
import {StubSpokeVerifier} from "../src/modules/StubSpokeVerifier.sol";
import {MarketMakerTestBase} from "./modules/MMTestBase.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import {MarketMaker} from "../src/libraries/MarketMaker.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {PositionInfo} from "../src/types/Position.sol";
import {IOracleRegistry} from "../src/interfaces/IOracleRegistry.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {PositionId} from "../src/types/Position.sol";
import {IVTSManager} from "../src/interfaces/IVTSManager.sol";
import {MarketVTSConfiguration} from "../src/types/VTS.sol";

contract MMPositionManagerTest is MarketTestBase, MarketMakerTestBase {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using MarketMaker for MarketMaker.State;

    MMPositionManager positionManager;
    MarketVTSConfiguration marketVTSConfiguration;

    LiquidityCommitmentCertificate lcc0;
    LiquidityCommitmentCertificate lcc1;

    address mockOracleBTC = makeAddr("mockOracleBTC");
    address mockOracleUSDT = makeAddr("mockOracleUSDT");

    function setUp() public {
        _setupMarket();
        _setUpMM();
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
        address[2] memory mockCurrencies = [address(lcc0.underlyingAsset()), address(lcc1.underlyingAsset())];
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
        // mock the oracle registry to return mock oracles for BTC/USD and USDT/USD which are the currencies in the user's signalled liquidity reserves
        vm.mockCall(
            address(oracleRegistry),
            abi.encodeWithSelector(IOracleRegistry.getOracle.selector, "BTC/USD", address(0)),
            abi.encode(mockOracleBTC)
        );
        vm.mockCall(
            address(oracleRegistry),
            abi.encodeWithSelector(IOracleRegistry.getOracle.selector, "USDT/USD", address(0)),
            abi.encode(mockOracleUSDT)
        );

        // mock the price oracles to return prices and decimals numbers
        // initialize the price feeds for the mock assets
        // Create mock price feeds with 8 decimals (standard for Chainlink)
        // these are the mock prices of the assets in the signal reserves, if more assets are added, we need to mock the prices for them her
        // BTC/USD: ~$113,000 * 10^8 = 11300000000000
        vm.mockCall(mockOracleBTC, abi.encodeWithSelector(IOracle.getPrice.selector), abi.encode(11300000000000));
        // USDT/USD: ~$0.997 * 10^8 = 99700000
        vm.mockCall(mockOracleUSDT, abi.encodeWithSelector(IOracle.getPrice.selector), abi.encode(99700000));
        // set the decimals for the mock oracles
        vm.mockCall(mockOracleBTC, abi.encodeWithSelector(IOracle.decimals.selector), abi.encode(8));
        vm.mockCall(mockOracleUSDT, abi.encodeWithSelector(IOracle.decimals.selector), abi.encode(8));
        // TODO: add mock prices for the other assets in the signal reserves

        // Mock the getOraclePrice used to calculate the USD value of the LCCs total commitment
        // LCC0: ~$0.997 * 10^8 = 99700000
        vm.mockCall(
            address(lcc0),
            abi.encodeWithSelector(LiquidityCommitmentCertificate.usdPrice.selector),
            abi.encode(uint256(99700000), 8)
        );
        // LCC1: ~$0.999 * 10^8 = 99900000
        vm.mockCall(
            address(lcc1),
            abi.encodeWithSelector(LiquidityCommitmentCertificate.usdPrice.selector),
            abi.encode(uint256(99900000), 8)
        );
    }

    function test_canAddLiquidityToCorePool() public {
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function test_canCommitPosition() public {
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        bytes memory liquiditySignal = abi.encode(liquiditySignal);

        // Get the amount of LCC tokens that will be minted
        (uint256 token0AmountMinted, uint256 token1AmountMinted) =
            positionManager.calculateTokenAmountsFromPositionParams(corePoolKey, liquidityParams);

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) =
            positionManager.getBaseSettlementAmounts(corePoolKey, token0AmountMinted, token1AmountMinted);

        // Approve
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction0);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction1);

        uint256 pmLcc0BalanceBefore = lcc0.balanceOf(address(manager));
        uint256 pmLcc1BalanceBefore = lcc1.balanceOf(address(manager));

        uint256 proxyCurrency0BalanceBefore = manager.balanceOf(address(proxyHook), proxyPoolKey.currency0.toId());
        uint256 proxyCurrency1BalanceBefore = manager.balanceOf(address(proxyHook), proxyPoolKey.currency1.toId());

        PositionId positionId = positionManager.commit(corePoolKey, liquidityParams, liquiditySignal);
        PositionInfo memory positionInfo = positionManager.getPosition(positionId);
        uint256 tokenId = positionInfo.tokenId;

        uint256 pmLcc0BalanceAfter = lcc0.balanceOf(address(manager));
        uint256 pmLcc1BalanceAfter = lcc1.balanceOf(address(manager));

        // validate lcc liquidity has been added to the core pool
        assertEq(pmLcc0BalanceAfter, pmLcc0BalanceBefore + token0AmountMinted);
        assertEq(pmLcc1BalanceAfter, pmLcc1BalanceBefore + token1AmountMinted);

        // validate underlying tokens have been transferred to proxy pool
        // and proxy hook has claim tokens
        uint256 proxyCurrency0BalanceAfter = manager.balanceOf(address(proxyHook), proxyPoolKey.currency0.toId());
        uint256 proxyCurrency1BalanceAfter = manager.balanceOf(address(proxyHook), proxyPoolKey.currency1.toId());

        assertEq(proxyCurrency0BalanceAfter, proxyCurrency0BalanceBefore + underlyingLiquidityFraction0);
        assertEq(proxyCurrency1BalanceAfter, proxyCurrency1BalanceBefore + underlyingLiquidityFraction1);

        // validate proper nft details
        (int256 totalLiquidity, uint256 activePositionCount) = positionManager.getTotalNFTLiquidity(tokenId);
        assertEq(totalLiquidity, liquidityParams.liquidityDelta);
        assertEq(activePositionCount, 1);

        assertEq(PoolId.unwrap(positionInfo.poolKey.toId()), PoolId.unwrap(corePoolKey.toId()));
        assertEq(positionInfo.tickLower, liquidityParams.tickLower);
        assertEq(positionInfo.tickUpper, liquidityParams.tickUpper);
        assertEq(positionInfo.liquidity, liquidityParams.liquidityDelta);
        assertEq(positionInfo.owner, address(this));
        assertEq(positionInfo.positionIndex, activePositionCount - 1);
        assertEq(positionInfo.isActive, true);
    }

    function test_canSettleToCreatedPosition() public {
        // get the default market confiration so we can tweak it

        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get the amount of LCC tokens that will be minted
        (uint256 token0AmountMinted, uint256 token1AmountMinted) =
            positionManager.calculateTokenAmountsFromPositionParams(corePoolKey, liquidityParams);

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) =
            positionManager.getBaseSettlementAmounts(corePoolKey, token0AmountMinted, token1AmountMinted);

        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction0);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction1);

        // commit the position
        PositionId positionId = positionManager.commit(corePoolKey, liquidityParams, liquiditySignal);

        // get the current vts for this position
        (uint256 vtsCurrent0BeforeSettlement, uint256 vtsCurrent1BeforeSettlement) =
            IVTSManager(coreHookAddress).getVTSCurrent(positionId);

        // assert the vts before further settlement is equal to the base vts
        assertEq(vtsCurrent0BeforeSettlement, marketVTSConfiguration.token0.baseVTSRate);
        assertEq(vtsCurrent1BeforeSettlement, marketVTSConfiguration.token1.baseVTSRate);
        // make a settlement to the position with the base vts, which should double the current VTS for this position
        // -- before making a settlement, we have to approve the position manager to take the tokens from us
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction0);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction1);
        // -- before making a settlement, we have to approve the position manager to take the tokens from us
        positionManager.settle(positionId, underlyingLiquidityFraction0, underlyingLiquidityFraction1);

        // get the current vts for this position
        (uint256 vtsCurrent0AfterSettlement, uint256 vtsCurrent1AfterSettlement) =
            IVTSManager(coreHookAddress).getVTSCurrent(positionId);
        // assert the vts after settlement is equal to the base vts * 2
        assertEq(vtsCurrent0AfterSettlement, marketVTSConfiguration.token0.baseVTSRate * 2);
        assertEq(vtsCurrent1AfterSettlement, marketVTSConfiguration.token1.baseVTSRate * 2);
    }

    function test_canWithdrawFromSettledPosition_withoutOpenRFS() public {
        // get the default market confiration so we can tweak it
        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get the amount of LCC tokens that will be minted
        (uint256 token0AmountMinted, uint256 token1AmountMinted) =
            positionManager.calculateTokenAmountsFromPositionParams(corePoolKey, liquidityParams);

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) =
            positionManager.getBaseSettlementAmounts(corePoolKey, token0AmountMinted, token1AmountMinted);

        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction0);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction1);

        // commit the position
        PositionId positionId = positionManager.commit(corePoolKey, liquidityParams, liquiditySignal);

        // get current VTS
        (uint256 vtsCurrent0BeforeWithdrawal, uint256 vtsCurrent1BeforeWithdrawal) =
            IVTSManager(coreHookAddress).getVTSCurrent(positionId);

        // Mock the RFS for this position
        // this means RFS for this position is not open and the user can withdraw 1000 & 500 units of each token
        uint256 amount0 = 100;
        uint256 amount1 = 50;
        bool rfsOpen = false; // if rfs is open then amount0 || amount1 will be less than zero
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.getRFS.selector),
            abi.encode(rfsOpen, toBalanceDelta(int128(int256(amount0)), int128(int256(amount1))))
        );
        // get balance of underlying tokens of position manager
        uint256 preBalanceOfToken0UnderlyingAssetInPM = Currency.wrap(lcc0.underlyingAsset()).balanceOf(address(this));
        uint256 preBalanceOfToken1UnderlyingAssetInPM = Currency.wrap(lcc1.underlyingAsset()).balanceOf(address(this));

        // withdraw from the position
        positionManager.withdraw(positionId, amount0, amount1);

        // get balance of underlying tokens of position manager after withdrawal
        uint256 postBalanceOfToken0UnderlyingAssetInPM = Currency.wrap(lcc0.underlyingAsset()).balanceOf(address(this));
        uint256 postBalanceOfToken1UnderlyingAssetInPM = Currency.wrap(lcc1.underlyingAsset()).balanceOf(address(this));

        // validate balance after withdrawal
        assertEq(postBalanceOfToken0UnderlyingAssetInPM, preBalanceOfToken0UnderlyingAssetInPM + amount0);
        assertEq(postBalanceOfToken1UnderlyingAssetInPM, preBalanceOfToken1UnderlyingAssetInPM + amount1);

        // validate vts current reduces after withdrawal
        (uint256 vtsCurrent0AfterWithdrawal, uint256 vtsCurrent1AfterWithdrawal) =
            IVTSManager(coreHookAddress).getVTSCurrent(positionId);

        assertGt(vtsCurrent0BeforeWithdrawal, vtsCurrent0AfterWithdrawal);
        assertGt(vtsCurrent1BeforeWithdrawal, vtsCurrent1AfterWithdrawal);
    }

    function test_canDecommitPosition_usingPositionId() public {
        // get the default market confiration so we can tweak it
        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get the amount of LCC tokens that will be minted
        (uint256 token0AmountMinted, uint256 token1AmountMinted) =
            positionManager.calculateTokenAmountsFromPositionParams(corePoolKey, liquidityParams);

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) =
            positionManager.getBaseSettlementAmounts(corePoolKey, token0AmountMinted, token1AmountMinted);

        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction0);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction1);
        PositionId positionId = positionManager.commit(corePoolKey, liquidityParams, liquiditySignal);

        // get underlying asset balance before decommitment
        uint256 token0BalanceBefore = Currency.wrap(lcc0.underlyingAsset()).balanceOf(address(this));
        uint256 token1BalanceBefore = Currency.wrap(lcc1.underlyingAsset()).balanceOf(address(this));

        console.log("token0BalanceBefore", token0BalanceBefore);
        console.log("token1BalanceBefore", token1BalanceBefore);

        // Mock the RFS for this position
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.getRFS.selector),
            abi.encode(false, toBalanceDelta(0, 0))
        );
        BalanceDelta balanceDelta = positionManager.decommitPosition(positionId);

        // get underlying asset balance after decommitment
        uint256 token0BalanceAfter = Currency.wrap(lcc0.underlyingAsset()).balanceOf(address(this));
        uint256 token1BalanceAfter = Currency.wrap(lcc1.underlyingAsset()).balanceOf(address(this));

        assertEq(token0BalanceAfter, token0BalanceBefore + LiquidityUtils.safeInt128ToUint256(balanceDelta.amount0()));
        assertEq(token1BalanceAfter, token1BalanceBefore + LiquidityUtils.safeInt128ToUint256(balanceDelta.amount1()));
    }

    function test_canDecommitPosition_usingTokenId() public {
        // get the default market confiration so we can tweak it
        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get the amount of LCC tokens that will be minted
        (uint256 token0AmountMinted, uint256 token1AmountMinted) =
            positionManager.calculateTokenAmountsFromPositionParams(corePoolKey, liquidityParams);

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) =
            positionManager.getBaseSettlementAmounts(corePoolKey, token0AmountMinted, token1AmountMinted);

        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction0);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction1);
        PositionId positionId = positionManager.commit(corePoolKey, liquidityParams, liquiditySignal);

        // get the token id for the position
        uint256 tokenId = positionManager.getPosition(positionId).tokenId;

        // get underlying asset balance before decommitment
        uint256 token0BalanceBefore = Currency.wrap(lcc0.underlyingAsset()).balanceOf(address(this));
        uint256 token1BalanceBefore = Currency.wrap(lcc1.underlyingAsset()).balanceOf(address(this));

        // Mock the RFS for this position
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.getRFS.selector),
            abi.encode(false, toBalanceDelta(0, 0))
        );

        positionManager.decommit(tokenId);

        // get underlying asset balance after decommitment
        uint256 token0BalanceAfter = Currency.wrap(lcc0.underlyingAsset()).balanceOf(address(this));
        uint256 token1BalanceAfter = Currency.wrap(lcc1.underlyingAsset()).balanceOf(address(this));

        assertGt(token0BalanceAfter, token0BalanceBefore);
        assertGt(token1BalanceAfter, token1BalanceBefore);
    }
}

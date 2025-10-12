// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
// solhint-disable max-line-length

import {BalanceDelta, toBalanceDelta, add} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {console} from "forge-std/console.sol";
import {MarketTestBase} from "./modules/MarketTestBase.sol";
import {MMPositionManager} from "../src/MMPositionManager.sol";
import {MarketMakerTestBase} from "./modules/MMTestBase.sol";
import {MarketMaker} from "../src/libraries/MarketMaker.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {PositionMeta} from "../src/types/Position.sol";
import {IOracleRegistry} from "../src/interfaces/IOracleRegistry.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {PositionId} from "../src/types/Position.sol";
import {IVTSManager} from "../src/interfaces/IVTSManager.sol";
import {MarketVTSConfiguration} from "../src/types/VTS.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {PositionMeta} from "../src/types/Position.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {IPositionIndex} from "../src/interfaces/IPositionIndex.sol";
import {LiquiditySignal} from "../src/types/Position.sol";

contract MMPositionManagerTest is MarketTestBase, MarketMakerTestBase {
    using SafeCast for *;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using MarketMaker for MarketMaker.State;

    MMPositionManager internal positionManager;
    MarketVTSConfiguration internal marketVTSConfiguration;

    LiquidityCommitmentCertificate internal lcc0;
    LiquidityCommitmentCertificate internal lcc1;

    address internal mockOracleBTC = makeAddr("mockOracleBTC");
    address internal mockOracleUSDT = makeAddr("mockOracleUSDT");

    address guarantor = makeAddr("guarantor");
    uint256 guarantorInitialBalance = 10000e18;

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

    function testCanAddLiquidityToCorePool() public {
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function testCanCommitPosition() public {
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
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction0);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction1);

        uint256 pmLcc0BalanceBefore = lcc0.balanceOf(address(manager));
        uint256 pmLcc1BalanceBefore = lcc1.balanceOf(address(manager));

        uint256 proxyCurrency0BalanceBefore = manager.balanceOf(address(proxyHook), proxyPoolKey.currency0.toId());
        uint256 proxyCurrency1BalanceBefore = manager.balanceOf(address(proxyHook), proxyPoolKey.currency1.toId());

        positionManager.commit(
            corePoolKey,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            liquidityParams.liquidityDelta,
            liquiditySignal
        );
        // First commit mints the first NFT
        uint256 tokenId = 1;
        PositionMeta memory m = positionManager.getPosition(tokenId, 0);

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

        assertEq(PoolId.unwrap(m.poolId), PoolId.unwrap(corePoolKey.toId()));
        assertEq(m.tickLower, liquidityParams.tickLower);
        assertEq(m.tickUpper, liquidityParams.tickUpper);
        assertEq(m.liquidity, liquidityParams.liquidityDelta);
        // Position owner is the manager contract
        assertEq(m.owner, address(mmPositionManager));
        assertEq(m.isActive, true);
    }

    function testCanSettleToCreatedPosition() public {
        // get the default market confiration so we can tweak it

        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) =
            LiquidityUtils.getBaseSettlementAmounts(liquidityParams, marketVTSConfiguration);

        // Approve the position manager to take the base/minimum underlying liquidity to create the position
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction0);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction1);

        // commit the position
        PositionId positionId = positionManager.commit(
            corePoolKey,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            liquidityParams.liquidityDelta,
            liquiditySignal
        );
        uint256 tokenId = 1;

        // get the current vts for this position
        // TODO: Change these tests to either depend on VTSCalculator, or ...
        (uint256 vtsCurrent0BeforeSettlement, uint256 vtsCurrent1BeforeSettlement) =
            IVTSManager(coreHookAddress).getVTSCurrent(positionId);

        // VTS current from the `IVTSManager` is expressed in 1e18
        // VTS base in the market configuration is expressed in bips
        uint256 vtsCurrent0BeforeSettlementBips = (vtsCurrent0BeforeSettlement * LiquidityUtils.ONE_BIP) / 1e18;
        uint256 vtsCurrent1BeforeSettlementBips = (vtsCurrent1BeforeSettlement * LiquidityUtils.ONE_BIP) / 1e18;

        // assert the vts before further settlement is equal to the base vts
        assertApproxEqRel(
            vtsCurrent0BeforeSettlementBips, marketVTSConfiguration.token0.baseVTSRate, 1e16, "Price within 1%"
        );
        assertApproxEqRel(
            vtsCurrent1BeforeSettlementBips, marketVTSConfiguration.token1.baseVTSRate, 1e16, "Price within 1%"
        );
        // make a settlement to the position with the base vts, which should double the current VTS for this position
        // -- before making a settlement, we have to approve the position manager to take the tokens from us
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction0);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction1);
        // -- make a settlement to the created position
        positionManager.settle(tokenId, 0, underlyingLiquidityFraction0, underlyingLiquidityFraction1);

        // get the current vts for this position
        (uint256 vtsCurrent0AfterSettlement, uint256 vtsCurrent1AfterSettlement) =
            IVTSManager(coreHookAddress).getVTSCurrent(positionId);
        // assert the vts after settlement is equal to the base vts * 2
        // since we basically just made another settlement equal to the base vts, the vts should be doubled
        uint256 vtsCurrent0AfterSettlementBips = (vtsCurrent0AfterSettlement * LiquidityUtils.ONE_BIP) / 1e18;
        uint256 vtsCurrent1AfterSettlementBips = (vtsCurrent1AfterSettlement * LiquidityUtils.ONE_BIP) / 1e18;

        assertApproxEqRel(
            vtsCurrent0AfterSettlementBips, marketVTSConfiguration.token0.baseVTSRate * 2, 1e16, "Price within 1%"
        );
        assertApproxEqRel(
            vtsCurrent1AfterSettlementBips, marketVTSConfiguration.token1.baseVTSRate * 2, 1e16, "Price within 1%"
        );
    }

    function testCanWithdrawFromSettledPositionWithoutOpenRFS() public {
        // get the default market confiration so we can tweak it
        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) =
            LiquidityUtils.getBaseSettlementAmounts(liquidityParams, marketVTSConfiguration);

        // Approve the position manager to take the base/minimum underlying liquidity to create the position
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction0);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction1);

        // commit the position
        PositionId positionId = positionManager.commit(
            corePoolKey,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            liquidityParams.liquidityDelta,
            liquiditySignal
        );
        uint256 tokenId = 1;

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
            abi.encodeWithSelector(IVTSManager.calcRFS.selector),
            abi.encode(rfsOpen, toBalanceDelta(int128(int256(amount0)), int128(int256(amount1))))
        );
        // get balance of underlying tokens of position manager
        uint256 preBalanceOfToken0UnderlyingAssetInPM = Currency.wrap(lcc0.underlyingAsset()).balanceOf(address(this));
        uint256 preBalanceOfToken1UnderlyingAssetInPM = Currency.wrap(lcc1.underlyingAsset()).balanceOf(address(this));

        // withdraw from the position
        positionManager.withdraw(tokenId, 0, amount0, amount1);

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

    function testCanDecommitPositionUsingTokenAndIndex() public {
        // get the default market confiration so we can tweak it
        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) =
            LiquidityUtils.getBaseSettlementAmounts(liquidityParams, marketVTSConfiguration);

        // Approve the position manager to take the base/minimum underlying liquidity to create the position
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction0);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction1);
        positionManager.commit(
            corePoolKey,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            liquidityParams.liquidityDelta,
            liquiditySignal
        );
        uint256 tokenId = 1;

        // get underlying asset balance before decommitment
        uint256 token0BalanceBefore = Currency.wrap(lcc0.underlyingAsset()).balanceOf(address(this));
        uint256 token1BalanceBefore = Currency.wrap(lcc1.underlyingAsset()).balanceOf(address(this));

        // Mock the liquidation preparation for this position
        uint256 s0 = 10;
        uint256 s1 = 5;
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.prepareLiquidation.selector),
            abi.encode(s0, s1)
        );
        BalanceDelta balanceDelta = positionManager.decommitPosition(corePoolKey, tokenId, 0);

        // get underlying asset balance after decommitment
        uint256 token0BalanceAfter = Currency.wrap(lcc0.underlyingAsset()).balanceOf(address(this));
        uint256 token1BalanceAfter = Currency.wrap(lcc1.underlyingAsset()).balanceOf(address(this));

        assertEq(token0BalanceAfter, token0BalanceBefore + LiquidityUtils.safeInt128ToUint256(balanceDelta.amount0()));
        assertEq(token1BalanceAfter, token1BalanceBefore + LiquidityUtils.safeInt128ToUint256(balanceDelta.amount1()));
        assertEq(uint256(uint128(int128(balanceDelta.amount0()))), s0);
        assertEq(uint256(uint128(int128(balanceDelta.amount1()))), s1);
    }

    function testCanDecommitPositionUsingTokenId() public {
        // get the default market confiration so we can tweak it
        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) =
            LiquidityUtils.getBaseSettlementAmounts(liquidityParams, marketVTSConfiguration);

        // Approve the position manager to take the base/minimum underlying liquidity to create the position
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction0);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction1);
        positionManager.commit(
            corePoolKey,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            liquidityParams.liquidityDelta,
            liquiditySignal
        );

        // get the token id for the position (first token)
        uint256 tokenId = 1;

        // get underlying asset balance before decommitment
        uint256 token0BalanceBefore = Currency.wrap(lcc0.underlyingAsset()).balanceOf(address(this));
        uint256 token1BalanceBefore = Currency.wrap(lcc1.underlyingAsset()).balanceOf(address(this));

        // Mock the liquidation preparation for this position
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.prepareLiquidation.selector),
            abi.encode(uint256(3), uint256(2))
        );

        positionManager.decommit(corePoolKey, tokenId);

        // get underlying asset balance after decommitment
        uint256 token0BalanceAfter = Currency.wrap(lcc0.underlyingAsset()).balanceOf(address(this));
        uint256 token1BalanceAfter = Currency.wrap(lcc1.underlyingAsset()).balanceOf(address(this));

        assertGt(token0BalanceAfter, token0BalanceBefore);
        assertGt(token1BalanceAfter, token1BalanceBefore);
    }

    // can partially seize a position while not being a market maker
    function test_canPartially_seizePosition_asNoneMM() public {
        // commit to a position
        bytes memory liquiditySignal = abi.encode(liquiditySignal);

        uint256 siezureFractionBPS = 1000;

        BalanceDelta rfsDelta = toBalanceDelta(-100, 0);

        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) =
            LiquidityUtils.calculateTokenAmountsFromPositionParams(manager, corePoolKey, liquidityParams);

        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction0);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction1);

        // commit the position
        PositionId positionId = positionManager.commit(
            corePoolKey,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            liquidityParams.liquidityDelta,
            liquiditySignal
        );
        uint256 tokenId = 1;

        // Mock the RFS for this position
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.calcRFS.selector),
            // mock the RFS for this position to be open and the balanceDelta to be negative to indicate pending amount to be settled by the mm
            abi.encode(true, rfsDelta)
        );

        // mock the siezure amount for this position
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.getSeizureAmount.selector),
            abi.encode(siezureFractionBPS) //10% of the position is up for seizure
        );

        // mint the underlying assets to the guarantor, and approve the  position manager to take the underlying assets
        MockERC20(lcc0.underlyingAsset()).mint(guarantor, guarantorInitialBalance);
        MockERC20(lcc1.underlyingAsset()).mint(guarantor, guarantorInitialBalance);

        // act as the guarantor who wants to seize the position partially
        vm.startPrank(guarantor);
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), 100);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), 100);

        // --- seize the position ---
        PositionMeta memory positionBeforeSeizure = positionManager.getPosition(tokenId, 0);
        // uint256 token1UABeforeSeizure = Currency.wrap(lcc1.underlyingAsset()).balanceOf(address(guarantor));
        uint256 token0UABeforeSeizure = Currency.wrap(lcc0.underlyingAsset()).balanceOf(address(guarantor));
        // get the initial settled balance delta
        (uint256 initialSettledAmount0, uint256 initialSettledAmount1) =
            IVTSManager(coreHookAddress).getPositionSettledAmounts(positionId);
        BalanceDelta initialSettledBalanceDelta =
            toBalanceDelta(initialSettledAmount0.toInt128(), initialSettledAmount1.toInt128());

        // during seizure, the outstanding amount will be settled, so that would be the total settled amount to use to calculate the fraction to return back
        BalanceDelta settledBalanceDelta = add(initialSettledBalanceDelta, LiquidityUtils.negateBalanceDelta(rfsDelta));
        // this is how much would be realized from the liquidation, which is basically the fraction of the position that can be seized multiplied by the settled balance delta
        BalanceDelta expectedSettlementFractionDelta =
            LiquidityUtils.calculateLiquidityFraction(settledBalanceDelta, siezureFractionBPS);

        // seize the position
        // settle all the outstanding rfs of token 0
        positionManager.seize(tokenId, 0, LiquidityUtils.safeInt128ToUint256(rfsDelta.amount0()), 0);

        // get the balance of the underlying assets after seizure
        uint256 token0UAAfterSeizure = Currency.wrap(lcc0.underlyingAsset()).balanceOf(address(guarantor));

        // get the expected balance of the underlying assets after seizure
        uint256 expectedGuarantorToken0UAAfterSeizure = token0UABeforeSeizure
            + LiquidityUtils.safeInt128ToUint256(expectedSettlementFractionDelta.amount0())
            - LiquidityUtils.safeInt128ToUint256(rfsDelta.amount0());

        PositionMeta memory positionAfterSeizure = positionManager.getPosition(tokenId, 0);

        uint256 expectedLiquidityAfterSeizure =
            (uint256(positionBeforeSeizure.liquidity) * (10000 - siezureFractionBPS)) / 10000;

        // validate liquidity in the position is reduced
        assertEq(uint256(positionAfterSeizure.liquidity), expectedLiquidityAfterSeizure);

        // validate that part of the position's settlement has been taken out, and
        assertEq(token0UAAfterSeizure, expectedGuarantorToken0UAAfterSeizure);

        // expected settlement = initial settlement + rfs delta -  settlement fraction seized
        (uint256 finalSettledAmount0, uint256 finalSettledAmount1) =
            IVTSManager(coreHookAddress).getPositionSettledAmounts(positionId);
        BalanceDelta finalSettledBalanceDelta =
            toBalanceDelta(finalSettledAmount0.toInt128(), finalSettledAmount1.toInt128());
        uint256 expectedRemainingSettlement0ForPosition = LiquidityUtils.safeInt128ToUint256(
            initialSettledBalanceDelta.amount0()
        ) + LiquidityUtils.safeInt128ToUint256(rfsDelta.amount0())
            - LiquidityUtils.safeInt128ToUint256(expectedSettlementFractionDelta.amount0());

        // validate the remaining settlement for the position is as expected
        assertEq(
            LiquidityUtils.safeInt128ToUint256(finalSettledBalanceDelta.amount0()),
            expectedRemainingSettlement0ForPosition
        );
    }

    // can partially seize a position while not being a market maker and settling more than the outstanding RFS amount
    function test_canPartially_seizePosition_asNoneMM_withPartialSettlement() public {
        // commit to a position
        bytes memory liquiditySignal = abi.encode(liquiditySignal);

        uint256 seizureFractionBPS = 1000;

        BalanceDelta rfsDelta = toBalanceDelta(-100, 0);

        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) =
            LiquidityUtils.getBaseSettlementAmounts(liquidityParams, marketVTSConfiguration);

        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction0);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction1);

        PositionId positionId = positionManager.commit(
            corePoolKey,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            liquidityParams.liquidityDelta,
            liquiditySignal
        );
        uint256 tokenId = 1;

        // Mock the RFS for this position
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.calcRFS.selector),
            // mock the RFS for this position to be open and the balanceDelta to be negative to indicate pending amount to be settled by the mm
            abi.encode(true, rfsDelta)
        );

        // mock the siezure amount for this position
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.getSeizureAmount.selector),
            abi.encode(seizureFractionBPS) //10% of the position is up for seizure
        );

        // mint the underlying assets to the guarantor, and approve the  position manager to take the underlying assets
        MockERC20(lcc0.underlyingAsset()).mint(guarantor, guarantorInitialBalance);
        MockERC20(lcc1.underlyingAsset()).mint(guarantor, guarantorInitialBalance);

        // act as the guarantor who wants to seize the position partially
        vm.startPrank(guarantor);
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), 100);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), 100);

        PositionMeta memory positionBeforeSeizure = positionManager.getPosition(tokenId, 0);
        // uint256 token1UABeforeSeizure = Currency.wrap(lcc1.underlyingAsset()).balanceOf(address(guarantor));
        uint256 token0UABeforeSeizure = Currency.wrap(lcc0.underlyingAsset()).balanceOf(address(guarantor));
        (uint256 initialSettledAmount0, uint256 initialSettledAmount1) =
            IVTSManager(coreHookAddress).getPositionSettledAmounts(positionId);
        BalanceDelta initialSettledBalanceDelta =
            toBalanceDelta(initialSettledAmount0.toInt128(), initialSettledAmount1.toInt128());
        // during seizure, the outstanding amount will be settled, so that would be the total settled amount to use to calculate the fraction to return back

        // ---- seize the position
        // settle all the outstanding rfs of token 0
        uint256 amount0ToSettle = LiquidityUtils.safeInt128ToUint256(rfsDelta.amount0()) / 2;
        BalanceDelta settledBalanceDelta =
            add(initialSettledBalanceDelta, toBalanceDelta(amount0ToSettle.toInt128(), 0));
        positionManager.seize(tokenId, 0, amount0ToSettle, 0);
        seizureFractionBPS = LiquidityUtils.calculateSiezureFraction(
            toBalanceDelta(amount0ToSettle.toInt128(), 0), rfsDelta, seizureFractionBPS
        );
        // this is how much would be realized from the liquidation, which is basically the fraction of the position that can be seized multiplied by the settled balance delta
        BalanceDelta expectedSettlementFractionDelta =
            LiquidityUtils.calculateLiquidityFraction(settledBalanceDelta, seizureFractionBPS);
        // get the balance of the underlying assets after seizure
        uint256 token0UAAfterSeizure = Currency.wrap(lcc0.underlyingAsset()).balanceOf(address(guarantor));

        // get the expected balance of the underlying assets after seizure
        uint256 expectedGuarantorToken0UAAfterSeizure = token0UABeforeSeizure
            + LiquidityUtils.safeInt128ToUint256(expectedSettlementFractionDelta.amount0()) - amount0ToSettle;

        PositionMeta memory positionAfterSeizure = positionManager.getPosition(tokenId, 0);

        uint256 expectedLiquidityAfterSeizure =
            (uint256(positionBeforeSeizure.liquidity) * (10000 - seizureFractionBPS)) / 10000;

        // validate liquidity in the position is reduced
        assertEq(uint256(positionAfterSeizure.liquidity), expectedLiquidityAfterSeizure);

        // validate that part of the position's settlement has been taken out, and
        assertEq(token0UAAfterSeizure, expectedGuarantorToken0UAAfterSeizure);

        // expected settlement = initial settlement + rfs delta -  settlement fraction seized
        (uint256 finalSettledAmount0, uint256 finalSettledAmount1) =
            IVTSManager(coreHookAddress).getPositionSettledAmounts(positionId);
        BalanceDelta finalSettledBalanceDelta =
            toBalanceDelta(finalSettledAmount0.toInt128(), finalSettledAmount1.toInt128());

        uint256 expectedRemainingSettlement0ForPosition = LiquidityUtils.safeInt128ToUint256(
            initialSettledBalanceDelta.amount0()
        ) + amount0ToSettle - LiquidityUtils.safeInt128ToUint256(expectedSettlementFractionDelta.amount0());

        // validate the remaining settlement for the position is as expected
        assertEq(
            LiquidityUtils.safeInt128ToUint256(finalSettledBalanceDelta.amount0()),
            expectedRemainingSettlement0ForPosition
        );
    }

    // can fully seize a position while not being a market maker
    function test_canFully_seizePosition_asNoneMM_withEnoughSettlement() public {
        // commit to a position
        bytes memory liquiditySignal = abi.encode(liquiditySignal);

        uint256 siezureFractionBPS = 10000;

        BalanceDelta rfsDelta = toBalanceDelta(-100, 0);

        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) =
            LiquidityUtils.getBaseSettlementAmounts(liquidityParams, marketVTSConfiguration);

        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction0);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction1);

        PositionId positionId = positionManager.commit(
            corePoolKey,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            liquidityParams.liquidityDelta,
            liquiditySignal
        );
        uint256 tokenId = 1;
        // Mock the RFS for this position
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.calcRFS.selector),
            // mock the RFS for this position to be open and the balanceDelta to be negative to indicate pending amount to be settled by the mm
            abi.encode(true, rfsDelta)
        );

        // mock the siezure amount for this position
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.getSeizureAmount.selector),
            abi.encode(siezureFractionBPS) //10% of the position is up for seizure
        );

        // mint the underlying assets to the guarantor, and approve the  position manager to take the underlying assets
        MockERC20(lcc0.underlyingAsset()).mint(guarantor, guarantorInitialBalance);
        // MockERC20(lcc1.underlyingAsset()).mint(guarantor, guarantorInitialBalance);

        // act as the guarantor who wants to seize the position partially
        vm.startPrank(guarantor);
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), 100);
        // ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), 100);

        // seize the position by settling all of the outstanding RFS amount
        positionManager.seize(
            tokenId,
            0,
            LiquidityUtils.safeInt128ToUint256(rfsDelta.amount0()),
            LiquidityUtils.safeInt128ToUint256(rfsDelta.amount1())
        );

        // get the total settlement amount for the position after seizure
        (uint256 finalSettledAmount0, uint256 finalSettledAmount1) =
            IVTSManager(coreHookAddress).getPositionSettledAmounts(positionId);
        BalanceDelta finalSettledBalanceDelta =
            toBalanceDelta(finalSettledAmount0.toInt128(), finalSettledAmount1.toInt128());

        // get the position info after seizure
        PositionMeta memory positionAfterSeizure = IPositionIndex(coreHookAddress).getPosition(positionId, false);

        // validate the position is marked as inactive
        assertEq(positionAfterSeizure.isActive, false);
        // validate all the settled amount is seized
        assertEq(LiquidityUtils.safeInt128ToUint256(finalSettledBalanceDelta.amount0()), 0);
    }

    // can seize a position while not being a market maker and settling more than the outstanding RFS amount
    function test_canFully_seizePosition_asNoneMM_withOverSettlement() public {
        // commit to a position
        bytes memory liquiditySignal = abi.encode(liquiditySignal);

        uint256 siezureFractionBPS = 10000;

        BalanceDelta rfsDelta = toBalanceDelta(-100, 0);

        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) =
            LiquidityUtils.getBaseSettlementAmounts(liquidityParams, marketVTSConfiguration);

        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction0);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction1);

        PositionId positionId = positionManager.commit(
            corePoolKey,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            liquidityParams.liquidityDelta,
            liquiditySignal
        );
        uint256 tokenId = 1;
        // Mock the RFS for this position
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.calcRFS.selector),
            // mock the RFS for this position to be open and the balanceDelta to be negative to indicate pending amount to be settled by the mm
            abi.encode(true, rfsDelta)
        );

        // mock the siezure amount for this position
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.getSeizureAmount.selector),
            abi.encode(siezureFractionBPS) //10% of the position is up for seizure
        );

        // mint the underlying assets to the guarantor, and approve the  position manager to take the underlying assets
        MockERC20(lcc0.underlyingAsset()).mint(guarantor, guarantorInitialBalance);
        // MockERC20(lcc1.underlyingAsset()).mint(guarantor, guarantorInitialBalance);

        // act as the guarantor who wants to seize the position partially
        vm.startPrank(guarantor);
        // seize the position by settling more than the outstanding RFS amount
        uint256 amount0ToSettle = LiquidityUtils.safeInt128ToUint256(rfsDelta.amount0()) + 100;
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), amount0ToSettle);
        // ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), 100);
        positionManager.seize(tokenId, 0, amount0ToSettle, 0);
        siezureFractionBPS = LiquidityUtils.calculateSiezureFraction(
            toBalanceDelta(amount0ToSettle.toInt128(), 0), rfsDelta, siezureFractionBPS
        );
        // get the total settlement amount for the position after seizure
        (uint256 finalSettledAmount0, uint256 finalSettledAmount1) =
            IVTSManager(coreHookAddress).getPositionSettledAmounts(positionId);
        BalanceDelta finalSettledBalanceDelta =
            toBalanceDelta(finalSettledAmount0.toInt128(), finalSettledAmount1.toInt128());

        // get the position info after seizure
        PositionMeta memory positionAfterSeizure = IPositionIndex(coreHookAddress).getPosition(positionId, false);

        // validate the position is marked as inactive
        assertEq(positionAfterSeizure.isActive, false);
        // validate all the settled amount is seized
        assertEq(LiquidityUtils.safeInt128ToUint256(finalSettledBalanceDelta.amount0()), 0);
    }

    // can partially seize a position while being a market maker
    function test_canPartially_seizePosition_asMM() public {
        LiquiditySignal[] memory liquiditySignals = generateLiquiditySignals(2);
        // Generate the liquidity signals
        bytes memory liquiditySignalOne = abi.encode(liquiditySignals[0]);
        bytes memory liquiditySignalTwo = abi.encode(liquiditySignals[1]);

        uint256 siezureFractionBPS = 5000; // 50% of the position in bps is up for seizure

        BalanceDelta rfsDelta = toBalanceDelta(0, -100);

        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) =
            LiquidityUtils.getBaseSettlementAmounts(liquidityParams, marketVTSConfiguration);

        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction0);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction1);

        // make a commitment to a position in order to be an mm
        positionManager.commit(
            corePoolKey,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            liquidityParams.liquidityDelta,
            liquiditySignalOne
        );

        // mock the seizure amount for this position
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.getSeizureAmount.selector),
            abi.encode(siezureFractionBPS) //10% of the position is up for seizure
        );

        // mint the underlying assets to the guarantor, and approve the  position manager to take the underlying assets
        MockERC20(lcc0.underlyingAsset()).mint(guarantor, guarantorInitialBalance);
        MockERC20(lcc1.underlyingAsset()).mint(guarantor, guarantorInitialBalance);

        // create another position to seize
        vm.startPrank(guarantor);
        // approve the position manager to take the underlying assets
        (underlyingLiquidityFraction0, underlyingLiquidityFraction1) =
            LiquidityUtils.getBaseSettlementAmounts(liquidityParams, marketVTSConfiguration);
        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        ERC20(lcc0.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction0);
        ERC20(lcc1.underlyingAsset()).approve(address(mmPositionManager), underlyingLiquidityFraction1);

        // make a commitment to a position in order to be an mm
        PositionId newPositionId = positionManager.commit(
            corePoolKey,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            liquidityParams.liquidityDelta,
            liquiditySignalTwo
        );
        uint256 tokenId = 2; //second token generated
        vm.stopPrank();

        // approve the amount to be deposited to the new position to make rfs
        ERC20(lcc0.underlyingAsset()).approve(
            address(mmPositionManager), LiquidityUtils.safeInt128ToUint256(rfsDelta.amount0())
        );
        ERC20(lcc1.underlyingAsset()).approve(
            address(mmPositionManager), LiquidityUtils.safeInt128ToUint256(rfsDelta.amount1())
        );

        PositionMeta memory positionToSeize = positionManager.getPosition(tokenId, 0);
        // get the total settlement amount for the position to seize
        (uint256 initialSettledAmount0, uint256 initialSettledAmount1) =
            IVTSManager(coreHookAddress).getPositionSettledAmounts(newPositionId);
        BalanceDelta initialSettledBalanceDelta =
            toBalanceDelta(initialSettledAmount0.toInt128(), initialSettledAmount1.toInt128());
        // during seizure, the outstanding RFS amount will be settled, so that would be the total settled amount to use to calculate the fraction to return back as settled amount for the new/liquidated position
        BalanceDelta settledBalanceDeltaForNewPosition =
            add(initialSettledBalanceDelta, LiquidityUtils.negateBalanceDelta(rfsDelta));
        // this is how much would be realized from the seizure, which is basically the fraction of the position that can be seized multiplied by the settled balance delta
        BalanceDelta expectedSettlementFractionDelta =
            LiquidityUtils.calculateLiquidityFraction(settledBalanceDeltaForNewPosition, siezureFractionBPS);
        // Mock the RFS for this position
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.calcRFS.selector, newPositionId),
            // mock the RFS for this position to be open and the balanceDelta to be negative to indicate pending amount to be settled by the mm
            abi.encode(true, rfsDelta)
        );

        // -- seize the new position
        PositionId newPositionIdSeized = positionManager.seize(
            tokenId,
            0,
            LiquidityUtils.safeInt128ToUint256(rfsDelta.amount0()),
            LiquidityUtils.safeInt128ToUint256(rfsDelta.amount1())
        );
        // get the token associated with the new position
        uint256 newTokenId = 3; //third token generated

        PositionMeta memory createdPositionAfterSeizure = positionManager.getPosition(newTokenId, 0);
        uint256 expectedLiquiditySeized = (uint256(positionToSeize.liquidity) * siezureFractionBPS) / 10000;

        // assert that the liquidity of the position to seize is equal to the liquidity of the created position after seizure
        assertEq(expectedLiquiditySeized, uint256(createdPositionAfterSeizure.liquidity));

        // assert that the settlement amount was transferred to the new position
        // get the total settlement amount for the new position
        (uint256 finalSettledAmount0, uint256 finalSettledAmount1) =
            IVTSManager(coreHookAddress).getPositionSettledAmounts(newPositionIdSeized);
        BalanceDelta finalSettledBalanceDeltaForNewPosition =
            toBalanceDelta(finalSettledAmount0.toInt128(), finalSettledAmount1.toInt128());

        // validate the equivalent seized settled liquidity was transferred to the new position's settled amount
        assertEq(finalSettledBalanceDeltaForNewPosition.amount0(), expectedSettlementFractionDelta.amount0());
        assertEq(finalSettledBalanceDeltaForNewPosition.amount1(), expectedSettlementFractionDelta.amount1());
    }
}

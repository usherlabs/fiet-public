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
import {MMActionAdapter as MMA} from "./modules/MMActionAdapter.sol";
import {MarketMakerTestBase} from "./modules/MMTestBase.sol";
import {MarketMaker} from "../src/libraries/MarketMaker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PositionMeta} from "../src/types/Position.sol";
import {PositionId} from "../src/types/Position.sol";
import {IVTSManager} from "../src/interfaces/IVTSManager.sol";
import {MarketVTSConfiguration} from "../src/types/VTS.sol";
import {MockERC20} from "./_mocks/MockERC20.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {IPositionRegistry} from "../src/interfaces/IPositionRegistry.sol";
import {SignalState} from "../src/types/Position.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {IOracleHelper} from "../src/interfaces/IOracleHelper.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract MMPositionManagerTest is MarketTestBase, MarketMakerTestBase {
    using SafeCast for *;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using MarketMaker for MarketMaker.State;
    using StateLibrary for IPoolManager;

    MMPositionManager internal positionManager;
    MarketVTSConfiguration internal marketVTSConfiguration;

    LiquidityCommitmentCertificate internal lcc0;
    LiquidityCommitmentCertificate internal lcc1;

    address guarantor = makeAddr("guarantor");
    uint256 guarantorInitialBalance = 10000e18;

    function setUp() public {
        _setupMarket();
        _setUpMM();
        console.log("setUP() mmPositionManager", address(mmPositionManager));
        positionManager = MMPositionManager(payable(mmPositionManager));
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

        // mock the price oracles to return prices
        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getPricesForLCCPair.selector),
            abi.encode(uint256(1), uint256(1))
        );
        vm.mockCall(
            address(oracleHelper), abi.encodeWithSelector(IOracleHelper.getTotalUsdValue.selector), abi.encode(2)
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
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});

        bytes memory liquiditySignal = abi.encode(liquiditySignal);

        // Get the amount of LCC tokens that will be minted
        (uint160 sqrtPriceX96, int24 currentTick,,) = manager.getSlot0(corePoolKey.toId());
        (uint256 token0AmountMinted, uint256 token1AmountMinted) = LiquidityUtils.calculateEffectiveTokenAmounts(
            sqrtPriceX96,
            currentTick,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            liquidityParams.liquidityDelta
        );

        uint256 pmLcc0BalanceBefore = lcc0.balanceOf(address(manager));
        uint256 pmLcc1BalanceBefore = lcc1.balanceOf(address(manager));
        uint256 proxyCurrency0BalanceBefore = manager.balanceOf(address(proxyHook), proxyPoolKey.currency0.toId());
        uint256 proxyCurrency1BalanceBefore = manager.balanceOf(address(proxyHook), proxyPoolKey.currency1.toId());

        // Setup committed position using helper
        (
            uint256 tokenId,
            PositionId positionId,
            uint256 requiredSettlementAmount0,
            uint256 requiredSettlementAmount1
        ) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            liquiditySignal,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

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

        assertEq(proxyCurrency0BalanceAfter, proxyCurrency0BalanceBefore + requiredSettlementAmount0);
        assertEq(proxyCurrency1BalanceAfter, proxyCurrency1BalanceBefore + requiredSettlementAmount1);

        assertEq(PoolId.unwrap(m.poolId), PoolId.unwrap(corePoolKey.toId()));
        assertEq(m.tickLower, liquidityParams.tickLower);
        assertEq(m.tickUpper, liquidityParams.tickUpper);
        assertEq(m.liquidity, liquidityParams.liquidityDelta);
        // Position owner is the manager contract
        assertEq(m.owner, address(mmPositionManager));
        assertEq(m.isActive, true);
    }

    function testCanSettleToCreatedPosition() public {
        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Setup committed position using helper
        (
            uint256 tokenId,
            PositionId positionId,
            uint256 requiredSettlementAmount0,
            uint256 requiredSettlementAmount1
        ) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            liquiditySignal,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        // get the current vts for this position
        // TODO: Change these tests to either depend on VTSCalculator, or ...
        (uint256 vtsCurrent0BeforeSettlement, uint256 vtsCurrent1BeforeSettlement) =
            IVTSManager(coreHookAddress).calcVTSCurrent(positionId);

        // VTS current from the `IVTSManager` is expressed in 1e18
        // VTS base in the market configuration is expressed in bips
        uint256 vtsCurrent0BeforeSettlementBips = (vtsCurrent0BeforeSettlement * 10000) / 1e18;
        uint256 vtsCurrent1BeforeSettlementBips = (vtsCurrent1BeforeSettlement * 10000) / 1e18;

        // assert the vts before further settlement is equal to the base vts
        assertApproxEqRel(
            vtsCurrent0BeforeSettlementBips, marketVTSConfiguration.token0.baseVTSRate, 1e16, "Price within 1%"
        );
        assertApproxEqRel(
            vtsCurrent1BeforeSettlementBips, marketVTSConfiguration.token1.baseVTSRate, 1e16, "Price within 1%"
        );
        // make a settlement to the position with the base vts, which should double the current VTS for this position
        // -- before making a settlement, we have to approve the position manager to take the tokens from us
        IERC20(lcc0.underlying()).approve(address(mmPositionManager), requiredSettlementAmount0);
        IERC20(lcc1.underlying()).approve(address(mmPositionManager), requiredSettlementAmount1);
        // -- make a settlement to the created position
        MMA.settle(
            positionManager,
            corePoolKey,
            tokenId,
            0,
            int128(int256(requiredSettlementAmount0)),
            int128(int256(requiredSettlementAmount1))
        );

        // get the current vts for this position
        (uint256 vtsCurrent0AfterSettlement, uint256 vtsCurrent1AfterSettlement) =
            IVTSManager(coreHookAddress).calcVTSCurrent(positionId);
        // assert the vts after settlement is equal to the base vts * 2
        // since we basically just made another settlement equal to the base vts, the vts should be doubled
        uint256 vtsCurrent0AfterSettlementBips = (vtsCurrent0AfterSettlement * 10000) / 1e18;
        uint256 vtsCurrent1AfterSettlementBips = (vtsCurrent1AfterSettlement * 10000) / 1e18;

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

        // Setup committed position using helper
        (uint256 tokenId, PositionId positionId,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            liquiditySignal,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        // get current VTS
        (uint256 vtsCurrent0BeforeWithdrawal, uint256 vtsCurrent1BeforeWithdrawal) =
            IVTSManager(coreHookAddress).calcVTSCurrent(positionId);

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
        uint256 preBalanceOfToken0UnderlyingAssetInPM = Currency.wrap(lcc0.underlying()).balanceOf(address(this));
        uint256 preBalanceOfToken1UnderlyingAssetInPM = Currency.wrap(lcc1.underlying()).balanceOf(address(this));

        // withdraw from the position by settling out
        MMA.settle(positionManager, corePoolKey, tokenId, 0, -int128(int256(amount0)), -int128(int256(amount1)));

        // get balance of underlying tokens of position manager after withdrawal
        uint256 postBalanceOfToken0UnderlyingAssetInPM = Currency.wrap(lcc0.underlying()).balanceOf(address(this));
        uint256 postBalanceOfToken1UnderlyingAssetInPM = Currency.wrap(lcc1.underlying()).balanceOf(address(this));

        // validate balance after withdrawal
        assertEq(postBalanceOfToken0UnderlyingAssetInPM, preBalanceOfToken0UnderlyingAssetInPM + amount0);
        assertEq(postBalanceOfToken1UnderlyingAssetInPM, preBalanceOfToken1UnderlyingAssetInPM + amount1);

        // validate vts current reduces after withdrawal
        (uint256 vtsCurrent0AfterWithdrawal, uint256 vtsCurrent1AfterWithdrawal) =
            IVTSManager(coreHookAddress).calcVTSCurrent(positionId);

        assertGt(vtsCurrent0BeforeWithdrawal, vtsCurrent0AfterWithdrawal);
        assertGt(vtsCurrent1BeforeWithdrawal, vtsCurrent1AfterWithdrawal);
    }

    function testCanburnUsingTokenAndIndex() public {
        // get the default market confiration so we can tweak it
        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Setup committed position using helper
        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            liquiditySignal,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        // get underlying asset balance before decommitment
        uint256 token0BalanceBefore = Currency.wrap(lcc0.underlying()).balanceOf(address(this));
        uint256 token1BalanceBefore = Currency.wrap(lcc1.underlying()).balanceOf(address(this));

        // burn
        MMA.burn(positionManager, corePoolKey, tokenId, 0);
        BalanceDelta balanceDelta = toBalanceDelta(0, 0); // effects come via VTS mock and internal settle

        // get underlying asset balance after decommitment
        uint256 token0BalanceAfter = Currency.wrap(lcc0.underlying()).balanceOf(address(this));
        uint256 token1BalanceAfter = Currency.wrap(lcc1.underlying()).balanceOf(address(this));

        assertEq(token0BalanceAfter, token0BalanceBefore + LiquidityUtils.safeInt128ToUint256(balanceDelta.amount0()));
        assertEq(token1BalanceAfter, token1BalanceBefore + LiquidityUtils.safeInt128ToUint256(balanceDelta.amount1()));
    }

    function testCanburnUsingTokenId() public {
        // get the default market confiration so we can tweak it
        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Setup committed position using helper
        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            liquiditySignal,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        // get underlying asset balance before decommitment
        uint256 token0BalanceBefore = Currency.wrap(lcc0.underlying()).balanceOf(address(this));
        uint256 token1BalanceBefore = Currency.wrap(lcc1.underlying()).balanceOf(address(this));

        MMA.decommit(positionManager, corePoolKey, tokenId);

        // get underlying asset balance after decommitment
        uint256 token0BalanceAfter = Currency.wrap(lcc0.underlying()).balanceOf(address(this));
        uint256 token1BalanceAfter = Currency.wrap(lcc1.underlying()).balanceOf(address(this));

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
        (uint160 sqrtPriceX96_2, int24 currentTick_2,,) = manager.getSlot0(corePoolKey.toId());
        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) = LiquidityUtils.calculateEffectiveTokenAmounts(
            sqrtPriceX96_2,
            currentTick_2,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            liquidityParams.liquidityDelta
        );

        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        IERC20(lcc0.underlying()).approve(address(mmPositionManager), requiredSettlementAmount0);
        IERC20(lcc1.underlying()).approve(address(mmPositionManager), requiredSettlementAmount1);

        // commit the position - batch commit and mint
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareCommit(corePoolKey, liquiditySignal);
        actions[1] = MMA.prepareMint(
            corePoolKey,
            1,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            uint256(liquidityParams.liquidityDelta)
        );
        MMA.execute(positionManager, actions);
        PositionId positionId = positionManager.getPositionId(1, 0);
        uint256 tokenId = 1;

        // Mock the RFS for this position
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.calcRFS.selector),
            // mock the RFS for this position to be open and the balanceDelta to be negative to indicate pending amount to be settled by the mm
            abi.encode(true, rfsDelta)
        );

        // mock the seized units for this position (fraction of current liquidity)
        uint256 seizedUnits = (uint256(positionManager.getPosition(tokenId, 0).liquidity) * siezureFractionBPS) / 10000;
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.calcSeizure.selector),
            abi.encode(seizedUnits)
        );

        // mint the underlying assets to the guarantor, and approve the  position manager to take the underlying assets
        MockERC20(lcc0.underlying()).mint(guarantor, guarantorInitialBalance);
        MockERC20(lcc1.underlying()).mint(guarantor, guarantorInitialBalance);

        // act as the guarantor who wants to seize the position partially
        vm.startPrank(guarantor);
        IERC20(lcc0.underlying()).approve(address(mmPositionManager), 100);
        IERC20(lcc1.underlying()).approve(address(mmPositionManager), 100);

        // --- seize the position ---
        PositionMeta memory positionBeforeSeizure = positionManager.getPosition(tokenId, 0);
        // uint256 token1UABeforeSeizure = Currency.wrap(lcc1.underlying()).balanceOf(address(guarantor));
        uint256 lcc0BeforeSeizure = lcc0.balanceOf(address(guarantor));
        // get the initial settled balance delta
        (uint256 initialSettledAmount0, uint256 initialSettledAmount1) =
            IVTSManager(coreHookAddress).getPositionSettledAmounts(positionId);
        BalanceDelta initialSettledBalanceDelta =
            toBalanceDelta(initialSettledAmount0.toInt128(), initialSettledAmount1.toInt128());

        // during seizure, the outstanding amount will be settled, so that would be the total settled amount to use to calculate the fraction to return back
        BalanceDelta settledBalanceDelta = add(initialSettledBalanceDelta, LiquidityUtils.negateBalanceDelta(rfsDelta));
        // expected seized settlement fraction per token (bps-based)
        uint256 seized0 =
            Math.mulDiv(LiquidityUtils.safeInt128ToUint256(settledBalanceDelta.amount0()), siezureFractionBPS, 10000);

        // seize the position
        // settle all the outstanding rfs of token 0
        MMA.seize(positionManager, corePoolKey, tokenId, 0, LiquidityUtils.safeInt128ToUint256(rfsDelta.amount0()), 0);

        // get the balance of the underlying assets after seizure
        uint256 lcc0AfterSeizure = lcc0.balanceOf(address(guarantor));

        // get the expected balance of the underlying assets after seizure
        // seizer receives LCCs, not underlying; ensure LCC balance increased
        assertGt(lcc0AfterSeizure, lcc0BeforeSeizure);

        PositionMeta memory positionAfterSeizure = positionManager.getPosition(tokenId, 0);

        uint256 expectedLiquidityAfterSeizure = uint256(positionBeforeSeizure.liquidity) - seizedUnits;

        // validate liquidity in the position is reduced
        assertEq(uint256(positionAfterSeizure.liquidity), expectedLiquidityAfterSeizure);

        // validate that LCC transfer occurred to seizer was positive (already asserted)

        // expected settlement = initial settlement + rfs delta -  settlement fraction seized
        (uint256 finalSettledAmount0, uint256 finalSettledAmount1) =
            IVTSManager(coreHookAddress).getPositionSettledAmounts(positionId);
        BalanceDelta finalSettledBalanceDelta =
            toBalanceDelta(finalSettledAmount0.toInt128(), finalSettledAmount1.toInt128());
        uint256 expectedRemainingSettlement0ForPosition =
            LiquidityUtils.safeInt128ToUint256(initialSettledBalanceDelta.amount0())
                + LiquidityUtils.safeInt128ToUint256(rfsDelta.amount0()) - seized0;

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
        (uint256 c0_partial, uint256 c1_partial) = LiquidityUtils.calculateCommitmentMaxima(
            liquidityParams.tickLower, liquidityParams.tickUpper, uint128(uint256(liquidityParams.liquidityDelta))
        );
        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) = LiquidityUtils.getBaseSettlementAmounts(
            c0_partial, c1_partial, marketVTSConfiguration.token0.baseVTSRate, marketVTSConfiguration.token1.baseVTSRate
        );

        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        IERC20(lcc0.underlying()).approve(address(mmPositionManager), requiredSettlementAmount0);
        IERC20(lcc1.underlying()).approve(address(mmPositionManager), requiredSettlementAmount1);

        // Batch commit and mint
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareCommit(corePoolKey, liquiditySignal);
        actions[1] = MMA.prepareMint(
            corePoolKey,
            1,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            uint256(liquidityParams.liquidityDelta)
        );
        MMA.execute(positionManager, actions);
        PositionId positionId = positionManager.getPositionId(1, 0);
        uint256 tokenId = 1;

        // Mock the RFS for this position
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.calcRFS.selector),
            // mock the RFS for this position to be open and the balanceDelta to be negative to indicate pending amount to be settled by the mm
            abi.encode(true, rfsDelta)
        );

        // mock the seized units for this position (fraction of current liquidity)
        uint256 seizedUnits = (uint256(positionManager.getPosition(tokenId, 0).liquidity) * seizureFractionBPS) / 10000;
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.calcSeizure.selector),
            abi.encode(seizedUnits)
        );

        // mint the underlying assets to the guarantor, and approve the  position manager to take the underlying assets
        MockERC20(lcc0.underlying()).mint(guarantor, guarantorInitialBalance);
        MockERC20(lcc1.underlying()).mint(guarantor, guarantorInitialBalance);

        // act as the guarantor who wants to seize the position partially
        vm.startPrank(guarantor);
        IERC20(lcc0.underlying()).approve(address(mmPositionManager), 100);
        IERC20(lcc1.underlying()).approve(address(mmPositionManager), 100);

        PositionMeta memory positionBeforeSeizure = positionManager.getPosition(tokenId, 0);
        // uint256 token1UABeforeSeizure = Currency.wrap(lcc1.underlying()).balanceOf(address(guarantor));
        uint256 lcc0BeforeSeizure2 = lcc0.balanceOf(address(guarantor));
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
        MMA.seize(positionManager, corePoolKey, tokenId, 0, amount0ToSettle, 0);
        // expected seized settlement fraction per token (bps-based)
        uint256 seized0 =
            Math.mulDiv(LiquidityUtils.safeInt128ToUint256(settledBalanceDelta.amount0()), seizureFractionBPS, 10000);
        // get the balance of the underlying assets after seizure
        uint256 lcc0AfterSeizure2 = lcc0.balanceOf(address(guarantor));

        // get the expected balance of the underlying assets after seizure
        // assert LCC payout to seizer increased
        assertGt(lcc0AfterSeizure2, lcc0BeforeSeizure2);

        PositionMeta memory positionAfterSeizure = positionManager.getPosition(tokenId, 0);

        uint256 expectedLiquidityAfterSeizure = uint256(positionBeforeSeizure.liquidity) - seizedUnits;

        // validate liquidity in the position is reduced
        assertEq(uint256(positionAfterSeizure.liquidity), expectedLiquidityAfterSeizure);

        // validate LCC payout was positive (already asserted)

        // expected settlement = initial settlement + rfs delta -  settlement fraction seized
        (uint256 finalSettledAmount0, uint256 finalSettledAmount1) =
            IVTSManager(coreHookAddress).getPositionSettledAmounts(positionId);
        BalanceDelta finalSettledBalanceDelta =
            toBalanceDelta(finalSettledAmount0.toInt128(), finalSettledAmount1.toInt128());

        uint256 expectedRemainingSettlement0ForPosition =
            LiquidityUtils.safeInt128ToUint256(initialSettledBalanceDelta.amount0()) + amount0ToSettle - seized0;

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

        BalanceDelta rfsDelta = toBalanceDelta(-100, 0);

        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 c0_full, uint256 c1_full) = LiquidityUtils.calculateCommitmentMaxima(
            liquidityParams.tickLower, liquidityParams.tickUpper, uint128(uint256(liquidityParams.liquidityDelta))
        );
        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) = LiquidityUtils.getBaseSettlementAmounts(
            c0_full, c1_full, marketVTSConfiguration.token0.baseVTSRate, marketVTSConfiguration.token1.baseVTSRate
        );

        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        IERC20(lcc0.underlying()).approve(address(mmPositionManager), requiredSettlementAmount0);
        IERC20(lcc1.underlying()).approve(address(mmPositionManager), requiredSettlementAmount1);

        // Batch commit and mint
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareCommit(corePoolKey, liquiditySignal);
        actions[1] = MMA.prepareMint(
            corePoolKey,
            1,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            uint256(liquidityParams.liquidityDelta)
        );
        MMA.execute(positionManager, actions);
        PositionId positionId = positionManager.getPositionId(1, 0);
        uint256 tokenId = 1;
        // Mock the RFS for this position
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.calcRFS.selector),
            // mock the RFS for this position to be open and the balanceDelta to be negative to indicate pending amount to be settled by the mm
            abi.encode(true, rfsDelta)
        );

        // mock full seized units (entire liquidity)
        uint256 seizedUnitsFull = uint256(positionManager.getPosition(tokenId, 0).liquidity);
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.calcSeizure.selector),
            abi.encode(seizedUnitsFull)
        );

        // mint the underlying assets to the guarantor, and approve the  position manager to take the underlying assets
        MockERC20(lcc0.underlying()).mint(guarantor, guarantorInitialBalance);
        // MockERC20(lcc1.underlying()).mint(guarantor, guarantorInitialBalance);

        // act as the guarantor who wants to seize the position partially
        vm.startPrank(guarantor);
        IERC20(lcc0.underlying()).approve(address(mmPositionManager), 100);
        // ERC20(lcc1.underlying()).approve(address(mmPositionManager), 100);

        // seize the position by settling all of the outstanding RFS amount
        MMA.seize(
            positionManager,
            corePoolKey,
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
        PositionMeta memory positionAfterSeizure = IPositionRegistry(coreHookAddress).getPosition(positionId, false);

        // validate the position is marked as inactive
        assertEq(positionAfterSeizure.isActive, false);
        // validate all the settled amount is seized
        assertEq(LiquidityUtils.safeInt128ToUint256(finalSettledBalanceDelta.amount0()), 0);
    }

    // can seize a position while not being a market maker and settling more than the outstanding RFS amount
    function test_canFully_seizePosition_asNoneMM_withOverSettlement() public {
        // commit to a position
        bytes memory liquiditySignal = abi.encode(liquiditySignal);

        BalanceDelta rfsDelta = toBalanceDelta(-100, 0);

        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 c0_fullover, uint256 c1_fullover) = LiquidityUtils.calculateCommitmentMaxima(
            liquidityParams.tickLower, liquidityParams.tickUpper, uint128(uint256(liquidityParams.liquidityDelta))
        );
        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) = LiquidityUtils.getBaseSettlementAmounts(
            c0_fullover,
            c1_fullover,
            marketVTSConfiguration.token0.baseVTSRate,
            marketVTSConfiguration.token1.baseVTSRate
        );

        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        IERC20(lcc0.underlying()).approve(address(mmPositionManager), requiredSettlementAmount0);
        IERC20(lcc1.underlying()).approve(address(mmPositionManager), requiredSettlementAmount1);

        // Batch commit and mint
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareCommit(corePoolKey, liquiditySignal);
        actions[1] = MMA.prepareMint(
            corePoolKey,
            1,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            uint256(liquidityParams.liquidityDelta)
        );
        MMA.execute(positionManager, actions);
        PositionId positionId = positionManager.getPositionId(1, 0);
        uint256 tokenId = 1;
        // Mock the RFS for this position
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.calcRFS.selector),
            // mock the RFS for this position to be open and the balanceDelta to be negative to indicate pending amount to be settled by the mm
            abi.encode(true, rfsDelta)
        );

        // mock full seized units (entire liquidity)
        uint256 seizedUnitsOver = uint256(positionManager.getPosition(tokenId, 0).liquidity);
        vm.mockCall(
            address(IVTSManager(coreHookAddress)),
            abi.encodeWithSelector(IVTSManager.calcSeizure.selector),
            abi.encode(seizedUnitsOver)
        );

        // mint the underlying assets to the guarantor, and approve the  position manager to take the underlying assets
        MockERC20(lcc0.underlying()).mint(guarantor, guarantorInitialBalance);
        // MockERC20(lcc1.underlying()).mint(guarantor, guarantorInitialBalance);

        // act as the guarantor who wants to seize the position partially
        vm.startPrank(guarantor);
        // seize the position by settling more than the outstanding RFS amount
        uint256 amount0ToSettle = LiquidityUtils.safeInt128ToUint256(rfsDelta.amount0()) + 100;
        IERC20(lcc0.underlying()).approve(address(mmPositionManager), amount0ToSettle);
        // ERC20(lcc1.underlying()).approve(address(mmPositionManager), 100);
        MMA.seize(positionManager, corePoolKey, tokenId, 0, amount0ToSettle, 0);
        // basic cap for fraction bps if needed (no-op here since we mocked full seize units)
        // get the total settlement amount for the position after seizure
        (uint256 finalSettledAmount0, uint256 finalSettledAmount1) =
            IVTSManager(coreHookAddress).getPositionSettledAmounts(positionId);
        BalanceDelta finalSettledBalanceDelta =
            toBalanceDelta(finalSettledAmount0.toInt128(), finalSettledAmount1.toInt128());

        // get the position info after seizure
        PositionMeta memory positionAfterSeizure = IPositionRegistry(coreHookAddress).getPosition(positionId, false);

        // validate the position is marked as inactive
        assertEq(positionAfterSeizure.isActive, false);
        // validate all the settled amount is seized
        assertEq(LiquidityUtils.safeInt128ToUint256(finalSettledBalanceDelta.amount0()), 0);
    }

    // can mint new positions to an existing token id
    function test_canMintPositions_usingExistingTokenId() public {
        // commit to a position
        bytes memory liquiditySignal = abi.encode(liquiditySignal);

        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 c0_mint1, uint256 c1_mint1) = LiquidityUtils.calculateCommitmentMaxima(
            liquidityParams.tickLower, liquidityParams.tickUpper, uint128(uint256(liquidityParams.liquidityDelta))
        );
        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) = LiquidityUtils.getBaseSettlementAmounts(
            c0_mint1, c1_mint1, marketVTSConfiguration.token0.baseVTSRate, marketVTSConfiguration.token1.baseVTSRate
        );

        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        IERC20(lcc0.underlying()).approve(address(mmPositionManager), requiredSettlementAmount0);
        IERC20(lcc1.underlying()).approve(address(mmPositionManager), requiredSettlementAmount1);

        // Batch commit and mint
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareCommit(corePoolKey, liquiditySignal);
        actions[1] = MMA.prepareMint(
            corePoolKey,
            1,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            uint256(liquidityParams.liquidityDelta)
        );
        MMA.execute(positionManager, actions);
        uint256 tokenId = 1;

        // mint a position using this token id
        // approve the position for base settlement
        IERC20(lcc0.underlying()).approve(address(mmPositionManager), requiredSettlementAmount0);
        IERC20(lcc1.underlying()).approve(address(mmPositionManager), requiredSettlementAmount1);

        MMA.mint(
            positionManager,
            corePoolKey,
            tokenId,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            uint256(liquidityParams.liquidityDelta)
        );
        uint256 positionIndex = 0;

        // validate the position is marked as active
        assertEq(positionManager.getPosition(tokenId, positionIndex).isActive, true);

        // validate base settlement for the position is made
        (uint256 finalSettledAmount0, uint256 finalSettledAmount1) = IVTSManager(coreHookAddress)
            .getPositionSettledAmounts(positionManager.getPositionId(tokenId, positionIndex));
        BalanceDelta finalSettledBalanceDelta =
            toBalanceDelta(finalSettledAmount0.toInt128(), finalSettledAmount1.toInt128());
        assertEq(LiquidityUtils.safeInt128ToUint256(finalSettledBalanceDelta.amount0()), requiredSettlementAmount0);
        assertEq(LiquidityUtils.safeInt128ToUint256(finalSettledBalanceDelta.amount1()), requiredSettlementAmount1);
    }

    // make sure the positions must be covered by the total usd value in the signal
    function test_cannotMintInsolventPositions_usingExistingTokenId() public {
        // commit to a position
        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 c0_insolvent, uint256 c1_insolvent) = LiquidityUtils.calculateCommitmentMaxima(
            liquidityParams.tickLower, liquidityParams.tickUpper, uint128(uint256(liquidityParams.liquidityDelta))
        );
        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) = LiquidityUtils.getBaseSettlementAmounts(
            c0_insolvent,
            c1_insolvent,
            marketVTSConfiguration.token0.baseVTSRate,
            marketVTSConfiguration.token1.baseVTSRate
        );

        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        IERC20(lcc0.underlying()).approve(address(mmPositionManager), requiredSettlementAmount0);
        IERC20(lcc1.underlying()).approve(address(mmPositionManager), requiredSettlementAmount1);

        MMA.commit(positionManager, corePoolKey, liquiditySignal);
        uint256 tokenId = 1;

        // mint a position using this token id
        // approve the position for base settlement
        IERC20(lcc0.underlying()).approve(address(mmPositionManager), requiredSettlementAmount0);
        IERC20(lcc1.underlying()).approve(address(mmPositionManager), requiredSettlementAmount1);

        // attempt to mint an amount that exceeds solvency; should revert via InvalidLiquiditySignal (solvency gate)
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLiquiditySignal.selector));
        MMA.mint(
            positionManager,
            corePoolKey,
            tokenId,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            type(uint256).max / 2
        );
    }

    function test_canRenewSignal() public {
        // make a commitment to a position
        bytes memory liquiditySignal = abi.encode(liquiditySignal);

        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 c0_renew, uint256 c1_renew) = LiquidityUtils.calculateCommitmentMaxima(
            liquidityParams.tickLower, liquidityParams.tickUpper, uint128(uint256(liquidityParams.liquidityDelta))
        );
        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) = LiquidityUtils.getBaseSettlementAmounts(
            c0_renew, c1_renew, marketVTSConfiguration.token0.baseVTSRate, marketVTSConfiguration.token1.baseVTSRate
        );

        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        IERC20(lcc0.underlying()).approve(address(mmPositionManager), requiredSettlementAmount0);
        IERC20(lcc1.underlying()).approve(address(mmPositionManager), requiredSettlementAmount1);

        // Batch commit and mint
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareCommit(corePoolKey, liquiditySignal);
        actions[1] = MMA.prepareMint(
            corePoolKey,
            1,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            uint256(liquidityParams.liquidityDelta)
        );
        MMA.execute(positionManager, actions);
        uint256 tokenId = 1;

        // renew the signal
        uint256 newTimestamp = 1000;
        vm.warp(newTimestamp);
        MMA.renew(positionManager, tokenId, abi.encode(renewSignal));

        // get the new signal
        SignalState memory newSignalState = positionManager.getSignalState(tokenId);

        // validate the new signal is the same as the renewed signal
        assertEq(abi.encode(newSignalState.signal), abi.encode(renewSignal));

        // validate the expiry is updated
        assertEq(newSignalState.expiresAt, newTimestamp + signalExpiryInSeconds);
    }

    // can modify an existing position by removing liquidity from it
    function test_canModifyLiquidity_byRemovingLiquidity() public {
        // make a commitment to a position
        bytes memory liquiditySignal = abi.encode(liquiditySignal);

        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 c0_remove, uint256 c1_remove) = LiquidityUtils.calculateCommitmentMaxima(
            liquidityParams.tickLower, liquidityParams.tickUpper, uint128(uint256(liquidityParams.liquidityDelta))
        );
        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) = LiquidityUtils.getBaseSettlementAmounts(
            c0_remove, c1_remove, marketVTSConfiguration.token0.baseVTSRate, marketVTSConfiguration.token1.baseVTSRate
        );

        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        IERC20(lcc0.underlying()).approve(address(mmPositionManager), requiredSettlementAmount0);
        IERC20(lcc1.underlying()).approve(address(mmPositionManager), requiredSettlementAmount1);

        // Batch commit and mint
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareCommit(corePoolKey, liquiditySignal);
        actions[1] = MMA.prepareMint(
            corePoolKey,
            1,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            uint256(liquidityParams.liquidityDelta)
        );
        MMA.execute(positionManager, actions);
        PositionId positionId = positionManager.getPositionId(1, 0);
        uint256 tokenId = 1;
        uint256 positionIndex = 0;
        int256 liquidityDelta = -1e5;

        // get the details of the position after commit
        PositionMeta memory positionAfterCommit = positionManager.getPosition(tokenId, positionIndex);
        (uint256 s0, uint256 s1) = IVTSManager(coreHookAddress).getPositionSettledAmounts(positionId);
        // get the balance of the underlying assets after commit
        uint256 lcc0BalanceAfterCommit = Currency.wrap(lcc0.underlying()).balanceOf(address(this));
        uint256 lcc1BalanceAfterCommit = Currency.wrap(lcc1.underlying()).balanceOf(address(this));

        // remove liquidity from the position
        MMA.decrease(positionManager, corePoolKey, tokenId, positionIndex, uint256(-liquidityDelta));

        // get the details of the position after modify liquidity
        PositionMeta memory positionAfterModifyLiquidity = positionManager.getPosition(tokenId, positionIndex);
        // get the balance of the underlying assets after commit
        uint256 lcc0BalanceAfterModifyLiquidity = Currency.wrap(lcc0.underlying()).balanceOf(address(this));
        uint256 lcc1BalanceAfterModifyLiquidity = Currency.wrap(lcc1.underlying()).balanceOf(address(this));

        // validate the position's liquidity is reduced
        assertEq(positionAfterModifyLiquidity.liquidity, positionAfterCommit.liquidity + liquidityDelta);

        // validate user is credited with the underlying assets
        //  get the fraction of the liquidity to take out of the position
        uint256 liquidityFraction = Math.mulDiv(uint256(-liquidityDelta), 1e18, uint256(positionAfterCommit.liquidity));
        // compute fraction of delta inline per token
        BalanceDelta underlyingAssetFraction = toBalanceDelta(
            int128(int256(Math.mulDiv(s0, liquidityFraction, 1e18))),
            int128(int256(Math.mulDiv(s1, liquidityFraction, 1e18)))
        );
        // validate mmpm holds no token balance
        assertEq(
            lcc0BalanceAfterModifyLiquidity,
            lcc0BalanceAfterCommit + LiquidityUtils.safeInt128ToUint256(underlyingAssetFraction.amount0())
        );
        assertEq(
            lcc1BalanceAfterModifyLiquidity,
            lcc1BalanceAfterCommit + LiquidityUtils.safeInt128ToUint256(underlyingAssetFraction.amount1())
        );
    }

    function test_canModifyLiquidity_byAddingLiquidity() public {
        // make a commitment to a position
        bytes memory liquiditySignal = abi.encode(liquiditySignal);

        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 c0_add, uint256 c1_add) = LiquidityUtils.calculateCommitmentMaxima(
            liquidityParams.tickLower, liquidityParams.tickUpper, uint128(uint256(liquidityParams.liquidityDelta))
        );
        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) = LiquidityUtils.getBaseSettlementAmounts(
            c0_add, c1_add, marketVTSConfiguration.token0.baseVTSRate, marketVTSConfiguration.token1.baseVTSRate
        );

        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        IERC20(lcc0.underlying()).approve(address(mmPositionManager), requiredSettlementAmount0);
        IERC20(lcc1.underlying()).approve(address(mmPositionManager), requiredSettlementAmount1);

        // Batch commit and mint
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareCommit(corePoolKey, liquiditySignal);
        actions[1] = MMA.prepareMint(
            corePoolKey,
            1,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            uint256(liquidityParams.liquidityDelta)
        );
        MMA.execute(positionManager, actions);
        uint256 tokenId = 1;
        uint256 positionIndex = 0;
        int256 liquidityDelta = 1e5;

        ModifyLiquidityParams memory modifyLiquidityParams = ModifyLiquidityParams({
            tickLower: liquidityParams.tickLower,
            tickUpper: liquidityParams.tickUpper,
            liquidityDelta: liquidityDelta,
            salt: bytes32(0)
        });

        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 c0_mint2, uint256 c1_mint2) = LiquidityUtils.calculateCommitmentMaxima(
            modifyLiquidityParams.tickLower,
            modifyLiquidityParams.tickUpper,
            uint128(uint256(modifyLiquidityParams.liquidityDelta))
        );
        (requiredSettlementAmount0, requiredSettlementAmount1) = LiquidityUtils.getBaseSettlementAmounts(
            c0_mint2, c1_mint2, marketVTSConfiguration.token0.baseVTSRate, marketVTSConfiguration.token1.baseVTSRate
        );

        // Approve the position manager to take the base/minimum underlying liquidity to create to the position
        IERC20(lcc0.underlying()).approve(address(mmPositionManager), requiredSettlementAmount0);
        IERC20(lcc1.underlying()).approve(address(mmPositionManager), requiredSettlementAmount1);

        // get the details of the position after add liquidity
        PositionMeta memory positionAfterCommit = positionManager.getPosition(tokenId, positionIndex);

        // add liquidity to the position
        PositionMeta memory posBounds2 = positionManager.getPosition(tokenId, positionIndex);
        MMA.mint(
            positionManager, corePoolKey, tokenId, posBounds2.tickLower, posBounds2.tickUpper, uint256(liquidityDelta)
        );

        // validate liquidity is added to the position
        assertEq(
            positionManager.getPosition(tokenId, positionIndex).liquidity,
            positionAfterCommit.liquidity + liquidityDelta
        );
    }

    // TODO: Recreate this once the new insolvent() is implemented
    // function test_canSeizeInsolventPosition() public {
    //     // make a commitment to a position
    //     bytes memory encodedLiquiditySignal = abi.encode(liquiditySignal);

    //     ModifyLiquidityParams memory liquidityParams =
    //         ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

    //     // Get amount of underlying liquidity to transfer from the issuer to the lcc
    //     (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) =
    //         LiquidityUtils.getBaseSettlementAmounts(liquidityParams, marketVTSConfiguration);

    //     // Approve the position manager to take the base/minimum underlying liquidity to create to the position
    //     ERC20(lcc0.underlying()).approve(address(mmPositionManager), requiredSettlementAmount0);
    //     ERC20(lcc1.underlying()).approve(address(mmPositionManager), requiredSettlementAmount1);

    //     MMA.commit(positionManager, corePoolKey, encodedLiquiditySignal);
    //     MMA.mint(
    //         positionManager,
    //         corePoolKey,
    //         1,
    //         liquidityParams.tickLower,
    //         liquidityParams.tickUpper,
    //         uint256(liquidityParams.liquidityDelta)
    //     );
    //     uint256 tokenId = 1;

    //     // get the position before reallocation
    //     PositionMeta memory positionBeforeReallocation = positionManager.getPosition(tokenId, 0);
    //     // prepare an insolvent renewal (force deficit by returning 0 USD value)
    //     uint256 newSignalUSDValue = 0;

    //     // mock the signal manager to return an insolvent response
    //     vm.mockCall(
    //         address(signalManager),
    //         abi.encodeWithSelector(signalManager.renewLiquiditySignal.selector),
    //         abi.encode(newSignalUSDValue, signalExpiryInSeconds)
    //     );

    //     address advancer = liquiditySignal.mmState.advancer;
    //     vm.prank(address(advancer));
    //     // reallocate the position by mocking an insolvent(by 20%) response from the signal manager
    //     // seizeCommitment remains a dedicated call: dispatch via action adapter is not defined; keep direct if present
    //     uint256 deficitFraction = positionManager.seizeCommitment(corePoolKey, tokenId, encodedLiquiditySignal);
    //     vm.stopPrank();

    //     // get the position after reallocation
    //     PositionMeta memory positionAfterReallocation = positionManager.getPosition(tokenId, 0);
    //     // validate the liquidity in the position is reduced by 20%
    //     uint256 expectedLiquidityAfterReallocation = uint256(positionBeforeReallocation.liquidity)
    //         - Math.mulDiv(uint256(positionBeforeReallocation.liquidity), deficitFraction, LiquidityUtils.ONE_BIP);
    //     assertEq(uint256(positionAfterReallocation.liquidity), expectedLiquidityAfterReallocation);
    // }
}

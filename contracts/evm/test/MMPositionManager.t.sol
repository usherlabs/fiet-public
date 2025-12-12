// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
// solhint-disable max-line-length

import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
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
import {PositionId} from "../src/types/Position.sol";
import {MarketVTSConfiguration} from "../src/types/VTS.sol";
import {MockERC20} from "./_mocks/MockERC20.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {IOracleHelper} from "../src/interfaces/IOracleHelper.sol";
import {Position} from "../src/types/Position.sol";
import {RFSCheckpoint} from "../src/types/Checkpoint.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {LiquiditySignal} from "../src/types/Commit.sol";
import {ILiquidityHub} from "../src/interfaces/ILiquidityHub.sol";

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

    Currency internal lccCurrency0;
    Currency internal lccCurrency1;

    address guarantor = makeAddr("guarantor");
    uint256 guarantorInitialBalance = 10000e18;

    function setUp() public {
        _setupMarket();
        _setUpMM();
        console.log("setUP() mmPositionManager", address(mmPositionManager));
        positionManager = MMPositionManager(payable(mmPositionManager));
        lcc0 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency2)));
        lcc1 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency3)));
        lccCurrency0 = Currency.wrap(address(lcc0));
        lccCurrency1 = Currency.wrap(address(lcc1));

        marketVTSConfiguration = vtsOrchestrator.getMarketVTSConfiguration(corePoolKey.toId());

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
            abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector),
            abi.encode(uint256(1), uint256(1))
        );
        // supply enough
        vm.mockCall(
            address(oracleHelper), abi.encodeWithSelector(IOracleHelper.getTotalValue.selector), abi.encode(1e18)
        );
    }

    function testCanAddLiquidityToCorePool() public {
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function testCanCommitAndMintPosition() public {
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
            vtsOrchestrator,
            corePoolKey,
            liquiditySignal,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        // Get the position from the vts orchestrator
        Position memory position = vtsOrchestrator.getPosition(positionId);
        // In the new architecture, position owner is MMPositionManager (not VTSOrchestrator)
        assertEq(position.owner, address(positionManager));
        // Validate the owner of the NFT is the caller of the function
        assertEq(positionManager.ownerOf(tokenId), address(this));

        assertEq(PoolId.unwrap(position.poolId), PoolId.unwrap(corePoolKey.toId()));
        assertEq(position.commitId, tokenId);
        assertEq(position.tickLower, liquidityParams.tickLower);
        assertEq(position.tickUpper, liquidityParams.tickUpper);
        // Validate the amount of liquidity has been added to the position
        assertEq(uint256(position.liquidity), uint256(liquidityParams.liquidityDelta));
        assertEq(position.isActive, true);

        uint256 pmLcc0BalanceAfter = lcc0.balanceOf(address(manager));
        uint256 pmLcc1BalanceAfter = lcc1.balanceOf(address(manager));

        // validate underlying tokens have been transferred to proxy pool and proxy hook has claim tokens
        uint256 proxyCurrency0BalanceAfter = manager.balanceOf(address(proxyHook), proxyPoolKey.currency0.toId());
        uint256 proxyCurrency1BalanceAfter = manager.balanceOf(address(proxyHook), proxyPoolKey.currency1.toId());

        console.log("requiredSettlementAmount0", requiredSettlementAmount0);
        console.log("requiredSettlementAmount1", requiredSettlementAmount1);

        console.log("token0AmountMinted", token0AmountMinted);
        console.log("token1AmountMinted", token1AmountMinted);

        console.log("pmLcc0BalanceBefore", pmLcc0BalanceBefore);
        console.log("pmLcc0BalanceAfter", pmLcc0BalanceAfter);

        console.log("pmLcc1BalanceAfter", pmLcc1BalanceAfter);
        console.log("pmLcc1BalanceBefore", pmLcc1BalanceBefore);

        console.log("proxyCurrency0BalanceBefore", proxyCurrency0BalanceBefore);
        console.log("proxyCurrency0BalanceBefore", proxyCurrency0BalanceBefore);

        console.log("proxyCurrency0BalanceAfter", proxyCurrency0BalanceAfter);
        console.log("proxyCurrency1BalanceAfter", proxyCurrency1BalanceAfter);

        // TODO: implement Fees accounting here to account for fees in token minted vs token transferred to the pm
        // this would account for the exact tokens rather than doing a greater than check

        // validate lcc liquidity has been added to the core pool
        assertGt(pmLcc0BalanceAfter, pmLcc0BalanceBefore);
        assertGt(pmLcc1BalanceAfter, pmLcc1BalanceBefore);

        assertGt(proxyCurrency0BalanceAfter, proxyCurrency0BalanceBefore);
        assertGt(proxyCurrency1BalanceAfter, proxyCurrency1BalanceBefore);
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
            vtsOrchestrator,
            corePoolKey,
            liquiditySignal,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        // get the current vts for this position
        // make a settlement to the position with the base vts, which should double the current VTS for this position
        // -- before making a settlement, we have to approve the position manager to take the tokens from us
        IERC20(lcc0.underlying()).approve(address(vtsOrchestrator), requiredSettlementAmount0);
        IERC20(lcc1.underlying()).approve(address(vtsOrchestrator), requiredSettlementAmount1);

        // log vts before settlement
        (uint256 vtsCurrent0BeforeSettlement, uint256 vtsCurrent1BeforeSettlement) =
            vtsOrchestrator.calcVTSCurrent(positionId);
        console.log("vtsCurrent0BeforeSettlement", vtsCurrent0BeforeSettlement);
        console.log("vtsCurrent1BeforeSettlement", vtsCurrent1BeforeSettlement);

        // -- make a settlement to the created position
        MMA.settle(
            positionManager,
            corePoolKey,
            tokenId,
            0,
            -int128(int256(requiredSettlementAmount0)),
            -int128(int256(requiredSettlementAmount1))
        );

        // get the current vts for this position
        (uint256 vtsCurrent0AfterSettlement, uint256 vtsCurrent1AfterSettlement) =
            vtsOrchestrator.calcVTSCurrent(positionId);
        console.log("vtsCurrent0AfterSettlement", vtsCurrent0AfterSettlement);
        console.log("vtsCurrent1AfterSettlement", vtsCurrent1AfterSettlement);

        // since we basically just made another settlement equal to the base vts, the vts should be doubled
        uint256 vtsCurrent0AfterSettlementBips = (vtsCurrent0AfterSettlement * 10000) / 1e18;
        uint256 vtsCurrent1AfterSettlementBips = (vtsCurrent1AfterSettlement * 10000) / 1e18;

        console.log("vtsCurrent0AfterSettlementBips", vtsCurrent0AfterSettlementBips);
        console.log("vtsCurrent1AfterSettlementBips", vtsCurrent1AfterSettlementBips);
        console.log("marketVTSConfiguration.token0.baseVTSRate", marketVTSConfiguration.token0.baseVTSRate);
        console.log("marketVTSConfiguration.token1.baseVTSRate", marketVTSConfiguration.token1.baseVTSRate);

        assertApproxEqRel(
            vtsCurrent0AfterSettlementBips, marketVTSConfiguration.token0.baseVTSRate, 1e16, "Price within 1%"
        );
        assertApproxEqRel(
            vtsCurrent1AfterSettlementBips, marketVTSConfiguration.token1.baseVTSRate, 1e16, "Price within 1%"
        );
    }

    function testCanWithdrawFromSettledPosition() public {
        // get the default market confiration so we can tweak it
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
            vtsOrchestrator,
            corePoolKey,
            liquiditySignal,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        // get the current vts for this position
        (uint256 vtsCurrent0BeforeSettlement, uint256 vtsCurrent1BeforeSettlement) =
            vtsOrchestrator.calcVTSCurrent(positionId);
        console.log("vtsCurrent0BeforeSettlement", vtsCurrent0BeforeSettlement);
        console.log("vtsCurrent1BeforeSettlement", vtsCurrent1BeforeSettlement);

        uint256 settlementAmount0 = requiredSettlementAmount0 * 3;
        uint256 settlementAmount1 = requiredSettlementAmount1 * 3;
        // make a settlement for the position
        IERC20(lcc0.underlying()).approve(address(vtsOrchestrator), settlementAmount0);
        IERC20(lcc1.underlying()).approve(address(vtsOrchestrator), settlementAmount1);
        // -- make a settlement to the created position
        MMA.settle(
            positionManager,
            corePoolKey,
            tokenId,
            0,
            -int128(int256(settlementAmount0)),
            -int128(int256(settlementAmount1))
        );

        // get the current vts for this position
        (uint256 vtsCurrent0AfterSettlement, uint256 vtsCurrent1AfterSettlement) =
            vtsOrchestrator.calcVTSCurrent(positionId);
        console.log("vtsCurrent0AfterSettlement", vtsCurrent0AfterSettlement);
        console.log("vtsCurrent1AfterSettlement", vtsCurrent1AfterSettlement);

        // get balance of underlying tokens of position manager
        uint256 preBalanceOfToken0UnderlyingAssetInPM = Currency.wrap(lcc0.underlying()).balanceOf(address(this));
        uint256 preBalanceOfToken1UnderlyingAssetInPM = Currency.wrap(lcc1.underlying()).balanceOf(address(this));

        console.log("========================");
        // validate vts current before withdrawal
        (uint256 vtsCurrent0BeforeWithdrawal, uint256 vtsCurrent1BeforeWithdrawal) =
            vtsOrchestrator.calcVTSCurrent(positionId);

        // withdraw from the position by settling out
        uint256 amount0 = 100;
        uint256 amount1 = 100;
        MMA.settle(positionManager, corePoolKey, tokenId, 0, int128(int256(amount0)), int128(int256(amount1)));

        // get the current vts for this position after withdrawal
        (uint256 vtsCurrent0AfterWithdrawal, uint256 vtsCurrent1AfterWithdrawal) =
            vtsOrchestrator.calcVTSCurrent(positionId);
        console.log("vtsCurrent0AfterWithdrawal", vtsCurrent0AfterWithdrawal);
        console.log("vtsCurrent1AfterWithdrawal", vtsCurrent1AfterWithdrawal);

        // get balance of underlying tokens of position manager after withdrawal
        uint256 postBalanceOfToken0UnderlyingAssetInPM = Currency.wrap(lcc0.underlying()).balanceOf(address(this));
        uint256 postBalanceOfToken1UnderlyingAssetInPM = Currency.wrap(lcc1.underlying()).balanceOf(address(this));

        console.log("preBalanceOfToken0UnderlyingAssetInPM", preBalanceOfToken0UnderlyingAssetInPM);
        console.log("preBalanceOfToken1UnderlyingAssetInPM", preBalanceOfToken1UnderlyingAssetInPM);
        console.log("postBalanceOfToken0UnderlyingAssetInPM", postBalanceOfToken0UnderlyingAssetInPM);
        console.log("postBalanceOfToken1UnderlyingAssetInPM", postBalanceOfToken1UnderlyingAssetInPM);

        // validate balance after withdrawal
        assertEq(postBalanceOfToken0UnderlyingAssetInPM, preBalanceOfToken0UnderlyingAssetInPM + amount0);
        assertEq(postBalanceOfToken1UnderlyingAssetInPM, preBalanceOfToken1UnderlyingAssetInPM + amount1);

        assertGt(vtsCurrent0BeforeWithdrawal, vtsCurrent0AfterWithdrawal);
        assertGt(vtsCurrent1BeforeWithdrawal, vtsCurrent1AfterWithdrawal);
    }

    function testCanburnPositionUsingTokenAndIndex() public {
        // get the default market confiration so we can tweak it
        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Setup committed position using helper
        (uint256 tokenId,, uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) = _setupCommittedPosition(
            positionManager,
            vtsOrchestrator,
            corePoolKey,
            liquiditySignal,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        uint256 settlementAmount0 = requiredSettlementAmount0 * 3;
        uint256 settlementAmount1 = requiredSettlementAmount1 * 3;
        // make a settlement for the position
        IERC20(lcc0.underlying()).approve(address(vtsOrchestrator), settlementAmount0);
        IERC20(lcc1.underlying()).approve(address(vtsOrchestrator), settlementAmount1);
        // -- make a settlement to the created position
        MMA.settle(
            positionManager,
            corePoolKey,
            tokenId,
            0,
            -int128(int256(settlementAmount0)),
            -int128(int256(settlementAmount1))
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

    function testCanDecommitUsingTokenId() public {
        // get the default market confiration so we can tweak it
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
            vtsOrchestrator,
            corePoolKey,
            liquiditySignal,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        // settle for the position
        uint256 settlementAmount0 = requiredSettlementAmount0 * 3;
        uint256 settlementAmount1 = requiredSettlementAmount1 * 3;
        // make a settlement for the position
        IERC20(lcc0.underlying()).approve(address(vtsOrchestrator), settlementAmount0);
        IERC20(lcc1.underlying()).approve(address(vtsOrchestrator), settlementAmount1);
        // -- make a settlement to the created position
        MMA.settle(
            positionManager,
            corePoolKey,
            tokenId,
            0,
            -int128(int256(settlementAmount0)),
            -int128(int256(settlementAmount1))
        );

        // get total settlement for position from mmpm
        BalanceDelta settlementDeltaBeforeDecommit =
            vtsOrchestrator.getUnderlyingDeltaPair(address(this), lccCurrency0, lccCurrency1);

        console.log("settlementDeltaBeforeDecommit.amount0()", settlementDeltaBeforeDecommit.amount0());
        console.log("settlementDeltaBeforeDecommit.amount1()", settlementDeltaBeforeDecommit.amount1());

        // get underlying asset balance before decommitment
        uint256 token0BalanceBefore = Currency.wrap(lcc0.underlying()).balanceOf(address(this));
        uint256 token1BalanceBefore = Currency.wrap(lcc1.underlying()).balanceOf(address(this));
        console.log("===== start decommit ======");
        // MMA.decommit(positionManager, corePoolKey, tokenId);
        _decommitAndWithdrawDeltas(positionManager, corePoolKey, tokenId, 0, false);

        BalanceDelta settlementDeltaAfterDecommit =
            vtsOrchestrator.getUnderlyingDeltaPair(address(this), lccCurrency0, lccCurrency1);

        // get underlying asset balance after decommitment
        uint256 token0BalanceAfter = Currency.wrap(lcc0.underlying()).balanceOf(address(this));
        uint256 token1BalanceAfter = Currency.wrap(lcc1.underlying()).balanceOf(address(this));

        // Validate the underlying tokens were redeemed and thus the balance of the caller has increased
        assertGt(token0BalanceAfter, token0BalanceBefore);
        assertGt(token1BalanceAfter, token1BalanceBefore);

        console.log("settlementDeltaBeforeDecommit.amount0()", settlementDeltaBeforeDecommit.amount0());
        console.log("settlementDeltaBeforeDecommit.amount1()", settlementDeltaBeforeDecommit.amount1());

        // validate that after settlement the settlement delta is 0
        assertEq(settlementDeltaAfterDecommit.amount0(), 0);
        assertEq(settlementDeltaAfterDecommit.amount1(), 0);
    }

    function testCanIncreaseLiquidityPosition() public {
        // get the default market confiration so we can tweak it
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
            vtsOrchestrator,
            corePoolKey,
            liquiditySignal,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        uint256 positionIndex = 0;

        // over settle to the position
        uint256 settlementAmount0 = requiredSettlementAmount0 * 3;
        uint256 settlementAmount1 = requiredSettlementAmount1 * 3;
        // make a settlement for the position
        IERC20(lcc0.underlying()).approve(address(vtsOrchestrator), settlementAmount0);
        IERC20(lcc1.underlying()).approve(address(vtsOrchestrator), settlementAmount1);
        // -- make a settlement to the created position
        MMA.settle(
            positionManager,
            corePoolKey,
            tokenId,
            positionIndex,
            -int128(int256(settlementAmount0)),
            -int128(int256(settlementAmount1))
        );

        (Position memory positionBeforeIncrease,) = positionManager.getPosition(tokenId, positionIndex);

        // increase the liquidity in the position
        uint256 liquidityToIncrease = 1000;
        MMA.increase(
            positionManager,
            corePoolKey,
            tokenId,
            positionIndex,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            liquidityToIncrease
        );

        // validate the liquidity in the position is increased
        (Position memory positionAfterIncrease,) = positionManager.getPosition(tokenId, positionIndex);
        assertEq(
            uint256(positionAfterIncrease.liquidity), uint256(positionBeforeIncrease.liquidity) + liquidityToIncrease
        );
    }

    function testCanDecreasePositionAndMintNewOneFromDeltas() public {
        // get the default market confiration so we can tweak it
        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Setup committed position using helper
        (uint256 tokenId,, uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) = _setupCommittedPosition(
            positionManager,
            vtsOrchestrator,
            corePoolKey,
            liquiditySignal,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        uint256 positionIndex = 0;

        // over settle to the position
        uint256 settlementAmount0 = requiredSettlementAmount0 * 1000000;
        uint256 settlementAmount1 = requiredSettlementAmount1 * 1000000;
        // make a settlement for the position
        IERC20(lcc0.underlying()).approve(address(vtsOrchestrator), settlementAmount0);
        IERC20(lcc1.underlying()).approve(address(vtsOrchestrator), settlementAmount1);
        // -- make a settlement to the created position
        MMA.settle(
            positionManager,
            corePoolKey,
            tokenId,
            positionIndex,
            -int128(int256(settlementAmount0)),
            -int128(int256(settlementAmount1))
        );

        (Position memory positionBeforeDecrease,) = positionManager.getPosition(tokenId, positionIndex);

        // increase the liquidity in the position
        uint256 liquidityToDecrease = 10000000;
        console.log("----- decreasing --------");

        _decreaseAndMintPositionFromDeltas(
            positionManager,
            corePoolKey,
            tokenId,
            positionIndex,
            liquidityToDecrease,
            liquidityParams.tickLower,
            liquidityParams.tickUpper
        );

        // validate the liquidity in the position is decreased
        (Position memory positionAfterIncrease,) = positionManager.getPosition(tokenId, positionIndex);
        assertEq(
            uint256(positionAfterIncrease.liquidity), uint256(positionBeforeDecrease.liquidity) - liquidityToDecrease
        );

        // validate the new position was created with the new ticks provided
        uint256 newPositionIndex = 1;
        (Position memory newPosition,) = positionManager.getPosition(tokenId, newPositionIndex);
        assertEq(newPosition.tickLower, liquidityParams.tickLower);
        assertEq(newPosition.tickUpper, liquidityParams.tickUpper);
    }

    function testCanDecreasePositionAndSettlePositionFromDelta() public {
        // get the default market confiration so we can tweak it
        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Setup committed position using helper
        (uint256 tokenId,, uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) = _setupCommittedPosition(
            positionManager,
            vtsOrchestrator,
            corePoolKey,
            liquiditySignal,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        uint256 positionIndex = 0;

        // over settle to the position
        uint256 settlementAmount0 = requiredSettlementAmount0 * 1000000;
        uint256 settlementAmount1 = requiredSettlementAmount1 * 1000000;
        // make a settlement for the position
        IERC20(lcc0.underlying()).approve(address(vtsOrchestrator), settlementAmount0);
        IERC20(lcc1.underlying()).approve(address(vtsOrchestrator), settlementAmount1);
        // -- make a settlement to the created position
        MMA.settle(
            positionManager,
            corePoolKey,
            tokenId,
            positionIndex,
            -int128(int256(settlementAmount0)),
            -int128(int256(settlementAmount1))
        );

        // create a new position using the decrease and mint new position
        uint256 liquidityToDecrease = 10000000;
        uint256 newPositionIndex = 1;
        _decreaseAndMintPositionFromDeltas(
            positionManager,
            corePoolKey,
            tokenId,
            positionIndex,
            liquidityToDecrease,
            liquidityParams.tickLower,
            liquidityParams.tickUpper
        );

        // get settlement amounts for this newly created position
        PositionId newPositionId = vtsOrchestrator.getPositionId(tokenId, newPositionIndex);
        (uint256 newPositionSettledAmount0Before, uint256 newPositionSettledAmount1Before) =
            vtsOrchestrator.getPositionSettledAmounts(newPositionId);

        // get liquidity amount for the position to be reduced
        (Position memory positionBeforeDecrease,) = vtsOrchestrator.getPosition(tokenId, positionIndex);

        // decrease from one position and settle to another position
        _decreaseAndSettlePositionFromDeltas(
            positionManager, corePoolKey, tokenId, positionIndex, newPositionIndex, liquidityToDecrease, true
        );

        // get settlement amounts for this newly created position
        (uint256 newPositionSettledAmount0After, uint256 newPositionSettledAmount1After) =
            vtsOrchestrator.getPositionSettledAmounts(newPositionId);

        // get liquidity amount for the position to be reduced
        (Position memory positionAfterDecrease,) = vtsOrchestrator.getPosition(tokenId, positionIndex);

        // assert that settlement is increased for the new position after `decreaseAndSettlePositionFromDeltas`
        assertGt(newPositionSettledAmount0After, newPositionSettledAmount0Before);
        assertGt(newPositionSettledAmount1After, newPositionSettledAmount1Before);

        // assert that the liquidity is decreased for the position to be reduced
        assertEq(
            uint256(positionAfterDecrease.liquidity), uint256(positionBeforeDecrease.liquidity) - liquidityToDecrease
        );
    }

    function testCanDecreasePositionAndIncreasePositionFromDelta() public {
        // get the default market confiration so we can tweak it
        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Setup committed position using helper
        (uint256 tokenId,, uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) = _setupCommittedPosition(
            positionManager,
            vtsOrchestrator,
            corePoolKey,
            liquiditySignal,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        uint256 positionIndex = 0;

        // over settle to the position
        uint256 settlementAmount0 = requiredSettlementAmount0 * 1000000;
        uint256 settlementAmount1 = requiredSettlementAmount1 * 1000000;
        // make a settlement for the position
        IERC20(lcc0.underlying()).approve(address(vtsOrchestrator), settlementAmount0);
        IERC20(lcc1.underlying()).approve(address(vtsOrchestrator), settlementAmount1);
        // -- make a settlement to the created position
        MMA.settle(
            positionManager,
            corePoolKey,
            tokenId,
            positionIndex,
            -int128(int256(settlementAmount0)),
            -int128(int256(settlementAmount1))
        );

        // create a new position using the decrease and mint new position
        uint256 liquidityToDecrease = 10000000;
        uint256 newPositionIndex = 1;
        _decreaseAndMintPositionFromDeltas(
            positionManager,
            corePoolKey,
            tokenId,
            positionIndex,
            liquidityToDecrease,
            liquidityParams.tickLower,
            liquidityParams.tickUpper
        );

        // get liquidity amounts before decrease and increase
        (Position memory positionBeforeDecrease,) = vtsOrchestrator.getPosition(tokenId, positionIndex);
        (Position memory positionBeforeIncrease,) = vtsOrchestrator.getPosition(tokenId, newPositionIndex);

        // decrease from one position and increase another position using deltas
        _decreaseAndIncreasePositionFromDeltas(
            positionManager,
            corePoolKey,
            tokenId,
            positionIndex,
            newPositionIndex,
            liquidityToDecrease,
            liquidityParams.tickLower,
            liquidityParams.tickUpper
        );

        // get liquidity amounts after decrease and increase
        (Position memory positionAfterDecrease,) = vtsOrchestrator.getPosition(tokenId, positionIndex);
        (Position memory positionAfterIncrease,) = vtsOrchestrator.getPosition(tokenId, newPositionIndex);

        // assert that the liquidity is decreased for the position to be reduced
        assertEq(
            uint256(positionAfterDecrease.liquidity), uint256(positionBeforeDecrease.liquidity) - liquidityToDecrease
        );

        // assert that the liquidity is increased for the target position
        assertGt(
            uint256(positionAfterIncrease.liquidity),
            uint256(positionBeforeIncrease.liquidity),
            "Target position liquidity should increase"
        );
    }

    function testCanExtendGracePeriod() public {
        // get the default market confiration so we can tweak it
        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Setup committed position using helper
        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            vtsOrchestrator,
            corePoolKey,
            liquiditySignal,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        uint256 positionIndex = 0;

        // extend the grace period of the commitment
        bytes memory settlementProof = abi.encode(1);
        uint8 settlementTokenIndex0 = 0;
        uint8 settlementTokenIndex1 = 1;
        uint32 verifierIndex = 0;

        // mock the call made to the settlement observer to verify the settlement proof
        vm.mockCall(
            address(settlementObserver),
            abi.encodeWithSelector(settlementObserver.verifySettlementProof.selector),
            abi.encode(true)
        );

        PositionId positionId = vtsOrchestrator.getPositionId(tokenId, positionIndex);

        // get the checkpoint of the position
        RFSCheckpoint memory checkpointBefore = vtsOrchestrator.positionToCheckpoint(positionId);
        vtsOrchestrator.positionToCheckpoint(positionId);

        // extend the grace period of both tokens in the market
        MMA.extendGracePeriod(
            positionManager, corePoolKey, tokenId, positionIndex, settlementTokenIndex0, verifierIndex, settlementProof
        );
        MMA.extendGracePeriod(
            positionManager, corePoolKey, tokenId, positionIndex, settlementTokenIndex1, verifierIndex, settlementProof
        );

        // validate the extension
        RFSCheckpoint memory checkpointAfter = vtsOrchestrator.positionToCheckpoint(positionId);
        vtsOrchestrator.positionToCheckpoint(positionId);

        console.log("gracePeriodExtension0Before", checkpointBefore.gracePeriodExtension0);
        console.log("gracePeriodExtension1Before", checkpointBefore.gracePeriodExtension1);
        console.log("gracePeriodExtension0After", checkpointAfter.gracePeriodExtension0);
        console.log("gracePeriodExtension1After", checkpointAfter.gracePeriodExtension1);
        assertGt(checkpointAfter.gracePeriodExtension0, checkpointBefore.gracePeriodExtension0);
        assertGt(checkpointAfter.gracePeriodExtension1, checkpointBefore.gracePeriodExtension1);
    }

    function testCanWrapAndUnwrapNativeAsset() public {
        // NOTE: Following Uniswap v4 PositionManager pattern, wrap/unwrap are now simple
        // WETH9 deposit/withdraw operations without delta accounting.
        // The wrap/unwrap operations are handled by MMPositionManager which inherits NativeWrapper.
        // Settlement happens via the standard settle/take flow.

        uint256 wrapAmount = 1 ether;

        // Deal ETH to MMPositionManager
        deal(address(mmPositionManager), wrapAmount);

        // Get WETH balance before wrap
        uint256 wethBalanceBefore = weth9.balanceOf(address(mmPositionManager));

        // Wrap native ETH to WETH via MMPositionManager's NativeWrapper
        // This is a simple WETH9.deposit() call - no delta accounting
        vm.prank(address(mmPositionManager));
        MMPositionManager(payable(mmPositionManager)).WETH9().deposit{value: wrapAmount}();

        // Get WETH balance after wrap
        uint256 wethBalanceAfter = weth9.balanceOf(address(mmPositionManager));

        // Validate: WETH balance should increase by wrap amount
        assertEq(wethBalanceAfter - wethBalanceBefore, wrapAmount, "WETH balance should increase by wrap amount");

        // Unwrap WETH to native ETH
        vm.prank(address(mmPositionManager));
        MMPositionManager(payable(mmPositionManager)).WETH9().withdraw(wrapAmount);

        // Get WETH balance after unwrap
        uint256 wethBalanceAfterUnwrap = weth9.balanceOf(address(mmPositionManager));

        // Validate: WETH balance should be back to original
        assertEq(wethBalanceAfterUnwrap, wethBalanceBefore, "WETH balance should be back to original");
    }

    function testCanUnwrapLcc() public {
        address user = makeAddr("user");
        uint256 amount = 1000;
        // Use lcc0 directly - verify it matches lccToken0 from MarketTestBase
        address lccTokenAddress = address(lcc0);
        // Verify addresses match (they should both be from _currency2)
        assertEq(lccTokenAddress, lccToken0, "lcc0 and lccToken0 should match");

        // Mock VTSOrchestrator as non-protocol so it accumulates LCC balance when tokens are transferred to it
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, address(user)), abi.encode(false)
        );

        // wrap some lcc tokens
        MockERC20 underlyingAsset = MockERC20(lcc0.underlying());
        // mint the underlying asset to the user
        underlyingAsset.mint(user, amount);
        // approve the liquidity hub to spend(move) the underlying asset
        // hub then spends(moves) underlying assets to itself
        // and then gives LCC tokens to the user
        vm.startPrank(user);
        underlyingAsset.approve(address(liquidityHub), amount);
        ILiquidityHub(liquidityHub).wrap(lccTokenAddress, amount);
        vm.stopPrank();

        // validate lcc balance of the user
        assertEq(lcc0.balanceOf(user), amount);

        // unwrap lcc using the position manager
        // approve position manager to spend the lcc (must be approved by the user, not the test contract)
        vm.startPrank(user);
        lcc0.approve(address(positionManager), amount);
        vm.stopPrank();

        // Verify the approval was set correctly (check outside of prank to ensure it persists)
        uint256 allowance = lcc0.allowance(user, address(positionManager));
        assertEq(allowance, amount, "Approval should be set before unwrap");

        // lcc0.balancesOf(user);

        vm.prank(user);
        MMA.unwrapLcc(positionManager, lccTokenAddress, amount, user, true);

        // validate lcc balance of the user
        assertEq(lcc0.balanceOf(user), 0);

        // validate underlying balance of the user
        assertEq(underlyingAsset.balanceOf(user), amount);
    }

    function test_canRenewSignal() public {
        // get the default market confiration so we can tweak it
        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Setup committed position using helper
        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            vtsOrchestrator,
            corePoolKey,
            liquiditySignal,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        (, uint256 expiresAtPrevious,) = vtsOrchestrator.getCommit(tokenId);

        // renew the signal
        uint256 newTimestamp = 1000;
        vm.warp(newTimestamp);
        MMA.renew(positionManager, tokenId, abi.encode(renewSignal));

        (, uint256 expiresAtAfter,) = vtsOrchestrator.getCommit(tokenId);

        console.log("expiresAtPrevious", expiresAtPrevious);
        console.log("expiresAtAfter", expiresAtAfter);

        // // validate the expiry is updated
        assertEq(expiresAtAfter + 1, newTimestamp + expiresAtPrevious);
    }

    // test can seize position
    function testCanSeizePosition() public {
        // get the default market confiration so we can tweak it
        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Setup committed position using helper
        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            vtsOrchestrator,
            corePoolKey,
            liquiditySignal,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        uint256 positionIndex = 0;

        vm.warp(block.timestamp + 10000000);

        // approve the orchestrator to spend the underlying assets
        uint256 amount0 = 1000;
        uint256 amount1 = 1000;
        // approve the orchestrator to spend the underlying assets
        IERC20(lcc0.underlying()).transfer(guarantor, amount0);
        IERC20(lcc1.underlying()).transfer(guarantor, amount1);

        BalanceDelta requiredSettlementDeltaBefore =
            vtsOrchestrator.getUnderlyingDeltaPair(address(guarantor), lccCurrency0, lccCurrency1);

        vm.startPrank(guarantor);
        IERC20(lcc0.underlying()).approve(address(vtsOrchestrator), amount0);
        IERC20(lcc1.underlying()).approve(address(vtsOrchestrator), amount1);

        // get position liquidity
        (Position memory positionBeforeSeize,) = vtsOrchestrator.getPosition(tokenId, positionIndex);
        // call the seize method of the orchestrator
        // vtsOrchestrator.seizePosition(address(this), corePoolKey, tokenId, positionIndex, amount0, amount1);
        // then call the withdraw from delta method of the orchestrator
        _seizeAndTakeDeltas(positionManager, corePoolKey, tokenId, positionIndex, amount0, amount1);
        vm.stopPrank();

        // get position liquidity after seize
        (Position memory positionAfterSeize,) = vtsOrchestrator.getPosition(tokenId, positionIndex);
        console.log("positionLiquidityBeforeSeize", uint256(positionBeforeSeize.liquidity));
        console.log("positionLiquidityAfterSeize", uint256(positionAfterSeize.liquidity));

        // get the position required settlement delta
        BalanceDelta requiredSettlementDeltaAFter =
            vtsOrchestrator.getUnderlyingDeltaPair(address(guarantor), lccCurrency0, lccCurrency1);

        console.log("requiredSettlementDelta0Before", requiredSettlementDeltaBefore.amount0());
        console.log("requiredSettlementDelta1Before", requiredSettlementDeltaBefore.amount1());
        console.log("requiredSettlementDelta0", requiredSettlementDeltaAFter.amount0());
        console.log("requiredSettlementDelta1", requiredSettlementDeltaAFter.amount1());

        // validate the position liquidity is decreased
        assertLt(uint256(positionAfterSeize.liquidity), uint256(positionBeforeSeize.liquidity));
        // validate the user's delta in increased
        assertGt(requiredSettlementDeltaAFter.amount0(), requiredSettlementDeltaBefore.amount0());
        assertGt(requiredSettlementDeltaAFter.amount1(), requiredSettlementDeltaBefore.amount1());
    }

    function testCanCheckpointWithCommitment() public {
        // get the default market configuration so we can tweak it
        LiquiditySignal memory renewSignal = liquiditySignal;

        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Setup committed position using helper
        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            vtsOrchestrator,
            corePoolKey,
            liquiditySignalBytes,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        uint256 positionIndex = 0;
        address advancer = renewSignal.mmState.advancer;

        // checkpoint with commitment backing check
        bytes memory unbackedLiquiditySignal = abi.encode(renewSignal);

        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(bytes,bool)")), unbackedLiquiditySignal, true
            ),
            abi.encode(true, 10)
        );

        // get liquidity in position 0
        (Position memory positionBeforeCheckpoint,) = vtsOrchestrator.getPosition(tokenId, positionIndex);
        console.log("positionLiquidityBeforeCheckpoint", uint256(positionBeforeCheckpoint.liquidity));

        // need to inflate the value of issuedusd to be greater than the signalusd by 20%
        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector),
            abi.encode(50000000000, 50000000000)
        );

        // Checkpoint with commitment backing check (liquiditySignal provided means withCommitment = true)
        // Call directly through CheckpointEntrypoints which uses msg.sender for validation
        vm.prank(advancer);
        positionManager.checkpoint(tokenId, positionIndex, unbackedLiquiditySignal);

        // get liquidity in position 0
        (Position memory positionAfterCheckpoint,) = vtsOrchestrator.getPosition(tokenId, positionIndex);
        console.log("positionLiquidityAfterCheckpoint", uint256(positionAfterCheckpoint.liquidity));
    }

    /**
     * @notice Calculates y such that (x * y) * 2 = signalUSD * (1 + percentageIncreaseBps/10000)
     * @param x The input value
     * @param signalUSD The current signal USD value (e.g., 10000)
     * @param percentageIncreaseBps The percentage increase in basis points (e.g., 2000 for 20%)
     * @return y The calculated value
     */
    function calculateY(uint256 x, uint256 signalUSD, uint256 percentageIncreaseBps) public pure returns (uint256 y) {
        require(x > 0, "x must be greater than 0");

        // Calculate: y = (signalUSD * (10000 + percentageIncreaseBps)) / (x * 2 * 10000)
        uint256 numerator = signalUSD * (10000 + percentageIncreaseBps);
        uint256 denominator = x * 2 * 10000;

        y = numerator / denominator;
    }
}

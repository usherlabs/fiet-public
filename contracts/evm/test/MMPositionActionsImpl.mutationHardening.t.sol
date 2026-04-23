// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {MarketTestBase} from "./base/MarketTestBase.sol";
import {MarketMakerTestBase} from "./base/MMTestBase.sol";
import {MMActionAdapter as MMA} from "./utils/MMActionAdapter.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {LiquiditySignal} from "../src/types/Commit.sol";

import {MMPositionManager} from "../src/MMPositionManager.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {IVTSOrchestrator} from "../src/interfaces/IVTSOrchestrator.sol";
import {IOracleHelper} from "../src/interfaces/IOracleHelper.sol";
import {MarketVTSConfiguration} from "../src/types/VTS.sol";
import {Errors} from "../src/libraries/Errors.sol";

/**
 * @notice Mutation hardening tests for MMPositionActionsImpl.
 * @dev Targets known survivors in `_settleFromDeltas` (credit gating + approval gating).
 */
contract MMPositionActionsImplMutationHardeningTest is MarketTestBase, MarketMakerTestBase {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    MMPositionManager internal positionManager;
    MarketVTSConfiguration internal marketVTSConfiguration;

    LiquidityCommitmentCertificate internal lcc0;
    LiquidityCommitmentCertificate internal lcc1;

    ModifyLiquidityParams internal defaultLiquidityParams =
        ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});

    function setUp() public {
        _setupMarket();
        _setUpMM();

        positionManager = MMPositionManager(payable(mmPositionManager));
        lcc0 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency2)));
        lcc1 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency3)));

        marketVTSConfiguration =
            IVTSOrchestrator(address(vtsOrchestrator)).getMarketVTSConfiguration(corePoolKey.toId());

        // Mock price/oracle paths used during settlement/backing checks.
        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector),
            abi.encode(uint256(1), uint256(1))
        );
        vm.mockCall(
            address(oracleHelper), abi.encodeWithSelector(IOracleHelper.getTotalValue.selector), abi.encode(1e18)
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
                abi.encode(uint256(1e18))
            );
        }
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, liquiditySignal.mmState.advancer),
            abi.encode(true)
        );

        _wireTestQueueCustodianFor(address(mmPositionManager), liquiditySignal.mmState.advancer);
        _wireAllUtilityTestQueueCustodians(address(mmPositionManager));
    }

    function _createPosition(
        ModifyLiquidityParams memory liquidityParams,
        bytes memory liquiditySignalBytes,
        uint256 tokenId,
        uint256 positionIndex
    ) internal {
        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) =
            _calculateSettlementAmounts(liquidityParams, marketVTSConfiguration);

        address locker = abi.decode(liquiditySignalBytes, (LiquiditySignal)).mmState.advancer;
        address u0 = ILCC(address(lcc0)).underlying();
        address u1 = ILCC(address(lcc1)).underlying();
        _fundLockerForSettlement(locker, u0, u1, requiredSettlementAmount0, requiredSettlementAmount1);

        vm.startPrank(locker);
        _approveTokenForPositionManager(
            u0, u1, address(positionManager), requiredSettlementAmount0, requiredSettlementAmount1
        );

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        actions[0] = MMA.prepareCommit(liquiditySignalBytes);
        actions[1] = MMA.prepareMint(
            corePoolKey,
            tokenId,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            uint256(liquidityParams.liquidityDelta)
        );
        actions[2] = MMA.prepareSettle(
            corePoolKey,
            tokenId,
            positionIndex,
            -SafeCast.toInt128(requiredSettlementAmount0),
            -SafeCast.toInt128(requiredSettlementAmount1),
            false
        );

        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();
    }

    function test_settleFromDeltas_withOneSidedProtocolCredit_token0Only() public {
        // Kills survivors around:
        // - (credit0 > 0 || credit1 > 0) -> (credit0 > 0 && credit1 > 0)
        // - credit0 > 0 -> credit0 < 0
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        ModifyLiquidityParams memory oneSided =
            ModifyLiquidityParams({tickLower: 1080, tickUpper: 1140, liquidityDelta: 1e18, salt: bytes32(0)});
        _createPosition(oneSided, abi.encode(liquiditySignal), tokenId, positionIndex);

        address locker = liquiditySignal.mmState.advancer;
        address underlying0 = lcc0.underlying();
        address underlying1 = lcc1.underlying();

        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) =
            _calculateSettlementAmounts(oneSided, marketVTSConfiguration);

        // Additional settle to ensure burn produces one-sided protocol credit.
        (uint256 commitment0,) = LiquidityUtils.calculateCommitmentMaxima(
            oneSided.tickLower, oneSided.tickUpper, uint128(uint256(oneSided.liquidityDelta))
        );
        _fundLockerForSettlement(locker, underlying0, underlying1, commitment0, 0);
        vm.startPrank(locker);
        _approveTokenForPositionManager(underlying0, underlying1, address(positionManager), commitment0, 0);
        MMA.PreparedAction[] memory preActions = new MMA.PreparedAction[](1);
        preActions[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, -int128(int256(commitment0)), 0, false);
        MMA.executeWithUnlock(positionManager, preActions, block.timestamp + 3600);
        vm.stopPrank();

        uint256 bal0Before = IERC20(underlying0).balanceOf(locker);
        uint256 bal1Before = IERC20(underlying1).balanceOf(locker);

        vm.startPrank(locker);
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
        actions[0] = MMA.prepareBurn(corePoolKey, tokenId, positionIndex);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
        actions[2] = MMA.prepareTake(Currency.wrap(underlying0), locker, 0);
        actions[3] = MMA.prepareTake(Currency.wrap(underlying1), locker, 0);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();

        uint256 bal0After = IERC20(underlying0).balanceOf(locker);
        uint256 bal1After = IERC20(underlying1).balanceOf(locker);

        assertGt(bal0After, bal0Before + requiredSettlementAmount0, "expected token0 payout from one-sided credit");
        assertEq(bal1After, bal1Before + requiredSettlementAmount1, "expected no token1 payout from token0-only credit");
    }

    function test_settleFromDeltas_withOneSidedProtocolCredit_token1Only() public {
        // Kills survivors around:
        // - (credit0 > 0 || credit1 > 0) -> (credit0 > 0 && credit1 > 0)
        // - credit1 > 0 -> credit1 < 0
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        ModifyLiquidityParams memory oneSided =
            ModifyLiquidityParams({tickLower: -1140, tickUpper: -1080, liquidityDelta: 1e18, salt: bytes32(0)});
        _createPosition(oneSided, abi.encode(liquiditySignal), tokenId, positionIndex);

        address locker = liquiditySignal.mmState.advancer;
        address underlying0 = lcc0.underlying();
        address underlying1 = lcc1.underlying();

        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) =
            _calculateSettlementAmounts(oneSided, marketVTSConfiguration);

        (, uint256 commitment1) = LiquidityUtils.calculateCommitmentMaxima(
            oneSided.tickLower, oneSided.tickUpper, uint128(uint256(oneSided.liquidityDelta))
        );
        _fundLockerForSettlement(locker, underlying0, underlying1, 0, commitment1);
        vm.startPrank(locker);
        _approveTokenForPositionManager(underlying0, underlying1, address(positionManager), 0, commitment1);
        MMA.PreparedAction[] memory preActions = new MMA.PreparedAction[](1);
        preActions[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, 0, -int128(int256(commitment1)), false);
        MMA.executeWithUnlock(positionManager, preActions, block.timestamp + 3600);
        vm.stopPrank();

        uint256 bal0Before = IERC20(underlying0).balanceOf(locker);
        uint256 bal1Before = IERC20(underlying1).balanceOf(locker);

        vm.startPrank(locker);
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
        actions[0] = MMA.prepareBurn(corePoolKey, tokenId, positionIndex);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
        actions[2] = MMA.prepareTake(Currency.wrap(underlying0), locker, 0);
        actions[3] = MMA.prepareTake(Currency.wrap(underlying1), locker, 0);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();

        uint256 bal0After = IERC20(underlying0).balanceOf(locker);
        uint256 bal1After = IERC20(underlying1).balanceOf(locker);

        assertEq(bal0After, bal0Before + requiredSettlementAmount0, "expected no token0 payout from token1-only credit");
        assertGt(bal1After, bal1Before + requiredSettlementAmount1, "expected token1 payout from one-sided credit");
    }

    function test_settleFromDeltas_deposit_revertsForNotApprovedCaller_whenNotSeizing() public {
        // Kills survivor:
        // - `if (!isSeizing)` approval gate inverted/removed
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _createPosition(defaultLiquidityParams, abi.encode(liquiditySignal), tokenId, positionIndex);

        address attacker = makeAddr("attacker");
        MMA.PreparedAction[] memory attackerActions = new MMA.PreparedAction[](1);
        attackerActions[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, -int128(1), 0, false);

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, attacker));
        MMA.executeWithUnlock(positionManager, attackerActions, block.timestamp + 3600);
        vm.stopPrank();
    }
}


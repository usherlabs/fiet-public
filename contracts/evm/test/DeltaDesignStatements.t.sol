// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {MarketTestBase} from "./base/MarketTestBase.sol";
import {MarketMakerTestBase} from "./base/MMTestBase.sol";
import {MMPositionManager} from "../src/MMPositionManager.sol";
import {MMActionAdapter as MMA} from "./utils/MMActionAdapter.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {MarketVTSConfiguration} from "../src/types/VTS.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {IMarketVault} from "../src/interfaces/IMarketVault.sol";
import {ILiquidityHub} from "../src/interfaces/ILiquidityHub.sol";
import {IOracleHelper} from "../src/interfaces/IOracleHelper.sol";
import {Errors} from "../src/libraries/Errors.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Real-path design-statement tests for DELTA-02 and DELTA-03.
contract DeltaDesignStatementsTest is MarketTestBase, MarketMakerTestBase {
    MMPositionManager internal positionManager;
    LiquidityCommitmentCertificate internal lcc0;
    LiquidityCommitmentCertificate internal lcc1;
    MarketVTSConfiguration internal marketVTSConfiguration;

    function setUp() public {
        _setupMarket();
        _setUpMM();

        positionManager = MMPositionManager(payable(mmPositionManager));
        lcc0 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency2)));
        lcc1 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency3)));
        marketVTSConfiguration = vtsOrchestrator.getMarketVTSConfiguration(corePoolKey.toId());

        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector, address(lcc0), address(lcc1)),
            abi.encode(uint256(1), uint256(1))
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
    }

    function test_delta02_router_residue_is_fcfs_dust() public {
        address underlying0 = lcc0.underlying();
        uint256 dust = 100e18;
        _mintErc20To(underlying0, address(positionManager), dust);
        assertEq(IERC20(underlying0).balanceOf(address(positionManager)), dust);

        // Next caller can claim residue via the real MMPM SYNC+TAKE path.
        address nextCaller = makeAddr("nextCaller");
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareSync(Currency.wrap(underlying0));
        actions[1] = MMA.prepareTake(Currency.wrap(underlying0), nextCaller, 0);
        vm.prank(nextCaller);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);

        assertEq(IERC20(underlying0).balanceOf(nextCaller), dust, "next caller should receive residue");
        assertEq(IERC20(underlying0).balanceOf(address(positionManager)), 0, "router residue should be depleted");
    }

    function test_delta03_planned_cancel_is_path_scoped_and_immediately_consumed() public {
        address recipient = liquiditySignal.mmState.advancer;
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        (uint256 tokenId,, uint256 req0, uint256 req1) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        positionManager.approve(recipient, tokenId);
        vm.mockCall(
            address(mv),
            abi.encodeWithSelector(IMarketVault.dryModifyLiquidities.selector),
            abi.encode(toBalanceDelta(0, 0))
        );
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, 0, uint256(liquidityParams.liquidityDelta));
        actions[1] = MMA.prepareSettle(corePoolKey, tokenId, 0, int128(uint128(req0)), int128(uint128(req1)), false);
        vm.prank(recipient);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);

        uint256 queued0 = ILiquidityHub(liquidityHub).settleQueue(address(lcc0), recipient);
        uint256 queued1 = ILiquidityHub(liquidityHub).settleQueue(address(lcc1), recipient);
        assertGt(queued0 + queued1, 0, "decrease path should materialise queued cancel output");

        // No deferred entitlement persists: leaving a synced credit without TAKE must still fail at batch end.
        address underlying0 = lcc0.underlying();
        _mintErc20To(underlying0, address(positionManager), 1);
        MMA.PreparedAction[] memory bad = new MMA.PreparedAction[](1);
        bad[0] = MMA.prepareSync(Currency.wrap(underlying0));
        vm.prank(recipient);
        vm.expectRevert(Errors.CurrencyNotSettled.selector);
        MMA.executeWithUnlock(positionManager, bad, block.timestamp + 3600);
    }

    function _mintErc20To(address token, address to, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", to, amount));
        require(ok, "mint failed");
    }
}


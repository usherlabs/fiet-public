// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import {MarketTestBase} from "test/base/MarketTestBase.sol";
import {MarketMakerTestBase} from "test/base/MMTestBase.sol";
import {MMPositionManager} from "src/MMPositionManager.sol";
import {MMActionAdapter as MMA} from "test/utils/MMActionAdapter.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquiditySignal} from "src/types/Commit.sol";
import {LiquidityCommitmentCertificate} from "src/LCC.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {IMarketVault} from "src/interfaces/IMarketVault.sol";
import {IMarketVaultDryBalanceDelta} from "test/_helpers/IMarketVaultDryBalanceDelta.sol";
import {ILiquidityHub} from "src/interfaces/ILiquidityHub.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MarketVTSConfiguration} from "src/types/VTS.sol";
import {IOracleHelper} from "src/interfaces/IOracleHelper.sol";

contract PausedMMTrace is MarketTestBase, MarketMakerTestBase {
    MMPositionManager internal positionManager;
    MarketVTSConfiguration internal marketVTSConfiguration;
    LiquidityCommitmentCertificate internal lcc0;
    LiquidityCommitmentCertificate internal lcc1;

    function setUp() public {
        _setupMarket();
        _setUpMM();
        positionManager = MMPositionManager(payable(mmPositionManager));
        lcc0 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency2)));
        lcc1 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency3)));
        marketVTSConfiguration = vtsOrchestrator.getMarketVTSConfiguration(corePoolKey.toId());
        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector),
            abi.encode(uint256(1), uint256(1))
        );
        vm.mockCall(
            address(oracleHelper), abi.encodeWithSelector(IOracleHelper.getTotalValue.selector), abi.encode(1e18)
        );
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, liquiditySignal.mmState.advancer),
            abi.encode(true)
        );

        _wireTestQueueCustodianFor(address(mmPositionManager), liquiditySignal.mmState.advancer);
        _wireAllUtilityTestQueueCustodians(address(mmPositionManager));
    }

    function test_trace() public {
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, address(positionManager)),
            abi.encode(true)
        );
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(uint256(1))});
        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        (,, uint256 pc,,) = vtsOrchestrator.getCommit(tokenId);
        uint256 positionIndex = pc - 1;
        vm.mockCall(
            address(mv),
            abi.encodeWithSelector(IMarketVaultDryBalanceDelta.dryModifyLiquidities.selector),
            abi.encode(toBalanceDelta(0, 0))
        );
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );
        vtsOrchestrator.pausePool(corePoolKey.toId());
        uint256 amountToDecrease = 5e9;
        address locker = liquiditySignal.mmState.advancer;
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, locker), abi.encode(true));
        MMA.PreparedAction[] memory setup = new MMA.PreparedAction[](3);
        setup[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, amountToDecrease);
        setup[1] = MMA.prepareTake(Currency.wrap(address(lcc0)), address(this), 0);
        setup[2] = MMA.prepareTake(Currency.wrap(address(lcc1)), address(this), 0);
        vm.startPrank(locker);
        MMA.executeWithUnlock(positionManager, setup, block.timestamp + 3600);
        vm.stopPrank();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// import "forge-std/Test.sol";

// import {MarketTestBase} from "../modules/MarketTestBase.sol";
// import {MarketMakerTestBase} from "../modules/MMTestBase.sol";
// import {MMPositionManager} from "../../src/MMPositionManager.sol";
// import {MarketMaker} from "../../src/libraries/MarketMaker.sol";
// import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
// import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
// import {IOracleHelper} from "../../src/interfaces/IOracleHelper.sol";
// import {Errors} from "../../src/libraries/Errors.sol";
// import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
// import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
// import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
// import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
// import {LiquidityCommitmentCertificate} from "../../src/LCC.sol";
// import {IVTSManager} from "../../src/interfaces/IVTSManager.sol";
// import {MarketVTSConfiguration} from "../../src/types/VTS.sol";
// import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
// import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
// import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
// import {PositionId} from "../../src/types/Position.sol";
// import {PositionMeta} from "../../src/types/Position.sol";
// import {Commit} from "../../src/types/Commit.sol";
// import {Pool} from "../../src/types/Pool.sol";
// import {MarketVTSConfiguration, PositionAccounting} from "../../src/types/VTS.sol";
// import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
// import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
// import {LiquiditySignal} from "../../src/types/Commit.sol";
// import {PositionLibrary} from "../../src/types/Position.sol";
// import {Position} from "../../src/types/Position.sol";

// contract VTSOrchestratorTest is MarketTestBase, MarketMakerTestBase {
//     using SafeCast for *;
//     using PoolIdLibrary for PoolId;
//     using CurrencyLibrary for Currency;
//     using MarketMaker for MarketMaker.State;
//     using StateLibrary for IPoolManager;

//     MMPositionManager internal positionManager;
//     MarketVTSConfiguration internal marketVTSConfiguration;

//     LiquidityCommitmentCertificate internal lcc0;
//     LiquidityCommitmentCertificate internal lcc1;

//     address guarantor = makeAddr("guarantor");
//     uint256 guarantorInitialBalance = 10000e18;

//     function setUp() public {
//         _setupMarket();
//         _setUpMM();
//         console.log("setUP() mmPositionManager", address(mmPositionManager));
//         positionManager = MMPositionManager(payable(mmPositionManager));
//         lcc0 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency2)));
//         lcc1 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency3)));

//         marketVTSConfiguration = IVTSManager(coreHookAddress).getMarketVTSConfiguration(corePoolKey.toId());

//         // approve the lccs to the mmPositionManager to be able to route tokens to the pool manager
//         // lcc0.approve(address(mmPositionManager), Constants.MAX_UINT256);
//         // lcc1.approve(address(mmPositionManager), Constants.MAX_UINT256);
//         // Mock the proxyHookToCurrencyPair function in order to make this caller appear to be an issuer
//         // when deploying the factory the mmposiiton manager will be provided and thus whitelsited
//         // but since we are mocking the factory, we need to mock a way to return the mmposition manager as an issuer
//         address[2] memory mockCurrencies = [address(lcc0.underlying()), address(lcc1.underlying())];
//         vm.mockCall(
//             marketFactory,
//             abi.encodeWithSelector(IMarketFactory.proxyHookToCurrencyPair.selector, address(mmPositionManager)),
//             abi.encode(mockCurrencies)
//         );
//         // mock the factory to return the right core hook
//         vm.mockCall(
//             marketFactory, abi.encodeWithSelector(IMarketFactory.coreToProxy.selector), abi.encode(proxyPoolKey.toId())
//         );
//         // mock the factory to return the right proxy hook
//         vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.proxyToHook.selector), abi.encode(proxyHook));

//         // mock the price oracles to return prices
//         vm.mockCall(
//             address(oracleHelper),
//             abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector),
//             abi.encode(uint256(1), uint256(1))
//         );
//         // supply enough
//         vm.mockCall(
//             address(oracleHelper), abi.encodeWithSelector(IOracleHelper.getTotalValue.selector), abi.encode(1e18)
//         );
//     }

//     function testCanAddLiquidityToVTSOrchestrator() public {
//         modifyLiquidityRouter.modifyLiquidity(
//             corePoolKey,
//             ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
//             ZERO_BYTES
//         );
//     }

//     function testCanCommitSignalToVTSOrchestrator() public {
//         bytes memory liquiditySignal = abi.encode(liquiditySignal);

//         // call commit method on the vts orchestrator
//         vm.prank(address(mmPositionManager));
//         uint256 tokenId = vtsOrchestrator.commitSignal(liquiditySignal);

//         // get the commit and validate that it was made
//         (MarketMaker.State memory mmState, uint256 expiresAt, uint256 positionCount, uint256 deficitBps) =
//             vtsOrchestrator.getCommit(tokenId);
//         MarketMaker.State memory expectedMMState = abi.decode(liquiditySignal, (LiquiditySignal)).mmState;
//         // Validate the commit was saved to state correctly
//         // signalExpiryInSeconds
//         assertEq(expiresAt, block.timestamp + signalExpiryInSeconds);
//         assertEq(abi.encode(mmState), abi.encode(expectedMMState));
//         assertEq(positionCount, 0);
//         assertEq(deficitBps, 0);
//     }

//     function testCanMintPositionToVTSOrchestrator() public {
//         // first commit a liquidity signal
//         bytes memory liquiditySignal = abi.encode(liquiditySignal);

//         // call commit method on the vts orchestrator
//         vm.prank(address(mmPositionManager));
//         uint256 tokenId = vtsOrchestrator.commitSignal(liquiditySignal);

//         // Generate the parameters for the mint position
//         ModifyLiquidityParams memory params = ModifyLiquidityParams({
//             tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: PositionLibrary.generateSalt(tokenId, 0)
//         });
//         // generate expected position id
//         PositionId expectedPositionId = PositionLibrary.generateId(address(mmPositionManager), params);

//         vm.prank(address(mmPositionManager));
//         (PositionId positionId, uint256 positionIndex) = vtsOrchestrator.mintPosition(
//             corePoolKey, tokenId, params.tickLower, params.tickUpper, uint256(params.liquidityDelta)
//         );

//         // get commit
//         (, uint256 expiresAt, uint256 positionCount,) = vtsOrchestrator.getCommit(tokenId);

//         assertEq(positionCount, 1);
//         assertEq(positionIndex, positionCount - 1);
//         assertEq(expiresAt, block.timestamp + signalExpiryInSeconds);

//         assertEq(PositionId.unwrap(positionId), PositionId.unwrap(expectedPositionId), "Position ID mismatch");

//         // get the position and validate that it was minted
//         Position memory position = vtsOrchestrator.getPosition(positionId);
//         assertEq(position.owner, address(mmPositionManager));
//         assertEq(PoolId.unwrap(position.poolId), PoolId.unwrap(corePoolKey.toId()));
//         assertEq(position.commitId, tokenId);
//     }
// }

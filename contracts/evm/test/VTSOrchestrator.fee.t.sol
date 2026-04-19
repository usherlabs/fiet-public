// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.26;

// import "forge-std/Test.sol";
// import {VTSOrchestratorFixture} from "./base/VTSOrchestratorFixture.sol";
// import {UnlockCaller} from "./base/VTSOrchestratorFixture.sol";
// import {VTSOrchestratorTestable} from "./base/VTSOrchestratorTestable.sol";
// import {VTSOrchestrator} from "../src/VTSOrchestrator.sol";
// import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
// import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
// import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
// import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
// import {PositionId, Position} from "../src/types/Position.sol";
// import {PositionModificationHookDataLib, PositionLibrary} from "../src/types/Position.sol";
// import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// import {MarketVTSConfiguration} from "../src/types/VTS.sol";
// import {VTSConfigs} from "../src/libraries/VTSConfigs.sol";
// import {Errors} from "../src/libraries/Errors.sol";
// import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
// import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
// import {RFSCheckpoint} from "../src/types/Checkpoint.sol";
// import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
// import {MarketFactory} from "../src/MarketFactory.sol";
// import {IOracleHelper} from "../src/interfaces/IOracleHelper.sol";
// import {IVRLSettlementObserver} from "../src/interfaces/IVRLSettlementObserver.sol";
// import {LiquiditySignal} from "../src/types/Commit.sol";
// import {MarketMaker} from "../src/libraries/MarketMaker.sol";
// import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
// import {MMActionAdapter as MMA} from "./utils/MMActionAdapter.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
// import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

// contract VTSOrchestratorTest is VTSOrchestratorFixture {
//     using PoolIdLibrary for PoolId;
//     using CurrencyLibrary for Currency;
//     using StateLibrary for IPoolManager;

//     // ============================================================
//     // Events (redeclared for vm.expectEmit)
//     // ============================================================

//     event Checkpointed(uint256 commitId, uint256 positionIndex, RFSCheckpoint checkpoint, bool withCommitment);
//     event GracePeriodExtended(uint256 commitId, uint256 positionIndex, uint8 tokenIndex, RFSCheckpoint checkpoint);
//     event VTSConfigSet(bytes32 indexed marketId, MarketVTSConfiguration newConfig);
//     event PositionSettled(
//         uint256 indexed commitId,
//         uint256 indexed positionIndex,
//         int128 settlementDelta0,
//         int128 settlementDelta1,
//         uint256 settledToken0,
//         uint256 settledToken1,
//         bool isSeizing,
//         bool rfsOpen
//     );

//     struct DICEAccounting {
//         uint256 totalDeficitPrincipal1;
//         uint256 diceIndex1;
//         uint256 diceResidual1;
//     }

//     struct CISEAccounting {
//         uint256 totalSettled0;
//         uint256 totalSettled1;
//         uint256 ciseIndex0;
//         uint256 ciseIndex1;
//         uint256 totalCISEExposure0;
//         uint256 totalCISEExposure1;
//     }

//     // ============================================================
//     // Deploy VTSOrchestratorTestable for storage inspection
//     // ============================================================

//     /// @notice Override to deploy VTSOrchestratorTestable with debug view functions
//     function _deployVTSOrchestrator(address _poolManager, address _oracleHelper, address _liquidityHub, address _owner)
//         internal
//         override
//         returns (VTSOrchestrator)
//     {
//         return new VTSOrchestratorTestable(_poolManager, _oracleHelper, _liquidityHub, _owner);
//     }

//     /// @notice Helper to access testable VTSOrchestrator with debug functions
//     function _testableOrchestrator() internal view returns (VTSOrchestratorTestable) {
//         return VTSOrchestratorTestable(address(vtsOrchestrator));
//     }

//     /// @dev Regression for finding 6: paused remove must materialise queued positive slashes.
//     function test_pausedRemoveLiquidity_materialisesPositivePendingSlash() public {
//         uint256 liquidity = 1e10;
//         uint256 amountToDecrease = liquidity / 2;
//         (uint256 tokenId, PositionId positionId,,) =
//             _createCommittedPosition(renewSignal, -60, 60, liquidity, bytes32(uint256(77)));

//         // Build slashable state: create deficit, exercise coverage, then settle growths.
//         _swapCore(true, -int256(2e18));
//         vm.prank(marketFactory);
//         vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 2e18, 2e18);
//         vtsOrchestrator.settlePositionGrowths(positionId);

//         // Ensure we have a positive pending slash lane; if not, try once in the opposite swap direction.
//         (,, int256 pending0Seed, int256 pending1Seed) = vtsOrchestrator.getPositionFeeAccounting(positionId);
//         if (pending0Seed <= 0 && pending1Seed <= 0) {
//             _swapCore(false, -int256(2e18));
//             vm.prank(marketFactory);
//             vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 2e18, 2e18);
//             vtsOrchestrator.settlePositionGrowths(positionId);
//             (,, pending0Seed, pending1Seed) = vtsOrchestrator.getPositionFeeAccounting(positionId);
//         }
//         assertTrue(pending0Seed > 0 || pending1Seed > 0, "precondition: expected positive pending slash");

//         // Non-seizure remove requires closed RFS. If open, settle exactly the required positive lanes.
//         (bool rfsOpenBefore, BalanceDelta rfsDeltaBefore) = vtsOrchestrator.calcRFS(positionId, false);
//         if (rfsOpenBefore) {
//             int128 settle0 = rfsDeltaBefore.amount0() > 0 ? -rfsDeltaBefore.amount0() : int128(0);
//             int128 settle1 = rfsDeltaBefore.amount1() > 0 ? -rfsDeltaBefore.amount1() : int128(0);
//             if (settle0 != 0 || settle1 != 0) {
//                 _mmSettle(tokenId, 0, settle0, settle1);
//             }
//         }

//         (bool rfsOpenAfterClose,) = vtsOrchestrator.calcRFS(positionId, false);
//         assertFalse(rfsOpenAfterClose, "precondition: RFS must be closed before paused remove");

//         (,, int256 pending0Before, int256 pending1Before) = vtsOrchestrator.getPositionFeeAccounting(positionId);
//         (uint256 pot0Before, uint256 pot1Before) = vtsOrchestrator.getSlashedPot(corePoolKey.toId());

//         vtsOrchestrator.pausePool(corePoolKey.toId());
//         _decreasePosition(tokenId, amountToDecrease);
//         vtsOrchestrator.unpausePool(corePoolKey.toId());

//         (,, int256 pending0After, int256 pending1After) = vtsOrchestrator.getPositionFeeAccounting(positionId);
//         (uint256 pot0After, uint256 pot1After) = vtsOrchestrator.getSlashedPot(corePoolKey.toId());

//         if (pending0Before > 0) {
//             assertLt(pending0After, pending0Before, "paused remove should materialise token0 pending slash");
//             assertGt(pot0After, pot0Before, "paused remove should fund token0 slashed pot");
//         }
//         if (pending1Before > 0) {
//             assertLt(pending1After, pending1Before, "paused remove should materialise token1 pending slash");
//             assertGt(pot1After, pot1Before, "paused remove should fund token1 slashed pot");
//         }
//     }
// }


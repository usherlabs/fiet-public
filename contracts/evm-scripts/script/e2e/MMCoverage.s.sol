// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * E2E: MMCoverage
 *
 * Goal:
 * - Exercise the MMPositionManager “coverage + fee realisation” path with TWO market makers.
 *
 * High-level flow:
 * - Deploy full stack + create a market (core LCC/LCC pool).
 * - MM1: commit → mint → settle a *small* position (intended to be “stressable”).
 * - MM2: commit → mint → settle a *large* position (acts as “deep liquidity / well-backed MM”).
 * - Fund a taker and execute swaps in both directions to generate activity.
 * - Partially unwrap LCCs after swaps to force the “coverage/settlement” mechanics to run.
 * - CHECKPOINT MM1 to ensure its snapshots/deficit state are current before fee materialisation.
 * - POKE both positions (no-op increase + take) to materialise any pending slashes/bonuses into LCC balances.
 * - Close RFS (if open), then burn + settle-from-deltas + decommit, and take remaining credits.
 *
 * Notes:
 * - This script is intentionally “mechanics-oriented”: it demonstrates the flows; it does not attempt to
 *   assert the exact slashed-pot math (which depends on protocol parameters and current market state).
 *
 * Env:
 * - LP_PRIVATE_KEY: MM1
 * - LP2_PRIVATE_KEY: MM2
 * - LP3_PRIVATE_KEY: MM3 (out-of-range / extreme band)
 * - PRIVATE_KEY: deployer; also used as taker for swaps
 */

import {MME2EBase} from "./base/MME2EBase.sol";

import {console} from "forge-std/Script.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {PositionId} from "src/types/Position.sol";
import {IVTSOrchestrator} from "src/interfaces/IVTSOrchestrator.sol";
import {MMPositionManager} from "src/MMPositionManager.sol";
import {MMActionAdapter} from "evm-test/utils/MMActionAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Token} from "../setup/MockERC20.s.sol";
import {MarketVTSConfiguration} from "src/types/VTS.sol";
import {RFSCheckpoint} from "src/types/Checkpoint.sol";
import {ILCC} from "src/interfaces/ILCC.sol";

interface IVTSOrchestratorExtraLens {
    function getPool(PoolId poolId)
        external
        view
        returns (
            PoolId id,
            Currency currency0,
            Currency currency1,
            MarketVTSConfiguration memory vtsConfig,
            bool _isPaused
        );

    function positionToCheckpoint(PositionId positionId) external view returns (RFSCheckpoint memory);
}

contract MMCoverageE2E is MME2EBase {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    uint24 internal constant CORE_POOL_FEE = 3000;

    // MM1: smaller liquidity, intended to be “stressable”.
    int24 internal constant MM1_TICK_LOWER = -120;
    int24 internal constant MM1_TICK_UPPER = 180;
    uint128 internal constant MM1_LIQUIDITY = 1e8;

    // MM2: larger liquidity, intended to be the “deep / well-backed” side.
    int24 internal constant MM2_TICK_LOWER = 60;
    int24 internal constant MM2_TICK_UPPER = 180;
    uint128 internal constant MM2_LIQUIDITY = 1e10;

    // MM3: extreme out-of-range band (should not be active near the post-swap tick ~156).
    // NOTE: Keep ticks aligned to common tickSpacing=60.
    int24 internal constant MM3_TICK_LOWER = 180;
    int24 internal constant MM3_TICK_UPPER = 240;
    uint128 internal constant MM3_LIQUIDITY = 1e20;

    // For this scenario we keep magnitudes small (works across forks / avoids hub reserve issues).
    uint256 internal constant WRAP_FOR_SWAPS = 5e7;
    uint128 internal constant SWAP_AMOUNT_IN = 5e7;

    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }

    function _settleRfsRequired(StandaloneMarket memory m, uint256 mmPk, uint256 commitId, int128 need0, int128 need1)
        internal
    {
        // If delta > 0, that amount is required (under-settled). We deposit by settling with a negative int128.
        if (need0 <= 0 && need1 <= 0) return;

        address mm = vm.addr(mmPk);
        PoolKey memory key = _corePoolKey(m);
        MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));

        int128 settle0 = need0 > 0 ? -need0 : int128(0);
        int128 settle1 = need1 > 0 ? -need1 : int128(0);

        uint256 fund0 = need0 > 0 ? uint256(uint128(need0)) : 0;
        uint256 fund1 = need1 > 0 ? uint256(uint128(need1)) : 0;

        vm.startBroadcast(mmPk);
        if (fund0 > 0) {
            Token(m.underlying0).mint(mm, fund0);
            IERC20(m.underlying0).approve(address(mmpm), fund0);
        }
        if (fund1 > 0) {
            Token(m.underlying1).mint(mm, fund1);
            IERC20(m.underlying1).approve(address(mmpm), fund1);
        }

        MMActionAdapter.PreparedAction[] memory acts = new MMActionAdapter.PreparedAction[](1);
        acts[0] = MMActionAdapter.prepareSettle(key, commitId, 0, settle0, settle1, false);
        MMActionAdapter.executeWithUnlock(mmpm, acts, block.timestamp + 3600);
        vm.stopBroadcast();
    }

    function run() external {
        _initNetwork();
        // --- Get all the private keys and addresses of all the market makers and swapper
        uint256 mm1Pk = uint256(vm.envBytes32("LP_PRIVATE_KEY"));
        uint256 mm2Pk = uint256(vm.envBytes32("LP2_PRIVATE_KEY"));
        uint256 mm3Pk = uint256(vm.envBytes32("LP3_PRIVATE_KEY"));
        uint256 takerPk = _getDeployerPrivateKey();

        address mm1 = vm.addr(mm1Pk);
        address mm2 = vm.addr(mm2Pk);
        address mm3 = vm.addr(mm3Pk);
        address takerAddress = vm.addr(takerPk);

        // --- Deploy shared “core” stack (PoolManager + system contracts) and create a market for LCC/LCC swaps.
        CoreDeployment memory d = _deployCoreContracts();
        StandaloneMarket memory m = _createMarket(d, mm1, CORE_POOL_FEE);

        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);
        IVTSOrchestratorExtraLens vtsLens = IVTSOrchestratorExtraLens(m.stack.contracts.vtsOrchestrator);

        // --- Create both MM positions (commit → mint → settle).
        uint256 mm1CommitId = _createMmPosition(m, mm1Pk, MM1_TICK_LOWER, MM1_TICK_UPPER, MM1_LIQUIDITY);
        uint256 mm2CommitId = _createMmPosition(m, mm2Pk, MM2_TICK_LOWER, MM2_TICK_UPPER, MM2_LIQUIDITY);
        uint256 mm3CommitId = _createMmPosition(m, mm3Pk, MM3_TICK_LOWER, MM3_TICK_UPPER, MM3_LIQUIDITY);

        // --- Get the position IDs for all the positions
        PositionId mm1PosId = vts.getPositionId(mm1CommitId, 0);
        PositionId mm2PosId = vts.getPositionId(mm2CommitId, 0);

        // --- Log the addresses and commit IDs for all the positions
        console.log("takerAddress:", takerAddress);
        console.log("mm1:", mm1);
        console.log("mm2:", mm2);
        console.log("mm3:", mm3);
        console.log("mm1CommitId:", mm1CommitId);
        console.log("mm2CommitId:", mm2CommitId);

        PoolKey memory key = _corePoolKey(m);
        // --- Pool should not be paused (sanity check).
        (,,,, bool isPaused) = vtsLens.getPool(key.toId());
        require(!isPaused, "pool: paused");

        // --- Aggressively settle and validate settlement of MM2 to ensure it is well-backed (useful for exploring bonus allocation paths).
        (uint256 mm2Settled0Before, uint256 mm2Settled1Before) = vts.getPositionSettledAmounts(mm2PosId);
        _settleToPosition(m, mm2Pk, mm2CommitId, type(int128).max, type(int128).max);
        (uint256 mm2Settled0After, uint256 mm2Settled1After) = vts.getPositionSettledAmounts(mm2PosId);
        require(mm2Settled0After > mm2Settled0Before && mm2Settled1After > mm2Settled1Before, "mm2: settled not up");

        // --- Get the protocol fee and slashed pot before swaps and validate they are zero
        (uint256 initialProtoFee0, uint256 initialProtoFee1) = vts.getProtocolFeeAccrued(key.toId());
        (uint256 initialPot0, uint256 initialPot1) = vts.getSlashedPot(key.toId());
        require(initialProtoFee0 == 0 && initialProtoFee1 == 0, "initialProtoFee not zero");
        require(initialPot0 == 0 && initialPot1 == 0, "initialPot not zero");

        // --- Generate activity: swap
        uint256 amountOut = _mintAndSwap(m, takerPk, WRAP_FOR_SWAPS, false, SWAP_AMOUNT_IN);

        require(amountOut > 0, "swap amountOut not greater than zero");
        uint256 lcc0AfterSwap = ILCC(m.lcc0).balanceOf(takerAddress);
        uint256 lcc1AfterSwap = ILCC(m.lcc1).balanceOf(takerAddress);
        console.log("lcc0After Swap:", lcc0AfterSwap);
        console.log("lcc1After Swap:", lcc1AfterSwap);

        // Perform some validations on the RFS state of the smaller MM (MM1)
        // After swaps we expect the smaller MM (MM1) to be under-settled (RFS open with a positive requirement).
        (, bool mm1RfsOpen, BalanceDelta mm1RfsDelta) = vts.calcRFS(mm1CommitId, 0, false);
        int128 need0 = mm1RfsDelta.amount0();
        int128 need1 = mm1RfsDelta.amount1();
        require(mm1RfsOpen && (need0 > 0 || need1 > 0), "mm1: expected RFS>0 after swaps");
        // CHECKPOINT should mirror the computed RFS open/closed state.
        require(vtsLens.positionToCheckpoint(mm1PosId).isOpen == mm1RfsOpen, "mm1: checkpoint mismatch");
        // we expect the rest of the MMs to not be open for RFS
        vts.calcRFS(mm2CommitId, 0, true);
        vts.calcRFS(mm3CommitId, 0, true);

        // --- Unwrap all the LCC's that were obtained from the swap in order to enable coverage/settlement flows
        if (lcc0AfterSwap > 0) _unwrapLcc(m, m.lcc0, takerPk, 0, true);
        if (lcc1AfterSwap > 0) _unwrapLcc(m, m.lcc1, takerPk, 0, true);

        // ---Settle for all mms to settle position growths
        _settleRfsRequired(m, mm1Pk, mm1CommitId, type(int128).max, type(int128).max);
        _settleRfsRequired(m, mm2Pk, mm2CommitId, type(int128).max, type(int128).max);
        _settleRfsRequired(m, mm3Pk, mm3CommitId, type(int128).max, type(int128).max);

        // Assert the RFS is now closed (requireClosed=true must not revert; rfsOpen must be false).
        vts.calcRFS(mm1CommitId, 0, true);
        vts.calcRFS(mm2CommitId, 0, true);
        vts.calcRFS(mm3CommitId, 0, true);

        // --- validate the fees accumulates after swaps
        (uint256 protoFee0AfterSwap, uint256 protoFee1AfterSwap) = vts.getProtocolFeeAccrued(key.toId());
        // if theres lcc0 output then it was a oneForZero swap, so the fees should be on token1 and fee1 should be greater than zero
        if (lcc0AfterSwap > 0) require(protoFee1AfterSwap > 0, "protocol Fee1 AfterSwap not greater than zero");
        // if theres lcc1 output then it was a zeroForOne swap, so the fees should be on token0 and fee0 should be greater than zero
        if (lcc1AfterSwap > 0) require(protoFee0AfterSwap > 0, "protocol Fee0 AfterSwap not greater than zero");
        console.log("protocol Fees 0 AfterSwap:", protoFee0AfterSwap);
        console.log("protocol Fees 1 AfterSwap:", protoFee1AfterSwap);

        // --- poke all positions to materialise fee-sharing state
        // poke the position of the first mm, this should materialise the slashed pot, since we expect them to be slashed as they are relatively undersettled to other market makers
        (,, int256 mm1Pending0BeforePoke, int256 mm1Pending1BeforePoke) = vts.getPositionFeeAccounting(mm1PosId);
        // validate the pending fees are equal to the total protocol fees
        require(
            uint256(mm1Pending0BeforePoke) == protoFee0AfterSwap
                && uint256(mm1Pending1BeforePoke) == protoFee1AfterSwap,
            "pending fees not equal to protocol fees"
        );

        (uint256 mm1Amount0Fees, uint256 mm1Amount1Fees) = _pokePosition(m, mm1Pk, mm1CommitId);
        if (lcc0AfterSwap > 0) require(mm1Amount1Fees > 0, "mm1Amount1Fees not greater than zero");
        if (lcc1AfterSwap > 0) require(mm1Amount0Fees > 0, "mm1Amount0Fees not greater than zero");
        // MM1 should be slashed, so right after poking it, the pot should be increased
        (uint256 pot0AfterPokeMM1, uint256 pot1AfterPokeMM1) = vts.getSlashedPot(key.toId());
        // if we have protocol fees0, then the pot for token0 should be greater than zero
        if (protoFee0AfterSwap > 0) {
            require(
                pot0AfterPokeMM1 > 0 && pot0AfterPokeMM1 == protoFee0AfterSwap, "pot0AfterPokeMM1 not greater than zero"
            );
        }
        // if we have protocol fees1, then the pot for token1 should be greater than zero
        if (protoFee1AfterSwap > 0) {
            require(
                pot1AfterPokeMM1 > 0 && pot1AfterPokeMM1 == protoFee1AfterSwap, "pot1AfterPokeMM1 not greater than zero"
            );
        }
        console.log("pot0AfterPokeMM1:", pot0AfterPokeMM1);
        console.log("pot1AfterPokeMM1:", pot1AfterPokeMM1);

        // --- poke the position of the other mms, this should give them their fees and  bonuses
        (uint256 mm2Amount0Fees, uint256 mm2Amount1Fees) = _pokePosition(m, mm2Pk, mm2CommitId);
        if (lcc0AfterSwap > 0) require(mm2Amount1Fees > 0, "mm2Amount1Fees not greater than zero");
        if (lcc1AfterSwap > 0) require(mm2Amount0Fees > 0, "mm2Amount0Fees not greater than zero");
        (uint256 mm3Amount0Fees, uint256 mm3Amount1Fees) = _pokePosition(m, mm3Pk, mm3CommitId);
        if (lcc0AfterSwap > 0) require(mm3Amount1Fees > 0, "mm3Amount1Fees not greater than zero");
        if (lcc1AfterSwap > 0) require(mm3Amount0Fees > 0, "mm3Amount0Fees not greater than zero");

        // pot should be empty now as other mms have taken their earned fees and bonuses
        (uint256 pot0After, uint256 pot1After) = vts.getSlashedPot(key.toId());
        require(pot0After == 0 && pot1After == 0, "pot should be empty");

        (
            uint256 mm1FeesShared0After,
            uint256 mm1FeesShared1After,
            int256 mm1Pending0AfterFeeCollected,
            int256 mm1Pending1AfterFeeCollected
        ) = vts.getPositionFeeAccounting(mm1PosId);
        // all pending fees must have been applied at this point
        require(
            mm1Pending0AfterFeeCollected == 0 && mm1Pending1AfterFeeCollected == 0, "pending fees not equal to zero"
        );
        // validate the fees shared for mm1 is equal to the total pot after poking
        require(
            mm1FeesShared0After == pot0AfterPokeMM1 && mm1FeesShared1After == pot1AfterPokeMM1,
            "fees shared not equal to protocol fees"
        );

        // --- Exit: close RFS (if any), burn → settle-from-deltas → decommit, and withdraw remaining credits.
        _closeRfsBurnDecommitAndTakeAllLccs(m, mm1Pk, mm1CommitId);
        _closeRfsBurnDecommitAndTakeAllLccs(m, mm2Pk, mm2CommitId);
        _closeRfsBurnDecommitAndTakeAllLccs(m, mm3Pk, mm3CommitId);
    }
}


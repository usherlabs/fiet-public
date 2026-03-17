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
import {MMActions} from "src/libraries/MMActions.sol";
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

    struct ActorKeys {
        uint256 mm1Pk;
        uint256 mm2Pk;
        uint256 mm3Pk;
        uint256 takerPk;
    }

    struct ActorAddrs {
        address mm1;
        address mm2;
        address mm3;
        address taker;
    }

    struct ScenarioState {
        StandaloneMarket market;
        PoolKey key;
        IVTSOrchestrator vts;
        IVTSOrchestratorExtraLens vtsLens;
        uint256 mm1CommitId;
        uint256 mm2CommitId;
        uint256 mm3CommitId;
        PositionId mm1PosId;
        PositionId mm2PosId;
    }

    struct SwapState {
        uint256 lcc0AfterSwap;
        uint256 lcc1AfterSwap;
        uint256 protoFee0AfterSwap;
        uint256 protoFee1AfterSwap;
        uint256 pot0AfterPokeMM1;
        uint256 pot1AfterPokeMM1;
    }

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

        bytes memory actions = abi.encodePacked(bytes1(uint8(MMActions.SETTLE_POSITION)));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(key, commitId, 0, settle0, settle1, false);
        mmpm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);
        vm.stopBroadcast();
    }

    function _loadActorKeys() internal view returns (ActorKeys memory keys) {
        keys.mm1Pk = uint256(
            _requireEnvBytes32("LP_PRIVATE_KEY", "Missing LP_PRIVATE_KEY env var (anvil keys can be used directly)")
        );
        keys.mm2Pk = uint256(
            _requireEnvBytes32("LP2_PRIVATE_KEY", "Missing LP2_PRIVATE_KEY env var (anvil keys can be used directly)")
        );
        keys.mm3Pk = uint256(
            _requireEnvBytes32("LP3_PRIVATE_KEY", "Missing LP3_PRIVATE_KEY env var (anvil keys can be used directly)")
        );
        keys.takerPk = _getDeployerPrivateKey();
    }

    function _deriveActors(ActorKeys memory keys) internal view returns (ActorAddrs memory actors) {
        actors.mm1 = vm.addr(keys.mm1Pk);
        actors.mm2 = vm.addr(keys.mm2Pk);
        actors.mm3 = vm.addr(keys.mm3Pk);
        actors.taker = vm.addr(keys.takerPk);
    }

    function _setupScenario(ActorKeys memory keys, ActorAddrs memory actors) internal returns (ScenarioState memory s) {
        CoreDeployment memory d = _deployCoreContracts();
        s.market = _createMarket(d, actors.mm1, CORE_POOL_FEE);
        s.vts = IVTSOrchestrator(s.market.stack.contracts.vtsOrchestrator);
        s.vtsLens = IVTSOrchestratorExtraLens(s.market.stack.contracts.vtsOrchestrator);

        s.mm1CommitId = _createMmPosition(s.market, keys.mm1Pk, MM1_TICK_LOWER, MM1_TICK_UPPER, MM1_LIQUIDITY);
        s.mm2CommitId = _createMmPosition(s.market, keys.mm2Pk, MM2_TICK_LOWER, MM2_TICK_UPPER, MM2_LIQUIDITY);
        s.mm3CommitId = _createMmPosition(s.market, keys.mm3Pk, MM3_TICK_LOWER, MM3_TICK_UPPER, MM3_LIQUIDITY);

        s.mm1PosId = s.vts.getPositionId(s.mm1CommitId, 0);
        s.mm2PosId = s.vts.getPositionId(s.mm2CommitId, 0);
        s.key = _corePoolKey(s.market);

        console.log("takerAddress:", actors.taker);
        console.log("mm1:", actors.mm1);
        console.log("mm2:", actors.mm2);
        console.log("mm3:", actors.mm3);
        console.log("mm1CommitId:", s.mm1CommitId);
        console.log("mm2CommitId:", s.mm2CommitId);
    }

    function _assertPoolAndSettlement(ScenarioState memory s, ActorKeys memory keys) internal {
        (,,,, bool isPaused) = s.vtsLens.getPool(s.key.toId());
        require(!isPaused, "pool: paused");

        (uint256 mm2Settled0Before, uint256 mm2Settled1Before) = s.vts.getPositionSettledAmounts(s.mm2PosId);
        _settleToPosition(s.market, keys.mm2Pk, s.mm2CommitId, type(int128).max, type(int128).max);
        (uint256 mm2Settled0After, uint256 mm2Settled1After) = s.vts.getPositionSettledAmounts(s.mm2PosId);
        require(mm2Settled0After > mm2Settled0Before && mm2Settled1After > mm2Settled1Before, "mm2: settled not up");
    }

    function _assertMm1CheckpointMatchesRfs(ScenarioState memory s, bool mm1RfsOpen) internal view {
        bool checkpointOpen = s.vtsLens.positionToCheckpoint(s.mm1PosId).openMask != 0;
        require(checkpointOpen == mm1RfsOpen, "mm1: checkpoint mismatch");
    }

    function _runSwapAndPreSettlementChecks(ScenarioState memory s, ActorKeys memory keys)
        internal
        returns (SwapState memory swapState)
    {
        (uint256 initialProtoFee0, uint256 initialProtoFee1) = s.vts.getProtocolFeeAccrued(s.key.toId());
        (uint256 initialPot0, uint256 initialPot1) = s.vts.getSlashedPot(s.key.toId());
        require(initialProtoFee0 == 0 && initialProtoFee1 == 0, "initialProtoFee not zero");
        require(initialPot0 == 0 && initialPot1 == 0, "initialPot not zero");

        uint256 amountOut = _mintAndSwap(s.market, keys.takerPk, WRAP_FOR_SWAPS, false, SWAP_AMOUNT_IN);
        require(amountOut > 0, "swap amountOut not greater than zero");

        address taker = vm.addr(keys.takerPk);
        swapState.lcc0AfterSwap = ILCC(s.market.lcc0).balanceOf(taker);
        swapState.lcc1AfterSwap = ILCC(s.market.lcc1).balanceOf(taker);
        console.log("lcc0After Swap:", swapState.lcc0AfterSwap);
        console.log("lcc1After Swap:", swapState.lcc1AfterSwap);

        {
            (, bool mm1RfsOpen, BalanceDelta mm1RfsDelta) = s.vts.calcRFS(s.mm1CommitId, 0, false);
            int128 need0 = mm1RfsDelta.amount0();
            int128 need1 = mm1RfsDelta.amount1();
            require(mm1RfsOpen && (need0 > 0 || need1 > 0), "mm1: expected RFS>0 after swaps");
            _assertMm1CheckpointMatchesRfs(s, mm1RfsOpen);
        }
        s.vts.calcRFS(s.mm2CommitId, 0, true);
        s.vts.calcRFS(s.mm3CommitId, 0, true);

        if (swapState.lcc0AfterSwap > 0) _unwrapLcc(s.market, s.market.lcc0, keys.takerPk, 0, true);
        if (swapState.lcc1AfterSwap > 0) _unwrapLcc(s.market, s.market.lcc1, keys.takerPk, 0, true);

        _settleRfsRequired(s.market, keys.mm1Pk, s.mm1CommitId, type(int128).max, type(int128).max);
        _settleRfsRequired(s.market, keys.mm2Pk, s.mm2CommitId, type(int128).max, type(int128).max);
        _settleRfsRequired(s.market, keys.mm3Pk, s.mm3CommitId, type(int128).max, type(int128).max);

        s.vts.calcRFS(s.mm1CommitId, 0, true);
        s.vts.calcRFS(s.mm2CommitId, 0, true);
        s.vts.calcRFS(s.mm3CommitId, 0, true);
    }

    function _collectMm1FeesAndPot(ScenarioState memory s, ActorKeys memory keys, SwapState memory swapState)
        internal
        returns (SwapState memory)
    {
        (swapState.protoFee0AfterSwap, swapState.protoFee1AfterSwap) = s.vts.getProtocolFeeAccrued(s.key.toId());

        if (swapState.lcc0AfterSwap > 0) {
            require(swapState.protoFee1AfterSwap > 0, "protocol Fee1 AfterSwap not greater than zero");
        }
        if (swapState.lcc1AfterSwap > 0) {
            require(swapState.protoFee0AfterSwap > 0, "protocol Fee0 AfterSwap not greater than zero");
        }
        console.log("protocol Fees 0 AfterSwap:", swapState.protoFee0AfterSwap);
        console.log("protocol Fees 1 AfterSwap:", swapState.protoFee1AfterSwap);

        (,, int256 mm1Pending0BeforePoke, int256 mm1Pending1BeforePoke) = s.vts.getPositionFeeAccounting(s.mm1PosId);
        require(
            uint256(mm1Pending0BeforePoke) == swapState.protoFee0AfterSwap
                && uint256(mm1Pending1BeforePoke) == swapState.protoFee1AfterSwap,
            "pending fees not equal to protocol fees"
        );

        (uint256 mm1Amount0Fees, uint256 mm1Amount1Fees) = _pokePosition(s.market, keys.mm1Pk, s.mm1CommitId);
        if (swapState.lcc0AfterSwap > 0) require(mm1Amount1Fees > 0, "mm1Amount1Fees not greater than zero");
        if (swapState.lcc1AfterSwap > 0) require(mm1Amount0Fees > 0, "mm1Amount0Fees not greater than zero");

        (swapState.pot0AfterPokeMM1, swapState.pot1AfterPokeMM1) = s.vts.getSlashedPot(s.key.toId());
        if (swapState.protoFee0AfterSwap > 0) {
            require(
                swapState.pot0AfterPokeMM1 > 0 && swapState.pot0AfterPokeMM1 == swapState.protoFee0AfterSwap,
                "pot0AfterPokeMM1 not greater than zero"
            );
        }
        if (swapState.protoFee1AfterSwap > 0) {
            require(
                swapState.pot1AfterPokeMM1 > 0 && swapState.pot1AfterPokeMM1 == swapState.protoFee1AfterSwap,
                "pot1AfterPokeMM1 not greater than zero"
            );
        }
        console.log("pot0AfterPokeMM1:", swapState.pot0AfterPokeMM1);
        console.log("pot1AfterPokeMM1:", swapState.pot1AfterPokeMM1);
        return swapState;
    }

    function _pokeRemainingMmsAndAssertPotCleared(ScenarioState memory s, ActorKeys memory keys, SwapState memory swapState)
        internal
    {
        (uint256 mm2Amount0Fees, uint256 mm2Amount1Fees) = _pokePosition(s.market, keys.mm2Pk, s.mm2CommitId);
        if (swapState.lcc0AfterSwap > 0) require(mm2Amount1Fees > 0, "mm2Amount1Fees not greater than zero");
        if (swapState.lcc1AfterSwap > 0) require(mm2Amount0Fees > 0, "mm2Amount0Fees not greater than zero");
        (uint256 mm3Amount0Fees, uint256 mm3Amount1Fees) = _pokePosition(s.market, keys.mm3Pk, s.mm3CommitId);
        if (swapState.lcc0AfterSwap > 0) require(mm3Amount1Fees > 0, "mm3Amount1Fees not greater than zero");
        if (swapState.lcc1AfterSwap > 0) require(mm3Amount0Fees > 0, "mm3Amount0Fees not greater than zero");

        (uint256 pot0After, uint256 pot1After) = s.vts.getSlashedPot(s.key.toId());
        require(pot0After == 0 && pot1After == 0, "pot should be empty");
    }

    function _assertMm1FeeAccounting(ScenarioState memory s, SwapState memory swapState) internal view {
        (
            uint256 mm1FeesShared0After,
            uint256 mm1FeesShared1After,
            int256 mm1Pending0AfterFeeCollected,
            int256 mm1Pending1AfterFeeCollected
        ) = s.vts.getPositionFeeAccounting(s.mm1PosId);
        require(
            mm1Pending0AfterFeeCollected == 0 && mm1Pending1AfterFeeCollected == 0, "pending fees not equal to zero"
        );
        require(
            mm1FeesShared0After == swapState.pot0AfterPokeMM1 && mm1FeesShared1After == swapState.pot1AfterPokeMM1,
            "fees shared not equal to protocol fees"
        );
    }

    function _materialiseFeesAndValidate(ScenarioState memory s, ActorKeys memory keys, SwapState memory swapState)
        internal
        returns (SwapState memory)
    {
        swapState = _collectMm1FeesAndPot(s, keys, swapState);
        _pokeRemainingMmsAndAssertPotCleared(s, keys, swapState);
        _assertMm1FeeAccounting(s, swapState);
        return swapState;
    }

    function _closeAllPositions(ScenarioState memory s, ActorKeys memory keys) internal {
        _closeRfsBurnDecommitAndTakeAllLccs(s.market, keys.mm1Pk, s.mm1CommitId);
        _closeRfsBurnDecommitAndTakeAllLccs(s.market, keys.mm2Pk, s.mm2CommitId);
        _closeRfsBurnDecommitAndTakeAllLccs(s.market, keys.mm3Pk, s.mm3CommitId);
    }

    function run() external {
        console.log("=== E2E: MMCoverage ===");
        _initNetwork();

        ActorKeys memory keys = _loadActorKeys();
        ActorAddrs memory actors = _deriveActors(keys);
        ScenarioState memory scenario = _setupScenario(keys, actors);

        _assertPoolAndSettlement(scenario, keys);
        SwapState memory swapState = _runSwapAndPreSettlementChecks(scenario, keys);
        _materialiseFeesAndValidate(scenario, keys, swapState);
        _closeAllPositions(scenario, keys);
    }
}


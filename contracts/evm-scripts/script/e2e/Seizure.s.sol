// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * E2E: Seizure (guarantor path)
 *
 * Covers four scenarios on isolated markets deployed on one full stack:
 * 1) Single active position: swap -> checkpoint -> grace warp -> guarantor seize + settle-from-deltas + take + AUTH-01A check.
 * 2) Two positions on one commitment: same seize window for indices 0 and 1; sequential single-position seize batches.
 * 3) Two positions on one commitment: same seize window; both positions seized in one guarantor batch.
 * 4) Four positions: commitment backing checkpoint (insolvency visibility), then seize one position index.
 *
 * Env:
 * - PRIVATE_KEY: deployer / taker for swaps
 * - LP_PRIVATE_KEY: MM (position owner)
 * - GUARANTOR_PRIVATE_KEY (optional): third-party seizer. If unset, falls back to LP2_PRIVATE_KEY, then LP3_PRIVATE_KEY (same keys as MMCoverage / multi-MM e2e).
 */

import {MME2EBase} from "./base/MME2EBase.sol";
import {console} from "forge-std/Script.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IVTSOrchestrator} from "src/interfaces/IVTSOrchestrator.sol";
import {IVTSAdmin} from "src/interfaces/IVTSAdmin.sol";
import {MarketVTSConfiguration} from "src/types/VTS.sol";
import {Position} from "src/types/Position.sol";
import {GlobalConfig} from "src/GlobalConfig.sol";

contract SeizureE2E is MME2EBase {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant CORE_POOL_FEE = 3000;

    uint128 internal constant MM_LIQ = 1e10;
    int24 internal constant TICK_A_LO = -60;
    int24 internal constant TICK_A_HI = 60;

    uint256 internal constant WRAP_FOR_SWAPS = 500_000 ether;

    /// @dev Prefer `GUARANTOR_PRIVATE_KEY`; otherwise `LP2_PRIVATE_KEY`, then `LP3_PRIVATE_KEY` (multi-actor e2e convention).
    function _loadGuarantorPk() internal view returns (uint256 pk) {
        try vm.envBytes32("GUARANTOR_PRIVATE_KEY") returns (bytes32 v) {
            return uint256(v);
        } catch {}
        try vm.envBytes32("LP2_PRIVATE_KEY") returns (bytes32 v2) {
            return uint256(v2);
        } catch {}
        pk = uint256(
            _requireEnvBytes32(
                "LP3_PRIVATE_KEY",
                "Missing guarantor key: set GUARANTOR_PRIVATE_KEY, or LP2_PRIVATE_KEY, or LP3_PRIVATE_KEY"
            )
        );
    }

    function _loadMmPrivateKey() internal view returns (uint256 mmPk) {
        mmPk = uint256(
            _requireEnvBytes32("LP_PRIVATE_KEY", "Missing LP_PRIVATE_KEY env var (anvil keys can be used directly)")
        );
    }

    /// @dev Forge script simulation does not replay `vm.warp`, so make seize windows deterministic by removing grace.
    function _setZeroSeizureGrace(StandaloneMarket memory m) internal {
        MarketVTSConfiguration memory cfg = _defaultE2EVTSConfig();
        cfg.token0.gracePeriodTime = 0;
        cfg.token0.maxGracePeriodTime = 0;
        cfg.token1.gracePeriodTime = 0;
        cfg.token1.maxGracePeriodTime = 0;

        vm.startBroadcast(_getDeployerPrivateKey());
        GlobalConfig(m.stack.contracts.globalConfig).proxyCall(
            m.stack.contracts.vtsOrchestrator,
            abi.encodeWithSelector(IVTSAdmin.setMarketVTSConfiguration.selector, _corePoolKey(m).toId(), cfg)
        );
        vm.stopBroadcast();
    }

    function _scenarioSingle(CoreDeployment memory core, uint256 mmPk, uint256 guarantorPk, uint256 takerPk) internal {
        console.log("--- Scenario 1: single-position seizure ---");
        StandaloneMarket memory m = _createMarket(core, vm.addr(mmPk), CORE_POOL_FEE);
        _setZeroSeizureGrace(m);
        uint256 commitId = _createMmPosition(m, mmPk, TICK_A_LO, TICK_A_HI, MM_LIQ);

        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);
        (Position memory posBefore,) = vts.getPosition(commitId, 0);
        uint128 liqBefore = posBefore.liquidity;

        _openSeizeWindowForPosition(m, takerPk, mmPk, commitId, 0, WRAP_FOR_SWAPS);

        require(vm.addr(guarantorPk) != vm.addr(mmPk), "e2e: guarantor must not be MM owner");

        _guarantorSeizeSettleFromDeltasAndTake(
            m, guarantorPk, commitId, 0, SEIZURE_SETTLE_AMOUNT_MAX, SEIZURE_SETTLE_AMOUNT_MAX
        );

        (Position memory posAfter,) = vts.getPosition(commitId, 0);
        require(uint256(posAfter.liquidity) < uint256(liqBefore), "e2e: liquidity should drop after seizure");

        address lcc0 = Currency.unwrap(_corePoolKey(m).currency0);
        address lcc1 = Currency.unwrap(_corePoolKey(m).currency1);
        address g = vm.addr(guarantorPk);
        require(
            IERC20(lcc0).balanceOf(g) + IERC20(lcc1).balanceOf(g) > 0,
            "e2e: guarantor should receive LCC after seize+take"
        );

        _assertNotApprovedOnGuarantorSettleAfterSeize(m, guarantorPk, commitId, 0);
        console.log("OK: scenario 1 complete");
    }

    function _scenarioTwoPositionsSequentialSingleBatches(
        CoreDeployment memory core,
        uint256 mmPk,
        uint256 guarantorPk,
        uint256 takerPk
    ) internal {
        console.log("--- Scenario 2: two positions, sequential single-position seizure batches ---");
        StandaloneMarket memory m = _createMarket(core, vm.addr(mmPk), CORE_POOL_FEE);
        _setZeroSeizureGrace(m);
        PositionSeed[] memory seeds = new PositionSeed[](2);
        seeds[0] = PositionSeed({tickLower: TICK_A_LO, tickUpper: TICK_A_HI, liquidity: MM_LIQ});
        // Same tick band as index 0 so one stress swap opens RFS on both (distinct salts / liquidity chunks).
        seeds[1] = PositionSeed({tickLower: TICK_A_LO, tickUpper: TICK_A_HI, liquidity: MM_LIQ / 10});
        uint256 commitId = _createMmPositionBatch(m, mmPk, seeds);

        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);
        (Position memory p0a,) = vts.getPosition(commitId, 0);
        (Position memory p1a,) = vts.getPosition(commitId, 1);

        uint256[] memory idx = new uint256[](2);
        idx[0] = 0;
        idx[1] = 1;
        _openSeizeWindowForPositions(m, takerPk, mmPk, commitId, idx, WRAP_FOR_SWAPS);

        _guarantorSeizeSettleFromDeltasAndTake(
            m, guarantorPk, commitId, 0, SEIZURE_SETTLE_AMOUNT_MAX, SEIZURE_SETTLE_AMOUNT_MAX
        );
        (Position memory p0b,) = vts.getPosition(commitId, 0);
        require(uint256(p0b.liquidity) < uint256(p0a.liquidity), "e2e: pos0 liquidity should drop");

        _guarantorSeizeSettleFromDeltasAndTake(
            m, guarantorPk, commitId, 1, SEIZURE_SETTLE_AMOUNT_MAX, SEIZURE_SETTLE_AMOUNT_MAX
        );
        (Position memory p1b,) = vts.getPosition(commitId, 1);
        require(uint256(p1b.liquidity) < uint256(p1a.liquidity), "e2e: pos1 liquidity should drop");

        _assertNotApprovedOnGuarantorSettleAfterSeize(m, guarantorPk, commitId, 1);
        console.log("OK: scenario 2 complete");
    }

    function _scenarioTwoPositionsSingleGuarantorBatch(
        CoreDeployment memory core,
        uint256 mmPk,
        uint256 guarantorPk,
        uint256 takerPk
    ) internal {
        console.log("--- Scenario 3: two positions, single guarantor multi-seize batch ---");
        StandaloneMarket memory m = _createMarket(core, vm.addr(mmPk), CORE_POOL_FEE);
        _setZeroSeizureGrace(m);
        PositionSeed[] memory seeds = new PositionSeed[](2);
        seeds[0] = PositionSeed({tickLower: TICK_A_LO, tickUpper: TICK_A_HI, liquidity: MM_LIQ});
        seeds[1] = PositionSeed({tickLower: TICK_A_LO, tickUpper: TICK_A_HI, liquidity: MM_LIQ / 10});
        uint256 commitId = _createMmPositionBatch(m, mmPk, seeds);

        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);
        (Position memory p0a,) = vts.getPosition(commitId, 0);
        (Position memory p1a,) = vts.getPosition(commitId, 1);

        uint256[] memory idx = new uint256[](2);
        idx[0] = 0;
        idx[1] = 1;
        _openSeizeWindowForPositions(m, takerPk, mmPk, commitId, idx, WRAP_FOR_SWAPS);

        uint256[] memory settleCap0 = new uint256[](2);
        uint256[] memory settleCap1 = new uint256[](2);
        settleCap0[0] = SEIZURE_SETTLE_AMOUNT_MAX;
        settleCap0[1] = SEIZURE_SETTLE_AMOUNT_MAX;
        settleCap1[0] = SEIZURE_SETTLE_AMOUNT_MAX;
        settleCap1[1] = SEIZURE_SETTLE_AMOUNT_MAX;
        _guarantorSeizeManySettleFromDeltasAndTake(m, guarantorPk, commitId, idx, settleCap0, settleCap1);

        (Position memory p0b,) = vts.getPosition(commitId, 0);
        (Position memory p1b,) = vts.getPosition(commitId, 1);
        require(uint256(p0b.liquidity) < uint256(p0a.liquidity), "e2e: pos0 liquidity should drop");
        require(uint256(p1b.liquidity) < uint256(p1a.liquidity), "e2e: pos1 liquidity should drop");

        _assertNotApprovedOnGuarantorSettleAfterSeize(m, guarantorPk, commitId, 1);
        console.log("OK: scenario 3 complete");
    }

    function _scenarioFourPositionsWithCommitmentCheckpoint(
        CoreDeployment memory core,
        uint256 mmPk,
        uint256 guarantorPk,
        uint256 takerPk
    ) internal {
        console.log("--- Scenario 4: four positions + commitment checkpoint + seizure ---");
        StandaloneMarket memory m = _createMarket(core, vm.addr(mmPk), CORE_POOL_FEE);
        _setZeroSeizureGrace(m);
        PositionSeed[] memory seeds = new PositionSeed[](4);
        seeds[0] = PositionSeed({tickLower: TICK_A_LO, tickUpper: TICK_A_HI, liquidity: MM_LIQ});
        // Narrow satellite bands (tickSpacing=60), distinct salts implied by sequential mints.
        seeds[1] = PositionSeed({tickLower: -120, tickUpper: -60, liquidity: MM_LIQ / 20});
        seeds[2] = PositionSeed({tickLower: 60, tickUpper: 120, liquidity: MM_LIQ / 20});
        seeds[3] = PositionSeed({tickLower: -180, tickUpper: 180, liquidity: MM_LIQ / 50});
        uint256 commitId = _createMmPositionBatch(m, mmPk, seeds);

        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);
        (, , uint256 pc,,) = vts.getCommit(commitId);
        require(pc == 4, "e2e: expected 4 positions on commit");

        // Run commitment backing on each position to surface / refresh deficit accounting (insolvency visibility).
        uint256[] memory checkpointIdx = new uint256[](4);
        checkpointIdx[0] = 0;
        checkpointIdx[1] = 1;
        checkpointIdx[2] = 2;
        checkpointIdx[3] = 3;
        _checkpointPositionsBatch(m, mmPk, commitId, checkpointIdx, true);

        // Seize index 0 (primary in-range band); satellite positions exist to satisfy the "four positions" commit shape.
        (Position memory posBefore,) = vts.getPosition(commitId, 0);

        _openSeizeWindowForPosition(m, takerPk, mmPk, commitId, 0, WRAP_FOR_SWAPS);

        _guarantorSeizeSettleFromDeltasAndTake(
            m, guarantorPk, commitId, 0, SEIZURE_SETTLE_AMOUNT_MAX, SEIZURE_SETTLE_AMOUNT_MAX
        );

        (Position memory posAfter,) = vts.getPosition(commitId, 0);
        require(uint256(posAfter.liquidity) < uint256(posBefore.liquidity), "e2e: seized position liquidity should drop");

        PoolKey memory key = _corePoolKey(m);
        address g = vm.addr(guarantorPk);
        require(
            IERC20(Currency.unwrap(key.currency0)).balanceOf(g)
                + IERC20(Currency.unwrap(key.currency1)).balanceOf(g)
                > 0,
            "e2e: guarantor should receive LCC on scenario 4"
        );

        _assertNotApprovedOnGuarantorSettleAfterSeize(m, guarantorPk, commitId, 0);
        console.log("OK: scenario 4 complete");
    }

    function run() external {
        console.log("=== E2E: Seizure (guarantor) ===");
        _initNetwork();

        uint256 mmPk = _loadMmPrivateKey();
        uint256 guarantorPk = _loadGuarantorPk();
        uint256 takerPk = _getDeployerPrivateKey();

        require(vm.addr(guarantorPk) != vm.addr(mmPk), "guarantor key must differ from LP_PRIVATE_KEY (use GUARANTOR_PRIVATE_KEY or LP2_PRIVATE_KEY)");

        CoreDeployment memory core = _deployCoreContracts();
        _scenarioSingle(core, mmPk, guarantorPk, takerPk);
        _scenarioTwoPositionsSequentialSingleBatches(core, mmPk, guarantorPk, takerPk);
        _scenarioTwoPositionsSingleGuarantorBatch(core, mmPk, guarantorPk, takerPk);
        _scenarioFourPositionsWithCommitmentCheckpoint(core, mmPk, guarantorPk, takerPk);

        console.log("=== E2E: Seizure - all scenarios passed ===");
    }
}

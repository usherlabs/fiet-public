// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * E2E: MM adaptive round-trip trading → full drain → decommit (matrix)
 *
 * Uses `_runAdaptiveRoundTripTradingPhase` to move price back toward the starting tick after a large sweep.
 */

import {console} from "forge-std/Script.sol";

import {MME2EBase} from "./base/MME2EBase.sol";

contract MarketMakerServiceableRoundTripE2E is MME2EBase {
    uint24 internal constant CORE_POOL_FEE = 3000;

    function _loadMmPrivateKey() internal view returns (uint256 mmPk) {
        mmPk = uint256(
            _requireEnvBytes32("LP_PRIVATE_KEY", "Missing LP_PRIVATE_KEY env var (anvil keys can be used directly)")
        );
    }

    function run() external {
        console.log("=== E2E: MM Serviceable round-trip matrix ===");
        _initNetwork();

        uint256 mmPk = _loadMmPrivateKey();
        uint256 directLpPk = _getDeployerPrivateKey();
        CoreDeployment memory d = _deployCoreContracts();
        PositionProfileE2E[] memory profiles = _mmPositionProfilesAll();
        BufferModeE2E[] memory buffers = _mmBufferModesAll();

        MakerHealthSnapshotE2E[] memory unbufAfterTrade = new MakerHealthSnapshotE2E[](profiles.length);

        for (uint256 i = 0; i < profiles.length; i++) {
            for (uint256 j = 0; j < buffers.length; j++) {
                StandaloneMarket memory m = _createMarket(d, vm.addr(mmPk), CORE_POOL_FEE);
                uint256 commitId = _createMmPositionFromProfile(m, mmPk, profiles[i]);

                _logMakerHealth(
                    string.concat("initial [", profiles[i].name, "][", buffers[j].name, "]"),
                    _snapshotMakerHealth(m, commitId, 0)
                );

                _seedDirectLPBufferIfEnabled(m, directLpPk, buffers[j]);

                uint256 takerPk = _getDeployerPrivateKey();
                _runAdaptiveRoundTripTradingPhase(m, mmPk, takerPk, commitId, MM_E2E_BIG_SWAP_IN, 100e18, 40);

                MakerHealthSnapshotE2E memory ht = _snapshotMakerHealth(m, commitId, 0);
                _logMakerHealth(
                    string.concat("after adaptive trade [", profiles[i].name, "][", buffers[j].name, "]"), ht
                );

                if (j == 0) {
                    unbufAfterTrade[i] = ht;
                } else {
                    _assertMakerHealthNotWorseWithBuffer(ht, unbufAfterTrade[i]);
                }

                _settleRfsIfOpen(m, mmPk, commitId);
                _logMakerHealth(
                    string.concat("after RFS [", profiles[i].name, "][", buffers[j].name, "]"),
                    _snapshotMakerHealth(m, commitId, 0)
                );

                _burnAndRealiseExitCredits(m, mmPk, commitId, 0);
                _logMakerHealth(
                    string.concat("after burn [", profiles[i].name, "][", buffers[j].name, "]"),
                    _snapshotMakerHealth(m, commitId, 0)
                );

                _assertDrainableAndFullyDrained(m, mmPk, commitId, 0, 48);
                _decommitAndTakeAllLccs(m, mmPk, commitId);
                _unwrapAllLccsAndAssert(m, mmPk, commitId, 0, true);

                console.log("OK: round-trip cell complete");
            }
        }
    }
}

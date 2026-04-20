// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * E2E: MM modest swaps (matrix)
 *
 * Asserts the pool tick stays away from extreme boundaries after small two-way volume, then classifies
 * exit outcome via a best-effort inactive drain (full exit when serviceable; blocked decommit otherwise).
 */

import {console} from "forge-std/Script.sol";

import {MME2EBase} from "./base/MME2EBase.sol";

contract MarketMakerModestSwapE2E is MME2EBase {
    uint24 internal constant CORE_POOL_FEE = 3000;

    function _loadMmPrivateKey() internal view returns (uint256 mmPk) {
        mmPk = uint256(
            _requireEnvBytes32("LP_PRIVATE_KEY", "Missing LP_PRIVATE_KEY env var (anvil keys can be used directly)")
        );
    }

    function run() external {
        console.log("=== E2E: MM Modest swap matrix ===");
        _initNetwork();

        uint256 mmPk = _loadMmPrivateKey();
        uint256 directLpPk = _getDeployerPrivateKey();
        CoreDeployment memory d = _deployCoreContracts();
        PositionProfileE2E[] memory profiles = _mmPositionProfilesAll();
        BufferModeE2E[] memory buffers = _mmBufferModesAll();

        MakerHealthSnapshotE2E[] memory unbufAfterBurn = new MakerHealthSnapshotE2E[](profiles.length);

        for (uint256 i = 0; i < profiles.length; i++) {
            for (uint256 j = 0; j < buffers.length; j++) {
                StandaloneMarket memory m = _createMarket(d, vm.addr(mmPk), CORE_POOL_FEE);
                uint256 commitId = _createMmPositionFromProfile(m, mmPk, profiles[i]);

                _seedDirectLPBufferIfEnabled(m, directLpPk, buffers[j]);

                uint256 takerPk = _getDeployerPrivateKey();
                _runModestTradingPhase(m, mmPk, takerPk, commitId);
                _assertTickNotExtreme(m);

                _logMakerHealth(
                    string.concat("after modest trade [", profiles[i].name, "][", buffers[j].name, "]"),
                    _snapshotMakerHealth(m, commitId, 0)
                );

                _settleRfsIfOpen(m, mmPk, commitId);
                _burnAndRealiseExitCredits(m, mmPk, commitId, 0);

                MakerHealthSnapshotE2E memory hb = _snapshotMakerHealth(m, commitId, 0);
                _logMakerHealth(string.concat("after burn [", profiles[i].name, "][", buffers[j].name, "]"), hb);

                if (j == 0) {
                    unbufAfterBurn[i] = hb;
                } else {
                    _assertMakerHealthNotWorseWithBuffer(hb, unbufAfterBurn[i]);
                }

                bool drained = _drainInactivePositionSurplusBestEffort(m, mmPk, commitId, 0, 32);
                if (drained) {
                    _decommitAndTakeAllLccs(m, mmPk, commitId);
                    _unwrapAllLccsAndAssert(m, mmPk, commitId, 0, true);
                    console.log("OK: modest path fully serviceable in this cell");
                } else {
                    _assertRecognisedUnserviceableOverflowBeforeRebalance(m, mmPk, commitId, 0);
                    console.log("OK: modest path left inactive remnant (classified)");
                }
            }
        }
    }
}

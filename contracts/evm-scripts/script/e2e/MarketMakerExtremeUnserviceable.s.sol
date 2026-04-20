// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * E2E: MM extreme sweep → unserviceable remnant (matrix)
 *
 * Iterates `PositionProfile` × `BufferMode`. The baseline cell (`tightTiny`, no DirectLP buffer)
 * asserts stalled inactive drain + blocked decommit. Buffered runs assert they are not materially
 * worse than the corresponding unbuffered burn snapshot for the same profile.
 */

import {console} from "forge-std/Script.sol";

import {MME2EBase} from "./base/MME2EBase.sol";

contract MarketMakerExtremeUnserviceableE2E is MME2EBase {
    uint24 internal constant CORE_POOL_FEE = 3000;

    function _loadMmPrivateKey() internal view returns (uint256 mmPk) {
        mmPk = uint256(
            _requireEnvBytes32("LP_PRIVATE_KEY", "Missing LP_PRIVATE_KEY env var (anvil keys can be used directly)")
        );
    }

    function run() external {
        console.log("=== E2E: MM Extreme / Unserviceable remnant matrix ===");
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

                _logMakerHealth(
                    string.concat("initial settle [", profiles[i].name, "][", buffers[j].name, "]"),
                    _snapshotMakerHealth(m, commitId, 0)
                );

                uint256 tokenIdCoreLp = _seedDirectLPBufferIfEnabled(m, directLpPk, buffers[j]);
                if (tokenIdCoreLp > 0) {
                    console.log("DirectLP buffer tokenId:", tokenIdCoreLp);
                }

                _logMakerHealth(
                    string.concat("after buffer seed [", profiles[i].name, "][", buffers[j].name, "]"),
                    _snapshotMakerHealth(m, commitId, 0)
                );

                uint256 takerPk = _getDeployerPrivateKey();
                _runExtremeTradingPhase(m, mmPk, takerPk, commitId);

                _logMakerHealth(
                    string.concat("after trading [", profiles[i].name, "][", buffers[j].name, "]"),
                    _snapshotMakerHealth(m, commitId, 0)
                );

                _settleRfsIfOpen(m, mmPk, commitId);

                _logMakerHealth(
                    string.concat("after RFS close [", profiles[i].name, "][", buffers[j].name, "]"),
                    _snapshotMakerHealth(m, commitId, 0)
                );

                _burnAndRealiseExitCredits(m, mmPk, commitId, 0);

                MakerHealthSnapshotE2E memory hb = _snapshotMakerHealth(m, commitId, 0);
                _logMakerHealth(string.concat("after burn [", profiles[i].name, "][", buffers[j].name, "]"), hb);

                if (j == 0) {
                    unbufAfterBurn[i] = hb;
                } else {
                    _assertMakerHealthNotWorseWithBuffer(hb, unbufAfterBurn[i]);
                }

                if (_isTightTinyProfile(profiles[i]) && !buffers[j].seedDirectLP) {
                    _assertUnserviceableRemnantAfterBurn(m, mmPk, commitId, 0);
                } else {
                    bool drained = _drainInactivePositionSurplusBestEffort(m, mmPk, commitId, 0, 32);
                    if (drained) {
                        _decommitAndTakeAllLccs(m, mmPk, commitId);
                        _unwrapAllLccsAndAssert(m, mmPk, commitId, 0, true);
                        console.log("OK: full exit (serviceable in this cell)");
                    } else {
                        _assertCommitNotDrainedOnDecommit(m, mmPk, commitId);
                        console.log("OK: decommit blocked as expected (unserviceable in this cell)");
                    }
                }
            }
        }
    }
}

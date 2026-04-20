// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * E2E: MM wide/deep stress vs `tightTiny` baseline (matrix)
 *
 * Captures the unbuffered `tightTiny` burn snapshot as a baseline, then asserts wider/deeper profiles
 * achieve strictly better combined effective+overflow economic posture when compared to that baseline.
 */

import {console} from "forge-std/Script.sol";

import {MME2EBase} from "./base/MME2EBase.sol";

contract MarketMakerWideOrDeepStressE2E is MME2EBase {
    uint24 internal constant CORE_POOL_FEE = 3000;

    function _loadMmPrivateKey() internal view returns (uint256 mmPk) {
        mmPk = uint256(
            _requireEnvBytes32("LP_PRIVATE_KEY", "Missing LP_PRIVATE_KEY env var (anvil keys can be used directly)")
        );
    }

    function run() external {
        console.log("=== E2E: MM Wide/deep stress matrix ===");
        _initNetwork();

        uint256 mmPk = _loadMmPrivateKey();
        uint256 directLpPk = _getDeployerPrivateKey();
        CoreDeployment memory d = _deployCoreContracts();
        PositionProfileE2E[] memory profiles = _mmPositionProfilesAll();
        BufferModeE2E[] memory buffers = _mmBufferModesAll();

        MakerHealthSnapshotE2E[] memory baselineTightTiny = new MakerHealthSnapshotE2E[](buffers.length);
        bool[] memory haveBaseline = new bool[](buffers.length);

        for (uint256 i = 0; i < profiles.length; i++) {
            for (uint256 j = 0; j < buffers.length; j++) {
                StandaloneMarket memory m = _createMarket(d, vm.addr(mmPk), CORE_POOL_FEE);
                uint256 commitId = _createMmPositionFromProfile(m, mmPk, profiles[i]);

                _seedDirectLPBufferIfEnabled(m, directLpPk, buffers[j]);

                uint256 takerPk = _getDeployerPrivateKey();
                _runWideOrDeepStressTradingPhase(m, mmPk, takerPk, commitId);

                _settleRfsIfOpen(m, mmPk, commitId);
                _burnAndRealiseExitCredits(m, mmPk, commitId, 0);

                MakerHealthSnapshotE2E memory hb = _snapshotMakerHealth(m, commitId, 0);
                _logMakerHealth(string.concat("after burn [", profiles[i].name, "][", buffers[j].name, "]"), hb);

                if (_mmProfileNameEq(profiles[i], "tightTiny")) {
                    baselineTightTiny[j] = hb;
                    haveBaseline[j] = true;
                } else {
                    require(haveBaseline[j], "e2e: missing tightTiny baseline row before comparison");
                    _assertImprovedServiceabilityVsBaseline(hb, baselineTightTiny[j]);
                }

                bool drained = _drainInactivePositionSurplusBestEffort(m, mmPk, commitId, 0, 32);
                if (_mmProfileNameEq(profiles[i], "wideDeep") && buffers[j].seedDirectLP) {
                    require(drained, "e2e: wideDeep buffered cell should fully drain");
                }
                if (drained) {
                    _decommitAndTakeAllLccs(m, mmPk, commitId);
                    _unwrapAllLccsAndAssert(m, mmPk, commitId, 0, true);
                } else {
                    _assertCommitNotDrainedOnDecommit(m, mmPk, commitId);
                }

                console.log("OK: wide/deep stress cell processed");
            }
        }

        require(haveBaseline[0] && haveBaseline[1], "e2e: missing tightTiny baseline rows for both buffer modes");
    }
}

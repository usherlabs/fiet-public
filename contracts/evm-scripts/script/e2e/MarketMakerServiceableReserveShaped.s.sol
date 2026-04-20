// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * E2E: MM reserve-shaped trading (no single extreme sweep) → full exit (matrix)
 *
 * Uses several modest two-way rounds to accumulate fees without pinning the pool tick to extremes.
 */

import {console} from "forge-std/Script.sol";

import {Errors} from "src/libraries/Errors.sol";

import {MME2EBase} from "./base/MME2EBase.sol";

contract MarketMakerServiceableReserveShapedE2E is MME2EBase {
    uint24 internal constant CORE_POOL_FEE = 3000;

    function _loadMmPrivateKey() internal view returns (uint256 mmPk) {
        mmPk = uint256(
            _requireEnvBytes32("LP_PRIVATE_KEY", "Missing LP_PRIVATE_KEY env var (anvil keys can be used directly)")
        );
    }

    function run() external {
        console.log("=== E2E: MM Serviceable reserve-shaped matrix ===");
        _initNetwork();

        uint256 mmPk = _loadMmPrivateKey();
        uint256 directLpPk = _getDeployerPrivateKey();
        PositionProfileE2E[] memory profiles = _mmPositionProfilesAll();
        BufferModeE2E[] memory buffers = _mmBufferModesAll();

        MakerHealthSnapshotE2E[] memory unbufAfterBurn = new MakerHealthSnapshotE2E[](profiles.length);

        for (uint256 i = 0; i < profiles.length; i++) {
            for (uint256 j = 0; j < buffers.length; j++) {
                StandaloneMarket memory m = _deployAndCreateMarket(vm.addr(mmPk), CORE_POOL_FEE);
                uint256 commitId = _createMmPositionFromProfile(m, mmPk, profiles[i]);

                _seedDirectLPBufferIfEnabled(m, directLpPk, buffers[j]);

                uint256 takerPk = _getDeployerPrivateKey();
                _runReserveShapedTradingAndExitSetup(m, mmPk, takerPk, commitId);

                _logMakerHealth(
                    string.concat("after reserve-shaped trade [", profiles[i].name, "][", buffers[j].name, "]"),
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

                bool drained = _drainInactivePositionSurplusBestEffort(m, mmPk, commitId, 0, 48);
                if (!drained) {
                    vm.expectRevert(abi.encodeWithSelector(Errors.CommitNotDrained.selector, commitId));
                    _decommitAndTakeAllLccs(m, mmPk, commitId);
                    console.log("SKIP: cell not fully serviceable under reserve-shaped path");
                    continue;
                }

                _decommitAndTakeAllLccs(m, mmPk, commitId);
                _unwrapAllLccsAndAssert(m, mmPk, commitId, 0, true);
                console.log("OK: reserve-shaped cell fully exited");
            }
        }
    }
}

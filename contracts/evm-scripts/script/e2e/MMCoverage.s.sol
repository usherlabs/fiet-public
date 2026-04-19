// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

/**
 * @notice **Retired.** This scenario previously exercised MM flows against `getSlashedPot`, `getPositionFeeAccounting`,
 *         and related fee-pot materialisation. Those orchestrator surfaces were removed with fee disablement.
 *
 *         For historical behaviour, see git history. For current MM / settlement E2E coverage, use the other scripts
 *         under `script/e2e/`.
 */
contract MMCoverageE2E is Script {
    function run() external pure {
        revert("MMCoverageE2E retired: fee-pot and position fee-accounting lens removed from IVTSOrchestrator");
    }
}

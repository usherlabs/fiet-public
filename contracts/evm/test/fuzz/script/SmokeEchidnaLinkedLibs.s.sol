// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {EchidnaLinkedLibs} from "../base/EchidnaLinkedLibs.sol";

contract EchidnaLinkedLibSmokeRunner {
    function run() external {
        EchidnaLinkedLibs.deployLCCFactoryLinkedLib();
        EchidnaLinkedLibs.deployLiquidityHubLinkedLib();
        EchidnaLinkedLibs.deployVTSCommitLib();
        EchidnaLinkedLibs.deployVTSFeeLinkedLib();
        EchidnaLinkedLibs.deployVTSPositionLib();
        EchidnaLinkedLibs.deployVTSPositionMMOpsLib();
        EchidnaLinkedLibs.deployVTSLifecycleLinkedLib();
    }
}

/// @notice Smokes the fuzz linked-library deployment helpers used by harness constructors.
/// @dev This validates the actual precondition the suite relies on without re-checking CREATE2 maths here.
contract SmokeEchidnaLinkedLibs is Script {
    /// @dev Medusa deploys the single-target harness contract at this deterministic address
    ///      when using deployer `0x30000` and nonce `0`.
    address internal constant FUZZ_HARNESS_DEPLOYER = 0xA647ff3c36cFab592509E13860ab8c4F28781a66;

    function run() external {
        console2.log("Smoking fuzz linked library deployments...");

        // Execute the helper calls from the same deterministic address Medusa assigns to the
        // single-target harness contract, so CREATE2 uses the real deployer for these libraries.
        EchidnaLinkedLibSmokeRunner runner = new EchidnaLinkedLibSmokeRunner();
        vm.etch(FUZZ_HARNESS_DEPLOYER, address(runner).code);

        (bool ok, bytes memory revertData) =
            FUZZ_HARNESS_DEPLOYER.call(abi.encodeCall(EchidnaLinkedLibSmokeRunner.run, ()));
        if (!ok) _bubbleRevert(revertData);

        console2.log("Fuzz linked libraries deployed at the expected addresses.");
    }

    function _bubbleRevert(bytes memory revertData) internal pure {
        if (revertData.length == 0) revert("SmokeEchidnaLinkedLibs: deployment failed");
        assembly {
            revert(add(revertData, 0x20), mload(revertData))
        }
    }
}

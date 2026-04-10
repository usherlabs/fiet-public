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
    }
}

/// @notice Smokes the Echidna linked-library deployment helpers used by fuzz harness constructors.
/// @dev This validates the actual precondition the suite relies on without re-checking CREATE2 maths here.
contract SmokeEchidnaLinkedLibs is Script {
    /// @dev Echidna deploys the harness contract at this deterministic address.
    address internal constant ECHIDNA_DEPLOYER = 0x00a329c0648769A73afAc7F9381E08FB43dBEA72;

    function run() external {
        console2.log("Smoking Echidna linked library deployments...");

        // Execute the helper calls from the same deterministic address that Echidna assigns
        // to the harness contract, so CREATE2 uses the real deployer for these libraries.
        EchidnaLinkedLibSmokeRunner runner = new EchidnaLinkedLibSmokeRunner();
        vm.etch(ECHIDNA_DEPLOYER, address(runner).code);

        (bool ok, bytes memory revertData) = ECHIDNA_DEPLOYER.call(abi.encodeCall(EchidnaLinkedLibSmokeRunner.run, ()));
        if (!ok) _bubbleRevert(revertData);

        console2.log("Echidna linked libraries deployed at the expected addresses.");
    }

    function _bubbleRevert(bytes memory revertData) internal pure {
        if (revertData.length == 0) revert("SmokeEchidnaLinkedLibs: deployment failed");
        assembly {
            revert(add(revertData, 0x20), mload(revertData))
        }
    }
}

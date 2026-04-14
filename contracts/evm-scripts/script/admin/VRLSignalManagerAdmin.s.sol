// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * Admin: VRLSignalManager owner functions
 *
 * Run:
 * - `just admin-vrl-signal-set-verifier`
 *
 * Env:
 * - PRIVATE_KEY
 * - NETWORK
 *
 * For setVerifier:
 * - NEW_VERIFIER: address
 */

import {console} from "forge-std/Script.sol";
import {AdminBase} from "./AdminBase.sol";

interface IOwnableView {
    function owner() external view returns (address);
}

interface IVRLSignalManagerAdmin {
    function setVerifier(address newVerifier) external;
}

contract VRLSignalManagerSetVerifierScript is AdminBase {
    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address newVerifier = vm.envAddress("NEW_VERIFIER");

        _loadAdminAddresses();
        address owner = IOwnableView(signalManager).owner();

        console.log("NETWORK:", networkName);
        console.log("VRLSignalManager:", signalManager);
        console.log("owner:", owner);
        console.log("GlobalConfig:", globalConfig);
        console.log("NEW_VERIFIER:", newVerifier);

        vm.startBroadcast(pk);
        if (owner == globalConfig) {
            _proxyCall(signalManager, abi.encodeCall(IVRLSignalManagerAdmin.setVerifier, (newVerifier)));
        } else {
            IVRLSignalManagerAdmin(signalManager).setVerifier(newVerifier);
        }
        vm.stopBroadcast();

        console.log("OK: setVerifier");
    }
}


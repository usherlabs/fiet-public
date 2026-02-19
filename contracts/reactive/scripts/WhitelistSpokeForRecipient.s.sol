// SPDX-License-Identifier: UNLICENSED
// register a spoke for a recipient on an already deployed HubCallback
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {HubCallback} from "../src/HubCallback.sol";

/// @notice Register a recipient -> spoke mapping on an already deployed HubCallback.
/// @dev HubCallback is owner-administered: the owner receives the Spoke deployment
/// address, performs validations, and sets it as the target Spoke for a recipient.
/// Recipients are responsible for the events handled by Spokes, while the Hub admin
/// is responsible for ensuring only valid Spokes are registered on the Hub.
contract WhitelistSpokeForRecipient is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address hubCallbackAddr = vm.envAddress("HUB_CALLBACK");
        address recipient = vm.envAddress("RECIPIENT");
        address spokeId = vm.envAddress("RVM_ID");

        console2.log("hubCallbackAddr", hubCallbackAddr);
        console2.log("recipient", recipient);
        console2.log("spokeId", spokeId);

        vm.startBroadcast(deployerKey);
        HubCallback(payable(hubCallbackAddr)).setSpokeForRecipient(recipient, spokeId);
        vm.stopBroadcast();
    }
}

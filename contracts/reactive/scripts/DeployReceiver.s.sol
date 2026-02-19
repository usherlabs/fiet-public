// SPDX-License-Identifier: UNLICENSED
// deploys the batch process settlement receiver on the protocol chain
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BatchProcessSettlement} from "src/dest/BatchProcessSettlement.sol";

/// @notice Deploys the destination receiver (BatchProcessSettlement).
contract DeployReceiver is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address callbackProxy = vm.envAddress("PROTOCOL_CALLBACK_PROXY");
        address liquidityHub = vm.envAddress("LIQUIDITY_HUB");

        uint256 prefund = vm.envOr("RECEIVER_PREFUND_WEI", uint256(0.01 ether));

        vm.startBroadcast(deployerKey);
        console2.log("deploying with liquidity hub:", address(liquidityHub));
        BatchProcessSettlement receiver = new BatchProcessSettlement{value: prefund}(callbackProxy, liquidityHub);
        vm.stopBroadcast();

        // ensure to log the address of the deployed contract
        // using the format contract_name:address
        // that way it can be parsed from the stdout of the script execution
        console2.log("BatchProcessSettlementReceiver:", address(receiver));
    }
}

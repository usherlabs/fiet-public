// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {ScriptHelper} from "./libraries/ScriptHelper.s.sol";

// Transfer ownership of MarketFactory to a new address

contract TransferOwnershipScript is ScriptHelper {
    string public networkName;
    address public marketFactory;
    address public newOwner;

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        networkName = vm.envString("NETWORK");
        console.log("Starting transfer ownership of Market Factory...");
        _setFilename(networkName);
        marketFactory = readAddress("marketFactory");
        console.log("MarketFactory address loaded:", marketFactory);
        newOwner = vm.envAddress("NEW_OWNER");
        require(newOwner != address(0), "NEW_OWNER must be set");
        vm.startBroadcast(deployerPrivateKey);
        MarketFactory factory = MarketFactory(marketFactory);
        factory.transferOwnership(newOwner);
        vm.stopBroadcast();
        console.log("Ownership transfer initiated to:", newOwner);
        console.log("New owner must call acceptOwnership() on MarketFactory");
    }
}

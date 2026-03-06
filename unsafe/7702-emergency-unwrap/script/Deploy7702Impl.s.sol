// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Eoa7702UnlockUnwrap} from "../src/Eoa7702UnlockUnwrap.sol";

contract Deploy7702Impl is Script {
    function _deployerPrivateKey() internal view returns (uint256 pk) {
        if (vm.envExists("DEPLOYER_PRIVATE_KEY")) {
            return uint256(vm.envBytes32("DEPLOYER_PRIVATE_KEY"));
        }
        if (vm.envExists("PRIVATE_KEY")) {
            return uint256(vm.envBytes32("PRIVATE_KEY"));
        }
        revert("Set DEPLOYER_PRIVATE_KEY or PRIVATE_KEY");
    }

    function run() external returns (address impl) {
        uint256 pk = _deployerPrivateKey();
        vm.startBroadcast(pk);
        impl = address(new Eoa7702UnlockUnwrap());
        vm.stopBroadcast();

        console2.log("Eoa7702UnlockUnwrap deployed:", impl);

        string memory path = "deployments/arbitrum_7702_impl.json";
        string memory out = vm.serializeAddress("impl", "implementation", impl);
        vm.writeJson(out, path);
        console2.log("Wrote implementation address to", path);
    }
}

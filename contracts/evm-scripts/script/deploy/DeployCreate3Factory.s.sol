// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {CREATE3Factory} from "../base/CREATE3Script.sol";

/**
 * @title DeployCreate3Factory
 * @notice Deploys a CREATE3Factory and writes its address to:
 *         deployments/create3_factory_${NETWORK}.address
 * @dev This is intended for networks where the canonical CREATE3 factory (0x9fBB...)
 *      is not deployed (ie. Arbitrum Sepolia).
 *      Set CREATE3_FACTORY=<deployed address> when running other scripts.
 *      For most EVM networks, the canonical CREATE3 factory is deployed at 0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf
 */
contract DeployCreate3Factory is Script {
    function run() external returns (CREATE3Factory factory) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        string memory network;
        try vm.envString("NETWORK") returns (string memory n) {
            network = n;
        } catch {
            network = "unknown";
        }

        vm.startBroadcast(deployerPrivateKey);
        factory = new CREATE3Factory();
        vm.stopBroadcast();

        string memory outFile = string.concat("deployments/create3_factory_", network, ".address");
        vm.writeFile(outFile, vm.toString(address(factory)));

        console.log("CREATE3Factory deployed at:", address(factory));
        console.log("Wrote:", outFile);
    }
}


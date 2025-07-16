// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {ScriptHelper} from "./libraries/ScriptHelper.s.sol";

/**
 * @title ReadDeploymentScript
 * @notice Script to read deployment addresses from JSON file
 * @dev Useful for other scripts that need to reference deployed contracts
 */
contract ReadDeploymentScript is ScriptHelper {
    string public networkName;

    function run() external {
        try vm.envString("NETWORK") returns (string memory envNetworkName) {
            networkName = envNetworkName;
        } catch {
            networkName = "sepolia";
        }
        _setFilename(networkName);
        console.log(
            "Reading deployment addresses from deployments/%s_deployments.json...",
            networkName
        );

        // Read addresses from JSON file
        address coreHook = readAddress("coreHook");
        address proxyHook = readAddress("proxyHook");
        address marketFactory = readAddress("marketFactory");

        console.log("\n=== Contract Addresses ===");
        console.log("CoreHook:", coreHook);
        console.log("ProxyHook:", proxyHook);
        console.log("MarketFactory:", marketFactory);

        // Check if addresses are valid
        if (coreHook == address(0)) {
            console.log("  CoreHook address not found in deployment file");
        }
        if (proxyHook == address(0)) {
            console.log("  ProxyHook address not found in deployment file");
        }
        if (marketFactory == address(0)) {
            console.log("  MarketFactory address not found in deployment file");
        }

        if (
            coreHook != address(0) &&
            proxyHook != address(0) &&
            marketFactory != address(0)
        ) {
            console.log("\nAll deployment addresses found!");
        }
    }
}

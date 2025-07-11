// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {ScriptHelper} from "./deployments/ScriptHelper.s.sol";

/**
 * @title ReadDeploymentScript
 * @notice Script to read deployment addresses from JSON file
 * @dev Useful for other scripts that need to reference deployed contracts
 */
contract ReadDeploymentScript is ScriptHelper {
    function run() external {
        _setFilename("sepolia");
        console.log(
            "Reading deployment addresses from script/deployments/sepolia_deployments.json..."
        );

        // Read addresses from JSON file
        address coreHook = readAddress("coreHook");
        address proxyHook = readAddress("proxyHook");
        address marketFactory = readAddress("marketFactory");

        // Read metadata
        string memory deploymentDate = readString("deploymentDate");
        string memory deploymentNetwork = readString("deploymentNetwork");
        string memory poolManager = readString("poolManager");

        console.log("\n=== Deployment Information ===");
        console.log("Network:", deploymentNetwork);
        console.log("Deployment Date:", deploymentDate);
        console.log("Pool Manager:", poolManager);

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

    /**
     * @dev Returns deployment addresses for use in other scripts
     */
    function getDeploymentAddresses()
        external
        view
        returns (address coreHook, address proxyHook, address marketFactory)
    {
        coreHook = readAddress("coreHook");
        proxyHook = readAddress("proxyHook");
        marketFactory = readAddress("marketFactory");
    }

    /**
     * @dev Returns deployment metadata
     */
    function getDeploymentMetadata()
        external
        view
        returns (
            string memory deploymentDate,
            string memory deploymentNetwork,
            string memory poolManager
        )
    {
        deploymentDate = readString("deploymentDate");
        deploymentNetwork = readString("deploymentNetwork");
        poolManager = readString("poolManager");
    }
}

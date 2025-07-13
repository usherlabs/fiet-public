// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {CoreHook} from "../src/CoreHook.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {ScriptHelper} from "./libraries/ScriptHelper.s.sol";

// Removed SepoliaConstants import

/**
 * @title CompleteDeployScript
 * @notice Comprehensive deployment script for CoreHook, ProxyHook, and MarketFactory
 * @dev Deploys contracts in the correct order with proper HookMiner logic
 *
 * Deployment Order:
 * 1. Deploy MarketFactory (without hooks)
 * 2. Deploy CoreHook (with proper flags and MarketFactory address)
 * 3. Deploy ProxyHook (with proper flags and MarketFactory address)
 * 4. Set hooks in MarketFactory using setHooks()
 * 5. Activate hooks (set cross-references)
 */
contract CompleteDeployScript is ScriptHelper {
    // Deployed contract addresses
    address public coreHook;
    address public proxyHook;
    address public marketFactory;

    // Network-specific constants set from environment
    address public poolManagerAddress;
    address public create2Deployer;
    string public networkName;

    // Hook flags for proper address mining
    uint160 constant CORE_HOOK_FLAGS =
        uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

    uint160 constant PROXY_HOOK_FLAGS =
        uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        networkName = vm.envString("NETWORK");
        poolManagerAddress = vm.envAddress("POOL_MANAGER");
        create2Deployer = vm.envAddress("DEPLOYER_CREATE2");

        console.log(
            "Starting deployment of CoreHook, ProxyHook, and MarketFactory on %s...",
            networkName
        );
        console.log("Pool Manager:", poolManagerAddress);
        console.log("CREATE2 Deployer:", create2Deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy MarketFactory
        console.log("\n=== Deploying MarketFactory ===");
        marketFactory = _deployMarketFactory();
        console.log("MarketFactory deployed at:", marketFactory);

        // Step 2: Deploy CoreHook
        console.log("\n=== Deploying CoreHook ===");
        coreHook = _deployCoreHook();
        console.log("CoreHook deployed at:", coreHook);

        // Step 3: Deploy ProxyHook
        console.log("\n=== Deploying ProxyHook ===");
        proxyHook = _deployProxyHook();
        console.log("ProxyHook deployed at:", proxyHook);

        // Step 4: Set hooks in MarketFactory
        console.log("\n=== Setting Hooks in MarketFactory ===");
        _setHooksInFactory();

        // Step 5: Activate hooks (set cross-references)
        console.log("\n=== Activating Hooks ===");
        _activateHooks();

        vm.stopBroadcast();

        // Write deployment addresses to files
        _writeDeploymentAddresses();

        console.log("\n=== Deployment Complete ===");
        console.log("CoreHook:", coreHook);
        console.log("ProxyHook:", proxyHook);
        console.log("MarketFactory:", marketFactory);
    }

    /**
     * @dev Deploys CoreHook using HookMiner to find correct address
     * @return The deployed CoreHook address
     */
    function _deployCoreHook() internal returns (address) {
        // CoreHook constructor takes (poolManager, marketFactory)
        // Now we pass the actual marketFactory address
        bytes memory constructorArgs = abi.encode(
            poolManagerAddress,
            marketFactory
        );

        // Mine the correct address with proper flags
        (address hookAddress, bytes32 salt) = HookMiner.find(
            create2Deployer,
            CORE_HOOK_FLAGS,
            type(CoreHook).creationCode,
            constructorArgs
        );

        console.log("CoreHook will be deployed to:", hookAddress);
        console.log("CoreHook salt:", vm.toString(salt));

        // Deploy the hook
        CoreHook deployedHook = new CoreHook{salt: salt}(
            poolManagerAddress,
            marketFactory
        );
        require(
            address(deployedHook) == hookAddress,
            "CoreHook: address mismatch"
        );

        return address(deployedHook);
    }

    /**
     * @dev Deploys ProxyHook using HookMiner to find correct address
     * @return The deployed ProxyHook address
     */
    function _deployProxyHook() internal returns (address) {
        // ProxyHook constructor takes (poolManager, marketFactory)
        // Now we pass the actual marketFactory address
        bytes memory constructorArgs = abi.encode(
            poolManagerAddress,
            marketFactory
        );

        // Mine the correct address with proper flags
        (address hookAddress, bytes32 salt) = HookMiner.find(
            create2Deployer,
            PROXY_HOOK_FLAGS,
            type(ProxyHook).creationCode,
            constructorArgs
        );

        console.log("ProxyHook will be deployed to:", hookAddress);
        console.log("ProxyHook salt:", vm.toString(salt));

        // Deploy the hook
        ProxyHook deployedHook = new ProxyHook{salt: salt}(
            poolManagerAddress,
            marketFactory
        );
        require(
            address(deployedHook) == hookAddress,
            "ProxyHook: address mismatch"
        );

        return address(deployedHook);
    }

    /**
     * @dev Deploys MarketFactory without hooks (hooks will be set later)
     * @return The deployed MarketFactory address
     */
    function _deployMarketFactory() internal returns (address) {
        // Initial bounds array (empty for now, can be updated later)
        address[] memory initialBounds = new address[](0);

        // MarketFactory constructor now only takes (poolManager, bounds)
        MarketFactory factory = new MarketFactory(
            poolManagerAddress,
            initialBounds
        );

        return address(factory);
    }

    /**
     * @dev Sets hooks in MarketFactory using the setHooks() function
     * This is called after MarketFactory deployment to establish the relationship
     */
    function _setHooksInFactory() internal {
        MarketFactory factoryInstance = MarketFactory(marketFactory);

        // Call setHooks to configure the hooks in MarketFactory
        factoryInstance.setHooks(coreHook, proxyHook);

        console.log("Hooks set in MarketFactory successfully");
    }

    /**
     * @dev Activates hooks by setting cross-references
     * This is called after hooks are set in MarketFactory to verify the relationship
     */
    function _activateHooks() internal view {
        // Verify the cross-references are set correctly after setHooks() call

        CoreHook coreHookInstance = CoreHook(coreHook);
        ProxyHook proxyHookInstance = ProxyHook(proxyHook);
        MarketFactory factoryInstance = MarketFactory(marketFactory);

        // Verify the hooks are properly configured
        require(
            coreHookInstance.marketFactory() == marketFactory,
            "CoreHook: marketFactory not set"
        );
        require(
            proxyHookInstance.marketFactory() == marketFactory,
            "ProxyHook: marketFactory not set"
        );
        require(
            factoryInstance.getCoreHook() == coreHook,
            "MarketFactory: coreHook not set"
        );
        require(
            factoryInstance.getProxyHook() == proxyHook,
            "MarketFactory: proxyHook not set"
        );

        console.log("Hooks activated successfully");
    }

    /**
     * @dev Writes deployment addresses to JSON file for future reference
     */
    function _writeDeploymentAddresses() internal {
        // Write addresses to JSON file using ScriptHelper
        _setFilename(networkName);
        writeAddress("coreHook", coreHook);
        writeAddress("proxyHook", proxyHook);
        writeAddress("marketFactory", marketFactory);

        console.log(
            "Deployment addresses written to script/deployments/%s_deployments.json",
            networkName
        );
    }

    /**
     * @dev Verifies hook permissions are correct
     * @param hookAddress The hook address to verify
     * @param expectedFlags The expected flags for the hook
     */
    function _verifyHookFlags(
        address hookAddress,
        uint160 expectedFlags
    ) internal pure {
        uint160 hookFlags = uint160(hookAddress) & Hooks.ALL_HOOK_MASK;
        require(hookFlags == expectedFlags, "Hook flags mismatch");
    }

    /**
     * @dev Verifies the complete deployment
     * Can be called after deployment to ensure everything is set up correctly
     */
    function verifyDeployment() external view {
        console.log("\n=== Verifying Deployment on %s ===", networkName);

        // Verify hook flags
        _verifyHookFlags(coreHook, CORE_HOOK_FLAGS);
        _verifyHookFlags(proxyHook, PROXY_HOOK_FLAGS);

        console.log("Hook flags verified");

        // Verify MarketFactory configuration
        MarketFactory factory = MarketFactory(marketFactory);
        require(
            factory.poolManager() == poolManagerAddress,
            "MarketFactory: wrong poolManager"
        );
        require(
            factory.getCoreHook() == coreHook,
            "MarketFactory: wrong coreHook"
        );
        require(
            factory.getProxyHook() == proxyHook,
            "MarketFactory: wrong proxyHook"
        );

        console.log("MarketFactory configuration verified");

        // Verify hook cross-references
        CoreHook coreHookInstance = CoreHook(coreHook);
        ProxyHook proxyHookInstance = ProxyHook(proxyHook);

        require(
            coreHookInstance.marketFactory() == marketFactory,
            "CoreHook: wrong marketFactory"
        );
        require(
            proxyHookInstance.marketFactory() == marketFactory,
            "ProxyHook: wrong marketFactory"
        );

        console.log("Hook cross-references verified");
        console.log("All verifications passed!");
    }

    /**
     * @dev Reads deployment addresses from JSON file
     * Useful for other scripts that need to reference deployed contracts
     */
    function readDeploymentAddresses()
        external
        view
        returns (
            address coreHookAddr,
            address proxyHookAddr,
            address marketFactoryAddr
        )
    {
        coreHookAddr = readAddress("coreHook");
        proxyHookAddr = readAddress("proxyHook");
        marketFactoryAddr = readAddress("marketFactory");

        console.log("Deployment addresses from JSON:");
        console.log("CoreHook:", coreHookAddr);
        console.log("ProxyHook:", proxyHookAddr);
        console.log("MarketFactory:", marketFactoryAddr);
    }
}

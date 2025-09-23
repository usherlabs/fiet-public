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

import {SepoliaConstants} from "./constants/ArbitrumSepolia.sol";
import {ArbitrumConstants} from "./constants/Arbitrum.sol";
import {HookFlags} from "./constants/HookFlags.sol";
import {EthSepoliaConstants} from "./constants/EthSepolia.sol";
import {MMPositionManager} from "../src/MMPositionManager.sol";
import {StubSpokeVerifier} from "../src/modules/StubSpokeVerifier.sol";
import {OracleRegistry} from "../src/OracleRegistry.sol";
import {ChainlinkFactory} from "../src/oracles/chainlink/ChainlinkFactory.sol";
import {VRLSpokeReceiver} from "../src/modules/VRLSpokeReceiver.sol";

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
    address public mmPositionManager;
    address public oracleRegistry;
    // Network-specific constants set from environment
    address public poolManagerAddress;
    address public create2Deployer;
    string public networkName;

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        networkName = vm.envString("NETWORK"); // "sepolia" | "arbitrum"
        if (keccak256(bytes(networkName)) == keccak256(bytes("sepolia"))) {
            poolManagerAddress = SepoliaConstants.POOL_MANAGER;
            create2Deployer = SepoliaConstants.DEPLOYER_CREATE2;
        } else if (keccak256(bytes(networkName)) == keccak256(bytes("arbitrum"))) {
            poolManagerAddress = ArbitrumConstants.POOL_MANAGER;
            create2Deployer = ArbitrumConstants.DEPLOYER_CREATE2;
        } else if (keccak256(bytes(networkName)) == keccak256(bytes("ethsepolia"))) {
            poolManagerAddress = EthSepoliaConstants.POOL_MANAGER;
            create2Deployer = EthSepoliaConstants.DEPLOYER_CREATE2;
        }

        console.log("Starting deployment of CoreHook, ProxyHook, and MarketFactory on %s...", networkName);
        console.log("Pool Manager:", poolManagerAddress);
        console.log("CREATE2 Deployer:", create2Deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy OracleRegistry and chainlink oracle factory
        console.log("\n=== Deploying OracleRegistry and Chainlink Oracle Factory ===");
        oracleRegistry = _deployOracleRegistry();
        console.log("OracleRegistry deployed at:", oracleRegistry);

        // Step 2: Deploy MarketFactory
        console.log("\n=== Deploying MarketFactory ===");
        marketFactory = _deployMarketFactory();
        console.log("MarketFactory deployed at:", marketFactory);

        // Step 3: Deploy MMPositionManager
        console.log("\n=== Deploying MMPositionManager ===");
        mmPositionManager = _deployMMPositionManager();
        console.log("MMPositionManager deployed at:", mmPositionManager);

        // Step 4: Deploy CoreHook
        console.log("\n=== Deploying CoreHook ===");
        coreHook = _deployCoreHook();
        console.log("CoreHook deployed at:", coreHook);

        // Step 5: Set hooks in MarketFactory
        console.log("\n=== Setting Hooks in MarketFactory ===");
        _setHooksInFactory();

        // Step 6: Verify hooks addresses across the contracts
        console.log("\n=== Verifying Hooks ===");
        _verifyHooks();

        // Step 7: Add all the protocol addresses expected to hold LCC as a protocol bound address in the market factory
        console.log("\n=== Adding addresses to bounds array ===");
        _addAddressesToBounds();

        vm.stopBroadcast();

        // Write deployment addresses to files
        _writeDeploymentAddresses();

        console.log("\n=== Deployment Complete ===");
        console.log("CoreHook:", coreHook);
        console.log("MarketFactory:", marketFactory);
        console.log("MMPositionManager:", mmPositionManager);
    }

    /**
     * @dev Deploys CoreHook using HookMiner to find correct address
     * @return The deployed CoreHook address
     */
    function _deployCoreHook() internal returns (address) {
        // CoreHook constructor takes (poolManager, marketFactory)
        // Now we pass the actual marketFactory address
        address calculator = address(0);
        bytes memory constructorArgs =
            abi.encode(poolManagerAddress, marketFactory, address(mmPositionManager), calculator);

        // Mine the correct address with proper flags
        (address hookAddress, bytes32 salt) =
            HookMiner.find(create2Deployer, HookFlags.CORE_HOOK_FLAGS, type(CoreHook).creationCode, constructorArgs);

        console.log("CoreHook will be deployed to:", hookAddress);
        console.log("CoreHook salt:", vm.toString(salt));

        // Deploy the hook
        CoreHook deployedHook =
            new CoreHook{salt: salt}(poolManagerAddress, marketFactory, address(mmPositionManager), calculator);
        require(address(deployedHook) == hookAddress, "CoreHook: address mismatch");

        return address(deployedHook);
    }

    /**
     * @dev Deploys MarketFactory without hooks (hooks will be set later)
     * @return The deployed MarketFactory address
     */
    function _deployMarketFactory() internal returns (address) {
        // Initial bounds array (empty for now, can be updated later)
        address[] memory initialBounds = new address[](0);

        MarketFactory factory = new MarketFactory(poolManagerAddress, oracleRegistry, initialBounds);

        return address(factory);
    }

    function _deployOracleRegistry() internal returns (address) {
        uint256 decimals = 18;
        OracleRegistry registry = new OracleRegistry();
        console.log("OracleRegistry deployed at:", address(registry));
        // deploy and set the chainlink oracle factory
        ChainlinkFactory factory = new ChainlinkFactory(address(registry), decimals);
        console.log("Chainlink Oracle Factory deployed at:", address(factory));
        registry.setDefaultFactory(address(factory));
        console.log("Chainlink Oracle Factory set in OracleRegistry");
        return address(registry);
    }

    /**
     * @dev Deploys MMPositionManager with a stub verifier
     * @return The deployed MMPositionManager address
     */
    function _deployMMPositionManager() internal returns (address) {
        // ? deploy a stub verifier for now
        address stubVerifier = address(new StubSpokeVerifier());
        console.log("StubSpokeVerifier deployed at:", stubVerifier);
        address spokeReceiver = address(new VRLSpokeReceiver(stubVerifier, oracleRegistry));
        console.log("SpokeReceiver deployed at:", spokeReceiver);
        MMPositionManager positionManager = new MMPositionManager(poolManagerAddress, spokeReceiver, marketFactory);
        console.log("MMPositionManager deployed at:", address(positionManager));
        return address(positionManager);
    }

    /**
     * @dev Sets hooks in MarketFactory using the setHooks() function
     * This is called after MarketFactory deployment to establish the relationship
     */
    function _setHooksInFactory() internal {
        MarketFactory factoryInstance = MarketFactory(marketFactory);

        // Call setHooks to configure the hooks in MarketFactory
        factoryInstance.setHooks(coreHook);

        console.log("Hooks set in MarketFactory successfully");
    }

    /**
     * @dev Verifies hooks by checking cross-references
     * This is called after hooks are set in MarketFactory to verify the relationship
     */
    function _verifyHooks() internal view {
        // Verify the cross-references are set correctly after setHooks() call

        CoreHook coreHookInstance = CoreHook(coreHook);
        MarketFactory factoryInstance = MarketFactory(marketFactory);

        // Verify the hooks are properly configured
        require(coreHookInstance.marketFactory() == marketFactory, "CoreHook: marketFactory not set");
        require(factoryInstance.getCoreHook() == coreHook, "MarketFactory: coreHook not set");

        console.log("Hooks activated successfully");
    }

    /**
     * @dev adds all relevant addess to bounds array in the market factory
     * Whitelist protocol
     */
    function _addAddressesToBounds() internal {
        // ? we can add more bounds here if needed
        MarketFactory factoryInstance = MarketFactory(marketFactory);
        address[] memory bounds = new address[](1);
        bounds[0] = mmPositionManager;
        // bounds[1] = mmPositionManager;
        // bounds[2] = coreHook;
        // bounds[3] = proxyHook;

        factoryInstance.addBounds(bounds);
    }

    /**
     * @dev Writes deployment addresses to JSON file for future reference
     */
    function _writeDeploymentAddresses() internal {
        // Write addresses to JSON file using ScriptHelper
        _setFilename(networkName);
        writeAddress("coreHook", coreHook);
        writeAddress("marketFactory", marketFactory);
        writeAddress("positionManager", mmPositionManager);
        writeAddress("oracleRegistry", oracleRegistry);

        console.log("Deployment addresses written to deployments/%s_deployments.json", networkName);
    }

    /**
     * @dev Verifies hook permissions are correct
     * @param hookAddress The hook address to verify
     * @param expectedFlags The expected flags for the hook
     */
    function _verifyHookFlags(address hookAddress, uint160 expectedFlags) internal pure {
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
        _verifyHookFlags(coreHook, HookFlags.CORE_HOOK_FLAGS);

        console.log("Hook flags verified");

        // Verify MarketFactory configuration
        MarketFactory factory = MarketFactory(marketFactory);
        require(factory.poolManager() == poolManagerAddress, "MarketFactory: wrong poolManager");
        require(factory.getCoreHook() == coreHook, "MarketFactory: wrong coreHook");

        console.log("MarketFactory configuration verified");

        // Verify hook cross-references
        CoreHook coreHookInstance = CoreHook(coreHook);

        require(coreHookInstance.marketFactory() == marketFactory, "CoreHook: wrong marketFactory");

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
        returns (address coreHookAddr, address proxyHookAddr, address marketFactoryAddr)
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

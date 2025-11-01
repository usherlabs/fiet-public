// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IOwnable} from "@chainlink/contracts/shared/interfaces/IOwnable.sol";

import {CoreHook} from "../src/CoreHook.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {ScriptHelper} from "./libraries/ScriptHelper.s.sol";

import {SepoliaConstants} from "./constants/ArbitrumSepolia.sol";
import {ArbitrumConstants} from "./constants/Arbitrum.sol";
import {HookFlags} from "../src/libraries/HookFlags.sol";
import {EthSepoliaConstants} from "./constants/EthSepolia.sol";
import {MMPositionManager} from "../src/MMPositionManager.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {StubSpokeVerifier} from "../src/modules/StubSpokeVerifier.sol";
import {VRLSignalManager} from "../src/modules/VRLSignalManager.sol";
import {VRLSettlementObserver} from "../src/VRLSettlementObserver.sol";
import {StubSettlementVerifier} from "../src/verifiers/StubSettlementVerifier.sol";
import {OracleHelper} from "../src/modules/OracleHelper.sol";
import {GlobalConfig} from "../src/GlobalConfig.sol";

/**
 * @title CompleteDeployScript
 * @notice Comprehensive deployment script for CoreHook, ProxyHook, and MarketFactory
 * @dev Deploys contracts in the correct order with proper HookMiner logic
 *
 * Deployment Order:
 * 1. Deploy OracleRegistry and ChainlinkFactory
 * 2. Deploy MarketFactory (without hooks)
 * 3. Deploy MMPositionManager (must be deployed before CoreHook)
 * 4. Deploy CoreHook (with proper flags and MarketFactory address)
 * 5. Set hooks in MarketFactory using setHooks()
 * 6. Verify hooks (set cross-references)
 * 7. Add protocol addresses to bounds array
 */
contract CompleteDeployScript is ScriptHelper {
    // Deployed contract addresses
    address public coreHook;
    address public proxyHook;
    address public marketFactory;
    address public mmPositionManager;
    address public oracleHelper;
    address public signalManager;
    address public settlementObserver;
    address public globalConfig;
    // Network-specific constants set from environment
    address public poolManagerAddress;
    address public create2Deployer;
    address public positionManagerAddress;
    string public networkName;

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        networkName = vm.envString("NETWORK"); // "sepolia" | "arbitrum"
        if (keccak256(bytes(networkName)) == keccak256(bytes("sepolia"))) {
            poolManagerAddress = SepoliaConstants.POOL_MANAGER;
            create2Deployer = SepoliaConstants.DEPLOYER_CREATE2;
            positionManagerAddress = SepoliaConstants.POSITION_MANAGER;
        } else if (keccak256(bytes(networkName)) == keccak256(bytes("arbitrum"))) {
            poolManagerAddress = ArbitrumConstants.POOL_MANAGER;
            create2Deployer = ArbitrumConstants.DEPLOYER_CREATE2;
            positionManagerAddress = ArbitrumConstants.POSITION_MANAGER;
        } else if (keccak256(bytes(networkName)) == keccak256(bytes("ethsepolia"))) {
            poolManagerAddress = EthSepoliaConstants.POOL_MANAGER;
            create2Deployer = EthSepoliaConstants.DEPLOYER_CREATE2;
            positionManagerAddress = EthSepoliaConstants.POSITION_MANAGER;
        }

        console.log("Starting deployment of CoreHook, ProxyHook, and MarketFactory on %s...", networkName);
        console.log("Pool Manager:", poolManagerAddress);
        console.log("CREATE2 Deployer:", create2Deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy OracleHelper
        // @dev the ResilientOracle would have been deployed and provided as an env var `RESILIENT_ORACLE_ADDRESS`
        console.log("\n=== Deploying OracleHelper ===");
        oracleHelper = _deployOracleHelper();
        console.log("OracleHelper deployed at:", oracleHelper);

        // Step 2: Deploy MarketFactory
        console.log("\n=== Deploying MarketFactory ===");
        marketFactory = _deployMarketFactory();
        console.log("MarketFactory deployed at:", marketFactory);

        // Step 3: Deploy Verifiers
        console.log("\n=== Deploying Verifiers ===");
        _deployVerifiers();
        console.log("SignalManager deployed at:", signalManager);
        console.log("SettlementObserver deployed at:", settlementObserver);

        // Step 4: Deploy MMPositionManager (must be before CoreHook)
        console.log("\n=== Deploying MMPositionManager ===");
        mmPositionManager = _deployMMPositionManager();
        console.log("MMPositionManager deployed at:", mmPositionManager);

        // Step 5: Deploy CoreHook
        console.log("\n=== Deploying CoreHook ===");
        coreHook = _deployCoreHook();
        console.log("CoreHook deployed at:", coreHook);

        // Step 6: Set hooks in MarketFactory
        console.log("\n=== Setting Hooks in MarketFactory ===");
        _setHooksInFactory();

        // Step 7: Verify hooks addresses across the contracts
        console.log("\n=== Verifying Hooks ===");
        _verifyHooks();

        // Step 8: Add all the protocol addresses expected to hold LCC as a protocol bound address in the market factory
        console.log("\n=== Adding addresses to bounds array ===");
        _addAddressesToBounds();

        // Step 9: Deploy GlobalConfig and assign ownership to the market factory
        console.log("\n=== Deploying GlobalConfig ===");
        globalConfig = _setupGlobalConfig();
        console.log("GlobalConfig deployed at:", globalConfig);

        vm.stopBroadcast();

        // Write deployment addresses to files
        _writeDeploymentAddresses();

        console.log("\n=== Deployment Complete ===");
        console.log("CoreHook:", coreHook);
        console.log("MarketFactory:", marketFactory);
        console.log("MMPositionManager:", mmPositionManager);
    }

    function _setupGlobalConfig() internal returns (address) {
        // deploy the global config
        GlobalConfig config = new GlobalConfig();
        console.log("GlobalConfig deployed at:", address(config));

        // Populate the owned contracts array with the contracts that need to be owned by the global config
        address[] memory ownedContracts = new address[](1);
        ownedContracts[0] = marketFactory;

        // Transfer ownership of the contracts to the global config
        uint256 len = ownedContracts.length;
        for (uint256 i = 0; i < len; i++) {
            IOwnable(ownedContracts[i]).transferOwnership(address(config));
        }
        return address(config);
    }

    function _deployOracleHelper() internal returns (address) {
        // read in the predeployed address of the resilient oracle from the env
        address resilientOracleAddress = vm.envAddress("RESILIENT_ORACLE_ADDRESS");
        console.log("Oracle loaded at address:", resilientOracleAddress);
        OracleHelper helper = new OracleHelper(resilientOracleAddress);
        console.log("OracleHelper deployed at:", address(helper));

        return address(helper);
    }

    /**
     * @dev Deploys CoreHook using HookMiner to find correct address
     * @return The deployed CoreHook address
     */
    function _deployCoreHook() internal returns (address) {
        bytes memory constructorArgs =
            abi.encode(poolManagerAddress, marketFactory, address(mmPositionManager), oracleHelper);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(create2Deployer, HookFlags.CORE_HOOK_FLAGS, type(CoreHook).creationCode, constructorArgs);

        console.log("CoreHook will be deployed to:", hookAddress);
        console.log("CoreHook salt:", vm.toString(salt));

        CoreHook deployedHook =
            new CoreHook{salt: salt}(poolManagerAddress, marketFactory, address(mmPositionManager), oracleHelper);
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

        MarketFactory factory = new MarketFactory(poolManagerAddress, oracleHelper, initialBounds);

        return address(factory);
    }

    /**
     * @dev Deploys Verifiers
     */
    function _deployVerifiers() internal {
        uint256 signalExpiryInSeconds = 3600;

        // deploy the proof verifiers
        address publicKeyAddress = vm.envAddress("PUBLIC_KEY_SIGNAL_VERIFIER_ADDRESS");
        address signalVerifier = address(new ECDSASignatureSignalVerifier(publicKeyAddress));

        signalManager = address(new VRLSignalManager(marketFactory, signalVerifier, signalExpiryInSeconds));
        console.log("SignalManager deployed at:", signalManager);

        // ? deploy settlement observer without verifiers. No verifiers developed yet.
        settlementObserver = address(new VRLSettlementObserver());
    }

    /**
     * @dev Deploys MMPositionManager with a stub verifier
     * @return The deployed MMPositionManager address
     */
    function _deployMMPositionManager() internal returns (address) {
        // Query WETH9 from the deployed PositionManager contract
        address wethAddress = PositionManager(positionManagerAddress).WETH9();
        console.log("WETH9 queried from PositionManager:", wethAddress);

        IWETH9 weth9 = IWETH9(wethAddress);
        MMPositionManager positionManager =
            new MMPositionManager(poolManagerAddress, signalManager, marketFactory, settlementObserver, weth9);
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
        writeAddress("oracleHelper", oracleHelper);
        writeAddress("globalConfig", globalConfig);

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
        returns (address coreHookAddr, address proxyHookAddr, address marketFactoryAddr, address globalConfigAddr)
    {
        coreHookAddr = readAddress("coreHook");
        proxyHookAddr = readAddress("proxyHook");
        marketFactoryAddr = readAddress("marketFactory");
        globalConfigAddr = readAddress("globalConfig");

        console.log("Deployment addresses from JSON:");
        console.log("CoreHook:", coreHookAddr);
        console.log("ProxyHook:", proxyHookAddr);
        console.log("MarketFactory:", marketFactoryAddr);
        console.log("GlobalConfig:", globalConfigAddr);
    }
}

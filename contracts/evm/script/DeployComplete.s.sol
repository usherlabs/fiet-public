// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {CoreHook} from "../src/CoreHook.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {ScriptHelper} from "./libraries/ScriptHelper.s.sol";

import {SepoliaConstants} from "./constants/ArbitrumSepolia.sol";
import {ArbitrumConstants} from "./constants/Arbitrum.sol";
import {HookFlags} from "../src/libraries/HookFlags.sol";
import {EthSepoliaConstants} from "./constants/EthSepolia.sol";
import {MMPositionManager} from "../src/MMPositionManager.sol";
import {MMPositionActionsImpl} from "../src/MMPositionActionsImpl.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {VRLSignalManager} from "../src/VRLSignalManager.sol";
import {VRLSettlementObserver} from "../src/VRLSettlementObserver.sol";
import {VTSOrchestrator} from "../src/VTSOrchestrator.sol";
import {OracleHelper} from "../src/OracleHelper.sol";
import {MMPCommitmentDescriptor} from "../src/MMPCommitmentDescriptor.sol";
import {LiquidityHub} from "../src/LiquidityHub.sol";
import {GlobalConfig} from "../src/GlobalConfig.sol";
import {ECDSASignatureSignalVerifier} from "../src/verifiers/ECDSASignatureSignalVerifier.sol";

/**
 * @title CompleteDeployScript
 * @notice Comprehensive deployment script for CoreHook, ProxyHook, and MarketFactory
 * @dev Deploys contracts in the correct order with proper HookMiner logic
 *
 * Deployment Order:
 * 1. Deploy OracleHelper
 * 2. Deploy LiquidityHub (must be before VTSO and MarketFactory)
 * 3. Deploy Verifiers (VTSO dependencies)
 * 4. Deploy VTSOrchestrator (must be before MMPositionManager and MarketFactory)
 * 5. Deploy MMPositionManager (must be before MarketFactory for bounds)
 * 6. Deploy MarketFactory (with LiquidityHub and VTSO, without hooks initially)
 * 7. Enable MarketFactory in LiquidityHub
 * 8. Deploy CoreHook (with proper flags and MarketFactory address)
 * 9. Set hooks in MarketFactory using setHooks()
 * 10. Verify hooks (set cross-references)
 * 11. Add protocol addresses to bounds array (including MMPositionManager)
 * 12. Deploy GlobalConfig and transfer ownership
 */
contract CompleteDeployScript is ScriptHelper {
    // Deployed contract addresses
    address public coreHook;
    address public proxyHook;
    address public marketFactory;
    address public mmPositionManager;
    address public oracleHelper;
    address payable public liquidityHub;
    address public signalManager;
    address public settlementObserver;
    address public globalConfig;
    address public commitmentDescriptor;
    // Network-specific constants set from environment
    address public poolManagerAddress;
    address public create2Deployer;
    address payable public positionManagerAddress;
    address public vtsOrchestrator;
    string public networkName;
    // Track Ownable contracts for ownership migration to GlobalConfig
    address[] public ownedContracts;

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        networkName = vm.envString("NETWORK"); // "sepolia" | "arbitrum"
        if (keccak256(bytes(networkName)) == keccak256(bytes("sepolia"))) {
            poolManagerAddress = SepoliaConstants.POOL_MANAGER;
            create2Deployer = SepoliaConstants.DEPLOYER_CREATE2;
            positionManagerAddress = payable(SepoliaConstants.POSITION_MANAGER);
        } else if (keccak256(bytes(networkName)) == keccak256(bytes("arbitrum"))) {
            poolManagerAddress = ArbitrumConstants.POOL_MANAGER;
            create2Deployer = ArbitrumConstants.DEPLOYER_CREATE2;
            positionManagerAddress = payable(ArbitrumConstants.POSITION_MANAGER);
        } else if (keccak256(bytes(networkName)) == keccak256(bytes("ethsepolia"))) {
            poolManagerAddress = EthSepoliaConstants.POOL_MANAGER;
            create2Deployer = EthSepoliaConstants.DEPLOYER_CREATE2;
            positionManagerAddress = payable(EthSepoliaConstants.POSITION_MANAGER);
        }

        console.log("Starting deployment of CoreHook, ProxyHook, and MarketFactory on %s...", networkName);
        console.log("Pool Manager:", poolManagerAddress);
        console.log("CREATE2 Deployer:", create2Deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy OracleHelper
        // @dev the ResilientOracle would have been deployed and provided as an env var `RESILIENT_ORACLE_ADDRESS`
        console.log("\n=== Step 1: Deploying OracleHelper ===");
        oracleHelper = _deployOracleHelper();
        console.log("OracleHelper deployed at:", oracleHelper);
        ownedContracts.push(oracleHelper);

        // Step 2: Deploy LiquidityHub (must be before VTSO and MarketFactory)
        console.log("\n=== Step 2: Deploying LiquidityHub ===");
        liquidityHub = _deployLiquidityHub();
        console.log("LiquidityHub deployed at:", liquidityHub);
        ownedContracts.push(liquidityHub);

        // Step 3: Deploy Verifiers (VTSO dependencies)
        console.log("\n=== Step 3: Deploying Verifiers (VTSO Dependencies) ===");
        _deployVerifiers();
        console.log("SignalManager deployed at:", signalManager);
        console.log("SettlementObserver deployed at:", settlementObserver);

        // Step 4: Deploy VTSOrchestrator (must be before MMPositionManager and MarketFactory)
        console.log("\n=== Step 4: Deploying VTSOrchestrator ===");
        vtsOrchestrator = _deployVTSOrchestrator();
        console.log("VTSOrchestrator deployed at:", vtsOrchestrator);
        ownedContracts.push(vtsOrchestrator);

        // Step 5: Deploy MMPositionManager (must be before MarketFactory for bounds)
        console.log("\n=== Step 5: Deploying MMPositionManager ===");
        mmPositionManager = _deployMMPositionManager();
        console.log("MMPositionManager deployed at:", mmPositionManager);

        // Step 6: Deploy MarketFactory (with LiquidityHub and VTSOrchestrator, without hooks initially)
        console.log("\n=== Step 6: Deploying MarketFactory ===");
        marketFactory = _deployMarketFactory();
        console.log("MarketFactory deployed at:", marketFactory);
        ownedContracts.push(marketFactory);

        // Step 7: Enable MarketFactory in LiquidityHub
        console.log("\n=== Step 7: Enabling MarketFactory in LiquidityHub ===");
        _enableFactoryInLiquidityHub();

        // Step 8: Deploy CoreHook
        console.log("\n=== Step 8: Deploying CoreHook ===");
        coreHook = _deployCoreHook();
        console.log("CoreHook deployed at:", coreHook);

        // Step 9: Set hooks in MarketFactory
        console.log("\n=== Step 9: Setting Hooks in MarketFactory ===");
        _setHooksInFactory();

        // Step 10: Verify hooks addresses across the contracts
        console.log("\n=== Step 10: Verifying Hooks ===");
        _verifyHooks();

        // Step 11: Add all the protocol addresses expected to hold LCC as a protocol bound address in the market factory
        // Note: LiquidityHub is already added to bounds in MarketFactory constructor
        // MMPositionManager is added here since it's no longer passed to constructor
        console.log("\n=== Step 11: Adding addresses to bounds array ===");
        _addAddressesToBounds();

        // Step 12: Deploy GlobalConfig and assign ownership to the market factory
        console.log("\n=== Step 12: Deploying GlobalConfig ===");
        globalConfig = _setupGlobalConfig();
        console.log("GlobalConfig deployed at:", globalConfig);

        vm.stopBroadcast();

        // Write deployment addresses to files
        _writeDeploymentAddresses();

        console.log("\n=== Deployment Complete ===");
        console.log("CoreHook:", coreHook);
        console.log("MarketFactory:", marketFactory);
        console.log("LiquidityHub:", liquidityHub);
        console.log("VTSOrchestrator:", vtsOrchestrator);
        console.log("MMPositionManager:", mmPositionManager);
    }

    function _setupGlobalConfig() internal returns (address) {
        // deploy the global config
        GlobalConfig config = new GlobalConfig();
        console.log("GlobalConfig deployed at:", address(config));

        // Transfer ownership of all Ownable contracts to the global config
        uint256 len = ownedContracts.length;
        console.log("Transferring ownership of", len, "contracts to GlobalConfig");
        for (uint256 i = 0; i < len; i++) {
            Ownable(ownedContracts[i]).transferOwnership(address(config));
            console.log("  - Transferred ownership of", ownedContracts[i]);
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
     * @dev Deploys LiquidityHub with native asset configuration
     * @return The deployed LiquidityHub address
     */
    function _deployLiquidityHub() internal returns (address payable) {
        // Native asset configuration - these can be overridden via env vars if needed
        string memory nativeAssetName = vm.envOr("NATIVE_ASSET_NAME", string("Ethereum"));
        string memory nativeAssetSymbol = vm.envOr("NATIVE_ASSET_SYMBOL", string("ETH"));
        uint8 nativeAssetDecimals = uint8(vm.envOr("NATIVE_ASSET_DECIMALS", uint256(18)));

        LiquidityHub hub = new LiquidityHub(oracleHelper, nativeAssetName, nativeAssetSymbol, nativeAssetDecimals);

        return payable(address(hub));
    }

    /**
     * @dev Enables MarketFactory in LiquidityHub so it can create LCC pairs
     */
    function _enableFactoryInLiquidityHub() internal {
        LiquidityHub hub = LiquidityHub(payable(liquidityHub));
        hub.setFactory(marketFactory, true);
        console.log("MarketFactory enabled in LiquidityHub");
    }

    /**
     * @dev Deploys CoreHook using HookMiner to find correct address
     * @return The deployed CoreHook address
     */
    function _deployCoreHook() internal returns (address) {
        bytes memory constructorArgs = abi.encode(poolManagerAddress, marketFactory, address(vtsOrchestrator));

        (address hookAddress, bytes32 salt) =
            HookMiner.find(create2Deployer, HookFlags.CORE_HOOK_FLAGS, type(CoreHook).creationCode, constructorArgs);

        console.log("CoreHook will be deployed to:", hookAddress);
        console.log("CoreHook salt:", vm.toString(salt));

        CoreHook deployedHook = new CoreHook{salt: salt}(poolManagerAddress, marketFactory, address(vtsOrchestrator));
        require(address(deployedHook) == hookAddress, "CoreHook: address mismatch");

        return address(deployedHook);
    }

    /**
     * @dev Deploys MarketFactory with LiquidityHub and VTSOrchestrator
     * @return The deployed MarketFactory address
     * @notice MMPositionManager is added to bounds separately via _addAddressesToBounds()
     */
    function _deployMarketFactory() internal returns (address) {
        // Initial bounds array (empty for now, mmPositionManager added later via _addAddressesToBounds)
        // Note: LiquidityHub is automatically added to bounds in MarketFactory constructor
        address[] memory initialBounds = new address[](0);

        // Deploy MarketFactory with LiquidityHub, OracleHelper, and VTSOrchestrator
        MarketFactory factory =
            new MarketFactory(poolManagerAddress, liquidityHub, oracleHelper, vtsOrchestrator, initialBounds);

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

        signalManager = address(new VRLSignalManager(signalVerifier, signalExpiryInSeconds));
        console.log("SignalManager deployed at:", signalManager);
        ownedContracts.push(signalManager);

        // ? deploy settlement observer without verifiers. No verifiers developed yet.
        settlementObserver = address(new VRLSettlementObserver());
        ownedContracts.push(settlementObserver);
    }

    /**
     * @dev Deploys VTSOrchestrator
     * @return The deployed VTSOrchestrator address
     */
    function _deployVTSOrchestrator() internal returns (address) {
        VTSOrchestrator orchestrator =
            new VTSOrchestrator(poolManagerAddress, signalManager, oracleHelper, liquidityHub, settlementObserver);
        console.log("VTSOrchestrator deployed at:", address(orchestrator));
        return address(orchestrator);
    }

    /**
     * @dev Deploys MMPCommitmentDescriptor
     * @return The deployed MMPCommitmentDescriptor address
     */
    function _deployCommitmentDescriptor() internal returns (address) {
        MMPCommitmentDescriptor descriptor = new MMPCommitmentDescriptor();
        console.log("MMPCommitmentDescriptor deployed at:", address(descriptor));
        return address(descriptor);
    }

    /**
     * @dev Deploys MMPositionManager with LiquidityHub and VTSOrchestrator
     * @return The deployed MMPositionManager address
     */
    function _deployMMPositionManager() internal returns (address) {
        address commitmentDescriptorAddr = _deployCommitmentDescriptor();
        // Get WETH9 and permit2 from the PositionManager (which has them as immutable)
        IWETH9 weth9 = PositionManager(positionManagerAddress).WETH9();
        IAllowanceTransfer permit2 = PositionManager(positionManagerAddress).permit2();

        // Deploy MMPositionActionsImpl first (requires poolManager, liquidityHub, vtsOrchestrator)
        MMPositionActionsImpl actionsImpl = new MMPositionActionsImpl(poolManagerAddress, liquidityHub, vtsOrchestrator);
        console.log("MMPositionActionsImpl deployed at:", address(actionsImpl));

        // Deploy MMPositionManager (requires poolManager, liquidityHub, vtsOrchestrator, descriptor, weth9, permit2, actionsImpl)
        MMPositionManager positionManager = new MMPositionManager(
            poolManagerAddress,
            liquidityHub,
            vtsOrchestrator,
            commitmentDescriptorAddr,
            weth9,
            permit2,
            address(actionsImpl)
        );
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
        require(address(coreHookInstance.marketFactory()) == marketFactory, "CoreHook: marketFactory not set");
        require(factoryInstance.coreHook() == coreHook, "MarketFactory: coreHook not set");

        console.log("Hooks activated successfully");
    }

    /**
     * @dev adds all relevant addresses to bounds array in the market factory
     * Whitelist protocol addresses
     * @notice The following are already added to bounds in MarketFactory constructor:
     *         - address(this) [MarketFactory]
     *         - poolManager
     *         - liquidityHub
     * @notice MMPositionManager is added here as it's not passed to the constructor
     */
    function _addAddressesToBounds() internal {
        MarketFactory factoryInstance = MarketFactory(marketFactory);

        // MMPositionManager is the recipient of LCCs from VTSO issuance
        // It must be a bounds address to hold LCC tokens
        address[] memory bounds = new address[](1);
        bounds[0] = mmPositionManager;

        factoryInstance.addBounds(bounds);
        console.log("MMPositionManager added to bounds:", mmPositionManager);
    }

    /**
     * @dev Writes deployment addresses to JSON file for future reference
     */
    function _writeDeploymentAddresses() internal {
        // Write addresses to JSON file using ScriptHelper
        _setFilename(networkName);
        writeAddress("coreHook", coreHook);
        writeAddress("marketFactory", marketFactory);
        writeAddress("liquidityHub", liquidityHub);
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
        require(address(factory.poolManager()) == poolManagerAddress, "MarketFactory: wrong poolManager");
        require(factory.coreHook() == coreHook, "MarketFactory: wrong coreHook");

        console.log("MarketFactory configuration verified");

        // Verify hook cross-references
        CoreHook coreHookInstance = CoreHook(coreHook);

        require(address(coreHookInstance.marketFactory()) == marketFactory, "CoreHook: wrong marketFactory");

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

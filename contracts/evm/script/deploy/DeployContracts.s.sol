// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {console} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {CoreHook} from "../../src/CoreHook.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {NetworkConfig} from "../base/NetworkConfig.sol";
import {CREATE3Script} from "../base/CREATE3Script.sol";
import {HookFlags} from "../../src/libraries/HookFlags.sol";
import {MMPositionManager} from "../../src/MMPositionManager.sol";
import {MMPositionActionsImpl} from "../../src/MMPositionActionsImpl.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {VRLSignalManager} from "../../src/VRLSignalManager.sol";
import {VRLSettlementObserver} from "../../src/VRLSettlementObserver.sol";
import {VTSOrchestrator} from "../../src/VTSOrchestrator.sol";
import {OracleHelper} from "../../src/OracleHelper.sol";
import {MMPCommitmentDescriptor} from "../../src/MMPCommitmentDescriptor.sol";
import {LiquidityHub} from "../../src/LiquidityHub.sol";
import {GlobalConfig} from "../../src/GlobalConfig.sol";
import {ECDSASignatureSignalVerifier} from "../../src/verifiers/ECDSASignatureSignalVerifier.sol";

/**
 * @title DeployContracts
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
 * 8. Deploy CoreHook (with proper flags and MarketFactory address) - uses CREATE2 for hook flags
 * 9. Set hooks in MarketFactory using setHooks()
 * 10. Verify hooks (set cross-references)
 * 11. Add protocol addresses to bounds array (including MMPositionManager)
 * 12. Deploy GlobalConfig and transfer ownership
 *
 * @notice Most contracts use CREATE3 for deterministic addresses across chains.
 *         CoreHook uses CREATE2 with HookMiner to ensure correct hook flags.
 */
contract DeployContracts is CREATE3Script, NetworkConfig {
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
    address public vtsOrchestrator;
    address public actionsImpl;
    // Track Ownable contracts for ownership migration to GlobalConfig
    address[] public ownedContracts;

    // Contract names for CREATE3 salt generation
    string constant ORACLE_HELPER = "OracleHelper";
    string constant LIQUIDITY_HUB = "LiquidityHub";
    string constant SIGNAL_VERIFIER = "ECDSASignatureSignalVerifier";
    string constant SIGNAL_MANAGER = "VRLSignalManager";
    string constant SETTLEMENT_OBSERVER = "VRLSettlementObserver";
    string constant VTS_ORCHESTRATOR = "VTSOrchestrator";
    string constant COMMITMENT_DESCRIPTOR = "MMPCommitmentDescriptor";
    string constant ACTIONS_IMPL = "MMPositionActionsImpl";
    string constant MM_POSITION_MANAGER = "MMPositionManager";
    string constant MARKET_FACTORY = "MarketFactory";
    string constant GLOBAL_CONFIG = "GlobalConfig";

    constructor() CREATE3Script("1") {}

    /**
     * @dev Deploys a contract using CREATE3
     * @param name The contract name for salt generation
     * @param creationCode The contract creation bytecode (including constructor args)
     * @return deployed The deployed contract address
     */
    function _deployCreate3(string memory name, bytes memory creationCode) internal returns (address deployed) {
        bytes32 salt = getCreate3ContractSalt(name);
        deployed = create3.deploy(salt, creationCode);

        // Verify deployment address matches prediction
        address predicted = getCreate3Contract(name);
        require(deployed == predicted, string.concat(name, ": address mismatch"));
    }

    /**
     * @dev Logs predicted addresses before deployment
     */
    function _logPredictedAddresses() internal view {
        console.log("\n=== Predicted Addresses (CREATE3) ===");
        console.log("OracleHelper:", getCreate3Contract(ORACLE_HELPER));
        console.log("LiquidityHub:", getCreate3Contract(LIQUIDITY_HUB));
        console.log("ECDSASignatureSignalVerifier:", getCreate3Contract(SIGNAL_VERIFIER));
        console.log("VRLSignalManager:", getCreate3Contract(SIGNAL_MANAGER));
        console.log("VRLSettlementObserver:", getCreate3Contract(SETTLEMENT_OBSERVER));
        console.log("VTSOrchestrator:", getCreate3Contract(VTS_ORCHESTRATOR));
        console.log("MMPCommitmentDescriptor:", getCreate3Contract(COMMITMENT_DESCRIPTOR));
        console.log("MMPositionActionsImpl:", getCreate3Contract(ACTIONS_IMPL));
        console.log("MMPositionManager:", getCreate3Contract(MM_POSITION_MANAGER));
        console.log("MarketFactory:", getCreate3Contract(MARKET_FACTORY));
        console.log("GlobalConfig:", getCreate3Contract(GLOBAL_CONFIG));
        console.log("\nNote: CoreHook uses CREATE2 (not CREATE3) due to hook flag requirements");
    }

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        // Initialise network configuration
        _initNetwork();

        console.log("Starting deployment of CoreHook, ProxyHook, and MarketFactory on %s...", networkName);
        console.log("Pool Manager:", config.poolManager);
        console.log("CREATE2 Deployer:", config.create2Deployer);
        console.log("CREATE3 Factory:", address(create3));

        // Log predicted addresses before deployment
        _logPredictedAddresses();

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
        bytes memory creationCode = type(GlobalConfig).creationCode;
        address deployed = _deployCreate3(GLOBAL_CONFIG, creationCode);
        console.log("GlobalConfig deployed at:", deployed);

        // Transfer ownership of all Ownable contracts to the global config
        uint256 len = ownedContracts.length;
        console.log("Transferring ownership of", len, "contracts to GlobalConfig");
        for (uint256 i = 0; i < len; i++) {
            Ownable(ownedContracts[i]).transferOwnership(deployed);
            console.log("  - Transferred ownership of", ownedContracts[i]);
        }
        return deployed;
    }

    function _deployOracleHelper() internal returns (address) {
        // read in the predeployed address of the resilient oracle from the env
        address resilientOracleAddress = vm.envAddress("RESILIENT_ORACLE_ADDRESS");
        console.log("Oracle loaded at address:", resilientOracleAddress);

        bytes memory constructorArgs = abi.encode(resilientOracleAddress);
        bytes memory creationCode = abi.encodePacked(type(OracleHelper).creationCode, constructorArgs);

        address deployed = _deployCreate3(ORACLE_HELPER, creationCode);
        console.log("OracleHelper deployed at:", deployed);

        return deployed;
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

        bytes memory constructorArgs = abi.encode(oracleHelper, nativeAssetName, nativeAssetSymbol, nativeAssetDecimals);
        bytes memory creationCode = abi.encodePacked(type(LiquidityHub).creationCode, constructorArgs);

        address deployed = _deployCreate3(LIQUIDITY_HUB, creationCode);
        console.log("LiquidityHub deployed at:", deployed);

        return payable(deployed);
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
        bytes memory constructorArgs = abi.encode(config.poolManager, marketFactory, address(vtsOrchestrator));

        (address hookAddress, bytes32 salt) = HookMiner.find(
            config.create2Deployer, HookFlags.CORE_HOOK_FLAGS, type(CoreHook).creationCode, constructorArgs
        );

        console.log("CoreHook will be deployed to:", hookAddress);
        console.log("CoreHook salt:", vm.toString(salt));

        CoreHook deployedHook = new CoreHook{salt: salt}(config.poolManager, marketFactory, address(vtsOrchestrator));
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
        bytes memory constructorArgs =
            abi.encode(config.poolManager, liquidityHub, oracleHelper, vtsOrchestrator, initialBounds);
        bytes memory creationCode = abi.encodePacked(type(MarketFactory).creationCode, constructorArgs);

        address deployed = _deployCreate3(MARKET_FACTORY, creationCode);
        console.log("MarketFactory deployed at:", deployed);
        return deployed;
    }

    /**
     * @dev Deploys Verifiers
     */
    function _deployVerifiers() internal {
        uint256 signalExpiryInSeconds = 3600;

        // deploy the proof verifiers
        address publicKeyAddress = vm.envAddress("PUBLIC_KEY_SIGNAL_VERIFIER_ADDRESS");

        bytes memory verifierConstructorArgs = abi.encode(publicKeyAddress);
        bytes memory verifierCreationCode =
            abi.encodePacked(type(ECDSASignatureSignalVerifier).creationCode, verifierConstructorArgs);
        address signalVerifier = _deployCreate3(SIGNAL_VERIFIER, verifierCreationCode);
        console.log("ECDSASignatureSignalVerifier deployed at:", signalVerifier);

        bytes memory signalManagerConstructorArgs = abi.encode(signalVerifier, signalExpiryInSeconds);
        bytes memory signalManagerCreationCode =
            abi.encodePacked(type(VRLSignalManager).creationCode, signalManagerConstructorArgs);
        signalManager = _deployCreate3(SIGNAL_MANAGER, signalManagerCreationCode);
        console.log("SignalManager deployed at:", signalManager);
        ownedContracts.push(signalManager);

        // ? deploy settlement observer without verifiers. No verifiers developed yet.
        bytes memory observerCreationCode = type(VRLSettlementObserver).creationCode;
        settlementObserver = _deployCreate3(SETTLEMENT_OBSERVER, observerCreationCode);
        console.log("SettlementObserver deployed at:", settlementObserver);
        ownedContracts.push(settlementObserver);
    }

    /**
     * @dev Deploys VTSOrchestrator
     * @return The deployed VTSOrchestrator address
     */
    function _deployVTSOrchestrator() internal returns (address) {
        bytes memory constructorArgs =
            abi.encode(config.poolManager, signalManager, oracleHelper, liquidityHub, settlementObserver);
        bytes memory creationCode = abi.encodePacked(type(VTSOrchestrator).creationCode, constructorArgs);

        address deployed = _deployCreate3(VTS_ORCHESTRATOR, creationCode);
        console.log("VTSOrchestrator deployed at:", deployed);
        return deployed;
    }

    /**
     * @dev Deploys MMPCommitmentDescriptor
     * @return The deployed MMPCommitmentDescriptor address
     */
    function _deployCommitmentDescriptor() internal returns (address) {
        bytes memory creationCode = type(MMPCommitmentDescriptor).creationCode;
        address deployed = _deployCreate3(COMMITMENT_DESCRIPTOR, creationCode);
        console.log("MMPCommitmentDescriptor deployed at:", deployed);
        return deployed;
    }

    /**
     * @dev Deploys MMPositionManager with LiquidityHub and VTSOrchestrator
     * @return The deployed MMPositionManager address
     */
    function _deployMMPositionManager() internal returns (address) {
        address commitmentDescriptorAddr = _deployCommitmentDescriptor();
        // Get WETH9 and permit2 from the PositionManager (which has them as immutable)
        IWETH9 weth9 = PositionManager(payable(config.positionManager)).WETH9();
        IAllowanceTransfer permit2 = PositionManager(payable(config.positionManager)).permit2();

        // Deploy MMPositionActionsImpl first (requires poolManager, liquidityHub, vtsOrchestrator)
        bytes memory actionsImplConstructorArgs = abi.encode(config.poolManager, liquidityHub, vtsOrchestrator);
        bytes memory actionsImplCreationCode =
            abi.encodePacked(type(MMPositionActionsImpl).creationCode, actionsImplConstructorArgs);
        actionsImpl = _deployCreate3(ACTIONS_IMPL, actionsImplCreationCode);
        console.log("MMPositionActionsImpl deployed at:", actionsImpl);

        // Deploy MMPositionManager (requires poolManager, liquidityHub, vtsOrchestrator, descriptor, weth9, permit2, actionsImpl)
        bytes memory positionManagerConstructorArgs = abi.encode(
            config.poolManager, liquidityHub, vtsOrchestrator, commitmentDescriptorAddr, weth9, permit2, actionsImpl
        );
        bytes memory positionManagerCreationCode =
            abi.encodePacked(type(MMPositionManager).creationCode, positionManagerConstructorArgs);
        address deployed = _deployCreate3(MM_POSITION_MANAGER, positionManagerCreationCode);
        console.log("MMPositionManager deployed at:", deployed);
        return deployed;
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
        // Write addresses to JSON file using FileHelper
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
        require(address(factory.poolManager()) == config.poolManager, "MarketFactory: wrong poolManager");
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

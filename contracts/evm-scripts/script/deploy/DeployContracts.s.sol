// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {DeployProtocolBase} from "../base/deploy/DeployProtocolBase.sol";
import {CoreHook} from "src/CoreHook.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {HookFlags} from "src/libraries/HookFlags.sol";

/**
 * @title DeployContracts
 * @notice Comprehensive deployment script for CoreHook, ProxyHook, and MarketFactory
 * @dev Deploys contracts in the correct order with proper HookMiner logic
 *
 * Deployment Order:
 * 1. Deploy GlobalConfig FIRST (used as initialOwner for all Ownable contracts via CREATE3)
 * 2. Deploy OracleHelper (with GlobalConfig as initialOwner)
 * 3. Deploy LiquidityHub (with GlobalConfig as initialOwner)
 * 4. Deploy VTSOrchestrator (with GlobalConfig as initialOwner)
 * 5. Deploy Verifiers (submitter-bound to VTSOrchestrator, with GlobalConfig as initialOwner)
 * 6. Register VRL proof handlers in VTSOrchestrator
 * 7. Deploy DirectLPDeltaResolver
 * 8. Deploy MarketFactory (with GlobalConfig as initialOwner)
 * 9. Enable MarketFactory in LiquidityHub
 * 10. Deploy MMPositionManager (requires MarketFactory in constructor path)
 * 11. Deploy CoreHook (with proper flags and MarketFactory address) - uses CREATE2 for hook flags
 * 12. Initialise MarketFactory (set hooks + bounds)
 * 13. Verify hooks (set cross-references)
 *
 * @notice Most contracts use CREATE3 for deterministic addresses across chains.
 *         CoreHook uses CREATE2 with HookMiner to ensure correct hook flags.
 * @notice GlobalConfig is deployed first and passed as initialOwner to all Ownable contracts.
 *         This is required because CREATE3 uses a temporary proxy contract as msg.sender in constructors,
 *         so contracts cannot rely on msg.sender being the deployer.
 *         Reference: https://github.com/ZeframLou/create3-factory
 */
contract DeployContracts is DeployProtocolBase {
    // Deployed contract addresses
    address public coreHook;
    address public proxyHook;
    address public marketFactory;
    address public mmPositionManager;
    address public oracleHelper;
    address payable public liquidityHub;
    address public signalManager;
    address public settlementObserver;
    address public signalVerifier;
    address public globalConfig;
    address public commitmentDescriptor;
    address public vtsOrchestrator;
    address public actionsImpl;
    address public directLPDeltaResolver;
    address public queueCustodian;

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
        console.log("MMQueueCustodian:", getCreate3Contract(QUEUE_CUSTODIAN));
        console.log("MMPositionManager:", getCreate3Contract(MM_POSITION_MANAGER));
        console.log("DirectLPDeltaResolver:", getCreate3Contract(DIRECT_LP_DELTA_RESOLVER));
        console.log("MarketFactory:", getCreate3Contract(MARKET_FACTORY));
        console.log("GlobalConfig:", getCreate3Contract(GLOBAL_CONFIG));
        console.log("\nNote: CoreHook uses CREATE2 (not CREATE3) due to hook flag requirements");
    }

    function run() external {
        uint256 deployerPrivateKey = _getDeployerPrivateKey();
        address deployer = _getDeployer();

        // Initialise network configuration
        _initNetwork();

        console.log("Starting deployment of CoreHook, ProxyHook, and MarketFactory on %s...", networkName);
        console.log("Pool Manager:", config.poolManager);
        console.log("CREATE2 Deployer:", config.create2Deployer);
        console.log("CREATE3 Factory:", address(create3));

        // Log predicted addresses before deployment
        _logPredictedAddresses();

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy GlobalConfig FIRST
        // GlobalConfig is deployed first so it can be passed as initialOwner to all Ownable contracts.
        // This is required because CREATE3 uses a temporary proxy contract as msg.sender in constructors.
        console.log("\n=== Step 1: Deploying GlobalConfig ===");
        globalConfig = _deployGlobalConfig(deployer);
        console.log("GlobalConfig deployed at:", globalConfig);
        console.log("GlobalConfig owner:", deployer);

        // Step 2: Deploy OracleHelper (with GlobalConfig as initialOwner)
        // @dev the ResilientOracle would have been deployed and provided as an env var `RESILIENT_ORACLE_ADDRESS`
        console.log("\n=== Step 2: Deploying OracleHelper ===");
        address resilientOracleAddress = vm.envAddress("RESILIENT_ORACLE_ADDRESS");
        console.log("Oracle loaded at address:", resilientOracleAddress);
        oracleHelper = _deployOracleHelper(resilientOracleAddress, globalConfig);
        console.log("OracleHelper deployed at:", oracleHelper);
        console.log("OracleHelper owner:", globalConfig);

        // Step 3: Deploy LiquidityHub (with GlobalConfig as initialOwner)
        console.log("\n=== Step 3: Deploying LiquidityHub ===");
        string memory nativeAssetName = vm.envOr("NATIVE_ASSET_NAME", string("Ethereum"));
        string memory nativeAssetSymbol = vm.envOr("NATIVE_ASSET_SYMBOL", string("ETH"));
        uint8 nativeAssetDecimals = uint8(vm.envOr("NATIVE_ASSET_DECIMALS", uint256(18)));
        console.log("Native asset name:", nativeAssetName);
        console.log("Native asset symbol:", nativeAssetSymbol);
        console.log("Native asset decimals:", uint256(nativeAssetDecimals));
        liquidityHub =
            _deployLiquidityHub(oracleHelper, nativeAssetName, nativeAssetSymbol, nativeAssetDecimals, globalConfig);
        console.log("LiquidityHub deployed at:", liquidityHub);
        console.log("LiquidityHub owner:", globalConfig);

        // Step 4: Deploy VTSOrchestrator (with GlobalConfig as initialOwner)
        console.log("\n=== Step 4: Deploying VTSOrchestrator ===");
        vtsOrchestrator = _deployVTSOrchestrator(oracleHelper, liquidityHub, globalConfig);
        console.log("VTSOrchestrator deployed at:", vtsOrchestrator);
        console.log("VTSOrchestrator owner:", globalConfig);

        // Step 5: Deploy Verifiers (VTSO dependencies, with GlobalConfig as initialOwner)
        console.log("\n=== Step 5: Deploying Verifiers (VTSO Dependencies) ===");
        address publicKeyAddress = vm.envAddress("PUBLIC_KEY_SIGNAL_VERIFIER_ADDRESS");
        console.log("Signal verifier public key address:", publicKeyAddress);
        signalVerifier = _deploySignalVerifier(publicKeyAddress);
        console.log("ECDSASignatureSignalVerifier deployed at:", signalVerifier);
        signalManager = _deploySignalManager(signalVerifier, 3600, vtsOrchestrator, globalConfig);
        settlementObserver = _deploySettlementObserver(vtsOrchestrator, globalConfig);
        console.log("SignalManager deployed at:", signalManager);
        console.log("SignalManager owner:", globalConfig);
        console.log("SettlementObserver deployed at:", settlementObserver);
        console.log("SettlementObserver owner:", globalConfig);

        // Step 6: Register VRL proof handlers
        console.log("\n=== Step 6: Registering VRL Proof Handlers ===");
        _registerVRLProofHandlers(globalConfig, vtsOrchestrator, signalManager, settlementObserver);
        console.log("VRL proof handlers registered in VTSOrchestrator (via GlobalConfig.proxyCall)");

        // Step 7: Deploy DirectLPDeltaResolver (must be protocol-bound for afterModifyLiquidity)
        console.log("\n=== Step 7: Deploying DirectLPDeltaResolver ===");
        directLPDeltaResolver = _deployDirectLPDeltaResolver(liquidityHub);
        console.log("DirectLPDeltaResolver deployed at:", directLPDeltaResolver);

        // Step 8: Deploy MarketFactory (with GlobalConfig as initialOwner)
        console.log("\n=== Step 8: Deploying MarketFactory ===");
        marketFactory = _deployMarketFactory(liquidityHub, oracleHelper, vtsOrchestrator, globalConfig);
        console.log("MarketFactory deployed at:", marketFactory);
        console.log("MarketFactory owner:", globalConfig);

        // Step 9: Enable MarketFactory in LiquidityHub
        console.log("\n=== Step 9: Enabling MarketFactory in LiquidityHub ===");
        _enableFactoryInLiquidityHub(globalConfig, liquidityHub, marketFactory);
        console.log("MarketFactory enabled in LiquidityHub (via GlobalConfig.proxyCall)");

        // Step 10: Deploy MMPositionManager
        console.log("\n=== Step 10: Deploying MMPositionManager ===");
        commitmentDescriptor = _deployCommitmentDescriptor();
        (actionsImpl, queueCustodian, mmPositionManager) =
            _deployMMStack(marketFactory, vtsOrchestrator, commitmentDescriptor, deployer);
        console.log("MMPCommitmentDescriptor deployed at:", commitmentDescriptor);
        console.log("MMPositionActionsImpl deployed at:", actionsImpl);
        console.log("MMQueueCustodian deployed at:", queueCustodian);
        console.log("MMQueueCustodian authorised binder:", deployer);
        console.log("MMPositionManager deployed at:", mmPositionManager);
        console.log("MMQueueCustodian positionManager bound to:", mmPositionManager);

        // Step 11: Deploy CoreHook
        console.log("\n=== Step 11: Deploying CoreHook ===");
        coreHook = _deployCoreHook(marketFactory, vtsOrchestrator);
        console.log("CoreHook deployed at:", coreHook);

        // Step 12: Initialise MarketFactory
        console.log("\n=== Step 12: Initialising MarketFactory ===");
        _initialiseFactory(
            globalConfig, marketFactory, coreHook, mmPositionManager, queueCustodian, directLPDeltaResolver
        );
        console.log("MarketFactory initialised successfully (via GlobalConfig.proxyCall)");

        // Step 13: Verify hooks addresses across the contracts
        console.log("\n=== Step 13: Verifying Hooks ===");
        _verifyHooks();

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

    /**
     * @dev Verifies hooks by checking cross-references
     * This is called after MarketFactory initialisation to verify the relationship
     */
    function _verifyHooks() internal view {
        // Verify the cross-references are set correctly after initialisation

        CoreHook coreHookInstance = CoreHook(coreHook);
        MarketFactory factoryInstance = MarketFactory(marketFactory);

        // Verify the hooks are properly configured
        require(address(coreHookInstance.marketFactory()) == marketFactory, "CoreHook: marketFactory not set");
        require(factoryInstance.coreHook() == coreHook, "MarketFactory: coreHook not set");

        console.log("Hooks activated successfully");
    }

    /**
     * @dev Writes deployment addresses to JSON file for future reference
     */
    function _writeDeploymentAddresses() internal {
        // Write addresses to JSON file using FileHelper
        _setFilename(networkName);
        // NOTE: Some keys are duplicated for backwards compatibility with older scripts.
        // Prefer the more explicit names when adding new scripts.

        // Core protocol surfaces
        writeAddress("coreHook", coreHook);
        writeAddress("proxyHook", proxyHook);
        writeAddress("marketFactory", marketFactory);
        writeAddress("liquidityHub", liquidityHub);
        writeAddress("positionManager", mmPositionManager); // legacy key (actually MMPositionManager)
        writeAddress("mmPositionManager", mmPositionManager);
        writeAddress("directLPDeltaResolver", directLPDeltaResolver);
        writeAddress("oracleHelper", oracleHelper);
        writeAddress("globalConfig", globalConfig);
        writeAddress("vtsOrchestrator", vtsOrchestrator);

        // VRL / verification stack
        writeAddress("signalVerifier", signalVerifier);
        writeAddress("signalManager", signalManager);
        writeAddress("settlementObserver", settlementObserver);

        // MM / market-maker stack
        writeAddress("commitmentDescriptor", commitmentDescriptor);
        writeAddress("actionsImpl", actionsImpl);
        writeAddress("queueCustodian", queueCustodian);

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
        require(factory.isInitialised(), "MarketFactory: not initialised");

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

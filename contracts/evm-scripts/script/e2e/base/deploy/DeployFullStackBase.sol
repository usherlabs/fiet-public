// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {DeployProtocolBase} from "../../../base/deploy/DeployProtocolBase.sol";

import {MockResilientOracle} from "../../mocks/oracle/MockResilientOracle.sol";
import {MockChainlinkOracle} from "../../mocks/oracle/MockChainlinkOracle.sol";

// Linked libraries to deploy
import {VTSPositionLib} from "src/libraries/VTSPositionLib.sol";
import {VTSSwapLib} from "src/libraries/VTSSwapLib.sol";
import {VTSCommitLib} from "src/libraries/VTSCommitLib.sol";
import {LCCFactoryLinkedLib} from "src/libraries/LCCFactoryLib.sol";
import {LiquidityHubLinkedLib} from "src/libraries/LiquidityHubLinkedLib.sol";
import {VTSFeeLinkedLib} from "src/libraries/VTSFeeLib.sol";

/**
 * @dev E2E deploy base: deploy full stack (libraries + contracts) and return addresses (no JSON writes).
 *
 * Notes:
 * - ALWAYS deploys: CREATE3 will revert if already deployed for the same deployer+salt.
 * - Linking: any script that deploys linked contracts must be compiled with linking enabled
 *   (run with `FOUNDRY_PROFILE=deploy` in `contracts/evm-scripts`).
 */
abstract contract DeployFullStackBase is DeployProtocolBase {
    struct LibraryAddrs {
        address vtsPositionLib;
        address vtsSwapLib;
        address vtsCommitLib;
        address vtsFeeLinkedLib;
        address lccFactoryLinkedLib;
        address liquidityHubLinkedLib;
    }

    struct ContractAddrs {
        address resilientOracle;
        /// @dev MAIN oracle used by `MockResilientOracle` (E2E uses this to set prices).
        address mainOracle;
        address coreHook;
        address marketFactory;
        address mmPositionManager;
        address queueCustodian;
        address oracleHelper;
        address payable liquidityHub;
        address signalManager;
        address settlementObserver;
        address globalConfig;
        address commitmentDescriptor;
        address vtsOrchestrator;
        address actionsImpl;
        address directLPDeltaResolver;
    }

    struct FullStack {
        LibraryAddrs libs;
        ContractAddrs contracts;
    }

    // Stored result of the most recent deployment in this script run.
    FullStack internal _deployed;

    // E2E-only CREATE3 names (not part of canonical protocol deployment set)
    string internal constant MOCK_RESILIENT_ORACLE = "MockResilientOracle";
    string internal constant MOCK_CHAINLINK_ORACLE = "MockChainlinkOracle";

    // Library names (must match existing deploy scripts for deterministic addresses)
    string internal constant VTS_POSITION_LIB = "VTSPositionLib";
    string internal constant VTS_SWAP_LIB = "VTSSwapLib";
    string internal constant VTS_COMMIT_LIB = "VTSCommitLib";
    string internal constant LCC_FACTORY_LINKED_LIB = "LCCFactoryLinkedLib";
    string internal constant LIQUIDITY_HUB_LINKED_LIB = "LiquidityHubLinkedLib";
    string internal constant VTS_FEE_LINKED_LIB = "VTSFeeLinkedLib";

    function _deployLibrary(string memory name, bytes memory creationCode) internal returns (address deployed) {
        return _deployCreate3(name, creationCode);
    }

    function _deployAll() internal returns (FullStack memory out) {
        // Load network constants + deployment file path (even though we don't write).
        _initNetwork();

        console.log("E2E DeployFullStack on %s", networkName);
        console.log("PoolManager:", config.poolManager);
        console.log("CREATE2 Deployer:", config.create2Deployer);
        console.log("CREATE3 Factory:", address(create3));

        vm.startBroadcast(_getDeployerPrivateKey());

        // ---- Deploy libraries (CREATE3) ----
        out.libs.lccFactoryLinkedLib = _deployLibrary(LCC_FACTORY_LINKED_LIB, type(LCCFactoryLinkedLib).creationCode);
        out.libs.liquidityHubLinkedLib =
            _deployLibrary(LIQUIDITY_HUB_LINKED_LIB, type(LiquidityHubLinkedLib).creationCode);
        out.libs.vtsFeeLinkedLib = _deployLibrary(VTS_FEE_LINKED_LIB, type(VTSFeeLinkedLib).creationCode);
        out.libs.vtsCommitLib = _deployLibrary(VTS_COMMIT_LIB, type(VTSCommitLib).creationCode);
        out.libs.vtsSwapLib = _deployLibrary(VTS_SWAP_LIB, type(VTSSwapLib).creationCode);
        out.libs.vtsPositionLib = _deployLibrary(VTS_POSITION_LIB, type(VTSPositionLib).creationCode);

        // ---- Deploy contracts (CREATE3/CREATE2) ----
        address deployer = _getDeployer();

        // 1) GlobalConfig (owned by deployer EOA so it can proxyCall)
        out.contracts.globalConfig = _deployGlobalConfig(deployer);

        // 2) MockResilientOracle (standalone E2E)
        out.contracts.resilientOracle = _deployCreate3(MOCK_RESILIENT_ORACLE, type(MockResilientOracle).creationCode);

        // 3) MAIN oracle (standalone E2E): `MockResilientOracle` forwards getPrice() to this.
        out.contracts.mainOracle = _deployCreate3(MOCK_CHAINLINK_ORACLE, type(MockChainlinkOracle).creationCode);

        // 4) OracleHelper (owned by GlobalConfig)
        out.contracts.oracleHelper = _deployOracleHelper(out.contracts.resilientOracle, out.contracts.globalConfig);

        // 5) LiquidityHub (owned by GlobalConfig)
        string memory nativeAssetName = "Ethereum";
        string memory nativeAssetSymbol = "ETH";
        uint8 nativeAssetDecimals = 18;
        out.contracts.liquidityHub = _deployLiquidityHub(
            out.contracts.oracleHelper,
            nativeAssetName,
            nativeAssetSymbol,
            nativeAssetDecimals,
            out.contracts.globalConfig
        );

        // 6) VTSOrchestrator (owned by GlobalConfig)
        out.contracts.vtsOrchestrator =
            _deployVTSOrchestrator(out.contracts.oracleHelper, out.contracts.liquidityHub, out.contracts.globalConfig);

        // 7) Verifiers / managers
        uint256 signalExpiryInSeconds = 3600;
        address signalVerifier = _deploySignalVerifier(deployer);

        out.contracts.signalManager = _deploySignalManager(
            signalVerifier, signalExpiryInSeconds, out.contracts.vtsOrchestrator, out.contracts.globalConfig
        );

        out.contracts.settlementObserver =
            _deploySettlementObserver(out.contracts.vtsOrchestrator, out.contracts.globalConfig);

        _registerVRLProofHandlers(
            out.contracts.globalConfig,
            out.contracts.vtsOrchestrator,
            out.contracts.signalManager,
            out.contracts.settlementObserver
        );

        // 8) DirectLPDeltaResolver
        out.contracts.directLPDeltaResolver = _deployDirectLPDeltaResolver(out.contracts.liquidityHub);

        // 9) MarketFactory (owned by GlobalConfig)
        out.contracts.marketFactory = _deployMarketFactory(
            out.contracts.liquidityHub,
            out.contracts.oracleHelper,
            out.contracts.vtsOrchestrator,
            out.contracts.globalConfig
        );

        // 10) Enable MarketFactory in LiquidityHub (via GlobalConfig)
        _enableFactoryInLiquidityHub(
            out.contracts.globalConfig, out.contracts.liquidityHub, out.contracts.marketFactory
        );

        // 11) MMPCommitmentDescriptor
        out.contracts.commitmentDescriptor = _deployCommitmentDescriptor();

        // 12) MMPositionActionsImpl + MMQueueCustodian + MMPositionManager
        (out.contracts.actionsImpl, out.contracts.queueCustodian, out.contracts.mmPositionManager) = _deployMMStack(
            out.contracts.marketFactory, out.contracts.vtsOrchestrator, out.contracts.commitmentDescriptor, deployer
        );

        // 13) Deploy CoreHook via CREATE2 HookMiner
        out.contracts.coreHook = _deployCoreHook(out.contracts.marketFactory, out.contracts.vtsOrchestrator);

        // 14) Initialise MarketFactory (via GlobalConfig)
        _initialiseFactory(
            out.contracts.globalConfig,
            out.contracts.marketFactory,
            out.contracts.coreHook,
            out.contracts.mmPositionManager,
            out.contracts.queueCustodian,
            out.contracts.directLPDeltaResolver
        );

        vm.stopBroadcast();

        _deployed = out;
    }

    function _deployedFullStack() internal view returns (FullStack memory) {
        return _deployed;
    }
}


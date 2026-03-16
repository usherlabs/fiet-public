// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {CoreHook} from "src/CoreHook.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {HookFlags} from "src/libraries/HookFlags.sol";
import {MMQueueCustodian} from "src/MMQueueCustodian.sol";
import {MMPositionManager} from "src/MMPositionManager.sol";
import {MMPositionActionsImpl} from "src/MMPositionActionsImpl.sol";
import {VRLSignalManager} from "src/VRLSignalManager.sol";
import {VRLSettlementObserver} from "src/VRLSettlementObserver.sol";
import {VTSOrchestrator} from "src/VTSOrchestrator.sol";
import {OracleHelper} from "src/OracleHelper.sol";
import {MMPCommitmentDescriptor} from "src/MMPCommitmentDescriptor.sol";
import {LiquidityHub} from "src/LiquidityHub.sol";
import {GlobalConfig} from "src/GlobalConfig.sol";
import {ECDSASignatureSignalVerifier} from "src/verifiers/ECDSASignatureSignalVerifier.sol";
import {DirectLPDeltaResolver} from "src/DirectLPDeltaResolver.sol";

import {PositionManager} from "v4-periphery/src/PositionManager.sol";

import {CREATE3Script} from "../../../base/CREATE3Script.sol";
import {NetworkConfig} from "../../../base/NetworkConfig.sol";

import {MockResilientOracle} from "../../mocks/oracle/MockResilientOracle.sol";
import {MockChainlinkOracle} from "../../mocks/oracle/MockChainlinkOracle.sol";

// Linked libraries to deploy
import {VTSPositionLib} from "src/libraries/VTSPositionLib.sol";
import {VTSSwapLib} from "src/libraries/VTSSwapLib.sol";
import {VTSCommitLib} from "src/libraries/VTSCommitLib.sol";
import {LCCFactoryLinkedLib} from "src/libraries/LCCFactoryLib.sol";
import {VTSFeeLinkedLib} from "src/libraries/VTSFeeLib.sol";

/**
 * @dev E2E deploy base: deploy full stack (libraries + contracts) and return addresses (no JSON writes).
 *
 * Notes:
 * - ALWAYS deploys: CREATE3 will revert if already deployed for the same deployer+salt.
 * - Linking: any script that deploys linked contracts must be compiled with linking enabled
 *   (run with `FOUNDRY_PROFILE=deploy` in `contracts/evm-scripts`).
 */
abstract contract DeployFullStackBase is CREATE3Script, NetworkConfig {
    constructor() CREATE3Script("1") {}

    struct LibraryAddrs {
        address vtsPositionLib;
        address vtsSwapLib;
        address vtsCommitLib;
        address vtsFeeLinkedLib;
        address lccFactoryLinkedLib;
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

    // CREATE3 names (must match existing deploy scripts for deterministic addresses)
    string internal constant MOCK_RESILIENT_ORACLE = "MockResilientOracle";
    string internal constant MOCK_CHAINLINK_ORACLE = "MockChainlinkOracle";
    string internal constant ORACLE_HELPER = "OracleHelper";
    string internal constant LIQUIDITY_HUB = "LiquidityHub";
    string internal constant SIGNAL_VERIFIER = "ECDSASignatureSignalVerifier";
    string internal constant SIGNAL_MANAGER = "VRLSignalManager";
    string internal constant SETTLEMENT_OBSERVER = "VRLSettlementObserver";
    string internal constant VTS_ORCHESTRATOR = "VTSOrchestrator";
    string internal constant COMMITMENT_DESCRIPTOR = "MMPCommitmentDescriptor";
    string internal constant ACTIONS_IMPL = "MMPositionActionsImpl";
    string internal constant QUEUE_CUSTODIAN = "MMQueueCustodian";
    string internal constant MM_POSITION_MANAGER = "MMPositionManager";
    string internal constant DIRECT_LP_DELTA_RESOLVER = "DirectLPDeltaResolver";
    string internal constant MARKET_FACTORY = "MarketFactory";
    string internal constant GLOBAL_CONFIG = "GlobalConfig";

    // Library names (must match existing deploy scripts for deterministic addresses)
    string internal constant VTS_POSITION_LIB = "VTSPositionLib";
    string internal constant VTS_SWAP_LIB = "VTSSwapLib";
    string internal constant VTS_COMMIT_LIB = "VTSCommitLib";
    string internal constant LCC_FACTORY_LINKED_LIB = "LCCFactoryLinkedLib";
    string internal constant VTS_FEE_LINKED_LIB = "VTSFeeLinkedLib";

    function _deployCreate3(string memory name, bytes memory creationCode) internal returns (address deployed) {
        bytes32 salt = getCreate3ContractSalt(name);
        deployed = create3.deploy(salt, creationCode);
        address predicted = getCreate3Contract(name);
        require(deployed == predicted, string.concat(name, ": address mismatch"));
    }

    function _deployLibrary(string memory name, bytes memory creationCode) internal returns (address deployed) {
        return _deployCreate3(name, creationCode);
    }

    function _deployMMStack(address liquidityHub, address vtsOrchestrator, address commitmentDescriptor, address deployer)
        internal
        returns (address actionsImpl, address queueCustodian, address mmPositionManager)
    {
        address weth9 = address(PositionManager(payable(config.positionManager)).WETH9());
        address permit2 = address(PositionManager(payable(config.positionManager)).permit2());

        actionsImpl = _deployCreate3(
            ACTIONS_IMPL,
            abi.encodePacked(
                type(MMPositionActionsImpl).creationCode, abi.encode(config.poolManager, liquidityHub, vtsOrchestrator)
            )
        );

        queueCustodian = _deployCreate3(
            QUEUE_CUSTODIAN,
            abi.encodePacked(type(MMQueueCustodian).creationCode, abi.encode(deployer))
        );

        mmPositionManager = _deployCreate3(
            MM_POSITION_MANAGER,
            abi.encodePacked(
                type(MMPositionManager).creationCode,
                abi.encode(
                    config.poolManager,
                    liquidityHub,
                    vtsOrchestrator,
                    commitmentDescriptor,
                    weth9,
                    permit2,
                    actionsImpl,
                    queueCustodian
                )
            )
        );
        MMQueueCustodian(queueCustodian).setPositionManager(mmPositionManager);
    }

    function _deployCoreHook(address marketFactory, address vtsOrchestrator) internal returns (address coreHook) {
        bytes memory ctorArgs = abi.encode(config.poolManager, marketFactory, vtsOrchestrator);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(config.create2Deployer, HookFlags.CORE_HOOK_FLAGS, type(CoreHook).creationCode, ctorArgs);
        CoreHook deployedHook = new CoreHook{salt: salt}(config.poolManager, marketFactory, vtsOrchestrator);
        require(address(deployedHook) == hookAddress, "CoreHook: address mismatch");
        coreHook = hookAddress;
    }

    function _initialiseFactory(
        address globalConfig,
        address marketFactory,
        address coreHook,
        address mmPositionManager,
        address queueCustodian,
        address directLPDeltaResolver
    ) internal {
        address[] memory initialBounds = new address[](3);
        initialBounds[0] = mmPositionManager;
        initialBounds[1] = queueCustodian;
        initialBounds[2] = directLPDeltaResolver;
        GlobalConfig(globalConfig)
            .proxyCall(
                marketFactory, abi.encodeWithSelector(MarketFactory.initialise.selector, coreHook, initialBounds)
            );
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
        out.libs.vtsFeeLinkedLib = _deployLibrary(VTS_FEE_LINKED_LIB, type(VTSFeeLinkedLib).creationCode);
        out.libs.vtsCommitLib = _deployLibrary(VTS_COMMIT_LIB, type(VTSCommitLib).creationCode);
        out.libs.vtsSwapLib = _deployLibrary(VTS_SWAP_LIB, type(VTSSwapLib).creationCode);
        out.libs.vtsPositionLib = _deployLibrary(VTS_POSITION_LIB, type(VTSPositionLib).creationCode);

        // ---- Deploy contracts (CREATE3/CREATE2) ----
        address deployer = _getDeployer();

        // 1) GlobalConfig (owned by deployer EOA so it can proxyCall)
        out.contracts.globalConfig =
            _deployCreate3(GLOBAL_CONFIG, abi.encodePacked(type(GlobalConfig).creationCode, abi.encode(deployer)));

        // 2) MockResilientOracle (standalone E2E)
        out.contracts.resilientOracle = _deployCreate3(MOCK_RESILIENT_ORACLE, type(MockResilientOracle).creationCode);

        // 3) MAIN oracle (standalone E2E): `MockResilientOracle` forwards getPrice() to this.
        out.contracts.mainOracle = _deployCreate3(MOCK_CHAINLINK_ORACLE, type(MockChainlinkOracle).creationCode);

        // 4) OracleHelper (owned by GlobalConfig)
        out.contracts.oracleHelper = _deployCreate3(
            ORACLE_HELPER,
            abi.encodePacked(
                type(OracleHelper).creationCode, abi.encode(out.contracts.resilientOracle, out.contracts.globalConfig)
            )
        );

        // 5) LiquidityHub (owned by GlobalConfig)
        string memory nativeAssetName = "Ethereum";
        string memory nativeAssetSymbol = "ETH";
        uint8 nativeAssetDecimals = 18;
        out.contracts.liquidityHub = payable(_deployCreate3(
                LIQUIDITY_HUB,
                abi.encodePacked(
                    type(LiquidityHub).creationCode,
                    abi.encode(
                        out.contracts.oracleHelper,
                        nativeAssetName,
                        nativeAssetSymbol,
                        nativeAssetDecimals,
                        out.contracts.globalConfig
                    )
                )
            ));

        // 6) Verifiers / managers
        uint256 signalExpiryInSeconds = 3600;
        address publicKeyAddress = deployer;

        address signalVerifier = _deployCreate3(
            SIGNAL_VERIFIER,
            abi.encodePacked(type(ECDSASignatureSignalVerifier).creationCode, abi.encode(publicKeyAddress))
        );

        out.contracts.signalManager = _deployCreate3(
            SIGNAL_MANAGER,
            abi.encodePacked(
                type(VRLSignalManager).creationCode,
                abi.encode(signalVerifier, signalExpiryInSeconds, out.contracts.globalConfig)
            )
        );

        out.contracts.settlementObserver = _deployCreate3(
            SETTLEMENT_OBSERVER,
            abi.encodePacked(type(VRLSettlementObserver).creationCode, abi.encode(out.contracts.globalConfig))
        );

        // 7) VTSOrchestrator (owned by GlobalConfig)
        out.contracts.vtsOrchestrator = _deployCreate3(
            VTS_ORCHESTRATOR,
            abi.encodePacked(
                type(VTSOrchestrator).creationCode,
                abi.encode(
                    config.poolManager,
                    out.contracts.signalManager,
                    out.contracts.oracleHelper,
                    out.contracts.liquidityHub,
                    out.contracts.settlementObserver,
                    out.contracts.globalConfig
                )
            )
        );

        // 8) MMPCommitmentDescriptor
        out.contracts.commitmentDescriptor =
            _deployCreate3(COMMITMENT_DESCRIPTOR, type(MMPCommitmentDescriptor).creationCode);

        // 9) MMPositionActionsImpl + MMQueueCustodian + MMPositionManager
        (out.contracts.actionsImpl, out.contracts.queueCustodian, out.contracts.mmPositionManager) = _deployMMStack(
            out.contracts.liquidityHub, out.contracts.vtsOrchestrator, out.contracts.commitmentDescriptor, deployer
        );

        // 10) DirectLPDeltaResolver
        out.contracts.directLPDeltaResolver = _deployCreate3(
            DIRECT_LP_DELTA_RESOLVER,
            abi.encodePacked(
                type(DirectLPDeltaResolver).creationCode, abi.encode(config.positionManager, out.contracts.liquidityHub)
            )
        );

        // 10) MarketFactory (owned by GlobalConfig)
        out.contracts.marketFactory = _deployCreate3(
            MARKET_FACTORY,
            abi.encodePacked(
                type(MarketFactory).creationCode,
                abi.encode(
                    config.poolManager,
                    out.contracts.liquidityHub,
                    out.contracts.oracleHelper,
                    out.contracts.vtsOrchestrator,
                    out.contracts.globalConfig
                )
            )
        );

        // 11) Enable MarketFactory in LiquidityHub (via GlobalConfig)
        GlobalConfig(out.contracts.globalConfig)
            .proxyCall(
                out.contracts.liquidityHub,
                abi.encodeWithSelector(LiquidityHub.setFactory.selector, out.contracts.marketFactory, true)
            );

        // 12) Deploy CoreHook via CREATE2 HookMiner
        out.contracts.coreHook = _deployCoreHook(out.contracts.marketFactory, out.contracts.vtsOrchestrator);

        // 13) Initialise MarketFactory (via GlobalConfig)
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


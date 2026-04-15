// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";

import {CoreHook} from "src/CoreHook.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {HookFlags} from "src/libraries/HookFlags.sol";
import {MMQueueCustodian} from "src/MMQueueCustodian.sol";
import {MMPositionManager} from "src/MMPositionManager.sol";
import {MMPositionActionsImpl} from "src/MMPositionActionsImpl.sol";
import {VRLSignalManager} from "src/VRLSignalManager.sol";
import {VRLSettlementObserver} from "src/VRLSettlementObserver.sol";
import {VTSOrchestrator} from "src/VTSOrchestrator.sol";
import {IVTSAdmin} from "src/interfaces/IVTSAdmin.sol";
import {OracleHelper} from "src/OracleHelper.sol";
import {MMPCommitmentDescriptor} from "src/MMPCommitmentDescriptor.sol";
import {LiquidityHub} from "src/LiquidityHub.sol";
import {GlobalConfig} from "src/GlobalConfig.sol";
import {ECDSASignatureSignalVerifier} from "src/verifiers/ECDSASignatureSignalVerifier.sol";
import {DirectLPDeltaResolver} from "src/DirectLPDeltaResolver.sol";
import {CanonicalVault} from "src/CanonicalVault.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {CREATE3Script} from "../CREATE3Script.sol";
import {NetworkConfig} from "../NetworkConfig.sol";

abstract contract DeployProtocolBase is CREATE3Script, NetworkConfig {
    // Contract names for CREATE3 salt generation
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
    string internal constant CANONICAL_VAULT = "CanonicalVault";
    string internal constant GLOBAL_CONFIG = "GlobalConfig";

    constructor() CREATE3Script("1") {}

    /// @dev Fail-fast checks for common misconfigured network constants / stale env RPC combinations.
    function _assertCorePeripheryConfig() internal view {
        require(config.poolManager.code.length > 0, "NetworkConfig: poolManager has no code on current RPC");
        require(config.positionManager.code.length > 0, "NetworkConfig: positionManager has no code on current RPC");
        require(config.permit2.code.length > 0, "NetworkConfig: permit2 has no code on current RPC");

        // Validate PositionManager wiring explicitly, so failures are clear instead of surfacing as opaque
        // "call to non-contract address" deep inside deployment logic.
        (bool okWeth, bytes memory wethData) = config.positionManager.staticcall(abi.encodeWithSignature("WETH9()"));
        require(okWeth && wethData.length >= 32, "NetworkConfig: PositionManager.WETH9() call failed");
        address weth9 = abi.decode(wethData, (address));
        require(weth9 != address(0), "NetworkConfig: PositionManager.WETH9() returned zero address");
        require(weth9.code.length > 0, "NetworkConfig: WETH9 has no code on current RPC");

        (bool okPermit2, bytes memory permit2Data) =
            config.positionManager.staticcall(abi.encodeWithSignature("permit2()"));
        require(okPermit2 && permit2Data.length >= 32, "NetworkConfig: PositionManager.permit2() call failed");
        address permit2FromPm = abi.decode(permit2Data, (address));
        require(permit2FromPm == config.permit2, "NetworkConfig: PositionManager.permit2() mismatch vs config");
    }

    function _deployCreate3(string memory name, bytes memory creationCode) internal returns (address deployed) {
        bytes32 salt = getCreate3ContractSalt(name);
        deployed = create3.deploy(salt, creationCode);

        address predicted = getCreate3Contract(name);
        require(deployed == predicted, string.concat(name, ": address mismatch"));
    }

    function _deployGlobalConfig(address deployer) internal returns (address) {
        return _deployCreate3(GLOBAL_CONFIG, abi.encodePacked(type(GlobalConfig).creationCode, abi.encode(deployer)));
    }

    function _deployOracleHelper(address resilientOracle, address globalConfig) internal returns (address) {
        return _deployCreate3(
            ORACLE_HELPER, abi.encodePacked(type(OracleHelper).creationCode, abi.encode(resilientOracle, globalConfig))
        );
    }

    function _deployLiquidityHub(
        address oracleHelper,
        string memory nativeAssetName,
        string memory nativeAssetSymbol,
        uint8 nativeAssetDecimals,
        address globalConfig
    ) internal returns (address payable) {
        address weth9 = address(PositionManager(payable(config.positionManager)).WETH9());
        return payable(_deployCreate3(
                LIQUIDITY_HUB,
                abi.encodePacked(
                    type(LiquidityHub).creationCode,
                    abi.encode(oracleHelper, nativeAssetName, nativeAssetSymbol, nativeAssetDecimals, weth9, globalConfig)
                )
            ));
    }

    function _deployVTSOrchestrator(address oracleHelper, address liquidityHub, address globalConfig)
        internal
        returns (address)
    {
        return _deployCreate3(
            VTS_ORCHESTRATOR,
            abi.encodePacked(
                type(VTSOrchestrator).creationCode,
                abi.encode(config.poolManager, oracleHelper, liquidityHub, globalConfig)
            )
        );
    }

    function _deploySignalVerifier(address publicKeyAddress) internal returns (address) {
        return _deployCreate3(
            SIGNAL_VERIFIER,
            abi.encodePacked(type(ECDSASignatureSignalVerifier).creationCode, abi.encode(publicKeyAddress))
        );
    }

    function _deploySignalManager(address signalVerifier, address submitter, address globalConfig)
        internal
        returns (address)
    {
        return _deployCreate3(
            SIGNAL_MANAGER,
            abi.encodePacked(type(VRLSignalManager).creationCode, abi.encode(signalVerifier, submitter, globalConfig))
        );
    }

    function _deploySettlementObserver(address submitter, address globalConfig) internal returns (address) {
        return _deployCreate3(
            SETTLEMENT_OBSERVER,
            abi.encodePacked(type(VRLSettlementObserver).creationCode, abi.encode(submitter, globalConfig))
        );
    }

    function _registerVRLProofHandlers(
        address globalConfig,
        address vtsOrchestrator,
        address signalManager,
        address settlementObserver
    ) internal {
        bytes memory callData = abi.encodeWithSelector(
            IVTSAdmin.registerVRLProofHandlers.selector, signalManager, settlementObserver
        );
        GlobalConfig(globalConfig).proxyCall(vtsOrchestrator, callData);
    }

    function _deployCommitmentDescriptor() internal returns (address) {
        return _deployCreate3(COMMITMENT_DESCRIPTOR, type(MMPCommitmentDescriptor).creationCode);
    }

    function _deployCanonicalVault(address liquidityHub, address marketFactory) internal returns (address) {
        return _deployCreate3(
            CANONICAL_VAULT,
            abi.encodePacked(
                type(CanonicalVault).creationCode, abi.encode(config.poolManager, liquidityHub, marketFactory)
            )
        );
    }

    function _deployMMStack(
        address marketFactory,
        address vtsOrchestrator,
        address commitmentDescriptor,
        address queueBinder,
        address canonicalVaultAddr
    ) internal returns (address actionsImpl, address queueCustodian, address mmPositionManager) {
        address weth9 = address(PositionManager(payable(config.positionManager)).WETH9());
        address permit2 = address(PositionManager(payable(config.positionManager)).permit2());

        actionsImpl = _deployCreate3(
            ACTIONS_IMPL,
            abi.encodePacked(
                type(MMPositionActionsImpl).creationCode,
                abi.encode(config.poolManager, marketFactory, vtsOrchestrator, canonicalVaultAddr)
            )
        );

        queueCustodian = _deployCreate3(
            QUEUE_CUSTODIAN, abi.encodePacked(type(MMQueueCustodian).creationCode, abi.encode(queueBinder))
        );

        mmPositionManager = _deployCreate3(
            MM_POSITION_MANAGER,
            abi.encodePacked(
                type(MMPositionManager).creationCode,
                abi.encode(
                    MMPositionManager.MMPositionManagerInit({
                        poolManager: IPoolManager(config.poolManager),
                        marketFactory: marketFactory,
                        vtsOrchestrator: vtsOrchestrator,
                        canonicalCustody: canonicalVaultAddr,
                        descriptor: commitmentDescriptor,
                        weth9: IWETH9(weth9),
                        permit2: IAllowanceTransfer(permit2),
                        actionsImpl: actionsImpl,
                        queueCustodianAddr: queueCustodian
                    })
                )
            )
        );

        MMQueueCustodian(queueCustodian).setPositionManager(mmPositionManager);
    }

    function _deployDirectLPDeltaResolver(address liquidityHub) internal returns (address) {
        return _deployCreate3(
            DIRECT_LP_DELTA_RESOLVER,
            abi.encodePacked(type(DirectLPDeltaResolver).creationCode, abi.encode(config.positionManager, liquidityHub))
        );
    }

    function _deployMarketFactory(
        address liquidityHub,
        address oracleHelper,
        address vtsOrchestrator,
        address globalConfig
    ) internal returns (address) {
        return _deployCreate3(
            MARKET_FACTORY,
            abi.encodePacked(
                type(MarketFactory).creationCode,
                abi.encode(config.poolManager, liquidityHub, oracleHelper, vtsOrchestrator, globalConfig)
            )
        );
    }

    function _enableFactoryInLiquidityHub(address globalConfig, address liquidityHub, address marketFactory) internal {
        GlobalConfig(globalConfig)
            .proxyCall(liquidityHub, abi.encodeWithSelector(LiquidityHub.setFactory.selector, marketFactory, true));
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
        address canonicalVaultAddr,
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
                marketFactory,
                abi.encodeWithSelector(MarketFactory.initialise.selector, canonicalVaultAddr, coreHook, initialBounds)
            );
    }
}

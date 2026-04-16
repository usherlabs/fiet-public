// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * E2E: Deploy (standalone)
 *
 * Deploys the full stack (libraries + contracts) and prints all deployed addresses.
 *
 * Usage:
 * FOUNDRY_PROFILE=deploy forge script script/e2e/Deploy.s.sol:DeployE2E --rpc-url $RPC --broadcast -vvv
 *
 * Env:
 * - NETWORK
 * - PRIVATE_KEY
 */

import {console} from "forge-std/Script.sol";
import {DeployFullStackBase} from "./base/deploy/DeployFullStackBase.sol";

contract DeployE2E is DeployFullStackBase {
    function run() external {
        FullStack memory stack = _deployAll();

        console.log("=== E2E Deploy Results ===");

        console.log("--- Libraries ---");
        console.log("VTSPositionLib:", stack.libs.vtsPositionLib);
        console.log("VTSSwapLib:", stack.libs.vtsSwapLib);
        console.log("VTSCommitLib:", stack.libs.vtsCommitLib);
        console.log("VTSPositionMMOpsLib:", stack.libs.vtsPositionMMOpsLib);
        console.log("VTSLifecycleLinkedLib:", stack.libs.vtsLifecycleLinkedLib);
        console.log("VTSFeeLinkedLib:", stack.libs.vtsFeeLinkedLib);
        console.log("LCCFactoryLinkedLib:", stack.libs.lccFactoryLinkedLib);
        console.log("LiquidityHubLinkedLib:", stack.libs.liquidityHubLinkedLib);

        console.log("--- Contracts ---");
        console.log("GlobalConfig:", stack.contracts.globalConfig);
        console.log("ResilientOracle:", stack.contracts.resilientOracle);
        console.log("MainOracle:", stack.contracts.mainOracle);
        console.log("OracleHelper:", stack.contracts.oracleHelper);
        console.log("LiquidityHub:", stack.contracts.liquidityHub);
        console.log("SignalManager:", stack.contracts.signalManager);
        console.log("SettlementObserver:", stack.contracts.settlementObserver);
        console.log("VTSOrchestrator:", stack.contracts.vtsOrchestrator);
        console.log("CommitmentDescriptor:", stack.contracts.commitmentDescriptor);
        console.log("ActionsImpl:", stack.contracts.actionsImpl);
        console.log("MMPositionManager:", stack.contracts.mmPositionManager);
        console.log("MMQueueCustodian:", stack.contracts.queueCustodian);
        console.log("DirectLPDeltaResolver:", stack.contracts.directLPDeltaResolver);
        console.log("MarketFactory:", stack.contracts.marketFactory);
        console.log("CoreHook:", stack.contracts.coreHook);
    }
}


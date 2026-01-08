// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {CREATE3Script, ICREATE3Factory} from "../base/CREATE3Script.sol";
import {NetworkConfig} from "../base/NetworkConfig.sol";

// Libraries to deploy
import {VTSPositionLib} from "src/libraries/VTSPositionLib.sol";
import {VTSSwapLib} from "src/libraries/VTSSwapLib.sol";
import {VTSCommitLib} from "src/libraries/VTSCommitLib.sol";
import {LCCFactoryLinkedLib} from "src/libraries/LCCFactoryLib.sol";
import {VTSFeeLinkedLib} from "src/libraries/VTSFeeLib.sol";

/**
 * @title DeployLibraries
 * @notice Deploys linked libraries using CREATE3 for deterministic addresses across chains
 * @dev Libraries with public/external functions must be deployed separately and linked.
 *      This script deploys:
 *      - VTSPositionLib (used by VTSOrchestrator)
 *      - VTSSwapLib (used by VTSOrchestrator)
 *      - VTSCommitLib (used by VTSOrchestrator, VTSPositionLib)
 *      - VTSFeeLinkedLib (used by VTSPositionLib)
 *      - LCCFactoryLinkedLib (used by LiquidityHub)
 *
 *      Note: VTSFeeLib (internal-only), LiquidityHubLib, and LCCFactoryLib only have internal functions
 *      and are inlined at compile time, so they don't require separate deployment.
 *
 * Deployment Order:
 * 1. Deploy LCCFactoryLinkedLib (no dependencies on VTS libs)
 * 2. Deploy VTSFeeLinkedLib (no dependencies on other VTS libs)
 * 3. Deploy VTSCommitLib (no dependencies on other VTS libs)
 * 4. Deploy VTSSwapLib (no dependencies on other VTS libs)
 * 5. Deploy VTSPositionLib (uses VTSCommitLib, VTSFeeLinkedLib)
 *
 * Usage:
 *   PRIVATE_KEY=<key> forge script script/deploy/DeployLibraries.s.sol \
 *     --rpc-url $RPC_URL --broadcast --verify
 *
 * After deployment, update foundry.toml with library addresses:
 *   [profile.default]
 *   libraries = [
 *     "src/libraries/VTSPositionLib.sol:VTSPositionLib:<address>",
 *     "src/libraries/VTSSwapLib.sol:VTSSwapLib:<address>",
 *     "src/libraries/VTSCommitLib.sol:VTSCommitLib:<address>",
 *     "src/libraries/VTSFeeLib.sol:VTSFeeLinkedLib:<address>",
 *     "src/libraries/LCCFactoryLib.sol:LCCFactoryLinkedLib:<address>",
 *   ]
 */
contract DeployLibraries is CREATE3Script, NetworkConfig {
    // Deployed library addresses
    address public vtsPositionLib;
    address public vtsSwapLib;
    address public vtsCommitLib;
    address public vtsFeeLinkedLib;
    address public lccFactoryLinkedLib;

    // Library names for salt generation
    string constant VTS_POSITION_LIB = "VTSPositionLib";
    string constant VTS_SWAP_LIB = "VTSSwapLib";
    string constant VTS_COMMIT_LIB = "VTSCommitLib";
    string constant LCC_FACTORY_LINKED_LIB = "LCCFactoryLinkedLib";
    string constant VTS_FEE_LINKED_LIB = "VTSFeeLinkedLib";

    constructor() CREATE3Script("1") {}

    function run() external {
        uint256 deployerPrivateKey = _getDeployerPrivateKey();

        // Initialise network configuration
        _initNetwork();

        console.log("Starting library deployment on %s...", networkName);
        console.log("CREATE3 Factory:", address(create3));

        // Predict addresses before deployment
        _logPredictedAddresses();

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy LCCFactoryLinkedLib (no dependencies)
        console.log("\n=== Step 1: Deploying LCCFactoryLinkedLib ===");
        lccFactoryLinkedLib = _deployLibrary(LCC_FACTORY_LINKED_LIB, type(LCCFactoryLinkedLib).creationCode);
        console.log("LCCFactoryLinkedLib deployed at:", lccFactoryLinkedLib);

        // Step 2: Deploy VTSFeeLinkedLib (no dependencies)
        console.log("\n=== Step 2: Deploying VTSFeeLinkedLib ===");
        vtsFeeLinkedLib = _deployLibrary(VTS_FEE_LINKED_LIB, type(VTSFeeLinkedLib).creationCode);
        console.log("VTSFeeLinkedLib deployed at:", vtsFeeLinkedLib);

        // Step 3: Deploy VTSCommitLib (no dependencies)
        console.log("\n=== Step 3: Deploying VTSCommitLib ===");
        vtsCommitLib = _deployLibrary(VTS_COMMIT_LIB, type(VTSCommitLib).creationCode);
        console.log("VTSCommitLib deployed at:", vtsCommitLib);

        // Step 4: Deploy VTSSwapLib (no dependencies)
        console.log("\n=== Step 4: Deploying VTSSwapLib ===");
        vtsSwapLib = _deployLibrary(VTS_SWAP_LIB, type(VTSSwapLib).creationCode);
        console.log("VTSSwapLib deployed at:", vtsSwapLib);

        // Step 5: Deploy VTSPositionLib
        // Note: VTSPositionLib imports VTSCommitLib and VTSFeeLinkedLib
        // The compiler will handle the linking for VTSCommitLib and VTSFeeLinkedLib if they're already deployed
        console.log("\n=== Step 5: Deploying VTSPositionLib ===");
        vtsPositionLib = _deployLibrary(VTS_POSITION_LIB, type(VTSPositionLib).creationCode);
        console.log("VTSPositionLib deployed at:", vtsPositionLib);

        vm.stopBroadcast();

        // Write deployment addresses and foundry.toml config
        _writeDeploymentAddresses();
        _logFoundryTomlConfig();

        console.log("\n=== Library Deployment Complete ===");
    }

    /**
     * @dev Deploys a library using CREATE3
     * @param name The library name for salt generation
     * @param creationCode The library creation bytecode
     * @return deployed The deployed library address
     */
    function _deployLibrary(string memory name, bytes memory creationCode) internal returns (address deployed) {
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
        console.log("\n=== Predicted Addresses ===");
        console.log("LCCFactoryLinkedLib:", getCreate3Contract(LCC_FACTORY_LINKED_LIB));
        console.log("VTSFeeLinkedLib:", getCreate3Contract(VTS_FEE_LINKED_LIB));
        console.log("VTSCommitLib:", getCreate3Contract(VTS_COMMIT_LIB));
        console.log("VTSSwapLib:", getCreate3Contract(VTS_SWAP_LIB));
        console.log("VTSPositionLib:", getCreate3Contract(VTS_POSITION_LIB));
    }

    /**
     * @dev Writes deployment addresses to JSON file
     */
    function _writeDeploymentAddresses() internal {
        _setFilenameWithSuffix(networkName, "_libraries");
        writeAddress("vtsPositionLib", vtsPositionLib);
        writeAddress("vtsSwapLib", vtsSwapLib);
        writeAddress("vtsCommitLib", vtsCommitLib);
        writeAddress("vtsFeeLinkedLib", vtsFeeLinkedLib);
        writeAddress("lccFactoryLinkedLib", lccFactoryLinkedLib);

        console.log("\nDeployment addresses written to deployments/%s_libraries_deployments.json", networkName);
    }

    /**
     * @dev Logs the foundry.toml configuration to add for library linking
     */
    function _logFoundryTomlConfig() internal view {
        console.log("\n=== Add to foundry.toml [profile.default] ===");
        console.log("libraries = [");
        console.log('  "src/libraries/VTSPositionLib.sol:VTSPositionLib:%s",', vtsPositionLib);
        console.log('  "src/libraries/VTSSwapLib.sol:VTSSwapLib:%s",', vtsSwapLib);
        console.log('  "src/libraries/VTSCommitLib.sol:VTSCommitLib:%s",', vtsCommitLib);
        console.log('  "src/libraries/VTSFeeLib.sol:VTSFeeLinkedLib:%s",', vtsFeeLinkedLib);
        console.log('  "src/libraries/LCCFactoryLib.sol:LCCFactoryLinkedLib:%s",', lccFactoryLinkedLib);
        console.log("]");
    }

    /**
     * @dev Returns predicted library addresses for other scripts to use
     */
    function getLibraryAddresses()
        external
        view
        returns (address positionLib, address swapLib, address commitLib, address feeLinkedLib, address lccFactoryLib)
    {
        positionLib = getCreate3Contract(VTS_POSITION_LIB);
        swapLib = getCreate3Contract(VTS_SWAP_LIB);
        commitLib = getCreate3Contract(VTS_COMMIT_LIB);
        feeLinkedLib = getCreate3Contract(VTS_FEE_LINKED_LIB);
        lccFactoryLib = getCreate3Contract(LCC_FACTORY_LINKED_LIB);
    }
}

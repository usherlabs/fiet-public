// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * Admin: Make GlobalConfig the owner of ResilientOracle
 *
 * This script performs the 2-step ownership handover commonly used by Venus oracle contracts:
 * 0) (Optional but recommended) Make GlobalConfig the Venus ACM admin (DEFAULT_ADMIN_ROLE) and revoke deployer admin
 * 1) `ResilientOracle.transferOwnership(GlobalConfig)`
 * 2) `GlobalConfig.proxyCall(ResilientOracle, acceptOwnership())`  (so msg.sender == GlobalConfig)
 *
 * Run:
 * - `just admin-oracle-transfer-to-globalconfig`
 *
 * Env:
 * - PRIVATE_KEY: admin EOA (must be current ResilientOracle owner AND GlobalConfig owner)
 * - NETWORK: deployments/<network>_deployments.json selector (for reading GlobalConfig)
 * - RESILIENT_ORACLE_ADDRESS: ResilientOracle proxy address
 *
 * Optional env:
 * - SKIP_ACM_ADMIN_TRANSFER: set to "true" to skip Step 0 entirely
 * - REQUIRE_ACM_ADMIN_TRANSFER: set to "true" to make Step 0 failures revert (default: best-effort)
 */

import {console} from "forge-std/Script.sol";
import {AdminBase} from "./AdminBase.sol";

interface IOwnable2StepLike {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

interface IResilientOracleACMView {
    function accessControlManager() external view returns (address);
}

interface IAccessControlLike {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
}

contract ResilientOracleTransferToGlobalConfigScript is AdminBase {
    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address oracle = vm.envAddress("RESILIENT_ORACLE_ADDRESS");

        _loadAdminAddresses();

        address oracleOwner = IOwnable2StepLike(oracle).owner();
        address oraclePending = address(0);
        // Best-effort: pendingOwner() might not exist on non-2step implementations.
        try IOwnable2StepLike(oracle).pendingOwner() returns (address p) {
            oraclePending = p;
        } catch {}

        console.log("NETWORK:", networkName);
        console.log("ResilientOracle:", oracle);
        console.log("ResilientOracle owner:", oracleOwner);
        console.log("ResilientOracle pendingOwner:", oraclePending);
        console.log("GlobalConfig:", globalConfig);

        // Step 0: (Optional but recommended) transfer Venus ACM admin to GlobalConfig, revoke deployer admin.
        // Note: ResilientOracle uses ACM to gate many admin operations via `_checkAccessAllowed(...)`.
        address acm = IResilientOracleACMView(oracle).accessControlManager();
        address oldAdmin = vm.addr(pk);

        bytes32 adminRole = IAccessControlLike(acm).DEFAULT_ADMIN_ROLE();
        console.log("AccessControlManager:", acm);
        console.log("ACM DEFAULT_ADMIN_ROLE:", uint256(adminRole));
        console.log("ACM OLD_ADMIN:", oldAdmin);

        vm.startBroadcast(pk);

        bool skipAcmTransfer = vm.envOr("SKIP_ACM_ADMIN_TRANSFER", false);
        bool requireAcmTransfer = vm.envOr("REQUIRE_ACM_ADMIN_TRANSFER", false);
        if (skipAcmTransfer) {
            console.log("NOTE: skipping ACM admin transfer (SKIP_ACM_ADMIN_TRANSFER=true)");
        } else {
            bool gcHasAdmin = IAccessControlLike(acm).hasRole(adminRole, globalConfig);
            bool oldHasAdmin = oldAdmin != address(0) && IAccessControlLike(acm).hasRole(adminRole, oldAdmin);
            console.log("ACM: GlobalConfig has DEFAULT_ADMIN_ROLE:", gcHasAdmin);
            console.log("ACM: OLD_ADMIN has DEFAULT_ADMIN_ROLE:", oldHasAdmin);

            // If GlobalConfig isn't yet admin, the current tx sender must be an ACM admin to grant it.
            if (!gcHasAdmin) {
                if (oldHasAdmin) {
                    IAccessControlLike(acm).grantRole(adminRole, globalConfig);
                    console.log("OK: granted ACM DEFAULT_ADMIN_ROLE to GlobalConfig");
                    gcHasAdmin = true;
                } else {
                    console.log("WARN: cannot grant ACM admin to GlobalConfig (sender is not ACM admin)");
                    if (requireAcmTransfer) revert("ACM: cannot grant DEFAULT_ADMIN_ROLE to GlobalConfig");
                }
            } else {
                console.log("SKIP: GlobalConfig already has ACM DEFAULT_ADMIN_ROLE");
            }

            // If GlobalConfig is admin, revoke OLD_ADMIN via GlobalConfig.proxyCall so we don't depend on the EOA retaining admin.
            if (gcHasAdmin && oldAdmin != address(0) && oldAdmin != globalConfig) {
                if (IAccessControlLike(acm).hasRole(adminRole, oldAdmin)) {
                    _proxyCall(acm, abi.encodeWithSignature("revokeRole(bytes32,address)", adminRole, oldAdmin));
                    console.log("OK: revoked ACM DEFAULT_ADMIN_ROLE from OLD_ADMIN (via GlobalConfig.proxyCall)");
                } else {
                    console.log("SKIP: OLD_ADMIN does not have ACM DEFAULT_ADMIN_ROLE");
                }
            } else if (gcHasAdmin) {
                console.log("SKIP: OLD_ADMIN is zero or GlobalConfig");
            }
        }

        // Step 1: initiate transfer (must be called by current oracle owner).
        if (oracleOwner != globalConfig) {
            IOwnable2StepLike(oracle).transferOwnership(globalConfig);
            console.log("OK: transferOwnership -> GlobalConfig (initiated)");
        } else {
            console.log("SKIP: oracle already owned by GlobalConfig");
        }

        // Step 2: accept ownership (must be called by pending owner; we route via GlobalConfig.proxyCall).
        // If the oracle uses 1-step Ownable, acceptOwnership() may not exist; in that case this will revert.
        // For Venus oracles (Ownable2StepUpgradeable), this is the expected path.
        _proxyCall(oracle, abi.encodeWithSignature("acceptOwnership()"));
        console.log("OK: acceptOwnership (via GlobalConfig.proxyCall)");

        vm.stopBroadcast();

        // Post-condition: GlobalConfig must be the final owner (fail loudly if not).
        address finalOwner = IOwnable2StepLike(oracle).owner();
        console.log("ResilientOracle final owner:", finalOwner);
        require(finalOwner == globalConfig, "ResilientOracleOwnership: owner != GlobalConfig");
    }
}


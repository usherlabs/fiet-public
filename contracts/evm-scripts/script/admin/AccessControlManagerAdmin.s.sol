// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * Admin: Transfer Venus AccessControlManager DEFAULT_ADMIN_ROLE to GlobalConfig
 *
 * Venus ACM uses OpenZeppelin `AccessControl` (not Ownable). The "admin" of the ACM is the holder(s)
 * of `DEFAULT_ADMIN_ROLE` (bytes32(0)), which can grant/revoke any roles, including granular call permissions.
 *
 * This script:
 * 1) grants DEFAULT_ADMIN_ROLE to GlobalConfig
 * 2) optionally revokes DEFAULT_ADMIN_ROLE from an OLD_ADMIN address (explicit env var)
 *
 * Run:
 * - `just admin-acm-transfer-admin-to-globalconfig`
 *
 * Env:
 * - PRIVATE_KEY: current ACM admin (must have DEFAULT_ADMIN_ROLE)
 * - ACCESS_CONTROL_MANAGER: ACM contract address
 *   - If not set, you may instead provide RESILIENT_ORACLE_ADDRESS and this script will resolve the ACM via
 *     `ResilientOracle.accessControlManager()`.
 * - RESILIENT_ORACLE_ADDRESS: (optional) ResilientOracle proxy address (used only to resolve ACM)
 * - OLD_ADMIN: (optional) address to revoke DEFAULT_ADMIN_ROLE from (e.g. deployer EOA)
 */

import {console} from "forge-std/Script.sol";
import {AdminBase} from "./AdminBase.sol";

interface IAccessControlLike {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
}

interface IResilientOracleACMView {
    function accessControlManager() external view returns (address);
}

contract AccessControlManagerTransferAdminToGlobalConfigScript is AdminBase {
    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address acm;
        // Prefer resolving the ACM from the ResilientOracle to avoid acting on a stale/mismatched ACM address.
        if (vm.envExists("RESILIENT_ORACLE_ADDRESS")) {
            address oracle = vm.envAddress("RESILIENT_ORACLE_ADDRESS");
            address acmFromOracle = IResilientOracleACMView(oracle).accessControlManager();
            if (vm.envExists("ACCESS_CONTROL_MANAGER")) {
                address acmFromEnv = vm.envAddress("ACCESS_CONTROL_MANAGER");
                require(acmFromEnv == acmFromOracle, "ACM: ACCESS_CONTROL_MANAGER != oracle.accessControlManager()");
            }
            acm = acmFromOracle;
        } else if (vm.envExists("ACCESS_CONTROL_MANAGER")) {
            acm = vm.envAddress("ACCESS_CONTROL_MANAGER");
        } else {
            revert("ACM: set RESILIENT_ORACLE_ADDRESS (preferred) or ACCESS_CONTROL_MANAGER");
        }

        _loadAdminAddresses();

        bytes32 adminRole = IAccessControlLike(acm).DEFAULT_ADMIN_ROLE();
        address oldAdmin = vm.envOr("OLD_ADMIN", address(0));

        console.log("NETWORK:", networkName);
        console.log("AccessControlManager:", acm);
        console.log("GlobalConfig:", globalConfig);
        console.logBytes32(adminRole);
        console.log("OLD_ADMIN:", oldAdmin);

        bool gcAlready = IAccessControlLike(acm).hasRole(adminRole, globalConfig);
        bool oldAlready = oldAdmin != address(0) && IAccessControlLike(acm).hasRole(adminRole, oldAdmin);
        console.log("GlobalConfig has DEFAULT_ADMIN_ROLE:", gcAlready);
        if (oldAdmin != address(0)) console.log("OLD_ADMIN has DEFAULT_ADMIN_ROLE:", oldAlready);

        vm.startBroadcast(pk);

        if (!gcAlready) {
            IAccessControlLike(acm).grantRole(adminRole, globalConfig);
            console.log("OK: granted DEFAULT_ADMIN_ROLE to GlobalConfig");
        } else {
            console.log("SKIP: GlobalConfig already has DEFAULT_ADMIN_ROLE");
        }

        // Safety: only revoke if explicitly provided, and never revoke GlobalConfig.
        if (oldAdmin != address(0)) {
            require(oldAdmin != globalConfig, "ACM: OLD_ADMIN must not be GlobalConfig");

            // Re-check after grant to avoid bricking by revoking the only admin.
            require(IAccessControlLike(acm).hasRole(adminRole, globalConfig), "ACM: GlobalConfig not admin");

            if (IAccessControlLike(acm).hasRole(adminRole, oldAdmin)) {
                IAccessControlLike(acm).revokeRole(adminRole, oldAdmin);
                console.log("OK: revoked DEFAULT_ADMIN_ROLE from OLD_ADMIN");
            } else {
                console.log("SKIP: OLD_ADMIN does not have DEFAULT_ADMIN_ROLE");
            }
        } else {
            console.log("NOTE: OLD_ADMIN not set; not revoking anyone");
        }

        vm.stopBroadcast();
    }
}


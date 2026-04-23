// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * Admin: Give Venus AccessControlManager call permission for target contract
 *
 * Venus `ResilientOracle` gates most admin operations via `_checkAccessAllowed("<sig>")`,
 * which is enforced by the Venus `AccessControlManager` (ACM). Making `GlobalConfig` the
 * oracle `owner()` is useful, but it does NOT automatically grant these ACM permissions.
 *
 * This script is a generic helper around:
 * - `AccessControlManager.giveCallPermission(targetContract, functionSig, accountToPermit)`
 *
 * IMPORTANT:
 * - The transaction sender must be an ACM admin (i.e. have the admin role for the permission role;
 *   by default this is `DEFAULT_ADMIN_ROLE`). Otherwise `giveCallPermission` will revert internally
 *   when it calls `grantRole(...)`.
 * - If you've already transferred ACM admin to `GlobalConfig` (recommended), you may prefer to route
 *   this call via `GlobalConfig.proxyCall(...)` so the ACM sees `msg.sender == GlobalConfig`.
 *
 * Run:
 * - `just admin-oracle-acm-give-call-permission`
 *
 * Env:
 * - PRIVATE_KEY: the admin EOA (must be allowed to administer ACM, OR be the owner of GlobalConfig if proxying)
 * - RESILIENT_ORACLE_ADDRESS: ResilientOracle proxy address (used to resolve ACM); if unset, read from
 *   `deployments/oracle_deployments/<ORACLE_DEPLOYMENT_NETWORK|mapped NETWORK>/addresses.json`
 * - TARGET_ADDRESS: contract to permit (e.g. MainOracle, BoundValidator, ResilientOracle)
 *
 * - FUNCTION_SIG: the exact signature string used by `_checkAccessAllowed`, e.g. "pause()"
 * - ACCOUNT_TO_PERMIT: the account that should be allowed to call that signature
 */

import {console} from "forge-std/Script.sol";
import {AdminBase} from "./AdminBase.sol";

interface IResilientOracleACMView {
    function accessControlManager() external view returns (address);
}

interface IAccessControlManagerLike {
    function giveCallPermission(address contractAddress, string calldata functionSig, address accountToPermit) external;
    function hasPermission(address account, address contractAddress, string calldata functionSig)
        external
        view
        returns (bool);
}

abstract contract ResilientOracleACMBase is AdminBase {
    function _resolveAcm(address oracle) internal view returns (address acm) {
        acm = IResilientOracleACMView(oracle).accessControlManager();
    }

    function _giveCallPermission(address acm, address targetContract, string memory functionSig, address account)
        internal
    {
        bool already = IAccessControlManagerLike(acm).hasPermission(account, targetContract, functionSig);
        if (already) {
            console.log("SKIP (already allowed):", functionSig);
            return;
        }

        _proxyCall(
            acm,
            abi.encodeWithSignature("giveCallPermission(address,string,address)", targetContract, functionSig, account)
        );
        bool nowAllowed = IAccessControlManagerLike(acm).hasPermission(account, targetContract, functionSig);
        console.log("Permission now allowed:", nowAllowed);
        require(nowAllowed, "ResilientOracleACM: permission not granted");
        console.log("OK (granted):", functionSig);
    }
}

contract ResilientOracleACMGiveCallPermissionScript is ResilientOracleACMBase {
    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address target = vm.envAddress("TARGET_ADDRESS");
        string memory functionSig = vm.envString("FUNCTION_SIG");
        address account = vm.envAddress("ACCOUNT_TO_PERMIT");

        _loadAdminAddresses();

        address oracle;
        if (vm.envExists("RESILIENT_ORACLE_ADDRESS")) {
            oracle = vm.envAddress("RESILIENT_ORACLE_ADDRESS");
        } else {
            oracle = _readOracleAddressBookKey(_oracleDeploymentNamespace(), "ResilientOracle_Proxy");
        }
        require(oracle != address(0), "ResilientOracleACM: missing RESILIENT_ORACLE_ADDRESS and address book entry");

        address acm = _resolveAcm(oracle);

        console.log("NETWORK:", networkName);
        console.log("ResilientOracle:", oracle);
        console.log("Target:", target);
        console.log("AccessControlManager:", acm);
        console.log("FUNCTION_SIG:", functionSig);
        console.log("ACCOUNT_TO_PERMIT:", account);

        vm.startBroadcast(pk);
        _giveCallPermission(acm, target, functionSig, account);
        vm.stopBroadcast();
    }
}


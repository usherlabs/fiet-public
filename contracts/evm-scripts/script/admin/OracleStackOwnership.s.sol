// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {AdminBase} from "./AdminBase.sol";

interface IOwnableLike {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface IOwnable2StepLike is IOwnableLike {
    function pendingOwner() external view returns (address);
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

/**
 * Admin: Transfer Venus oracle ownership/admin surfaces to GlobalConfig
 *
 * This script handles:
 * - ResilientOracle ownership handoff to GlobalConfig
 * - optional ACM DEFAULT_ADMIN_ROLE handoff to GlobalConfig
 * - optional ownership handoff for:
 * - BoundValidator
 * - Main oracle (ChainlinkOracle or SequencerChainlinkOracle proxy)
 * - DefaultProxyAdmin (upgrade admin owner)
 *
 * Run:
 * - `just admin-oracle-transfer-to-globalconfig`
 * - `just admin-oracle-transfer-stack-to-globalconfig`
 *
 * Env:
 * - PRIVATE_KEY: owner EOA (or an account that can initiate transferOwnership)
 * - NETWORK: deployments/<network>_deployments.json selector (for loading GlobalConfig)
 * - RESILIENT_ORACLE_ADDRESS: optional but recommended
 * - BOUND_VALIDATOR_ADDRESS: optional
 * - MAIN_ORACLE_ADDRESS: optional
 * - DEFAULT_PROXY_ADMIN_ADDRESS: optional
 *
 * Optional env:
 * - SKIP_ACM_ADMIN_TRANSFER: set to "true" to skip ACM admin migration
 * - REQUIRE_ACM_ADMIN_TRANSFER: set to "true" to fail when ACM admin migration cannot be completed
 */
contract OracleStackTransferToGlobalConfigScript is AdminBase {
    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address signer = vm.addr(pk);
        address resilientOracle = vm.envOr("RESILIENT_ORACLE_ADDRESS", address(0));
        address boundValidator = vm.envOr("BOUND_VALIDATOR_ADDRESS", address(0));
        address mainOracle = vm.envOr("MAIN_ORACLE_ADDRESS", address(0));
        address defaultProxyAdmin = vm.envOr("DEFAULT_PROXY_ADMIN_ADDRESS", address(0));

        _loadAdminAddresses();

        require(
            resilientOracle != address(0) || boundValidator != address(0) || mainOracle != address(0)
                || defaultProxyAdmin != address(0),
            "set at least one target address"
        );

        console.log("NETWORK:", networkName);
        console.log("GlobalConfig:", globalConfig);
        console.log("Signer:", signer);

        vm.startBroadcast(pk);
        if (resilientOracle != address(0)) {
            _handoffResilientOracleAndAcm(resilientOracle, signer);
        } else {
            console.log("SKIP: ResilientOracle (address not provided)");
        }
        _handoff(boundValidator, "BoundValidator", signer);
        _handoff(mainOracle, "MainOracle", signer);
        _handoff(defaultProxyAdmin, "DefaultProxyAdmin", signer);
        vm.stopBroadcast();
    }

    function _handoffResilientOracleAndAcm(address oracle, address signer) internal {
        address oracleOwner = IOwnableLike(oracle).owner();
        address oraclePending = address(0);
        try IOwnable2StepLike(oracle).pendingOwner() returns (address p) {
            oraclePending = p;
        } catch {}

        console.log("ResilientOracle:", oracle);
        console.log("ResilientOracle owner:", oracleOwner);
        console.log("ResilientOracle pendingOwner:", oraclePending);

        bool skipAcmTransfer = vm.envOr("SKIP_ACM_ADMIN_TRANSFER", false);
        bool requireAcmTransfer = vm.envOr("REQUIRE_ACM_ADMIN_TRANSFER", false);
        if (skipAcmTransfer) {
            console.log("NOTE: skipping ACM admin transfer (SKIP_ACM_ADMIN_TRANSFER=true)");
        } else {
            _handoffAcmAdmin(oracle, signer, requireAcmTransfer);
        }

        _handoff(oracle, "ResilientOracle", signer);
    }

    function _handoffAcmAdmin(address oracle, address signer, bool requireAcmTransfer) internal {
        address acm = IResilientOracleACMView(oracle).accessControlManager();
        bytes32 adminRole = IAccessControlLike(acm).DEFAULT_ADMIN_ROLE();
        bool gcHasAdmin = IAccessControlLike(acm).hasRole(adminRole, globalConfig);
        bool signerHasAdmin = signer != address(0) && IAccessControlLike(acm).hasRole(adminRole, signer);

        console.log("AccessControlManager:", acm);
        console.log("ACM DEFAULT_ADMIN_ROLE:", uint256(adminRole));
        console.log("ACM signer has DEFAULT_ADMIN_ROLE:", signerHasAdmin);
        console.log("ACM GlobalConfig has DEFAULT_ADMIN_ROLE:", gcHasAdmin);

        if (!gcHasAdmin) {
            if (signerHasAdmin) {
                IAccessControlLike(acm).grantRole(adminRole, globalConfig);
                console.log("OK: granted ACM DEFAULT_ADMIN_ROLE to GlobalConfig");
                gcHasAdmin = true;
            } else {
                console.log("WARN: cannot grant ACM admin to GlobalConfig (signer is not ACM admin)");
                if (requireAcmTransfer) revert("ACM: cannot grant DEFAULT_ADMIN_ROLE to GlobalConfig");
            }
        }

        if (gcHasAdmin && signer != address(0) && signer != globalConfig) {
            if (IAccessControlLike(acm).hasRole(adminRole, signer)) {
                _proxyCall(acm, abi.encodeWithSignature("revokeRole(bytes32,address)", adminRole, signer));
                console.log("OK: revoked ACM DEFAULT_ADMIN_ROLE from signer (via GlobalConfig.proxyCall)");
            }
        }
    }

    function _handoff(address target, string memory label, address signer) internal {
        if (target == address(0)) {
            console.log("SKIP:", label, "(address not provided)");
            return;
        }

        address currentOwner = IOwnableLike(target).owner();
        console.log(label, "target:", target);
        console.log(label, "owner:", currentOwner);

        if (currentOwner == globalConfig) {
            console.log("SKIP:", label, "already owned by GlobalConfig");
            return;
        }

        if (currentOwner == signer) {
            IOwnableLike(target).transferOwnership(globalConfig);
            console.log("OK:", label, "transferOwnership -> GlobalConfig (initiated)");
        } else {
            console.log("NOTE:", label, "owner is not signer; skipping transferOwnership");
        }

        address pending = address(0);
        try IOwnable2StepLike(target).pendingOwner() returns (address p) {
            pending = p;
        } catch {}

        if (pending == globalConfig) {
            _proxyCall(target, abi.encodeWithSignature("acceptOwnership()"));
            console.log("OK:", label, "acceptOwnership via GlobalConfig.proxyCall");
        }

        address finalOwner = IOwnableLike(target).owner();
        require(finalOwner == globalConfig, string.concat(label, ": owner != GlobalConfig"));
        console.log("OK:", label, "final owner is GlobalConfig");
    }
}

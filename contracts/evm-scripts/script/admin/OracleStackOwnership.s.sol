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
 * - DefaultProxyAdmin (upgrade admin contract; GlobalConfig becomes its owner)
 *
 * Run:
 * - `just admin-oracle-transfer-to-globalconfig`
 * - `just admin-oracle-transfer-stack-to-globalconfig`
 *
 * Env:
 * - PRIVATE_KEY: owner EOA (or an account that can initiate transferOwnership)
 * - NETWORK: deployments/<network>_deployments.json selector (for loading GlobalConfig)
 * - ORACLE_DEPLOYMENT_NETWORK: optional override for `deployments/oracle_deployments/<name>/addresses.json`
 * - RESILIENT_ORACLE_ADDRESS: optional; defaults from oracle address book
 * - BOUND_VALIDATOR_ADDRESS: optional; defaults from oracle address book
 * - MAIN_ORACLE_ADDRESS: optional; defaults from oracle address book
 * - ORACLE_PROXY_ADMIN_ADDRESS: optional; current oracle `DefaultProxyAdmin` contract (not GlobalConfig).
 *   Legacy: `DEFAULT_PROXY_ADMIN_ADDRESS` is still accepted if `ORACLE_PROXY_ADMIN_ADDRESS` is unset.
 *
 * Optional env:
 * - SKIP_ACM_ADMIN_TRANSFER: set to "true" to skip ACM admin migration
 * - REQUIRE_ACM_ADMIN_TRANSFER: set to "true" to fail when ACM admin migration cannot be completed
 */
contract OracleStackTransferToGlobalConfigScript is AdminBase {
    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address signer = vm.addr(pk);

        _loadAdminAddresses();

        string memory oracleNs = _oracleDeploymentNamespace();
        console.log("ORACLE_DEPLOYMENT_NAMESPACE (resolved):", oracleNs);
        console.log("ORACLE_ADDRESS_BOOK:", _oracleAddressesBookPath(oracleNs));

        address resilientOracle = _resilientOracleAddress(oracleNs);
        address boundValidator = _boundValidatorAddress(oracleNs);
        address mainOracle = _mainOracleAddress(oracleNs);
        address oracleProxyAdmin = _oracleProxyAdminAddress(oracleNs);

        require(
            resilientOracle != address(0) || boundValidator != address(0) || mainOracle != address(0)
                || oracleProxyAdmin != address(0),
            "set at least one target address (env or oracle address book)"
        );

        _assertHandoffTargetsSafe(resilientOracle, boundValidator, mainOracle, oracleProxyAdmin);

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
        _handoff(oracleProxyAdmin, "OracleProxyAdmin", signer);
        vm.stopBroadcast();
    }

    function _resilientOracleAddress(string memory ns) internal view returns (address) {
        if (vm.envExists("RESILIENT_ORACLE_ADDRESS")) {
            return vm.envAddress("RESILIENT_ORACLE_ADDRESS");
        }
        return _readOracleAddressBookKey(ns, "ResilientOracle_Proxy");
    }

    function _boundValidatorAddress(string memory ns) internal view returns (address) {
        if (vm.envExists("BOUND_VALIDATOR_ADDRESS")) {
            return vm.envAddress("BOUND_VALIDATOR_ADDRESS");
        }
        return _readOracleAddressBookKey(ns, "BoundValidator_Proxy");
    }

    function _mainOracleAddress(string memory ns) internal view returns (address) {
        if (vm.envExists("MAIN_ORACLE_ADDRESS")) {
            return vm.envAddress("MAIN_ORACLE_ADDRESS");
        }
        return _readMainOracleProxyFromBook(ns);
    }

    /// @notice The deployed `DefaultProxyAdmin` contract for the oracle proxies (transfer target), not `GlobalConfig`.
    function _oracleProxyAdminAddress(string memory ns) internal view returns (address) {
        if (vm.envExists("ORACLE_PROXY_ADMIN_ADDRESS")) {
            return vm.envAddress("ORACLE_PROXY_ADMIN_ADDRESS");
        }
        if (vm.envExists("DEFAULT_PROXY_ADMIN_ADDRESS")) {
            return vm.envAddress("DEFAULT_PROXY_ADMIN_ADDRESS");
        }
        return _readOracleAddressBookKeyOrZero(ns, "DefaultProxyAdmin");
    }

    function _assertHandoffTargetsSafe(
        address resilientOracle,
        address boundValidator,
        address mainOracle,
        address oracleProxyAdmin
    ) internal view {
        require(resilientOracle != globalConfig, "OracleStackOwnership: ResilientOracle must not be GlobalConfig");
        require(boundValidator != globalConfig, "OracleStackOwnership: BoundValidator must not be GlobalConfig");
        require(mainOracle != globalConfig, "OracleStackOwnership: MainOracle must not be GlobalConfig");
        require(oracleProxyAdmin != globalConfig, "OracleStackOwnership: OracleProxyAdmin must not be GlobalConfig");

        address[4] memory addrs = [resilientOracle, boundValidator, mainOracle, oracleProxyAdmin];
        for (uint256 i = 0; i < 4; i++) {
            for (uint256 j = i + 1; j < 4; j++) {
                if (addrs[i] != address(0) && addrs[i] == addrs[j]) {
                    revert("OracleStackOwnership: duplicate oracle handoff target address");
                }
            }
        }
    }

    function _handoffResilientOracleAndAcm(address oracle, address signer) internal {
        require(oracle != globalConfig, "OracleStackOwnership: ResilientOracle must not be GlobalConfig");

        address oracleOwner = IOwnableLike(oracle).owner();
        address oraclePending = address(0);
        try IOwnable2StepLike(oracle).pendingOwner() returns (address p) {
            oraclePending = p;
        } catch {}

        console.log("ResilientOracle:", oracle);
        console.log("ResilientOracle current owner:", oracleOwner);
        console.log("ResilientOracle current pendingOwner:", oraclePending);

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

        require(target != globalConfig, "OracleStackOwnership: GlobalConfig cannot be a handoff target");

        address currentOwner = IOwnableLike(target).owner();
        console.log(label, "GlobalConfig address:", globalConfig);
        console.log(label, "deployed address:", target);
        console.log(label, "current owner:", currentOwner);

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

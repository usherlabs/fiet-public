// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FileHelper} from "./FileHelper.sol";

/**
 * @notice Reads Venus oracle deployment artefacts under `deployments/oracle_deployments/<namespace>/addresses.json`.
 * @dev Namespace resolution matches `just deploy-oracle` (`ORACLE_NETWORK_ARG`), with `ORACLE_DEPLOYMENT_NETWORK`
 *      as an explicit override. For validation flows that use `ORACLE_CONFIG_FILE`, use
 *      `_oracleDeploymentNamespaceForValidate` so `arbitrumone.json` maps to folder `arbitrumone` when unset.
 */
abstract contract OracleDeploymentBook is FileHelper {
    /// @dev Mirrors `deploy-oracle` ORACLE_NETWORK_ARG mapping when `ORACLE_DEPLOYMENT_NETWORK` is unset.
    function _oracleDeploymentNamespace() internal view returns (string memory) {
        if (vm.envExists("ORACLE_DEPLOYMENT_NETWORK")) {
            return vm.envString("ORACLE_DEPLOYMENT_NETWORK");
        }

        string memory net = vm.envString("NETWORK");
        string memory mode = vm.envOr("MODE", string("LOCAL"));
        if (keccak256(bytes(mode)) == keccak256(bytes("LOCAL"))) {
            return "development";
        }

        bytes32 nh = keccak256(bytes(net));
        if (nh == keccak256(bytes("ethsepolia"))) return "sepolia";
        if (nh == keccak256(bytes("sepolia"))) return "arbitrumsepolia";
        if (nh == keccak256(bytes("arbitrum"))) return "arbitrumone";
        return net;
    }

    /// @dev Prefer explicit `ORACLE_DEPLOYMENT_NETWORK`, else basename of config file without `.json`, else `NETWORK` mapping.
    function _oracleDeploymentNamespaceForValidate(string memory oracleConfigFile) internal view returns (string memory) {
        if (vm.envExists("ORACLE_DEPLOYMENT_NETWORK")) {
            return vm.envString("ORACLE_DEPLOYMENT_NETWORK");
        }
        if (bytes(oracleConfigFile).length > 0) {
            return _oracleBookStripJsonSuffix(_oracleBookBasename(oracleConfigFile));
        }
        return _oracleDeploymentNamespace();
    }

    function _oracleAddressesBookPath(string memory oracleDeploymentNetwork) internal pure returns (string memory) {
        return string.concat("deployments/oracle_deployments/", oracleDeploymentNetwork, "/addresses.json");
    }

    function _readOracleAddressBookKey(string memory oracleDeploymentNetwork, string memory jsonKey)
        internal
        view
        returns (address)
    {
        string memory json = vm.readFile(_oracleAddressesBookPath(oracleDeploymentNetwork));
        return vm.parseJsonAddress(json, string.concat(".", jsonKey));
    }

    function _readOracleAddressBookKeyOrZero(string memory oracleDeploymentNetwork, string memory jsonKey)
        internal
        view
        returns (address)
    {
        string memory json = vm.readFile(_oracleAddressesBookPath(oracleDeploymentNetwork));
        string memory dotted = string.concat(".", jsonKey);
        if (!vm.keyExistsJson(json, dotted)) return address(0);
        return vm.parseJsonAddress(json, dotted);
    }

    function _readMainOracleProxyFromBook(string memory ns) internal view returns (address) {
        address main = _readOracleAddressBookKeyOrZero(ns, "ChainlinkOracle_Proxy");
        if (main != address(0)) return main;
        return _readOracleAddressBookKeyOrZero(ns, "SequencerChainlinkOracle_Proxy");
    }

    function _oracleBookBasename(string memory path) internal pure returns (string memory) {
        bytes memory data = bytes(path);
        uint256 start = 0;
        for (uint256 i = 0; i < data.length; i++) {
            if (data[i] == bytes1("/")) start = i + 1;
        }
        return _oracleBookSubstring(data, start, data.length);
    }

    function _oracleBookStripJsonSuffix(string memory name) internal pure returns (string memory) {
        bytes memory data = bytes(name);
        if (data.length >= 5) {
            uint256 i = data.length - 5;
            if (
                data[i] == bytes1(".") && data[i + 1] == bytes1("j") && data[i + 2] == bytes1("s")
                    && data[i + 3] == bytes1("o") && data[i + 4] == bytes1("n")
            ) {
                return _oracleBookSubstring(data, 0, i);
            }
        }
        return name;
    }

    function _oracleBookSubstring(bytes memory data, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory out = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = data[i];
        }
        return string(out);
    }
}

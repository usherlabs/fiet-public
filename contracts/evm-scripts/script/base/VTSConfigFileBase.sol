// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {MarketVTSConfiguration, TokenConfiguration} from "src/types/VTS.sol";

/// @notice Shared helper for loading a fully-specified VTS config from disk.
/// @dev Intended for Foundry scripts; uses cheatcodes for env + file IO + JSON/TOML parsing.
abstract contract VTSConfigFileBase is Script {
    /// @dev Required env var pointing at a JSON or TOML file.
    /// - JSON keys: `.token0.gracePeriodTime` etc
    /// - TOML keys: `token0.gracePeriodTime` etc
    string internal constant VTS_CONFIG_ENV = "VTS_CONFIG_FILE_PATH";

    function _loadVTSConfig() internal view returns (MarketVTSConfiguration memory cfg, string memory source) {
        if (!vm.envExists(VTS_CONFIG_ENV)) {
            revert("VTS config file required: set VTS_CONFIG_FILE_PATH");
        }

        string memory path = vm.envString(VTS_CONFIG_ENV);
        string memory contents = vm.readFile(path);

        if (_endsWith(path, ".toml")) {
            cfg = _parseTomlConfig(contents);
        } else {
            // Default to JSON (matches other scripts in this repo).
            cfg = _parseJsonConfig(contents);
        }

        return (cfg, path);
    }

    function _parseJsonConfig(string memory json) private view returns (MarketVTSConfiguration memory cfg) {
        cfg = MarketVTSConfiguration({
            token0: _parseJsonTokenConfig(json, ".token0"),
            token1: _parseJsonTokenConfig(json, ".token1"),
            minResidualUnits: _jsonUint(json, ".minResidualUnits"),
            unbackedCommitmentGraceBypassBps: _jsonUint16(json, ".unbackedCommitmentGraceBypassBps")
        });
    }

    function _parseTomlConfig(string memory toml) private view returns (MarketVTSConfiguration memory cfg) {
        cfg = MarketVTSConfiguration({
            token0: _parseTomlTokenConfig(toml, "token0"),
            token1: _parseTomlTokenConfig(toml, "token1"),
            minResidualUnits: _tomlUint(toml, "minResidualUnits"),
            unbackedCommitmentGraceBypassBps: _tomlUint16(toml, "unbackedCommitmentGraceBypassBps")
        });
    }

    function _parseJsonTokenConfig(string memory json, string memory prefix)
        private
        view
        returns (TokenConfiguration memory cfg)
    {
        cfg = TokenConfiguration({
            gracePeriodTime: _jsonUint(json, string.concat(prefix, ".gracePeriodTime")),
            baseVTSRate: _jsonUint(json, string.concat(prefix, ".baseVTSRate")),
            maxGracePeriodTime: _jsonUint(json, string.concat(prefix, ".maxGracePeriodTime")),
            unbackedCommitmentGraceBypassTime: _jsonUint(
                json, string.concat(prefix, ".unbackedCommitmentGraceBypassTime")
            ),
            unbackedCommitmentGraceBypassThreshold: _jsonUint(
                json, string.concat(prefix, ".unbackedCommitmentGraceBypassThreshold")
            )
        });
    }

    function _parseTomlTokenConfig(string memory toml, string memory prefix)
        private
        view
        returns (TokenConfiguration memory cfg)
    {
        cfg = TokenConfiguration({
            gracePeriodTime: _tomlUint(toml, string.concat(prefix, ".gracePeriodTime")),
            baseVTSRate: _tomlUint(toml, string.concat(prefix, ".baseVTSRate")),
            maxGracePeriodTime: _tomlUint(toml, string.concat(prefix, ".maxGracePeriodTime")),
            unbackedCommitmentGraceBypassTime: _tomlUint(
                toml, string.concat(prefix, ".unbackedCommitmentGraceBypassTime")
            ),
            unbackedCommitmentGraceBypassThreshold: _tomlUint(
                toml, string.concat(prefix, ".unbackedCommitmentGraceBypassThreshold")
            )
        });
    }

    function _jsonUint(string memory json, string memory key) private view returns (uint256) {
        require(vm.keyExistsJson(json, key), string.concat("missing VTS config key: ", key));
        return vm.parseJsonUint(json, key);
    }

    function _jsonUint16(string memory json, string memory key) private view returns (uint16) {
        require(vm.keyExistsJson(json, key), string.concat("missing VTS config key: ", key));
        uint256 v = vm.parseJsonUint(json, key);
        require(v <= type(uint16).max, "vts cfg: uint16 overflow");
        return uint16(v);
    }

    function _tomlUint(string memory toml, string memory key) private view returns (uint256) {
        require(vm.keyExistsToml(toml, key), string.concat("missing VTS config key: ", key));
        return vm.parseTomlUint(toml, key);
    }

    function _tomlUint16(string memory toml, string memory key) private view returns (uint16) {
        require(vm.keyExistsToml(toml, key), string.concat("missing VTS config key: ", key));
        uint256 v = vm.parseTomlUint(toml, key);
        require(v <= type(uint16).max, "vts cfg: uint16 overflow");
        return uint16(v);
    }

    function _endsWith(string memory s, string memory suffix) private pure returns (bool) {
        bytes memory bs = bytes(s);
        bytes memory suf = bytes(suffix);
        if (bs.length < suf.length) return false;
        uint256 start = bs.length - suf.length;
        for (uint256 i = 0; i < suf.length; i++) {
            if (bs[start + i] != suf[i]) return false;
        }
        return true;
    }
}

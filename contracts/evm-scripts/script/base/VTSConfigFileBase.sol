// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {VTSConfigs} from "src/libraries/VTSConfigs.sol";
import {MarketVTSConfiguration} from "src/types/VTS.sol";

/// @notice Shared helper for loading a VTS config from disk (optional), with defaults as fallback.
/// @dev Intended for Foundry scripts; uses cheatcodes for env + file IO + JSON/TOML parsing.
abstract contract VTSConfigFileBase is Script {
    /// @dev Optional env var pointing at a JSON or TOML file. If absent, defaults are used.
    /// - JSON keys: `.token0.gracePeriodTime` etc
    /// - TOML keys: `token0.gracePeriodTime` etc
    string internal constant VTS_CONFIG_ENV = "VTS_CONFIG_FILE_PATH";

    function _loadVTSConfig() internal view returns (MarketVTSConfiguration memory cfg, string memory source) {
        cfg = VTSConfigs.getDefaultConfig();

        if (!vm.envExists(VTS_CONFIG_ENV)) {
            return (cfg, "default");
        }

        string memory path = vm.envString(VTS_CONFIG_ENV);
        string memory contents = vm.readFile(path);

        if (_endsWith(path, ".toml")) {
            cfg = _applyTomlOverrides(cfg, contents);
        } else {
            // Default to JSON (matches other scripts in this repo).
            cfg = _applyJsonOverrides(cfg, contents);
        }

        return (cfg, path);
    }

    function _applyJsonOverrides(MarketVTSConfiguration memory cfg, string memory json)
        private
        view
        returns (MarketVTSConfiguration memory)
    {
        // token0
        cfg.token0.gracePeriodTime =
            _jsonUintOr(json, ".token0.gracePeriodTime", cfg.token0.gracePeriodTime);
        cfg.token0.maxGracePeriodTime =
            _jsonUintOr(json, ".token0.maxGracePeriodTime", cfg.token0.maxGracePeriodTime);
        cfg.token0.seizureUnlockTime =
            _jsonUintOr(json, ".token0.seizureUnlockTime", cfg.token0.seizureUnlockTime);
        cfg.token0.baseVTSRate = _jsonUintOr(json, ".token0.baseVTSRate", cfg.token0.baseVTSRate);

        // token1
        cfg.token1.gracePeriodTime =
            _jsonUintOr(json, ".token1.gracePeriodTime", cfg.token1.gracePeriodTime);
        cfg.token1.maxGracePeriodTime =
            _jsonUintOr(json, ".token1.maxGracePeriodTime", cfg.token1.maxGracePeriodTime);
        cfg.token1.seizureUnlockTime =
            _jsonUintOr(json, ".token1.seizureUnlockTime", cfg.token1.seizureUnlockTime);
        cfg.token1.baseVTSRate = _jsonUintOr(json, ".token1.baseVTSRate", cfg.token1.baseVTSRate);

        // top-level
        cfg.coverageFeeShare = _jsonUint16Or(json, ".coverageFeeShare", cfg.coverageFeeShare);
        cfg.minResidualUnits = _jsonUintOr(json, ".minResidualUnits", cfg.minResidualUnits);
        cfg.unbackedCommitmentGraceBypassBps = _jsonUint16Or(
            json,
            ".unbackedCommitmentGraceBypassBps",
            _jsonUint16Or(json, ".commitmentDeficitBypassBps", cfg.unbackedCommitmentGraceBypassBps)
        );

        return cfg;
    }

    function _applyTomlOverrides(MarketVTSConfiguration memory cfg, string memory toml)
        private
        view
        returns (MarketVTSConfiguration memory)
    {
        // token0
        cfg.token0.gracePeriodTime =
            _tomlUintOr(toml, "token0.gracePeriodTime", cfg.token0.gracePeriodTime);
        cfg.token0.maxGracePeriodTime =
            _tomlUintOr(toml, "token0.maxGracePeriodTime", cfg.token0.maxGracePeriodTime);
        cfg.token0.seizureUnlockTime =
            _tomlUintOr(toml, "token0.seizureUnlockTime", cfg.token0.seizureUnlockTime);
        cfg.token0.baseVTSRate = _tomlUintOr(toml, "token0.baseVTSRate", cfg.token0.baseVTSRate);

        // token1
        cfg.token1.gracePeriodTime =
            _tomlUintOr(toml, "token1.gracePeriodTime", cfg.token1.gracePeriodTime);
        cfg.token1.maxGracePeriodTime =
            _tomlUintOr(toml, "token1.maxGracePeriodTime", cfg.token1.maxGracePeriodTime);
        cfg.token1.seizureUnlockTime =
            _tomlUintOr(toml, "token1.seizureUnlockTime", cfg.token1.seizureUnlockTime);
        cfg.token1.baseVTSRate = _tomlUintOr(toml, "token1.baseVTSRate", cfg.token1.baseVTSRate);

        // top-level
        cfg.coverageFeeShare = _tomlUint16Or(toml, "coverageFeeShare", cfg.coverageFeeShare);
        cfg.minResidualUnits = _tomlUintOr(toml, "minResidualUnits", cfg.minResidualUnits);
        cfg.unbackedCommitmentGraceBypassBps = _tomlUint16Or(
            toml,
            "unbackedCommitmentGraceBypassBps",
            _tomlUint16Or(toml, "commitmentDeficitBypassBps", cfg.unbackedCommitmentGraceBypassBps)
        );

        return cfg;
    }

    function _jsonUintOr(string memory json, string memory key, uint256 defaultValue) private view returns (uint256) {
        if (!vm.keyExistsJson(json, key)) return defaultValue;
        return vm.parseJsonUint(json, key);
    }

    function _jsonUint16Or(string memory json, string memory key, uint16 defaultValue) private view returns (uint16) {
        if (!vm.keyExistsJson(json, key)) return defaultValue;
        uint256 v = vm.parseJsonUint(json, key);
        require(v <= type(uint16).max, "vts cfg: uint16 overflow");
        return uint16(v);
    }

    function _tomlUintOr(string memory toml, string memory key, uint256 defaultValue) private view returns (uint256) {
        if (!vm.keyExistsToml(toml, key)) return defaultValue;
        return vm.parseTomlUint(toml, key);
    }

    function _tomlUint16Or(string memory toml, string memory key, uint16 defaultValue) private view returns (uint16) {
        if (!vm.keyExistsToml(toml, key)) return defaultValue;
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


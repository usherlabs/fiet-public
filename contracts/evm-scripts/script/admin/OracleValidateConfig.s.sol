// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {AdminBase} from "./AdminBase.sol";

interface IOwnable2StepLike {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}

interface IAccessControlledLike is IOwnable2StepLike {
    function accessControlManager() external view returns (address);
}

interface IAccessControlManagerView {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function hasPermission(address account, address contractAddress, string calldata functionSig)
        external
        view
        returns (bool);
}

interface IChainlinkOracleView is IAccessControlledLike {
    function tokenConfigs(address asset) external view returns (address, address, uint256);
}

interface IBoundValidatorView is IAccessControlledLike {
    function validateConfigs(address asset) external view returns (address, uint256, uint256);
}

interface IResilientOracleView is IAccessControlledLike {
    struct TokenConfig {
        address asset;
        address[3] oracles;
        bool[3] enableFlagsForOracles;
        bool cachingEnabled;
    }

    function getTokenConfig(address asset) external view returns (TokenConfig memory);
}

contract OracleValidateConfigScript is AdminBase {
    address internal constant NATIVE_ASSET_SENTINEL = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;
    string internal constant MAIN_SET_TOKEN_CONFIG_SIG = "setTokenConfig(TokenConfig)";
    string internal constant MAIN_SET_TOKEN_CONFIG_TUPLE_SIG = "setTokenConfig((address,address,uint256))";
    string internal constant RESILIENT_SET_TOKEN_CONFIG_SIG = "setTokenConfig(TokenConfig)";
    string internal constant BOUND_SET_VALIDATE_CONFIG_SIG = "setValidateConfig(ValidateConfig)";

    uint256 internal failureCount;
    uint256 internal warningCount;

    function run() external {
        _loadAdminAddresses();

        string memory cfgFile = vm.envOr("ORACLE_CONFIG_FILE", string("example.json"));
        string memory cfgPath = string.concat("config/oracle/", cfgFile);
        string memory json = vm.readFile(cfgPath);

        string memory oracleDeploymentNetwork =
            vm.envOr("ORACLE_DEPLOYMENT_NETWORK", _stripJsonSuffix(_basename(cfgFile)));
        string memory addrBookPath =
            string.concat("deployments/oracle_deployments/", oracleDeploymentNetwork, "/addresses.json");
        string memory addrBook = vm.readFile(addrBookPath);

        address resilientOracle = vm.parseJsonAddress(json, ".contracts.resilientOracle");
        address mainOracle = vm.parseJsonAddress(json, ".contracts.mainOracle");
        address boundValidator = vm.parseJsonAddress(json, ".contracts.boundValidator");
        address defaultPivotOracle = vm.parseJsonAddress(json, ".contracts.pivotOracle");
        address defaultFallbackOracle = vm.parseJsonAddress(json, ".contracts.fallbackOracle");

        uint256 assetCount = _assetCount(json);
        bool requiresBoundsPermission = _requiresBoundsPermission(json, assetCount);

        console.log("NETWORK:", networkName);
        console.log("GlobalConfig:", globalConfig);
        console.log("ORACLE_CONFIG:", cfgPath);
        console.log("ORACLE_DEPLOYMENT_NETWORK:", oracleDeploymentNetwork);
        console.log("ADDRESS_BOOK:", addrBookPath);
        console.log("assets.length:", assetCount);

        _check(assetCount > 0, "oracle config has at least one asset");
        _check(resilientOracle != address(0), "config resilientOracle is non-zero");
        _check(mainOracle != address(0), "config mainOracle is non-zero");
        _check(boundValidator != address(0), "config boundValidator is non-zero");

        address expectedResilientOracle = vm.parseJsonAddress(addrBook, ".ResilientOracle_Proxy");
        address expectedBoundValidator = vm.parseJsonAddress(addrBook, ".BoundValidator_Proxy");
        address expectedMainOracle = _jsonAddressOr(addrBook, ".ChainlinkOracle_Proxy", address(0));
        if (expectedMainOracle == address(0)) {
            expectedMainOracle = _jsonAddressOr(addrBook, ".SequencerChainlinkOracle_Proxy", address(0));
        }
        address expectedAccessControlManager = vm.parseJsonAddress(addrBook, ".AccessControlManager");
        address expectedDefaultProxyAdmin = _jsonAddressOr(addrBook, ".DefaultProxyAdmin", address(0));

        _checkEqAddress("config resilientOracle matches oracle deployment artefact", resilientOracle, expectedResilientOracle);
        _checkEqAddress("config mainOracle matches oracle deployment artefact", mainOracle, expectedMainOracle);
        _checkEqAddress("config boundValidator matches oracle deployment artefact", boundValidator, expectedBoundValidator);

        address resilientAcm = IAccessControlledLike(resilientOracle).accessControlManager();
        address mainAcm = IAccessControlledLike(mainOracle).accessControlManager();
        address boundAcm = IAccessControlledLike(boundValidator).accessControlManager();

        _checkEqAddress("ResilientOracle.accessControlManager matches oracle deployment artefact", resilientAcm, expectedAccessControlManager);
        _checkEqAddress("MainOracle.accessControlManager matches ResilientOracle ACM", mainAcm, resilientAcm);
        _checkEqAddress("BoundValidator.accessControlManager matches ResilientOracle ACM", boundAcm, resilientAcm);

        _checkEqAddress("ResilientOracle owner is GlobalConfig", IOwnable2StepLike(resilientOracle).owner(), globalConfig);
        _checkEqAddress("MainOracle owner is GlobalConfig", IOwnable2StepLike(mainOracle).owner(), globalConfig);
        _checkEqAddress("BoundValidator owner is GlobalConfig", IOwnable2StepLike(boundValidator).owner(), globalConfig);

        _checkEqAddress("ResilientOracle pendingOwner is clear", _pendingOwnerOrZero(resilientOracle), address(0));
        _checkEqAddress("MainOracle pendingOwner is clear", _pendingOwnerOrZero(mainOracle), address(0));
        _checkEqAddress("BoundValidator pendingOwner is clear", _pendingOwnerOrZero(boundValidator), address(0));

        if (expectedDefaultProxyAdmin != address(0)) {
            _checkEqAddress("DefaultProxyAdmin owner is GlobalConfig", IOwnable2StepLike(expectedDefaultProxyAdmin).owner(), globalConfig);
        } else {
            _warn("DefaultProxyAdmin missing from oracle deployment artefact; skipping owner check");
        }

        bytes32 adminRole = IAccessControlManagerView(resilientAcm).DEFAULT_ADMIN_ROLE();
        _check(
            IAccessControlManagerView(resilientAcm).hasRole(adminRole, globalConfig),
            "GlobalConfig has ACM DEFAULT_ADMIN_ROLE"
        );

        _check(
            IAccessControlManagerView(resilientAcm).hasPermission(globalConfig, mainOracle, MAIN_SET_TOKEN_CONFIG_SIG),
            "GlobalConfig has MainOracle setTokenConfig(TokenConfig) permission"
        );
        if (
            !IAccessControlManagerView(resilientAcm).hasPermission(
                globalConfig, mainOracle, MAIN_SET_TOKEN_CONFIG_TUPLE_SIG
            )
        ) {
            _warn("GlobalConfig is missing optional MainOracle tuple-style permission setTokenConfig((address,address,uint256))");
        } else {
            _ok("GlobalConfig has optional MainOracle tuple-style permission");
        }
        _check(
            IAccessControlManagerView(resilientAcm).hasPermission(globalConfig, resilientOracle, RESILIENT_SET_TOKEN_CONFIG_SIG),
            "GlobalConfig has ResilientOracle setTokenConfig(TokenConfig) permission"
        );
        if (requiresBoundsPermission) {
            _check(
                IAccessControlManagerView(resilientAcm).hasPermission(
                    globalConfig, boundValidator, BOUND_SET_VALIDATE_CONFIG_SIG
                ),
                "GlobalConfig has BoundValidator setValidateConfig(ValidateConfig) permission"
            );
        } else {
            _warn("No asset enables pivot/fallback; BoundValidator permission is not required for this config");
        }

        _validateAssetConfigs(json, assetCount, mainOracle, boundValidator, resilientOracle, defaultPivotOracle, defaultFallbackOracle);

        console.log("");
        console.log("Validation failures:", failureCount);
        console.log("Validation warnings:", warningCount);

        require(failureCount == 0, "OracleValidateConfig: validation failed");
        console.log("OK: oracle config validation passed");
    }

    function _validateAssetConfigs(
        string memory json,
        uint256 assetCount,
        address mainOracle,
        address boundValidator,
        address resilientOracle,
        address defaultPivotOracle,
        address defaultFallbackOracle
    ) internal {
        address[] memory seenAssets = new address[](assetCount);

        for (uint256 i = 0; i < assetCount; i++) {
            string memory base = string.concat(".assets[", vm.toString(i), "]");
            string memory label = string.concat("asset[", vm.toString(i), "]");

            address configAssetRaw = vm.parseJsonAddress(json, string.concat(base, ".asset"));
            address asset = _normaliseAsset(configAssetRaw);
            address feed = vm.parseJsonAddress(json, string.concat(base, ".feed"));
            uint256 maxStalePeriod = vm.parseJsonUint(json, string.concat(base, ".maxStalePeriod"));

            bool cachingEnabled = _jsonBoolOr(json, string.concat(base, ".cachingEnabled"), _jsonBoolOr(json, ".defaults.cachingEnabled", false));
            bool enableMain = _jsonBoolOr(json, string.concat(base, ".enableMain"), _jsonBoolOr(json, ".defaults.enableMain", true));
            bool enablePivot = _jsonBoolOr(json, string.concat(base, ".enablePivot"), _jsonBoolOr(json, ".defaults.enablePivot", false));
            bool enableFallback =
                _jsonBoolOr(json, string.concat(base, ".enableFallback"), _jsonBoolOr(json, ".defaults.enableFallback", false));

            address pivotOracle = _jsonAddressOr(json, string.concat(base, ".pivotOracle"), defaultPivotOracle);
            address fallbackOracle = _jsonAddressOr(json, string.concat(base, ".fallbackOracle"), defaultFallbackOracle);

            _check(asset != address(0), string.concat(label, " asset is non-zero after native sentinel normalisation"));
            _check(feed != address(0), string.concat(label, " feed is non-zero"));
            _check(maxStalePeriod > 0, string.concat(label, " maxStalePeriod is positive"));
            _check(enableMain, string.concat(label, " enableMain is true"));

            for (uint256 j = 0; j < i; j++) {
                if (seenAssets[j] == asset) {
                    _fail(string.concat(label, " duplicates a previous asset entry"));
                    break;
                }
            }
            seenAssets[i] = asset;

            if (vm.keyExistsJson(json, string.concat(base, ".ticker"))) {
                string memory ticker = vm.parseJsonString(json, string.concat(base, ".ticker"));
                _check(bytes(ticker).length > 0, string.concat(label, " ticker is non-empty when provided"));
            }

            if (enablePivot) {
                _check(pivotOracle != address(0), string.concat(label, " pivotOracle is non-zero when enabled"));
            }
            if (enableFallback) {
                _check(fallbackOracle != address(0), string.concat(label, " fallbackOracle is non-zero when enabled"));
            }

            _validateOnchainMainConfig(label, mainOracle, asset, feed, maxStalePeriod);
            _validateOnchainResilientConfig(
                label, resilientOracle, asset, mainOracle, pivotOracle, fallbackOracle, enableMain, enablePivot, enableFallback, cachingEnabled
            );

            if (enablePivot || enableFallback) {
                _validateOnchainBoundsConfig(label, json, base, boundValidator, asset);
            }
        }
    }

    function _validateOnchainMainConfig(
        string memory label,
        address mainOracle,
        address asset,
        address expectedFeed,
        uint256 expectedMaxStalePeriod
    ) internal {
        (address configuredAsset, address configuredFeed, uint256 configuredMaxStalePeriod) =
            IChainlinkOracleView(mainOracle).tokenConfigs(asset);

        _checkEqAddress(string.concat(label, " MainOracle asset"), configuredAsset, asset);
        _checkEqAddress(string.concat(label, " MainOracle feed"), configuredFeed, expectedFeed);
        _checkEqUint(string.concat(label, " MainOracle maxStalePeriod"), configuredMaxStalePeriod, expectedMaxStalePeriod);
    }

    function _validateOnchainBoundsConfig(
        string memory label,
        string memory json,
        string memory base,
        address boundValidator,
        address asset
    ) internal {
        bool hasUpper = vm.keyExistsJson(json, string.concat(base, ".bounds.upperBoundRatio"));
        bool hasLower = vm.keyExistsJson(json, string.concat(base, ".bounds.lowerBoundRatio"));
        _check(hasUpper, string.concat(label, " bounds.upperBoundRatio exists"));
        _check(hasLower, string.concat(label, " bounds.lowerBoundRatio exists"));
        if (!(hasUpper && hasLower)) return;

        uint256 expectedUpper = vm.parseJsonUint(json, string.concat(base, ".bounds.upperBoundRatio"));
        uint256 expectedLower = vm.parseJsonUint(json, string.concat(base, ".bounds.lowerBoundRatio"));
        _check(expectedUpper > 0, string.concat(label, " bounds.upperBoundRatio is positive"));
        _check(expectedLower > 0, string.concat(label, " bounds.lowerBoundRatio is positive"));
        _check(expectedUpper > expectedLower, string.concat(label, " bounds upper is greater than lower"));

        (address configuredAsset, uint256 configuredUpper, uint256 configuredLower) =
            IBoundValidatorView(boundValidator).validateConfigs(asset);

        _checkEqAddress(string.concat(label, " BoundValidator asset"), configuredAsset, asset);
        _checkEqUint(string.concat(label, " BoundValidator upperBoundRatio"), configuredUpper, expectedUpper);
        _checkEqUint(string.concat(label, " BoundValidator lowerBoundRatio"), configuredLower, expectedLower);
    }

    function _validateOnchainResilientConfig(
        string memory label,
        address resilientOracle,
        address asset,
        address expectedMainOracle,
        address expectedPivotOracle,
        address expectedFallbackOracle,
        bool expectedMainEnabled,
        bool expectedPivotEnabled,
        bool expectedFallbackEnabled,
        bool expectedCachingEnabled
    ) internal {
        IResilientOracleView.TokenConfig memory cfg = IResilientOracleView(resilientOracle).getTokenConfig(asset);

        _checkEqAddress(string.concat(label, " ResilientOracle asset"), cfg.asset, asset);
        _checkEqAddress(string.concat(label, " ResilientOracle main oracle"), cfg.oracles[0], expectedMainOracle);
        _checkEqAddress(string.concat(label, " ResilientOracle pivot oracle"), cfg.oracles[1], expectedPivotOracle);
        _checkEqAddress(string.concat(label, " ResilientOracle fallback oracle"), cfg.oracles[2], expectedFallbackOracle);
        _checkEqBool(string.concat(label, " ResilientOracle main enabled"), cfg.enableFlagsForOracles[0], expectedMainEnabled);
        _checkEqBool(string.concat(label, " ResilientOracle pivot enabled"), cfg.enableFlagsForOracles[1], expectedPivotEnabled);
        _checkEqBool(string.concat(label, " ResilientOracle fallback enabled"), cfg.enableFlagsForOracles[2], expectedFallbackEnabled);
        _checkEqBool(string.concat(label, " ResilientOracle cachingEnabled"), cfg.cachingEnabled, expectedCachingEnabled);
    }

    function _assetCount(string memory json) internal view returns (uint256 count) {
        while (vm.keyExistsJson(json, string.concat(".assets[", vm.toString(count), "].asset"))) {
            count++;
        }
    }

    function _requiresBoundsPermission(string memory json, uint256 assetCount) internal view returns (bool) {
        bool defaultEnablePivot = _jsonBoolOr(json, ".defaults.enablePivot", false);
        bool defaultEnableFallback = _jsonBoolOr(json, ".defaults.enableFallback", false);

        for (uint256 i = 0; i < assetCount; i++) {
            string memory base = string.concat(".assets[", vm.toString(i), "]");
            bool enablePivot = _jsonBoolOr(json, string.concat(base, ".enablePivot"), defaultEnablePivot);
            bool enableFallback = _jsonBoolOr(json, string.concat(base, ".enableFallback"), defaultEnableFallback);
            if (enablePivot || enableFallback) return true;
        }

        return false;
    }

    function _normaliseAsset(address asset) internal pure returns (address) {
        if (asset == address(0)) return NATIVE_ASSET_SENTINEL;
        return asset;
    }

    function _pendingOwnerOrZero(address target) internal view returns (address pendingOwner) {
        try IOwnable2StepLike(target).pendingOwner() returns (address p) {
            pendingOwner = p;
        } catch {
            pendingOwner = address(0);
        }
    }

    function _jsonAddressOr(string memory json, string memory key, address defaultValue)
        internal
        view
        returns (address)
    {
        if (!vm.keyExistsJson(json, key)) return defaultValue;
        return vm.parseJsonAddress(json, key);
    }

    function _jsonBoolOr(string memory json, string memory key, bool defaultValue) internal view returns (bool) {
        if (!vm.keyExistsJson(json, key)) return defaultValue;
        return vm.parseJsonBool(json, key);
    }

    function _basename(string memory path) internal pure returns (string memory) {
        bytes memory data = bytes(path);
        uint256 start = 0;
        for (uint256 i = 0; i < data.length; i++) {
            if (data[i] == bytes1("/")) start = i + 1;
        }
        return _substring(data, start, data.length);
    }

    function _stripJsonSuffix(string memory name) internal pure returns (string memory) {
        bytes memory data = bytes(name);
        if (data.length >= 5) {
            uint256 i = data.length - 5;
            if (
                data[i] == bytes1(".") && data[i + 1] == bytes1("j") && data[i + 2] == bytes1("s")
                    && data[i + 3] == bytes1("o") && data[i + 4] == bytes1("n")
            ) {
                return _substring(data, 0, i);
            }
        }
        return name;
    }

    function _substring(bytes memory data, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory out = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = data[i];
        }
        return string(out);
    }

    function _ok(string memory label) internal pure {
        console.log("OK:", label);
    }

    function _warn(string memory label) internal {
        warningCount++;
        console.log("WARN:", label);
    }

    function _fail(string memory label) internal {
        failureCount++;
        console.log("FAIL:", label);
    }

    function _check(bool condition, string memory label) internal {
        if (condition) {
            _ok(label);
        } else {
            _fail(label);
        }
    }

    function _checkEqAddress(string memory label, address actual, address expected) internal {
        if (actual == expected) {
            _ok(label);
            return;
        }

        _fail(label);
        console.log("  expected:", expected);
        console.log("  actual:", actual);
    }

    function _checkEqUint(string memory label, uint256 actual, uint256 expected) internal {
        if (actual == expected) {
            _ok(label);
            return;
        }

        _fail(label);
        console.log("  expected:", expected);
        console.log("  actual:", actual);
    }

    function _checkEqBool(string memory label, bool actual, bool expected) internal {
        if (actual == expected) {
            _ok(label);
            return;
        }

        _fail(label);
        console.log("  expected:", expected);
        console.log("  actual:", actual);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * Admin: Configure Venus oracle feeds + ResilientOracle per asset (via GlobalConfig)
 *
 * This script:
 * - Reads an oracle config file from `contracts/evm-scripts/config/oracle/`
 * - For each asset:
 *   1) Calls `ChainlinkOracle.setTokenConfig(asset, feed, maxStalePeriod)`
 *   2) Calls `BoundValidator.setValidateConfig(asset, upperBoundRatio, lowerBoundRatio)` (when pivot/fallback enabled)
 *   3) Calls `ResilientOracle.setTokenConfig(asset, [main,pivot,fallback], enableFlags, cachingEnabled)`
 *
 * IMPORTANT:
 * - All calls are routed through `GlobalConfig.proxyCall`, so the tx signer must be the GlobalConfig owner.
 * - Venus oracles gate admin calls via ACM (`_checkAccessAllowed("<sig>")`), so GlobalConfig must have
 *   ACM permissions for each target function before running this.
 *
 * Inputs:
 * - PRIVATE_KEY
 * - NETWORK (loads GlobalConfig from deployments/<network>_deployments.json)
 *
 * - ORACLE_CONFIG_FILE (optional): filename under `config/oracle/` (default: `example.json`)
 */

import {console} from "forge-std/Script.sol";
// (no VmSafe needed; we no longer fetch broadcast tx hashes)

import {AdminBase} from "./AdminBase.sol";

interface IChainlinkOracleAdmin {
    struct TokenConfig {
        address asset;
        address feed;
        uint256 maxStalePeriod;
    }

    function setTokenConfig(TokenConfig calldata tokenConfig) external;
}

interface IBoundValidatorAdmin {
    struct ValidateConfig {
        address asset;
        uint256 upperBoundRatio;
        uint256 lowerBoundRatio;
    }

    function setValidateConfig(ValidateConfig calldata config) external;
}

interface IResilientOracleAdmin {
    struct TokenConfig {
        address asset;
        address[3] oracles; // [main, pivot, fallback]
        bool[3] enableFlagsForOracles;
        bool cachingEnabled;
    }

    function setTokenConfig(TokenConfig calldata tokenConfig) external;
}

interface IOracleHelperAdmin {
    function registerTicker(string calldata ticker, address asset) external;
}

struct OracleBoundsConfig {
    uint256 upperBoundRatio;
    uint256 lowerBoundRatio;
}

struct OracleAssetConfig {
    string ticker;
    address asset;
    address feed;
    uint256 maxStalePeriod;
    bool cachingEnabled;
    bool enableMain;
    bool enablePivot;
    bool enableFallback;
    address pivotOracle;
    address fallbackOracle;
    OracleBoundsConfig bounds;
}

contract OracleConfigureAssetsScript is AdminBase {
    // Sentinel used by Venus ResilientOracle to denote native gas token (e.g. ETH).
    address internal constant NATIVE_ASSET_SENTINEL = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;

    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));

        _loadAdminAddresses();

        string memory cfgFile = vm.envOr("ORACLE_CONFIG_FILE", string("example.json"));
        string memory path = string.concat("config/oracle/", cfgFile);
        string memory json = vm.readFile(path);

        // Optional: limit which assets are configured. If unset/empty, we configure all assets from the config file.
        // Format: comma-separated list of addresses, e.g.
        // ORACLE_ASSET_FILTER="0xabc...,0xdef..."
        string memory assetFilterCsv = vm.envOr("ORACLE_ASSET_FILTER", string(""));
        address[] memory assetFilter = _parseAddressCsv(assetFilterCsv);

        address resilientOracle = vm.parseJsonAddress(json, ".contracts.resilientOracle");
        address mainOracle = vm.parseJsonAddress(json, ".contracts.mainOracle");
        address boundValidator = vm.parseJsonAddress(json, ".contracts.boundValidator");
        address defaultPivotOracle = vm.parseJsonAddress(json, ".contracts.pivotOracle");
        address defaultFallbackOracle = vm.parseJsonAddress(json, ".contracts.fallbackOracle");

        bool defaultCachingEnabled = _jsonBoolOr(json, ".defaults.cachingEnabled", false);
        bool defaultEnableMain = _jsonBoolOr(json, ".defaults.enableMain", true);
        bool defaultEnablePivot = _jsonBoolOr(json, ".defaults.enablePivot", false);
        bool defaultEnableFallback = _jsonBoolOr(json, ".defaults.enableFallback", false);

        // Determine assets.length without decoding a struct, so configs can safely include extra keys (e.g. `configured`).
        uint256 n = 0;
        while (vm.keyExistsJson(json, string.concat(".assets[", vm.toString(n), "].asset"))) {
            n++;
        }
        require(n > 0, "oracle cfg: assets empty");

        console.log("NETWORK:", networkName);
        console.log("GlobalConfig:", globalConfig);
        console.log("ORACLE_CONFIG:", path);
        console.log("assets.length:", n);
        console.log("ResilientOracle:", resilientOracle);
        console.log("MainOracle:", mainOracle);
        console.log("BoundValidator:", boundValidator);
        console.log("OracleHelper:", oracleHelper);

        require(resilientOracle != address(0), "oracle cfg: resilientOracle=0");
        require(mainOracle != address(0), "oracle cfg: mainOracle=0");
        require(boundValidator != address(0), "oracle cfg: boundValidator=0");
        require(oracleHelper != address(0), "oracle cfg: oracleHelper=0");

        vm.startBroadcast(pk);

        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".assets[", vm.toString(i), "]");

            // If this asset config has already been applied (boolean marker), skip it.
            string memory configuredKey = string.concat(base, ".configured");
            if (vm.keyExistsJson(json, configuredKey) && vm.parseJsonBool(json, configuredKey)) {
                address existingAsset = _jsonAddressOr(json, string.concat(base, ".asset"), address(0));
                console.log("\nSKIP: already configured");
                console.log("asset:", existingAsset);
                continue;
            }

            address configAsset = vm.parseJsonAddress(json, string.concat(base, ".asset"));
            address asset = configAsset;

            // Allow configs to specify native asset as `asset=0x0` by mapping to ResilientOracle sentinel.
            if (asset == address(0)) {
                asset = NATIVE_ASSET_SENTINEL;
                console.log("NOTE: config asset=0x0 (native), using sentinel:", asset);
            }

            if (assetFilter.length > 0 && !_containsAddress(assetFilter, asset) && !_containsAddress(assetFilter, configAsset))
            {
                console.log("\nSKIP: filtered out");
                console.log("asset:", asset);
                continue;
            }

            address feed = vm.parseJsonAddress(json, string.concat(base, ".feed"));
            uint256 maxStalePeriod = vm.parseJsonUint(json, string.concat(base, ".maxStalePeriod"));

            bool cachingEnabled = _jsonBoolOr(json, string.concat(base, ".cachingEnabled"), defaultCachingEnabled);
            bool enableMain = _jsonBoolOr(json, string.concat(base, ".enableMain"), defaultEnableMain);
            bool enablePivot = _jsonBoolOr(json, string.concat(base, ".enablePivot"), defaultEnablePivot);
            bool enableFallback = _jsonBoolOr(json, string.concat(base, ".enableFallback"), defaultEnableFallback);

            address pivotOracle = _jsonAddressOr(json, string.concat(base, ".pivotOracle"), defaultPivotOracle);
            address fallbackOracle = _jsonAddressOr(json, string.concat(base, ".fallbackOracle"), defaultFallbackOracle);

            require(asset != address(0), "oracle cfg: asset=0");
            require(feed != address(0), "oracle cfg: feed=0");
            require(maxStalePeriod > 0, "oracle cfg: maxStalePeriod=0");
            require(enableMain, "oracle cfg: enableMain must be true");

            if (enablePivot) require(pivotOracle != address(0), "oracle cfg: pivotOracle=0");
            if (enableFallback) require(fallbackOracle != address(0), "oracle cfg: fallbackOracle=0");

            console.log("\n=== Asset ===");
            console.log("asset:", asset);
            console.log("feed:", feed);
            console.log("maxStalePeriod:", maxStalePeriod);
            console.log("enableMain:", enableMain);
            console.log("enablePivot:", enablePivot);
            console.log("enableFallback:", enableFallback);

            // 1) ChainlinkOracle feed config
            // ? As we expand to other Oracle Types beyond ChainlinkOracle, we will need a switch case here.
            IChainlinkOracleAdmin.TokenConfig memory clCfg =
                IChainlinkOracleAdmin.TokenConfig({asset: asset, feed: feed, maxStalePeriod: maxStalePeriod});
            _proxyCall(mainOracle, abi.encodeCall(IChainlinkOracleAdmin.setTokenConfig, (clCfg)));
            console.log("OK: MainOracle.setTokenConfig");

            // 2) BoundValidator bounds (required whenever pivot/fallback validation may occur)
            if (enablePivot || enableFallback) {
                uint256 upper = vm.parseJsonUint(json, string.concat(base, ".bounds.upperBoundRatio"));
                uint256 lower = vm.parseJsonUint(json, string.concat(base, ".bounds.lowerBoundRatio"));
                require(upper > 0 && lower > 0, "oracle cfg: bounds must be positive");
                require(upper > lower, "oracle cfg: upper must be > lower");

                IBoundValidatorAdmin.ValidateConfig memory bCfg =
                    IBoundValidatorAdmin.ValidateConfig({asset: asset, upperBoundRatio: upper, lowerBoundRatio: lower});
                _proxyCall(boundValidator, abi.encodeCall(IBoundValidatorAdmin.setValidateConfig, (bCfg)));
                console.log("OK: BoundValidator.setValidateConfig");
            } else {
                console.log("SKIP: bounds (pivot/fallback disabled)");
            }

            // 3) ResilientOracle token config
            IResilientOracleAdmin.TokenConfig memory rCfg;
            rCfg.asset = asset;
            rCfg.oracles[0] = mainOracle;
            rCfg.oracles[1] = pivotOracle;
            rCfg.oracles[2] = fallbackOracle;
            rCfg.enableFlagsForOracles[0] = enableMain;
            rCfg.enableFlagsForOracles[1] = enablePivot;
            rCfg.enableFlagsForOracles[2] = enableFallback;
            rCfg.cachingEnabled = cachingEnabled;

            _proxyCall(resilientOracle, abi.encodeCall(IResilientOracleAdmin.setTokenConfig, (rCfg)));
            console.log("OK: ResilientOracle.setTokenConfig");

            // Optional: register ticker in OracleHelper (convenience mapping used elsewhere in protocol).
            if (vm.keyExistsJson(json, string.concat(base, ".ticker"))) {
                string memory ticker = vm.parseJsonString(json, string.concat(base, ".ticker"));
                require(bytes(ticker).length > 0, "oracle cfg: ticker empty");
                _proxyCall(oracleHelper, abi.encodeCall(IOracleHelperAdmin.registerTicker, (ticker, asset)));
                console.log("OK: OracleHelper.registerTicker");
            }

            // Mark this asset config as applied with a boolean flag in the config file.
            // (Avoids any reliance on tx hash/broadcast metadata.)
            try vm.writeJson("true", path, configuredKey) {
                console.log("WROTE: configured=true");
            } catch {
                console.log("WARN: failed to write configured=true to config (path/key may be invalid)");
            }
        }

        vm.stopBroadcast();

        console.log("\nOK: oracle configured");
    }

    function _jsonBoolOr(string memory json, string memory key, bool defaultValue) private view returns (bool) {
        if (!vm.keyExistsJson(json, key)) return defaultValue;
        return vm.parseJsonBool(json, key);
    }

    function _jsonAddressOr(string memory json, string memory key, address defaultValue)
        private
        view
        returns (address)
    {
        if (!vm.keyExistsJson(json, key)) return defaultValue;
        return vm.parseJsonAddress(json, key);
    }

    function _containsAddress(address[] memory xs, address x) private pure returns (bool) {
        for (uint256 i = 0; i < xs.length; i++) {
            if (xs[i] == x) return true;
        }
        return false;
    }

    function _parseAddressCsv(string memory csv) private pure returns (address[] memory out) {
        bytes memory b = bytes(csv);
        if (b.length == 0) return new address[](0);

        uint256 count = 1;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == bytes1(",")) count++;
        }

        out = new address[](count);
        uint256 outIdx = 0;
        uint256 start = 0;

        for (uint256 i = 0; i <= b.length; i++) {
            if (i == b.length || b[i] == bytes1(",")) {
                string memory token = _trim(_substring(b, start, i));
                if (bytes(token).length == 0) revert("oracle cfg: empty ORACLE_ASSET_FILTER token");
                out[outIdx++] = vm.parseAddress(token);
                start = i + 1;
            }
        }

        assembly ("memory-safe") {
            mstore(out, outIdx)
        }
        return out;
    }

    function _trim(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 i = 0;
        uint256 j = b.length;

        while (i < j && (b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0a || b[i] == 0x0d)) i++;
        while (j > i && (b[j - 1] == 0x20 || b[j - 1] == 0x09 || b[j - 1] == 0x0a || b[j - 1] == 0x0d)) j--;

        return _substring(b, i, j);
    }

    function _substring(bytes memory b, uint256 start, uint256 end) private pure returns (string memory) {
        require(end >= start, "oracle cfg: bad substring");
        bytes memory out = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = b[i];
        }
        return string(out);
    }

}


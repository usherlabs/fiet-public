// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * ConfigureOracle.s.sol
 *
 * - Configures Venus `ResilientOracle` token configs (enables MAIN oracle) for a pair of underlying assets, and (optionally)
 *   sets mock prices on the MAIN oracle (LOCAL/dev).
 *
 * Required env vars:
 * - RESILIENT_ORACLE_ADDRESS: Address of the deployed ResilientOracle proxy to configure.
 * - UNDERLYING_ASSET_0: First underlying asset address to configure.
 * - UNDERLYING_ASSET_1: Second underlying asset address to configure.
 *
 * Optional env vars (*):
 * - MAIN_ORACLE_ADDRESS*: Address of the MAIN oracle contract used by ResilientOracle for both assets.
 *   - If not set, defaults to `../evm/deployments/oracle_deployments/development/ChainlinkOracle_Proxy.json` (hardhat-deploy output).
 *
 * - ORACLE_CACHING_ENABLED*: 1 to set `cachingEnabled=true` in the ResilientOracle token configs (default 0).
 *
 * Notes:
 * - This script is intentionally separate from `create-market` because it mutates global oracle state and may require admin permissions.
 */
import "forge-std/Script.sol";

import {NetworkConfig} from "../base/NetworkConfig.sol";
import {EthSepoliaConstants} from "../constants/EthSepolia.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";

interface IResilientOracleAdmin {
    struct TokenConfig {
        address asset;
        address[3] oracles; // [main, pivot, fallback]
        bool[3] enableFlagsForOracles;
        bool cachingEnabled;
    }

    function setTokenConfig(TokenConfig calldata tokenConfig) external;
}

/// @dev Local/dev `MockChainlinkOracle`-style price setter.
interface IOracleMockPrice {
    function setPrice(address asset, uint256 price) external;
}

/**
 * @title ConfigureOracleScript
 * @notice Configures the locally deployed Venus ResilientOracle so `MarketFactory.createMarket()` can pass oracle validation.
 *
 * How oracle configuration works in this repo:
 *
 * - If `MODE=LOCAL`:
 *   - `just deploy-oracle` deploys the Venus oracle stack using Hardhat `--network development`, which sets `live=false`.
 *   - As a result, `ChainlinkOracle_Proxy` is a proxy to the dev `MockChainlinkOracle` implementation.
 *   - You still need to run `just configure-oracle` to enable MAIN in `ResilientOracle` and set mock prices
 *     via `setPrice(asset, price)` (this script sets `1e18`).
 *
 * - If `MODE!=LOCAL` (i.e. non-dev / live-like environments):
 *   - The MAIN oracle is expected to be a real feed-backed oracle (e.g. Venus `ChainlinkOracle` /
 *     `SequencerChainlinkOracle`), so you must configure the feed mapping first via `ChainlinkOracle.setTokenConfig(...)`
 *     for each underlying, before (or alongside) enabling MAIN in `ResilientOracle`.
 *   - `ChainlinkOracle.TokenConfig` is:
 *     struct TokenConfig {
 *         address asset;
 *         address feed;
 *         uint256 maxStalePeriod;
 *     }
 *
 * In all modes, this script configures `ResilientOracle.TokenConfig` to enable MAIN for each underlying asset.
 */
contract ConfigureOracleScript is NetworkConfig {
    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        _initNetwork();

        string memory mode = vm.envOr("MODE", string("LOCAL"));

        // Required: resilient oracle proxy address (written by `just deploy-oracle`)
        address resilientOracle = vm.envAddress("RESILIENT_ORACLE_ADDRESS");

        // MAIN oracle address (for LOCAL/dev, this is typically ChainlinkOracle_Proxy which points to a mock oracle implementation)
        address mainOracle;
        bool hasMainOracleEnv = vm.envExists("MAIN_ORACLE_ADDRESS");
        if (hasMainOracleEnv) {
            mainOracle = vm.envAddress("MAIN_ORACLE_ADDRESS");
        } else {
            // Default is only safe for LOCAL/dev. For non-LOCAL deployments, require explicit wiring.
            if (keccak256(bytes(mode)) != keccak256(bytes("LOCAL"))) {
                revert("ConfigureOracle: set MAIN_ORACLE_ADDRESS for non-LOCAL mode");
            }
            // ChainlinkOracle_Proxy is deployed by Hardhat (oracle submodule), and the implementation it points to is MockChainlinkOracle in contracts/evm/lib/oracle/contracts/oracles/mocks/MockChainlinkOracle.sol.
            // The implementation metadata for that address is the mock oracle contract: contracts/evm/deployments/oracle_deployments/development/ChainlinkOracle_Implementation.json
            string memory chainlinkJson = "../evm/deployments/oracle_deployments/development/ChainlinkOracle_Proxy.json";
            mainOracle = vm.parseJsonAddress(vm.readFile(chainlinkJson), ".address");
        }

        // Underlyings: reuse the same env names as CreateMarket.
        address asset0;
        address asset1;
        if (vm.envExists("UNDERLYING_ASSET_0")) {
            asset0 = vm.envAddress("UNDERLYING_ASSET_0");
        }
        if (vm.envExists("UNDERLYING_ASSET_1")) {
            asset1 = vm.envAddress("UNDERLYING_ASSET_1");
        }

        // If neither is provided, force the user to be explicit (this script is meant to work for arbitrary markets).
        if (asset0 == address(0) || asset1 == address(0)) {
            revert("ConfigureOracle: set UNDERLYING_ASSET_0 and UNDERLYING_ASSET_1");
        }
        require(asset0 != asset1, "ConfigureOracle: UNDERLYING_ASSET_0/1 must differ");

        console.log("Configuring oracle for MODE:", mode);
        console.log("ResilientOracle:", resilientOracle);
        console.log("MAIN oracle:", mainOracle);
        console.log("Asset0:", asset0);
        console.log("Asset1:", asset1);

        // IMPORTANT: these admin calls must be sent from the deployer EOA that has ACM permissions,
        // not from the script contract address.
        vm.startBroadcast(deployerPrivateKey);

        // In LOCAL mode, set deterministic "1" prices for the underlying assets (so oracle checks can pass).
        // We assume MAIN oracle is the dev `MockChainlinkOracle` proxy, which exposes `setPrice(address,uint256)`.
        if (keccak256(bytes(mode)) == keccak256(bytes("LOCAL"))) {
            uint256 price = 1e18;
            console.log("Setting mock prices for underlying assets in LOCAL mode");
            console.log("price:", price);
            IOracleMockPrice(mainOracle).setPrice(asset0, price);
            IOracleMockPrice(mainOracle).setPrice(asset1, price);
        }

        // if not in dev mode we would need to call ChainlinkOracle.setTokenConfig(...) for each underlying, before (or alongside) enabling MAIN in ResilientOracle.
        // ChainlinkOracle.TokenConfig is:
        // struct TokenConfig {
        //     address asset;
        //     address feed;
        //     uint256 maxStalePeriod;
        // }

        // Enable MAIN oracle for each asset in the resilient oracle.
        IResilientOracleAdmin.TokenConfig memory cfg;
        cfg.oracles[0] = mainOracle; // MAIN
        cfg.enableFlagsForOracles[0] = true; // MAIN enabled
        cfg.cachingEnabled = vm.envOr("ORACLE_CACHING_ENABLED", uint256(0)) != 0;

        cfg.asset = asset0;
        IResilientOracleAdmin(resilientOracle).setTokenConfig(cfg);

        cfg.asset = asset1;
        IResilientOracleAdmin(resilientOracle).setTokenConfig(cfg);

        vm.stopBroadcast();

        console.log("Oracle configured: MAIN enabled for asset0/asset1");
    }
}


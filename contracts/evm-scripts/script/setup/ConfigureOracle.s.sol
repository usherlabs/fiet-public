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

/**
 * @title ConfigureOracleScript
 * @notice Configures the locally deployed Venus ResilientOracle so `MarketFactory.createMarket()` can pass oracle validation.
 *
 * What it does (LOCAL mode):
 * - Reads `RESILIENT_ORACLE_ADDRESS` from env (written by `just deploy-oracle`)
 * - Loads the local Hardhat deployment address of `ChainlinkOracle_Proxy` (which is a proxy to `MockChainlinkOracle` in dev)
 * - Sets mock prices for the default CreateMarket pair (USDC/WETH) on the mock chainlink oracle
 * - Sets `ResilientOracle.TokenConfig` for each asset, enabling MAIN oracle
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
            // Default: local hardhat oracle deploy output path
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

        console.log("Configuring oracle for MODE:", mode);
        console.log("ResilientOracle:", resilientOracle);
        console.log("MAIN oracle:", mainOracle);
        console.log("Asset0:", asset0);
        console.log("Asset1:", asset1);

        // IMPORTANT: these admin calls must be sent from the deployer EOA that has ACM permissions,
        // not from the script contract address.
        vm.startBroadcast(deployerPrivateKey);

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


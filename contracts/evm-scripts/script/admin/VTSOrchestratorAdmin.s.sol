// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * Admin: VTSOrchestrator owner functions
 *
 * Includes:
 * - pausePool/unpausePool (already exist via PauseMarketScript; included here for completeness)
 * - setGlobalPause
 * - setMarketVTSConfiguration (from an explicit config file)
 *
 * Run:
 * - `just admin-vts-set-global-pause`
 * - `just admin-vts-set-market-config`
 *
 * Env:
 * - PRIVATE_KEY
 * - NETWORK
 * - CORE_POOL_ID: bytes32 (for per-pool operations)
 * - PAUSED: 0|1 (for setGlobalPause)
 *
 * Required VTS config input:
 * - VTS_CONFIG_FILE_PATH: path to a JSON or TOML file containing VTS config fields.
 *   - JSON keys should match the struct field names (e.g. `.token0.gracePeriodTime`).
 *   - TOML keys should match the struct field names (e.g. `token0.gracePeriodTime`).
 *   - All fields must be present; the loader does not apply fallback defaults.
 */

import {console} from "forge-std/Script.sol";
import {AdminBase} from "./AdminBase.sol";
import {VTSConfigFileBase} from "../base/VTSConfigFileBase.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {MarketVTSConfiguration} from "src/types/VTS.sol";

interface IOwnableView {
    function owner() external view returns (address);
}

interface IPausableVTSOwner {
    function pausePool(PoolId poolId) external;
    function unpausePool(PoolId poolId) external;
    function setGlobalPause(bool paused) external;
}

interface IVTSConfigOwner {
    function setMarketVTSConfiguration(PoolId corePoolId, MarketVTSConfiguration memory cfg) external;
}

contract VTSSetGlobalPauseScript is AdminBase {
    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        bool paused = vm.envUint("PAUSED") != 0;

        _loadAdminAddresses();

        address owner = IOwnableView(vtsOrchestrator).owner();
        console.log("NETWORK:", networkName);
        console.log("VTSOrchestrator:", vtsOrchestrator);
        console.log("owner:", owner);
        console.log("GlobalConfig:", globalConfig);
        console.log("PAUSED:", paused);

        vm.startBroadcast(pk);
        if (owner == globalConfig) {
            _proxyCall(vtsOrchestrator, abi.encodeCall(IPausableVTSOwner.setGlobalPause, (paused)));
        } else {
            IPausableVTSOwner(vtsOrchestrator).setGlobalPause(paused);
        }
        vm.stopBroadcast();

        console.log("OK: setGlobalPause");
    }
}

contract VTSSetMarketConfigScript is AdminBase, VTSConfigFileBase {
    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        PoolId corePoolId = PoolId.wrap(vm.envBytes32("CORE_POOL_ID"));

        _loadAdminAddresses();

        address owner = IOwnableView(vtsOrchestrator).owner();
        (MarketVTSConfiguration memory cfg, string memory cfgSource) = _loadVTSConfig();

        console.log("NETWORK:", networkName);
        console.log("VTSOrchestrator:", vtsOrchestrator);
        console.log("owner:", owner);
        console.log("GlobalConfig:", globalConfig);
        console.log("CORE_POOL_ID:", vm.toString(PoolId.unwrap(corePoolId)));
        console.log("VTS_CONFIG_SOURCE:", cfgSource);

        vm.startBroadcast(pk);
        if (owner == globalConfig) {
            _proxyCall(vtsOrchestrator, abi.encodeCall(IVTSConfigOwner.setMarketVTSConfiguration, (corePoolId, cfg)));
        } else {
            IVTSConfigOwner(vtsOrchestrator).setMarketVTSConfiguration(corePoolId, cfg);
        }
        vm.stopBroadcast();

        console.log("OK: setMarketVTSConfiguration");
    }
}


// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * Admin: ProxyCall (generic)
 *
 * Calls `GlobalConfig.proxyCall(target, calldata)` as the GlobalConfig owner.
 *
 * Run:
 * - `just admin-proxy-call`
 *
 * Env:
 * - PRIVATE_KEY: admin EOA (must be GlobalConfig owner)
 * - NETWORK: deployments/<network>_deployments.json selector (for reading globalConfig)
 * - TARGET: contract to call
 * - CALLDATA: ABI-encoded calldata (0x...)
 */

import {console} from "forge-std/Script.sol";
import {AdminBase} from "./AdminBase.sol";

contract AdminProxyCallScript is AdminBase {
    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address target = vm.envAddress("TARGET");
        bytes memory data = vm.envBytes("CALLDATA");

        _loadAdminAddresses();

        console.log("NETWORK:", networkName);
        console.log("GlobalConfig:", globalConfig);
        console.log("TARGET:", target);
        console.log("CALLDATA bytes length:", data.length);

        vm.startBroadcast(pk);
        bytes memory result = _proxyCall(target, data);
        vm.stopBroadcast();

        console.log("proxyCall OK, return bytes length:", result.length);
    }
}


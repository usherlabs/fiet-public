// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * Admin: MarketFactory.setHooks(coreHook)
 *
 * Notes:
 * - `MarketFactory.setHooks` is `onlyOwner` and is typically owned by `GlobalConfig`.
 * - This script routes the call via `GlobalConfig.proxyCall`.
 *
 * Run:
 * - `just admin-marketfactory-set-hooks`
 *
 * Env:
 * - PRIVATE_KEY: admin EOA (must be GlobalConfig owner)
 * - NETWORK: deployments/<network>_deployments.json selector
 * - CORE_HOOK: (optional) core hook address; defaults to `deployments` key `coreHook`
 */

import {console} from "forge-std/Script.sol";
import {AdminBase} from "./AdminBase.sol";

interface IMarketFactoryAdmin {
    function setHooks(address coreHook) external;
}

contract MarketFactorySetHooksScript is AdminBase {
    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));

        _loadAdminAddresses();

        address coreHook;
        if (vm.envExists("CORE_HOOK")) {
            coreHook = vm.envAddress("CORE_HOOK");
        } else {
            coreHook = readAddress("coreHook");
        }

        console.log("NETWORK:", networkName);
        console.log("GlobalConfig:", globalConfig);
        console.log("MarketFactory:", marketFactory);
        console.log("CORE_HOOK:", coreHook);

        vm.startBroadcast(pk);
        _proxyCall(marketFactory, abi.encodeCall(IMarketFactoryAdmin.setHooks, (coreHook)));
        vm.stopBroadcast();

        console.log("OK: setHooks");
    }
}


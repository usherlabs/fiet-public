// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * Admin: LiquidityHub.setFactory(factory, enabled)
 *
 * Run:
 * - `just admin-liquidityhub-set-factory`
 *
 * Env:
 * - PRIVATE_KEY
 * - NETWORK
 * - FACTORY: address
 * - ENABLED: 0|1
 */

import {console} from "forge-std/Script.sol";
import {AdminBase} from "./AdminBase.sol";

interface ILiquidityHubAdmin {
    function setFactory(address factory, bool enabled) external;
}

contract LiquidityHubSetFactoryScript is AdminBase {
    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address factory = vm.envAddress("FACTORY");
        bool enabled = vm.envUint("ENABLED") != 0;

        _loadAdminAddresses();

        console.log("NETWORK:", networkName);
        console.log("GlobalConfig:", globalConfig);
        console.log("LiquidityHub:", liquidityHub);
        console.log("FACTORY:", factory);
        console.log("ENABLED:", enabled);

        vm.startBroadcast(pk);
        _proxyCall(liquidityHub, abi.encodeCall(ILiquidityHubAdmin.setFactory, (factory, enabled)));
        vm.stopBroadcast();

        console.log("OK: setFactory");
    }
}


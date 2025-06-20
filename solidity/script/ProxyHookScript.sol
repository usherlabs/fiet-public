// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {ProxyHook} from "../src/ProxyHook.sol";

/**
 * To deploy proxy hook (e.g. for ETH/USDC), following pools need to be deployed first.
 * - Itokens and ERC20 tokens,
 * - Proxy pool: Uniswap v4 pool with ERC20 standard token,
 * - Core pool: Uniswap v4 pool with non-compitable intent token.
 */
contract ProxyHookScript is Script {
    ProxyHook proxyHook;

    function run() external {
        vm.startBroadcast();
        //proxyHook = new ProxyHook();
        vm.stopBroadcast();
    }
}

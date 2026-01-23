// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * Admin: OracleHelper.registerTicker(ticker, asset)
 *
 * Run:
 * - `just admin-oraclehelper-register-ticker`
 *
 * Env:
 * - PRIVATE_KEY
 * - NETWORK
 * - TICKER: string (e.g. "BTC")
 * - ASSET: address
 */

import {console} from "forge-std/Script.sol";
import {AdminBase} from "./AdminBase.sol";

interface IOracleHelperAdmin {
    function registerTicker(string calldata ticker, address asset) external;
}

contract OracleHelperRegisterTickerScript is AdminBase {
    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        string memory ticker = vm.envString("TICKER");
        address asset = vm.envAddress("ASSET");

        _loadAdminAddresses();

        console.log("NETWORK:", networkName);
        console.log("OracleHelper:", oracleHelper);
        console.log("TICKER:", ticker);
        console.log("ASSET:", asset);

        vm.startBroadcast(pk);
        _proxyCall(oracleHelper, abi.encodeCall(IOracleHelperAdmin.registerTicker, (ticker, asset)));
        vm.stopBroadcast();

        console.log("OK: registerTicker");
    }
}


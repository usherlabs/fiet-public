// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {ScriptHelper} from "./libraries/ScriptHelper.s.sol";

contract PauseMarketScript is ScriptHelper {
    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        string memory networkName = vm.envString("NETWORK"); // "sepolia" | "arbitrum"
        bytes32 poolIdBytes = vm.envBytes32("POOL_ID");
        uint256 pauseFlag = vm.envUint("PAUSE"); // 0 for unpause, 1 for pause

        PoolId poolId = PoolId.wrap(poolIdBytes);

        _setFilename(networkName);
        address marketFactory = readAddress("marketFactory");
        console.log("MarketFactory:", marketFactory);

        vm.startBroadcast(deployerPrivateKey);

        if (pauseFlag == 1) {
            MarketFactory(marketFactory).pause(poolId);
            console.log("Paused market:", vm.toString(PoolId.unwrap(poolId)));
        } else if (pauseFlag == 0) {
            MarketFactory(marketFactory).unpause(poolId);
            console.log("Unpaused market:", vm.toString(PoolId.unwrap(poolId)));
        } else {
            revert("Invalid PAUSE flag");
        }

        vm.stopBroadcast();
    }
}

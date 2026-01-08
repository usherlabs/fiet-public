// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {VTSOrchestrator} from "src/VTSOrchestrator.sol";
import {FileHelper} from "./base/FileHelper.sol";

interface IHasVTSOrchestrator {
    function vtsOrchestrator() external view returns (address);
}

interface IGlobalConfig {
    function proxyCall(address target, bytes calldata data) external returns (bytes memory result);
}

interface IPausableVTSAdmin {
    function pausePool(PoolId poolId) external;
    function unpausePool(PoolId poolId) external;
}

contract PauseMarketScript is FileHelper {
    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        address caller = vm.addr(deployerPrivateKey);
        string memory networkName = vm.envString("NETWORK"); // "sepolia" | "arbitrum"
        bytes32 poolIdBytes = vm.envBytes32("CORE_POOL_ID");
        uint256 pauseFlag = vm.envUint("PAUSE"); // 0 for unpause, 1 for pause

        PoolId poolId = PoolId.wrap(poolIdBytes);

        _setFilename(networkName);
        // `deployments/<network>_deployments.json` does not always include `vtsOrchestrator`.
        // However, `MarketFactory` stores it as an immutable with a public getter.
        address marketFactory = readAddress("marketFactory");
        address globalConfig = readAddress("globalConfig");
        address vtsOrchestrator = IHasVTSOrchestrator(marketFactory).vtsOrchestrator();
        address vtsOwner = VTSOrchestrator(vtsOrchestrator).owner();
        console.log("VTSOrchestrator:", vtsOrchestrator);
        console.log("Caller:", caller);
        console.log("VTSOrchestrator owner:", vtsOwner);
        console.log("GlobalConfig:", globalConfig);

        vm.startBroadcast(deployerPrivateKey);

        if (pauseFlag == 1) {
            if (vtsOwner == globalConfig) {
                IGlobalConfig(globalConfig)
                    .proxyCall(vtsOrchestrator, abi.encodeCall(IPausableVTSAdmin.pausePool, (poolId)));
            } else {
                VTSOrchestrator(vtsOrchestrator).pausePool(poolId);
            }
            console.log("Paused market:", vm.toString(PoolId.unwrap(poolId)));
        } else if (pauseFlag == 0) {
            if (vtsOwner == globalConfig) {
                IGlobalConfig(globalConfig)
                    .proxyCall(vtsOrchestrator, abi.encodeCall(IPausableVTSAdmin.unpausePool, (poolId)));
            } else {
                VTSOrchestrator(vtsOrchestrator).unpausePool(poolId);
            }
            console.log("Unpaused market:", vm.toString(PoolId.unwrap(poolId)));
        } else {
            revert("Invalid PAUSE flag");
        }

        vm.stopBroadcast();
    }
}

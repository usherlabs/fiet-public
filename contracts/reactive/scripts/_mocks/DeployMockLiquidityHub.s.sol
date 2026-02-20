// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MockLiquidityHub} from "test/_mocks/MockLiquidityHub.sol";

/// @notice Deploys the MockLiquidityHub for testnet use.
contract DeployMockLiquidityHub is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        MockLiquidityHub hub = new MockLiquidityHub();
        vm.stopBroadcast();

        // ensure to log the address of the deployed contract
        // using the format contract_name:address
        // that way it can be parsed from the stdout of the script execution
        console2.log("MockLiquidityHub:", address(hub));
    }
}

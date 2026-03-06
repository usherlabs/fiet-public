// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

contract TeardownDelegation is Script {
    function run() external view returns (string memory suggestedCastCommand) {
        address eoa = vm.envAddress("EOA");

        bool clearDelegation = vm.envOr("CLEAR_DELEGATION", uint256(0)) == 1;
        address newImpl = vm.envOr("NEW_IMPL", address(0));
        uint256 gasLimit = vm.envOr("TEARDOWN_GAS_LIMIT", uint256(100_000));
        address targetImpl = clearDelegation ? address(0) : newImpl;
        require(clearDelegation || targetImpl != address(0), "Provide NEW_IMPL or set CLEAR_DELEGATION=1");

        suggestedCastCommand = string.concat(
            "cast send ",
            vm.toString(eoa),
            " --auth ",
            vm.toString(targetImpl),
            " --gas-limit ",
            vm.toString(gasLimit),
            " --rpc-url $ARB_MAINNET_RPC_URL --private-key $LP_PRIVATE_KEY"
        );

        console2.log("EOA:", eoa);
        if (clearDelegation) {
            console2.log("Teardown action: clear delegation and restore empty EOA code");
        } else {
            console2.log("Teardown implementation target:", targetImpl);
        }
        console2.log("Gas limit:", gasLimit);
        console2.log("Suggested command:");
        console2.log(suggestedCastCommand);
    }
}

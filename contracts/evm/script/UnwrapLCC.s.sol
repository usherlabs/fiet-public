// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract UnwrapLCCScript is Script {
    function run() external {
        uint256 privateKey = uint256(vm.envBytes32("LP_PRIVATE_KEY"));
        address wallet = vm.addr(privateKey);

        address lccAddress = vm.envAddress("LCC_ADDRESS");

        LiquidityCommitmentCertificate lcc = LiquidityCommitmentCertificate(lccAddress);

        uint256 balance = IERC20(lccAddress).balanceOf(wallet);

        if (balance == 0) {
            console.log("No LCC tokens to unwrap.");
            return;
        }

        vm.startBroadcast(privateKey);
        lcc.unwrap(balance);
        vm.stopBroadcast();

        console.log("Unwrapped %s LCC tokens to underlying asset.", balance);
    }
}

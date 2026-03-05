// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {LiquidityCommitmentCertificate} from "src/LCC.sol";
import {ILiquidityHub} from "src/interfaces/ILiquidityHub.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FileHelper} from "./base/FileHelper.sol";

/**
 * @notice Unwraps the caller’s full LCC balance into the underlying via `LiquidityHub.unwrap`.
 *
 * Env vars
 * - REQUIRED:
 *   - `LP_PRIVATE_KEY`: key holding the LCC balance
 *   - `LCC_ADDRESS`: LCC token to unwrap
 * - OPTIONAL:
 *   - `NETWORK`: deployment namespace (default: `sepolia`)
 */
contract UnwrapLCCScript is FileHelper {
    function run() external {
        uint256 privateKey = uint256(vm.envBytes32("LP_PRIVATE_KEY"));
        address wallet = vm.addr(privateKey);

        address lccAddress = vm.envAddress("LCC_ADDRESS");

        // Get LiquidityHub address from deployment
        string memory networkName = vm.envOr("NETWORK", string("sepolia"));
        _setFilename(networkName);
        address liquidityHubAddr = readAddress("liquidityHub");
        ILiquidityHub liquidityHub = ILiquidityHub(liquidityHubAddr);

        uint256 balance = IERC20(lccAddress).balanceOf(wallet);

        if (balance == 0) {
            console.log("No LCC tokens to unwrap.");
            return;
        }

        vm.startBroadcast(privateKey);
        // Use LiquidityHub to unwrap LCC to underlying
        liquidityHub.unwrap(lccAddress, balance);
        vm.stopBroadcast();

        console.log("Unwrapped %s LCC tokens to underlying asset.", balance);
    }
}

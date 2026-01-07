// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console, Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC20Mintable {
    function mint(address to, uint256 amount) external;
}

/**
 * MintMockERC20.s.sol
 *
 * One-liner:
 * - Funds the "current" account with large balances of `UNDERLYING_ASSET_0` and `UNDERLYING_ASSET_1`.
 *
 * How it works:
 * - Reads token addresses from env: UNDERLYING_ASSET_0 / UNDERLYING_ASSET_1
 * - Uses PRIVATE_KEY as the funding account (tx sender)
 * - Determines the recipient as:
 *   - RECIPIENT_ADDRESS* if set, else
 *   - LP_PRIVATE_KEY* address if set, else
 *   - PRIVATE_KEY address
 * - If the token supports `mint(address,uint256)`, it mints `AMOUNT` (default: max uint256 / 2)
 * - Otherwise, it transfers as much as possible from the funding account balance (up to AMOUNT)
 *
 * Required env vars:
 * - PRIVATE_KEY
 * - UNDERLYING_ASSET_0
 * - UNDERLYING_ASSET_1
 *
 * Optional env vars (*):
 * - RECIPIENT_ADDRESS*
 * - LP_PRIVATE_KEY*
 * - AMOUNT* (defaults to type(uint256).max / 2)
 */
contract MintMockERC20Script is Script {
    function run() external {
        uint256 funderPk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address funder = vm.addr(funderPk);

        address token0 = vm.envAddress("UNDERLYING_ASSET_0");
        address token1 = vm.envAddress("UNDERLYING_ASSET_1");
        require(token0 != address(0) && token1 != address(0), "token is zero");
        require(token0 != token1, "tokens must be different");

        address recipient;
        if (vm.envExists("RECIPIENT_ADDRESS")) {
            recipient = vm.envAddress("RECIPIENT_ADDRESS");
        } else if (vm.envExists("LP_PRIVATE_KEY")) {
            uint256 lpPk = uint256(vm.envBytes32("LP_PRIVATE_KEY"));
            recipient = vm.addr(lpPk);
        } else {
            recipient = funder;
        }
        require(recipient != address(0), "recipient is zero");

        uint256 amount = vm.envOr("AMOUNT", type(uint256).max / 2);

        console.log("Funding account:", funder);
        console.log("Recipient:", recipient);
        console.log("Token0:", token0);
        console.log("Token1:", token1);
        console.log("Target amount:", amount);

        vm.startBroadcast(funderPk);
        _fundToken(token0, funder, recipient, amount);
        _fundToken(token1, funder, recipient, amount);
        vm.stopBroadcast();
    }

    function _fundToken(address token, address funder, address recipient, uint256 amount) internal {
        // Try minting (works for some mocks).
        try IERC20Mintable(token).mint(recipient, amount) {
            console.log("Minted to recipient for token:", token);
            return;
        } catch {
            // Fallback: transfer from funder balance (works for OZ ERC20 mocks deployed with initial supply).
            uint256 bal = IERC20(token).balanceOf(funder);
            require(bal > 0, "funder has zero balance for token");
            uint256 sendAmount = bal < amount ? bal : amount;
            bool ok = IERC20(token).transfer(recipient, sendAmount);
            require(ok, "transfer failed");
            console.log("Transferred to recipient for token:", token);
        }
    }
}

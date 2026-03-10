// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {NetworkConfig} from "../base/NetworkConfig.sol";

// ? This will default to 18 decimals, but we can override it for testing purposes when required.
contract Token is ERC20 {
    constructor(string memory name, string memory symbol, uint256 initialSupply) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
    }

    /// @dev Test-only mint helper (intentionally permissionless).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Deploying mock USDT / USDC token
contract TokenScriptUSDT is NetworkConfig {
    Token token;

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        vm.startBroadcast(deployerPrivateKey);
        token = new Token("Mock USDT", "USDT", 100000 ether); // initial supply = 100,000 ether
        vm.stopBroadcast();

        _initNetwork();
        writeAddress("usdtToken", address(token));
    }
}

contract TokenScriptUSDC is NetworkConfig {
    Token token;

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        vm.startBroadcast(deployerPrivateKey);
        token = new Token("Mock USDC", "USDC", 100000 ether); // initial supply = 100,000 ether
        vm.stopBroadcast();

        _initNetwork();
        writeAddress("usdcToken", address(token));
    }
}

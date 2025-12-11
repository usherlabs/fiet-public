// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ScriptHelper} from "../libraries/ScriptHelper.s.sol";

// ? This will default to 18 decimals, but we can override it for testing purposes when required.
contract Token is ERC20 {
    constructor(string memory name, string memory symbol, uint256 initialSupply) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
    }
}

/// Deploying mock USDT / USDC token
contract TokenScriptUSDT is ScriptHelper {
    Token token;

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        vm.startBroadcast(deployerPrivateKey);
        token = new Token("Mock USDT", "USDT", 100000 ether); // initial supply = 100,000 ether
        vm.stopBroadcast();

        _setFilename("sepolia");
        writeAddress("usdtToken", address(token));
    }
}

contract TokenScriptUSDC is ScriptHelper {
    Token token;

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        vm.startBroadcast(deployerPrivateKey);
        token = new Token("Mock USDC", "USDC", 100000 ether); // initial supply = 100,000 ether
        vm.stopBroadcast();

        _setFilename("sepolia");
        writeAddress("usdcToken", address(token));
    }
}

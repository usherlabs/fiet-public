// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {IToken} from "../src/IToken.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SepoliaConstants} from "./constants.sol";

contract Token is ERC20 {
    constructor(string memory name, string memory symbol, uint256 initialSupply) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
    }
}

/// Deploying mock USDT token
contract TokenScript is Script {
    Token token;

    function run() external {
        vm.startBroadcast();
        token = new Token("Mock USDT", "USDT", 100000 ether); // initial supply = 100,000 ether
        vm.stopBroadcast();
    }
}

contract ITokenUSDTScript is Script {
    IToken token;
    address underlying_asset = SepoliaConstants.TokenA;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        token = new IToken("Mock LCC USDT", "LCC USDT", underlying_asset, 10_000); // base = 100%
        vm.stopBroadcast();
    }
}

contract ITokenUSDCScript is Script {
    IToken token;
    address underlying_asset = SepoliaConstants.TokenB;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        token = new IToken("Mock LCC USDC", "LCC USDC", underlying_asset, 10_000); // base = 100%
        vm.stopBroadcast();
    }
}

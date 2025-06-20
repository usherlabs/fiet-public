// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {IToken} from "../src/IToken.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

contract ITokenScript is Script {
    IToken token;
    address underlying_asset = 0x99729dD47ACdA1713171501250E57a36aDCE5D08;

    function run() external {
        vm.startBroadcast();
        token = new IToken("Mock LCC USDT", "LCC USDT", underlying_asset, 10); // base = 10 bps
        vm.stopBroadcast();
    }
}

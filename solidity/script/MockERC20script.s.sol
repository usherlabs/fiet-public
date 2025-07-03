// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IToken} from "../src/IToken.sol";
import {Script, console} from "forge-std/Script.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SepoliaConstants} from "./constants.sol";
import {ScriptHelper} from "./deployments/ScriptHelper.s.sol";

contract Token is ERC20 {
    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply
    ) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
    }
}

/// Deploying mock USDT token
contract TokenScriptUSDT is ScriptHelper {
    Token token;

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        vm.startBroadcast(deployerPrivateKey);
        token = new Token("Mock USDT", "USDT", 100000 ether); // initial supply = 100,000 ether
        vm.stopBroadcast();

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

        writeAddress("usdcToken", address(token));
    }
}

contract ITokenUSDTScript is ScriptHelper {
    IToken token;

    function run() external {
        address underlyingAsset = readAddress("usdtToken");
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        vm.startBroadcast(deployerPrivateKey);
        token = new IToken(
            "Mock LCC USDT",
            "LCC USDT",
            underlyingAsset,
            10_000
        ); // base = 100%

        vm.stopBroadcast();
        writeAddress("lccTokenUSDT", address(token));
    }
}

contract ITokenUSDCScript is ScriptHelper {
    IToken token;

    function run() external {
        address underlyingAsset = readAddress("usdcToken");
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        vm.startBroadcast(deployerPrivateKey);
        token = new IToken(
            "Mock LCC USDC",
            "LCC USDC",
            underlyingAsset,
            10_000
        ); // base = 100%
        vm.stopBroadcast();
        writeAddress("lccTokenUSDC", address(token));
    }
}

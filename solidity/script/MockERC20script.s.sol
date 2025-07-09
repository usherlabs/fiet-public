// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {Script, console} from "forge-std/Script.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SepoliaConstants} from "./constants.sol";
import {ScriptHelper} from "./deployments/ScriptHelper.s.sol";

// ? This will default to 18 decimals, but we can override it for testing purposes when required.
contract Token is ERC20 {
    constructor(string memory name, string memory symbol, uint256 initialSupply) ERC20(name, symbol) {
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

contract LCCUSDTScript is ScriptHelper {
    LiquidityCommitmentCertificate token;

    function run() external {
        address underlyingAsset = readAddress("usdtToken");
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        // Define issuers and bounds arrays for LCC constructor
        address[] memory issuers = new address[](1);
        issuers[0] = vm.envAddress("DEPLOYER_ADDRESS"); // Use deployer as initial issuer

        address[] memory bounds = new address[](1);
        bounds[0] = vm.envAddress("DEPLOYER_ADDRESS"); // Use deployer as initial bound

        vm.startBroadcast(deployerPrivateKey);
        token = new LiquidityCommitmentCertificate(underlyingAsset, issuers, bounds);

        vm.stopBroadcast();
        writeAddress("lccTokenUSDT", address(token));
    }
}

contract LCCUSDCScript is ScriptHelper {
    LiquidityCommitmentCertificate token;

    function run() external {
        address underlyingAsset = readAddress("usdcToken");
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        // Define issuers and bounds arrays for LCC constructor
        address[] memory issuers = new address[](1);
        issuers[0] = vm.envAddress("DEPLOYER_ADDRESS"); // Use deployer as initial issuer

        address[] memory bounds = new address[](1);
        bounds[0] = vm.envAddress("DEPLOYER_ADDRESS"); // Use deployer as initial bound

        vm.startBroadcast(deployerPrivateKey);
        token = new LiquidityCommitmentCertificate(underlyingAsset, issuers, bounds);
        vm.stopBroadcast();
        writeAddress("lccTokenUSDC", address(token));
    }
}

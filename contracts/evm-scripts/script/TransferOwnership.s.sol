// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {FileHelper} from "./base/FileHelper.sol";

// Transfer ownership of MarketFactory to a new address

interface IGlobalConfig {
    function proxyCall(address target, bytes calldata data) external returns (bytes memory result);
}

interface IOwnableAdmin {
    function transferOwnership(address newOwner) external;
    function owner() external view returns (address);
}

/**
 * @notice Transfers `MarketFactory` ownership to `NEW_OWNER` (via `GlobalConfig.proxyCall` when applicable).
 *
 * Env vars
 * - REQUIRED:
 *   - `PRIVATE_KEY`: current owner/admin key
 *   - `NETWORK`: deployment namespace (e.g. `sepolia`, `arbitrum`)
 *   - `NEW_OWNER`: address that will become the new owner (must call `acceptOwnership()` afterwards)
 */
contract TransferOwnershipScript is FileHelper {
    string public networkName;
    address public marketFactory;
    address public newOwner;

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        address caller = vm.addr(deployerPrivateKey);
        networkName = vm.envString("NETWORK");
        console.log("Starting transfer ownership of Market Factory...");
        _setFilename(networkName);
        marketFactory = readAddress("marketFactory");
        console.log("MarketFactory address loaded:", marketFactory);
        address globalConfig = readAddress("globalConfig");
        address factoryOwner = IOwnableAdmin(marketFactory).owner();
        console.log("Caller:", caller);
        console.log("MarketFactory owner:", factoryOwner);
        console.log("GlobalConfig:", globalConfig);
        newOwner = vm.envAddress("NEW_OWNER");
        require(newOwner != address(0), "NEW_OWNER must be set");
        vm.startBroadcast(deployerPrivateKey);
        MarketFactory factory = MarketFactory(marketFactory);
        if (factoryOwner == globalConfig) {
            IGlobalConfig(globalConfig)
                .proxyCall(marketFactory, abi.encodeCall(IOwnableAdmin.transferOwnership, (newOwner)));
        } else {
            factory.transferOwnership(newOwner);
        }
        vm.stopBroadcast();
        console.log("Ownership transfer initiated to:", newOwner);
        console.log("New owner must call acceptOwnership() on MarketFactory");
    }
}

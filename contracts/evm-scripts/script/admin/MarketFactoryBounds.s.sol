// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * Admin: MarketFactory.addBounds/removeBounds
 *
 * Run:
 * - `just admin-marketfactory-add-bounds`
 * - `just admin-marketfactory-remove-bounds`
 *
 * Env:
 * - PRIVATE_KEY
 * - NETWORK
 *
 * Bounds input (choose one):
 * - BOUNDS_FILE: path to a json file containing `{ "bounds": ["0x..", ...] }`
 * - BOUNDS_JSON: the json string itself (same shape)
 */

import {console} from "forge-std/Script.sol";
import {AdminBase} from "./AdminBase.sol";

interface IMarketFactoryBoundsAdmin {
    function addBounds(address[] calldata bounds) external;
    function removeBounds(address[] calldata bounds) external;
}

abstract contract MarketFactoryBoundsBase is AdminBase {
    function _loadBounds() internal returns (address[] memory boundsToApply) {
        string memory json;
        if (vm.envExists("BOUNDS_FILE")) {
            string memory path = vm.envString("BOUNDS_FILE");
            json = vm.readFile(path);
        } else {
            json = vm.envString("BOUNDS_JSON");
        }
        boundsToApply = vm.parseJsonAddressArray(json, ".bounds");
        require(boundsToApply.length > 0, "bounds: empty");
    }
}

contract MarketFactoryAddBoundsScript is MarketFactoryBoundsBase {
    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        _loadAdminAddresses();

        address[] memory boundsToApply = _loadBounds();

        console.log("NETWORK:", networkName);
        console.log("MarketFactory:", marketFactory);
        console.log("bounds.length:", boundsToApply.length);

        vm.startBroadcast(pk);
        _proxyCall(marketFactory, abi.encodeCall(IMarketFactoryBoundsAdmin.addBounds, (boundsToApply)));
        vm.stopBroadcast();

        console.log("OK: addBounds");
    }
}

contract MarketFactoryRemoveBoundsScript is MarketFactoryBoundsBase {
    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        _loadAdminAddresses();

        address[] memory boundsToApply = _loadBounds();

        console.log("NETWORK:", networkName);
        console.log("MarketFactory:", marketFactory);
        console.log("bounds.length:", boundsToApply.length);

        vm.startBroadcast(pk);
        _proxyCall(marketFactory, abi.encodeCall(IMarketFactoryBoundsAdmin.removeBounds, (boundsToApply)));
        vm.stopBroadcast();

        console.log("OK: removeBounds");
    }
}


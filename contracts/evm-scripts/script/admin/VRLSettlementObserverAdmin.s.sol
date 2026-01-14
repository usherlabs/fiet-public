// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * Admin: VRLSettlementObserver owner functions
 *
 * Run:
 * - `just admin-vrl-settlement-add-verifier`
 * - `just admin-vrl-settlement-nullify-verifier`
 * - `just admin-vrl-settlement-allow-verifier-for-tokens`
 * - `just admin-vrl-settlement-disallow-verifier-for-tokens`
 *
 * Env:
 * - PRIVATE_KEY
 * - NETWORK
 *
 * For addVerifier:
 * - VERIFIER: address
 *
 * For nullifyVerifier:
 * - VERIFIER_INDEX: uint256
 *
 * For allow/disallow:
 * - VERIFIER_INDEX: uint256
 * - TOKENS_FILE or TOKENS_JSON (same shape as bounds scripts): `{ "tokens": ["0x..", ...] }`
 */

import {console} from "forge-std/Script.sol";
import {AdminBase} from "./AdminBase.sol";

interface IVRLSettlementObserverAdmin {
    function addVerifier(address verifier) external returns (uint32);
    function nullifyVerifier(uint32 index) external;
    function allowVerifierForTokens(uint32 verifierIndex, address[] memory tokens) external;
    function disallowVerifierForTokens(uint32 verifierIndex, address[] memory tokens) external;
}

abstract contract TokensJsonBase is AdminBase {
    function _loadTokens() internal returns (address[] memory tokens) {
        string memory json;
        if (vm.envExists("TOKENS_FILE")) {
            string memory path = vm.envString("TOKENS_FILE");
            json = vm.readFile(path);
        } else {
            json = vm.envString("TOKENS_JSON");
        }
        tokens = vm.parseJsonAddressArray(json, ".tokens");
        require(tokens.length > 0, "tokens: empty");
    }
}

contract VRLSettlementAddVerifierScript is AdminBase {
    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address verifier = vm.envAddress("VERIFIER");

        _loadAdminAddresses();

        console.log("NETWORK:", networkName);
        console.log("VRLSettlementObserver:", settlementObserver);
        console.log("VERIFIER:", verifier);

        vm.startBroadcast(pk);
        bytes memory ret =
            _proxyCall(settlementObserver, abi.encodeCall(IVRLSettlementObserverAdmin.addVerifier, (verifier)));
        vm.stopBroadcast();

        if (ret.length >= 32) {
            uint32 idx = abi.decode(ret, (uint32));
            console.log("OK: addVerifier index:", uint256(idx));
        } else {
            console.log("OK: addVerifier");
        }
    }
}

contract VRLSettlementNullifyVerifierScript is AdminBase {
    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        uint32 idx = uint32(vm.envUint("VERIFIER_INDEX"));

        _loadAdminAddresses();

        console.log("NETWORK:", networkName);
        console.log("VRLSettlementObserver:", settlementObserver);
        console.log("VERIFIER_INDEX:", uint256(idx));

        vm.startBroadcast(pk);
        _proxyCall(settlementObserver, abi.encodeCall(IVRLSettlementObserverAdmin.nullifyVerifier, (idx)));
        vm.stopBroadcast();

        console.log("OK: nullifyVerifier");
    }
}

contract VRLSettlementAllowVerifierForTokensScript is TokensJsonBase {
    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        uint32 idx = uint32(vm.envUint("VERIFIER_INDEX"));

        _loadAdminAddresses();
        address[] memory tokens = _loadTokens();

        console.log("NETWORK:", networkName);
        console.log("VRLSettlementObserver:", settlementObserver);
        console.log("VERIFIER_INDEX:", uint256(idx));
        console.log("tokens.length:", tokens.length);

        vm.startBroadcast(pk);
        _proxyCall(
            settlementObserver, abi.encodeCall(IVRLSettlementObserverAdmin.allowVerifierForTokens, (idx, tokens))
        );
        vm.stopBroadcast();

        console.log("OK: allowVerifierForTokens");
    }
}

contract VRLSettlementDisallowVerifierForTokensScript is TokensJsonBase {
    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        uint32 idx = uint32(vm.envUint("VERIFIER_INDEX"));

        _loadAdminAddresses();
        address[] memory tokens = _loadTokens();

        console.log("NETWORK:", networkName);
        console.log("VRLSettlementObserver:", settlementObserver);
        console.log("VERIFIER_INDEX:", uint256(idx));
        console.log("tokens.length:", tokens.length);

        vm.startBroadcast(pk);
        _proxyCall(
            settlementObserver, abi.encodeCall(IVRLSettlementObserverAdmin.disallowVerifierForTokens, (idx, tokens))
        );
        vm.stopBroadcast();

        console.log("OK: disallowVerifierForTokens");
    }
}


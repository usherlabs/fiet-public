// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

abstract contract HookMinerBase {
    function _findSalt(uint160 flags, bytes memory creationCode, bytes memory args) internal view returns (bytes32) {
        uint160 mask = Hooks.ALL_HOOK_MASK;
        flags &= mask;
        bytes memory init = abi.encodePacked(creationCode, args);
        for (uint256 salt; salt < 160_444; salt++) {
            address mined = _computeCreate2(address(this), bytes32(salt), init);
            if (uint160(mined) & mask == flags) {
                return bytes32(salt);
            }
        }
        revert("HookMiner: could not find salt");
    }

    function _computeCreate2(address deployer, bytes32 salt, bytes memory init) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(init))))));
    }
}

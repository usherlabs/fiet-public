// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ICommitmentDescriptor} from "../../src/interfaces/ICommitmentDescriptor.sol";

/// @notice Minimal test-only descriptor for MM commitment NFTs.
contract MockCommitmentDescriptor is ICommitmentDescriptor {
    string internal _base;

    constructor(string memory base) {
        _base = base;
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        return string(abi.encodePacked(_base, _toString(tokenId)));
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}


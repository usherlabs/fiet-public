// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionDescriptor} from "v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

/// @notice Minimal test-only descriptor to avoid compiling Uniswap's full `PositionDescriptor` (which exceeds EIP-170).
contract MockPositionDescriptor is IPositionDescriptor {
    IPoolManager public immutable override poolManager;
    address public immutable override wrappedNative;
    bytes32 internal immutable _nativeCurrencyLabelBytes;

    constructor(IPoolManager _poolManager, address _wrappedNative, bytes32 nativeCurrencyLabelBytes) {
        poolManager = _poolManager;
        wrappedNative = _wrappedNative;
        _nativeCurrencyLabelBytes = nativeCurrencyLabelBytes;
    }

    function tokenURI(IPositionManager, uint256 tokenId) external pure override returns (string memory) {
        // Keep it deterministic and small; tests that care about metadata should use the real Uniswap descriptor.
        return string(abi.encodePacked("mock://position/", _toString(tokenId)));
    }

    function flipRatio(address, address) external pure override returns (bool) {
        return false;
    }

    function currencyRatioPriority(address) external pure override returns (int256) {
        return 0;
    }

    function nativeCurrencyLabel() external view override returns (string memory) {
        uint256 len = 0;
        while (len < 32 && _nativeCurrencyLabelBytes[len] != 0) {
            len++;
        }
        bytes memory b = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            b[i] = _nativeCurrencyLabelBytes[i];
        }
        return string(b);
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


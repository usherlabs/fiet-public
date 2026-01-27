// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Minimal IERC20Metadata mock for Echidna harnesses.
/// @dev LiquidityHub may query `decimals()` during LCC creation/initialization paths.
contract MockERC20Metadata is IERC20Metadata {
    function name() external pure returns (string memory) {
        return "MOCK";
    }

    function symbol() external pure returns (string memory) {
        return "MOCK";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    // ===== IERC20 (unused) =====

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert("unused");
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure returns (bool) {
        revert("unused");
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert("unused");
    }
}


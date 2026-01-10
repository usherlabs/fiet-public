// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @dev Minimal MAIN oracle for E2E that returns USD prices with 18 decimals.
contract MockChainlinkOracle {
    mapping(address => uint256) public prices; // asset => price (18 decimals)

    function setPrice(address asset, uint256 price) external {
        prices[asset] = price;
    }

    function getPrice(address asset) external view returns (uint256) {
        return prices[asset];
    }
}



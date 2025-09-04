// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IOracleRegistry {
    function getOracle(string memory pricePair) external view returns (address);
}

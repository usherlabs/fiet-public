// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IOracleRegistry {
    function getOracle(string memory pricePair, address marketOracleFactory) external view returns (address);
}

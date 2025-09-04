// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IOracleFactory {
    function oracleRegistry() external view returns (address);
    function getOracle(string memory pricePair) external view returns (address);
    function registerOracle(string memory pricePair, address oracle) external;
}

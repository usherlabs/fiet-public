// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IOracleFactory {
    function oracleRegistry() external view returns (address);

    function getOracle(string memory pricePair) external view returns (address);

    function deploy(
        string memory _baseTicker,
        address _baseFeedAddress,
        string memory _quoteTicker,
        address _quoteFeedAddress
    ) external returns (address);
}

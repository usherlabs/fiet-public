// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IOracleHelper {
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event TickerUpdated(string indexed ticker, bytes32 indexed tickerHash, address indexed newAsset);

    function oracle() external view returns (address);

    function tickerHashToAsset(bytes32 tickerHash) external view returns (address);

    function registerTicker(string calldata ticker, address asset) external;

    function getAssetByTicker(string calldata ticker) external view returns (address);

    function getPriceByTicker(string calldata ticker) external view returns (uint256);

    function validateMarketOraclesExist(address lcc0, address lcc1) external view;

    function getTotalUsdValue(string[] memory tickers, uint256[] memory amounts) external view returns (uint256);

    function getPricesForLCCPair(address lcc0, address lcc1) external view returns (uint256 price0, uint256 price1);
}

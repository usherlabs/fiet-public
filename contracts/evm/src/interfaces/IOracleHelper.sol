// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

interface IOracleHelper {
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event TickerUpdated(string indexed ticker, bytes32 indexed tickerHash, address indexed newAsset);

    function oracle() external view returns (address);

    function tickerHashToAsset(bytes32 tickerHash) external view returns (address);

    function registerTicker(string calldata ticker, address asset) external;

    function getAssetByTicker(string calldata ticker) external view returns (address);

    function getPriceByTicker(string calldata ticker) external view returns (uint256);

    function validateMarketOracles(address lcc0, address lcc1) external view;

    function getTotalValue(string[] memory tickers, uint256[] memory amounts) external view returns (uint256);

    function getPriceForLcc(address lcc) external view returns (uint256 price);

    function getPricesForLccPair(address lcc0, address lcc1) external view returns (uint256 price0, uint256 price1);
}

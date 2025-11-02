// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IResilientOracle} from "./interfaces/IResilientOracle.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OracleUtils} from "./libraries/OracleUtils.sol";

contract OracleHelper is Ownable {
    error MarketOraclesNotConfigured();
    error InvalidOracleAddress();
    error TickerNotRegistered(string ticker);
    error InvalidAssetAddress();

    IResilientOracle public oracle;

    // Mapping of ticker hash to asset address
    mapping(bytes32 => address) public tickerHashToAsset;

    event TickerUpdated(string indexed ticker, bytes32 indexed tickerHash, address indexed newAsset);

    constructor(address _oracle) Ownable(msg.sender) {
        if (_oracle == address(0)) revert InvalidOracleAddress();
        oracle = IResilientOracle(_oracle);
    }

    /**
     * @notice Registers or updates a ticker to asset mapping in order to be able to get the price of an asset by ticker
     * @param ticker The ticker string (e.g., "ETH", "USDC")
     * @param asset The asset address
     * @custom:access Only owner
     */
    function registerTicker(string calldata ticker, address asset) external onlyOwner {
        if (asset == address(0)) revert InvalidAssetAddress();

        bytes32 tickerHash = keccak256(bytes(ticker));

        tickerHashToAsset[tickerHash] = asset;

        emit TickerUpdated(ticker, tickerHash, asset);
    }

    /**
     * @notice Gets asset address from ticker
     * @param ticker The ticker string
     * @return asset The asset address
     */
    function getAssetByTicker(string memory ticker) public view returns (address) {
        bytes32 tickerHash = keccak256(bytes(ticker));
        address asset = tickerHashToAsset[tickerHash];
        if (asset == address(0)) revert TickerNotRegistered(ticker);
        return asset;
    }

    /**
     * @notice Gets price by ticker
     * @param ticker The ticker string (e.g., "ETH", "USDC")
     * @return price The asset price in USD (18 decimals)
     */
    function getPriceByTicker(string memory ticker) public view returns (uint256) {
        address asset = getAssetByTicker(ticker);
        return oracle.getPrice(OracleUtils.unifyNativeTokenAddress(asset));
    }

    /**
     * @notice Validates that the oracles exist and are enabled for the given LCC tokens
     * @param lcc0 The address of the first LCC token
     * @param lcc1 The address of the second LCC token
     * @custom:error MarketOraclesNotConfigured if the oracles are not configured
     */
    function validateMarketOracles(address lcc0, address lcc1) external view {
        // make sure to check if the underlying asset is the native token and account for the representation difference
        // thus if it is the native token then use the resilient oracle native token address
        address underlying0 = OracleUtils.unifyNativeTokenAddress(ILCC(lcc0).underlying());
        address underlying1 = OracleUtils.unifyNativeTokenAddress(ILCC(lcc1).underlying());
        TokenConfig memory tokenConfig0 = oracle.getTokenConfig(underlying0);
        TokenConfig memory tokenConfig1 = oracle.getTokenConfig(underlying1);
        if (
            tokenConfig0.enableFlagsForOracles[uint256(OracleRole.MAIN)] == false
                || tokenConfig1.enableFlagsForOracles[uint256(OracleRole.MAIN)] == false
                || tokenConfig0.asset == address(0) || tokenConfig1.asset == address(0)
        ) {
            revert MarketOraclesNotConfigured();
        }
    }

    /**
     * @notice Gets the total USD value of a list of assets
     * @param tickers The list of tickers
     * @param amounts The list of amounts
     * @return totalUsdValue The total USD value
     */
    function getTotalUsdValue(string[] memory tickers, uint256[] memory amounts) public view returns (uint256) {
        uint256 totalUsdValue = 0;
        for (uint256 i = 0; i < tickers.length; i++) {
            uint256 price = getPriceByTicker(tickers[i]);
            totalUsdValue += price * amounts[i];
        }
        return totalUsdValue;
    }

    /**
     * @notice Gets USD prices for an LCC pair (batched for efficiency).
     * @param lcc0 Address of the first LCC.
     * @param lcc1 Address of the second LCC.
     * @return price0 USD price of lcc0's underlying (normalized by ResilientOracle).
     * @return price1 USD price of lcc1's underlying (normalized by ResilientOracle).
     */
    function getPricesForLCCPair(address lcc0, address lcc1) external view returns (uint256 price0, uint256 price1) {
        address underlying0 = OracleUtils.unifyNativeTokenAddress(ILCC(lcc0).underlying());
        address underlying1 = OracleUtils.unifyNativeTokenAddress(ILCC(lcc1).underlying());

        // Fetch from ResilientOracle, which handles decimals internally
        price0 = oracle.getPrice(underlying0);
        price1 = oracle.getPrice(underlying1);
    }
}

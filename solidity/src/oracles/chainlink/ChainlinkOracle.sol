// SPDX-License-Identifier: MIT
// The `ChainlinkOracle` is a contract that provides the price of a price pair using Chainlink
// It is used to get the price of a price pair using the Chainlink oracle

pragma solidity ^0.8.0;

import {ChainlinkDataFeedLib} from "../../libraries/ChainlinkDataFeedLib.sol";
import {AggregatorV3Interface} from "../../interfaces/AggregatorV3Interface.sol";
import {IOracle} from "../../interfaces/IOracle.sol";

contract ChainlinkOracle is IOracle {
    using ChainlinkDataFeedLib for AggregatorV3Interface;

    string public pricePair;
    uint256 public immutable decimals;
    AggregatorV3Interface public immutable baseFeed;
    AggregatorV3Interface public immutable quoteFeed;

    constructor(string memory _pricePair, uint256 _decimals, address _baseFeedAddress, address _quoteFeedAddress) {
        decimals = _decimals;
        pricePair = _pricePair;

        baseFeed = AggregatorV3Interface(_baseFeedAddress);
        quoteFeed = AggregatorV3Interface(_quoteFeedAddress);
    }

    /**
     * @dev Returns the price of the price pair
     * @return price The price of the price pair scaled to the oracle's decimals
     */
    function getPrice() external view returns (uint256 price) {
        // get the price of the base token
        uint256 basePrice = baseFeed.getPrice();
        // get the price of the quote token
        uint256 quotePrice = quoteFeed.getPrice();

        // we scale the price down by the decimals specified by the oracle for the quote token and base token
        // then we scale up by multiplying by 10^decimals
        // ((quotePrice / (10 ^ quoteDecimals)) / (basePrice / (10 ^ baseDecimals))) * 10^decimals
        // simplifying the equation above we get
        price = (quotePrice * 10 ** (decimals + baseFeed.decimals() - quoteFeed.decimals())) / basePrice;
    }
}

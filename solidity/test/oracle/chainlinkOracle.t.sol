// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {ChainlinkOracle} from "../../src/oracles/chainlink/ChainlinkOracle.sol";
import {ChainlinkFactory} from "../../src/oracles/chainlink/ChainlinkFactory.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

contract ChainlinkOracleTest is Test {
    ChainlinkFactory chainlinkFactory;

    string baseTicker = "BTC";
    string quoteTicker = "USD";
    string currencyPair = string.concat(baseTicker, "/", quoteTicker);
    address baseFeedAddress = makeAddr("USDT");
    address quoteFeedAddress = makeAddr("ETH");

    function setUp() public {
        uint256 decimals = 4;
        address oracleRegistry = address(0);
        chainlinkFactory = new ChainlinkFactory(oracleRegistry, decimals);

        vm.mockCall(
            baseFeedAddress,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(1, 99700000, block.timestamp, block.timestamp, 1)
        );

        vm.mockCall(baseFeedAddress, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(8));

        vm.mockCall(
            quoteFeedAddress,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(1, 250000000000, block.timestamp, block.timestamp, 1)
        );

        vm.mockCall(quoteFeedAddress, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(8));
    }

    function test_canDeployOracleUsingFactory() public {
        // deploy the oracle using the factory
        address deployedOracleAddress =
            chainlinkFactory.deploy(baseTicker, baseFeedAddress, quoteTicker, quoteFeedAddress);

        // get the oracle address from the factory
        address pricePairOracleAddress = chainlinkFactory.getOracle(currencyPair);
        // assert that the oracle address is the same as the deployed oracle address
        assertEq(pricePairOracleAddress, deployedOracleAddress);
    }

    function test_canGetPriceFromOracle() public {
        // deploy the oracle using the factory
        address deployedOracleAddress =
            chainlinkFactory.deploy(baseTicker, baseFeedAddress, quoteTicker, quoteFeedAddress);
        // get the price from the oracle
        uint256 price = IOracle(deployedOracleAddress).getPrice();
        uint256 decimals = IOracle(deployedOracleAddress).decimals();

        // assert that the price is the same as the expected price
        assertEq(price / 10 ** decimals, 2507);
    }
}

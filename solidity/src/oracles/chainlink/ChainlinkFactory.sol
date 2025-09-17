// SPDX-License-Identifier: MIT
// The `ChainlinkFactory` is responsible for returning the price of a particular price pair
// It is called by the oracle registry to get the oracle responsible for providing the price of a particular price pair
pragma solidity ^0.8.0;

import {IOracleFactory} from "../../interfaces/IOracleFactory.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ChainlinkOracle} from "./ChainlinkOracle.sol";

contract ChainlinkFactory is IOracleFactory, Ownable {
    address public oracleRegistry;
    uint256 private immutable decimals;
    // pricePair(quoteTicker/baseTicker) => oracleAddress
    mapping(string => address) public oracles;

    error OracleNotRegistered();

    constructor(address _oracleRegistry, uint256 _decimals) Ownable(msg.sender) {
        oracleRegistry = _oracleRegistry;
        decimals = _decimals;
    }

    /**
     * @dev Deploys an oracle and it's configuration for a given price pair
     * @param _baseTicker The base ticker
     * @param _baseFeedAddress The base feed address
     * @param _quoteTicker The quote ticker
     * @param _quoteFeedAddress The quote feed address
     */
    function deploy(
        string memory _baseTicker,
        address _baseFeedAddress,
        string memory _quoteTicker,
        address _quoteFeedAddress
    ) external onlyOwner returns (address) {
        string memory pricePair = string.concat(_baseTicker, "/", _quoteTicker);
        // deploy the oracle
        ChainlinkOracle oracleAddress = new ChainlinkOracle(pricePair, decimals, _baseFeedAddress, _quoteFeedAddress);

        oracles[pricePair] = address(oracleAddress);
        return address(oracleAddress);
    }

    /**
     * @dev Returns the oracle address for a given price pair
     * @param pricePair The price pair to get the oracle for
     * @return The oracle address which is responsible for providing the price of the price pair
     */
    function getOracle(string memory pricePair) external view returns (address) {
        if (oracles[pricePair] == address(0)) {
            revert OracleNotRegistered();
        }
        return oracles[pricePair];
    }
}

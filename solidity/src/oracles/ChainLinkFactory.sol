// SPDX-License-Identifier: MIT
// The `ChainLinkFactory` is responsible for returning the price of a particular price pair
// It is called by the oracle registry to get the oracle responsible for providing the price of a particular price pair
pragma solidity ^0.8.0;

import {IOracleFactory} from "../interfaces/IOracleFactory.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract ChainLinkFactory is IOracleFactory, Ownable {
    address public oracleRegistry;
    // pricePair => oracleAddress
    mapping(string => address) public oracles;

    error OracleNotRegistered();

    constructor(address _oracleRegistry) Ownable(msg.sender) {
        oracleRegistry = _oracleRegistry;
    }

    /**
     * @dev Registers an oracle for a given price pair
     * @param pricePair The price pair to register the oracle for
     * @param oracle The oracle address to register
     */
    function registerOracle(string memory pricePair, address oracle) external onlyOwner {
        oracles[pricePair] = oracle;
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

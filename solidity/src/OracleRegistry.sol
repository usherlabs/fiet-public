// SPDX-License-Identifier: MIT
// The Oracle registry returns an oracle responsible for a particular price pair
// It is used by the `MMPositionManager` to get the oracle responsible for a particular price pair and factory
pragma solidity ^0.8.0;

import {IOracleFactory} from "./interfaces/IOracleFactory.sol";
import {IOracleRegistry} from "./interfaces/IOracleRegistry.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract OracleRegistry is IOracleRegistry, Ownable {
    address public oracleFactory;

    constructor() Ownable(msg.sender) {}

    /**
     * @dev Calls a particular factory to get the oracle responsible for a particular price pair
     * @param pricePair The price pair would determine the oracle to be returned
     * @return The oracle address which is responsible for providing the price of the price pair
     */
    function getOracle(string memory pricePair) external view returns (address) {
        address oracle = IOracleFactory(oracleFactory).getOracle(pricePair);
        return oracle;
    }

    /**
     * @dev Sets the oracle factory/provider
     * @param factory The oracle factory/provider address
     */
    function setFactory(address factory) external onlyOwner {
        oracleFactory = factory;
    }
}

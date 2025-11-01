// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityCommitmentCertificate} from "./LCC.sol";
import {IOracleHelper} from "./interfaces/IOracleHelper.sol";

/**
 * @title MarketFactory
 * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
 * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
 */
contract LiquidityHub is ILiquidityHub, Ownable {
    IOracleHelper public immutable oracleHelper;
    address public mmPositionManager;

    // Mapping from underlying asset to LCC token
    mapping(address => address) public underlyingToLCC;

    // Mapping from LCC token to underlying asset
    mapping(address => address) public lccToUnderlying;

    // Mapping from LCC token to factory
    mapping(address => address) public lccToFactory;

    mapping(address => bool) public isFactory;

    constructor(address _oracleHelper) Ownable(msg.sender) {
        oracleHelper = IOracleHelper(_oracleHelper);
    }

    function getOrCreateLCC(address underlyingAsset) external onlyOwner returns (address lccToken) {
        return _getOrCreateLCC(underlyingAsset);
    }

    /**
     * @notice Gets or creates an LCC token for the given underlying asset
     * @param underlyingAsset The underlying asset address
     * @return lccToken The LCC token address
     */
    function _getOrCreateLCC(address underlyingAsset) internal returns (address lccToken) {
        lccToken = underlyingToLCC[underlyingAsset];

        if (lccToken == address(0)) {
            // Create new LCC token

            // Set MMPositionManager as an issuer. By default, ProxyHook/MarketVault is an issuer.
            address[] memory issuers = new address[](1);
            issuers[0] = address(mmPositionManager);

            lccToken = address(new LiquidityCommitmentCertificate(underlyingAsset, issuers, address(this)));

            underlyingToLCC[underlyingAsset] = lccToken;
            lccToUnderlying[lccToken] = underlyingAsset;
            lccToFactory[lccToken] = address(this);

            emit LCCCreated(underlyingAsset, lccToken);
        }
    }

    /**
     * @notice Gets the LCC token for a given underlying asset
     * @param underlyingAsset The underlying asset address
     * @return The LCC token address
     */
    function getLCC(address underlyingAsset) external view returns (address) {
        return underlyingToLCC[underlyingAsset];
    }

    /**
     * @notice Gets the underlying asset for a given LCC token
     * @param lccToken The LCC token address
     * @return The underlying asset address
     */
    function getUnderlyingAsset(address lccToken) external view returns (address) {
        return lccToUnderlying[lccToken];
    }
}

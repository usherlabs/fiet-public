// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILiquidityHub
 * @notice Interface for LiquidityHub contract that manages LCC token creation
 */
interface ILiquidityHub {
    // ============ LCC Factory ============

    /**
     * @notice Creates LCC token pair for a market
     * @param factory The factory address calling this function
     * @param marketId The market ID
     * @param underlyingAsset0 The first underlying asset address
     * @param underlyingAsset1 The second underlying asset address
     * @param marketName The market name
     * @return lccToken0 The first LCC token address
     * @return lccToken1 The second LCC token address
     */
    function createLCCPair(
        address factory,
        bytes32 marketId,
        address underlyingAsset0,
        address underlyingAsset1,
        string memory marketName
    ) external returns (address lccToken0, address lccToken1);

    /**
     * @notice Gets the LCC token for a given underlying asset
     * @param underlyingAsset The underlying asset address
     * @return The LCC token address
     */
    function getLCC(address underlyingAsset) external view returns (address);

    /**
     * @notice Gets the underlying asset for a given LCC token
     * @param lccToken The LCC token address
     * @return The underlying asset address
     */
    function getUnderlyingAsset(address lccToken) external view returns (address);
}


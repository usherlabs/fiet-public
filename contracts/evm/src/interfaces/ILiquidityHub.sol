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
     * @param marketRef The market reference (bytes from proxyHookAddress)
     * @param underlyingAsset0 The first underlying asset address
     * @param underlyingAsset1 The second underlying asset address
     * @param marketName The market name
     * @param initialIssuers Array of addresses to set as issuers for both LCC tokens
     * @param marketVaultAddress The Uniswap V4 pool manager address (market vault)
     * @return lccToken0 The first LCC token address
     * @return lccToken1 The second LCC token address
     */
    function createLCCPair(
        bytes memory marketRef,
        address underlyingAsset0,
        address underlyingAsset1,
        string memory marketName,
        address[] memory initialIssuers,
        address marketVaultAddress
    ) external returns (address lccToken0, address lccToken1);

    /**
     * @notice Initializes the mapping from LCC tokens to Market (with ID and Ref)
     * @param lccToken0 The first LCC token address
     * @param lccToken1 The second LCC token address
     * @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
     * @param marketRef The market reference (bytes from proxyHookAddress)
     * @param refIsValidIssuer Whether the market ref address is a valid issuer
     */
    function initialize(
        address lccToken0,
        address lccToken1,
        bytes32 marketId,
        bytes memory marketRef,
        bool refIsValidIssuer
    ) external;

    /**
     * @notice Issues LCC tokens (mints to issuer)
     * @param lccToken The LCC token address to issue for
     * @param amount The amount to issue
     */
    function issue(address lccToken, uint256 amount) external;

    /**
     * @notice Cancels LCC tokens (burns from issuer)
     * @param lccToken The LCC token address to cancel for
     * @param amount The amount to cancel
     */
    function cancel(address lccToken, uint256 amount) external;

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

    /**
     * @notice Gets the Market struct for a given LCC token
     * @param lccToken The LCC token address
     * @return factory The factory that created this market
     * @return id The market ID (core pool id as market)
     * @return ref The market reference (proxy)
     * @return refIsValidIssuer Whether the market ref address is a valid issuer
     */
    function lccToMarket(address lccToken)
        external
        view
        returns (address factory, bytes32 id, bytes memory ref, bool refIsValidIssuer);

    /**
     * @notice Gets the total amount queued for settlement for a given LCC token
     * @param lcc The LCC token address
     * @return The total amount queued for settlement
     */
    function totalQueued(address lcc) external view returns (uint256);

    /**
     * @notice Called by MarketVault after taking underlying liquidity from the market to LCC
     * @param lcc The LCC token address
     * @param amount The amount of underlying liquidity taken
     * @param shouldEmit Whether to emit LiquidityAvailable event
     */
    function confirmTake(address lcc, uint256 amount, bool shouldEmit) external;

    /**
     * @notice Process settlement for a specific recipient using reserveOfUnderlying
     * @dev Permissionless function that allows anyone to process settlements when liquidity is available
     * @param lcc The LCC token address
     * @param recipient The recipient address to settle for
     * @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
     */
    function processSettlementFor(address lcc, address recipient, uint256 maxAmount) external;

    /**
     * @notice Prepare settlement of underlying from Hub to MarketVault
     * @param lcc The LCC token address
     * @param amount The amount of underlying to prepare for settlement
     */
    function prepareSettle(address lcc, uint256 amount) external;

    /**
     * @notice Annul a user's queued settlement prior to a protocol-bound transfer
     * @param lcc The LCC token address
     * @param fromUser The user initiating the transfer
     * @param amountToTransfer The amount intended to be transferred
     */
    function annulSettlementBeforeTransfer(address lcc, address from, uint256 amountToTransfer) external;
}


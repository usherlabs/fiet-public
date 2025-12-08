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
     * @return lccToken0 The first LCC token address
     * @return lccToken1 The second LCC token address
     */
    function createLCCPair(
        bytes memory marketRef,
        address underlyingAsset0,
        address underlyingAsset1,
        string memory marketName,
        address[] memory initialIssuers
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
     * @notice Issues LCC tokens (mints to specified recipient)
     * @param lccToken The LCC token address to issue for
     * @param to The recipient address
     * @param amount The amount to issue
     */
    function issue(address lccToken, address to, uint256 amount) external;

    /**
     * @notice Cancels LCC tokens (burns from specified address)
     * @param lccToken The LCC token address to cancel for
     * @param from The address to cancel tokens from
     * @param amount The amount to cancel
     */
    function cancel(address lccToken, address from, uint256 amount) external;

    /**
     * @notice Cancels LCC tokens and queues a settlement for the shortfall
     * @param lccToken The LCC token address to cancel for
     * @param from The address to cancel tokens from
     * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
     * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
     * @param recipient The recipient address for the queued settlement
     */
    function cancelWithQueue(
        address lccToken,
        address from,
        uint256 principalAmount,
        uint256 queueAmount,
        address recipient
    ) external;

    // ============ Trader wrapping/unwrapping ============
    function wrapTo(address lcc, address to, uint256 amount) external payable;
    function wrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external payable;
    function wrap(address lcc, uint256 amount) external payable;
    function wrap(address underlying, bytes32 marketId, uint256 amount) external payable;
    function unwrap(address lcc, uint256 amount) external;
    function unwrap(address underlying, bytes32 marketId, uint256 amount) external;
    function unwrapTo(address lcc, address to, uint256 amount) external;
    function unwrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external;

    /**
     * @notice Gets the LCC token for a given underlying asset in a specific market
     * @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
     * @param underlying The underlying asset address
     * @return The LCC token address
     */
    function getLCC(bytes32 marketId, address underlying) external view returns (address);

    /**
     * @notice Gets the underlying asset for a given LCC token
     * @param lccToken The LCC token address
     * @return The underlying asset address
     */
    function getUnderlying(address lccToken) external view returns (address);

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
     * @notice Gets the reserve of underlying for a given LCC token
     * @param underlying The underlying asset address
     * @return The reserve of underlying
     */
    function reserveOfUnderlying(address underlying) external view returns (uint256);

    /**
     * @notice Gets the LCC's shared reserve of underlying
     * @param lcc The LCC token address
     * @return The reserve of underlying
     */
    function sharedReserveOf(address lcc) external view returns (uint256);

    /**
     * @notice Gets the direct supply of underlying for a given LCC token
     * @param underlying The underlying asset address
     * @return The direct supply of underlying
     */
    function directSupply(address underlying) external view returns (uint256);

    /**
     * @notice Gets the settle queue for a given LCC -> recipient mapping
     * @param lcc The LCC token address
     * @param recipient The recipient address
     * @return The settle queue amount
     */
    function settleQueue(address lcc, address recipient) external view returns (uint256);

    /**
     * @notice Gets the market liquidity for a given LCC token
     * @param lcc The LCC token address
     * @return The market liquidity amount
     */
    function marketLiquidity(address lcc) external view returns (uint256);

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
     * @dev If the transfer amount exceeds the user's current liquid balance (wrapped + marketDerived),
     *      the excess "bleed" will be removed from their queued settlement up to the queued amount.
     * @param lcc The LCC token address
     * @param from The user initiating the transfer
     * @param wrappedBalance The user's wrapped balance
     * @param marketDerivedBalance The user's market-derived balance
     * @param amountToTransfer The amount intended to be transferred
     */
    function annulSettlementBeforeTransfer(
        address lcc,
        address from,
        uint256 wrappedBalance,
        uint256 marketDerivedBalance,
        uint256 amountToTransfer
    ) external;

    // ============ Factory Management ============

    /**
     * @notice Sets a factory address as enabled or disabled
     * @param factory The factory address
     * @param enabled Whether the factory should be enabled
     */
    function setFactory(address factory, bool enabled) external;
}


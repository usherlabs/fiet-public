// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IMarketFactory} from "./IMarketFactory.sol";
import {IBoundRegistry} from "./IBoundRegistry.sol";
import {IMinimalLiquidityHub} from "./IMinimalLiquidityHub.sol";

/**
 * @title ILiquidityHub
 * @notice Interface for LiquidityHub contract that manages LCC token creation
 */
interface ILiquidityHub is IBoundRegistry, IMinimalLiquidityHub {
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
     */
    function initialize(address lccToken0, address lccToken1, bytes32 marketId, bytes memory marketRef) external;

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

    /**
     * @notice Queues settlement for a recipient after issuer-side deficit transfer.
     * @dev Intended for issuer flows where the recipient already received market-derived LCC and
     *      queue ownership must match that recipient. This path performs strict serviceability
     *      checks up front, unlike generic queue accounting paths that defer settleability checks
     *      to `processSettlementFor(...)`.
     *
     *      External reserve-funded settlement rejects any protocol-bound recipient (factory namespace) and objective
     *      sink addresses (`weth9()` for native-backed LCCs; the underlying token for ERC20-backed LCCs). Non-bound
     *      recipients are admitted without recipient-shape introspection; integrators must nominate addresses capable of
     *      receiving ERC20-compatible settlement assets (native lanes may still resolve as WETH for unsupported contracts).
     * @param lccToken The LCC token address
     * @param recipient The queue owner / eventual settlement recipient
     * @param amount The amount to queue
     */
    function queueForTransferRecipient(address lccToken, address recipient, uint256 amount) external;

    /**
     * @notice Plans a cancel operation to be executed on a specific transfer path
     * @param lcc The LCC token address
     * @param awaitingLastOwner The expected sender of the transfer
     * @param cancelFromNextOwner The expected recipient of the transfer
     * @param amount The amount to cancel
     */
    function planCancel(address lcc, address awaitingLastOwner, address cancelFromNextOwner, uint256 amount) external;

    /**
     * @notice Plans a cancel with queue operation to be executed on a specific transfer path
     * @param lcc The LCC token address
     * @param awaitingLastOwner The expected sender of the transfer
     * @param cancelFromNextOwner The expected recipient of the transfer
     * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
     * @param queueAmount The amount to queue for settlement
     * @param recipient The recipient address for the queued settlement
     */
    function planCancelWithQueue(
        address lcc,
        address awaitingLastOwner,
        address cancelFromNextOwner,
        uint256 principalAmount,
        uint256 queueAmount,
        address recipient
    ) external;

    /**
     * @notice Gets the Market factory for a given two LCC tokens
     * @param lcc0 The first LCC token address
     * @param lcc1 The second LCC token address
     * @return The Market factory
     */
    function getFactory(address lcc0, address lcc1) external view returns (IMarketFactory);

    /**
     * @notice Called by MarketVault after taking underlying liquidity from the market to LCC
     * @param lcc The LCC token address
     * @param amount The amount of underlying liquidity taken
     * @param shouldEmit If true, emit `LiquidityAvailable` when amount > 0 (dispatch wake-up; see event NatSpec)
     */
    function confirmTake(address lcc, uint256 amount, bool shouldEmit) external;

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
     * @param from The user initiating the transfer
     * @param wrappedBalance The user's wrapped balance
     * @param marketDerivedBalance The user's market-derived balance
     * @param amountToTransfer The amount intended to be transferred
     */
    function annulSettlementBeforeTransfer(
        address from,
        uint256 wrappedBalance,
        uint256 marketDerivedBalance,
        uint256 amountToTransfer
    ) external;

    /**
     * @notice Called by LCC on transfer to execute any planned cancellations
     * @param sender The expected sender of the transfer (e.g., poolManager)
     * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM)
     */
    function executePlannedCancel(address sender, address cancelFromRecipient) external;

    // ============ Factory Management ============

    /**
     * @notice Checks if an address is a registered factory
     * @param factory The factory address to check
     * @return True if the address is a registered factory
     */
    function isFactory(address factory) external view returns (bool);

    /**
     * @notice Sets a factory address as enabled or disabled
     * @param factory The factory address
     * @param enabled Whether the factory should be enabled
     */
    function setFactory(address factory, bool enabled) external;
}

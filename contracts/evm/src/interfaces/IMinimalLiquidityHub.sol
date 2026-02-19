// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title IMinimalLiquidityHub
 * @notice Minimal, wallet-facing interface for the LiquidityHub
 */
interface IMinimalLiquidityHub {
    // ============ Trader wrapping/unwrapping ============
    function wrapTo(address lcc, address to, uint256 amount) external payable;
    function wrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external payable;
    function wrap(address lcc, uint256 amount) external payable;
    function wrap(address underlying, bytes32 marketId, uint256 amount) external payable;
    function unwrap(address lcc, uint256 amount) external;
    function unwrap(address underlying, bytes32 marketId, uint256 amount) external;
    function unwrapTo(address lcc, address to, uint256 amount) external;

    /**
     * @notice Unwraps LCC tokens back to underlying assets and transfers any immediately-available underlying to `to`,
     *         while queueing any unfulfilled portion to a separate settlement queue owner.
     * @dev If available liquidity is insufficient to fulfil `amount`, the shortfall is queued under `queueTo` and can be
     *      permissionlessly processed later via `processSettlementFor(lcc, queueTo, maxAmount)` when reserves become available.
     *
     *      This overload exists for protocol flows where "who receives underlying now" differs from "who owns the
     *      settlement claim".
     * @param lcc The LCC token address to unwrap
     * @param to The recipient address for any underlying paid out immediately
     * @param queueTo The address credited for any queued settlement shortfall (the eventual recipient on settlement)
     * @param amount The amount of LCC tokens to unwrap
     *
     * @custom:constraints `queueTo` MUST NOT be `address(0)`; queueing to the zero address will strand the settlement.
     * @custom:constraints `queueTo` MAY equal `to` to match the behaviour of `unwrapTo(lcc, to, amount)`.
     */
    function unwrapTo(address lcc, address to, address queueTo, uint256 amount) external;
    function unwrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external;

    /**
     * @notice Unwraps LCC tokens (resolved by `underlying` + `marketId`) back to underlying assets and transfers any
     *         immediately-available underlying to `to`, while queueing any unfulfilled portion to `queueTo`.
     * @dev If available liquidity is insufficient to fulfil `amount`, the shortfall is queued under `queueTo` and can be
     *      permissionlessly processed later via `processSettlementFor(lcc, queueTo, maxAmount)`.
     *
     *      This overload exists for protocol flows where the settlement queue owner must differ from the immediate
     *      payout recipient.
     * @param underlying The underlying asset address
     * @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
     * @param to The recipient address for any underlying paid out immediately
     * @param queueTo The address credited for any queued settlement shortfall (the eventual recipient on settlement)
     * @param amount The amount of LCC tokens to unwrap
     *
     * @custom:constraints `queueTo` MUST NOT be `address(0)`; queueing to the zero address will strand the settlement.
     * @custom:constraints `queueTo` MAY equal `to` to match the behaviour of `unwrapTo(underlying, marketId, to, amount)`.
     */
    function unwrapTo(address underlying, bytes32 marketId, address to, address queueTo, uint256 amount) external;

    /**
     * @notice Process settlement for a specific recipient using reserveOfUnderlying
     * @dev Permissionless function that allows anyone to process settlements when liquidity is available
     * @param lcc The LCC token address
     * @param recipient The recipient address to settle for
     * @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
     */
    function processSettlementFor(address lcc, address recipient, uint256 maxAmount) external;

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
     * @notice Checks if an address is a valid LCC token
     * @param lcc The address to check
     * @return True if the address is a valid LCC token
     */
    function isLCC(address lcc) external view returns (bool);

    /**
     * @notice Gets the Market ID and Factory Address for a given LCC token
     * @param lccToken The LCC token address
     * @return id The market ID (core pool id as market)
     * @return factory The factory that created this market
     */
    function lccToMarket(address lccToken) external view returns (bytes32 id, address factory);

    /**
     * @notice Gets the total amount queued for settlement for a given LCC token
     * @param lcc The LCC token address
     * @return The total amount queued for settlement
     */
    function totalQueued(address lcc) external view returns (uint256);

    /**
     * @notice Gets the LCC's reserve of underlying assets
     * @param lcc The LCC token address
     * @return The reserve of underlying
     */
    function reserveOfUnderlying(address lcc) external view returns (uint256);

    /**
     * @notice Returns the direct supply (wrapped underlying) for a given LCC token
     * @param lcc The LCC token address
     * @return The amount of direct supply
     */
    function directSupply(address lcc) external view returns (uint256);

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
}

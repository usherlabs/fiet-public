// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title IMinimalLiquidityHub
 * @notice Minimal interface for the LiquidityHub trader-facing wrap/unwrap and settlement helpers
 */
interface IMinimalLiquidityHub {
    // ============ Trader wrapping/unwrapping ============
    function wrapTo(address lcc, address to, uint256 amount) external payable;
    function wrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external payable;
    function wrap(address lcc, uint256 amount) external payable;
    function wrap(address underlying, bytes32 marketId, uint256 amount) external payable;
    function unwrap(address lcc, uint256 amount) external;
    function unwrap(address underlying, bytes32 marketId, uint256 amount) external;
    /**
     * @notice Endpoint-only: unwrap from `msg.sender`’s Hub/LCC balance and pay underlying to `to` (queue shortfall to `to`).
     * @dev Caller must be `BOUND_ENDPOINT` for this LCC’s market. Direct users should use `unwrap(...)`.
     *      Immediate payout `to` must not be the Hub, `BOUND_EXEMPT`, or `BOUND_DEX` (see HUB-02B in INVARIANTS.md).
     */
    function unwrapTo(address lcc, address to, uint256 amount) external;

    /**
     * @notice Unwraps LCC tokens back to underlying assets and transfers any immediately-available underlying to `to`,
     *         while queueing any unfulfilled portion to a separate settlement queue owner.
     * @dev If available liquidity is insufficient to fulfil `amount`, the shortfall is queued under `queueTo` and can be
     *      permissionlessly processed later via `processSettlementFor(lcc, queueTo, maxAmount)` when reserves become available.
     *      Queue creation validates owner shape (for example non-zero and non-exempt unless Hub), while present settleability is
     *      enforced at `processSettlementFor` time and may require a later retry after reconciliation.
     *
     *      Endpoint-only: caller must be `BOUND_ENDPOINT` for this LCC’s market. Intended for protocol flows where
     *      "who receives underlying now" differs from "who owns the settlement claim".
     * @param lcc The LCC token address to unwrap
     * @param to The recipient address for any underlying paid out immediately
     * @param queueTo The address credited for any queued settlement shortfall (the eventual recipient on settlement)
     * @param amount The amount of LCC tokens to unwrap
     *
     * @custom:constraints `queueTo` MUST NOT be `address(0)`; queueing to the zero address will strand the settlement.
     * @custom:constraints `queueTo` MAY equal `to` to match the behaviour of `unwrapTo(lcc, to, amount)`.
     * @custom:constraints `to` MUST NOT be `address(0)`, the Hub, `BOUND_EXEMPT`, or `BOUND_DEX` (HUB-02B).
     */
    function unwrapTo(address lcc, address to, address queueTo, uint256 amount) external;
    /**
     * @notice Endpoint-only: same as `unwrapTo(lcc, to, amount)` with LCC resolved by market.
     */
    function unwrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external;

    /**
     * @notice Unwraps LCC tokens (resolved by `underlying` + `marketId`) back to underlying assets and transfers any
     *         immediately-available underlying to `to`, while queueing any unfulfilled portion to `queueTo`.
     * @dev If available liquidity is insufficient to fulfil `amount`, the shortfall is queued under `queueTo` and can be
     *      permissionlessly processed later via `processSettlementFor(lcc, queueTo, maxAmount)`.
     *      Queue creation validates owner shape (for example non-zero and non-exempt unless Hub), while present settleability is
     *      enforced at `processSettlementFor` time and may require a later retry after reconciliation.
     *
     *      Endpoint-only: caller must be `BOUND_ENDPOINT` for the resolved LCC’s market.
     * @param underlying The underlying asset address
     * @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
     * @param to The recipient address for any underlying paid out immediately
     * @param queueTo The address credited for any queued settlement shortfall (the eventual recipient on settlement)
     * @param amount The amount of LCC tokens to unwrap
     *
     * @custom:constraints `queueTo` MUST NOT be `address(0)`; queueing to the zero address will strand the settlement.
     * @custom:constraints `queueTo` MAY equal `to` to match the behaviour of `unwrapTo(underlying, marketId, to, amount)`.
     * @custom:constraints `to` MUST NOT be `address(0)`, the Hub, `BOUND_EXEMPT`, or `BOUND_DEX` (HUB-02B).
     */
    function unwrapTo(address underlying, bytes32 marketId, address to, address queueTo, uint256 amount) external;

    /**
     * @notice Process settlement for a specific recipient using reserveOfUnderlying
     * @dev Permissionless function that allows anyone to process settlements when liquidity is available.
     *      Reverts for external recipients are retriable and indicate reserves/custody are not yet reconciled.
     * @param lcc The LCC token address
     * @param recipient The recipient address to settle for
     * @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
     */
    function processSettlementFor(address lcc, address recipient, uint256 maxAmount) external;

    /**
     * @notice Atomically releases queued MM custody and settles it against the recipient's Hub queue.
     * @dev Best-effort path for MM collection flows. Returns 0 when nothing is currently settleable.
     * @param lcc The LCC token address
     * @param custodian The MM queue custodian holding beneficiary-scoped queued LCC
     * @param tokenId The commitment token id bucket to debit in the custodian
     * @param recipient The queue owner and settlement recipient
     * @param maxAmount The maximum amount to settle
     */
    function settleFromCustodian(address lcc, address custodian, uint256 tokenId, address recipient, uint256 maxAmount)
        external;

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
     * @notice Gets the total queued settlement debt for the underlying backing a given LCC
     * @param lcc The LCC token address
     * @return The aggregated queued debt across all LCCs sharing the same underlying
     */
    function queueOfUnderlying(address lcc) external view returns (uint256);

    /**
     * @notice Gets the unfunded queued settlement debt for the underlying backing a given LCC
     * @dev Returns `max(queueOfUnderlying - marketDerivedReserveOfUnderlying, 0)` at underlying scope.
     * @param lcc The LCC token address
     * @return The remaining underlying shortfall that still needs mobilisation
     */
    function unfundedQueueOfUnderlying(address lcc) external view returns (uint256);

    /**
     * @notice Gets the LCC's reserve of underlying assets
     * @param lcc The LCC token address
     * @return The reserve of underlying
     */
    function reserveOfUnderlying(address lcc) external view returns (uint256);

    /**
     * @notice Gets the split underlying reserve tuple for a given LCC
     * @param lcc The LCC token address
     * @return direct The reserve backing direct/wrapped supply
     * @return marketDerived The reserve mobilised from market-derived flows
     */
    function reserveOfUnderlyingTuple(address lcc) external view returns (uint256 direct, uint256 marketDerived);

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

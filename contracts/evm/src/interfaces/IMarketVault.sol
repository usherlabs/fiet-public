// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {VaultSettlementIntent} from "../types/VTS.sol";

/**
 * @title IMarketVault
 * @notice Per-market vault facade implemented by `ProxyHook` (routes to `ICanonicalVault`).
 */
interface IMarketVault {
    /// @notice Core pool identifier for this market facade.
    /// @return The market id as `bytes32`.
    function marketId() external view returns (bytes32);

    /// @notice Factory-scoped canonical custody used by this facade.
    /// @return Canonical vault address.
    function canonicalVault() external view returns (address);

    /// @notice Sorted LCC pair for this market.
    /// @return lccToken0 First LCC token.
    /// @return lccToken1 Second LCC token.
    function lccs() external view returns (address lccToken0, address lccToken1);

    /**
     * @notice Get the balance of a currency in the market vault
     * @param currency The currency to get the balance of
     * @return The balance of the currency in the market vault
     */
    function inMarketBalanceOf(Currency currency) external view returns (uint256);

    /**
     * @notice Modify vault liquidity, handling partial withdrawals gracefully
     * @param balanceDelta The desired balance delta to apply
     */
    function modifyLiquidities(BalanceDelta balanceDelta) external;

    /**
     * @notice Try to modify vault liquidity, handling partial withdrawals gracefully
     * @param balanceDelta The desired balance delta to apply
     * @return The actual balance delta that was applied (may be less than requested for withdrawals)
     */
    function tryModifyLiquidities(BalanceDelta balanceDelta) external returns (BalanceDelta);

    /**
     * @notice Try to modify vault liquidity with a custom recipient for withdrawals
     * @param balanceDelta The desired balance delta to apply
     * @param recipient The recipient for withdrawals (positive deltas)
     * @return The actual balance delta that was applied (may be less than requested for withdrawals)
     */
    function tryModifyLiquiditiesWithRecipient(BalanceDelta balanceDelta, address recipient)
        external
        returns (BalanceDelta);

    /**
     * @notice Dry run to modify vault liquidity, handling partial withdrawals gracefully
     * @param balanceDelta The desired balance delta to apply
     * @return The actual balance delta that was applied (may be less than requested for withdrawals)
     */
    function dryModifyLiquidities(BalanceDelta balanceDelta) external view returns (BalanceDelta);

    function dryModifyLiquidities(VaultSettlementIntent calldata settlementIntent) external view returns (BalanceDelta);

    function modifyLiquidities(VaultSettlementIntent calldata settlementIntent) external;

    function tryModifyLiquidities(VaultSettlementIntent calldata settlementIntent) external returns (BalanceDelta);

    function tryModifyLiquiditiesWithRecipient(VaultSettlementIntent calldata settlementIntent, address recipient)
        external
        returns (BalanceDelta);

    /**
     * @notice Increase the in-market liquidity reserve ledger for an underlying currency (canonical vault accounting).
     * @param underlyingCurrency Underlying asset the reserve tracks.
     * @param amount Amount to add to the reserve.
     * @dev Access: Only callable by VTS (`marketFactory.vts()`). Reverts `Errors.InvalidSender` for any other caller.
     */
    function increaseLiquidityReserve(Currency underlyingCurrency, uint256 amount) external;

    /**
     * @notice Decrease the in-market liquidity reserve ledger for an underlying currency.
     * @param underlyingCurrency Underlying asset the reserve tracks.
     * @param amount Amount to remove from the reserve.
     * @dev Access: Only callable by VTS (`marketFactory.vts()`). Reverts `Errors.InvalidSender` for any other caller.
     */
    function decreaseLiquidityReserve(Currency underlyingCurrency, uint256 amount) external;
}

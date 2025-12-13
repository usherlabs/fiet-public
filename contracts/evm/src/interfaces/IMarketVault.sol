// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/**
 * @title IMarketVault
 * @notice Interface for th ProxyHook contract
 */
interface IMarketVault {
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
     * @notice Dry run to modify vault liquidity, handling partial withdrawals gracefully
     * @param balanceDelta The desired balance delta to apply
     * @return The actual balance delta that was applied (may be less than requested for withdrawals)
     */
    function dryModifyLiquidities(BalanceDelta balanceDelta) external returns (BalanceDelta);
}

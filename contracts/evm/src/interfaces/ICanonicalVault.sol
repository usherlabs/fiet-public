// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {VaultSettlementIntent} from "../types/VTS.sol";

/**
 * @title ICanonicalVault
 * @notice Factory-scoped custody surface used by market facades and VTS bookkeeping paths.
 */
interface ICanonicalVault {
    /// @notice Bound `MarketFactory` for this deployment.
    /// @return The factory address.
    function marketFactory() external view returns (address);

    /// @notice One-time registration of a market facade and its LCC / underlying pair.
    function registerMarket(
        bytes32 marketId,
        address facade,
        address lcc0,
        address lcc1,
        address underlying0,
        address underlying1
    ) external;

    /// @notice Durable reserve ledger balance for `currency` in `marketId`.
    function inMarketBalanceOf(bytes32 marketId, Currency currency) external view returns (uint256);

    /// @notice Dry-run vault delta without mutating state (no settlement intent split).
    function dryModifyLiquidities(bytes32 marketId, Currency currency0, Currency currency1, BalanceDelta balanceDelta)
        external
        view
        returns (BalanceDelta);

    /// @notice Dry-run with explicit credit-backed vs settled-backed lanes.
    function dryModifyLiquidities(
        bytes32 marketId,
        Currency currency0,
        Currency currency1,
        VaultSettlementIntent calldata settlementIntent
    ) external view returns (BalanceDelta);

    /// @notice Apply liquidity modification; full delta must be consumed or revert.
    function modifyLiquidities(
        bytes32 marketId,
        Currency currency0,
        Currency currency1,
        address lcc0,
        address lcc1,
        BalanceDelta balanceDelta,
        address recipient
    ) external returns (BalanceDelta usedDelta);

    /// @notice Apply modification using explicit settlement intent (credit-backed lanes).
    function modifyLiquidities(
        bytes32 marketId,
        Currency currency0,
        Currency currency1,
        address lcc0,
        address lcc1,
        VaultSettlementIntent calldata settlementIntent,
        address recipient
    ) external returns (BalanceDelta usedDelta);

    /// @notice Batch-settle both LCC obligations for a market.
    function settleObligations(bytes32 marketId, address lcc0, address lcc1) external;

    /// @notice Settle obligations for a single LCC lane.
    function settleObligationsForLCC(bytes32 marketId, address lccToken) external;

    /// @notice Pull underlying from hub into canonical custody for `lccToken`.
    function settleUnderlyingToVaultFromHub(bytes32 marketId, address lccToken, uint256 amount) external;

    /// @notice Cancel LCC with deficit handling; may route remainder to `deficitRecipient`.
    function cancelLCCWithDeficit(bytes32 marketId, address lccToken, uint256 amount, address deficitRecipient)
        external
        returns (uint256 amountToCancel);

    /// @notice Convert underlying ERC6909 claims into durable reserve for this market.
    function takeUnderlyingClaims(bytes32 marketId, Currency underlyingCurrency, uint256 amount) external;

    /// @notice Move settled underlying claims toward pool settlement.
    function settleUnderlyingFromClaims(bytes32 marketId, Currency underlyingCurrency, uint256 amount) external;

    /// @notice Issue and settle an LCC tranche from pool manager context.
    function issueAndSettleLcc(bytes32 marketId, address lccToken, uint256 amount) external;

    /// @notice Pull LCC ERC6909 from the pool manager into canonical custody.
    function takeLccFromPoolManager(bytes32 marketId, address lccToken, uint256 amount) external;

    /// @notice Increase durable underlying reserve for this market (VTS-only).
    function increaseLiquidityReserve(bytes32 marketId, Currency underlyingCurrency, uint256 amount) external;

    /// @notice Decrease durable underlying reserve for this market (VTS-only).
    function decreaseLiquidityReserve(bytes32 marketId, Currency underlyingCurrency, uint256 amount) external;
}

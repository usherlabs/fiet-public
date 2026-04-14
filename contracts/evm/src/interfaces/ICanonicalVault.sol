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
    function marketFactory() external view returns (address);

    function registerMarket(
        bytes32 marketId,
        address facade,
        address lcc0,
        address lcc1,
        address underlying0,
        address underlying1
    ) external;

    function inMarketBalanceOf(bytes32 marketId, Currency currency) external view returns (uint256);

    function dryModifyLiquidities(bytes32 marketId, Currency currency0, Currency currency1, BalanceDelta balanceDelta)
        external
        view
        returns (BalanceDelta);

    function dryModifyLiquidities(
        bytes32 marketId,
        Currency currency0,
        Currency currency1,
        VaultSettlementIntent calldata settlementIntent
    ) external view returns (BalanceDelta);

    function modifyLiquidities(
        bytes32 marketId,
        Currency currency0,
        Currency currency1,
        address lcc0,
        address lcc1,
        BalanceDelta balanceDelta,
        address recipient
    ) external returns (BalanceDelta usedDelta);

    function modifyLiquidities(
        bytes32 marketId,
        Currency currency0,
        Currency currency1,
        address lcc0,
        address lcc1,
        VaultSettlementIntent calldata settlementIntent,
        address recipient
    ) external returns (BalanceDelta usedDelta);

    function settleObligations(bytes32 marketId, address lcc0, address lcc1) external;

    function settleObligationsForLCC(bytes32 marketId, address lccToken) external;

    function settleUnderlyingToVaultFromHub(bytes32 marketId, address lccToken, uint256 amount) external;

    function cancelLCCWithDeficit(bytes32 marketId, address lccToken, uint256 amount, address deficitRecipient)
        external
        returns (uint256 amountToCancel);

    function takeUnderlyingClaims(bytes32 marketId, Currency underlyingCurrency, uint256 amount) external;

    function settleUnderlyingFromClaims(bytes32 marketId, Currency underlyingCurrency, uint256 amount) external;

    function issueAndSettleLcc(bytes32 marketId, address lccToken, uint256 amount) external;

    function takeLccFromPoolManager(bytes32 marketId, address lccToken, uint256 amount) external;

    function increaseLiquidityReserve(bytes32 marketId, Currency underlyingCurrency, uint256 amount) external;

    function decreaseLiquidityReserve(bytes32 marketId, Currency underlyingCurrency, uint256 amount) external;
}

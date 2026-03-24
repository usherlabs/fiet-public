// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LiquidityHubLib} from "./LiquidityHubLib.sol";
import {LiquidityHubStorage} from "../types/Liquidity.sol";

/**
 * @title LiquidityHubLinkedLib
 * @notice External entrypoints for LiquidityHubLib so heavy logic is not inlined into LiquidityHub bytecode.
 * @dev Mirrors the LCCFactoryLinkedLib pattern: delegatecall into this library from LiquidityHub.
 */
library LiquidityHubLinkedLib {
    function wrapWithPrepare(LiquidityHubStorage storage s, address lcc, address withLCC, address from, uint256 amount)
        external
        view
        returns (LiquidityHubLib.WrapWithContext memory)
    {
        return LiquidityHubLib.wrapWithPrepare(s, lcc, withLCC, from, amount);
    }

    function wrapWithContext(
        LiquidityHubStorage storage s,
        address lcc,
        address withLCC,
        LiquidityHubLib.WrapWithContext memory ctx
    ) external returns (LiquidityHubLib.WrapWithContext memory) {
        return LiquidityHubLib.wrapWithContext(s, lcc, withLCC, ctx);
    }

    function unwrapInternalLogic(
        LiquidityHubStorage storage s,
        address lcc,
        address queueTo,
        uint256 amount,
        uint256 wrappedBalance,
        uint256 marketDerivedBalance
    ) external returns (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) {
        return LiquidityHubLib.unwrapInternalLogic(s, lcc, queueTo, amount, wrappedBalance, marketDerivedBalance);
    }

    function processSettlementLogic(LiquidityHubStorage storage s, address lcc, address recipient, uint256 maxAmount)
        external
    {
        LiquidityHubLib.processSettlementLogic(s, lcc, recipient, maxAmount);
    }

    function pay(
        LiquidityHubStorage storage s,
        address lcc,
        address owner,
        address to,
        uint256 fromDirect,
        uint256 fromMarket
    ) external {
        LiquidityHubLib.pay(s, lcc, owner, to, fromDirect, fromMarket);
    }

    function queueSettlement(LiquidityHubStorage storage s, address lcc, address recipient, uint256 amount) external {
        LiquidityHubLib.queueSettlement(s, lcc, recipient, amount);
    }

    function confirmTakePrepare(LiquidityHubStorage storage s, address lcc, uint256 amount, bool shouldEmit)
        external
        returns (LiquidityHubLib.ConfirmTakeContext memory)
    {
        return LiquidityHubLib.confirmTakePrepare(s, lcc, amount, shouldEmit);
    }

    function confirmTakeBalanceInvariant(LiquidityHubStorage storage s, address underlying) external view {
        LiquidityHubLib.confirmTakeBalanceInvariant(s, underlying);
    }

    function prepareSettle(LiquidityHubStorage storage s, address lcc, uint256 amount, address issuer) external {
        LiquidityHubLib.prepareSettle(s, lcc, amount, issuer);
    }

    function settleFromCustodian(
        LiquidityHubStorage storage s,
        address lcc,
        address custodian,
        uint256 tokenId,
        address recipient,
        uint256 maxAmount
    ) external returns (uint256 settled) {
        return LiquidityHubLib.settleFromCustodian(s, lcc, custodian, tokenId, recipient, maxAmount);
    }

    function annulSettlementBeforeTransfer(
        LiquidityHubStorage storage s,
        address lcc,
        address from,
        uint256 wrappedBalance,
        uint256 marketDerivedBalance,
        uint256 amountToTransfer
    ) external returns (uint256 toAnnul) {
        return LiquidityHubLib.annulSettlementBeforeTransfer(
            s, lcc, from, wrappedBalance, marketDerivedBalance, amountToTransfer
        );
    }
}

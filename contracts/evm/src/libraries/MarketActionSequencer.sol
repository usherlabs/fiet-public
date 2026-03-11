// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {IVaultCoreActionHandler} from "../interfaces/IVaultCoreActionHandler.sol";

/**
 * @title MarketActionSequencer
 * @notice Factory-scoped transient reconciler for transfer provenance and direct core actions.
 * @dev The sequencer intentionally separates:
 *      - transfer facts (`total`, `wrapped`) emitted by LCC
 *      - action facts (`swap`, `liquidity`) emitted by CoreHook
 *      Actions are resolved FIFO per market, while lane credits are cumulative per LCC.
 */
library MarketActionSequencer {
    using TransientSlot for *;

    uint256 internal constant ACTION_SWAP = 1;
    uint256 internal constant ACTION_LIQUIDITY = 2;

    bytes32 internal constant NAMESPACE_CREDIT_TOTAL = keccak256("MARKET_ACTION_CREDIT_TOTAL");
    bytes32 internal constant NAMESPACE_CREDIT_WRAPPED = keccak256("MARKET_ACTION_CREDIT_WRAPPED");
    bytes32 internal constant NAMESPACE_HEAD = keccak256("MARKET_ACTION_HEAD");
    bytes32 internal constant NAMESPACE_TAIL = keccak256("MARKET_ACTION_TAIL");
    bytes32 internal constant NAMESPACE_ACTION_TYPE = keccak256("MARKET_ACTION_TYPE");
    bytes32 internal constant NAMESPACE_ACTION_LCC0 = keccak256("MARKET_ACTION_LCC0");
    bytes32 internal constant NAMESPACE_ACTION_LCC1 = keccak256("MARKET_ACTION_LCC1");
    bytes32 internal constant NAMESPACE_ACTION_REMAINING0 = keccak256("MARKET_ACTION_REMAINING0");
    bytes32 internal constant NAMESPACE_ACTION_REMAINING1 = keccak256("MARKET_ACTION_REMAINING1");
    bytes32 internal constant NAMESPACE_ACTION_WRAPPED0 = keccak256("MARKET_ACTION_WRAPPED0");
    bytes32 internal constant NAMESPACE_ACTION_WRAPPED1 = keccak256("MARKET_ACTION_WRAPPED1");

    struct LaneCredit {
        uint256 total;
        uint256 wrapped;
    }

    /**
     * @notice Consumes currently available lane credit immediately.
     * @dev Returns both consumed total ingress and consumed wrapped ingress.
     */
    function consumeImmediate(address lcc, uint256 requestedAmount)
        internal
        returns (uint256 consumedTotal, uint256 consumedWrapped)
    {
        LaneCredit memory credit = _laneCredit(lcc);
        consumedTotal = requestedAmount < credit.total ? requestedAmount : credit.total;
        consumedWrapped = consumedTotal < credit.wrapped ? consumedTotal : credit.wrapped;
        if (consumedTotal > 0) {
            _setLaneCredit(lcc, credit.total - consumedTotal, credit.wrapped - consumedWrapped);
        }
    }

    function addIngress(address lcc, uint256 totalAmount, uint256 wrappedAmount) internal {
        if (wrappedAmount > totalAmount) {
            wrappedAmount = totalAmount;
        }
        bytes32 totalSlot = _slotForLcc(lcc, NAMESPACE_CREDIT_TOTAL);
        bytes32 wrappedSlot = _slotForLcc(lcc, NAMESPACE_CREDIT_WRAPPED);
        TransientSlot.asUint256(totalSlot).tstore(TransientSlot.asUint256(totalSlot).tload() + totalAmount);
        TransientSlot.asUint256(wrappedSlot).tstore(TransientSlot.asUint256(wrappedSlot).tload() + wrappedAmount);
    }

    function enqueueSwap(bytes32 marketId, address lccIn, uint256 amountIn) internal {
        uint256 tail = _tail(marketId);
        _setActionType(marketId, tail, ACTION_SWAP);
        _setActionLcc0(marketId, tail, lccIn);
        _setActionRemaining0(marketId, tail, amountIn);
        _setTail(marketId, tail + 1);
    }

    function enqueueLiquidity(bytes32 marketId, address lcc0, address lcc1, uint256 amount0, uint256 amount1) internal {
        uint256 tail = _tail(marketId);
        _setActionType(marketId, tail, ACTION_LIQUIDITY);
        _setActionLcc0(marketId, tail, lcc0);
        _setActionLcc1(marketId, tail, lcc1);
        _setActionRemaining0(marketId, tail, amount0);
        _setActionRemaining1(marketId, tail, amount1);
        _setTail(marketId, tail + 1);
    }

    function resolve(bytes32 marketId, address handler) internal {
        uint256 head = _head(marketId);
        uint256 tail = _tail(marketId);

        while (head < tail) {
            uint256 actionType = _actionType(marketId, head);
            if (actionType == ACTION_SWAP) {
                address lccIn = _actionLcc0(marketId, head);
                (uint256 remaining, uint256 wrappedAccrued) =
                    _consumeLane(lccIn, _actionRemaining0(marketId, head), _actionWrapped0(marketId, head));
                _setActionRemaining0(marketId, head, remaining);
                _setActionWrapped0(marketId, head, wrappedAccrued);

                if (remaining > 0) {
                    break;
                }

                IVaultCoreActionHandler(handler).handleSwap(lccIn, wrappedAccrued);
                _clearAction(marketId, head);
                head++;
                continue;
            }

            if (actionType == ACTION_LIQUIDITY) {
                address lcc0 = _actionLcc0(marketId, head);
                address lcc1 = _actionLcc1(marketId, head);

                (uint256 remaining0, uint256 wrapped0) =
                    _consumeLane(lcc0, _actionRemaining0(marketId, head), _actionWrapped0(marketId, head));
                (uint256 remaining1, uint256 wrapped1) =
                    _consumeLane(lcc1, _actionRemaining1(marketId, head), _actionWrapped1(marketId, head));

                _setActionRemaining0(marketId, head, remaining0);
                _setActionRemaining1(marketId, head, remaining1);
                _setActionWrapped0(marketId, head, wrapped0);
                _setActionWrapped1(marketId, head, wrapped1);

                if (remaining0 > 0 || remaining1 > 0) {
                    break;
                }

                IVaultCoreActionHandler(handler).handleAddLiquidity(wrapped0, wrapped1);
                _clearAction(marketId, head);
                head++;
                continue;
            }

            break;
        }

        _setHead(marketId, head);
    }

    function _consumeLane(address lcc, uint256 remaining, uint256 wrappedAccrued)
        private
        returns (uint256 newRemaining, uint256 newWrappedAccrued)
    {
        LaneCredit memory credit = _laneCredit(lcc);
        uint256 consumeTotal = remaining < credit.total ? remaining : credit.total;
        uint256 consumeWrapped = consumeTotal < credit.wrapped ? consumeTotal : credit.wrapped;

        if (consumeTotal > 0) {
            _setLaneCredit(lcc, credit.total - consumeTotal, credit.wrapped - consumeWrapped);
        }

        return (remaining - consumeTotal, wrappedAccrued + consumeWrapped);
    }

    function _laneCredit(address lcc) private view returns (LaneCredit memory credit) {
        credit.total = TransientSlot.asUint256(_slotForLcc(lcc, NAMESPACE_CREDIT_TOTAL)).tload();
        credit.wrapped = TransientSlot.asUint256(_slotForLcc(lcc, NAMESPACE_CREDIT_WRAPPED)).tload();
    }

    function _setLaneCredit(address lcc, uint256 total, uint256 wrapped) private {
        TransientSlot.asUint256(_slotForLcc(lcc, NAMESPACE_CREDIT_TOTAL)).tstore(total);
        TransientSlot.asUint256(_slotForLcc(lcc, NAMESPACE_CREDIT_WRAPPED)).tstore(wrapped);
    }

    function _head(bytes32 marketId) private view returns (uint256) {
        return TransientSlot.asUint256(_slotForMarket(marketId, NAMESPACE_HEAD)).tload();
    }

    function _setHead(bytes32 marketId, uint256 value) private {
        TransientSlot.asUint256(_slotForMarket(marketId, NAMESPACE_HEAD)).tstore(value);
    }

    function _tail(bytes32 marketId) private view returns (uint256) {
        return TransientSlot.asUint256(_slotForMarket(marketId, NAMESPACE_TAIL)).tload();
    }

    function _setTail(bytes32 marketId, uint256 value) private {
        TransientSlot.asUint256(_slotForMarket(marketId, NAMESPACE_TAIL)).tstore(value);
    }

    function _actionType(bytes32 marketId, uint256 idx) private view returns (uint256) {
        return TransientSlot.asUint256(_slotForAction(marketId, idx, NAMESPACE_ACTION_TYPE)).tload();
    }

    function _setActionType(bytes32 marketId, uint256 idx, uint256 actionType) private {
        TransientSlot.asUint256(_slotForAction(marketId, idx, NAMESPACE_ACTION_TYPE)).tstore(actionType);
    }

    function _actionLcc0(bytes32 marketId, uint256 idx) private view returns (address) {
        return address(uint160(TransientSlot.asUint256(_slotForAction(marketId, idx, NAMESPACE_ACTION_LCC0)).tload()));
    }

    function _setActionLcc0(bytes32 marketId, uint256 idx, address lcc) private {
        TransientSlot.asUint256(_slotForAction(marketId, idx, NAMESPACE_ACTION_LCC0)).tstore(uint256(uint160(lcc)));
    }

    function _actionLcc1(bytes32 marketId, uint256 idx) private view returns (address) {
        return address(uint160(TransientSlot.asUint256(_slotForAction(marketId, idx, NAMESPACE_ACTION_LCC1)).tload()));
    }

    function _setActionLcc1(bytes32 marketId, uint256 idx, address lcc) private {
        TransientSlot.asUint256(_slotForAction(marketId, idx, NAMESPACE_ACTION_LCC1)).tstore(uint256(uint160(lcc)));
    }

    function _actionRemaining0(bytes32 marketId, uint256 idx) private view returns (uint256) {
        return TransientSlot.asUint256(_slotForAction(marketId, idx, NAMESPACE_ACTION_REMAINING0)).tload();
    }

    function _setActionRemaining0(bytes32 marketId, uint256 idx, uint256 amount) private {
        TransientSlot.asUint256(_slotForAction(marketId, idx, NAMESPACE_ACTION_REMAINING0)).tstore(amount);
    }

    function _actionRemaining1(bytes32 marketId, uint256 idx) private view returns (uint256) {
        return TransientSlot.asUint256(_slotForAction(marketId, idx, NAMESPACE_ACTION_REMAINING1)).tload();
    }

    function _setActionRemaining1(bytes32 marketId, uint256 idx, uint256 amount) private {
        TransientSlot.asUint256(_slotForAction(marketId, idx, NAMESPACE_ACTION_REMAINING1)).tstore(amount);
    }

    function _actionWrapped0(bytes32 marketId, uint256 idx) private view returns (uint256) {
        return TransientSlot.asUint256(_slotForAction(marketId, idx, NAMESPACE_ACTION_WRAPPED0)).tload();
    }

    function _setActionWrapped0(bytes32 marketId, uint256 idx, uint256 amount) private {
        TransientSlot.asUint256(_slotForAction(marketId, idx, NAMESPACE_ACTION_WRAPPED0)).tstore(amount);
    }

    function _actionWrapped1(bytes32 marketId, uint256 idx) private view returns (uint256) {
        return TransientSlot.asUint256(_slotForAction(marketId, idx, NAMESPACE_ACTION_WRAPPED1)).tload();
    }

    function _setActionWrapped1(bytes32 marketId, uint256 idx, uint256 amount) private {
        TransientSlot.asUint256(_slotForAction(marketId, idx, NAMESPACE_ACTION_WRAPPED1)).tstore(amount);
    }

    function _clearAction(bytes32 marketId, uint256 idx) private {
        _setActionType(marketId, idx, 0);
        _setActionLcc0(marketId, idx, address(0));
        _setActionLcc1(marketId, idx, address(0));
        _setActionRemaining0(marketId, idx, 0);
        _setActionRemaining1(marketId, idx, 0);
        _setActionWrapped0(marketId, idx, 0);
        _setActionWrapped1(marketId, idx, 0);
    }

    function _slotForLcc(address lcc, bytes32 namespaceSlot) private pure returns (bytes32) {
        return EfficientHashLib.hash(abi.encodePacked(namespaceSlot, lcc));
    }

    function _slotForMarket(bytes32 marketId, bytes32 namespaceSlot) private pure returns (bytes32) {
        return EfficientHashLib.hash(abi.encodePacked(namespaceSlot, marketId));
    }

    function _slotForAction(bytes32 marketId, uint256 idx, bytes32 namespaceSlot) private pure returns (bytes32) {
        return EfficientHashLib.hash(abi.encodePacked(namespaceSlot, marketId, idx));
    }
}


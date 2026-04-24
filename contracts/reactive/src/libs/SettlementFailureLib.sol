// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @notice Shared helpers for compact settlement failure identity forwarding.
library SettlementFailureLib {
    uint8 internal constant FAILURE_CLASS_UNKNOWN = 0;
    uint8 internal constant FAILURE_CLASS_TERMINAL_POLICY = 1;
    uint8 internal constant FAILURE_CLASS_REQUIRES_FRESH_LIQUIDITY = 2;

    bytes4 internal constant NOT_APPROVED_SELECTOR = bytes4(keccak256("NotApproved(address)"));
    bytes4 internal constant LIQUIDITY_ERROR_SELECTOR = bytes4(keccak256("LiquidityError(address,uint256)"));

    function selectorFromRevertData(bytes memory revertData) internal pure returns (bytes4 selector) {
        if (revertData.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(revertData, 0x20))
        }
    }

    function classify(bytes4 failureSelector) internal pure returns (uint8 failureClass) {
        if (failureSelector == NOT_APPROVED_SELECTOR) {
            return FAILURE_CLASS_TERMINAL_POLICY;
        }
        if (failureSelector == LIQUIDITY_ERROR_SELECTOR) {
            return FAILURE_CLASS_REQUIRES_FRESH_LIQUIDITY;
        }
        return FAILURE_CLASS_UNKNOWN;
    }

    function isTerminal(uint8 failureClass) internal pure returns (bool) {
        return failureClass == FAILURE_CLASS_TERMINAL_POLICY;
    }

    function restoresBudget(uint8 failureClass) internal pure returns (bool) {
        return failureClass != FAILURE_CLASS_REQUIRES_FRESH_LIQUIDITY;
    }

    function requiresFreshLiquidity(uint8 failureClass) internal pure returns (bool) {
        return failureClass == FAILURE_CLASS_REQUIRES_FRESH_LIQUIDITY;
    }
}

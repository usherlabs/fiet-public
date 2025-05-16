// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/interfaces/IRFS.sol";

contract MockRFS is IRFS {
    function triggerRfS(
        address underlyingAsset,
        address custodian,
        address currency,
        uint256 amount
    ) external override {
        // This is a mock, so we intentionally do nothing here
        // Useful for testing without triggering real RfS logic
    }

    function queueWithdrawal(
        address recipient,
        address custodian,
        address currency,
        uint256 amount
    ) external override {
        // This is a mock, so we intentionally do nothing here
        // Useful for testing without triggering real RfS logic
    }
}

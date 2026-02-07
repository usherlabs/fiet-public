// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

contract MockLiquidityHub {
    event SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount);

    /// @notice Helper to emit SettlementQueued with supplied parameters.
    function triggerSettlementQueued(address lcc, address recipient, uint256 amount) external {
        emit SettlementQueued(lcc, recipient, amount);
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

contract MockLiquidityHub {
    mapping(address => bool) public shouldRevertForLcc;

    function setShouldRevert(address lcc, bool shouldRevert) external {
        shouldRevertForLcc[lcc] = shouldRevert;
    }

    function processSettlementFor(address lcc, address, uint256) external view {
        require(!shouldRevertForLcc[lcc], "mock-revert");
    }
}

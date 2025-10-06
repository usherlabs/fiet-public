// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IMarketLiquidity {
    function getMarketTotalSettlementDeficit(bytes32 marketId) external view returns (uint256);
}

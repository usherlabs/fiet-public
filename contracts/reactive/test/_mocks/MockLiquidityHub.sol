// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

contract MockLiquidityHub {
    event SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount);
    event LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId);
    event SettlementProcessed(
        address indexed lcc, address indexed recipient, uint256 settledAmount, uint256 requestedAmount
    );

    // keep track of the total amount disbursed for each lcc and recipient i.e the amount that has been settled for a given lcc and recipient
    mapping(address lcc => mapping(address recipient => uint256 amount)) private totalAmountSettled;

    uint256 public availableLiquidity;

    constructor() {
        availableLiquidity = uint256(type(uint256).max);
    }

    /// @notice Set the available liquidity for the mock liquidity hub.
    function setAvailableLiquidity(uint256 amount) external {
        availableLiquidity = amount;
    }

    /// @notice Helper to emit SettlementQueued with supplied parameters.
    function triggerSettlementQueued(address lcc, address recipient, uint256 amount) external {
        emit SettlementQueued(lcc, recipient, amount);
    }

    /// @notice Helper to emit LiquidityAvailable with supplied parameters.
    function triggerLiquidityAvailable(address lcc, address underlyingAsset, uint256 amount, bytes32 marketId)
        external
    {
        emit LiquidityAvailable(lcc, underlyingAsset, amount, marketId);
    }

    /// @notice Mock processSettlementFor entrypoint used by receiver tests.
    function processSettlementFor(address lcc, address recipient, uint256 maxAmount) external {
        // increment the total amount disbursed for the provided lcc and recipient
        uint256 amount = maxAmount < availableLiquidity ? maxAmount : availableLiquidity;
        totalAmountSettled[lcc][recipient] += amount;
        availableLiquidity -= amount;

        emit SettlementProcessed(lcc, recipient, amount, maxAmount);
    }

    /// @notice Returns the total amount settled for the provided lcc and recipient.
    function getTotalAmountSettled(address lcc, address recipient) external view returns (uint256) {
        return totalAmountSettled[lcc][recipient];
    }
}

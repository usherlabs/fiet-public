// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice Stand-in for `LiquidityHub` in tests and scripted e2e runs.
/// @dev Event signatures must match `contracts/evm/src/LiquidityHub.sol` so topics align with
///      `ReactiveConstants` and `HubRSC` ingestion. `SettlementSucceeded`, `SettlementFailed`, and
///      `MoreLiquidityAvailable` are not emitted here: HubRSC expects those from `destinationReceiverContract`
///      and `address(hub)` respectively, not from the liquidity hub address.
contract MockLiquidityHub {
    event LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId);
    event LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId);
    event SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount);
    event SettlementAnnulled(address indexed lcc, address indexed recipient, uint256 amount);
    event SettlementProcessed(
        address indexed lcc, address indexed recipient, uint256 settledAmount, uint256 requestedAmount
    );

    mapping(address lcc => mapping(address recipient => uint256 amount)) private totalAmountSettled;

    uint256 public availableLiquidity;

    constructor() {
        availableLiquidity = uint256(type(uint256).max);
    }

    /// @notice Set the available liquidity for the mock liquidity hub.
    function setAvailableLiquidity(uint256 amount) external {
        availableLiquidity = amount;
    }

    /// @notice Helper to emit `LCCCreated` with supplied parameters.
    function triggerLccCreated(address underlyingAsset, address lccToken, bytes32 marketId) external {
        emit LCCCreated(underlyingAsset, lccToken, marketId);
    }

    /// @notice Helper to emit `SettlementQueued` with supplied parameters.
    function triggerSettlementQueued(address lcc, address recipient, uint256 amount) external {
        emit SettlementQueued(lcc, recipient, amount);
    }

    /// @notice Helper to emit `LiquidityAvailable` with supplied parameters.
    function triggerLiquidityAvailable(address lcc, address underlyingAsset, uint256 amount, bytes32 marketId)
        external
    {
        emit LiquidityAvailable(lcc, underlyingAsset, amount, marketId);
    }

    /// @notice Helper to emit `SettlementAnnulled` with supplied parameters.
    function triggerSettlementAnnulled(address lcc, address recipient, uint256 amount) external {
        emit SettlementAnnulled(lcc, recipient, amount);
    }

    /// @notice Helper to emit `SettlementProcessed` without mutating settlement counters.
    function triggerSettlementProcessed(
        address lcc,
        address recipient,
        uint256 settledAmount,
        uint256 requestedAmount
    ) external {
        emit SettlementProcessed(lcc, recipient, settledAmount, requestedAmount);
    }

    /// @notice Mock `processSettlementFor` entrypoint used by receiver tests.
    function processSettlementFor(address lcc, address recipient, uint256 maxAmount) external {
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

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ILiquidityHub} from "./ILiquidityHub.sol";

/// @title IMMQueueCustodian
/// @notice MM queue custodian: one immutable beneficiary, beneficiary-global LCC custody, Hub queue ownership for `MMPositionManager`.
/// @dev Hub queue ownership for MM synthetic principal is keyed to this custodian (`settleQueue(lcc, address(custodian))`).
///      Custodied LCC principal is tracked per `lcc` only (no commitment buckets). Underlying is released to
///      `MMPositionManager` for pull withdrawal via locker `TAKE`, not pushed to EOAs from this contract.
interface IMMQueueCustodian {
    /// @notice Returns the MMPositionManager bound to this custodian
    function positionManager() external view returns (address);

    /// @notice Immutable beneficiary whose custodian this is (same key as `custodianFor[beneficiary]` on the manager).
    function beneficiary() external view returns (address);

    /// @notice Aggregate custodied LCC still outstanding for `lcc` (LCC units).
    /// @dev Used with `LiquidityHub.settleQueue(lcc, address(this))` to cap payout of underlying already received
    ///      when the Hub queue was settled permissionlessly before collect.
    function totalQueuedLcc(address lcc) external view returns (uint256);

    /// @notice Hub `unwrap` as this contract: shortfall queues to this custodian; immediate underlying is forwarded.
    function unwrapLccViaHub(address lcc, address forwardUnderlyingTo, uint256 amount, ILiquidityHub hub) external;

    /// @notice Records queued LCC that has already been transferred into custody (increments per-`lcc` balance).
    function record(address lcc, uint256 amount) external;

    /// @notice After Hub settlement, moves underlying from this custodian to the position manager (pull collect path).
    /// @dev Debits custodied LCC entitlement by `amount`; caller must be the bound position manager.
    function releaseSettledUnderlyingToManager(address lcc, uint256 amount) external;
}

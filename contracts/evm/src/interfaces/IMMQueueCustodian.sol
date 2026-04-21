// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ILiquidityHub} from "./ILiquidityHub.sol";

/// @title IMMQueueCustodian
/// @notice MM queue custodian: beneficiary-scoped LCC custody and Hub queue ownership for `MMPositionManager`.
/// @dev Custody is keyed by commitment `tokenId` (or utility bucket `0`), `lcc`, and `beneficiary`. Hub queue ownership
///      for MM synthetic principal is keyed to this custodian (`settleQueue(lcc, address(custodian))`); beneficiary
///      slices gate who may receive underlying after settlement. LCC leaves custody only via Hub settlement
///      (`processSettlementFor` + `collectUnderlyingToBeneficiary`), not a separate pre-settlement `release` path.
///      Commit buckets may also be drained via four-word `COLLECT_AVAILABLE_LIQUIDITY` params, which pays only the named beneficiary.
interface IMMQueueCustodian {
    /// @notice Returns the MMPositionManager bound to this custodian
    function positionManager() external view returns (address);

    /// @notice Aggregate beneficiary-scoped custody still outstanding for `lcc` (LCC units), across all buckets.
    /// @dev Used with `LiquidityHub.settleQueue(lcc, address(this))` to cap payout of underlying already received
    ///      when the Hub queue was settled permissionlessly before `COLLECT_AVAILABLE_LIQUIDITY`.
    function totalQueuedLcc(address lcc) external view returns (uint256);

    /// @notice Reads custodied LCC balance for a bucket, LCC, and beneficiary slice.
    function queued(uint256 tokenId, address lcc, address beneficiary) external view returns (uint256);

    /// @notice Hub `unwrap` as this contract: shortfall queues to this custodian; immediate underlying is forwarded.
    function unwrapLccViaHub(
        address lcc,
        address forwardUnderlyingTo,
        address beneficiary,
        uint256 bucketId,
        uint256 amount,
        ILiquidityHub hub
    ) external;

    /// @notice Records queued LCC that has already been transferred into custody
    /// @param tokenId The commitment token id whose custody bucket is being credited (or utility bucket, e.g. `0`)
    /// @param lcc The LCC token address
    /// @param beneficiary The party entitled to this slice (locker / seizer for underlying payout after settlement)
    /// @param amount Amount transferred into custody
    function record(uint256 tokenId, address lcc, address beneficiary, uint256 amount) external;

    /// @notice After `LiquidityHub.processSettlementFor` has paid underlying to this custodian, forwards that slice to the beneficiary.
    /// @dev Caller must be the bound position manager; debits beneficiary-scoped entitlement by `amount`.
    function collectUnderlyingToBeneficiary(uint256 tokenId, address lcc, address beneficiary, uint256 amount) external;

    /// @notice True when the given bucket (`0` = utility unwrap, `tokenId` = commitment id) has no recorded custody slices.
    function isBucketEmpty(uint256 bucketId) external view returns (bool);
}

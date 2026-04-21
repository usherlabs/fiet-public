// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IQueueCustodian
/// @notice Minimal interface for beneficiary-scoped queued LCC custody used by MM queue owners.
/// @dev `bucketId` is an opaque bucket key (for example commitment NFT id, or a utility sentinel such as `0` for
///      `UNWRAP_LCC` shortfalls). Implementations map `(bucketId, lcc, beneficiary)` to a custodied LCC slice that
///      must align with `LiquidityHub.settleQueue(lcc, queueOwner)` when the queue owner is the custodian contract.
interface IQueueCustodian {
    /// @notice Reads custodied LCC balance for a bucket, LCC, and beneficiary slice.
    function queued(uint256 bucketId, address lcc, address beneficiary) external view returns (uint256);

    /// @notice Releases up to `maxAmount` of custodied LCC to `beneficiary`, debiting the slice.
    /// @return released Actual amount released (capped by slice balance).
    function release(uint256 bucketId, address lcc, address beneficiary, uint256 maxAmount)
        external
        returns (uint256 released);
}

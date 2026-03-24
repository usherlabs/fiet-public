// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IMMQueueCustodian
/// @notice Custody interface for queued MM-backed LCC balances
/// @dev Custody is keyed by commitment `tokenId`, `lcc`, and `beneficiary`. The beneficiary MUST match the
///      LiquidityHub `settleQueue(lcc, beneficiary)` recipient for that staged principal so a caller cannot
///      pair their own queue with another party's commit bucket (see MMPositionManager._collectAvailableLiquidity).
interface IMMQueueCustodian {
    /// @notice Returns the MMPositionManager bound to this custodian
    function positionManager() external view returns (address);

    /// @notice Binds the position manager once
    /// @dev Must be called by the pre-authorised binder
    function setPositionManager(address _positionManager) external;

    /// @notice Records queued LCC that has already been transferred into custody
    /// @param tokenId The commitment token id whose custody bucket is being credited
    /// @param lcc The LCC token address
    /// @param beneficiary The party entitled to release this slice (must match Hub queue recipient for that flow)
    /// @param amount Amount transferred into custody
    function record(uint256 tokenId, address lcc, address beneficiary, uint256 amount) external;

    /// @notice Releases queued LCC from a beneficiary's slice under a commitment bucket
    /// @param tokenId The commitment token id bucket to debit
    /// @param lcc The LCC token address
    /// @param beneficiary The slice owner; released LCC is transferred to this address
    /// @param maxAmount Maximum amount requested for release
    /// @return released Actual amount released (capped by slice balance)
    function release(uint256 tokenId, address lcc, address beneficiary, uint256 maxAmount)
        external
        returns (uint256 released);

    /// @notice Reads queued custody balance for a commitment bucket, LCC, and beneficiary
    function queued(uint256 tokenId, address lcc, address beneficiary) external view returns (uint256);

}

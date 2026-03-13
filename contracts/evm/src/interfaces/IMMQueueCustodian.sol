// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IMMQueueCustodian
/// @notice Custody interface for queued MM-backed LCC balances
interface IMMQueueCustodian {
    /// @notice Returns the MMPositionManager bound to this custodian
    function positionManager() external view returns (address);

    /// @notice Binds the position manager once
    /// @dev Must be called by the pre-authorised binder
    function setPositionManager(address _positionManager) external;

    /// @notice Records queued LCC that has already been transferred into custody
    /// @param tokenId The commitment token id whose custody bucket is being credited
    /// @param lcc The LCC token address
    /// @param amount Amount transferred into custody
    function record(uint256 tokenId, address lcc, uint256 amount) external;

    /// @notice Releases queued LCC from a specific commitment bucket
    /// @param tokenId The commitment token id bucket to debit
    /// @param lcc The LCC token address
    /// @param recipient Recipient to receive LCC for settlement burn
    /// @param maxAmount Maximum amount requested for release
    /// @return released Actual amount released (capped by bucket balance)
    function release(uint256 tokenId, address lcc, address recipient, uint256 maxAmount)
        external
        returns (uint256 released);

    /// @notice Reads queued custody balance for a commitment bucket and LCC
    function queued(uint256 tokenId, address lcc) external view returns (uint256);
}

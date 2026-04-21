// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IQueueCustodian} from "./IQueueCustodian.sol";

/// @title IMMQueueCustodian
/// @notice MM queue custodian: extends generic `IQueueCustodian` with deployment and producer APIs used by
///         `MMPositionManager` / `MMPositionActionsImpl`.
/// @dev Custody is keyed by commitment `tokenId` (or utility bucket), `lcc`, and `beneficiary`. Hub queue ownership
///      for MM synthetic principal is keyed to this custodian (`settleQueue(lcc, address(custodian))`); beneficiary
///      slices gate who may receive underlying after settlement.
interface IMMQueueCustodian is IQueueCustodian {
    /// @notice Returns the MMPositionManager bound to this custodian
    function positionManager() external view returns (address);

    /// @notice Binds the position manager once
    /// @dev Must be called by the pre-authorised binder
    function setPositionManager(address _positionManager) external;

    /// @notice Records queued LCC that has already been transferred into custody
    /// @param tokenId The commitment token id whose custody bucket is being credited (or utility bucket, e.g. `0`)
    /// @param lcc The LCC token address
    /// @param beneficiary The party entitled to release this slice (must match Hub queue recipient for that flow)
    /// @param amount Amount transferred into custody
    function record(uint256 tokenId, address lcc, address beneficiary, uint256 amount) external;

    /// @notice After `LiquidityHub.processSettlementFor` has paid underlying to this custodian, forwards that slice to the beneficiary.
    /// @dev Caller must be the bound position manager; debits beneficiary-scoped entitlement by `amount`.
    function collectUnderlyingToBeneficiary(uint256 tokenId, address lcc, address beneficiary, uint256 amount) external;

    /// @notice True when this custodian has no beneficiary entitlement remaining and holds no stray native balance.
    function isEmpty() external view returns (bool);

    /// @notice True when the given bucket (`0` = utility unwrap, `tokenId` = commitment id) has no recorded custody slices.
    function isBucketEmpty(uint256 bucketId) external view returns (bool);
}

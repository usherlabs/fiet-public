// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IQueueCustodian} from "./IQueueCustodian.sol";

/// @title IMMQueueCustodian
/// @notice MM queue custodian: extends generic `IQueueCustodian` with deployment and producer APIs used by
///         `MMPositionManager` / `MMPositionActionsImpl`.
/// @dev Custody is keyed by commitment `tokenId` (or utility bucket), `lcc`, and `beneficiary`. The beneficiary MUST
///      match the LiquidityHub `settleQueue(lcc, beneficiary)` recipient for that staged principal so a caller cannot
///      pair their own queue with another party's commit bucket (see `MMPositionManager._collectAvailableLiquidity`).
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
}

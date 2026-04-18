// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IEndpointUnwrapAdmission
/// @notice Optional view hook for `BOUND_ENDPOINT` callers of `LiquidityHub.unwrapTo` so admission headroom can
///         count beneficiary-scoped queued LCC held off-router (e.g. `MMQueueCustodian` for `UNWRAP_LCC` shortfalls).
interface IEndpointUnwrapAdmission {
    /// @notice Amount of LCC the endpoint treats as backing existing queue claims for `beneficiary`, not on the endpoint balance.
    /// @dev Must be capped by the Hub against `settleQueue[lcc][beneficiary]`; implementations return raw custody slice.
    function unwrapAdmissionCredit(address lcc, address beneficiary) external view returns (uint256);
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IMarketFactory} from "./IMarketFactory.sol";

/// @title IMMQueueCustodianFactory
/// @notice Deploys `MMQueueCustodian` instances bound to the calling MMPM (`msg.sender`).
/// @dev `deploy` succeeds only when `marketFactory.bounds(msg.sender)` is true for the supplied factory namespace.
interface IMMQueueCustodianFactory {
    /// @notice Deploys a new queue custodian for `msg.sender` (the MMPM).
    /// @param recipient Recipient key used for idempotence / future salt schemes; must be non-zero.
    /// @param marketFactory Factory namespace used to validate `msg.sender` via `bounds`.
    /// @return custodian Address of the deployed `MMQueueCustodian`.
    function deploy(address recipient, IMarketFactory marketFactory) external returns (address custodian);
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IMMQueueCustodian} from "../interfaces/IMMQueueCustodian.sol";

/// @title PositionManagerQueueCustodian
/// @notice Optional abstraction for MM position managers that route queued LCC via a custodian
abstract contract PositionManagerQueueCustodian {
    /// @notice Returns the shared queue custodian address used by MM position manager flows
    function _queueCustodian() internal view virtual returns (IMMQueueCustodian);
}

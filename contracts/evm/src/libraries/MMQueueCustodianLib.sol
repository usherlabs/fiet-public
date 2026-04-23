// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IMMPositionManager} from "../interfaces/IMMPositionManager.sol";
import {IMMQueueCustodian} from "../interfaces/IMMQueueCustodian.sol";

/// @title MMQueueCustodianLib
/// @notice Shared view helpers for validating queue custodian contracts against `IMMPositionManager.custodianFor`.
library MMQueueCustodianLib {
    /// @notice True if `candidate` is the registered queue custodian for its declared beneficiary on `manager`.
    function isRegisteredCustodian(IMMPositionManager manager, address candidate) internal view returns (bool) {
        if (candidate.code.length == 0) return false;
        (bool ok, bytes memory data) = candidate.staticcall(abi.encodeCall(IMMQueueCustodian.beneficiary, ()));
        if (!ok || data.length < 32) return false;
        address beneficiary = abi.decode(data, (address));
        if (beneficiary == address(0)) return false;
        return manager.custodianFor(beneficiary) == candidate;
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {MMQueueCustodian} from "./MMQueueCustodian.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {IMMQueueCustodianFactory} from "./interfaces/IMMQueueCustodianFactory.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title MMQueueCustodianFactory
/// @notice Stateless factory: deploys recipient-keyed queue custodians bound to the caller MMPM.
/// @dev Authorisation reuses `MarketFactory` bound-endpoint registration (`bounds(msg.sender)`).
contract MMQueueCustodianFactory is IMMQueueCustodianFactory {
    /// @inheritdoc IMMQueueCustodianFactory
    function deploy(address recipient, IMarketFactory marketFactory) external returns (address custodian) {
        if (recipient == address(0)) revert Errors.InvalidAddress(recipient);
        if (!marketFactory.bounds(msg.sender)) revert Errors.InvalidSender();
        custodian = address(new MMQueueCustodian(msg.sender));
    }
}

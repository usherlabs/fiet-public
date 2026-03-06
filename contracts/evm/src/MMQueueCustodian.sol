// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title MMQueueCustodian
/// @notice Shared custody for queued MM-backed LCC balances, bucketed by commitment token id
contract MMQueueCustodian is IMMQueueCustodian {
    using CurrencyTransfer for Currency;

    address public positionManager;

    // tokenId => lcc => queued custody balance
    // @note: While LiquidityHub.settleQueue is source of truth, this accounting is specific for queued LCC as a result of MMPositionManager position decrease.
    mapping(uint256 tokenId => mapping(address lcc => uint256 amount)) private _queuedLcc;

    modifier onlyPositionManager() {
        if (msg.sender != positionManager) revert Errors.InvalidSender();
        _;
    }

    function setPositionManager(address _positionManager) external {
        if (_positionManager == address(0)) revert Errors.InvalidAddress(_positionManager);
        if (positionManager != address(0)) revert Errors.InvalidSender();
        // Only the target position manager may self-bind this custodian.
        if (msg.sender != _positionManager) revert Errors.InvalidSender();
        positionManager = _positionManager;
    }

    function record(uint256 tokenId, address lcc, uint256 amount) external onlyPositionManager {
        if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
        if (amount == 0) return;
        _queuedLcc[tokenId][lcc] += amount;
    }

    function release(uint256 tokenId, address lcc, address recipient, uint256 maxAmount)
        external
        onlyPositionManager
        returns (uint256 released)
    {
        if (recipient == address(0)) revert Errors.InvalidAddress(recipient);
        if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
        if (maxAmount == 0) return 0;

        uint256 available = _queuedLcc[tokenId][lcc];
        released = available < maxAmount ? available : maxAmount;
        if (released == 0) return 0;

        _queuedLcc[tokenId][lcc] = available - released;
        Currency.wrap(lcc).transfer(recipient, released);
    }

    function queued(uint256 tokenId, address lcc) external view returns (uint256) {
        return _queuedLcc[tokenId][lcc];
    }
}

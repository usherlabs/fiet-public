// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IMMQueueCustodian} from "../../../src/interfaces/IMMQueueCustodian.sol";
import {Errors} from "../../../src/libraries/Errors.sol";
import {IFuzzTakeOrchestrator} from "../harnesses/IFuzzTakeOrchestrator.sol";

/// @notice Records `take` calls for MMQ-01 visibility without moving funds.
contract FuzzTakeOrchestratorMock is IFuzzTakeOrchestrator {
    Currency public lastCurrency;
    address public lastTarget;
    uint256 public lastMaxAmount;
    uint256 public takeCallCount;

    function take(Currency currency, address target, uint256 maxAmount) external returns (uint256 taken) {
        lastCurrency = currency;
        lastTarget = target;
        lastMaxAmount = maxAmount;
        takeCallCount++;
        return maxAmount;
    }
}

/// @notice Minimal `IMMQueueCustodian` used by the composed MMQ-01 fuzz module.
contract FuzzMMQueueCustodian is IMMQueueCustodian {
    address public immutable authorisedBinder;
    address public override positionManager;

    mapping(uint256 tokenId => mapping(address lcc => mapping(address beneficiary => uint256 amount))) private _queued;

    modifier onlyPositionManager() {
        if (msg.sender != positionManager) revert Errors.InvalidSender();
        _;
    }

    constructor(address authorisedBinder_) {
        if (authorisedBinder_ == address(0)) revert Errors.InvalidAddress(authorisedBinder_);
        authorisedBinder = authorisedBinder_;
    }

    function setPositionManager(address positionManager_) external override {
        if (msg.sender != authorisedBinder) revert Errors.InvalidSender();
        if (positionManager != address(0)) revert Errors.InvalidSender();
        if (positionManager_ == address(0) || positionManager_.code.length == 0) {
            revert Errors.InvalidAddress(positionManager_);
        }
        positionManager = positionManager_;
    }

    function record(uint256 tokenId, address lcc, address beneficiary, uint256 amount)
        external
        override
        onlyPositionManager
    {
        if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
        if (beneficiary == address(0)) revert Errors.InvalidAddress(beneficiary);
        if (amount == 0) return;
        _queued[tokenId][lcc][beneficiary] += amount;
    }

    function queued(uint256 tokenId, address lcc, address beneficiary) external view override returns (uint256) {
        return _queued[tokenId][lcc][beneficiary];
    }

    function release(uint256, address, address, uint256) external pure override returns (uint256) {
        return 0;
    }
}

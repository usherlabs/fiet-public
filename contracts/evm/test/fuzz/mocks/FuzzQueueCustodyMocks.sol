// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IFuzzTakeOrchestrator} from "../harnesses/IFuzzTakeOrchestrator.sol";
import {IMMQueueCustodian} from "../../../src/interfaces/IMMQueueCustodian.sol";
import {ILiquidityHub} from "../../../src/interfaces/ILiquidityHub.sol";
import {Errors} from "../../../src/libraries/Errors.sol";

/// @notice Records `take` calls for fuzz visibility; does not move tokens (sufficient for routing-guard coverage).
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

/// @notice Minimal `IMMQueueCustodian` for the composed Medusa fuzz harnesses.
/// @dev Constructor binds `authorisedBinder` only; `wirePositionManager` breaks the harness↔custodian circular `new`
///      (production deploys via `MMQueueCustodianFactory` bound to the MMPM).
contract FuzzMMQueueCustodian is IMMQueueCustodian {
    address public immutable authorisedBinder;

    address public override positionManager;
    address public override beneficiary;

    mapping(address lcc => uint256) private _queued;

    modifier onlyPositionManager() {
        if (msg.sender != positionManager) revert Errors.InvalidSender();
        _;
    }

    constructor(address authorisedBinder_, address beneficiary_) {
        if (authorisedBinder_ == address(0)) revert Errors.InvalidAddress(authorisedBinder_);
        if (beneficiary_ == address(0)) revert Errors.InvalidAddress(beneficiary_);
        authorisedBinder = authorisedBinder_;
        beneficiary = beneficiary_;
    }

    /// @notice One-time link after `new PositionManagerImplQueueCustodyHarness(..., this)`.
    function wirePositionManager(address _positionManager) external {
        if (msg.sender != authorisedBinder) revert Errors.InvalidSender();
        if (positionManager != address(0)) revert Errors.InvalidSender();
        if (_positionManager == address(0) || _positionManager.code.length == 0) {
            revert Errors.InvalidAddress(_positionManager);
        }
        positionManager = _positionManager;
    }

    function unwrapLccViaHub(address, address, uint256, ILiquidityHub) external pure override {}

    function record(address lcc, uint256 amount) external override onlyPositionManager {
        if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
        if (amount == 0) return;
        _queued[lcc] += amount;
    }

    function totalQueuedLcc(address lcc) external view override returns (uint256) {
        return _queued[lcc];
    }

    function releaseSettledUnderlyingToManager(address lcc, uint256 amount) external override onlyPositionManager {
        if (amount == 0) return;
        uint256 q = _queued[lcc];
        if (q < amount) revert Errors.InsufficientBalance(q, amount);
        _queued[lcc] = q - amount;
    }
}

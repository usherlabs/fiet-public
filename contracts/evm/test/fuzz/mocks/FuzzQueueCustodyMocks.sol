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
///      (production uses `new MMQueueCustodian(mmpm)` with no second step).
contract FuzzMMQueueCustodian is IMMQueueCustodian {
    address public immutable authorisedBinder;

    address public override positionManager;

    mapping(uint256 tokenId => mapping(address lcc => mapping(address beneficiary => uint256 amount))) private _queued;
    mapping(uint256 bucketId => uint256 total) private _bucketTotals;

    modifier onlyPositionManager() {
        if (msg.sender != positionManager) revert Errors.InvalidSender();
        _;
    }

    constructor(address authorisedBinder_) {
        if (authorisedBinder_ == address(0)) revert Errors.InvalidAddress(authorisedBinder_);
        authorisedBinder = authorisedBinder_;
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

    function unwrapLccViaHub(address, address, address, uint256, uint256, ILiquidityHub) external pure override {}

    function record(uint256 tokenId, address lcc, address beneficiary, uint256 amount)
        external
        override
        onlyPositionManager
    {
        if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
        if (beneficiary == address(0)) revert Errors.InvalidAddress(beneficiary);
        if (amount == 0) return;
        _queued[tokenId][lcc][beneficiary] += amount;
        _bucketTotals[tokenId] += amount;
    }

    function isBucketEmpty(uint256 bucketId) external view override returns (bool) {
        return _bucketTotals[bucketId] == 0;
    }

    function queued(uint256 tokenId, address lcc, address beneficiary) external view override returns (uint256) {
        return _queued[tokenId][lcc][beneficiary];
    }

    function collectUnderlyingToBeneficiary(uint256, address, address, uint256) external pure override {}
}

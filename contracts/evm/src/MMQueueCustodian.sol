// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title MMQueueCustodian
/// @notice Shared custody for queued MM-backed LCC balances, bucketed by commitment token id and beneficiary
/// @dev Beneficiary-scoped slices prevent cross-composition: Hub queue is per-(lcc, recipient); custody must
///      align so COLLECT_AVAILABLE_LIQUIDITY cannot spend another recipient's LCC under the same tokenId.
///
///      Intended model:
///      - `beneficiary` is always the MM batch locker whose `LiquidityHub.settleQueue(lcc, beneficiary)` entry
///        was created for that staged principal (see `VTSPositionLib` queue recipient == hook `locker`).
///      - Normal decreases: locker is the authorised party acting on the commitment (typically owner or approved operator).
///      - Seizure decreases: locker is the seizer. Custody and queue (when present) both attribute to that locker.
contract MMQueueCustodian is IMMQueueCustodian {
    using CurrencyTransfer for Currency;

    /// @notice Beneficiary-scoped custody increased (MM-backed LCC staged for later Hub settlement).
    event CustodyRecorded(uint256 indexed tokenId, address indexed lcc, address indexed beneficiary, uint256 amount);

    /// @notice Beneficiary-scoped custody decreased and LCC transferred out.
    event CustodyReleased(uint256 indexed tokenId, address indexed lcc, address indexed beneficiary, uint256 amount);

    /// @notice One-time authoriser allowed to bind the position manager.
    address public authorisedBinder;
    address public override positionManager;

    // tokenId => lcc => beneficiary => queued custody balance
    mapping(uint256 tokenId => mapping(address lcc => mapping(address beneficiary => uint256 amount))) private
        _queuedLcc;

    modifier onlyPositionManager() {
        if (msg.sender != positionManager) revert Errors.InvalidSender();
        _;
    }

    constructor(address _authorisedBinder) {
        if (_authorisedBinder == address(0)) revert Errors.InvalidAddress(_authorisedBinder);
        authorisedBinder = _authorisedBinder;
    }

    function setPositionManager(address _positionManager) external override {
        if (msg.sender != authorisedBinder) revert Errors.InvalidSender();
        if (positionManager != address(0)) revert Errors.InvalidSender();
        if (_positionManager == address(0) || _positionManager.code.length == 0) {
            revert Errors.InvalidAddress(_positionManager);
        }
        positionManager = _positionManager;
        authorisedBinder = address(0);
    }

    function record(uint256 tokenId, address lcc, address beneficiary, uint256 amount)
        external
        override
        onlyPositionManager
    {
        if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
        if (beneficiary == address(0)) revert Errors.InvalidAddress(beneficiary);
        if (amount == 0) return;
        _queuedLcc[tokenId][lcc][beneficiary] += amount;
        emit CustodyRecorded(tokenId, lcc, beneficiary, amount);
    }

    // Releases LCC to recipient before processSettlementFor is called.
    function release(uint256 tokenId, address lcc, address beneficiary, uint256 maxAmount)
        external
        override
        returns (uint256 released)
    {
        if (beneficiary == address(0)) revert Errors.InvalidAddress(beneficiary);
        if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
        if (msg.sender != positionManager) {
            (bool ok, bytes memory data) = lcc.staticcall(abi.encodeCall(ILCC.hub, ()));
            if (!ok || data.length < 32 || msg.sender != abi.decode(data, (address))) revert Errors.InvalidSender();
        }
        if (maxAmount == 0) return 0;

        uint256 available = _queuedLcc[tokenId][lcc][beneficiary];
        released = available < maxAmount ? available : maxAmount;
        if (released == 0) return 0;

        _queuedLcc[tokenId][lcc][beneficiary] = available - released;
        emit CustodyReleased(tokenId, lcc, beneficiary, released);
        Currency.wrap(lcc).transfer(beneficiary, released);
    }

    function queued(uint256 tokenId, address lcc, address beneficiary) external view override returns (uint256) {
        return _queuedLcc[tokenId][lcc][beneficiary];
    }
}

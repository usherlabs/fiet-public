// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {ReentrancyLock} from "v4-periphery/src/base/ReentrancyLock.sol";
import {Multicall_v4} from "v4-periphery/src/base/Multicall_v4.sol";
import {BaseActionsRouter} from "v4-periphery/src/base/BaseActionsRouter.sol";
import {Permit2Forwarder} from "v4-periphery/src/base/Permit2Forwarder.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
import {IMMPMActionsImpl} from "./interfaces/IMMPMActionsImpl.sol";
import {PositionId, Position} from "./types/Position.sol";
import {MarketMaker} from "./libraries/MarketMaker.sol";

/// @title MMPositionManager
/// @notice Entry point for VRL commitment position management
/// @dev Delegates action execution and ERC721 operations to MMPMActionsImpl via delegatecall
contract MMPositionManager is IMMPositionManager, ReentrancyLock, Multicall_v4, Permit2Forwarder, BaseActionsRouter {
    // ═══════════════════════════════════════════════════════════════════════════
    // Immutables
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The implementation contract for all logic
    address public immutable actionsImpl;

    // ═══════════════════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address _manager, address _actionsImpl, IAllowanceTransfer _permit2)
        BaseActionsRouter(IPoolManager(_manager))
        Permit2Forwarder(_permit2)
    {
        actionsImpl = _actionsImpl;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BaseActionsRouter Overrides
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc BaseActionsRouter
    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Entry Points
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Executes a batch of liquidity modifications
    /// @dev Mirrors v4 PositionManager.modifyLiquidities
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable isNotLocked {
        // Call before hook on impl
        _delegateToImpl(abi.encodeWithSelector(IMMPMActionsImpl.beforeEntrypoint.selector, deadline));

        _executeActions(unlockData);

        // Call after hook on impl
        _delegateToImpl(abi.encodeWithSelector(IMMPMActionsImpl.afterEntrypoint.selector));
    }

    /// @notice Executes actions without acquiring a new unlock
    /// @dev Mirrors v4 PositionManager.modifyLiquiditiesWithoutUnlock
    function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params)
        external
        payable
        isNotLocked
    {
        // Call before hook on impl (no deadline check)
        _delegateToImpl(abi.encodeWithSelector(IMMPMActionsImpl.beforeEntrypoint.selector, type(uint256).max));

        _executeActionsWithoutUnlock(actions, params);

        // Call after hook on impl
        _delegateToImpl(abi.encodeWithSelector(IMMPMActionsImpl.afterEntrypoint.selector));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Action Dispatcher (delegatecall to implementation)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Handles action execution by delegating to the actions implementation
    /// @dev All action logic is in MMPMActionsImpl, called via delegatecall to share storage context
    function _handleAction(uint256 action, bytes calldata params) internal virtual override {
        _delegateToImpl(abi.encodeWithSelector(IMMPMActionsImpl.handleAction.selector, action, params));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Delegation Helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Delegates a call to the implementation contract
    function _delegateToImpl(bytes memory data) internal {
        (bool success, bytes memory result) = actionsImpl.delegatecall(data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Fallback - Delegates ERC721 & other calls to implementation
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Fallback delegates all unmatched calls to impl (ERC721 functions, views, etc.)
    fallback() external payable {
        address impl = actionsImpl;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}

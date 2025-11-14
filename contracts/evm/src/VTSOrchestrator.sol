// SPDX-License-Identifier: MIT
// This contract is the central state management layer and orchestrator for VTS logic
// Adopts Bunni-style pattern: state in storage struct, logic delegated to linked libraries
pragma solidity ^0.8.26;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionId} from "./types/Position.sol";
import {Commit} from "./types/Commit.sol";
import {Pool} from "./types/Pool.sol";
import {Position} from "./types/Position.sol";
import {MarketVTSConfiguration} from "./types/VTS.sol";
import {MarketMaker} from "./libraries/MarketMaker.sol";
import {
    IPoolManager
} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {VTSStorage} from "./types/VTS.sol";
// Import VTSLogic library once created (for delegation)
// import {VTSLogic} from "./lib/VTSLogic.sol";

/// @notice Custom errors for VTSOrchestrator
error VTSOrchestrator__InvalidPoolManager();
error VTSOrchestrator__InvalidOwner();

/// @title VTSOrchestrator
/// @notice Central state management layer and orchestrator for VTS logic
/// @dev Adopts Bunni-style pattern: state managed in VTSStorage struct, complex logic delegated to linked libraries
contract VTSOrchestrator is Ownable {
    /// @notice Central storage pointer (passed to libraries)
    VTSStorage internal s;

    /// @notice Immutable pool manager reference
    IPoolManager public immutable poolManager;

    /// @notice Constructor
    /// @param _poolManager The Uniswap V4 PoolManager address
    /// @param initialOwner The initial owner address
    constructor(
        address _poolManager,
        address initialOwner
    ) Ownable(initialOwner) {
        if (_poolManager == address(0))
            revert VTSOrchestrator__InvalidPoolManager();
        if (initialOwner == address(0)) revert VTSOrchestrator__InvalidOwner();
        poolManager = IPoolManager(_poolManager);
    }

    /// @notice Get position by PositionId
    /// @param positionId The position identifier
    /// @return The Position struct
    function getPosition(
        PositionId positionId
    ) external view returns (Position memory) {
        return s.positions[positionId];
    }

    /// @notice Get commit by tokenId
    /// @dev Note: Cannot return Commit directly due to mapping in struct
    /// @param tokenId The commit token identifier
    /// @return mmState The MarketMaker state
    /// @return expiresAt The expiration timestamp
    /// @return poolId The bound pool ID
    /// @return positionCount The count of positions
    /// @return deficitBps The deficit basis points
    function getCommit(
        uint256 tokenId
    )
        external
        view
        returns (
            MarketMaker.State memory mmState,
            uint256 expiresAt,
            uint256 positionCount,
            uint256 deficitBps
        )
    {
        Commit storage commit = s.commits[tokenId];
        return (
            commit.mmState,
            commit.expiresAt,
            commit.positionCount,
            commit.deficitBps
        );
    }

    /// @notice Get position ID for a commit at a specific index
    /// @param tokenId The commit token identifier
    /// @param positionIndex The position index
    /// @return The PositionId at the given index
    function getCommitPosition(
        uint256 tokenId,
        uint256 positionIndex
    ) external view returns (PositionId) {
        return s.commits[tokenId].positions[positionIndex];
    }

    /// @notice Get pool by PoolId
    /// @dev Note: Cannot return Pool directly due to mapping in struct
    /// @param poolId The pool identifier
    /// @return id The pool ID
    /// @return currency0 Token0 currency
    /// @return currency1 Token1 currency
    /// @return vtsConfig The VTS configuration
    /// @return isPaused Whether pool is paused
    function getPool(
        PoolId poolId
    )
        external
        view
        returns (
            PoolId id,
            Currency currency0,
            Currency currency1,
            MarketVTSConfiguration memory vtsConfig,
            bool isPaused
        )
    {
        Pool storage pool = s.pools[poolId];
        return (
            pool.id,
            pool.currency0,
            pool.currency1,
            pool.vtsConfig,
            pool.isPaused
        );
    }

    /// @notice Set global pause flag
    /// @param paused Whether to pause all operations
    function setPaused(bool paused) external onlyOwner {
        s.isPaused = paused;
    }

    /// @notice Get global pause status
    /// @return Whether operations are paused
    function isPaused() external view returns (bool) {
        return s.isPaused;
    }

    // TODO: Add functions to delegate complex logic to VTSLogic library
    // Example:
    // function settle(PositionId positionId, ...) external nonReentrant {
    //     require(!s.isPaused, "VTSOrchestrator: paused");
    //     return VTSLogic.settle(s, Env({poolManager: poolManager, ...}), positionId, ...);
    // }
}

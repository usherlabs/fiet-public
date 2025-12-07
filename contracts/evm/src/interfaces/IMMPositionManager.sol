// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PositionId, Position} from "../types/Position.sol";
import {MarketMaker} from "../libraries/MarketMaker.sol";

/// @title IMMPositionManager
/// @notice Interface for the MMPositionManager contract
interface IMMPositionManager {
    /// @notice Unlocks Uniswap v4 PoolManager and batches actions for modifying liquidity
    /// @dev This is the standard entrypoint for the MMPositionManager
    /// @param unlockData is an encoding of actions, and parameters for those actions
    /// @param deadline is the deadline for the batched actions to be executed
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;

    /// @notice Batches actions for modifying liquidity without unlocking v4 PoolManager
    /// @dev This must be called by a contract that has already unlocked the v4 PoolManager
    /// @param actions the actions to perform
    /// @param params the parameters to provide for the actions
    function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params) external payable;

    /// @notice Returns the position information for a given token ID and position index
    /// @param tokenId the ERC721 tokenId (commitment NFT ID)
    /// @param positionIndex the index of the position within the commitment
    /// @return position The position data
    /// @return positionId The position ID
    function getPosition(uint256 tokenId, uint256 positionIndex)
        external
        view
        returns (Position memory position, PositionId positionId);

    /// @notice Returns the position ID for a given token ID and position index
    /// @param tokenId the ERC721 tokenId (commitment NFT ID)
    /// @param positionIndex the index of the position within the commitment
    /// @return PositionId the position ID
    function getPositionId(uint256 tokenId, uint256 positionIndex) external view returns (PositionId);

    /// @notice Returns the commit information for a given commitment NFT
    /// @param tokenId the ERC721 tokenId (commitment NFT ID)
    /// @return state the MarketMaker.State associated with the commitment
    /// @return expiresAt the expiry timestamp of the commitment
    /// @return positionCount the number of positions associated with the commitment
    /// @return deficitBps the deficit basis points associated with the commitment
    function commitOf(uint256 tokenId)
        external
        view
        returns (MarketMaker.State memory state, uint256 expiresAt, uint256 positionCount, uint256 deficitBps);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PositionMeta} from "../types/Position.sol";
import {PositionId} from "../types/Position.sol";
import {SignalState} from "../types/Position.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

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

    /// @notice Used to get the ID that will be used for the next minted commitment NFT
    /// @return uint256 The next token ID
    function getNextTokenId() external view returns (uint256);

    /// @notice Returns the position information for a given token ID and position index
    /// @param tokenId the ERC721 tokenId (commitment NFT ID)
    /// @param positionIndex the index of the position within the commitment
    /// @return PositionMeta the position metadata
    function getPosition(uint256 tokenId, uint256 positionIndex) external view returns (PositionMeta memory);

    /// @notice Returns the position ID for a given token ID and position index
    /// @param tokenId the ERC721 tokenId (commitment NFT ID)
    /// @param positionIndex the index of the position within the commitment
    /// @return PositionId the position ID
    function getPositionId(uint256 tokenId, uint256 positionIndex) external view returns (PositionId);

    /// @notice Returns the signal state for a given commitment NFT
    /// @param tokenId the ERC721 tokenId (commitment NFT ID)
    /// @return SignalState the signal state
    function getSignalState(uint256 tokenId) external view returns (SignalState memory);

    /// @notice Returns the number of positions associated with a commitment NFT
    /// @param tokenId the ERC721 tokenId (commitment NFT ID)
    /// @return uint256 the number of positions
    function commitToPositionCount(uint256 tokenId) external view returns (uint256);

    /// @notice Returns the commit information for a given commitment NFT
    /// @param tokenId the ERC721 tokenId (commitment NFT ID)
    /// @return state the signal state
    /// @return poolId the pool ID associated with the commitment
    function commitOf(uint256 tokenId) external view returns (SignalState memory state, PoolId poolId);

    /// @notice Returns the URI for a given commitment NFT
    /// @param tokenId the ERC721 tokenId (commitment NFT ID)
    /// @return string the token URI
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

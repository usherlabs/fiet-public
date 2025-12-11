// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {Position as UniPosition} from "v4-periphery/lib/v4-core/src/libraries/Position.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {RFSCheckpoint} from "./Checkpoint.sol";

type PositionId is bytes32;

/// @notice Core Position struct for state management (Bunni-style)
struct Position {
    // the owner of the position -- ie. the router, mm position manager, native Uv4, etc.
    address owner;
    // the core pool id for this position (immutable after registration)
    PoolId poolId;
    // the commit ID (tokenId) this position belongs to (0 if not part of a commit)
    uint256 commitId;
    // the lower tick of the position
    int24 tickLower;
    // the upper tick of the position
    int24 tickUpper;
    // the liquidity of the position
    uint128 liquidity;
    // whether the position is active
    bool isActive;
    // Unique salt for position ID generation
    bytes32 salt;
    // Position-level RFS checkpoint.
    RFSCheckpoint checkpoint;
}

/// @notice Seizure-specific data for position seizure operations
struct SeizureData {
    /// @notice Whether this is a seizure operation
    bool isSeizing;
    /// @notice The settlement delta for seizure (amounts being settled by seizer)
    int128 settle0;
    int128 settle1;
}

/// @notice Hook data structure for position modifications via MMPositionManager
/// @dev Passed through poolManager.modifyLiquidity -> CoreHook -> VTSOrchestrator
struct PositionModificationHookData {
    /// @notice The commit ID (ERC721 tokenId) this position belongs to
    /// @dev Required for all MM position operations (mint, increase, decrease)
    uint256 commitId;
    /// @notice The position index within the commit
    uint256 positionIndex;
    /// @notice The locker address (msgSender who initiated the operation via MMPM)
    /// @dev Used for settlement queue attribution; address(0) defaults to position owner
    address locker;
    /// @notice Seizure-related data (only populated during seizure operations)
    SeizureData seizure;
    /// @notice Arbitrary additional data for future extensions
    bytes extraData;
}

/// @notice Library for encoding/decoding PositionModificationHookData
library PositionModificationHookDataLib {
    /// @notice Encodes hook data for standard position modifications
    /// @param commitId The commit ID (ERC721 tokenId)
    /// @param positionIndex The position index within the commit
    /// @param locker The locker address (msgSender who initiated the operation)
    /// @return Encoded hook data bytes
    function encode(uint256 commitId, uint256 positionIndex, address locker) internal pure returns (bytes memory) {
        return abi.encode(
            PositionModificationHookData({
                commitId: commitId,
                positionIndex: positionIndex,
                locker: locker,
                seizure: SeizureData({isSeizing: false, settle0: 0, settle1: 0}),
                extraData: ""
            })
        );
    }

    /// @notice Encodes hook data for seizure operations
    /// @param commitId The commit ID (ERC721 tokenId)
    /// @param positionIndex The position index within the commit
    /// @param locker The locker address (msgSender who initiated the operation)
    /// @param settle0 The settlement amount for token0
    /// @param settle1 The settlement amount for token1
    /// @return Encoded hook data bytes
    function encodeSeizure(uint256 commitId, uint256 positionIndex, address locker, int128 settle0, int128 settle1)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            PositionModificationHookData({
                commitId: commitId,
                positionIndex: positionIndex,
                locker: locker,
                seizure: SeizureData({isSeizing: true, settle0: settle0, settle1: settle1}),
                extraData: ""
            })
        );
    }

    /// @notice Decodes hook data, returns empty struct if data is empty or invalid
    /// @param hookData The encoded hook data bytes
    /// @return Decoded PositionModificationHookData struct
    function decode(bytes memory hookData) internal pure returns (PositionModificationHookData memory) {
        if (hookData.length == 0) {
            return PositionModificationHookData({
                commitId: 0,
                positionIndex: 0,
                locker: address(0),
                seizure: SeizureData({isSeizing: false, settle0: 0, settle1: 0}),
                extraData: ""
            });
        }
        return abi.decode(hookData, (PositionModificationHookData));
    }

    /// @notice Decodes hook data from calldata, returns empty struct if data is empty
    /// @param hookData The encoded hook data calldata
    /// @return Decoded PositionModificationHookData struct
    function decodeCalldata(bytes calldata hookData) internal pure returns (PositionModificationHookData memory) {
        if (hookData.length == 0) {
            return PositionModificationHookData({
                commitId: 0,
                positionIndex: 0,
                locker: address(0),
                seizure: SeizureData({isSeizing: false, settle0: 0, settle1: 0}),
                extraData: ""
            });
        }
        return abi.decode(hookData, (PositionModificationHookData));
    }

    /// @notice Check if this is an MM position modification (has valid commitId)
    /// @param data The decoded hook data
    /// @return True if this is an MM operation
    function isMMOperation(PositionModificationHookData memory data) internal pure returns (bool) {
        return data.commitId > 0;
    }

    /// @notice Gets the effective locker address, defaulting to fallback if not set
    /// @param data The decoded hook data
    /// @param fallbackAddress The fallback address to use if locker is not set
    /// @return The effective locker address
    function getLocker(PositionModificationHookData memory data, address fallbackAddress)
        internal
        pure
        returns (address)
    {
        return data.locker != address(0) ? data.locker : fallbackAddress;
    }
}

library PositionLibrary {
    /**
     * @dev This function is used to generate the id of a position using the router and the params of the modify liquidity operation
     * @param modifyLiquidityRouter The router used to modify the liquidity of the position
     * @param params The params of the modify liquidity operation
     * @return id The id of the position
     */
    function generateId(address modifyLiquidityRouter, ModifyLiquidityParams memory params)
        internal
        pure
        returns (PositionId id)
    {
        bytes32 positionKey = UniPosition.calculatePositionKey(
            modifyLiquidityRouter, params.tickLower, params.tickUpper, params.salt
        );

        id = PositionId.wrap(positionKey);
    }

    /**
     * @dev This function is used to generate a unique salt for a given token id and position index
     * @param tokenId The token id to generate the salt for
     * @param positionIndex The position index to generate the salt for
     * @return salt The unique salt
     */
    function generateSalt(uint256 tokenId, uint256 positionIndex) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenId, positionIndex));
    }
}

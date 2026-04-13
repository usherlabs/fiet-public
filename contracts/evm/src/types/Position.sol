// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {Position as UniPosition} from "v4-periphery/lib/v4-core/src/libraries/Position.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {RFSCheckpoint} from "./Checkpoint.sol";
import {Errors} from "../libraries/Errors.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

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

/// @notice MM increase-specific hook payload for consuming protocol credit in-hook
struct MMIncreaseHookExtraData {
    /// @notice Whether this modify should settle protocol credit inside the hook path
    bool settleInHook;
    /// @notice Token0 protocol credit snapshot intended for in-hook settlement
    uint256 intendedSettle0;
    /// @notice Token1 protocol credit snapshot intended for in-hook settlement
    uint256 intendedSettle1;
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
    /// @dev Required for MM settlement queue attribution and advancer authorisation
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
        return encodeWithExtraData(commitId, positionIndex, locker, "");
    }

    /// @notice Encodes hook data for standard position modifications with custom extraData
    function encodeWithExtraData(uint256 commitId, uint256 positionIndex, address locker, bytes memory extraData)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            PositionModificationHookData({
                commitId: commitId,
                positionIndex: positionIndex,
                locker: locker,
                seizure: SeizureData({isSeizing: false, settle0: 0, settle1: 0}),
                extraData: extraData
            })
        );
    }

    /// @notice Encodes hook data for MM add-liquidity paths that settle protocol credit inside the hook
    function encodeWithInHookProtocolSettlement(
        uint256 commitId,
        uint256 positionIndex,
        address locker,
        uint256 intendedSettle0,
        uint256 intendedSettle1
    ) internal pure returns (bytes memory) {
        return encodeWithExtraData(
            commitId,
            positionIndex,
            locker,
            abi.encode(
                MMIncreaseHookExtraData({
                    settleInHook: true, intendedSettle0: intendedSettle0, intendedSettle1: intendedSettle1
                })
            )
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

    /// @notice Decodes MM increase extraData, returning the zero/default payload when absent
    function decodeMMIncreaseHookExtraData(PositionModificationHookData memory data)
        internal
        pure
        returns (MMIncreaseHookExtraData memory extra)
    {
        if (data.extraData.length == 0) {
            return MMIncreaseHookExtraData({settleInHook: false, intendedSettle0: 0, intendedSettle1: 0});
        }
        return abi.decode(data.extraData, (MMIncreaseHookExtraData));
    }

    /// @notice Check if this is an MM position modification (has valid commitId)
    /// @param data The decoded hook data
    /// @return True if this is an MM operation
    function isMMOperation(PositionModificationHookData memory data) internal pure returns (bool) {
        return data.commitId > 0;
    }

    /// @notice Gets the required locker address for MM operations
    /// @param data The decoded hook data
    /// @return The required locker address
    function getLocker(PositionModificationHookData memory data) internal pure returns (address) {
        if (data.locker == address(0)) {
            revert Errors.InvariantViolated("MM Operation: locker must be passed into hookdata");
        }
        return data.locker;
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
        return EfficientHashLib.hash(abi.encodePacked(tokenId, positionIndex));
    }
}

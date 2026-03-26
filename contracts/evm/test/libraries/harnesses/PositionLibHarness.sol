// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";

import {
    PositionId,
    PositionLibrary,
    PositionModificationHookData,
    PositionModificationHookDataLib
} from "../../../src/types/Position.sol";

/// @title PositionLibHarness
/// @notice Exposes PositionLibrary and PositionModificationHookDataLib helpers for unit testing
contract PositionLibHarness {
    // ============ PositionLibrary ============

    function generateId(address modifyLiquidityRouter, ModifyLiquidityParams memory params)
        external
        pure
        returns (PositionId)
    {
        return PositionLibrary.generateId(modifyLiquidityRouter, params);
    }

    function generateSalt(uint256 tokenId, uint256 positionIndex) external pure returns (bytes32) {
        return PositionLibrary.generateSalt(tokenId, positionIndex);
    }

    // ============ PositionModificationHookDataLib ============

    function encodeHookData(uint256 commitId, uint256 positionIndex, address locker)
        external
        pure
        returns (bytes memory)
    {
        return PositionModificationHookDataLib.encode(commitId, positionIndex, locker);
    }

    function encodeSeizureHookData(
        uint256 commitId,
        uint256 positionIndex,
        address locker,
        int128 settle0,
        int128 settle1
    ) external pure returns (bytes memory) {
        return PositionModificationHookDataLib.encodeSeizure(commitId, positionIndex, locker, settle0, settle1);
    }

    function decodeHookData(bytes memory hookData) external pure returns (PositionModificationHookData memory) {
        return PositionModificationHookDataLib.decode(hookData);
    }

    function decodeHookDataCalldata(bytes calldata hookData)
        external
        pure
        returns (PositionModificationHookData memory)
    {
        return PositionModificationHookDataLib.decodeCalldata(hookData);
    }

    function isMMOperation(PositionModificationHookData memory data) external pure returns (bool) {
        return PositionModificationHookDataLib.isMMOperation(data);
    }

    function getLocker(PositionModificationHookData memory data) external pure returns (address) {
        return PositionModificationHookDataLib.getLocker(data);
    }
}


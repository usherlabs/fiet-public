// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVTSManager} from "../interfaces/IVTSManager.sol";
import {PositionMeta, PositionId} from "../types/Position.sol";
import {RFSCheckpoint, RFSCheckpointLibrary} from "../types/Checkpoint.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

// NOTE: Contract name intentionally not `RFSCheckpoint` to avoid a name clash with the struct `RFSCheckpoint`.
abstract contract RFSCheckpointModule {
    using RFSCheckpointLibrary for RFSCheckpoint;

    event Checkpointed(uint256 tokenId, uint256 positionIndex, RFSCheckpoint checkpoint);

    // PositionId => rolling RFS checkpoint state
    mapping(PositionId => RFSCheckpoint) public positionToCheckpoint;

    // ----- Required hooks to be implemented by inheritors -----
    function _positionCountOf(uint256 tokenId) internal view virtual returns (uint256);

    function calcRFS(uint256 tokenId, uint256 positionIndex, bool requireClosedRfS)
        public
        virtual
        returns (PositionId positionId, bool rfsOpen, BalanceDelta rfsDelta);

    // ----- Internal helpers -----
    function _markCheckpoint(PositionId positionId, bool isOpen) internal {
        positionToCheckpoint[positionId].mark(isOpen);
    }

    // ----- Checkpoint API -----
    function _checkpoint(uint256 tokenId, uint256 positionIndex) internal {
        (PositionId positionId, bool rfsOpen,) = calcRFS(tokenId, positionIndex, false);
        _markCheckpoint(positionId, rfsOpen);
        emit Checkpointed(tokenId, positionIndex, positionToCheckpoint[positionId]);
    }

    function checkpoint(uint256 tokenId, uint256 positionIndex) public {
        _checkpoint(tokenId, positionIndex);
    }

    function checkpoint(uint256[] memory tokenIds, uint256[] memory positionIndexes) public {
        require(tokenIds.length == positionIndexes.length, "Invalid input lengths");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _checkpoint(tokenIds[i], positionIndexes[i]);
        }
    }

    function checkpoint(uint256 tokenId) public {
        for (uint256 i = 0; i < _positionCountOf(tokenId); i++) {
            _checkpoint(tokenId, i);
        }
    }

    function checkpoint(uint256[] memory tokenIds) public {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            checkpoint(tokenIds[i]);
        }
    }
}

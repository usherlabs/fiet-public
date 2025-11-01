// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVTSManager} from "../interfaces/IVTSManager.sol";
import {PositionMeta, PositionId} from "../types/Position.sol";
import {RFSCheckpoint, RFSCheckpointLibrary} from "../types/Checkpoint.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IVRLSettlementObserver} from "../interfaces/IVRLSettlementObserver.sol";

// NOTE: Contract name intentionally not `RFSCheckpoint` to avoid a name clash with the struct `RFSCheckpoint`.
abstract contract RFSCheckpointModule {
    using RFSCheckpointLibrary for RFSCheckpoint;

    event Checkpointed(uint256 tokenId, uint256 positionIndex, RFSCheckpoint checkpoint);
    event GracePeriodExtended(uint256 tokenId, uint256 positionIndex, RFSCheckpoint checkpoint);

    IVRLSettlementObserver public immutable settlementObserver;

    // PositionId => rolling RFS checkpoint state
    mapping(PositionId => RFSCheckpoint) public positionToCheckpoint;

    constructor(address _settlementObserver) {
        settlementObserver = IVRLSettlementObserver(_settlementObserver);
    }

    // ----- Required hooks to be implemented by inheritors -----
    function _positionCountOf(uint256 tokenId) internal view virtual returns (uint256);
    function getPositionId(uint256 tokenId, uint256 positionIndex) public view virtual returns (PositionId);

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

    /**
     * @notice Extends the grace period for a position by providing a settlement proof
     * @dev This function allows market makers to extend their grace period by providing
     *      a valid settlement proof that gets verified against a Settlement Observer's verifier.
     * @dev "I have a token coming, it's just pending a bank transfer to the stablecoin issuer."
     * @param tokenId The token id of the position
     * @param positionIndex The position index
     * @param settlementProof The settlement signal containing the proof
     */
    function _extendGracePeriod(
        MarketVTSConfiguration memory vtsConfiguration,
        uint256 tokenId,
        uint256 positionIndex,
        uint8 settlementTokenIndex,
        bytes memory settlementProof
    ) internal {
        require(settlementTokenIndex == 0 || settlementTokenIndex == 1, "Invalid settlement token index");
        PositionId positionId = getPositionId(tokenId, positionIndex);

        // verify the settlement proof and get the grace period extension
        settlementObserver.verifySettlementProof(positionId, settlementTokenIndex, settlementProof);
        bool isTokenZero = settlementTokenIndex == 0;

        // extend the grace period for the position
        positionToCheckpoint[positionId].extendGracePeriod(vtsConfiguration, isTokenZero);

        // emit an event to notify the market maker that the grace period has been extended
        emit GracePeriodExtended(positionId, positionToCheckpoint[positionId]);
    }
}

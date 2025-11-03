// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVTSManager} from "../interfaces/IVTSManager.sol";
import {PositionMeta, PositionId} from "../types/Position.sol";
import {RFSCheckpoint, RFSCheckpointLibrary} from "../types/Checkpoint.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IVRLSettlementObserver} from "../interfaces/IVRLSettlementObserver.sol";
import {MarketVTSConfiguration, TokenConfiguration} from "../types/VTS.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Errors} from "../libraries/Errors.sol";

// NOTE: Contract name intentionally not `RFSCheckpoint` to avoid a name clash with the struct `RFSCheckpoint`.
abstract contract RFSCheckpointModule {
    using RFSCheckpointLibrary for RFSCheckpoint;

    event Checkpointed(uint256 tokenId, uint256 positionIndex, RFSCheckpoint checkpoint);
    event GracePeriodExtended(uint256 tokenId, uint256 positionIndex, uint8 tokenIndex, RFSCheckpoint checkpoint);

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
        PoolKey memory poolKey,
        MarketVTSConfiguration memory vtsConfiguration,
        uint256 tokenId,
        uint256 positionIndex,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) internal {
        require(settlementTokenIndex == 0 || settlementTokenIndex == 1, "Invalid settlement token index");
        PositionId positionId = getPositionId(tokenId, positionIndex);

        // verify the settlement proof and get the grace period extension
        settlementObserver.verifySettlementProof(poolKey, settlementTokenIndex, verifierIndex, settlementProof, true);
        // extend the grace period for the position
        TokenConfiguration memory tokenConfiguration =
            settlementTokenIndex == 0 ? vtsConfiguration.token0 : vtsConfiguration.token1;
        positionToCheckpoint[positionId].extendGracePeriod(tokenConfiguration, settlementTokenIndex);

        // emit an event to notify the market maker that the grace period has been extended
        emit GracePeriodExtended(tokenId, positionIndex, settlementTokenIndex, positionToCheckpoint[positionId]);
    }

    /**
     * @notice Determines if a position is open for seizure by checking if the grace period has elapsed
     * @dev Returns true if timeSinceLastCheckpoint > (gracePeriodTime + extension) for either token
     * @param vtsConfiguration The VTS configuration
     * @param tokenId The token id of the position
     * @param positionIndex The position index
     * @param revertOnFalse Whether to revert if the grace period has not elapsed
     * @return true if the position can be seized (grace period elapsed for either token), false otherwise
     */
    function _isSeizable(
        MarketVTSConfiguration memory vtsConfiguration,
        uint256 tokenId,
        uint256 positionIndex,
        bool revertOnFalse
    ) internal view returns (bool) {
        PositionId positionId = getPositionId(tokenId, positionIndex);
        RFSCheckpoint memory checkpoint = positionToCheckpoint[positionId];
        if (!checkpoint.isOpen) {
            if (revertOnFalse) {
                revert Errors.GracePeriodNotElapsed(tokenId, positionIndex, checkpoint);
            }
            return false;
        }
        uint256 timeSinceLastCheckpoint = block.timestamp - checkpoint.timeOfLastTransition;

        uint256 totalGracePeriod0 = vtsConfiguration.token0.gracePeriodTime + checkpoint.gracePeriodExtension0;
        uint256 totalGracePeriod1 = vtsConfiguration.token1.gracePeriodTime + checkpoint.gracePeriodExtension1;

        bool gracePeriod0Elapsed = timeSinceLastCheckpoint > totalGracePeriod0;
        bool gracePeriod1Elapsed = timeSinceLastCheckpoint > totalGracePeriod1;

        bool isSeizable = gracePeriod0Elapsed || gracePeriod1Elapsed;
        if (revertOnFalse && !isSeizable) {
            revert Errors.GracePeriodNotElapsed(tokenId, positionIndex, checkpoint);
        }

        return isSeizable;
    }
}

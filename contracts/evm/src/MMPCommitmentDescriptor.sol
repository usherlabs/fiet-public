// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICommitmentDescriptor} from "./interfaces/ICommitmentDescriptor.sol";
import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
import {SignalState} from "./types/Position.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

contract MMPCommitmentDescriptor is ICommitmentDescriptor {
    using Strings for uint256;

    /**
     * @notice Generates a token URI for a commitment NFT
     * @param manager The address of the MMPositionManager contract
     * @param tokenId The token ID of the commitment NFT
     * @return The token URI as a data URI containing JSON metadata
     */
    function tokenURI(address manager, uint256 tokenId) external view override returns (string memory) {
        IMMPositionManager positionManager = IMMPositionManager(manager);

        uint256 posCount = positionManager.commitToPositionCount(tokenId);
        (SignalState memory s,) = positionManager.commitOf(tokenId);

        string memory name = string(abi.encodePacked("Fiet Commitment #", tokenId.toString()));
        string memory description = "Fiet VRL Commitment NFT granting position management rights.";
        string memory attributes = string(
            abi.encodePacked(
                "[{\"trait_type\":\"positions\",\"value\":",
                posCount.toString(),
                "},",
                "{\"trait_type\":\"expiresAt\",\"value\":",
                s.expiresAt.toString(),
                "}]"
            )
        );
        string memory json = string(
            abi.encodePacked(
                "{\"name\":\"",
                name,
                "\",",
                "\"description\":\"",
                description,
                "\",",
                "\"attributes\":",
                attributes,
                "}"
            )
        );
        return string(abi.encodePacked("data:application/json;utf8,", json));
    }
}


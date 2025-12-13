// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ICommitmentDescriptor} from "./interfaces/ICommitmentDescriptor.sol";
import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
import {LibString} from "solady/utils/LibString.sol";

contract MMPCommitmentDescriptor is ICommitmentDescriptor {
    using LibString for uint256;

    /**
     * @notice Generates a token URI for a commitment NFT
     * @param tokenId The token ID of the commitment NFT
     * @return The token URI as a data URI containing JSON metadata
     */
    function tokenURI(uint256 tokenId) external view override returns (string memory) {
        IMMPositionManager positionManager = IMMPositionManager(msg.sender);

        (, uint256 expiresAt, uint256 posCount) = positionManager.commitOf(tokenId);

        string memory name = string(abi.encodePacked("Fiet Commitment #", tokenId.toString()));
        string memory description = "Fiet VRL Commitment NFT granting position management rights.";
        string memory attributes = string(
            abi.encodePacked(
                "[{\"trait_type\":\"positions\",\"value\":",
                posCount.toString(),
                "},",
                "{\"trait_type\":\"expiresAt\",\"value\":",
                expiresAt.toString(),
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


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC721Permit_v4} from "v4-periphery/src/base/ERC721Permit_v4.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Errors} from "./Errors.sol";
import {IVTSOrchestrator} from "../interfaces/IVTSOrchestrator.sol";
import {Position} from "../types/Position.sol";

/// @title MMHelpers
/// @notice Library providing shared helper functions for MMPositionManager
/// @dev Used by both MMPositionManager and MMPositionActionsImpl
library MMHelpers {
    /// @dev Asserts that the caller is approved or the owner of the token
    /// @dev Accesses ERC721 storage via delegatecall context from MMPositionManager
    /// @param caller The address to check approval for
    /// @param tokenId The token ID to check
    function assertApprovedOrOwner(address caller, uint256 tokenId) internal view {
        // Access ERC721 functions via delegatecall context
        // MMPositionManager has ERC721Permit_v4, so we can call public functions
        address owner = ERC721Permit_v4(address(this)).ownerOf(tokenId);
        if (caller == owner) return;
        if (ERC721Permit_v4(address(this)).getApproved(tokenId) == caller) return;
        if (ERC721Permit_v4(address(this)).isApprovedForAll(owner, caller)) return;
        revert Errors.NotApproved(caller);
    }

    /// @notice Enforces that the commit is valid (not expired)
    /// @param vtsOrchestrator The VTS orchestrator to query commit data
    /// @param tokenId The commitment NFT token ID
    function assertSignalValid(IVTSOrchestrator vtsOrchestrator, uint256 tokenId) internal view {
        (, uint256 expiresAt,) = vtsOrchestrator.getCommit(tokenId);
        if (expiresAt < block.timestamp) {
            revert Errors.SignalExpired(tokenId);
        }
    }

    /// @notice Asserts that the position belongs to the specified pool
    /// @param poolKey The pool key to validate against
    /// @param position The position to validate
    function assertPositionForPool(PoolKey calldata poolKey, Position memory position) internal pure {
        if (PoolId.unwrap(position.poolId) != PoolId.unwrap(poolKey.toId())) {
            revert Errors.InvalidMarket(poolKey);
        }
    }
}


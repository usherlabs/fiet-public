// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC721Permit_v4} from "v4-periphery/src/base/ERC721Permit_v4.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Errors} from "./Errors.sol";
import {Position} from "../types/Position.sol";

import {IMMPositionManager} from "../interfaces/IMMPositionManager.sol";

/// @title MMHelpers
/// @notice Library providing shared helper functions for MMPositionManager
/// @dev Used by both MMPositionManager and MMPositionActionsImpl
library MMHelpers {
    function isApprovedOrOwner(address caller, uint256 tokenId) internal view returns (bool) {
        // Defensive guard: `caller` should never be the zero address in real flows (it's typically msg.sender),
        // but explicitly rejecting it avoids accidental authorisation via default-zero approvals.
        if (caller == address(0)) return false;

        address owner = ERC721Permit_v4(address(this)).ownerOf(tokenId);
        if (caller == owner) return true;
        if (ERC721Permit_v4(address(this)).getApproved(tokenId) == caller) return true;
        if (ERC721Permit_v4(address(this)).isApprovedForAll(owner, caller)) return true;
        return false;
    }

    /// @dev Asserts that the caller is approved or the owner of the token
    /// @dev Accesses ERC721 storage via delegatecall context from MMPositionManager
    /// @param caller The address to check approval for
    /// @param tokenId The token ID to check
    function assertApprovedOrOwner(address caller, uint256 tokenId) internal view {
        if (!isApprovedOrOwner(caller, tokenId)) {
            revert Errors.NotApproved(caller);
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

    /// @notice Requires `custodianFor(recipient)` to be non-zero (queue custodian is created only in `commitSignal`).
    function assertQueueCustodianForRecipient(address recipient) internal view {
        if (recipient == address(0)) revert Errors.InvalidAddress(recipient);
        address c = IMMPositionManager(address(this)).custodianFor(recipient);
        if (c == address(0)) revert Errors.QueueCustodianNotDeployed(recipient);
    }

    /// @notice Requires the current `ownerOf(tokenId)` to already have a queue custodian.
    function assertQueueCustodianForCommitToken(uint256 tokenId) internal view {
        address owner = ERC721Permit_v4(address(this)).ownerOf(tokenId);
        assertQueueCustodianForRecipient(owner);
    }
}

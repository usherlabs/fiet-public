// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {MarketMaker} from "../libraries/MarketMaker.sol";
import {PositionId} from "./Position.sol";

/// The parameters of the proof to verify the state of the market maker
struct LiquiditySignal {
    /// The nonce of the liquidity signal which should always be incrementing
    uint256 nonce;
    /// The hash of the root merkle tree
    bytes32 rootHash;
    /// The canister's signature of the root state hash
    bytes rootHashSignature;
    /// The merkle proof of mm state data we want to verify in the merkle tree
    bytes32[] merkleProof;
    /// The state of the market maker
    MarketMaker.State mmState;
    /// The signature of the state of the market maker
    bytes mmSignature;
}

/// @notice Core Commit struct for state management (Bunni-style)
struct Commit {
    /// MarketMaker state
    MarketMaker.State mmState;
    /// @notice The only address allowed as VTS `owner` on the CoreHook MM path (`processPosition` router) for this commit.
    /// @dev Set once at commit creation from the actual `VTSOrchestrator` caller (e.g. `MMPositionManager`). This binds
    ///      MM liquidity operations to the integration surface that created the commit, so `factory.bounds(owner)` alone
    ///      cannot authorise a different bound endpoint to issue LCC or operate positions under another party's commit.
    ///      Renewals do not rotate this field (immutable binding). `address(0)` means legacy commits predating this field;
    ///      those retain the previous authorisation model (bounds + advancer locker only).
    address authorisedRelayer;
    /// Expiration timestamp
    uint256 expiresAt;
    /// Mapping of position index to PositionId (avoids arrays)
    mapping(uint256 => PositionId) positions;
    /// Count of positions (for management)
    uint256 positionCount;
    /// Count of active positions
    uint256 activePositionCount;
    /// Inactive positions that still hold live `pa.settled` (withdrawable via MM settle paths; blocks decommit)
    uint256 inactiveRemnantCount;
}

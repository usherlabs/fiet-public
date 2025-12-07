// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Commit} from "./Commit.sol";
import {PositionId, Position} from "./Position.sol";
import {Pool} from "./Pool.sol";
import {RFSCheckpoint} from "./Checkpoint.sol";
import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";
import {IOracleHelper} from "../interfaces/IOracleHelper.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";

struct TokenConfiguration {
    // Grace period time
    uint256 gracePeriodTime;
    // Seizure unlock time
    uint256 seizureUnlockTime;
    // Base VTS Rate in bps (basis points)
    uint256 baseVTSRate;
    // Max grace period time
    uint256 maxGracePeriodTime;
}

struct MarketVTSConfiguration {
    // Token configuration for token0
    TokenConfiguration token0;
    // Token configuration for token1
    TokenConfiguration token1;
    // Fee share applied to LP fees when protocol covers deficits (in basis points)
    uint16 coverageFeeShare;
    // Minimum residual liquidity units threshold for full position closure during seizure
    uint256 minResidualUnits;
}

/// @notice Context struct for position processing dependencies
/// @dev Passed to VTSPositionLib.touchPosition to provide access to external contracts
struct PositionContext {
    // PoolManager for position queries and state management
    IPoolManager poolManager;
    // LiquidityHub for LCC issuance/cancellation
    ILiquidityHub liquidityHub;
    // OracleHelper for commitment validation
    IOracleHelper oracleHelper;
    // MM Position Manager address for delta accounting
    address mmPositionManager;
    // Market vault address for settlement clamping
    address marketVault;
}

/// @notice Per-position accounting data (mirrors VTSManager per-position mappings)
/// @dev Split out of VTSManager to follow the Bunni-style storage pattern
struct PositionAccounting {
    // Commitment maxima per token
    TokenPairUint commitmentMax;
    // Settled amounts per token
    TokenPairUint settled;
    // Cumulative deficit per token (raw units)
    TokenPairUint cumulativeDeficit;
    // Coverage usage growth snapshots per token
    TokenPairUint coverageUseGrowthInsideLast;
    // Deficit growth snapshots per token
    TokenPairUint deficitGrowthInsideLast;
    // Inflow growth snapshots per token
    TokenPairUint inflowGrowthInsideLast;
    // Fee growth snapshots per token
    TokenPairUint feeGrowthInsideLast;
    // Cumulative outflows per token
    TokenPairUint cumulativeOutflows;
    // Outflow snapshots at last fee snap per token
    TokenPairUint outflowsAtFeeSnap;
    // Commitment-scoped deficit (insolvency gate) per token
    TokenPairUint commitmentDeficit;
    // Fees shared by position per token
    TokenPairUint feesShared;
    // Pending fee adjustments per token: +slash (reduces payout), -bonus (increases payout)
    TokenPairInt pendingFeeAdj;
    // Net settlement since last modification per token
    TokenPairInt netSettlementSinceLastMod;
    // Last funded pending adjustment per token
    TokenPairInt lastFundedPendingAdj;
}

/// @notice Per-pool accounting data (mirrors VTSManager per-pool mappings)
/// @dev Split out of VTSManager to follow the Bunni-style storage pattern
struct PoolAccounting {
    // Deficit growth global per token
    TokenPairUint deficitGrowthGlobal;
    // Inflow growth global per token
    TokenPairUint inflowGrowthGlobal;
    // Protocol coverage per token
    TokenPairUint protocolCoverage;
    // Coverage usage growth global per token
    TokenPairUint coverageUseGrowthGlobal;
    // Residual coverage per token (when no in-range liquidity)
    TokenPairUint coverageResidual;
    // Sum of all position cumulative deficits per token
    TokenPairUint globalDeficit;
    // Protocol/LPs fee pot accrued from fee sharing per token
    TokenPairUint protocolFeeAccrued;
    // Slashed pot balances per token
    TokenPairUint slashedPot;
    // Pool-wide sum of positive nets since last modification per token
    TokenPairUint poolNetSinceLastMod;
}

/// @notice Simple pair struct for per-tick growth (replaces uint256[2] arrays)
struct GrowthPair {
    uint256 token0;
    uint256 token1;
}

/// @notice Pair struct for uint256 values per token (token0 and token1)
/// @dev Similar to GrowthPair but used for general accounting fields
struct TokenPairUint {
    uint256 token0;
    uint256 token1;
}

/// @notice Pair struct for int256 values per token (token0 and token1)
/// @dev Used for signed accounting fields like net settlement and fee adjustments
struct TokenPairInt {
    int256 token0;
    int256 token1;
}

/// @title TokenPairLib
/// @notice Library for accessing TokenPair fields by tokenIndex
/// @dev Provides get/set helpers to replace manual if (tokenIndex == 0) branching
library TokenPairLib {
    /// @notice Get the value for a specific token index from a TokenPairUint
    /// @param self The TokenPairUint storage reference
    /// @param tokenIndex The token index (0 or 1)
    /// @return The value for the specified token
    function get(TokenPairUint storage self, uint8 tokenIndex) internal view returns (uint256) {
        return tokenIndex == 0 ? self.token0 : self.token1;
    }

    /// @notice Set the value for a specific token index in a TokenPairUint
    /// @param self The TokenPairUint storage reference
    /// @param tokenIndex The token index (0 or 1)
    /// @param value The value to set
    function set(TokenPairUint storage self, uint8 tokenIndex, uint256 value) internal {
        if (tokenIndex == 0) {
            self.token0 = value;
        } else {
            self.token1 = value;
        }
    }

    /// @notice Get the value for a specific token index from a TokenPairInt
    /// @param self The TokenPairInt storage reference
    /// @param tokenIndex The token index (0 or 1)
    /// @return The value for the specified token
    function get(TokenPairInt storage self, uint8 tokenIndex) internal view returns (int256) {
        return tokenIndex == 0 ? self.token0 : self.token1;
    }

    /// @notice Set the value for a specific token index in a TokenPairInt
    /// @param self The TokenPairInt storage reference
    /// @param tokenIndex The token index (0 or 1)
    /// @param value The value to set
    function set(TokenPairInt storage self, uint8 tokenIndex, int256 value) internal {
        if (tokenIndex == 0) {
            self.token0 = value;
        } else {
            self.token1 = value;
        }
    }
}

/// @notice Central storage struct (like Bunni's HubStorage)
/// @dev Contains all state mappings for pools, commits, positions and accounting
/// ? need a mapping from CommitId => PositionIndex => PositionId
struct VTSStorage {
    /// Per-pool state
    mapping(PoolId => Pool) pools;
    /// Per-pool accounting state
    mapping(PoolId => PoolAccounting) poolAccounting;
    /// Per-commit (CommitId) state
    mapping(uint256 => Commit) commits;
    /// Per-position state
    mapping(PositionId => Position) positions;
    /// Per-position accounting state
    mapping(PositionId => PositionAccounting) positionAccounting;
    /// Per-pool per-tick deficit growth outside
    mapping(PoolId => mapping(int24 => GrowthPair)) deficitGrowthOutside;
    /// Per-pool per-tick inflow growth outside
    mapping(PoolId => mapping(int24 => GrowthPair)) inflowGrowthOutside;
    /// Per-pool per-tick coverage usage growth outside
    mapping(PoolId => mapping(int24 => GrowthPair)) coverageUseGrowthOutside;
    /// Root-level RFS checkpoints, keyed by a generic bytes32 identifier
    /// For positions: use PositionId.unwrap(positionId)
    /// For commits: use keccak256(abi.encodePacked(commitCommitId))
    mapping(bytes32 => RFSCheckpoint) checkpoints;
    /// Persistent underlying credits owed by protocol to users (target => underlying => credit)
    /// Used to track unsettled withdrawals that couldn't be fulfilled immediately
    mapping(address => mapping(address => uint256)) persistentUnderlyingCredits;
    /// Next token ID for commit NFTs (starts at 1)
    uint256 nextTokenId;
    /// Global pause flag
    bool isPaused;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Commit} from "./Commit.sol";
import {PositionId, Position} from "./Position.sol";
import {Pool} from "./Pool.sol";
import {RFSCheckpoint} from "./Checkpoint.sol";

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

/// @notice Per-position accounting data (mirrors VTSManager per-position mappings)
/// @dev Split out of VTSManager to follow the Bunni-style storage pattern
struct PositionAccounting {
    // Commitment maxima per token
    uint256 commitmentMax0;
    uint256 commitmentMax1;
    // Settled amounts per token
    uint256 settled0;
    uint256 settled1;
    // Cumulative deficit per token (raw units)
    uint256 cumulativeDeficit0;
    uint256 cumulativeDeficit1;
    // Coverage usage growth snapshots per token
    uint256 coverageUseGrowthInsideLast0;
    uint256 coverageUseGrowthInsideLast1;
    // Deficit growth snapshots per token
    uint256 deficitGrowthInsideLast0;
    uint256 deficitGrowthInsideLast1;
    // Inflow growth snapshots per token
    uint256 inflowGrowthInsideLast0;
    uint256 inflowGrowthInsideLast1;
    // Fee growth snapshots per token
    uint256 feeGrowthInsideLast0;
    uint256 feeGrowthInsideLast1;
    // Cumulative outflows per token
    uint256 cumulativeOutflows0;
    uint256 cumulativeOutflows1;
    // Outflow snapshots at last fee snap per token
    uint256 outflowsAtFeeSnap0;
    uint256 outflowsAtFeeSnap1;
    // Commitment-scoped deficit (insolvency gate) per token
    uint256 commitmentDeficit0;
    uint256 commitmentDeficit1;
    // Fees shared by position per token
    uint256 feesShared0;
    uint256 feesShared1;
    // Pending fee adjustments per token: +slash (reduces payout), -bonus (increases payout)
    int256 pendingFeeAdj0;
    int256 pendingFeeAdj1;
    // Net settlement since last modification per token
    int256 netSettlementSinceLastMod0;
    int256 netSettlementSinceLastMod1;
    // Last funded pending adjustment per token
    int256 lastFundedPendingAdj0;
    int256 lastFundedPendingAdj1;
}

/// @notice Per-pool accounting data (mirrors VTSManager per-pool mappings)
/// @dev Split out of VTSManager to follow the Bunni-style storage pattern
struct PoolAccounting {
    // Deficit growth global per token
    uint256 deficitGrowthGlobal0;
    uint256 deficitGrowthGlobal1;
    // Inflow growth global per token
    uint256 inflowGrowthGlobal0;
    uint256 inflowGrowthGlobal1;
    // Protocol coverage per token
    uint256 protocolCoverage0;
    uint256 protocolCoverage1;
    // Coverage usage growth global per token
    uint256 coverageUseGrowthGlobal0;
    uint256 coverageUseGrowthGlobal1;
    // Residual coverage per token (when no in-range liquidity)
    uint256 coverageResidual0;
    uint256 coverageResidual1;
    // Sum of all position cumulative deficits per token
    uint256 globalDeficit0;
    uint256 globalDeficit1;
    // Protocol/LPs fee pot accrued from fee sharing per token
    uint256 protocolFeeAccrued0;
    uint256 protocolFeeAccrued1;
    // Slashed pot balances per token
    uint256 slashedPot0;
    uint256 slashedPot1;
    // Pool-wide sum of positive nets since last modification per token
    uint256 poolNetSinceLastMod0;
    uint256 poolNetSinceLastMod1;
}

/// @notice Simple pair struct for per-tick growth (replaces uint256[2] arrays)
struct GrowthPair {
    uint256 token0;
    uint256 token1;
}

/// @notice Central storage struct (like Bunni's HubStorage)
/// @dev Contains all state mappings for pools, commits, positions and accounting
struct VTSStorage {
    /// Per-pool state
    mapping(PoolId => Pool) pools;
    /// Per-pool accounting state
    mapping(PoolId => PoolAccounting) poolAccounting;
    /// Per-commit (tokenId) state
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
    /// For commits: use keccak256(abi.encodePacked(commitTokenId))
    /// For commit-position pairs: use keccak256(abi.encodePacked(commitTokenId, positionIndex))
    mapping(bytes32 => RFSCheckpoint) checkpoints;
    /// Global pause flag
    bool isPaused;
}

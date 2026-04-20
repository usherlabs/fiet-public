// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Commit} from "./Commit.sol";
import {PositionId, Position} from "./Position.sol";
import {Pool} from "./Pool.sol";
import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";
import {IOracleHelper} from "../interfaces/IOracleHelper.sol";
import {IVRLSignalManager} from "../interfaces/IVRLSignalManager.sol";
import {IVRLSettlementObserver} from "../interfaces/IVRLSettlementObserver.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {IMarketVault} from "../interfaces/IMarketVault.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

struct TokenConfiguration {
    // Grace period time
    uint256 gracePeriodTime;
    // Base VTS Rate in bps (basis points)
    uint256 baseVTSRate;
    // Max grace period time
    uint256 maxGracePeriodTime;
    // Minimum time a non-zero commitment deficit must persist before grace bypass is allowed (0 disables age gating)
    uint256 unbackedCommitmentGraceBypassTime;
    // Optional token deficit threshold used only when deficit bps is below bypass bps (0 disables)
    uint256 unbackedCommitmentGraceBypassThreshold;
}

// forge-lint: disable-next-line(pascal-case-struct)
struct MarketVTSConfiguration {
    // Token configuration for token0
    TokenConfiguration token0;
    // Token configuration for token1
    TokenConfiguration token1;
    // Minimum residual liquidity units threshold for full position closure during seizure
    uint256 minResidualUnits;
    // Commitment deficit severity threshold (bps) above which grace bypass is allowed
    uint16 unbackedCommitmentGraceBypassBps;
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
    // Market vault address for settlement clamping
    IMarketVault marketVault;
}

/// @notice Lightweight orchestrator context for lifecycle library paths
struct VTSLifecycleContext {
    IPoolManager poolManager;
    ILiquidityHub liquidityHub;
    IOracleHelper oracleHelper;
    IVRLSettlementObserver settlementObserver;
}

/// @notice CoreHook processing context before market-vault resolution
struct VTSCoreHookContext {
    IPoolManager poolManager;
    ILiquidityHub liquidityHub;
    IOracleHelper oracleHelper;
}

/// @notice Routing context for commit/renew entrypoints
struct VTSCommitRouterContext {
    ILiquidityHub liquidityHub;
    IVRLSignalManager signalManager;
    /// @dev Used to enforce signal admission (oracle-priceable reserve set) on commit/renew.
    IOracleHelper oracleHelper;
}

/// @notice Parameters for touchPosition to reduce stack pressure
/// @dev Bundles external call parameters into single struct
struct TouchPositionParams {
    // The owner of the position
    address owner;
    // The pool key (needed for LCC operations and currency access)
    PoolKey poolKey;
    // The modify liquidity params
    ModifyLiquidityParams params;
    // The caller delta from poolManager.modifyLiquidity
    BalanceDelta callerDelta;
    // The fees accrued from poolManager.modifyLiquidity
    BalanceDelta feesAccrued;
    // The hook data containing PositionModificationHookData
    bytes hookData;
}

/// @notice Result of touchPosition to reduce stack pressure
struct TouchPositionResult {
    Position pos;
    PositionId id;
}

/// @notice Parameters for onMMSettle to reduce stack pressure
/// @dev Bundles settlement parameters into single struct
struct SettleParams {
    // The market vault interface for liquidity availability checks
    IMarketVault vault;
    // The position id
    PositionId positionId;
    // The pool currency of the LCC token for token0
    Currency lccCurrency0;
    // The pool currency of the LCC token for token1
    Currency lccCurrency1;
    // The balance delta of the settlement
    BalanceDelta delta;
    // Whether the position is being seized
    bool isSeizing;
    // When true, deposit lanes settle from existing positive underlying delta (explicit settle-from-deltas path). No-op for withdrawals.
    bool fromDeltas;
}

/// @notice Explicit vault execution intent computed by VTS settlement paths.
/// @dev `requestedDelta` is the final vault delta to execute after VTS-side clamping.
///      `creditBackedWithdrawal{0,1}` describe the portion of positive withdrawal lanes that
///      are funded by produced same-underlying credit rather than the destination market reserve.
struct VaultSettlementIntent {
    BalanceDelta requestedDelta;
    uint256 creditBackedWithdrawal0;
    uint256 creditBackedWithdrawal1;
}

/// @notice Result of onMMSettle to reduce stack pressure
/// @dev Bundles return values into single struct
struct SettleResult {
    // The delta actually applied to underlying
    BalanceDelta settlementDelta;
    // Explicit vault execution intent for downstream custody calls.
    VaultSettlementIntent vaultSettlementIntent;
    // Whether the RFS is open for the position
    bool rfsOpen;
    // The amount of liquidity units seized (non-zero only when seizing)
    uint256 seizedLiquidityUnits;
}

/// @notice Per-position accounting data (mirrors VTSManager per-position mappings)
/// @dev Split out of VTSManager to follow the Bunni-style storage pattern
struct PositionAccounting {
    // Commitment maxima per token
    TokenPairUint commitmentMax;
    // Settled amounts per token
    TokenPairUint settled;
    /// @dev Deferred positive settlement when inflow would exceed `commitmentMax` on the live `settled` lane.
    ///      Consumed before deficit accrual and migrated into `settled` when headroom reopens.
    TokenPairUint settledOverflow;
    // Cumulative deficit per token (raw units)
    TokenPairUint cumulativeDeficit;
    // Deficit growth snapshots per token
    TokenPairUint deficitGrowthInsideLast;
    // Inflow growth snapshots per token
    TokenPairUint inflowGrowthInsideLast;
    // Cumulative outflows per token
    TokenPairUint cumulativeOutflows;
    // Commitment-scoped deficit (insolvency gate) per token.
    // Derived from checkpoint backing shortfall.
    TokenPairUint commitmentDeficit;
    // Commitment deficit severity in bps (0-10000), updated by commitment checkpoints
    uint16 commitmentDeficitBps;
    // Timestamp at which commitment deficit became non-zero per token (0 when token deficit is zero)
    TokenPairUint commitmentDeficitSince;
}

/// @title PositionAccountingLib
/// @notice Read helpers for `PositionAccounting` (canonical economic quantities per position)
library PositionAccountingLib {
    /// @notice Effective settled per lane: live `settled` + `settledOverflow`
    function effectiveSettled(PositionAccounting storage pa) internal view returns (uint256 eff0, uint256 eff1) {
        eff0 = pa.settled.token0 + pa.settledOverflow.token0;
        eff1 = pa.settled.token1 + pa.settledOverflow.token1;
    }
}

/// @notice Per-pool accounting data (mirrors VTSManager per-pool mappings)
/// @dev Swap growth globals plus pool-wide aggregates for deficit principal and settled liquidity.
struct PoolAccounting {
    // Deficit growth global per token
    TokenPairUint deficitGrowthGlobal;
    // Inflow growth global per token
    TokenPairUint inflowGrowthGlobal;
    // Pool-wide outstanding swap-incurred deficit principal per token (mirrors summed position cumulativeDeficit, excludes commitmentDeficit)
    TokenPairUint totalDeficitPrincipal;
    // Pool-wide total settled aggregate per token
    TokenPairUint totalSettled;
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
/// @dev Used for signed accounting fields like net settlement
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
// forge-lint: disable-next-line(pascal-case-struct)
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
    /// Next commit ID for commit NFTs (starts at 1)
    uint256 nextCommitId;
    /// Global pause flag
    bool isPaused;
}

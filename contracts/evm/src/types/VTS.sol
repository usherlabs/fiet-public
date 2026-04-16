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
    // Fee share applied to LP fees when protocol covers deficits (in basis points)
    uint16 coverageFeeShare;
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
/// @dev Bundles return values into a single struct. When hook data indicates an MM operation, the MM tail
///      (`VTSPositionMMOpsLib.processMMOperations`) runs inside `touchPosition` before `pos` is finalised.
///      `pos` is always reloaded from storage at the end of `touchPosition` so it reflects checkpointing and other
///      MM-tail updates in the same call.
struct TouchPositionResult {
    // The position struct
    Position pos;
    // The position id
    PositionId id;
    // The fee adjustment delta
    BalanceDelta feeAdj;
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
    // Cumulative deficit per token (raw units)
    TokenPairUint cumulativeDeficit;
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
    // Commitment-scoped deficit (insolvency gate) per token.
    // Derived from checkpoint backing shortfall; not part of DICE principal accounting.
    TokenPairUint commitmentDeficit;
    // Commitment deficit severity in bps (0-10000), updated by commitment checkpoints
    uint16 commitmentDeficitBps;
    // Timestamp at which commitment deficit became non-zero per token (0 when token deficit is zero)
    TokenPairUint commitmentDeficitSince;
    // Fees shared by position per token
    TokenPairUint feesShared;
    // Pending fee adjustments per token: +slash (reduces payout), -bonus (increases payout)
    TokenPairInt pendingFeeAdj;
    // DICE: Coverage index checkpoint per token (snapshot of pool index at last settlement)
    TokenPairUint coverageIndexLastX128;
    // DICE: Residual-only coverage index checkpoint per token
    TokenPairUint residualCoverageIndexLastX128;
    // DICE: Banked residual-derived burn base awaiting a later outflow window
    TokenPairUint pendingResidualBurnBase;
    // DICE: Historical fee backing frozen for the currently unresolved residual-burn episode across
    // zero-liquidity intervals and partial liquidity decreases (removed slice). Stored by fee token lane
    // (opposite the deficit token lane) and cleared once that matching residual burn base is fully consumed.
    TokenPairUint pendingResidualFeeBacking;
    // DICE: Outflow watermark captured when residual burn base is banked
    TokenPairUint pendingResidualBurnOutflowsFloor;
    // CISE: Position checkpoint of pool coverage-per-settled index (Q128)
    TokenPairUint ciseIndexLastX128;
    // CISE: Banked realised exposure since last bonus allocation
    TokenPairUint ciseExposureSinceLastMod;
    // CSI: Position checkpoint of the pool remaining-share factor (Q128), last synced from pool for this position.
    // Interpret `feesSharedRemainingFactorLastX128` together with `feesSharedEpoch` on the same token lane:
    // when the position epoch matches the pool epoch, `factor == 0` is the baseline sentinel meaning "no prior
    // remaining-share checkpoint in this epoch yet" and the next sync should adopt the pool factor, not treat the
    // position as fully spent. Fully spent state is represented by `feesShared == 0`, not by a zero factor alone.
    TokenPairUint feesSharedRemainingFactorLastX128;
    // CSI: Position checkpoint of the pool spend epoch (per token), advanced with the pool on sync / setup.
    TokenPairUint feesSharedEpoch;
    // Remainder numerator for coverage fee-burn baseline checkpoint (see VTSFeeLib._applyBurnBase).
    TokenPairUint feeBurnGrowthRemainder;
}

/// @notice Per-pool accounting data (mirrors VTSManager per-pool mappings)
/// @dev Split out of VTSManager to follow the Bunni-style storage pattern
struct PoolAccounting {
    // Deficit growth global per token
    TokenPairUint deficitGrowthGlobal;
    // Inflow growth global per token
    TokenPairUint inflowGrowthGlobal;
    // Protocol/LPs fee pot accrued from fee sharing per token
    TokenPairUint protocolFeeAccrued;
    // Slashed pot balances per token
    TokenPairUint slashedPot;
    // DICE: Pool-wide outstanding swap-incurred deficit principal per token.
    // Mirrors summed cumulativeDeficit and excludes commitmentDeficit.
    TokenPairUint totalDeficitPrincipal;
    // DICE: Coverage-per-deficit-unit index (Q128) per token
    TokenPairUint coveragePerDeficitIndexX128;
    // DICE: Residual-only coverage-per-deficit-unit index (Q128) per token
    TokenPairUint coveragePerResidualDeficitIndexX128;
    // DICE: Deferred coverage residual (socialised when totalDeficitPrincipal = 0 at exercise time)
    TokenPairUint coverageResidualDICE;
    // CISE: Pool-wide total settled aggregate per token
    TokenPairUint totalSettled;
    // CISE: Coverage-per-settled index (Q128) per token
    TokenPairUint coveragePerSettledIndexX128;
    // CISE: Pool-wide bonus denominator window: incremented by coveredAmount on each allocatable coverage index step
    // and decremented when bonuses are allocated. Position numerators accrue lazily. Coverage exercised while
    // `totalSettled == 0` is intentionally excluded from CISE rather than being deferred and socialised later.
    TokenPairUint totalCISEExposureSinceLastMod;
    // CSI: Pool-wide remaining-share factor (Q128). Zero means either "no spend this epoch yet" or
    // "epoch fully spent"; `feesSharedEpoch` disambiguates replacement epochs.
    TokenPairUint feesSharedRemainingFactorX128;
    // CSI: Pool-wide spend epoch, incremented when a fully-spent epoch is replaced by fresh contributions.
    TokenPairUint feesSharedEpoch;
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

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionId, Position} from "../types/Position.sol";
import {MarketVTSConfiguration, VaultSettlementIntent} from "../types/VTS.sol";
import {MarketMaker} from "../libraries/MarketMaker.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {RFSCheckpoint} from "../types/Checkpoint.sol";
import {IPausableVTS} from "./IPausableVTS.sol";
import {IVTSCurrencyDelta} from "./IVTSCurrencyDelta.sol";
import {IVTSAdmin} from "./IVTSAdmin.sol";
import {IMarketFactory} from "./IMarketFactory.sol";

interface IVTSOrchestrator is IPausableVTS, IVTSCurrencyDelta, IVTSAdmin {
    // Events
    event Checkpointed(uint256 commitId, uint256 positionIndex, RFSCheckpoint checkpoint, bool withCommitment);
    event GracePeriodExtended(uint256 commitId, uint256 positionIndex, uint8 tokenIndex, RFSCheckpoint checkpoint);
    event PositionSettled(
        uint256 indexed commitId,
        uint256 indexed positionIndex,
        int128 settlementDelta0,
        int128 settlementDelta1,
        uint256 settledToken0,
        uint256 settledToken1,
        bool isSeizing,
        bool rfsOpen
    );

    // Access Control / Config

    // State Getters
    /// @notice Get a position by PositionId
    /// @param positionId The position identifier
    /// @return The Position struct
    function getPosition(PositionId positionId) external view returns (Position memory);

    /// @notice Get a position by commit ID and position index
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    /// @return The Position struct
    /// @return The PositionId
    function getPosition(uint256 commitId, uint256 positionIndex) external view returns (Position memory, PositionId);

    /// @notice Get the next commit ID that will be assigned
    /// @return The next commit ID (will be assigned on next commitSignal call)
    function nextCommitId() external view returns (uint256);

    /// @notice Get commit information by commit ID
    /// @dev Note: Cannot return Commit directly due to mapping in struct
    /// @param commitId The commit identifier
    /// @return mmState The MarketMaker state
    /// @return expiresAt The expiration timestamp
    /// @return positionCount The count of positions in the commit
    /// @return activePositionCount The count of active positions in the commit
    /// @return inactiveRemnantCount Inactive positions under this commit that still hold non-zero live `pa.settled` (blocks decommit)
    function getCommit(uint256 commitId)
        external
        view
        returns (
            MarketMaker.State memory mmState,
            uint256 expiresAt,
            uint256 positionCount,
            uint256 activePositionCount,
            uint256 inactiveRemnantCount
        );

    /// @notice Get pool information by PoolId
    /// @dev Note: Cannot return Pool directly due to mapping in struct
    /// @param poolId The pool identifier
    /// @return id The pool ID
    /// @return currency0 Token0 currency
    /// @return currency1 Token1 currency
    /// @return vtsConfig The VTS configuration
    /// @return _isPaused Whether the pool is paused
    function getPool(PoolId poolId)
        external
        view
        returns (
            PoolId id,
            Currency currency0,
            Currency currency1,
            MarketVTSConfiguration memory vtsConfig,
            bool _isPaused
        );

    // Position metadata / validity helper (canonical Position-based surface)
    /// @notice Check if a position is valid
    /// @param id The position identifier
    /// @param requireActive Whether the position must be active
    /// @return True if the position is valid under the requested constraints
    function isPositionValid(PositionId id, bool requireActive) external view returns (bool);

    /// @notice Checks if a commit exists and optionally enforces a live VRL-backed signal
    /// @param commitId The commit identifier
    /// @param requireLiveSignal If true, requires non-empty reserves, not expired, and a non-zero owner. If false,
    ///        only requires an initialised commit with a non-zero owner (empty reserves allowed for recovery flows).
    /// @return isValid True if the commit satisfies the requested constraints
    function isSignalValid(uint256 commitId, bool requireLiveSignal) external view returns (bool isValid);

    // VTS Logic & Settlement
    /// @notice Settle position growths before liquidity modifications
    /// @dev Called by CoreHook to settle position growths before adding or removing liquidity
    /// @param positionId The position identifier
    function settlePositionGrowths(PositionId positionId) external;

    /// @notice Get the protocol fee accrued (slashed fees) for a pool
    /// @param poolId The pool identifier
    /// @return fee0 The accrued fee for token0
    /// @return fee1 The accrued fee for token1
    function getProtocolFeeAccrued(PoolId poolId) external view returns (uint256 fee0, uint256 fee1);

    /// @notice Get the materialised slashed pot (claimables available for bonus payouts) for a pool
    /// @param poolId The pool identifier
    /// @return pot0 Slashed pot balance for token0
    /// @return pot1 Slashed pot balance for token1
    function getSlashedPot(PoolId poolId) external view returns (uint256 pot0, uint256 pot1);

    /// @notice Get fee-sharing accounting for a position
    /// @dev `pendingFeeAdj` is signed: +slash (funds pot), -bonus (drains pot when materialised)
    /// @param positionId The position identifier
    /// @return feesShared0 Total fees attributed to this position for token0
    /// @return feesShared1 Total fees attributed to this position for token1
    /// @return pendingFeeAdj0 Pending fee adjustment for token0 (+slash, -bonus)
    /// @return pendingFeeAdj1 Pending fee adjustment for token1 (+slash, -bonus)
    function getPositionFeeAccounting(PositionId positionId)
        external
        view
        returns (uint256 feesShared0, uint256 feesShared1, int256 pendingFeeAdj0, int256 pendingFeeAdj1);

    /// @notice Initialize a market's configuration in the VTS state
    /// @dev Called by MarketFactory contract during market creation
    /// @param corePoolKey The core pool key
    /// @param vtsConfiguration The VTS configuration
    function initPool(PoolKey memory corePoolKey, MarketVTSConfiguration memory vtsConfiguration) external;

    /// @notice Get the market VTS configuration
    /// @param corePoolId The core pool ID
    /// @return The MarketVTSConfiguration struct
    function getMarketVTSConfiguration(PoolId corePoolId) external view returns (MarketVTSConfiguration memory);

    // RFS Calculation & VTS Metrics
    /// @notice Calculate the Risk-Free Settlement (RFS) status for a position
    /// @param positionId The position identifier
    /// @param requireClosedRfS Whether to require the RFS to be closed
    /// @return rfsOpen True if RFS is open, false if closed
    /// @return delta The balance delta for the position
    function calcRFS(PositionId positionId, bool requireClosedRfS) external returns (bool, BalanceDelta);
    /// @notice Calculate the Risk-Free Settlement (RFS) status for a position by commit ID and index
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    /// @param requireClosedRfS Whether to require the RFS to be closed
    /// @return positionId The position identifier
    /// @return rfsOpen True if RFS is open, false if closed
    /// @return delta The balance delta for the position
    function calcRFS(uint256 commitId, uint256 positionIndex, bool requireClosedRfS)
        external
        returns (PositionId, bool, BalanceDelta);

    /// @notice Get the position ID for a given commit ID and position index
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    /// @return The position identifier
    function getPositionId(uint256 commitId, uint256 positionIndex) external view returns (PositionId);

    /// @notice Get the settled amounts for a position
    /// @param positionId The position identifier
    /// @return amount0 Settled amount for token0
    /// @return amount1 Settled amount for token1
    function getPositionSettledAmounts(PositionId positionId) external view returns (uint256 amount0, uint256 amount1);

    /// @notice Increment coverage amounts for a pool
    /// @param poolId The pool identifier
    /// @param amount0 Amount to increment for token0
    /// @param amount1 Amount to increment for token1
    function incrementCoverage(PoolId poolId, uint256 amount0, uint256 amount1) external;

    /// @notice Get the maximum commitment amounts for a position
    /// @param positionId The position identifier
    /// @return commitment0 Maximum commitment for token0
    /// @return commitment1 Maximum commitment for token1
    function getCommitmentMaxima(PositionId positionId) external view returns (uint256 commitment0, uint256 commitment1);

    // CoreHook
    /// @notice Called by CoreHook after add/remove liquidity to update position state and process fees
    /// @dev Consolidates all delta management for both MM and DirectLP positions.
    ///      For MM positions: handles fee accounting, LCC issuance/cancellation, position linking, and delta accounting.
    /// @param owner The owner of the position (e.g., MMPositionManager or other router)
    /// @param poolKey The pool key for the position
    /// @param params The modify liquidity params
    /// @param callerDelta The caller delta from poolManager.modifyLiquidity
    /// @param feesAccrued The fees accrued from poolManager.modifyLiquidity
    /// @param hookData The hook data containing PositionModificationHookData for MM operations
    /// @return pos The position struct
    /// @return id The position id
    /// @return feeAdj The fee adjustment delta
    /// @return isMMPosition True if this is an MM position operation with valid signal
    function processPosition(
        address owner,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata params,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (Position memory pos, PositionId id, BalanceDelta feeAdj, bool isMMPosition);

    /// @notice Called by CoreHook after a swap to process swap-related accounting
    /// @param key The pool key
    /// @param params The swap parameters
    /// @param delta The balance delta from the swap
    /// @param sqrtPBefore The sqrt price before the swap
    /// @param liqBefore The liquidity before the swap
    /// @param tickBefore Authoritative `slot0.tick` before the swap (must not be derived from `sqrtPBefore` alone)
    function afterCoreSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        uint160 sqrtPBefore,
        uint128 liqBefore,
        int24 tickBefore
    ) external;

    // MMPositionManager Functions
    /// @notice Commit a liquidity signal to the VTS state
    /// @param sender The effective caller (locker) for commit authorisation
    /// @param liquiditySignal The liquidity signal to commit
    /// @return commitId The commit identifier for the committed signal
    function commitSignal(IMarketFactory factory, address sender, bytes memory liquiditySignal)
        external
        returns (uint256 commitId);
    /// @notice Commit a liquidity signal using sender-signed EIP-712 relayer authorisation
    /// @param factory The market factory namespace for caller-bound validation (mirrors non-relayed commit)
    function commitSignalRelayed(
        IMarketFactory factory,
        address sender,
        bytes memory liquiditySignal,
        uint256 deadline,
        uint256 authNonce,
        bytes memory authSig
    ) external returns (uint256 commitId);
    /// @notice Extend the grace period for a position
    /// @param poolKey The pool key for the position
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    /// @param settlementTokenIndex The index of the settlement token
    /// @param verifierIndex The verifier index
    /// @param settlementProof The settlement proof
    function extendGracePeriod(
        IMarketFactory factory,
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) external;

    /// @notice Settle a market maker position
    /// @dev Called by MMPositionManager to settle a position, handling both normal settlement and seizure
    /// @param factory The market factory namespace for caller-bound validation
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    /// @param amountDelta The amount delta for settlement
    /// @param isSeizing Whether the position is being seized
    /// @param fromDeltas When true, deposit lanes consume existing positive underlying delta (settle-from-deltas).
    ///        Withdrawal lanes ignore this flag; they always follow the withdrawal path in `VTSLifecycleLinkedLib`.
    /// @return settlementDelta The settlement balance delta
    /// @return rfsOpen Whether the RFS is open after settlement
    /// @return seizedLiquidityUnits The amount of liquidity units seized (0 if not seizing)
    /// @return vaultSettlementIntent Explicit vault execution intent for downstream custody handling
    function onMMSettle(
        IMarketFactory factory,
        uint256 commitId,
        uint256 positionIndex,
        BalanceDelta amountDelta,
        bool isSeizing,
        bool fromDeltas
    )
        external
        returns (
            BalanceDelta settlementDelta,
            bool rfsOpen,
            uint256 seizedLiquidityUnits,
            VaultSettlementIntent memory vaultSettlementIntent
        );

    /// @notice Validate that the grace period has elapsed for a position (required before seizure)
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    function onSeize(uint256 commitId, uint256 positionIndex) external;

    /// @notice Renew a liquidity signal for an existing commit, using an explicit sender for advancer validation
    /// @dev Useful for router-style callers where msg.sender is a forwarding contract
    /// @param sender The effective caller (locker) used for advancer validation
    /// @param commitId The commit identifier to renew
    /// @param liquiditySignal The new liquidity signal
    function renewSignal(IMarketFactory factory, address sender, uint256 commitId, bytes memory liquiditySignal)
        external;
    /// @notice Renew a liquidity signal using sender-signed EIP-712 relayer authorisation
    /// @param factory The market factory namespace for caller-bound validation (mirrors non-relayed renew)
    function renewSignalRelayed(
        IMarketFactory factory,
        address sender,
        uint256 commitId,
        bytes memory liquiditySignal,
        uint256 deadline,
        uint256 authNonce,
        bytes memory authSig
    ) external;

    /// @notice Checkpoint a position and optionally run commitment backing checks
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    /// @param withCommitment Whether to run commitment backing checks and update position deficits
    function checkpoint(uint256 commitId, uint256 positionIndex, bool withCommitment) external;

    // Checkpoints
    /// @notice Get the checkpoint for a given position
    /// @param positionId The position identifier
    /// @return checkpoint The RFS checkpoint for the position
    function positionToCheckpoint(PositionId positionId) external view returns (RFSCheckpoint memory);
}

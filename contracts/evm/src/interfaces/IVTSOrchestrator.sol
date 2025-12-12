// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionId, Position} from "../types/Position.sol";
import {MarketVTSConfiguration} from "../types/VTS.sol";
import {MarketMaker} from "../libraries/MarketMaker.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {RFSCheckpoint} from "../types/Checkpoint.sol";
import {IPausableVTS} from "./IPausableVTS.sol";
import {IVTSCurrencyDelta} from "./IVTSCurrencyDelta.sol";
import {IMarketVault} from "./IMarketVault.sol";

interface IVTSOrchestrator is IPausableVTS, IVTSCurrencyDelta {
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

    /// @notice Get commit information by commit ID
    /// @dev Note: Cannot return Commit directly due to mapping in struct
    /// @param commitId The commit identifier
    /// @return mmState The MarketMaker state
    /// @return expiresAt The expiration timestamp
    /// @return positionCount The count of positions in the commit
    function getCommit(uint256 commitId)
        external
        view
        returns (MarketMaker.State memory mmState, uint256 expiresAt, uint256 positionCount);

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

    // VTS Logic & Settlement
    /// @notice Settle position growths before liquidity modifications
    /// @dev Called by CoreHook to settle position growths before adding or removing liquidity
    /// @param positionId The position identifier
    function settlePositionGrowths(PositionId positionId) external;

    /// @notice Initialize a market's configuration in the VTS state
    /// @dev Called by MarketFactory contract during market creation
    /// @param corePoolKey The core pool key
    /// @param vtsConfiguration The VTS configuration
    function initPool(PoolKey memory corePoolKey, MarketVTSConfiguration memory vtsConfiguration) external;

    /// @notice Set the market VTS configuration
    /// @param corePoolId The core pool ID
    /// @param vtsConfiguration The VTS configuration to set
    function setMarketVTSConfiguration(PoolId corePoolId, MarketVTSConfiguration memory vtsConfiguration) external;

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

    /// @notice Calculate the current VTS amounts for a position
    /// @param positionId The position identifier
    /// @return vtsCurrent0 Current VTS amount for token0
    /// @return vtsCurrent1 Current VTS amount for token1
    function calcVTSCurrent(PositionId positionId) external returns (uint256 vtsCurrent0, uint256 vtsCurrent1);

    /// @notice Calculate the required VTS amounts for a position
    /// @param positionId The position identifier
    /// @return vtsRequired0 Required VTS amount for token0
    /// @return vtsRequired1 Required VTS amount for token1
    function calcVTSRequired(PositionId positionId) external returns (uint256 vtsRequired0, uint256 vtsRequired1);

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
    function processPosition(
        address owner,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata params,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (Position memory pos, PositionId id, BalanceDelta feeAdj);

    /// @notice Called by CoreHook after a swap to process swap-related accounting
    /// @param key The pool key
    /// @param params The swap parameters
    /// @param delta The balance delta from the swap
    /// @param sqrtPBefore The sqrt price before the swap
    /// @param liqBefore The liquidity before the swap
    function afterCoreSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        uint160 sqrtPBefore,
        uint128 liqBefore
    ) external;

    // MMPositionManager Functions
    /// @notice Commit a liquidity signal to the VTS state
    /// @param liquiditySignal The liquidity signal to commit
    /// @return commitId The commit identifier for the committed signal
    function commitSignal(bytes memory liquiditySignal) external returns (uint256 commitId);
    /// @notice Extend the grace period for a position
    /// @param poolKey The pool key for the position
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    /// @param settlementTokenIndex The index of the settlement token
    /// @param verifierIndex The verifier index
    /// @param settlementProof The settlement proof
    function extendGracePeriod(
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) external;

    /// @notice Settle a market maker position
    /// @dev Called by MMPositionManager to settle a position, handling both normal settlement and seizure
    /// @param marketVault The market vault contract
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    /// @param currency0 The currency0 token
    /// @param currency1 The currency1 token
    /// @param amountDelta The amount delta for settlement
    /// @param isSeizing Whether the position is being seized
    /// @return settlementDelta The settlement balance delta
    /// @return rfsOpen Whether the RFS is open after settlement
    /// @return seizedLiquidityUnits The amount of liquidity units seized (0 if not seizing)
    function onMMSettle(
        IMarketVault marketVault,
        uint256 commitId,
        uint256 positionIndex,
        Currency currency0,
        Currency currency1,
        BalanceDelta amountDelta,
        bool isSeizing
    ) external returns (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiquidityUnits);

    /// @notice Validate that the grace period has elapsed for a position (required before seizure)
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    function onSeize(uint256 commitId, uint256 positionIndex) external;

    /// @notice Renew a liquidity signal for an existing commit
    /// @param commitId The commit identifier to renew
    /// @param liquiditySignal The new liquidity signal
    function renewSignal(uint256 commitId, bytes memory liquiditySignal) external;

    /// @notice Checkpoint a position and optionally run commitment backing checks
    /// @param sender The caller address (used for advancer validation when withCommitment is true)
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    /// @param liquiditySignal The liquidity signal (required when withCommitment is true)
    /// @param withCommitment Whether to run commitment backing checks and update position deficits
    function checkpoint(
        address sender,
        uint256 commitId,
        uint256 positionIndex,
        bytes memory liquiditySignal,
        bool withCommitment
    ) external;

    // Checkpoints & Fee Collection
    /// @notice Get the checkpoint for a given position
    /// @param positionId The position identifier
    /// @return checkpoint The RFS checkpoint for the position
    function positionToCheckpoint(PositionId positionId) external view returns (RFSCheckpoint memory);

    /// @notice Collect LCC fees by converting ERC-6909 claims to actual ERC20 tokens
    /// @dev Must be called during an active PoolManager unlock context. The caller must have ERC-6909 claims
    ///      and positive VTS delta credit for the LCC currency.
    /// @param lccCurrency The LCC currency to collect fees for
    /// @param recipient The recipient of the actual ERC20 tokens
    /// @param maxAmount The maximum amount to collect (0 = collect full available credit)
    /// @return collected The amount actually collected
    function collectFees(Currency lccCurrency, address recipient, uint256 maxAmount)
        external
        returns (uint256 collected);
}

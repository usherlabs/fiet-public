// SPDX-License-Identifier: MIT
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
    event PoolInitialized(
        PoolId indexed corePoolId,
        address indexed currency0,
        address indexed currency1,
        MarketVTSConfiguration vtsConfiguration
    );

    // Access Control / Config
    function setMMPositionManager(address _mmPositionManager) external;

    // State Getters
    function getPosition(PositionId positionId) external view returns (Position memory);
    function getPosition(uint256 commitId, uint256 positionIndex) external view returns (Position memory, PositionId);
    function getCommit(uint256 commitId)
        external
        view
        returns (MarketMaker.State memory mmState, uint256 expiresAt, uint256 positionCount, uint256 deficitBps);
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
    function isPositionValid(PositionId id, bool requireActive) external view returns (bool);

    // VTS Logic & Settlement
    function settlePositionGrowths(PositionId positionId) external;
    function initPool(PoolKey memory corePoolKey, MarketVTSConfiguration memory vtsConfiguration) external;
    function setMarketVTSConfiguration(PoolId corePoolId, MarketVTSConfiguration memory vtsConfiguration) external;
    function getMarketVTSConfiguration(PoolId corePoolId) external view returns (MarketVTSConfiguration memory);

    // NOTE: onMMSettle has been removed from the interface.
    // Settlement is now handled internally via VTSSettleLib.onMMSettle called from _settle.

    function calcRFS(PositionId positionId, bool requireClosedRfS) external returns (bool, BalanceDelta);
    function calcRFS(uint256 commitId, uint256 positionIndex, bool requireClosedRfS)
        external
        returns (PositionId, bool, BalanceDelta);
    function getPositionId(uint256 commitId, uint256 positionIndex) external view returns (PositionId);
    function calcVTSCurrent(PositionId positionId) external returns (uint256 vtsCurrent0, uint256 vtsCurrent1);
    function calcVTSRequired(PositionId positionId) external returns (uint256 vtsRequired0, uint256 vtsRequired1);
    function getPositionSettledAmounts(PositionId positionId) external view returns (uint256 amount0, uint256 amount1);
    function incrementCoverage(PoolId poolId, uint256 amount0, uint256 amount1) external;
    function getCommitment(PositionId positionId) external view returns (uint256 commitment0, uint256 commitment1);
    function applyCommitmentDeficit(PositionId[] calldata ids, uint256 totalDeficitBps) external;

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

    function afterCoreSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        uint160 sqrtPBefore,
        uint128 liqBefore
    ) external;

    // MMPositionManager
    function commitSignal(bytes memory liquiditySignal) external returns (uint256 commitId);
    function extendGracePeriod(
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) external;

    function onMMSettle(
        IMarketVault marketVault,
        PositionId positionId,
        Currency currency0,
        Currency currency1,
        BalanceDelta amountDelta,
        bool isSeizing
    ) external returns (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiquidityUnits);

    function onSeize(uint256 commitId, uint256 positionIndex) external;

    function renewSignal(uint256 commitId, bytes memory liquiditySignal) external;
    function declareUnbackedCommitment(address sender, uint256 commitId, bytes memory liquiditySignal) external;

    // Checkpoints
    function positionToCheckpoint(PositionId positionId) external view returns (RFSCheckpoint memory);
    /// @notice Marks a checkpoint for a given position
    /// @param positionId The position ID
    /// @param rfsOpen Whether the RFS is open
    function markCheckpoint(PositionId positionId, bool rfsOpen) external;

    function collectFees(Currency lccCurrency, address recipient, uint256 maxAmount)
        external
        returns (uint256 collected);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionId, Position, PositionMeta} from "../types/Position.sol";
import {MarketVTSConfiguration} from "../types/VTS.sol";
import {MarketMaker} from "../libraries/MarketMaker.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {RFSCheckpoint} from "../types/Checkpoint.sol";

interface IVTSOrchestrator {
    // Events
    event PoolInitialized(
        PoolId indexed corePoolId,
        address indexed currency0,
        address indexed currency1,
        MarketVTSConfiguration vtsConfiguration
    );

    // Access Control / Config
    function setMMPositionManager(address _mmPositionManager) external;
    function setPaused(bool paused) external;
    function isPaused() external view returns (bool);

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

    // IPositionRegistry
    function getPosition(PositionId id, bool requireActive, bool revertIfInvalid)
        external
        view
        returns (PositionMeta memory);
    function isPositionValid(PositionId id, bool requireActive) external view returns (bool);

    // VTS Logic & Settlement
    function settlePositionGrowths(PositionId positionId) external;
    function initPool(PoolKey memory corePoolKey, MarketVTSConfiguration memory vtsConfiguration) external;
    function setMarketVTSConfiguration(PoolId corePoolId, MarketVTSConfiguration memory vtsConfiguration) external;
    function getMarketVTSConfiguration(PoolId corePoolId) external view returns (MarketVTSConfiguration memory);

    function onMMSettle(
        PositionId positionId,
        Currency lccCurrency0,
        Currency lccCurrency1,
        BalanceDelta delta,
        bool isSeizing
    ) external returns (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiquidityUnits);

    function calcRFS(PositionId positionId, bool requireClosedRfS) external returns (bool, BalanceDelta);
    function calcRFS(uint256 commitId, uint256 positionIndex, bool requireClosedRfS)
        external
        returns (PositionId, bool, BalanceDelta);
    function getPositionId(uint256 commitId, uint256 positionIndex) external view returns (PositionId);
    function calcVTSCurrent(PositionId positionId) external returns (uint256 vtsCurrent0, uint256 vtsCurrent1);
    function getPositionSettledAmounts(PositionId positionId) external view returns (uint256 amount0, uint256 amount1);
    function incrementCoverage(PoolId poolId, uint256 amount0, uint256 amount1) external;
    function getCommitment(PositionId positionId) external view returns (uint256 commitment0, uint256 commitment1);
    function applyCommitmentDeficit(PositionId[] calldata ids, uint256 totalDeficitBps) external;

    // CoreHook
    function touchAndProcessPosition(
        address owner,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata params,
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
    function mintPosition(
        address owner,
        PoolKey memory poolKey,
        uint256 commitId,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    ) external returns (PositionId positionId, uint256 positionIndex);

    function increaseInternal(
        address owner,
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    ) external returns (PositionId);

    function decreaseInternal(
        address sender,
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        bytes32 salt,
        uint256 amountToDecrease,
        bytes memory hookData
    ) external returns (BalanceDelta, BalanceDelta);

    function getFullCredit(Currency currency, address owner) external view returns (uint256);
    function collectAvailableLiquidity(address sender, address lcc, address recipient, uint256 maxAmount) external;
    function settleFromDeltas(
        address sender,
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        bool settleIn0,
        bool settleIn1
    ) external returns (BalanceDelta sDelta);

    function take(Currency currency, address sender, address to, uint256 maxAmount) external;
    function extendGracePeriod(
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) external;

    function seizePosition(
        address sender,
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        uint256 amount0,
        uint256 amount1
    ) external;

    function wrapNative(address sender, uint256 amount) external payable;
    function unwrapNative(address sender, uint256 amount) external;
    function unwrapLCC(address sender, address lccAddr, address from, address to, uint256 requested)
        external
        returns (uint256 unwrapped, address underlying);

    function getLiquidityFromDeltas(address owner, PoolKey memory poolKey, int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint256 liquidity);

    function settle(
        address sender,
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        BalanceDelta sDelta
    ) external returns (uint256 seizedLiquidityUnits, bool isSeizing);

    function renewSignal(uint256 commitId, bytes memory liquiditySignal) external;
    function declareUnbackedCommitment(address sender, uint256 commitId, bytes memory liquiditySignal) external;
    function getSettlementDelta(address user, address currency0, address currency1) external view returns (BalanceDelta);

    // Checkpoints
    function positionToCheckpoint(PositionId positionId) external view returns (RFSCheckpoint memory);
    function markCheckpoint(uint256 commitId, uint256 positionIndex) external;
}

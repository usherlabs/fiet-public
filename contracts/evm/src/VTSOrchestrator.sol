// SPDX-License-Identifier: MIT
// This contract is the central state management layer and orchestrator for VTS logic
// Adopts Bunni-style pattern: state in storage struct, logic delegated to linked libraries
pragma solidity ^0.8.26;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionId} from "./types/Position.sol";
import {PositionMeta, Position} from "./types/Position.sol";
import {Commit} from "./types/Commit.sol";
import {Pool} from "./types/Pool.sol";
import {MarketVTSConfiguration, PositionAccounting} from "./types/VTS.sol";
import {MarketMaker} from "./libraries/MarketMaker.sol";
import {
    IPoolManager
} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {VTSStorage} from "./types/VTS.sol";
import {IVTSManager} from "./interfaces/IVTSManager.sol";
import {IPositionRegistry} from "./interfaces/IPositionRegistry.sol";
import {
    VTSPoolAndPositionAccountingLib
} from "./libraries/VTSPoolAndPositionAccountingLib.sol";
import {VTSSettleLib} from "./libraries/VTSSettleLib.sol";
import {VTSCommitLib} from "./libraries/VTSCommitLib.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TransientSlots} from "./libraries/TransientSlots.sol";
import {Errors} from "./libraries/Errors.sol";

/// @notice Custom errors for VTSOrchestrator
error VTSOrchestrator__InvalidPoolManager();
error VTSOrchestrator__InvalidOwner();
error VTSOrchestrator__Paused();
error VTSOrchestrator__InvalidPosition();

/// @title VTSOrchestrator
/// @notice Central state management layer and orchestrator for VTS logic
/// @dev Adopts Bunni-style pattern: state managed in VTSStorage struct, complex logic delegated to linked libraries
/// @author Fiet Protocol
contract VTSOrchestrator is Ownable, IVTSManager, IPositionRegistry {
    /// @notice Central storage pointer (passed to libraries)
    VTSStorage internal s;

    /// @notice Immutable pool manager reference
    IPoolManager public immutable poolManager;

    /// @notice MarketFactory address (for access control)
    address public immutable marketFactory;

    /// @notice MM Position Manager address (for access control)
    address public immutable mmPositionManager;

    /// @notice Event emitted when VTS configuration is set
    event MarketVTSConfigurationSet(
        PoolId indexed corePoolId,
        MarketVTSConfiguration indexed vtsConfiguration
    );

    /// @notice Constructor
    /// @param _poolManager The Uniswap V4 PoolManager address
    /// @param _marketFactory The MarketFactory address
    /// @param _mmPositionManager The MM Position Manager address
    /// @param initialOwner The initial owner address
    constructor(
        address _poolManager,
        address _marketFactory,
        address _mmPositionManager,
        address initialOwner
    ) Ownable(initialOwner) {
        if (_poolManager == address(0))
            revert VTSOrchestrator__InvalidPoolManager();
        if (_marketFactory == address(0)) revert Errors.InvalidSender();
        if (_mmPositionManager == address(0)) revert Errors.InvalidSender();
        if (initialOwner == address(0)) revert VTSOrchestrator__InvalidOwner();
        poolManager = IPoolManager(_poolManager);
        marketFactory = _marketFactory;
        mmPositionManager = _mmPositionManager;
    }

    /// @notice Modifier to check if caller is MarketFactory
    modifier onlyFactory() {
        if (msg.sender != marketFactory) revert Errors.InvalidSender();
        _;
    }

    /// @notice Modifier to check if caller is MM Position Manager
    modifier onlyMMPosition(PositionId positionId) {
        if (msg.sender != mmPositionManager) revert Errors.InvalidSender();
        if (!_isMMPosition(positionId)) {
            revert Errors.InvalidPosition(0, 0, positionId);
        }
        _;
    }

    /// @notice Modifier to check if position is valid
    modifier onlyPositionValid(PositionId positionId) {
        if (!isPositionValid(positionId, true)) {
            revert Errors.InvalidPosition(0, 0, positionId);
        }
        _;
    }

    /// @notice Modifier to check if contract is not paused
    modifier notPaused() {
        if (s.isPaused) revert VTSOrchestrator__Paused(); // TODO: To use Errors.sol
        _;
    }

    /// @notice Check if a position is MM-managed
    /// @param positionId The position ID
    /// @return True if position is owned by MM Position Manager
    function _isMMPosition(PositionId positionId) internal view returns (bool) {
        return s.positions[positionId].owner == mmPositionManager;
    }

    /// @notice Get position by PositionId
    /// @param positionId The position identifier
    /// @return The Position struct
    function getPosition(
        PositionId positionId
    ) external view returns (Position memory) {
        return s.positions[positionId];
    }

    /// @notice Get commit by tokenId
    /// @dev Note: Cannot return Commit directly due to mapping in struct
    /// @param tokenId The commit token identifier
    /// @return mmState The MarketMaker state
    /// @return expiresAt The expiration timestamp
    /// @return poolId The bound pool ID
    /// @return positionCount The count of positions
    /// @return deficitBps The deficit basis points
    function getCommit(
        uint256 tokenId
    )
        external
        view
        returns (
            MarketMaker.State memory mmState,
            uint256 expiresAt,
            uint256 positionCount,
            uint256 deficitBps
        )
    {
        Commit storage commit = s.commits[tokenId];
        return (
            commit.mmState,
            commit.expiresAt,
            commit.positionCount,
            commit.deficitBps
        );
    }

    /// @notice Get position ID for a commit at a specific index
    /// @param tokenId The commit token identifier
    /// @param positionIndex The position index
    /// @return The PositionId at the given index
    function getCommitPosition(
        uint256 tokenId,
        uint256 positionIndex
    ) external view returns (PositionId) {
        return s.commits[tokenId].positions[positionIndex];
    }

    /// @notice Get pool by PoolId
    /// @dev Note: Cannot return Pool directly due to mapping in struct
    /// @param poolId The pool identifier
    /// @return id The pool ID
    /// @return currency0 Token0 currency
    /// @return currency1 Token1 currency
    /// @return vtsConfig The VTS configuration
    /// @return isPaused Whether pool is paused
    function getPool(
        PoolId poolId
    )
        external
        view
        returns (
            PoolId id,
            Currency currency0,
            Currency currency1,
            MarketVTSConfiguration memory vtsConfig,
            bool isPaused
        )
    {
        Pool storage pool = s.pools[poolId];
        return (
            pool.id,
            pool.currency0,
            pool.currency1,
            pool.vtsConfig,
            pool.isPaused
        );
    }

    /// @notice Set global pause flag
    /// @param paused Whether to pause all operations
    function setPaused(bool paused) external onlyOwner {
        s.isPaused = paused;
    }

    /// @notice Get global pause status
    /// @return Whether operations are paused
    function isPaused() external view returns (bool) {
        return s.isPaused;
    }

    // --------------------------------------------------
    // IPositionRegistry Implementation
    // --------------------------------------------------
    // TODO: By moving MMP related core logic into the Orchestator as a library (ie. MMPositionsLib.sol), then it can internally call for state on VTSStorage
    /// @inheritdoc IPositionRegistry
    function getPosition(
        PositionId id,
        bool requireActive,
        bool revertIfInvalid
    ) external view returns (PositionMeta memory) {
        Position memory pos = s.positions[id];
        if (pos.owner == address(0)) {
            if (revertIfInvalid) revert Errors.InvalidPosition(0, 0, id);
            return
                PositionMeta({
                    tickLower: 0,
                    tickUpper: 0,
                    liquidity: 0,
                    owner: address(0),
                    isActive: false,
                    poolId: PoolId.wrap(bytes32(0))
                });
        }
        if (requireActive && !pos.isActive) {
            if (revertIfInvalid) revert Errors.InvalidPosition(0, 0, id);
            return
                PositionMeta({
                    tickLower: pos.tickLower,
                    tickUpper: pos.tickUpper,
                    liquidity: int256(uint256(pos.liquidity)),
                    owner: pos.owner,
                    isActive: false,
                    poolId: pos.poolId
                });
        }
        return
            PositionMeta({
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                liquidity: int256(uint256(pos.liquidity)),
                owner: pos.owner,
                isActive: pos.isActive,
                poolId: pos.poolId
            });
    }

    /// @inheritdoc IPositionRegistry
    function isPositionValid(
        PositionId id,
        bool requireActive
    ) public view returns (bool) {
        Position memory pos = s.positions[id];
        if (pos.owner == address(0)) return false;
        if (requireActive && !pos.isActive) return false;
        PositionAccounting storage pa = s.positionAccounting[id];
        // Commitment maxima must be > 0 for active positions
        if (
            requireActive &&
            (pa.commitmentMax.token0 == 0 || pa.commitmentMax.token1 == 0)
        ) {
            return false;
        }
        return true;
    }

    // --------------------------------------------------
    // IVTSManager Implementation
    // --------------------------------------------------

    /// @inheritdoc IVTSManager
    function setMarketVTSConfiguration(
        PoolId corePoolId,
        MarketVTSConfiguration memory vtsConfiguration
    ) external onlyFactory {
        s.pools[corePoolId].vtsConfig = vtsConfiguration;
        emit MarketVTSConfigurationSet(corePoolId, vtsConfiguration);
    }

    /// @inheritdoc IVTSManager
    function getMarketVTSConfiguration(
        PoolId corePoolId
    ) external view returns (MarketVTSConfiguration memory) {
        return s.pools[corePoolId].vtsConfig;
    }

    /// @inheritdoc IVTSManager
    function onMMSettle(
        PositionId positionId,
        Currency lccCurrency0,
        Currency lccCurrency1,
        BalanceDelta delta,
        bool isSeizing
    )
        external
        onlyMMPosition(positionId)
        notPaused
        returns (
            BalanceDelta settlementDelta,
            bool rfsOpen,
            uint256 seizedLiquidityUnits
        )
    {
        // Read positionRequiredSettlementDelta from transient storage
        BalanceDelta positionRequiredSettlementDelta = TransientSlots
            .readPositionRequiredSettlementDelta(positionId);

        return
            VTSSettleLib.onMMSettle(
                s,
                poolManager,
                positionId,
                lccCurrency0,
                lccCurrency1,
                delta,
                isSeizing,
                positionRequiredSettlementDelta
            );
    }

    /// @inheritdoc IVTSManager
    function calcRFS(
        PositionId positionId,
        bool requireClosedRfS
    ) external onlyPositionValid(positionId) returns (bool, BalanceDelta) {
        VTSPoolAndPositionAccountingLib._settlePositionGrowths(
            s,
            poolManager,
            positionId
        );
        (bool rfsOpen, BalanceDelta delta) = VTSSettleLib._getRFS(
            s,
            positionId
        );
        if (requireClosedRfS && rfsOpen) {
            revert Errors.RFSOpenForPosition(positionId);
        }
        return (rfsOpen, delta);
    }

    // TODO: Not necessary? Esp. if contract sizes are big.
    /// @inheritdoc IVTSManager
    function calcVTSRequired(
        PositionId positionId
    )
        external
        onlyPositionValid(positionId)
        returns (uint256 vtsRequired0, uint256 vtsRequired1)
    {
        VTSPoolAndPositionAccountingLib._settlePositionGrowths(
            s,
            poolManager,
            positionId
        );
        return _getVTSRequired(positionId);
    }

    // TODO: Not necessary? Esp. if contract sizes are big.
    /// @inheritdoc IVTSManager
    function calcVTSCurrent(
        PositionId positionId
    )
        external
        onlyPositionValid(positionId)
        returns (uint256 vtsCurrent0, uint256 vtsCurrent1)
    {
        VTSPoolAndPositionAccountingLib._settlePositionGrowths(
            s,
            poolManager,
            positionId
        );
        return _getVTSCurrent(positionId);
    }

    /// @inheritdoc IVTSManager
    function getPositionSettledAmounts(
        PositionId positionId
    ) external view returns (uint256 amount0, uint256 amount1) {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        return (pa.settled.token0, pa.settled.token1);
    }

    /// @inheritdoc IVTSManager
    function incrementCoverage(
        PoolId poolId,
        uint256 amount0,
        uint256 amount1
    ) external onlyFactory {
        if (amount0 > 0) {
            VTSPoolAndPositionAccountingLib._incrementCoverage(
                s,
                poolManager,
                poolId,
                0,
                amount0
            );
        }
        if (amount1 > 0) {
            VTSPoolAndPositionAccountingLib._incrementCoverage(
                s,
                poolManager,
                poolId,
                1,
                amount1
            );
        }
    }

    /// @inheritdoc IVTSManager
    function getCommitment(
        PositionId positionId
    )
        external
        view
        onlyPositionValid(positionId)
        returns (uint256 commitment0, uint256 commitment1)
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        return (pa.commitmentMax.token0, pa.commitmentMax.token1);
    }

    /// @inheritdoc IVTSManager
    function applyCommitmentDeficit(
        PositionId[] calldata ids,
        uint256 totalDeficitBps
    ) external {
        if (msg.sender != mmPositionManager) revert Errors.InvalidSender();
        VTSCommitLib._applyCommitmentDeficit(
            s,
            mmPositionManager,
            ids,
            totalDeficitBps
        );
    }

    // --------------------------------------------------
    // Internal Helper Functions
    // --------------------------------------------------

    /// @notice Gets the required VTS for a position using cumulative deficits
    /// @param positionId The position ID
    /// @return vtsRequired0 The required VTS for token0 (1e18 scale)
    /// @return vtsRequired1 The required VTS for token1 (1e18 scale)
    function _getVTSRequired(
        PositionId positionId
    ) internal view returns (uint256 vtsRequired0, uint256 vtsRequired1) {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        uint256 c0 = pa.commitmentMax.token0;
        uint256 c1 = pa.commitmentMax.token1;
        uint256 d0 = pa.cumulativeDeficit.token0;
        uint256 d1 = pa.cumulativeDeficit.token1;
        uint256 one = 1e18;
        vtsRequired0 = c0 == 0
            ? 0
            : (d0 >= c0 ? one : FullMath.mulDiv(d0, one, c0));
        vtsRequired1 = c1 == 0
            ? 0
            : (d1 >= c1 ? one : FullMath.mulDiv(d1, one, c1));
    }

    /// @notice Gets the current VTS for a position
    /// @param positionId The position ID
    /// @return vtsCurrent0 The current VTS for token0
    /// @return vtsCurrent1 The current VTS for token1
    function _getVTSCurrent(
        PositionId positionId
    ) internal view returns (uint256 vtsCurrent0, uint256 vtsCurrent1) {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        uint256 c0 = pa.commitmentMax.token0;
        uint256 c1 = pa.commitmentMax.token1;
        uint256 s0 = pa.settled.token0;
        uint256 s1 = pa.settled.token1;
        uint256 one = 1e18;
        uint256 v0 = c0 > 0 ? FullMath.mulDiv(s0, one, c0) : 0;
        uint256 v1 = c1 > 0 ? FullMath.mulDiv(s1, one, c1) : 0;
        return (v0, v1);
    }
}

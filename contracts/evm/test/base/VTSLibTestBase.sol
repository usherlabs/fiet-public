// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {MarketTestBase} from "./MarketTestBase.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";

import {
    VTSStorage,
    PositionAccounting,
    PoolAccounting,
    GrowthPair,
    MarketVTSConfiguration,
    TokenConfiguration,
    TokenPairUint,
    TokenPairInt,
    TokenPairLib
} from "../../src/types/VTS.sol";
import {PositionId, Position, PositionLibrary} from "../../src/types/Position.sol";
import {Pool} from "../../src/types/Pool.sol";
import {RFSCheckpoint} from "../../src/types/Checkpoint.sol";

/// @title VTSLibTestBase
/// @notice Base test module extending MarketTestBase for isolated VTS library testing
/// @dev Provides emulated VTSStorage and leverages real PoolManager infrastructure from Deployers
abstract contract VTSLibTestBase is MarketTestBase {
    using TokenPairLib for TokenPairUint;
    using TokenPairLib for TokenPairInt;
    using StateLibrary for IPoolManager;

    // ============ Default Test Values ============

    address internal constant DEFAULT_OWNER = address(0xBEEF);
    int24 internal constant DEFAULT_TICK_LOWER = -600;
    int24 internal constant DEFAULT_TICK_UPPER = 600;
    uint128 internal constant DEFAULT_LIQUIDITY = 1000e18;
    bytes32 internal constant DEFAULT_SALT = bytes32(uint256(0));

    // Default VTS configuration
    uint256 internal constant DEFAULT_GRACE_PERIOD = 1 hours;
    uint256 internal constant DEFAULT_BASE_VTS_RATE = 500; // 5% in bps
    uint256 internal constant DEFAULT_MAX_GRACE_PERIOD = 7 days;
    uint16 internal constant DEFAULT_COVERAGE_FEE_SHARE = 1000; // 10% in bps
    uint256 internal constant DEFAULT_MIN_RESIDUAL_UNITS = 1000;

    // ============ Setup ============

    /// @notice Standard setup - deploys market infrastructure
    function setUp() public virtual {
        _setupMarket();
    }

    // ============ VTS Configuration Helpers ============

    /// @notice Creates a default VTS configuration for testing
    function _createDefaultVTSConfig() internal pure returns (MarketVTSConfiguration memory) {
        TokenConfiguration memory tokenConfig = TokenConfiguration({
            gracePeriodTime: DEFAULT_GRACE_PERIOD,
            baseVTSRate: DEFAULT_BASE_VTS_RATE,
            maxGracePeriodTime: DEFAULT_MAX_GRACE_PERIOD,
            unbackedCommitmentGraceBypassTime: 0,
            unbackedCommitmentGraceBypassThreshold: 0
        });

        return MarketVTSConfiguration({
            token0: tokenConfig,
            token1: tokenConfig,
            coverageFeeShare: DEFAULT_COVERAGE_FEE_SHARE,
            minResidualUnits: DEFAULT_MIN_RESIDUAL_UNITS,
            unbackedCommitmentGraceBypassBps: 500
        });
    }

    // ============ Position Helpers ============

    /// @notice Generates a position ID from parameters
    function _generatePositionId(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (PositionId)
    {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: 0, // Not used for ID generation
            salt: salt
        });
        return PositionLibrary.generateId(owner, params);
    }

    /// @notice Gets the default pool ID from corePoolKey
    function _getDefaultPoolId() internal view returns (PoolId) {
        return corePoolKey.toId();
    }

    /// @notice Gets position liquidity from the real PoolManager
    function _getPositionLiquidity(PoolId poolId, PositionId positionId) internal view returns (uint128) {
        return manager.getPositionLiquidity(poolId, PositionId.unwrap(positionId));
    }

    /// @notice Gets fee growth inside from the real PoolManager
    function _getFeeGrowthInside(PoolId poolId, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 feeGrowthInside0, uint256 feeGrowthInside1)
    {
        return manager.getFeeGrowthInside(poolId, tickLower, tickUpper);
    }

    /// @notice Gets slot0 data from the real PoolManager
    function _getSlot0(PoolId poolId)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return manager.getSlot0(poolId);
    }
}

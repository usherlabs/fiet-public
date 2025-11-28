// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionId} from "../types/Position.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Interface for CoreHook to interact with VTS system
interface ICoreHookVTS {
    /// @notice Accrue deficit growth for a pool/token
    function accrueDeficitGrowth(PoolId corePoolId, uint8 token, uint256 deficitAmount) external;

    /// @notice Accrue inflow growth for a pool/token
    function accrueInflowGrowth(PoolId corePoolId, uint8 token, uint256 inflowAmount) external;

    /// @notice Handle tick cross (flip outside growth)
    function onTickCross(PoolId corePoolId, int24 tick, uint8 token) external;

    /// @notice Touch/update a position (register or update)
    function touchPosition(
        address owner,
        PoolId poolId,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external;

    /// @notice Process position fees
    function processPositionFees(PositionId id, Currency currency0, Currency currency1) external returns (BalanceDelta);

    /// @notice Check if caller is MM Position Manager
    function isCallerMMP(address caller) external view returns (bool);

    /// @notice Check if position is MM position
    function isMMPosition(PositionId positionId) external view returns (bool);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LiquiditySignal} from "../types/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";

interface IVRLSignalManager {
    // Events
    event VerifierChanged(address indexed oldVerifier, address indexed newVerifier);

    // Errors
    error InvalidProof();
    error InvalidDelta(int128 amount0, int128 amount1);
    error InvalidNonce(uint256 newNonce, uint256 prevNonce);
    error InvalidLiquiditySignalEncoding();
    error InvalidLiquiditySignal();
    error InsufficientLiquidityInSignal(uint256 totalSignalUsdValue, uint256 totalLCCValue);

    // View functions
    function verifier() external view returns (address);

    function oracleRegistry() external view returns (address);

    function getTotalUsdValue(string[] memory tickers, uint256[] memory amounts) external view returns (uint256);

    // External functions
    function setVerifier(address _newVerifier) external;

    function checkSignalSolvency(
        PoolKey calldata poolKey,
        bytes memory liquiditySignal,
        ModifyLiquidityParams memory liquidityParams
    ) external returns (uint256, uint256, uint256);

    function verifyLiquiditySignalSolvency(
        PoolKey calldata poolKey,
        bytes memory liquiditySignal,
        ModifyLiquidityParams memory liquidityParams
    ) external returns (uint256, uint256, uint256);

    function verifySettlementProof(bytes memory settlementSignal) external returns (uint256 gracePeriodExtension);

    function renewLiquiditySignal(bytes memory liquiditySignal) external returns (uint256, uint256);
}

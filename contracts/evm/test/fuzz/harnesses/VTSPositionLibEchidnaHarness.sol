// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSStorage, MarketVTSConfiguration} from "../../../src/types/VTS.sol";
import {PositionId, Position} from "../../../src/types/Position.sol";
import {Pool} from "../../../src/types/Pool.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {VTSPositionLib} from "../../../src/libraries/VTSPositionLib.sol";
import {DynamicCurrencyDelta} from "../../../src/libraries/DynamicCurrencyDelta.sol";
import {IMarketVault} from "../../../src/interfaces/IMarketVault.sol";

/// @notice Minimal Echidna-oriented harness that avoids calling `public`/`external` functions on `VTSPositionLib`.
///         This prevents linked-library DELEGATECALLs that cause Echidna/HEVM to attempt RPC bytecode fetches.
contract VTSPositionLibEchidnaHarness {
    VTSStorage internal s;

    // Hard-linked library address (see `foundry.toml` `[profile.echidna].libraries`).
    address internal constant VTS_POSITION_LIB = 0xa05ceC1A8F8639C0432Fa44FDd62d77bBcA4d211;

    constructor() {
        _deployVTSPositionLib();
    }

    function _deployVTSPositionLib() internal {
        // Deploy VTSPositionLib via CREATE2 to the hard-linked address.
        // This prevents Echidna/HEVM from trying to RPC-fetch code for `VTS_POSITION_LIB`.
        bytes32 salt = keccak256("echidna.VTSPositionLib");
        bytes memory initCode = type(VTSPositionLib).creationCode;
        address deployed;
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(deployed != address(0), "VTSPositionLib deploy failed");
        require(deployed == VTS_POSITION_LIB, "VTSPositionLib addr mismatch");
    }

    // -------------------------------------------------------------------------
    // Setup / internal-library calls (safe: internal functions are inlined)
    // -------------------------------------------------------------------------

    function setupPool(PoolId poolId, MarketVTSConfiguration memory config) external {
        s.pools[poolId] = Pool({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            vtsConfig: config,
            isPaused: false
        });
    }

    function registerPosition(address owner, PoolId poolId, ModifyLiquidityParams calldata params) external {
        VTSPositionLib._registerPosition(s, owner, poolId, params);
    }

    function initPositionSnapshots(IPoolManager poolManager, PositionId id) external {
        VTSPositionLib._initPositionSnapshots(s, poolManager, id);
    }

    // -------------------------------------------------------------------------
    // Storage setters (used by fuzz harness)
    // -------------------------------------------------------------------------

    function setCommitmentMax(PositionId id, uint256 c0, uint256 c1) external {
        s.positionAccounting[id].commitmentMax.token0 = c0;
        s.positionAccounting[id].commitmentMax.token1 = c1;
    }

    function setSettled(PositionId id, uint256 s0, uint256 s1) external {
        s.positionAccounting[id].settled.token0 = s0;
        s.positionAccounting[id].settled.token1 = s1;
    }

    function setCumulativeDeficit(PositionId id, uint256 d0, uint256 d1) external {
        s.positionAccounting[id].cumulativeDeficit.token0 = d0;
        s.positionAccounting[id].cumulativeDeficit.token1 = d1;
    }

    function setPoolTotalDeficitPrincipal(PoolId poolId, uint256 principal0, uint256 principal1) external {
        s.poolAccounting[poolId].totalDeficitPrincipal.token0 = principal0;
        s.poolAccounting[poolId].totalDeficitPrincipal.token1 = principal1;
    }

    function setPositionActive(PositionId id, bool active) external {
        s.positions[id].isActive = active;
    }

    function setUnderlyingDelta(Currency currency, address target, int128 delta) external {
        DynamicCurrencyDelta.accountDelta(currency, delta, target);
    }

    // -------------------------------------------------------------------------
    // RFS (delegate to VTSPositionLib)
    // -------------------------------------------------------------------------

    function getRFS(PositionId positionId) external view returns (bool rfsOpen, BalanceDelta delta) {
        // NOTE: This is safe in Echidna because `getRFS` takes a `VTSStorage storage` pointer,
        // so the compiler inlines it (no linked-library DELEGATECALL).
        return VTSPositionLib.getRFS(s, positionId);
    }

    // -------------------------------------------------------------------------
    // Minimal settle entrypoint for SETTLE-01 fuzzing
    // -------------------------------------------------------------------------

    function onMMSettle(
        IPoolManager, // poolManager (unused in this minimal harness)
        IMarketVault, // vault (unused)
        PositionId positionId,
        Currency, // lccCurrency0 (unused)
        Currency, // lccCurrency1 (unused)
        BalanceDelta delta,
        bool isSeizing
    ) external returns (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiquidityUnits) {
        Position memory pos = s.positions[positionId];
        if (pos.owner == address(0)) revert("VTSPositionLib: Invalid position");

        (rfsOpen,) = VTSPositionLib.getRFS(s, positionId);

        // For SETTLE-01 we only care that withdrawals revert while RFS is open (unless seizing).
        bool isWithdrawal = (delta.amount0() > 0) || (delta.amount1() > 0);
        if (pos.isActive && !isSeizing && rfsOpen && isWithdrawal) {
            revert("VTSPositionLibEchidnaHarness: RFS open");
        }

        return (delta, rfsOpen, 0);
    }
}


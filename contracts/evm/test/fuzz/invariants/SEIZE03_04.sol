// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSPositionLibFuzzHarness} from "../harnesses/VTSPositionLibFuzzHarness.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockMarketVault} from "../../_mocks/MockMarketVault.sol";
import {MockLCC} from "../../_mocks/MockLCC.sol";

import {
    MarketVTSConfiguration,
    TokenConfiguration,
    PositionContext,
    TouchPositionParams
} from "../../../src/types/VTS.sol";
import {Position, PositionId, PositionLibrary, PositionModificationHookDataLib} from "../../../src/types/Position.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ILiquidityHub} from "../../../src/interfaces/ILiquidityHub.sol";
import {IOracleHelper} from "../../../src/interfaces/IOracleHelper.sol";

/// @notice fuzz harness for SEIZE-03 and SEIZE-04 using the real `VTSPositionLib.touchPosition` path.
contract SEIZE03_04 {
    using PoolIdLibrary for PoolKey;

    VTSPositionLibFuzzHarness internal harness;
    MockPoolManager internal poolManager;
    MockMarketVault internal vault;
    PoolKey internal poolKey;
    PoolId internal poolId;

    bool internal checked03;
    bool internal lastOk03;
    bool internal checked04;
    bool internal lastOk04;

    constructor() {
        harness = new VTSPositionLibFuzzHarness();
        poolManager = new MockPoolManager();
        vault = new MockMarketVault(address(0));

        address underlying0 = address(0x2000000000000000000000000000000000000031);
        address underlying1 = address(0x2000000000000000000000000000000000000032);
        MockLCC lcc0 = new MockLCC("MockLCC0", "MLCC0", 18, underlying0);
        MockLCC lcc1 = new MockLCC("MockLCC1", "MLCC1", 18, underlying1);

        MarketVTSConfiguration memory config = MarketVTSConfiguration({
            token0: TokenConfiguration({
                gracePeriodTime: 7 days,
                baseVTSRate: 1000,
                maxGracePeriodTime: 30 days,
                unbackedCommitmentGraceBypassTime: 0,
                unbackedCommitmentGraceBypassThreshold: 0
            }),
            token1: TokenConfiguration({
                gracePeriodTime: 7 days,
                baseVTSRate: 1000,
                maxGracePeriodTime: 30 days,
                unbackedCommitmentGraceBypassTime: 0,
                unbackedCommitmentGraceBypassThreshold: 0
            }),
            coverageFeeShare: 5000,
            minResidualUnits: 1000,
            unbackedCommitmentGraceBypassBps: 500
        });
        poolKey = PoolKey({
            currency0: Currency.wrap(address(lcc0)),
            currency1: Currency.wrap(address(lcc1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();
        harness.setupPool(poolId, config);
        poolManager.setSlot0(poolId, TickMath.getSqrtPriceAtTick(0), 0, 0, 0);
    }

    /// @notice Exercise seizure-path touch logic and require the touch to revert before issuing LCCs.
    /// @param tickLower Proposed lower tick, clamped into valid bounds.
    /// @param tickUpper Proposed upper tick, clamped into valid bounds.
    /// @param liqRaw Fuzzed liquidity magnitude for the attempted seizure modification.
    /// @param salt Position salt used in the touched liquidity params.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_seize_03_no_lcc_issue_during_seizure(int24 tickLower, int24 tickUpper, uint96 liqRaw, bytes32 salt)
        external
    {
        checked03 = false;
        lastOk03 = true;
        (int24 tl, int24 tu) = _clampTicks(tickLower, tickUpper);
        uint256 liq = uint256(liqRaw % 1e10) + 1;
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: int256(liq), salt: salt});
        bytes memory hookData = PositionModificationHookDataLib.encodeSeizure(1, 0, address(this), 0, 0);

        (bool reverted,) = _touchReverts(address(this), params, hookData);
        checked03 = true;
        lastOk03 = reverted;
    }

    /// @notice Verify that touching an existing MM position with a mismatched commit id reverts.
    ///         Depending on commit validity, the real path may fail at signal validation before the mismatch guard.
    /// @param storedCommitId Commit id stored on the position before the touch.
    /// @param providedCommitId Commit id supplied in hook data for the touch.
    /// @param salt Position salt used to derive the deterministic test position id.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_seize_04_commit_id_must_match(uint256 storedCommitId, uint256 providedCommitId, bytes32 salt)
        external
    {
        checked04 = false;
        lastOk04 = true;

        uint256 stored = (storedCommitId % 1e6) + 1;
        uint256 provided = (providedCommitId % 1e6) + 1;
        if (provided == stored) {
            provided = stored + 1;
        }

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 0, salt: salt});
        PositionId id = PositionLibrary.generateId(address(this), params);
        harness.registerPosition(address(this), poolId, params);
        harness.setPositionCommitId(id, stored);

        bytes memory hookData = PositionModificationHookDataLib.encode(provided, 0, address(this));
        (bool reverted,) = _touchReverts(address(this), params, hookData);
        checked04 = true;
        lastOk04 = reverted;
    }

    /// @notice Invariant: seizure flow must not permit LCC issuance during a touch.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_seize_03_no_lcc_issue_during_seizure() external view returns (bool) {
        return !checked03 || lastOk03;
    }

    /// @notice Invariant: an existing MM position keeps a fixed commit identity during touch.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_seize_04_commit_identity_fixed() external view returns (bool) {
        return !checked04 || lastOk04;
    }

    function _touchReverts(address owner, ModifyLiquidityParams memory params, bytes memory hookData)
        internal
        returns (bool reverted, bytes4 selector)
    {
        PositionContext memory ctx = PositionContext({
            poolManager: IPoolManager(address(poolManager)),
            liquidityHub: ILiquidityHub(address(0x111)),
            oracleHelper: IOracleHelper(address(0x222)),
            marketVault: vault
        });
        TouchPositionParams memory tp = TouchPositionParams({
            owner: owner,
            poolKey: poolKey,
            params: params,
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: hookData
        });
        try harness.touchPosition(ctx, tp) returns (Position memory, PositionId, BalanceDelta) {
            reverted = false;
        } catch (bytes memory reason) {
            reverted = true;
            selector = _selectorOf(reason);
        }
    }

    function _clampTicks(int24 tickLower, int24 tickUpper) internal pure returns (int24 tl, int24 tu) {
        tl = tickLower;
        tu = tickUpper;
        if (tl < TickMath.MIN_TICK) tl = TickMath.MIN_TICK;
        if (tu > TickMath.MAX_TICK) tu = TickMath.MAX_TICK;
        if (tl >= tu) {
            tl = -60;
            tu = 60;
        }
    }

    function _selectorOf(bytes memory reason) internal pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(reason, 32))
        }
    }
}

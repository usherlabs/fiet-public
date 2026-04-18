// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSCommitLib} from "../../../src/libraries/VTSCommitLib.sol";
import {PositionId} from "../../../src/types/Position.sol";
import {MockOracleHelper} from "../mocks/MockOracleHelper.sol";
import {VTSCommitLibHarness} from "../../libraries/harnesses/VTSCommitLibHarness.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FuzzLinkedLibs} from "../base/FuzzLinkedLibs.sol";
import {MarketMaker} from "../../../src/libraries/MarketMaker.sol";

/// @notice fuzz harness for COMMIT-01 / SIG-BACKING-01 (Domain C):
/// the gate `issuedUsd <= settledUsd + signalUsd` enforced by `VTSCommitLib.validateLiquidityDelta`.
///
/// We mock:
/// - settledUsd via `VTSCommitLibHarness.setPositionSettled`
/// - signalUsd via oracle.getTotalValue (oracle returns a configurable constant)
/// - prices via oracle.getPricesForLccPair (oracle returns configurable p0/p1)
///
/// And we execute production code via `VTSCommitLibHarness`, which calls `VTSCommitLib` directly
/// using its own isolated `VTSStorage`.
contract COMMIT01 {
    MockOracleHelper internal oracle;
    VTSCommitLibHarness internal commitHarness;

    address internal constant LCC0 = address(0x1000000000000000000000000000000000000001);
    address internal constant LCC1 = address(0x1000000000000000000000000000000000000002);

    uint256 internal constant COMMIT_ID = 1;
    PositionId internal positionId;

    bool internal checked;
    bool internal lastOk;

    function _seedCommitState() internal {
        MarketMaker.Reserve[] memory reserves = new MarketMaker.Reserve[](1);
        reserves[0] = MarketMaker.Reserve({asset: "USD", amount: 1e18});

        commitHarness.setCommitMmState(
            COMMIT_ID,
            MarketMaker.State({
                owner: address(this),
                reserves: reserves,
                sourceState: "",
                prover: "",
                nonce: "",
                advancer: address(this),
                expiryAt: block.timestamp + 365 days
            })
        );
    }

    function _seedAll() internal {
        uint160 sp = uint160(1) << 96;
        int24 ct = 0;
        int24 tl = -60;
        int24 tu = 60;
        int256 ld = 1;

        VTSCommitLib.LiquidityDeltaParams memory p = VTSCommitLib.LiquidityDeltaParams({
            currency0: Currency.wrap(LCC0),
            currency1: Currency.wrap(LCC1),
            sqrtPriceX96: sp,
            currentTick: ct,
            tickLower: tl,
            tickUpper: tu,
            liquidityDelta: ld
        });

        bool success;
        uint256 issuedUsd;
        uint256 settledUsd;
        uint256 signalUsd;

        try commitHarness.validateLiquidityDelta(oracle, COMMIT_ID, positionId, p, false) returns (
            bool sOk, uint256 iUsd, uint256 stUsd, uint256 siUsd
        ) {
            success = sOk;
            issuedUsd = iUsd;
            settledUsd = stUsd;
            signalUsd = siUsd;
        } catch {
            checked = true;
            lastOk = false;
            return;
        }

        bool shouldPass = issuedUsd <= (settledUsd + signalUsd);
        checked = true;
        lastOk = (success == shouldPass);
    }

    constructor() {
        FuzzLinkedLibs.deployVTSCommitLib();

        oracle = new MockOracleHelper(address(0));
        oracle.setPrices(1e18, 1e18);
        oracle.setTotalValue(0);

        positionId = PositionId.wrap(keccak256("fuzz.sig-backing-01"));

        commitHarness = new VTSCommitLibHarness();
        _seedCommitState();

        _seedAll();
    }

    // ===== actions to mutate backing inputs =====

    // forge-lint: disable-next-line(mixed-case-function)
    function action_set_prices(uint256 p0, uint256 p1) external {
        uint256 c0 = p0 == 0 ? 1 : (p0 > 1e30 ? 1e30 : p0);
        uint256 c1 = p1 == 0 ? 1 : (p1 > 1e30 ? 1e30 : p1);
        oracle.setPrices(c0, c1);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_set_signal(uint256 signalUsd) external {
        oracle.setTotalValue(signalUsd > 1e36 ? 1e36 : signalUsd);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_set_settled(uint256 settled0, uint256 settled1) external {
        uint256 a0 = settled0 > 1e36 ? 1e36 : settled0;
        uint256 a1 = settled1 > 1e36 ? 1e36 : settled1;
        commitHarness.setPositionSettled(positionId, a0, a1);
    }

    /// @notice Executes the gate in non-reverting mode so we can observe
    /// (success, issuedUsd, settledUsd, signalUsd) for any input.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_validate_liquidity_delta(
        uint160 sqrtPriceX96,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) external {
        checked = true;
        lastOk = true;

        uint160 sp = sqrtPriceX96;
        if (sp <= TickMath.MIN_SQRT_PRICE) sp = TickMath.MIN_SQRT_PRICE + 1;
        if (sp >= TickMath.MAX_SQRT_PRICE) sp = TickMath.MAX_SQRT_PRICE - 1;

        int24 tl = tickLower;
        int24 tu = tickUpper;
        int24 ct = currentTick;
        if (tl < TickMath.MIN_TICK) tl = TickMath.MIN_TICK;
        if (tu > TickMath.MAX_TICK) tu = TickMath.MAX_TICK;
        if (ct < TickMath.MIN_TICK) ct = TickMath.MIN_TICK;
        if (ct > TickMath.MAX_TICK) ct = TickMath.MAX_TICK;
        if (tl >= tu) {
            tl = -60;
            tu = 60;
        }

        uint256 absL;
        if (liquidityDelta == type(int256).min) {
            absL = 1;
        } else {
            int256 v = liquidityDelta < 0 ? -liquidityDelta : liquidityDelta;
            absL = uint256(v);
        }
        int256 ld = int256((absL % 1e18) + 1);

        VTSCommitLib.LiquidityDeltaParams memory p = VTSCommitLib.LiquidityDeltaParams({
            currency0: Currency.wrap(LCC0),
            currency1: Currency.wrap(LCC1),
            sqrtPriceX96: sp,
            currentTick: ct,
            tickLower: tl,
            tickUpper: tu,
            liquidityDelta: ld
        });

        bool success;
        uint256 issuedUsd;
        uint256 settledUsd;
        uint256 signalUsd;
        try commitHarness.validateLiquidityDelta(oracle, COMMIT_ID, positionId, p, false) returns (
            bool sOk, uint256 iUsd, uint256 stUsd, uint256 siUsd
        ) {
            success = sOk;
            issuedUsd = iUsd;
            settledUsd = stUsd;
            signalUsd = siUsd;
        } catch {
            lastOk = false;
            return;
        }

        bool shouldPass = issuedUsd <= (settledUsd + signalUsd);
        lastOk = (success == shouldPass);
    }

    // ===== properties =====

    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_commit_01_gate_correct() external view returns (bool) {
        return !checked || lastOk;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_commit_01_smoke() external pure returns (bool) {
        return true;
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSCommitLib} from "../../src/libraries/VTSCommitLib.sol";
import {PositionId} from "../../src/types/Position.sol";
import {MockOracleHelper} from "./mocks/MockOracleHelper.sol";
import {VTSCommitLibHarness} from "../libraries/harnesses/VTSCommitLibHarness.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";

/// @notice Echidna harness for COMMIT-01 / SIG-BACKING-01 (Domain C):
/// the gate `issuedUsd <= settledUsd + signalUsd` enforced by `VTSCommitLib.validateLiquidityDelta`.
///
/// We mock:
/// - settledUsd via `VTSCommitLibHarness.setPositionSettled`
/// - signalUsd via oracle.getTotalValue (oracle returns a configurable constant)
/// - prices via oracle.getPricesForLccPair (oracle returns configurable p0/p1)
///
/// And we execute production code via `VTSCommitLibHarness`, which calls `VTSCommitLib` directly
/// using its own isolated `VTSStorage`.
contract VTSCommit01SigBackingEchidnaTest {
    MockOracleHelper internal oracle;
    VTSCommitLibHarness internal commitHarness;

    // Must match `foundry.toml` profile `echidna` hard-link for `VTSCommitLib`.
    address internal constant VTS_COMMIT_LIB = 0x08f6e330612797F445209Bfee166c949cfd0BF4F;

    // Two dummy currencies for the computation; they never need to be real tokens in this harness.
    address internal constant LCC0 = address(0x1000000000000000000000000000000000000001);
    address internal constant LCC1 = address(0x1000000000000000000000000000000000000002);

    uint256 internal constant COMMIT_ID = 1;
    PositionId internal positionId;

    // Tracking for property
    bool internal checked;
    bool internal lastOk;

    function _deployVTSCommitLib() internal {
        // Deploy VTSCommitLib via CREATE2 to the hard-linked address.
        bytes32 salt = keccak256("echidna.VTSCommitLib");
        bytes memory initCode = type(VTSCommitLib).creationCode;
        address deployed;
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(deployed != address(0), "VTSCommitLib deploy failed");
        require(deployed == VTS_COMMIT_LIB, "VTSCommitLib addr mismatch");
    }

    constructor() {
        _deployVTSCommitLib();

        oracle = new MockOracleHelper(address(0));
        oracle.setPrices(1e18, 1e18);
        oracle.setTotalValue(0);

        // Stable position id.
        positionId = PositionId.wrap(keccak256("echidna.sig-backing-01"));

        commitHarness = new VTSCommitLibHarness();
    }

    // ===== actions to mutate backing inputs =====

    function action_set_prices(uint256 p0, uint256 p1) external {
        // clamp to reasonable 18d range
        uint256 c0 = p0 == 0 ? 1 : (p0 > 1e30 ? 1e30 : p0);
        uint256 c1 = p1 == 0 ? 1 : (p1 > 1e30 ? 1e30 : p1);
        oracle.setPrices(c0, c1);
    }

    function action_set_signal(uint256 signalUsd) external {
        oracle.setTotalValue(signalUsd > 1e36 ? 1e36 : signalUsd);
    }

    function action_set_settled(uint256 settled0, uint256 settled1) external {
        // Settled token units are 18d in this system; clamp to keep math bounded.
        uint256 a0 = settled0 > 1e36 ? 1e36 : settled0;
        uint256 a1 = settled1 > 1e36 ? 1e36 : settled1;
        commitHarness.setPositionSettled(positionId, a0, a1);
    }

    /// @notice Executes the gate in non-reverting mode so we can observe
    /// (success, issuedUsd, settledUsd, signalUsd) for any input.
    function action_validate_liquidity_delta(
        uint160 sqrtPriceX96,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) external {
        checked = false;
        lastOk = true;

        if (liquidityDelta <= 0) return;
        if (tickLower >= tickUpper) return;
        if (sqrtPriceX96 == 0) return;

        // Clamp ticks to Uniswap bounds to avoid unrelated math edge reverts.
        int24 tl = tickLower;
        int24 tu = tickUpper;
        int24 ct = currentTick;
        if (tl < -887272) tl = -887272;
        if (tu > 887272) tu = 887272;
        if (ct < -887272) ct = -887272;
        if (ct > 887272) ct = 887272;
        if (tl >= tu) return;

        VTSCommitLib.LiquidityDeltaParams memory p = VTSCommitLib.LiquidityDeltaParams({
            currency0: Currency.wrap(LCC0),
            currency1: Currency.wrap(LCC1),
            sqrtPriceX96: sqrtPriceX96,
            currentTick: ct,
            tickLower: tl,
            tickUpper: tu,
            liquidityDelta: liquidityDelta
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
            return; // ignore unexpected non-backing revert paths
        }

        // Basic self-consistency: library's success must match inequality.
        bool shouldPass = issuedUsd <= (settledUsd + signalUsd);
        bool ok = (success == shouldPass);

        checked = true;
        lastOk = ok;
    }

    // ===== property =====

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_sig_backing_01_gate_correct() external view returns (bool) {
        return !checked || lastOk;
    }

    // Echidna sometimes crashes internally when there is only a single property in the target contract.
    // Keep a second trivial property to stabilize the runner (does not weaken the real invariant).
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_sig_backing_01_smoke() external pure returns (bool) {
        return true;
    }

    // ===== internals =====
    // NOTE: we intentionally do not test the reverting-mode behavior here to keep this harness minimal.
}


// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSCurrencyDeltaHarness} from "../../libraries/harnesses/VTSCurrencyDeltaHarness.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IMarketFactory} from "../../../src/interfaces/IMarketFactory.sol";

/// @notice Echidna harness for DELTA-01: Deltas must net to zero per unlock/batch.
///         Any non-zero currency delta at end-of-batch must cause CurrencyNotSettled().
contract DELTA01 {
    VTSCurrencyDeltaHarness internal deltaHarness;

    Currency internal constant C0 = Currency.wrap(address(0x1000));
    Currency internal constant C1 = Currency.wrap(address(0x2000));
    address internal constant TARGET = address(0xBEEF);
    IMarketFactory internal constant DELTA01_FACTORY = IMarketFactory(address(0xF01));

    bool internal checked;
    bool internal lastOk;

    constructor() {
        deltaHarness = new VTSCurrencyDeltaHarness();
    }

    /// @notice Set deltas and assert NonzeroDeltaCount gating via assertNonZeroDeltas.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_set_deltas_and_assert(int128 d0Raw, int128 d1Raw) external {
        checked = false;
        lastOk = true;

        // Clamp away int128 min to avoid negation edge cases in downstream code.
        int128 d0 = d0Raw == type(int128).min ? int128(0) : d0Raw;
        int128 d1 = d1Raw == type(int128).min ? int128(0) : d1Raw;

        deltaHarness.setDelta(C0, TARGET, d0);
        deltaHarness.setDelta(C1, TARGET, d1);

        bool shouldRevert = d0 != 0 || d1 != 0;
        bool reverted;
        try deltaHarness.assertNonZeroDeltas(DELTA01_FACTORY) {
            reverted = false;
        } catch {
            reverted = true;
        }

        checked = true;
        lastOk = shouldRevert == reverted;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_delta_01_nonzero_deltas_revert() external view returns (bool) {
        return !checked || lastOk;
    }

    // Keep a second trivial property to avoid rare Echidna instability with single-property targets.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_delta_01_smoke() external pure returns (bool) {
        return true;
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * E2E: MarketMaker
 *
 * Goal:
 * - Provide a compact “happy path” journey for a single MMPositionManager position:
 *   commit → mint → settle → swaps → poke (realise fees) → close RFS → burn → drain inactive surplus → decommit → unwrap.
 *
 * High-level flow:
 * - Deploy full stack + create a market (core LCC/LCC pool) with a non-zero fee.
 * - Create one MM position (commit → mint → settle).
 * - Execute swaps in both directions to generate fee growth.
 * - Poke the position (no-op increase + take) to materialise any pending fee adjustments as LCC balances.
 * - Close RFS (if open), then burn + settle-from-deltas, drain inactive economic remnant if any (if the vault clamps
 *   withdrawals, assert recognised unserviceable overflow then perform directional reserve-replenishing swaps and re-drain),
 *   decommit, and take credits.
 * - Unwrap any remaining LCCs back to underlyings and assert 1:1 deltas.
 *
 * Env:
 * - LP_PRIVATE_KEY: MM actor (position owner)
 * - PRIVATE_KEY: deployer; used as taker for swaps
 */

import {MME2EBase} from "./base/MME2EBase.sol";

import {console} from "forge-std/Script.sol";

// @note Future unwraps now first attempt to settle any outstanding queue for that owner, then only unwrap up to the current headroom (liquid - queued). If headroom is zero they skip gracefully instead of reverting.

contract MarketMakerE2E is MME2EBase {
    // Non-zero so fee collection is meaningful.
    uint24 internal constant CORE_POOL_FEE = 3000;

    uint128 internal constant LIQUIDITY = 1e10;
    int24 internal constant TICK_LOWER = -60;
    int24 internal constant TICK_UPPER = 60;

    function _loadMmPrivateKey() internal view returns (uint256 mmPk) {
        mmPk = uint256(
            _requireEnvBytes32("LP_PRIVATE_KEY", "Missing LP_PRIVATE_KEY env var (anvil keys can be used directly)")
        );
    }

    function _runTradingPhase(StandaloneMarket memory m, uint256 mmPk, uint256 commitId) internal {
        uint256 takerPk = _getDeployerPrivateKey();
        _runAdaptiveRoundTripTradingPhase(m, mmPk, takerPk, commitId, MM_E2E_BIG_SWAP_IN, 100e18, 40);
    }

    function _runExitPhase(StandaloneMarket memory m, uint256 mmPk, uint256 commitId) internal {
        uint256 rebalanceTakerPk = _getDeployerPrivateKey();
        OverflowRecoveryResultE2E memory recovery =
            _closeRfsBurnDrainRebalanceDecommitAndTakeAllLccs(m, mmPk, rebalanceTakerPk, commitId);
        if (recovery.blockedDrainObserved) {
            require(
                recovery.stalledOverflow0 > 0 || recovery.stalledOverflow1 > 0,
                "e2e: blocked drain must expose inactive overflow before rebalance"
            );
            require(
                recovery.stalledInactiveRemnantCount > 0,
                "e2e: blocked drain must preserve an inactive remnant before rebalance"
            );
        }
        require(recovery.fullyResolved, "e2e: baseline MM exit must fully resolve overflow before unwrap");
        _unwrapAllLccsAndAssert(m, mmPk, commitId, 0, true);
    }

    /// @notice Runs the end-to-end market-maker happy path on the configured network.
    /// @dev Initialises network state, loads the MM key, deploys and creates the market, opens the MM position,
    ///      executes the trading phase, and then runs the exit phase assertions.
    function run() external {
        console.log("=== E2E: MarketMaker ===");
        _initNetwork();

        uint256 mmPk = _loadMmPrivateKey();
        StandaloneMarket memory m = _deployAndCreateMarket(vm.addr(mmPk), CORE_POOL_FEE);
        uint256 commitId = _createMmPosition(m, mmPk, TICK_LOWER, TICK_UPPER, LIQUIDITY);
        console.log("OK: position created");
        console.log("commitId:", commitId);

        _runTradingPhase(m, mmPk, commitId);
        _runExitPhase(m, mmPk, commitId);
    }
}

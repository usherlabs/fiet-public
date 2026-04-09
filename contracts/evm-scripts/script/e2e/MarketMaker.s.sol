// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * E2E: MarketMaker
 *
 * Goal:
 * - Provide a compact “happy path” journey for a single MMPositionManager position:
 *   commit → mint → settle → swaps → poke (realise fees) → close RFS → burn/decommit → unwrap.
 *
 * High-level flow:
 * - Deploy full stack + create a market (core LCC/LCC pool) with a non-zero fee.
 * - Create one MM position (commit → mint → settle).
 * - Execute swaps in both directions to generate fee growth.
 * - Poke the position (no-op increase + take) to materialise any pending fee adjustments as LCC balances.
 * - Close RFS (if open), then burn + settle-from-deltas + decommit, and take any remaining credits.
 * - Unwrap any remaining LCCs back to underlyings and assert 1:1 deltas.
 *
 * Env:
 * - LP_PRIVATE_KEY: MM actor (position owner)
 * - PRIVATE_KEY: deployer; used as taker for swaps
 */

import {MME2EBase} from "./base/MME2EBase.sol";

import {console} from "forge-std/Script.sol";

contract MarketMakerE2E is MME2EBase {
    // Non-zero so fee collection is meaningful.
    uint24 internal constant CORE_POOL_FEE = 3000;

    uint128 internal constant LIQUIDITY = 1e10;
    int24 internal constant TICK_LOWER = -60;
    int24 internal constant TICK_UPPER = 60;

    uint256 internal constant WRAP_FOR_SWAPS = 50_000e18;
    uint128 internal constant BIG_SWAP_AMOUNT_IN = 5_000e18;

    function _loadMmPrivateKey() internal view returns (uint256 mmPk) {
        mmPk = uint256(
            _requireEnvBytes32("LP_PRIVATE_KEY", "Missing LP_PRIVATE_KEY env var (anvil keys can be used directly)")
        );
    }

    function _runTradingPhase(StandaloneMarket memory m, uint256 mmPk, uint256 commitId) internal {
        uint256 takerPk = _getDeployerPrivateKey();
        _swapBothDirections(m, takerPk, WRAP_FOR_SWAPS, BIG_SWAP_AMOUNT_IN);
        _pokePosition(m, mmPk, commitId);
    }

    function _runExitPhase(StandaloneMarket memory m, uint256 mmPk, uint256 commitId) internal {
        _closeRfsBurnDecommitAndTakeAllLccs(m, mmPk, commitId);
        _unwrapAllLccsAndAssert(m, mmPk, 0, true);
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

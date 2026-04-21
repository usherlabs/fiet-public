// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * E2E: MM asymmetric overflow cure
 *
 * Goal:
 * - Stress one MM position into a token0-only inactive remnant.
 * - Realise the serviceable token1 side on burn.
 * - Seed exogenous full-range DirectLP liquidity only after the remnant is recognised.
 * - Rebalance with `0 -> 1` against that post-burn external liquidity.
 * - Re-drain the remaining token0 remnant, then decommit and unwrap successfully.
 */

import {console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MME2EBase} from "./base/MME2EBase.sol";
import {IVTSOrchestrator} from "src/interfaces/IVTSOrchestrator.sol";

contract MarketMakerAsymmetricOverflowCureE2E is MME2EBase {
    uint24 internal constant CORE_POOL_FEE = 3000;

    function _loadMmPrivateKey() internal view returns (uint256 mmPk) {
        mmPk = uint256(
            _requireEnvBytes32("LP_PRIVATE_KEY", "Missing LP_PRIVATE_KEY env var (anvil keys can be used directly)")
        );
    }

    function _runDirectionalStress(StandaloneMarket memory m, uint256 mmPk, uint256 commitId, uint256 takerPk)
        internal
    {
        // Reverse the legacy extreme sweep so the stressed MM realises token1 on burn while token0 remains stranded.
        _mintAndSwap(m, takerPk, MM_E2E_WRAP_FOR_SWAPS_LARGE, false, MM_E2E_BIG_SWAP_IN);
        _mintAndSwap(m, takerPk, MM_E2E_WRAP_FOR_SWAPS_LARGE, true, MM_E2E_BIG_SWAP_IN);
        _pokePosition(m, mmPk, commitId, false);
    }

    function _burnIntoRecognisedToken0Remnant(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        address mm
    ) internal returns (uint256 token1WithdrawnOnBurn) {
        uint256 token1BeforeBurn = IERC20(m.underlying1).balanceOf(mm);

        _settleRfsIfOpen(m, mmPk, commitId);
        _burnAndRealiseExitCredits(m, mmPk, commitId, 0);

        ExitSnapshotE2E memory burned = _snapshotExitState(m, commitId, 0);
        token1WithdrawnOnBurn = IERC20(m.underlying1).balanceOf(mm) - token1BeforeBurn;
        _logMakerHealth("after burn (pre-asymmetric cure)", _snapshotMakerHealth(m, commitId, 0));
        require(burned.eff0 > 0, "e2e: expected token0 remnant after directional sweep");
        require(burned.eff1 == 0, "e2e: expected token1 lane to be fully withdrawn before cure");
        require(token1WithdrawnOnBurn > 0, "e2e: expected burn to realise the serviceable token1 side");
        console.log("e2e: token1 withdrawn on burn:", token1WithdrawnOnBurn);

        _assertRecognisedUnserviceableOverflowBeforeRebalance(m, mmPk, commitId, 0);
    }

    function _runAsymmetricOverflowCure(StandaloneMarket memory m, uint256 mmPk, uint256 commitId, uint256 takerPk)
        internal
    {
        uint256 bufferTokenId = _addCoreLiquidityFullRange(
            m, takerPk, MM_E2E_BUFFER_WRAP_PER_ASSET, MM_E2E_BUFFER_AMOUNT_MAX_PER_ASSET
        );
        console.log("e2e: seeded rebalance buffer tokenId:", bufferTokenId);

        bool drained;
        for (uint256 r = 0; r < MM_E2E_REBALANCE_MAX_ROUNDS; r++) {
            (uint256 eff0, uint256 eff1) =
                _getEffectiveSettledPair(IVTSOrchestrator(m.stack.contracts.vtsOrchestrator), commitId, 0);
            if (eff0 == 0 && eff1 == 0) {
                drained = true;
                break;
            }

            console.log("e2e: asymmetric rebalance round:", r);
            _rebalanceStrandedLanesForInactiveDrain(
                m, takerPk, eff0, eff1, MM_E2E_REBALANCE_SWAP_CHUNK, MM_E2E_REBALANCE_WRAP_PER_LEG
            );
            _logMakerHealth("after asymmetric reserve rebalance", _snapshotMakerHealth(m, commitId, 0));

            drained = _drainInactivePositionSurplusBestEffort(m, mmPk, commitId, 0, 32);
            if (drained) break;
        }

        require(drained, "e2e: asymmetric overflow cure failed to restore token0 serviceability");
        _assertInactiveSurplusFullyResolvedForDecommit(m, commitId, 0);
    }

    function run() external {
        console.log("=== E2E: MM Asymmetric overflow cure ===");
        _initNetwork();

        uint256 mmPk = _loadMmPrivateKey();
        uint256 takerPk = _getDeployerPrivateKey();
        address mm = vm.addr(mmPk);

        StandaloneMarket memory m = _deployAndCreateMarket(mm, CORE_POOL_FEE);
        uint256 commitId = _createMmPositionFromProfile(m, mmPk, _mmPositionProfilesAll()[0]);
        _runDirectionalStress(m, mmPk, commitId, takerPk);
        _burnIntoRecognisedToken0Remnant(m, mmPk, commitId, mm);
        _runAsymmetricOverflowCure(m, mmPk, commitId, takerPk);

        _decommitAndTakeAllLccs(m, mmPk, commitId);
        _unwrapAllLccsAndAssert(m, mmPk, commitId, 0, true);
        console.log("OK: asymmetric overflow cure completed");
    }
}

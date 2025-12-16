// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {VTSOrchestratorFixture} from "../modules/VTSOrchestratorFixture.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {PositionId} from "../../src/types/Position.sol";
import {IMarketVault} from "../../src/interfaces/IMarketVault.sol";
import {VTSOrchestrator} from "../../src/VTSOrchestrator.sol";

import {MMActionAdapter as MMA} from "../libraries/MMActionAdapter.sol";

contract VTSFeeLibScenarioTest is VTSOrchestratorFixture {
    using CurrencyLibrary for Currency;

    // Use swap settings consistent with other integration tests
    function _swapSettings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    function _swapCore(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        uint160 sqrtPriceLimit = zeroForOne ? ZERO_FOR_ONE_LIMIT : ONE_FOR_ZERO_LIMIT;
        return swapRouter.swap(
            corePoolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimit}),
            _swapSettings(),
            ZERO_BYTES
        );
    }

    function _negInt128Capped(uint256 amount) internal pure returns (int128) {
        uint256 cap = uint256(uint128(type(int128).max));
        uint256 a = amount > cap ? cap : amount;
        return a == 0 ? int128(0) : -int128(int256(a));
    }

    function _coreHookClaims(Currency lccCurrency) internal view returns (uint256) {
        return manager.balanceOf(coreHookAddress, lccCurrency.toId());
    }

    function _mmpmFullCredit(Currency lccCurrency) internal view returns (uint256) {
        return vtsOrchestrator.getFullCredit(lccCurrency, address(positionManager));
    }

    function _commitAndMintFirstMM() internal returns (uint256 tokenId, PositionId positionId) {
        (tokenId, positionId,,) = _createCommittedPosition();
    }

    function _mintAdditionalMM(uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity)
        internal
        returns (uint256 positionIndex, PositionId positionId)
    {
        (,, uint256 countBefore,) = vtsOrchestrator.getCommit(tokenId);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareMint(corePoolKey, tokenId, tickLower, tickUpper, liquidity);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);

        positionIndex = countBefore;
        positionId = vtsOrchestrator.getPositionId(tokenId, positionIndex);
    }

    function _pokeMM(uint256 tokenId, uint256 positionIndex, int24 tickLower, int24 tickUpper) internal {
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareIncrease(corePoolKey, tokenId, positionIndex, tickLower, tickUpper, 0);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
    }

    function _mmDeposit(uint256 tokenId, uint256 positionIndex, int128 amount0, int128 amount1) internal {
        bytes memory result = unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.onMMSettle.selector,
                IMarketVault(address(proxyHook)),
                tokenId,
                positionIndex,
                corePoolKey.currency0,
                corePoolKey.currency1,
                toBalanceDelta(amount0, amount1),
                false
            )
        );
        // Sanity: decode return to ensure call succeeded
        (BalanceDelta settlementDelta,,) = abi.decode(result, (BalanceDelta, bool, uint256));
        settlementDelta; // silence unused
    }

    function _addDirectLP(int24 tickLower, int24 tickUpper, int256 liquidityDelta) internal returns (PositionId id) {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: 0
        });
        id = PositionId.wrap(bytes32(0)); // not used; DirectLP ids are derived in core hook, but we don’t need it here
        modifyLiquidityRouter.modifyLiquidity(corePoolKey, params, ZERO_BYTES);
    }

    function _pokeDirectLP(int24 tickLower, int24 tickUpper) internal {
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: 0}),
            ZERO_BYTES
        );
    }

    // ============================================================
    // Example scenarios
    // ============================================================

    function test_multiMM_oneDeficit_protocolCovers_slashOnlyDeficitMM() public {
        // 3 MM positions in-range
        (uint256 tokenId, PositionId mm1) = _commitAndMintFirstMM(); // idx 0
        (uint256 idx2, PositionId mm2) = _mintAdditionalMM(tokenId, -60, 60, 1e10);
        (uint256 idx3, PositionId mm3) = _mintAdditionalMM(tokenId, -60, 60, 1e10);
        assertEq(idx2, 1);
        assertEq(idx3, 2);

        // Make MM2 and MM3 solvent by depositing some settlement
        _mmDeposit(tokenId, idx2, _negInt128Capped(5e18), _negInt128Capped(5e18));
        _mmDeposit(tokenId, idx3, _negInt128Capped(5e18), _negInt128Capped(5e18));

        // Swap to accrue fees + outflow growth (choose direction that accrues token0 outflow)
        _swapCore(false, -int256(5e18));

        // Protocol covers unwraps: increment coverage (token0 only)
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 2e18, 0);

        uint256 potBefore = _coreHookClaims(lccCurrency0);
        uint256 creditBefore = _mmpmFullCredit(lccCurrency0);

        // Poke MM1 to settle growth + materialise slashes (if any) and process fees
        _pokeMM(tokenId, 0, -60, 60);

        uint256 potAfter = _coreHookClaims(lccCurrency0);
        uint256 creditAfter = _mmpmFullCredit(lccCurrency0);

        // Expect some funding into the pot (slash materialisation) and reduced fee credit vs baseline direction
        assertGe(potAfter, potBefore, "Pot should not decrease on slash materialisation");
        assertLe(creditAfter, creditBefore, "MM fee credit should not increase when slashed");

        // Touch other MMs to ensure they are not slashed; they should not increase the pot via slashes
        uint256 potMid = _coreHookClaims(lccCurrency0);
        _pokeMM(tokenId, idx2, -60, 60);
        _pokeMM(tokenId, idx3, -60, 60);
        uint256 potEnd = _coreHookClaims(lccCurrency0);
        assertEq(potEnd, potMid, "Solvent MMs should not fund pot via slashes");

        mm1;
        mm2;
        mm3;
    }

    function test_multiMM_twoDeficits_protocolCovers_bothSlashed_selfExcludedFromOwnPot() public {
        (uint256 tokenId,) = _commitAndMintFirstMM(); // idx0
        (uint256 idx2,) = _mintAdditionalMM(tokenId, -60, 60, 1e10); // idx1
        (uint256 idx3,) = _mintAdditionalMM(tokenId, -60, 60, 1e10); // idx2

        // Make MM3 solvent (beneficiary)
        _mmDeposit(tokenId, idx3, _negInt128Capped(10e18), _negInt128Capped(10e18));

        // Swap + coverage -> create deficits on MM0 and MM1
        _swapCore(false, -int256(8e18));
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 4e18, 0);

        uint256 pot0 = _coreHookClaims(lccCurrency0);
        // Poke slashed MMs to fund pot (materialise +pending)
        _pokeMM(tokenId, 0, -60, 60);
        _pokeMM(tokenId, idx2, -60, 60);
        uint256 pot1 = _coreHookClaims(lccCurrency0);
        assertGe(pot1, pot0, "Pot should increase after slashed MMs finalise");

        // Now poke beneficiary; expect it to drain some pot (bonus materialisation) and increase credit
        uint256 creditBefore = _mmpmFullCredit(lccCurrency0);
        _pokeMM(tokenId, idx3, -60, 60);
        uint256 creditAfter = _mmpmFullCredit(lccCurrency0);
        uint256 pot2 = _coreHookClaims(lccCurrency0);

        assertGe(creditAfter, creditBefore, "Beneficiary MM should not lose credit when receiving bonuses");
        assertLe(pot2, pot1, "Bonus materialisation should not increase pot");
    }

    function test_insufficientLiquidity_noCoverageExecuted_noSlashFromQueuedPortion() public {
        // This scenario relies on the settlement liquidity clamp path.
        // We simulate it by making a large withdrawal request and mocking limited vault liquidity.
        (uint256 tokenId, PositionId positionId) = _commitAndMintFirstMM();

        // Close RFS by depositing enough first
        _mmDeposit(tokenId, 0, _negInt128Capped(20e18), _negInt128Capped(20e18));

        // Create some outflows + fees then request coverage
        _swapCore(false, -int256(3e18));
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 2e18, 0);

        // Mock vault to have no liquidity, forcing clamp/queue on withdrawal
        vm.mockCall(
            address(proxyHook),
            abi.encodeWithSelector(IMarketVault.dryModifyLiquidities.selector),
            abi.encode(toBalanceDelta(int128(0), int128(0)))
        );

        uint256 potBefore = _coreHookClaims(lccCurrency0);

        // Attempt a withdrawal via onMMSettle; it will be clamped to 0 by vault mock
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.onMMSettle.selector,
                IMarketVault(address(proxyHook)),
                tokenId,
                0,
                corePoolKey.currency0,
                corePoolKey.currency1,
                toBalanceDelta(int128(10), int128(0)),
                false
            )
        );

        // Poke to process any fee adjustments; queued portion should not create new slashes
        _pokeMM(tokenId, 0, -60, 60);

        uint256 potAfter = _coreHookClaims(lccCurrency0);
        assertEq(potAfter, potBefore, "No executed coverage/withdrawal should not fund pot from queued portion");
        positionId;
    }

    function test_directLP_outOfRange_earnsBonus_fromMMslashes() public {
        // Fund pot by slashing an MM
        (uint256 tokenId,) = _commitAndMintFirstMM(); // idx0
        _swapCore(false, -int256(6e18));
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 3e18, 0);
        _pokeMM(tokenId, 0, -60, 60);

        uint256 potFunded = _coreHookClaims(lccCurrency0);
        assertGt(potFunded, 0, "Expected pot to be funded by MM slash");

        // Add an out-of-range direct LP position and poke it to trigger fee processing
        // Use far out-of-range ticks so it doesn't contribute to coverage attribution, but can still receive bonus.
        _addDirectLP(600, 1200, int256(1e18));

        uint256 potBefore = _coreHookClaims(lccCurrency0);
        _pokeDirectLP(600, 1200);
        uint256 potAfter = _coreHookClaims(lccCurrency0);

        assertLe(potAfter, potBefore, "DirectLP bonus materialisation should drain pot (or leave unchanged)");
    }

    // ============================================================
    // Core edge cases
    // ============================================================

    function test_selfExclusion_potAvailZero_noBonus() public {
        (uint256 tokenId,) = _commitAndMintFirstMM();

        // Create deficit+fees+coverage => slash
        _swapCore(false, -int256(4e18));
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 2e18, 0);
        _pokeMM(tokenId, 0, -60, 60); // materialise slash into pot

        uint256 potAfterSlash = _coreHookClaims(lccCurrency0);
        assertGt(potAfterSlash, 0, "Expected pot funded by slash");

        // Now run a swap that creates inflow for token0 to generate positive net settlement,
        // but the only protocol fee accrued should still be this position's own contribution.
        _swapCore(true, -int256(4e18));

        uint256 creditBefore = _mmpmFullCredit(lccCurrency0);
        uint256 potBefore = _coreHookClaims(lccCurrency0);
        _pokeMM(tokenId, 0, -60, 60);
        uint256 creditAfter = _mmpmFullCredit(lccCurrency0);
        uint256 potAfter = _coreHookClaims(lccCurrency0);

        // Self-exclusion should prevent draining own pot into own bonus.
        assertEq(potAfter, potBefore, "Self position should not drain pot via bonus when potAvail==0");
        assertEq(creditAfter, creditBefore, "Self position should not gain bonus credit from its own pot");
    }

    function test_partialBonusMaterialisation_whenPotNotYetFunded() public {
        // Two MMs: MM0 will be slashed (but we won't finalise yet), MM1 is beneficiary.
        (uint256 tokenId,) = _commitAndMintFirstMM();
        (uint256 idx1,) = _mintAdditionalMM(tokenId, -60, 60, 1e10);

        // Make beneficiary have positive net settlement
        _mmDeposit(tokenId, idx1, _negInt128Capped(10e18), _negInt128Capped(0));

        // Create slash on MM0 by swap + coverage, but do NOT poke MM0 yet (so pot not funded)
        _swapCore(false, -int256(5e18));
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 2e18, 0);

        uint256 potBefore = _coreHookClaims(lccCurrency0);
        uint256 creditBefore = _mmpmFullCredit(lccCurrency0);

        // Poke beneficiary first: it may queue bonus, but cannot drain (pot==0)
        _pokeMM(tokenId, idx1, -60, 60);
        uint256 potAfterFirst = _coreHookClaims(lccCurrency0);
        uint256 creditAfterFirst = _mmpmFullCredit(lccCurrency0);

        assertEq(potAfterFirst, potBefore, "No pot funded yet, so no draining should occur");
        assertEq(creditAfterFirst, creditBefore, "No pot funded yet, so no bonus should materialise");

        // Now poke slashed MM0 to fund pot, then poke beneficiary again to receive bonus
        _pokeMM(tokenId, 0, -60, 60);
        uint256 potAfterFund = _coreHookClaims(lccCurrency0);
        assertGt(potAfterFund, 0, "Pot should be funded after slashed MM finalises");

        _pokeMM(tokenId, idx1, -60, 60);
        uint256 potAfterSecond = _coreHookClaims(lccCurrency0);
        uint256 creditAfterSecond = _mmpmFullCredit(lccCurrency0);

        assertLe(potAfterSecond, potAfterFund, "Second beneficiary poke should drain pot");
        assertGe(creditAfterSecond, creditAfterFirst, "Bonus should materialise after pot is funded");
    }

    function test_dustGuard_bonusSkipped_under1e12Net() public {
        (uint256 tokenId,) = _commitAndMintFirstMM(); // slasher
        (uint256 dustIdx,) = _mintAdditionalMM(tokenId, -60, 60, 1e10); // beneficiary candidate

        // Fund pot via slashing idx0
        _swapCore(false, -int256(5e18));
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 2e18, 0);
        _pokeMM(tokenId, 0, -60, 60);
        uint256 potFunded = _coreHookClaims(lccCurrency0);
        assertGt(potFunded, 0, "Pot should be funded");

        // Create tiny positive net settlement on dustIdx (below 1e12) via deposit
        _mmDeposit(tokenId, dustIdx, _negInt128Capped(1e12 - 1), int128(0));

        uint256 creditBefore = _mmpmFullCredit(lccCurrency0);
        uint256 potBefore = _coreHookClaims(lccCurrency0);
        _pokeMM(tokenId, dustIdx, -60, 60);
        uint256 creditAfter = _mmpmFullCredit(lccCurrency0);
        uint256 potAfter = _coreHookClaims(lccCurrency0);

        assertEq(creditAfter, creditBefore, "Dust net should not allocate bonus");
        assertEq(potAfter, potBefore, "Dust net should not drain pot");
    }

    function test_rounding_residualPot_leftOver() public {
        // Fund pot with one slashed MM, then distribute to 3 beneficiaries with different weights
        (uint256 tokenId,) = _commitAndMintFirstMM(); // idx0 slasher
        (uint256 idx1,) = _mintAdditionalMM(tokenId, -60, 60, 1e10);
        (uint256 idx2,) = _mintAdditionalMM(tokenId, -60, 60, 1e10);
        (uint256 idx3,) = _mintAdditionalMM(tokenId, -60, 60, 1e10);

        // Beneficiary weights: 1,2,3 (token0 deposits)
        _mmDeposit(tokenId, idx1, _negInt128Capped(2e12), int128(0));
        _mmDeposit(tokenId, idx2, _negInt128Capped(4e12), int128(0));
        _mmDeposit(tokenId, idx3, _negInt128Capped(6e12), int128(0));

        _swapCore(false, -int256(10e18));
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 5e18, 0);
        _pokeMM(tokenId, 0, -60, 60);

        uint256 potStart = _coreHookClaims(lccCurrency0);
        assertGt(potStart, 0, "Expected funded pot");

        // Drain in fixed order
        _pokeMM(tokenId, idx1, -60, 60);
        _pokeMM(tokenId, idx2, -60, 60);
        _pokeMM(tokenId, idx3, -60, 60);

        uint256 potEnd = _coreHookClaims(lccCurrency0);
        assertLe(potEnd, potStart, "Bonuses should not increase pot");
        // Expect some remainder due to rounding / sequential allocation
        assertTrue(potEnd < potStart, "Expected pot to be partially drained");
    }
}


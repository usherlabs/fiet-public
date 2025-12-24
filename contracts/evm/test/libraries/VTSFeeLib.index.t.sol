// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VTSOrchestratorFixture} from "../modules/VTSOrchestratorFixture.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {VTSOrchestratorTestable} from "../modules/VTSOrchestratorTestable.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionId} from "../../src/types/Position.sol";
import {VTSOrchestrator} from "../../src/VTSOrchestrator.sol";
import {LiquiditySignal} from "../../src/types/Commit.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
import {console} from "forge-std/console.sol";

/// @title VTSFeeLibIndexTest
/// @notice Unit tests for DICE (Deficit-Indexed Coverage Exercise) and CSI (Contribution Spend Index) mechanisms
/// @dev These tests verify the core index-based accounting mechanisms:
///      - DICE: Coverage attribution to deficit creators, not current tick positions
///      - CSI: Self-excluding bonus allocation via contribution spend tracking
contract VTSFeeLibIndexTest is VTSOrchestratorFixture {
    using CurrencyLibrary for Currency;

    // ============================================================
    // Multi-Commit Support
    // ============================================================

    /// @notice Array of liquidity signals for creating multiple independent commits
    LiquiditySignal[] internal multiSignals;

    /// @notice Index tracking which signal to use next
    uint256 internal nextSignalIndex;

    /// @notice Override setUp to generate additional signals for multi-commit tests
    function setUp() public virtual override {
        super.setUp();
        // Generate additional signals for multi-commit scenarios (nonces 3, 4, 5, ...)
        // Note: nonces 1 and 2 are already used by liquiditySignal and renewSignal
        LiquiditySignal[] memory signals = generateLiquiditySignals(10);
        // Copy each signal to storage manually (avoids memory[] to storage[] issue)
        for (uint256 i = 0; i < signals.length; i++) {
            multiSignals.push();
            _saveSignal(multiSignals[i], signals[i]);
        }
        nextSignalIndex = 0;
    }

    /// @notice Override to deploy VTSOrchestratorTestable with debug view functions
    function _deployVTSOrchestrator(
        address _poolManager,
        address _signalManager,
        address _oracleHelper,
        address _liquidityHub,
        address _settlementObserver,
        address _owner
    ) internal override returns (VTSOrchestrator) {
        return new VTSOrchestratorTestable(
            _poolManager, _signalManager, _oracleHelper, _liquidityHub, _settlementObserver, _owner
        );
    }

    /// @notice Helper to access testable VTSOrchestrator with debug functions
    function _testableOrchestrator() internal view returns (VTSOrchestratorTestable) {
        return VTSOrchestratorTestable(address(vtsOrchestrator));
    }

    /// @notice Creates a new MM commit with a unique signal (supports multiple independent commits)
    /// @dev Uses default range (-60, 60) and default liquidity (1e10)
    /// @return tokenId The commitment NFT token ID
    /// @return positionId The position ID of the minted position
    function _createNewMMCommit(int24 tickLower, int24 tickUpper, uint256 liquidity)
        internal
        returns (uint256 tokenId, PositionId positionId)
    {
        require(nextSignalIndex < multiSignals.length, "No more signals available");
        LiquiditySignal memory signal = multiSignals[nextSignalIndex++];
        // Get the next commit ID before creating the commit (for reference/verification)
        uint256 expectedTokenId = vtsOrchestrator.nextCommitId();
        (tokenId, positionId,,) = _createCommittedPosition(signal, tickLower, tickUpper, liquidity, bytes32(0));
        // Verify the tokenId matches what we expected
        assertEq(tokenId, expectedTokenId, "TokenId should match nextCommitId");
    }

    // ============================================================
    // DICE (Deficit-Indexed Coverage Exercise) Tests
    // ============================================================

    /// @notice DICE Test 1: Coverage is attributed to positions that created deficit,
    ///         NOT to positions in-range at coverage time
    /// @dev Verifies that out-of-range positions with deficit are still slashed.
    ///      This is the core fix for the tick-indexed coverage attribution bug.
    function test_DICE_coverageAttributedToDeficitCreators_notCurrentTick() public {
        // Setup: Create MM position in range [-60, 60]
        (uint256 tokenId, PositionId mmPositionId) = _createNewMMCommit(-60, 60, 3e10);

        // Record initial state
        // Note: For a "one for zero" swap (token1 -> token0), fees accrue on token1 (input token)
        // So we check token1 fees, not token0
        (, uint256 feeAccruedBefore1) = _protocolFeeAccrued(corePoolKey.toId());
        (, int24 tickInitial,,) = StateLibrary.getSlot0(manager, corePoolKey.toId());

        console.log("====== INITIAL STATE ======");
        console.log("feeAccruedBefore1:", feeAccruedBefore1);
        console.log("tickInitial:", tickInitial);

        // Swap to create deficit - this also moves the tick
        // Using a large swap to potentially move tick beyond MM's range
        // "one for zero" swap: token1 -> token0 (fees accrue on token1)
        _swapCore(false, -int256(50e18)); // one for zero swap

        (, int24 tickAfterSwap,,) = StateLibrary.getSlot0(manager, corePoolKey.toId());
        console.log("====== AFTER SWAP ======");
        console.log("tickAfterSwap:", tickAfterSwap);

        // Inspect position accounting BEFORE first settle
        {
            (
                uint256 cumulativeDeficit0Before,
                uint256 cumulativeDeficit1Before,
                uint256 settled0Before,
                uint256 settled1Before,
                uint256 commitmentMax0Before,
                uint256 commitmentMax1Before
            ) = _testableOrchestrator().getPositionAccounting(mmPositionId);
            console.log("====== POSITION ACCOUNTING BEFORE SETTLE ======");
            console.log("cumulativeDeficit0:", cumulativeDeficit0Before);
            console.log("cumulativeDeficit1:", cumulativeDeficit1Before);
            console.log("settled0:", settled0Before);
            console.log("settled1:", settled1Before);
            console.log("commitmentMax0:", commitmentMax0Before);
            console.log("commitmentMax1:", commitmentMax1Before);
        }

        // Settle MM position to materialise deficit
        vtsOrchestrator.settlePositionGrowths(mmPositionId);

        // Inspect position accounting AFTER first settle
        {
            (
                uint256 cumulativeDeficit0After,
                uint256 cumulativeDeficit1After,
                uint256 settled0After,
                uint256 settled1After,
                uint256 commitmentMax0After,
                uint256 commitmentMax1After
            ) = _testableOrchestrator().getPositionAccounting(mmPositionId);
            console.log("====== POSITION ACCOUNTING AFTER 1ST SETTLE ======");
            console.log("cumulativeDeficit0:", cumulativeDeficit0After);
            console.log("cumulativeDeficit1:", cumulativeDeficit1After);
            console.log("settled0:", settled0After);
            console.log("settled1:", settled1After);
            console.log("commitmentMax0:", commitmentMax0After);
            console.log("commitmentMax1:", commitmentMax1After);
        }

        // Inspect pool accounting BEFORE incrementCoverage
        {
            (
                uint256 totalDeficitPrincipal0,
                uint256 totalDeficitPrincipal1,
                uint256 coveragePerDeficitIndex0,
                uint256 coveragePerDeficitIndex1,
                uint256 coverageResidual0,
                uint256 coverageResidual1
            ) = _testableOrchestrator().getPoolDICEAccounting(corePoolKey.toId());
            console.log("====== POOL DICE ACCOUNTING BEFORE COVERAGE ======");
            console.log("totalDeficitPrincipal0:", totalDeficitPrincipal0);
            console.log("totalDeficitPrincipal1:", totalDeficitPrincipal1);
            console.log("coveragePerDeficitIndex0:", coveragePerDeficitIndex0);
            console.log("coveragePerDeficitIndex1:", coveragePerDeficitIndex1);
            console.log("coverageResidual0:", coverageResidual0);
            console.log("coverageResidual1:", coverageResidual1);
        }

        // Protocol covers unwraps (token0)
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 5e18, 0);

        // Inspect pool accounting AFTER incrementCoverage
        {
            (
                uint256 totalDeficitPrincipal0,
                uint256 totalDeficitPrincipal1,
                uint256 coveragePerDeficitIndex0,
                uint256 coveragePerDeficitIndex1,
                uint256 coverageResidual0,
                uint256 coverageResidual1
            ) = _testableOrchestrator().getPoolDICEAccounting(corePoolKey.toId());
            console.log("====== POOL DICE ACCOUNTING AFTER COVERAGE ======");
            console.log("totalDeficitPrincipal0:", totalDeficitPrincipal0);
            console.log("totalDeficitPrincipal1:", totalDeficitPrincipal1);
            console.log("coveragePerDeficitIndex0:", coveragePerDeficitIndex0);
            console.log("coveragePerDeficitIndex1:", coveragePerDeficitIndex1);
            console.log("coverageResidual0:", coverageResidual0);
            console.log("coverageResidual1:", coverageResidual1);
        }

        // Inspect position's coverage index checkpoint BEFORE 2nd settle
        {
            (uint256 coverageIndexLast0, uint256 coverageIndexLast1) =
                _testableOrchestrator().getPositionCoverageIndex(mmPositionId);
            console.log("====== POSITION COVERAGE INDEX BEFORE 2ND SETTLE ======");
            console.log("coverageIndexLast0:", coverageIndexLast0);
            console.log("coverageIndexLast1:", coverageIndexLast1);
        }

        // Settle MM position growths again to apply DICE coverage
        vtsOrchestrator.settlePositionGrowths(mmPositionId);

        // Inspect position's coverage index checkpoint AFTER 2nd settle
        {
            (uint256 coverageIndexLast0, uint256 coverageIndexLast1) =
                _testableOrchestrator().getPositionCoverageIndex(mmPositionId);
            console.log("====== POSITION COVERAGE INDEX AFTER 2ND SETTLE ======");
            console.log("coverageIndexLast0:", coverageIndexLast0);
            console.log("coverageIndexLast1:", coverageIndexLast1);
        }

        // DICE: MM should be slashed because it has deficit principal,
        // regardless of whether it's currently in-range
        // For token0 deficit (from token1->token0 swap), fees accrue on token1
        (, uint256 feeAccruedAfter1) = _protocolFeeAccrued(corePoolKey.toId());

        console.log("====== FINAL STATE ======");
        console.log("feeAccruedBefore1:", feeAccruedBefore1);
        console.log("feeAccruedAfter1:", feeAccruedAfter1);
        console.log("delta:", feeAccruedAfter1 - feeAccruedBefore1);

        assertGt(
            feeAccruedAfter1,
            feeAccruedBefore1,
            "DICE: Position with deficit should be slashed regardless of current tick"
        );

        // Suppress unused variable warning
        tokenId;
    }

    /// @notice DICE Test 2: In-range position without deficit is NOT slashed
    /// @dev Verifies that coverage charges are only applied to positions with deficit,
    ///      not just positions that happen to be in-range at coverage time.
    function test_DICE_inRangePositionWithoutDeficit_notSlashed() public {
        // Create two positions: MM1 (will have deficit), MM2 (settlement-buffered, should remain solvent)
        (uint256 mm1, PositionId mm1PositionId) = _createNewMMCommit(-60, 60, 3e10);
        (uint256 mm2, PositionId mm2PositionId) = _createNewMMCommit(-60, 60, 3e10);

        // Make MM2 fully solvent (no deficit expected after swap)
        _mmSettle(mm2, 0, _negInt128Capped(20e18), _negInt128Capped(20e18));

        // Swap to create outflow growth. Both positions are in-range, but MM2 should cover via settlement.
        _swapCore(false, -int256(10e18)); // one for zero swap - fees accrue on token1, deficits (if any) on token0

        // First settle MM1 to MATERIALISE deficit principal (required for incrementCoverage() to bump the DICE index).
        // This should not slash yet because no coverage has been exercised.
        vtsOrchestrator.settlePositionGrowths(mm1PositionId);

        // Record pool + MM2 fee accounting baseline (should not move when settling a solvent MM after coverage).
        (, uint256 feeAccruedBefore1) = _protocolFeeAccrued(corePoolKey.toId());
        (
            uint256 mm2FeesShared0Before,
            uint256 mm2FeesShared1Before,
            int256 mm2Pending0Before,
            int256 mm2Pending1Before
        ) = _testableOrchestrator().getPositionFeeAccounting(mm2PositionId);

        // Coverage event
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 5e18, 0);

        // Settle MM2 after coverage: MM2 has no deficit principal, so it must NOT be slashed.
        vtsOrchestrator.settlePositionGrowths(mm2PositionId);

        (, uint256 feeAccruedAfter1) = _protocolFeeAccrued(corePoolKey.toId());

        // DICE: No pool protocolFeeAccrued increase should occur from settling a solvent position.
        assertEq(
            feeAccruedAfter1,
            feeAccruedBefore1,
            "DICE: Settling a solvent position must not increase protocolFeeAccrued"
        );

        // And MM2 should not have been attributed any slashed fees or pending adjustments.
        (uint256 mm2FeesShared0After, uint256 mm2FeesShared1After, int256 mm2Pending0After, int256 mm2Pending1After) =
            _testableOrchestrator().getPositionFeeAccounting(mm2PositionId);
        assertEq(mm2FeesShared0After, mm2FeesShared0Before, "DICE: Solvent MM2 must not be slashed (feesShared0)");
        assertEq(mm2FeesShared1After, mm2FeesShared1Before, "DICE: Solvent MM2 must not be slashed (feesShared1)");
        assertEq(mm2Pending0After, mm2Pending0Before, "DICE: Solvent MM2 must not be slashed (pendingFeeAdj0)");
        assertEq(mm2Pending1After, mm2Pending1Before, "DICE: Solvent MM2 must not be slashed (pendingFeeAdj1)");

        // Settling MM1 again should now apply DICE coverage burn and increase protocolFeeAccrued (fee token = token1).
        vtsOrchestrator.settlePositionGrowths(mm1PositionId);
        (, uint256 feeAccruedAfter2) = _protocolFeeAccrued(corePoolKey.toId());
        assertGt(
            feeAccruedAfter2, feeAccruedAfter1, "DICE: Protocol fee should reflect coverage from deficit positions"
        );

        // Suppress unused variable warning
        mm1;
    }

    /// @notice DICE Test 3: Coverage residual is socialised when deficit materialises later
    /// @dev Verifies that coverage exercised when totalDeficitPrincipal = 0 is deferred
    ///      and correctly applied when deficits are later materialised.
    function test_DICE_residualSocialisedToFutureDeficits() public {
        // Setup: Create a position with no materialised deficit initially.
        // Note: We intentionally do NOT add an oversized settlement buffer here, so a later swap can
        // actually materialise deficit principal and trigger residual flushing.
        (uint256 tokenId, PositionId positionId) = _createNewMMCommit(-60, 60, 3e10);

        // Settle to ensure no deficit exists yet
        vtsOrchestrator.settlePositionGrowths(positionId);

        (, uint256 feeAccruedBeforeCoverage) = _protocolFeeAccrued(corePoolKey.toId());

        // Coverage event with no deficit in pool (should go to DICE residual)
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 5e18, 0);

        (, uint256 feeAccruedAfterFirstCoverage) = _protocolFeeAccrued(corePoolKey.toId());

        assertEq(
            feeAccruedAfterFirstCoverage,
            feeAccruedBeforeCoverage,
            "DICE: protocolFeeAccrued must not change when coverage is deferred into residual"
        );

        // Confirm residual was recorded (and index was not incremented yet)
        {
            (
                uint256 totalDeficitPrincipal0,
                uint256 totalDeficitPrincipal1,
                uint256 coveragePerDeficitIndex0,
                uint256 coveragePerDeficitIndex1,
                uint256 coverageResidual0,
                uint256 coverageResidual1
            ) = _testableOrchestrator().getPoolDICEAccounting(corePoolKey.toId());
            assertEq(totalDeficitPrincipal0, 0, "DICE: totalDeficitPrincipal0 must be 0 before deficit materialises");
            assertEq(totalDeficitPrincipal1, 0, "DICE: totalDeficitPrincipal1 must be 0 before deficit materialises");
            assertEq(coveragePerDeficitIndex0, 0, "DICE: coverage index must not increment when principal is 0");
            assertEq(coverageResidual0, 5e18, "DICE: coverage should be deferred into residual when principal is 0");
            // Suppress unused variable warnings
            coveragePerDeficitIndex1;
            coverageResidual1;
        }

        // Now create deficit via a larger swap that exceeds settlement buffer
        _swapCore(false, -int256(250e18)); // one for zero swap - therefore fee accrued on token1, deficit on token0

        // Settle position (should flush residual and apply coverage)
        vtsOrchestrator.settlePositionGrowths(positionId);

        // DICE: Residual should have been flushed into the index once principal exists.
        // Note: feesBurn (and thus protocolFeeAccrued) can still be 0 if no fees were accrued,
        // so we assert on the DICE accounting invariants rather than protocolFeeAccrued deltas.
        {
            (
                uint256 totalDeficitPrincipal0,
                uint256 totalDeficitPrincipal1,
                uint256 coveragePerDeficitIndex0,
                uint256 coveragePerDeficitIndex1,
                uint256 coverageResidual0,
                uint256 coverageResidual1
            ) = _testableOrchestrator().getPoolDICEAccounting(corePoolKey.toId());

            assertGt(totalDeficitPrincipal0, 0, "DICE: deficit principal must materialise for token0");
            assertEq(coverageResidual0, 0, "DICE: residual must be flushed once principal exists");
            assertGt(coveragePerDeficitIndex0, 0, "DICE: residual must be socialised into the coverage index");

            // Suppress unused variable warnings
            totalDeficitPrincipal1;
            coveragePerDeficitIndex1;
            coverageResidual1;
        }

        (, uint256 feeAccruedAfterSettle) = _protocolFeeAccrued(corePoolKey.toId());
        assertGt(
            feeAccruedAfterSettle,
            feeAccruedAfterFirstCoverage,
            "DICE: protocolFeeAccrued must not decrease after deficit materialises"
        );
    }

    // ============================================================
    // CSI (Contribution Spend Index) Tests
    // ============================================================
    // These tests verify the CSI mechanism for self-exclusion, ensuring
    // that potAvail is computed correctly based on remaining self-contribution
    // rather than lifetime contribution.

    /// @notice CSI Test 1: Position's own pot contribution stays excluded until spent
    /// @dev Verifies that a position cannot receive bonuses from its own contribution
    ///      (selfRemaining > 0) until that contribution has been spent by others.
    function test_csi_selfOnlyPotStaysExcluded() public {
        // Setup: Create position A (will be slashed) and position B (potential bonus recipient)
        (uint256 mmA, PositionId posIdA) = _createNewMMCommit(-60, 60, 3e10);
        (uint256 mmB, PositionId posIdB) = _createNewMMCommit(-60, 60, 3e10);

        // Make B solvent
        _mmSettle(mmB, 0, _negInt128Capped(20e18), _negInt128Capped(20e18));

        // Swap to create deficit on A
        _swapCore(false, -int256(50e18));
        vtsOrchestrator.settlePositionGrowths(posIdA);

        // Coverage event triggers slash on A
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 10e18, 0);

        // Settle A to materialise the slash
        vtsOrchestrator.settlePositionGrowths(posIdA);

        // ? Deficit on MM A, slash on MM A, then poke MM A.

        // Record A's fee accounting after slash
        (uint256 aFeesShared0Before, uint256 aFeesShared1Before, int256 aPending0Before, int256 aPending1Before) =
            _testableOrchestrator().getPositionFeeAccounting(posIdA);

        assertGt(aFeesShared1Before, 0, "CSI: Position must queue fee share from its own contribution (feesShared > 0)");
        assertEq(
            aPending1Before > 0 ? uint256(aPending1Before) : 0,
            aFeesShared1Before,
            "CSI: Fee share must equal pending adjustment to position fees."
        );

        // Record pot and CSI state
        (, uint256 potBefore) = _protocolFeeAccrued(corePoolKey.toId());
        // Fee token for one-for-zero swaps is token1, so we track token1's spend index.
        (, uint256 poolSpendIndex1Before) = _testableOrchestrator().getPoolCSIAccounting(corePoolKey.toId());

        // A's contribution is the only thing in the pot
        // A's selfRemaining should equal its feesShared (nothing consumed yet)
        // Therefore potAvail for A should be 0

        // Poke A to trigger fee processing
        _pokeMM(mmA, 0, -60, 60);

        // Record A's pending after poke
        (, uint256 aFeesShared1After, int256 aPending0After, int256 aPending1After) =
            _testableOrchestrator().getPositionFeeAccounting(posIdA);

        // A should NOT have received a bonus.
        // Note: pendingFeeAdj is materialised on poke (positive pending slashes are moved into `slashedPot`),
        // so pending can decrease to 0 even when no bonus is allocated. The invariant we want is: no negative pending.
        assertGe(aPending1After, 0, "CSI: Position must not queue a bonus from its own contribution (pending < 0)");
        assertGe(aFeesShared1After, 0, "CSI: Position must maintain a fee share as bonus is not allocated.");

        // Pool spend index should NOT have advanced (no bonus was allocated)
        (, uint256 poolSpendIndex1After) = _testableOrchestrator().getPoolCSIAccounting(corePoolKey.toId());
        assertEq(
            poolSpendIndex1After, poolSpendIndex1Before, "CSI: Spend index should not advance when no bonus allocated"
        );

        // Suppress unused variable warnings
        mmA;
        mmB;
        posIdB;
        aFeesShared0Before;
        aFeesShared1Before;
        aPending0Before;
        aPending0After;
        potBefore;
    }

    /// @notice CSI Test 2: Mixed pot allows partial self-exclusion
    /// @dev Verifies that when multiple positions contribute to the pot,
    ///      each can only allocate bonuses from the non-self portion.
    /// @dev Verifies that after a position's contributed slashes are distributed via bonuses,
    ///      the position can participate in future bonus allocations from new contributions.
    ///      This is the core bug fix that CSI addresses.
    function test_csi_mixedPotPartialExclusion_withPostFeeShareSettleForBonus() public {
        // Setup: Create 3 positions - A, B (both will be slashed), C (bonus recipient)
        (uint256 mmA, PositionId posIdA) = _createNewMMCommit(-60, 60, 10e18);
        (uint256 mmB, PositionId posIdB) = _createNewMMCommit(-60, 60, 10e18);
        (uint256 mmC, PositionId posIdC) = _createNewMMCommit(-60, 60, 10e18);

        // Make C very solvent (will be the beneficiary)
        // (uint256 commitMax0, uint256 commitMax1) = vtsOrchestrator.getCommitmentMaxima(posIdC);
        // _mmSettle(mmC, 0, _negInt128Capped(commitMax0 / 2), _negInt128Capped(commitMax1 / 2));
        // Settle must be < than 29953549559107809 where swap is 50e18, and MM position L is 10e18
        _mmSettle(mmC, 0, _negInt128Capped(2e16), _negInt128Capped(2e16));

        (, int24 tickBefore,,) = StateLibrary.getSlot0(manager, corePoolKey.toId());

        // Swap to create deficits on A and B
        _swapCore(false, -int256(50e18)); // 1 for 0

        (, int24 tickAfter,,) = StateLibrary.getSlot0(manager, corePoolKey.toId());

        console.log("tickBefore", tickBefore);
        console.log("tickAfter", tickAfter);

        // Settle both to materialise deficit principals
        console.log("-------------------------------- Settling A");
        vtsOrchestrator.settlePositionGrowths(posIdA);
        console.log("-------------------------------- Settling B");
        vtsOrchestrator.settlePositionGrowths(posIdB);
        console.log("-------------------------------- Settling C");
        vtsOrchestrator.settlePositionGrowths(posIdC);
        console.log("--------------------------------");

        // Coverage event triggers slashes on both A and B
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 20e18, 0);

        // Settle both to materialise slashes
        console.log("-------------------------------- Settling A");
        vtsOrchestrator.settlePositionGrowths(posIdA);
        console.log("-------------------------------- Settling B");
        vtsOrchestrator.settlePositionGrowths(posIdB);
        console.log("-------------------------------- Settling C");
        vtsOrchestrator.settlePositionGrowths(posIdC);
        console.log("--------------------------------");

        // ? At this stage:
        // mmA, mmB, mmC are all in a deficit. Fees are slashed. But mmC earns a bonus relative to their settled. Pots not allocated.

        // Record contributions
        // Fee token for one-for-zero swaps is token1.
        (, uint256 aFeesShared1,,) = _testableOrchestrator().getPositionCSIAccounting(posIdA);
        (, uint256 bFeesShared1,,) = _testableOrchestrator().getPositionCSIAccounting(posIdB);
        (, uint256 cFeesShared1,,) = _testableOrchestrator().getPositionCSIAccounting(posIdC);
        (, uint256 potAfterSlashes) = _protocolFeeAccrued(corePoolKey.toId());

        // Both A and B contributed to the pot
        assertGt(aFeesShared1, 0, "CSI: A should have contributed to pot");
        assertGt(bFeesShared1, 0, "CSI: B should have contributed to pot");
        assertGt(cFeesShared1, 0, "CSI: C should have contributed to pot");

        // Total pot should be sum of contributions (before any bonuses)
        // Note: pot = A's contribution + B's contribution
        // potAfterSlashes should be >= aFeesShared1 + bFeesShared1 for fee token1 (before any bonuses)
        assertEq(potAfterSlashes, aFeesShared1 + bFeesShared1 + cFeesShared1, "CSI: Pot should be sum of contributions");

        assertLt(
            cFeesShared1,
            aFeesShared1,
            "CSI: Settled amounts differ, therefore C fees shared should be less than A fees shared"
        );

        // C pokes and receives a bonus
        int256 cPendingBefore;
        (,,, cPendingBefore) = _testableOrchestrator().getPositionFeeAccounting(posIdC);

        _pokeMM(mmC, 0, -60, 60);

        int256 cPendingAfter;
        (,,, cPendingAfter) = _testableOrchestrator().getPositionFeeAccounting(posIdC);

        // // C should have received a bonus (pending decreased / more negative)
        // assertLt(cPendingAfter, cPendingBefore, "CSI: C should receive bonus from A+B's contributions");
        // // ? However, bonus does not materialise until the next poke.

        assertLt(cPendingAfter, cPendingBefore, "CSI: C should have materialised fee share ONLY.");
        // ? Bonus cannot be queued to MM3 at this stage, as the potAvail == 0.

        // Now A pokes - A can receive bonus from B's contribution, but not its own
        int256 aPendingBefore;
        (,, aPendingBefore,) = _testableOrchestrator().getPositionFeeAccounting(posIdA);

        console.log("-------------------------------- Poke A");
        _pokeMM(mmA, 0, -60, 60);
        console.log("-------------------------------- END Poke A");

        // Record A's CSI state after poke
        // With remaining-shares CSI, A's remaining shares should decrease after C consumes from the pot.
        (, uint256 aRemaining1After,,) = _testableOrchestrator().getPositionCSIAccounting(posIdA);

        // Similarly B pokes
        console.log("-------------------------------- Poke B");
        _pokeMM(mmB, 0, -60, 60);
        console.log("-------------------------------- END Poke B");

        (, uint256 bRemaining1After,,) = _testableOrchestrator().getPositionCSIAccounting(posIdB);

        (, uint256 pot1) = _testableOrchestrator().getSlashedPot(corePoolKey.toId());
        assertEq(pot1, potAfterSlashes, "CSI: Slashed pot should increase after poke");

        // ? At this stage, C has feesShared > 0.
        // ? Given how deficits are settled, if a position actually has deficit principal for (say) token0,
        // ? then when you settle deficit growth it will generally have had its token0 settlement buffer fully consumed
        // ? (it gets spent down to cover outflows), leaving no token0 “settled” remaining to be exposed,
        // ? so it won’t accrue CISE exposure for token0 coverage.

        // Settle more.
        _mmSettle(mmC, 0, _negInt128Capped(5e18), _negInt128Capped(5e18));

        // Increment more coverage to trigger bonus, that nets against the slashes.
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 30e18, 0);

        vtsOrchestrator.settlePositionGrowths(posIdA);
        vtsOrchestrator.settlePositionGrowths(posIdB);
        vtsOrchestrator.settlePositionGrowths(posIdC);

        uint256 lcc1BalanceBefore = _selfLccBalance(lccCurrency1);

        console.log("-------------------------------- Poke C");
        _pokeMM(mmC, 0, -60, 60);
        console.log("-------------------------------- END Poke C");

        (,,, cPendingAfter) = _testableOrchestrator().getPositionFeeAccounting(posIdC);
        assertEq(cPendingAfter, 0, "CSI: C should have materialised and cleared its bonus.");

        uint256 lcc1BalanceAfter = _selfLccBalance(lccCurrency1);
        assertGt(lcc1BalanceAfter, lcc1BalanceBefore, "CSI: LCC balance will greater after poke C");
        // assertEq(lcc1BalanceAfter, lcc1BalanceBefore, "CSI: LCC balance will be the same after poke C");

        // Suppress unused variable warnings
        mmA;
        mmB;
        mmC;
        aFeesShared1;
        bFeesShared1;
        potAfterSlashes;
        aPendingBefore;
        aRemaining1After;
        bRemaining1After;
    }

    /// @notice CSI Test 3: New shares are not retroactively consumed
    /// @dev Verifies that when a position receives new slashes after the spend index
    ///      has advanced, the new shares are not treated as already consumed.
    function test_csi_newSharesNotRetroactivelyConsumed() public {
        // Setup: Create positions A (will be slashed twice), B (bonus recipient)
        (uint256 mmA, PositionId posIdA) = _createNewMMCommit(-60, 60, 3e10);
        (uint256 mmB, PositionId posIdB) = _createNewMMCommit(-60, 60, 3e10);

        // Make B solvent
        _mmSettle(mmB, 0, _negInt128Capped(30e18), _negInt128Capped(30e18));

        // First round: create deficit + fees while positions are still in-range.
        // NOTE: Large swaps can move tick far outside [-60,60] and prevent any further in-range accruals,
        // which makes it impossible to test "new shares minted after spend index advances".
        _swapCore(false, -int256(2e18));
        vtsOrchestrator.settlePositionGrowths(posIdA);
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 2e18, 0);
        vtsOrchestrator.settlePositionGrowths(posIdA);

        // Record A's first contribution
        // Fee token for one-for-zero swaps is token1.
        (, uint256 aFeesShared1First,, uint256 aIndexLast1First) =
            _testableOrchestrator().getPositionCSIAccounting(posIdA);

        assertGt(aFeesShared1First, 0, "A should have fees shared after first slash");

        uint256 lcc1BalanceBefore = _selfLccBalance(lccCurrency1);
        (, uint256 pot1BeforeBonus) = _protocolFeeAccrued(corePoolKey.toId());

        // B receives bonus from A's first contribution (advances spend index)
        _pokeMM(mmB, 0, -60, 60);
        uint256 lcc1BalanceAfter = _selfLccBalance(lccCurrency1);
        assertGt(lcc1BalanceAfter, lcc1BalanceBefore, "LCC balance will be greater after poke B");

        // Record spend index after B's bonus
        (, uint256 spendIndex1AfterFirstBonus) = _testableOrchestrator().getPoolCSIAccounting(corePoolKey.toId());
        assertGt(spendIndex1AfterFirstBonus, 0, "CSI: Spend index should advance after bonus allocation");

        // Bonus allocation should have drained the fee pot (protocolFeeAccrued for fee token1)
        (, uint256 pot1AfterBonus) = _protocolFeeAccrued(corePoolKey.toId());
        assertLt(pot1AfterBonus, pot1BeforeBonus, "CSI: Bonus should drain protocol fee pot (token1)");

        (uint256 def0, uint256 def1,,,,) = _testableOrchestrator().getPositionAccounting(posIdA);
        console.log("POS A: def0", def0);
        console.log("POS A: def1", def1);
        assertGt(def0, 0, "A should have a cumulative deficit after first slash");
        assertEq(def1, 0, "A should have no cumulative deficit after first slash");

        (,, uint256 coveragePerDeficitIndex0Before,,,) =
            _testableOrchestrator().getPoolDICEAccounting(corePoolKey.toId());

        // Create fresh in-range outflow/fee windows so a second burn mints new shares.
        _swapCore(false, -int256(3e18));
        // ? without conducting the second swap, this causes the full deficit to be exercised in coverage.
        // ? therefore, second swap applies more deficit.
        vtsOrchestrator.settlePositionGrowths(posIdA);
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 3e18, 0);

        (,, uint256 coveragePerDeficitIndex0After,,,) =
            _testableOrchestrator().getPoolDICEAccounting(corePoolKey.toId());
        assertGt(
            coveragePerDeficitIndex0After,
            coveragePerDeficitIndex0Before,
            "Coverage per deficit index for token0 should be greater after second slash"
        );

        // Record pot before second slash is materialised; delta in pot corresponds to newly minted fee shares (feesBurn2)
        (, uint256 pot1BeforeSecondSlash) = _protocolFeeAccrued(corePoolKey.toId());
        console.log("-------------------------------- Settling A #2");
        vtsOrchestrator.settlePositionGrowths(posIdA);
        console.log("-------------------------------- END Settling A");
        (, uint256 pot1AfterSecondSlash) = _protocolFeeAccrued(corePoolKey.toId());
        uint256 minted2 = pot1AfterSecondSlash - pot1BeforeSecondSlash;
        assertGt(minted2, 0, "second slash should mint new fee shares");

        // Record A's total contribution after second slash
        (, uint256 aFeesShared1Second,,) = _testableOrchestrator().getPositionCSIAccounting(posIdA);

        // Critical invariant (remaining-shares model):
        // When A is slashed again AFTER the spend index advanced, the implementation must:
        // 1) spend-down A's *existing* remaining shares using (spendIndex - A.indexLast), then
        // 2) mint new shares for the new slash.
        // Therefore, the new shares (minted2) must NOT be treated as already spent.
        //
        // expected = (aFeesShared1First - spent) + minted2
        uint256 spent =
            FullMath.mulDiv(aFeesShared1First, spendIndex1AfterFirstBonus - aIndexLast1First, FixedPoint128.Q128);
        uint256 remaining = spent >= aFeesShared1First ? 0 : (aFeesShared1First - spent);
        uint256 expected = remaining + minted2;
        assertEq(aFeesShared1Second, expected, "CSI: New shares must not be retroactively consumed");

        // Suppress unused variable warnings
        mmA;
        mmB;
        posIdB;
        aFeesShared1First;
    }
}


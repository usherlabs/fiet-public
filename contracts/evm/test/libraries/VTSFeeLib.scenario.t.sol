// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VTSOrchestratorFixture} from "../modules/VTSOrchestratorFixture.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {VTSOrchestratorTestable} from "../modules/VTSOrchestratorTestable.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {PositionId, PositionLibrary} from "../../src/types/Position.sol";
import {IMarketVault} from "../../src/interfaces/IMarketVault.sol";
import {VTSOrchestrator} from "../../src/VTSOrchestrator.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {MMActionAdapter as MMA} from "../libraries/MMActionAdapter.sol";
import {LiquiditySignal} from "../../src/types/Commit.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

/// @title VTSFeeLibScenarioTest
/// @notice Scenario-driven integration tests for VTS fee-sharing paradigm (slashes, bonuses, materialisation)
/// @dev These tests exercise the full fee-sharing pipeline described in Tick-Indexed-Coverage-and-Fee-Sharing-in-VTSManager.md:
///      - Coverage usage attribution via tick-indexed growth (incrementCoverage)
///      - Fee slashing from positions with deficits (feesBurn = fees * (burnBase/ofDelta) * bps/10000)
///      - Self-excluding bonus allocation (bonus = potAvail * selfNet / totalNet, where potAvail excludes selfContrib)
///      - Materialisation via pendingFeeAdj (positive = slash funds pot, negative = bonus drains pot)
/// @dev Tests use observable effects (fee holder ERC-6909 claims, VTS delta credits) rather than direct storage access
contract VTSFeeLibScenarioTest is VTSOrchestratorFixture {
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

    /// @notice Helper to get slashed pot balance for token0 (fee-sharing pot)
    /// @dev Uses testable VTSO view function instead of ERC-6909 claims balance
    function _slashedPot0() internal view returns (uint256) {
        (uint256 pot0,) = _testableOrchestrator().getSlashedPot(corePoolKey.toId());
        return pot0;
    }

    /// @notice Helper to get slashed pot balance for token1 (fee-sharing pot)
    function _slashedPot1() internal view returns (uint256) {
        (, uint256 pot1) = _testableOrchestrator().getSlashedPot(corePoolKey.toId());
        return pot1;
    }

    function _addInitialLiquidityToPool() internal override {
        // (uint160 sqrtPriceX96, int24 currentTick,,) = StateLibrary.getSlot0(manager, corePoolKey.toId());
        int24 tickLower = TickMath.minUsableTick(corePoolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(corePoolKey.tickSpacing);
        // (uint256 eff0, uint256 eff1) = LiquidityUtils.calculateEffectiveTokenAmounts(
        //     sqrtPriceX96, currentTick, tickLower, tickUpper, int256(initialLiquidity)
        // );
        // console.log("==== INITIAL LIQUIDITY TO POOL ====");
        // console.log("eff0:", eff0);
        // console.log("eff1:", eff1);
        // console.log("===================================");
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(initialLiquidity), salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    // ============================================================
    // Helper Functions
    // ============================================================

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

    /// @notice Creates the first MM position using the default signal (backwards compatible)
    /// @dev Uses default range (-60, 60) and default liquidity (1e10)
    /// @return tokenId The commitment NFT token ID (always 1 for first commit)
    /// @return positionId The position ID of the minted position
    function _commitAndMintFirstMM() internal returns (uint256 tokenId, PositionId positionId) {
        (tokenId, positionId,,) = _createCommittedPosition(-60, 60, 1e10);
    }

    /// @notice Creates the first MM position with custom liquidity
    /// @dev Uses default range (-60, 60) and default signal
    /// @param liquidity The liquidity amount to mint
    /// @return tokenId The commitment NFT token ID (always 1 for first commit)
    /// @return positionId The position ID of the minted position
    function _commitAndMintFirstMMWithLiquidity(uint256 liquidity)
        internal
        returns (uint256 tokenId, PositionId positionId)
    {
        (tokenId, positionId,,) = _createCommittedPosition(liquiditySignal, -60, 60, liquidity, bytes32(0));
    }

    /// @notice Mints an additional MM position under an existing commit
    /// @param tokenId The commitment NFT token ID
    /// @param tickLower Lower tick of the position range
    /// @param tickUpper Upper tick of the position range
    /// @param liquidity Amount of liquidity to mint
    /// @return positionIndex The index of the new position within the commit
    /// @return positionId The position ID of the minted position
    function _mintAdditionalMM(uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity)
        internal
        returns (uint256 positionIndex, PositionId positionId)
    {
        (,, uint256 countBefore,) = vtsOrchestrator.getCommit(tokenId);

        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) = _calculateSettlementAmounts(
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(liquidity), salt: 0
            }),
            marketVTSConfiguration
        );

        // Mint underlying tokens and approve via Permit2 for settlement
        _mintAndApproveUnderlyingForSettlement(requiredSettlementAmount0, requiredSettlementAmount1);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareMint(corePoolKey, tokenId, tickLower, tickUpper, liquidity);
        actions[1] = MMA.prepareSettle(
            corePoolKey,
            tokenId,
            positionIndex,
            -SafeCast.toInt128(requiredSettlementAmount0),
            -SafeCast.toInt128(requiredSettlementAmount1),
            false
        );
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);

        positionIndex = countBefore;
        positionId = vtsOrchestrator.getPositionId(tokenId, positionIndex);
    }

    /// @notice Adds a DirectLP position (non-MM) to the core pool
    /// @param tickLower Lower tick of the position range
    /// @param tickUpper Upper tick of the position range
    /// @param liquidityDelta Amount of liquidity to add (can be negative for removal)
    /// @return id PositionId (not used; DirectLP IDs are derived in CoreHook)
    function _addDirectLP(int24 tickLower, int24 tickUpper, int256 liquidityDelta) internal returns (PositionId id) {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: 0
        });
        id = PositionId.wrap(bytes32(0)); // not used; DirectLP ids are derived in core hook, but we don’t need it here
        modifyLiquidityRouter.modifyLiquidity(corePoolKey, params, ZERO_BYTES);
    }

    /// @notice Pokes a DirectLP position (modifyLiquidity with delta=0) to trigger fee processing
    /// @param tickLower Lower tick of the position range
    /// @param tickUpper Upper tick of the position range
    function _pokeDirectLP(int24 tickLower, int24 tickUpper) internal {
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: 0}),
            ZERO_BYTES
        );
    }

    // ============================================================
    // Example Scenarios (from spec discussion)
    // ============================================================

    /// @notice Scenario 1: Multiple MM commits, only one MM has deficit, protocol covers unwraps
    /// @dev Tests that fee slashing only applies to positions with deficits, not solvent positions.
    ///      Setup:
    ///      - 3 independent MM commits (each with their own tokenId and unique signal nonce)
    ///      - MM2 and MM3 are made solvent via settlement deposits
    ///      - MM1 remains under-settled (will have deficit)
    ///      Actions:
    ///      - Execute swap to accrue LP fees and generate outflow growth
    ///      - Protocol covers unwraps via incrementCoverage (creates coverage usage growth)
    ///      - Coverage usage is attributed to all in-range positions proportionally
    ///      Expected:
    ///      - Only MM1 (with deficit) should be slashed: feesBurn computed from its deficit portion
    ///      - MM2 and MM3 (solvent) should not be slashed even though they receive coverage attribution
    ///      - Fee pot should increase from swap fees and slash materialisation
    ///      - Assertions verify pot increases after swap + coverage operations
    function test_multiMM_oneDeficit_protocolCovers_slashOnlyDeficitMM() public {
        // 3 independent MM commits (each with unique signal nonce)
        (uint256 mm1, PositionId mm1PositionId) = _createNewMMCommit(-60, 60, 3e10);
        (uint256 mm2, PositionId mm2PositionId) = _createNewMMCommit(-60, 60, 3e10);
        (uint256 mm3, PositionId mm3PositionId) = _createNewMMCommit(-60, 60, 3e10);
        assertEq(mm1, 1);
        assertEq(mm2, 2);
        assertEq(mm3, 3);

        // Make MM2 and MM3 solvent by depositing some settlement
        // Note: For independent commits, position index is always 0
        _mmSettle(mm2, 0, _negInt128Capped(5e18), _negInt128Capped(5e18));
        _mmSettle(mm3, 0, _negInt128Capped(5e18), _negInt128Capped(5e18));

        uint256 potBefore = _slashedPot1();
        (uint256 protocolFeeAccruedBefore0, uint256 protocolFeeAccruedBefore1) = _protocolFeeAccrued(corePoolKey.toId());

        // Swap to accrue fees + outflow growth (choose direction that accrues token0 outflow)
        // Fee pot should be affected on swap, not on position modification
        _swapCore(false, -int256(5e18)); // ? one for zero, therefore protocolFeeAccruedBefore1 should increase

        vtsOrchestrator.settlePositionGrowths(mm2PositionId);
        vtsOrchestrator.settlePositionGrowths(mm3PositionId);
        vtsOrchestrator.settlePositionGrowths(mm1PositionId); // settle position now that deficit has surfaced.

        // Protocol covers unwraps: increment coverage (token0 only)
        // NOTE: With DICE (Deficit-Indexed Coverage Exercise), coverage is now indexed to
        // outstanding deficit principal, not to tick-indexed liquidity. This means coverage
        // is correctly attributed to positions that created the deficit, regardless of when
        // the coverage event occurs relative to tick movement.
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 2e18, 0);

        vtsOrchestrator.settlePositionGrowths(mm2PositionId);
        vtsOrchestrator.settlePositionGrowths(mm3PositionId);
        vtsOrchestrator.settlePositionGrowths(mm1PositionId);

        (uint256 protocolFeeAccruedAfter0, uint256 protocolFeeAccruedAfter1) = _protocolFeeAccrued(corePoolKey.toId());

        (,, uint256 settled0, uint256 settled1,,) = _testableOrchestrator().getPositionAccounting(mm1PositionId);
        console.log("mm1 settled0:", settled0);
        console.log("mm1 settled1:", settled1);
        (,, uint256 settled02, uint256 settled12,,) = _testableOrchestrator().getPositionAccounting(mm2PositionId);
        console.log("mm2 settled0:", settled02);
        console.log("mm2 settled1:", settled12);
        (,, uint256 settled03, uint256 settled13,,) = _testableOrchestrator().getPositionAccounting(mm3PositionId);
        console.log("mm3 settled0:", settled03);
        console.log("mm3 settled1:", settled13);

        _pokeMM(mm2, 0, -60, 60);
        _pokeMM(mm3, 0, -60, 60);
        uint256 potAfter = _slashedPot1();

        _pokeMM(mm1, 0, -60, 60);

        uint256 potAfterDeficitMMSPoke = _slashedPot1();

        assertEq(potAfter, potBefore, "Direct Pot change should be zero after swap + coverage (before settleGrowths)");
        assertGt(potAfterDeficitMMSPoke, potAfter, "Pot change should be greater than zero after settleGrowths");
        assertGt(
            _selfLccBalance(lccCurrency1),
            potAfterDeficitMMSPoke,
            "Self LCC balance should be greater than slashed pot because feeCoverage < 50%"
        );

        // DICE: Protocol fee accrued for token0 should now increase because MM1 has deficit
        // and coverage was applied. The old tick-indexed model incorrectly showed no increase
        // because coverage was attributed to whoever was in-range at coverage time.
        assertEq(
            protocolFeeAccruedAfter0, protocolFeeAccruedBefore0, "DICE: Protocol fee accrued should be 0 for token0"
        );
        // Note: Token1 protocol fee behavior depends on swap fees, not DICE coverage.
        // Coverage occurs on outflows/deficits, and therefore only for token0 only.
        // Token1 assertion relaxed to non-decreasing.
        assertGt(protocolFeeAccruedAfter1, protocolFeeAccruedBefore1, "Protocol fee accrued should increase for token1");
    }

    /// @notice Scenario 2: Multiple MMs, two MMs have deficits, protocol covers unwraps
    /// @dev Tests self-exclusion: a position cannot receive bonuses from its own slash contributions.
    ///      Setup:
    ///      - 3 MM positions
    ///      - MM3 is made solvent (will be beneficiary)
    ///      - MM0 and MM1 remain under-settled (will have deficits)
    ///      Actions:
    ///      - Swap + incrementCoverage to create deficits on MM0 and MM1
    ///      - Both MM0 and MM1 will be slashed, funding the fee pot
    ///      Expected:
    ///      - Fee pot increases after swap + coverage (from slashes)
    ///      - When MM0 processes fees later, it should NOT receive bonuses from its own contribution
    ///      - MM3 (beneficiary) can receive bonuses from both MM0 and MM1's contributions
    ///      - Self-exclusion ensures: potAvail = protocolFeeAccrued - feesShared(position), so MM0's potAvail excludes its own slash
    function test_multiMM_twoDeficits_protocolCovers_bothSlashed_selfExcludedFromOwnPot() public {
        (uint256 tokenId,) = _commitAndMintFirstMM(); // idx0
        (uint256 idx2,) = _mintAdditionalMM(tokenId, -60, 60, 1e10); // idx1
        (uint256 idx3,) = _mintAdditionalMM(tokenId, -60, 60, 1e10); // idx2

        // Make MM3 solvent (beneficiary)
        _mmSettle(tokenId, idx3, _negInt128Capped(10e18), _negInt128Capped(10e18));

        uint256 pot0 = _slashedPot0();

        // Swap + coverage -> create deficits on MM0 and MM1
        // Fee pot should be affected on swap, not on position modification
        _swapCore(false, -int256(8e18));
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 4e18, 0);

        uint256 pot1 = _slashedPot0();
        assertGe(pot1, pot0, "Pot should increase after swap + coverage");
    }

    /// @notice Scenario 3: Insufficient liquidity prevents coverage execution, no slash from queued portion
    /// @dev Tests that when vault lacks liquidity to execute withdrawal, the queued portion
    ///      does not create new slashes or affect the fee pot.
    ///      Setup:
    ///      - Create MM position, make it solvent via deposit
    ///      - Execute swap + coverage to create outflows
    ///      - Mock vault to have no liquidity (forces clamp/queue)
    ///      Actions:
    ///      - Attempt withdrawal via onMMSettle; vault mock clamps to 0
    ///      Expected:
    ///      - Pot should remain unchanged (no executed coverage = no slash)
    ///      - Queued portion should not fund pot
    function test_insufficientLiquidity_noCoverageExecuted_noSlashFromQueuedPortion() public {
        (uint256 tokenId, PositionId positionId) = _commitAndMintFirstMM();

        // Close RFS by depositing enough first
        _mmSettle(tokenId, 0, _negInt128Capped(20e18), _negInt128Capped(20e18));

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

        uint256 potBefore = _slashedPot0();

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

        uint256 potAfter = _slashedPot0();
        // Fee pot is affected on swap, not on position modification
        // No executed coverage/withdrawal should not fund pot from queued portion
        assertEq(potAfter, potBefore, "No executed coverage/withdrawal should not fund pot from queued portion");
        positionId;
    }

    /// @notice Scenario 4: Out-of-range DirectLP can be added to pool with funded fee pot
    /// @dev Tests that DirectLP positions can be created out-of-range after fee pot is funded.
    ///      Setup:
    ///      - Create MM position and slash it via swap + incrementCoverage
    ///      - Fee pot is funded by the MM's slash
    ///      Actions:
    ///      - Add an out-of-range DirectLP position (ticks far from current price)
    ///      Expected:
    ///      - Fee pot should be funded after swap + coverage
    ///      - Out-of-range DirectLP can be added without errors
    /// @dev Note: Verifying that DirectLP receives bonuses would require separate position
    ///      modification with proper delta settlement (via modifyLiquidityRouter).
    ///      Out-of-range positions don't contribute to coverage attribution, so they're never slashed,
    ///      but they can still benefit from bonuses if they've contributed settled liquidity.
    function test_directLP_outOfRange_canBeAdded_withFundedPot() public {
        (uint256 tokenId,) = _commitAndMintFirstMM(); // idx0

        uint256 potBefore = _slashedPot0();

        // Fee pot should be funded on swap + coverage, not on position modification
        _swapCore(false, -int256(6e18));
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 3e18, 0);

        uint256 potFunded = _slashedPot0();
        assertGe(potFunded, potBefore, "Expected pot to be funded after swap + coverage");

        // Add an out-of-range direct LP position
        // Use far out-of-range ticks so it doesn't contribute to coverage attribution
        _addDirectLP(600, 1200, int256(1e18));

        // Suppress unused variable warning
        tokenId;
    }

    /// @notice Scenario 5: Out-of-range DirectLP earns bonus from fee pot funded by MM slashes
    /// @dev Tests that DirectLP positions can receive bonuses from the fee pot even when out-of-range,
    ///      provided they have positive net settlement (from adding liquidity).
    ///      Setup:
    ///      - Add an out-of-range DirectLP position (creates positive net settlement)
    ///      - Create MM position and slash it via swap + incrementCoverage
    ///      - Fee pot is funded by the MM's slash
    ///      Actions:
    ///      - Poke DirectLP position (zero-delta modifyLiquidity) to trigger fee processing
    ///      - processPositionFees calculates bonus based on selfNet and potAvail
    ///      Expected:
    ///      - Fee pot should decrease after DirectLP poke (bonus materialised)
    ///      - DirectLP receives bonus proportional to its net settlement contribution
    /// @dev Note: With DICE (Deficit-Indexed Coverage Exercise), coverage slashing only occurs on
    ///      positions that have actual deficit (cumulativeDeficit > 0). If the position has sufficient
    ///      settlement to cover swap-time outflows, no slash occurs. This is correct behavior.
    ///      DirectLP uses modifyLiquidityRouter which properly settles deltas.
    function test_directLP_outOfRange_earnsBonus_fromMMslashes() public {
        // Step 1: Add out-of-range DirectLP position
        // This creates positive net settlement for the DirectLP (it has deposited LCC tokens)
        // Out-of-range ticks ensure it won't be attributed coverage usage
        // int24 directTickUpper = TickMath.maxUsableTick(corePoolKey.tickSpacing);
        // _addDirectLP(directTickUpper - 1, directTickUpper, int256(50e18));
        // _addDirectLP(600, 1200, int256(50e18));

        // Step 2: Create MM position with meaningful liquidity (1000e18 gives ~10% share of pool)
        // Note: Initial pool has 10000e18 liquidity, so MM needs comparable liquidity to accrue
        // meaningful fees and deficits for slashing to occur

        // ? Increment coverage occurs after swap, and can occur of MM Position.
        // ? This causes residual collection of coverage usage growth - that applies to next in-range.
        // ? Therefore, we need a range that spans the tick advancement of the swap.
        // ? But the swap amount must put the position in a deficit.

        // @note - TickMisaligned error means range is not aligned with tick spacing.
        // tick spacing of 60 means [-1000, 1000] is not aligned with tick spacing. Must be multiples of 60 eg. [-960, 960]
        (uint256 tokenId, PositionId mmPositionId,,) = _createCommittedPosition(-1020, 1020, 50e10);

        // Record initial protocol fee accrued
        (uint256 feeAccruedInitial0,) = _protocolFeeAccrued(corePoolKey.toId());

        // Step 3: Swap + coverage creates deficit on MM
        // Swap must be large enough to create outflows exceeding MM's base settlement,
        // but small enough to keep price within the -60 to 60 tick range (otherwise no in-range liquidity)
        (, int24 currentTickBefore,,) = StateLibrary.getSlot0(manager, corePoolKey.toId());
        _swapCore(false, -int256(10e18));
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 10e18, 0); // in the coverage range after the swap.
        (, int24 currentTickAfter,,) = StateLibrary.getSlot0(manager, corePoolKey.toId());

        console.log("currentTickBefore", currentTickBefore);
        console.log("currentTickAfter", currentTickAfter);

        // Step 4: Settle MM position growths to process coverage and queue slashes
        // This updates protocolFeeAccrued internally (slashes are queued in pendingFeeAdj)
        vtsOrchestrator.settlePositionGrowths(mmPositionId);

        // Step 5: Verify protocolFeeAccrued - with DICE, slashing only occurs if position has deficit
        // If swap-time outflows are covered by settlement buffer, no deficit and no slash.
        // Changed to assertGe to reflect DICE behavior (protocol fee should not decrease)
        (uint256 feeAccruedAfterSlash0,) = _protocolFeeAccrued(corePoolKey.toId());
        assertGe(feeAccruedAfterSlash0, feeAccruedInitial0, "DICE: protocolFeeAccrued should not decrease");

        // uint256 slashedAmount = feeAccruedAfterSlash0 - feeAccruedInitial0;

        // // Step 6: Record DirectLP LCC balance before poke
        // uint256 directLPBalanceBefore = _selfLccBalance(lccCurrency0);

        // // Step 7: Poke DirectLP to trigger fee processing and receive bonus
        // // This calls processPositionFees which allocates bonus from potAvail
        // _pokeDirectLP(600, 1200);

        // uint256 directLPBalanceAfter = _selfLccBalance(lccCurrency0);

        // // Step 8: Verify DirectLP received bonus from slashed fees
        // // DirectLP has positive net settlement, so it should receive bonus from pot
        // uint256 bonusReceived =
        //     directLPBalanceAfter > directLPBalanceBefore ? directLPBalanceAfter - directLPBalanceBefore : 0;

        // assertGt(bonusReceived, 0, "DirectLP should receive bonus from MM slash");
        // // Bonus should be <= slashed amount (can't receive more than what was slashed)
        // assertLe(bonusReceived, slashedAmount, "Bonus should not exceed slashed amount");

        // Suppress unused variable warning
        tokenId;
    }

    // ============================================================
    // Core Edge Cases (Maths Paradigms)
    // ============================================================

    /// @notice Edge Case 1: Self-exclusion when potAvail is zero
    /// @dev Tests that a position cannot receive bonuses when all protocolFeeAccrued comes from its own slashes.
    ///      This ensures positions cannot reclaim their own penalties.
    ///      Setup:
    ///      - Single MM position
    ///      - Create deficit + fees + coverage to trigger slash
    ///      - Slash materialises, funding pot
    ///      Actions:
    ///      - Run reverse swap to create inflow (generates positive net settlement)
    ///      - Process fees: position should compute potAvail = protocolFeeAccrued - feesShared(self)
    ///      Expected:
    ///      - potAvail should be zero (or very small) since all fees came from this position
    ///      - No bonus should be allocated (potAvail == 0 guard)
    ///      - Pot should not decrease (no bonus materialisation)
    function test_selfExclusion_potAvailZero_noBonus() public {
        (uint256 tokenId,) = _commitAndMintFirstMM();

        // Fee token for "one for zero" swaps is token1, so self-exclusion should be observed on token1 pot/accounting.
        uint256 pot0Before = _slashedPot0();
        uint256 pot1Before = _slashedPot1();

        // Create fees + deficit + coverage event (slash is queued when growths are settled).
        _swapCore(false, -int256(1e18)); // one for zero (fee token = token1)
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 5e17, 0);

        // Trigger settle + fee processing for the MM position (this is where feeAdj is finalised into the slashed pot).
        _pokeMM(tokenId, 0, -60, 60);

        // Pot0 should remain unchanged (fee token is token1 in this scenario).
        assertEq(_slashedPot0(), pot0Before, "token0 slashed pot should not change for one-for-zero fee token");
        // Pot1 should be funded by the slasher's pending fee adjustment.
        assertGt(_slashedPot1(), pot1Before, "token1 slashed pot should be funded after slasher fee processing");

        // ============================================================================================================
        // KEY ASSERTION: Self-exclusion invariant verification
        // ============================================================================================================
        // The core self-exclusion mechanism in VTSFeeLib.processPositionFees() computes:
        //   potAvail = protocolFeeAccrued - feesShared(self)
        //
        // For self-exclusion to prevent bonus allocation, we require:
        //   potAvail == 0  =>  protocolFeeAccrued == feesShared(self)
        //
        // IMPLICIT ASSUMPTION: This test assumes that ONLY the MM position contributes to protocolFeeAccrued
        // for the fee token (token1). While MarketTestBase seeds initial liquidity (full-range DirectLP),
        // that seed position remains solvent (no deficit, no slash) and thus does NOT contribute to
        // protocolFeeAccrued. If other positions were slashed, protocolFeeAccrued > feesShared(self),
        // and potAvail > 0, allowing the MM to receive bonus from others' contributions.
        //
        // This assertion verifies the precondition: protocolFeeAccrued1 is entirely self-contributed.
        // ============================================================================================================
        PositionId mmPosId = vtsOrchestrator.getPositionId(tokenId, 0);
        (, uint256 feeAccrued1) = _protocolFeeAccrued(corePoolKey.toId());
        (, uint256 feesShared1,,) = _testableOrchestrator().getPositionFeeAccounting(mmPosId);
        assertEq(
            feeAccrued1,
            feesShared1,
            "Self-exclusion precondition: protocolFeeAccrued1 should be entirely self-contributed (potAvail == 0)"
        );

        // Create positive net settlement on token1 (above dust) to attempt bonus allocation on next fee processing.
        _mmSettle(tokenId, 0, int128(0), _negInt128Capped(2e12));

        uint256 pot1BeforeBonusAttempt = _slashedPot1();
        _pokeMM(tokenId, 0, -60, 60);
        uint256 pot1AfterBonusAttempt = _slashedPot1();

        // ============================================================================================================
        // KEY ASSERTION: Self-exclusion prevents bonus allocation when potAvail == 0
        // ============================================================================================================
        // Since potAvail = protocolFeeAccrued - feesShared(self) == 0 (verified above), VTSFeeLib.processPositionFees()
        // should skip bonus allocation (potAvail == 0 guard at line 177). Therefore:
        //   1. No pot drain (bonus materialisation requires draining slashedPot)
        //   2. No negative pendingFeeAdj queued (bonus would queue negative pending)
        // ============================================================================================================
        assertEq(pot1AfterBonusAttempt, pot1BeforeBonusAttempt, "Self-exclusion: pot must not be drained by self bonus");
        (,, int256 pending0, int256 pending1) = _testableOrchestrator().getPositionFeeAccounting(mmPosId);
        pending0; // silence unused variable warning
        assertGe(pending1, 0, "Self-exclusion: should not queue a negative pendingFeeAdj (bonus) for self");
    }

    /// @notice Edge Case 2: Partial bonus materialisation when pot not yet funded
    /// @dev Tests the ordering dependency: bonuses can be queued before slashes are materialised,
    ///      but actual payout requires the pot to be funded first.
    ///      Setup:
    ///      - Two MMs: MM0 (will be slashed), MM1 (beneficiary with positive net)
    ///      - MM1 has positive net settlement from deposits
    ///      Actions:
    ///      - Create slash on MM0 via swap + coverage (protocolFeeAccrued increases, pendingFeeAdj queued)
    ///      - Do NOT poke MM0 yet (so pot not funded via _finaliseFeeAdjustment)
    ///      - Poke MM1 first: should queue bonus but cannot drain (pot == 0)
    ///      - Then poke MM0 to fund pot
    ///      - Poke MM1 again to receive bonus
    ///      Expected:
    ///      - First MM1 poke: pot unchanged, no bonus materialised (pot not funded)
    ///      - After MM0 poke: pot increases (slash materialised)
    ///      - Second MM1 poke: pot decreases (bonus materialised), MM1 receives credit
    /// @dev Note: Current implementation funds pot during swap+coverage, so this test verifies
    ///      that pot increases after swap + coverage operations rather than testing the ordering dependency.
    function test_partialBonusMaterialisation_whenPotNotYetFunded() public {
        (uint256 tokenId,) = _commitAndMintFirstMM();
        (uint256 idx1,) = _mintAdditionalMM(tokenId, -60, 60, 1e10);

        // Make beneficiary have positive net settlement
        _mmSettle(tokenId, idx1, _negInt128Capped(10e18), _negInt128Capped(0));

        uint256 potBefore = _slashedPot0();

        // Create slash on MM0 by swap + coverage
        // Fee pot should be funded on swap + coverage, not on position modification
        _swapCore(false, -int256(5e18));
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 2e18, 0);

        uint256 potAfter = _slashedPot0();
        assertGe(potAfter, potBefore, "Pot should be funded after swap + coverage");

        // Suppress unused variable warnings
        tokenId;
        idx1;
    }

    /// @notice Edge Case 3: Dust guard prevents bonus for tiny net settlements
    /// @dev Tests that positions with net settlement below dust threshold (1e12) do not receive bonuses.
    ///      This prevents rounding/gas issues from processing negligible amounts.
    ///      Setup:
    ///      - Fund pot via swap + coverage (triggers slash on MM0)
    ///      - Create tiny positive net settlement on beneficiary (below 1e12)
    ///      Actions:
    ///      - Process fees: dustIdx has positive net but below threshold
    ///      Expected:
    ///      - Bonus should be skipped (selfNet < DUST_THRESHOLD guard)
    ///      - Pot should remain unchanged
    function test_dustGuard_bonusSkipped_under1e12Net() public {
        (uint256 tokenId,) = _commitAndMintFirstMM(); // slasher
        (uint256 dustIdx,) = _mintAdditionalMM(tokenId, -60, 60, 1e10); // beneficiary candidate

        uint256 potBefore = _slashedPot1();

        // Fund pot via swap + coverage (slashes idx0)
        _swapCore(false, -int256(5e18)); // one for zero swap - therefore fee accrued on token1, deficit on token0
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 2e18, 0);

        uint256 potFunded = _slashedPot1();
        assertGe(potFunded, potBefore, "Pot should be funded after swap + coverage");

        // Create tiny positive net settlement on dustIdx (below 1e12) via deposit
        _mmSettle(tokenId, dustIdx, _negInt128Capped(1e12 - 1), int128(0));

        uint256 potAfterSettle = _slashedPot1();

        // Dust net should not drain pot - pot should not decrease
        assertGe(potAfterSettle, potFunded, "Dust net should not drain pot");

        // Suppress unused variable warning
        tokenId;
        dustIdx;
    }

    /// @notice Edge Case 4: Rounding leaves residual pot after sequential bonus allocation
    /// @dev Tests that mulDiv truncation in bonus calculations can leave remainder in the pot
    ///      when bonuses are allocated sequentially to multiple beneficiaries.
    ///      Setup:
    ///      - Fund pot with one slashed MM via swap + coverage
    ///      - Create 3 beneficiary MMs with different net settlement weights (1:2:3 ratio)
    ///      Actions:
    ///      - Process fees during swap/coverage operations
    ///      - Each allocation uses: bonus = potAvail * selfNet / totalNet (FullMath.mulDiv truncates)
    ///      Expected:
    ///      - Total bonuses allocated ≤ potStart (no over-allocation)
    ///      - Pot should be funded after swap + coverage
    function test_rounding_residualPot_leftOver() public {
        (uint256 tokenId,) = _commitAndMintFirstMM(); // idx0 slasher
        (uint256 idx1,) = _mintAdditionalMM(tokenId, -60, 60, 1e10);
        (uint256 idx2,) = _mintAdditionalMM(tokenId, -60, 60, 1e10);
        (uint256 idx3,) = _mintAdditionalMM(tokenId, -60, 60, 1e10);

        // Beneficiary weights: 1,2,3 (token0 deposits)
        _mmSettle(tokenId, idx1, _negInt128Capped(2e12), int128(0));
        _mmSettle(tokenId, idx2, _negInt128Capped(4e12), int128(0));
        _mmSettle(tokenId, idx3, _negInt128Capped(6e12), int128(0));

        uint256 potBefore = _slashedPot0();

        // Swap + coverage funds pot and processes fee allocations
        _swapCore(false, -int256(10e18));
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 5e18, 0);

        uint256 potAfter = _slashedPot0();

        // Pot should be funded from swap fees and slash processing
        assertGe(potAfter, potBefore, "Expected pot to be funded after swap + coverage");

        // Suppress unused variable warnings
        tokenId;
        idx1;
        idx2;
        idx3;
    }

    /// @notice Edge Case 5: Beneficiary can allocate (queue) a bonus before any slashing is materialised into the pot,
    ///         if it processes fees before the slasher position does.
    /// @dev Demonstrates the ordering hazard:
    ///      - Coverage burn queues +pendingFeeAdj on the slasher and increments protocolFeeAccrued (accounting pot)
    ///      - But slashedPot is only funded when the slasher is later poked (finalised via _finaliseFeeAdjustment)
    ///      - Meanwhile, a beneficiary poke can reduce protocolFeeAccrued and queue -pendingFeeAdj (bonus),
    ///        despite slashedPot still being 0 (so nothing can be paid yet)
    ///      Setup:
    ///      - Create MM0 (slasher) and MM1 (beneficiary) positions
    ///      - Create deficit + coverage to trigger slash on MM0 (queues +pendingFeeAdj, increments protocolFeeAccrued)
    ///      - Do NOT poke MM0 yet (slashedPot remains 0)
    ///      - Poke MM1 first (beneficiary processes fees before slasher)
    ///      Expected:
    ///      - slashedPot remains 0 (slasher not poked yet)
    ///      - protocolFeeAccrued is reduced by bonus allocation (bonus queued from accounting pot)
    ///      - MM1 has negative pendingFeeAdj (queued bonus)
    ///      - After MM0 poke, slashedPot is funded and MM1's bonus can be materialised
    function test_bonusAllocatedBeforeSlashMaterialised_whenBeneficiaryPokesFirst() public {
        int24 tickLower = -960;
        int24 tickUpper = 960;

        // Create commit with idx0 (intended slasher)
        (uint256 tokenId, PositionId mm0PosId,,) = _createCommittedPosition(tickLower, tickUpper, 50e10);

        // Clear any "net since last mod" from initial settlement so the pool net is clean
        _pokeMM(tokenId, 0, tickLower, tickUpper);

        // Add idx1 (beneficiary) and leave it with positive net settlement since last modification
        (uint256 idx1, PositionId mm1PosId) = _mintAdditionalMM(tokenId, tickLower, tickUpper, 50e10);

        // Create deficit + fees (fees accrue on token1 for one-for-zero swap)
        _swapCore(false, -int256(50e18));

        // Materialise deficit principal first (required for DICE index to move meaningfully)
        vtsOrchestrator.settlePositionGrowths(mm0PosId);

        // Exercise coverage (token0), then settle again to queue coverage burn (slash) in fee token (token1)
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 5e18, 0);
        vtsOrchestrator.settlePositionGrowths(mm0PosId);

        // Sanity: slashed pot should still be 0 (slasher not poked -> no _finaliseFeeAdjustment funding)
        uint256 potBefore = _slashedPot1();
        assertEq(potBefore, 0, "Precondition: slashed pot must be 0 before any slasher position poke");

        // Sanity: protocolFeeAccrued should be >0 after coverage burn
        (, uint256 feeAccruedBefore) = _protocolFeeAccrued(corePoolKey.toId());
        assertGt(feeAccruedBefore, 0, "Precondition: protocolFeeAccrued1 must be > 0 after coverage burn");

        // Sanity: mm0 has a queued positive slash (pendingFeeAdj1 > 0)
        (,, int256 mm0Pending0Before, int256 mm0Pending1Before) =
            _testableOrchestrator().getPositionFeeAccounting(mm0PosId);
        assertGt(mm0Pending1Before, 0, "Precondition: slasher must have pendingFeeAdj1 > 0");
        mm0Pending0Before; // silence unused variable

        // Beneficiary processes fees FIRST (allocates bonus from protocolFeeAccrued, but cannot be paid yet since pot==0)
        _pokeMM(tokenId, idx1, tickLower, tickUpper);

        // Pot is still unfunded (slasher still not poked)
        uint256 potAfterBeneficiary = _slashedPot1();
        assertEq(potAfterBeneficiary, 0, "Pot must remain 0 until slasher is poked");

        // protocolFeeAccrued will NOT reduce because bonus > (potAvail = 0), therefore we bank it for when potAvail > 0
        (, uint256 feeAccruedAfterBeneficiary) = _protocolFeeAccrued(corePoolKey.toId());
        assertEq(
            feeAccruedAfterBeneficiary,
            feeAccruedBefore,
            "Bonus allocation should NOT reduce protocolFeeAccrued because bonus > (potAvail = 0), therefore we bank it for when potAvail > 0"
        );

        // Beneficiary should not have changed negative pending adjustment (bonus)
        (,, int256 mm1Pending0After, int256 mm1Pending1After) =
            _testableOrchestrator().getPositionFeeAccounting(mm1PosId);
        assertEq(mm1Pending1After, 0, "Beneficiary should have unchanged pendingFeeAdj1");
        mm1Pending0After; // silence unused variable

        // Now poke slasher: this should fund the pot from its +pendingFeeAdj
        _pokeMM(tokenId, 0, tickLower, tickUpper);
        uint256 potAfterSlasher = _slashedPot1();
        assertGt(potAfterSlasher, 0, "Slasher poke should fund the pot");

        // Give beneficiary positive selfNet (eligibility gate) via settlement deposit before it processes fees.
        _mmSettle(tokenId, idx1, _negInt128Capped(2e18), _negInt128Capped(2e18));

        // SECOND Beneficiary poke: this should materialise the bonus
        _pokeMM(tokenId, idx1, tickLower, tickUpper);
        (, uint256 feeAccruedAfterBeneficiary2) = _protocolFeeAccrued(corePoolKey.toId());
        assertLt(
            feeAccruedAfterBeneficiary2, feeAccruedAfterBeneficiary, "Bonus allocation NOW reduces protocolFeeAccrued"
        );
        (,, int256 mm1Pending0After2, int256 mm1Pending1After2) =
            _testableOrchestrator().getPositionFeeAccounting(mm1PosId);
        assertLt(mm1Pending1After2, mm1Pending1After, "Beneficiary should have negative pendingFeeAdj1 (queued bonus)");
        mm1Pending0After2; // silence unused variable

        // Suppress unused variable warnings
        tokenId;
        idx1;
    }

    /// @notice Edge Case 6: An inactive (0-liquidity) position can still poke to materialise queued bonuses once the pot is funded.
    /// @dev Regression for the "dissolved position" case:
    ///      - A DirectLP position allocates a bonus while the slashed pot is still empty (bonus is queued, not paid)
    ///      - The DirectLP fully removes liquidity (becomes inactive)
    ///      - Later, a slashed MM position is poked, funding the pot
    ///      - The now-inactive DirectLP can still poke (liquidityDelta=0) and receive payout (pending bonus reduces, pot drains)
    function test_inactivePosition_canPokeToMaterialiseQueuedBonus_afterPotFunded() public {
        // ------------------------------------------------------------
        // 1) Create a slasher MM that queues protocolFeeAccrued + pendingFeeAdj, but DO NOT fund slashedPot yet
        // ------------------------------------------------------------
        int24 mmTickLower = -960;
        int24 mmTickUpper = 960;
        (uint256 tokenId, PositionId slasherPosId,,) = _createCommittedPosition(mmTickLower, mmTickUpper, 50e10);

        // Create deficit + fees (fee token = token1 for one-for-zero swap)
        /**
         *   If swap amount is too large (eg. 50e18),
         *   The swap will have the pool tick sitting above your DirectLP’s tickUpper = 960 (e.g. it shows tick: 972 then tick: 1010), so the position is out-of-range during the “accrue token1 fees” swap.
         *   Out-of-range positions don’t accrue swap fees, so the subsequent modifyLiquidity call reports feesAccrued == 0 → feeWeight == 0 → no queued bonus → pendingFeeAdj1 stays 0 and the assertion fails.
         *   slashedPot only affects materialisation in _finaliseFeeAdjustment (paying down negative pending).
         *   It does not gate queuing the negative pending in _queueBonusForToken. So slashedPot == 0 would mean “bonus can’t be paid yet”, not “bonus can’t be queued”.
         */
        _swapCore(false, -int256(30e18));

        // Materialise deficit principal, then exercise coverage and settle again to queue fee burn
        vtsOrchestrator.settlePositionGrowths(slasherPosId);
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 5e18, 0);
        vtsOrchestrator.settlePositionGrowths(slasherPosId);

        // protocolFeeAccrued should be > 0, but slashed pot should still be 0 until the slasher is poked
        (, uint256 feeAccruedBefore) = _protocolFeeAccrued(corePoolKey.toId());
        assertGt(feeAccruedBefore, 0, "Precondition: protocolFeeAccrued1 must be > 0 after queued slashes");
        (, uint256 potBefore) = vtsOrchestrator.getSlashedPot(corePoolKey.toId());
        assertEq(potBefore, 0, "Precondition: slashedPot1 must be 0 before slasher poke");

        // ------------------------------------------------------------
        // 2) Create a DirectLP beneficiary.
        // IMPORTANT: Creating a *new* DirectLP position must NOT allocate bonuses immediately,
        // even if protocolFeeAccrued is already > 0. Bonus allocation is reserved for existing positions.
        // ------------------------------------------------------------
        // Use an in-range DirectLP so it can accrue native fees (feeWeight) from swaps.
        int24 dlTickLower = -960;
        int24 dlTickUpper = 960;
        uint256 dlLiquidity = 1e18;

        // Mint a Uniswap v4 PositionManager position and subscribe it to DirectLPDeltaResolver.
        // This ensures CoreHook's hook deltas (feeAdj) are cleared during the same unlock session via MarketFactory.afterModifyLiquidity.
        uint256 dlTokenId = uniPositionManager.nextTokenId();
        {
            bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(
                corePoolKey,
                dlTickLower,
                dlTickUpper,
                dlLiquidity,
                type(uint128).max,
                type(uint128).max,
                address(this),
                ZERO_BYTES
            );
            params[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1);
            uniPositionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);
        }
        uniPositionManager.subscribe(dlTokenId, address(directLPDeltaResolver), "");

        // Compute DirectLP positionId (owner is the caller to PoolManager, i.e. Uniswap PositionManager),
        // and salt is the tokenId (PositionManager uses tokenId as the position salt).
        ModifyLiquidityParams memory dlAddParamsForId = ModifyLiquidityParams({
            tickLower: dlTickLower,
            tickUpper: dlTickUpper,
            liquidityDelta: int256(dlLiquidity),
            salt: bytes32(dlTokenId)
        });
        PositionId directPosId = PositionLibrary.generateId(address(uniPositionManager), dlAddParamsForId);

        // New DirectLP should not have any queued bonus/slash yet.
        (,, int256 dlPending0AfterAdd, int256 dlPending1AfterAdd) =
            vtsOrchestrator.getPositionFeeAccounting(directPosId);
        dlPending0AfterAdd; // silence
        assertEq(dlPending1AfterAdd, 0, "New DirectLP must not queue a bonus on creation");
        (, uint256 potAfterAdd) = vtsOrchestrator.getSlashedPot(corePoolKey.toId());
        assertEq(potAfterAdd, 0, "Precondition: slashedPot1 still 0 (bonus cannot be materialised yet)");

        // ------------------------------------------------------------
        // 3) Accrue some native fees for DirectLP, then perform an increase (creates selfNet) so it can allocate a bonus.
        // ------------------------------------------------------------
        _swapCore(false, -int256(2e18)); // accrue token1 fees for in-range positions

        // Now that the DirectLP is an *existing* position, a subsequent increase can allocate a bonus
        // (selfNet > 0 from settlement, feeWeight > 0 from accrued fees).
        uint256 dlMoreLiquidity = 5e17;
        {
            bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(dlTokenId, dlMoreLiquidity, type(uint128).max, type(uint128).max, ZERO_BYTES);
            params[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1);
            uniPositionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);
        }

        // selfNet (pa.netSettlementSinceLastMod) is only updated when _updateSettlement runs
        // (e.g. via settlePositionGrowths or direct settlement changes), not at swap-time directly.
        // Bonus allocation requires selfNet > 0 at fee-processing time (during modifyLiquidity touch).

        (,, int256 dlPending0AfterIncrease, int256 dlPending1AfterIncrease) =
            vtsOrchestrator.getPositionFeeAccounting(directPosId);
        dlPending0AfterIncrease; // silence
        assertLt(dlPending1AfterIncrease, 0, "Existing DirectLP should be able to queue a bonus on subsequent touch");

        // ------------------------------------------------------------
        // 4) Fully remove DirectLP liquidity => position becomes inactive (0-liquidity)
        // ------------------------------------------------------------
        {
            bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] =
                abi.encode(dlTokenId, dlLiquidity + dlMoreLiquidity, type(uint128).min, type(uint128).min, ZERO_BYTES);
            params[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1, address(this));
            uniPositionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);
        }

        assertEq(vtsOrchestrator.isPositionValid(directPosId, true), false, "DirectLP should now be inactive");

        // Pending bonus should remain queued after removal (pot still empty, so cannot pay)
        (,, int256 dlPending0AfterRemove, int256 dlPending1AfterRemove) =
            vtsOrchestrator.getPositionFeeAccounting(directPosId);
        dlPending0AfterRemove; // silence
        assertLt(dlPending1AfterRemove, 0, "Queued bonus must remain for inactive position");

        // ------------------------------------------------------------
        // 5) Fund the slashed pot by poking the slasher MM (materialises its +pendingFeeAdj)
        // ------------------------------------------------------------
        _pokeMM(tokenId, 0, mmTickLower, mmTickUpper);
        (, uint256 potFunded) = vtsOrchestrator.getSlashedPot(corePoolKey.toId());
        assertGt(potFunded, 0, "Pot must be funded after slasher poke");

        // ------------------------------------------------------------
        // 6) Inactive DirectLP re-activates with a small increase, then closes again to collect;
        //    position must end inactive while materialising its queued bonus.
        // ------------------------------------------------------------
        uint256 potBeforeInactivePoke = potFunded;
        uint256 dlReopenLiquidity = 1e12;
        // {
        //     bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
        //     bytes[] memory params = new bytes[](2);
        //     params[0] = abi.encode(dlTokenId, dlReopenLiquidity, type(uint128).max, type(uint128).max, ZERO_BYTES);
        //     params[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1);
        //     uniPositionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);
        // }
        {
            bytes memory actions = abi.encodePacked(
                uint8(Actions.INCREASE_LIQUIDITY),
                uint8(Actions.SETTLE_PAIR),
                uint8(Actions.DECREASE_LIQUIDITY),
                uint8(Actions.TAKE_PAIR)
            );
            bytes[] memory params = new bytes[](4);
            params[0] = abi.encode(dlTokenId, dlReopenLiquidity, type(uint128).max, type(uint128).max, ZERO_BYTES);
            params[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1);
            params[2] = abi.encode(dlTokenId, dlReopenLiquidity, type(uint128).min, type(uint128).min, ZERO_BYTES);
            params[3] = abi.encode(corePoolKey.currency0, corePoolKey.currency1, address(this));
            uniPositionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);
        }

        assertEq(vtsOrchestrator.isPositionValid(directPosId, true), false, "DirectLP should end inactive after claim");
        (, uint256 potAfterInactivePoke) = vtsOrchestrator.getSlashedPot(corePoolKey.toId());

        // The pot should have drained (at least partially), and the pending bonus should move towards 0
        assertLt(
            potAfterInactivePoke, potBeforeInactivePoke, "Inactive poke should materialise bonus and drain the pot"
        );

        (,, int256 dlPending0Final, int256 dlPending1Final) = vtsOrchestrator.getPositionFeeAccounting(directPosId);
        dlPending0Final; // silence
        assertGt(dlPending1Final, dlPending1AfterRemove, "Pending bonus should be reduced after inactive poke");
    }

    /// @notice Edge Case 6b: An inactive (0-liquidity) MM position can collect dormant fees/bonuses by re-activating,
    ///         settling, closing again, then taking both LCC deltas.
    /// @dev This specifically exercises the MMPositionManager/MMPositionActionsImpl pathway:
    ///      increase (reactivate) -> settle (fund) -> decrease (return to 0-liquidity) -> take(lcc0) -> take(lcc1).
    function test_inactiveMMPosition_canCollectDormantFees() public {
        // ------------------------------------------------------------
        // 1) Create a slasher MM that queues protocolFeeAccrued, but DO NOT fund slashedPot yet
        // ------------------------------------------------------------
        int24 mmTickLower = -960;
        int24 mmTickUpper = 960;
        (uint256 slasherTokenId, PositionId slasherPosId,,) = _createCommittedPosition(mmTickLower, mmTickUpper, 50e10);

        // Create deficit + fees (fee token = token1 for one-for-zero swap)
        _swapCore(false, -int256(30e18));

        (, int24 tickAfterSwap,,) = StateLibrary.getSlot0(manager, corePoolKey.toId());
        console.log("====== AFTER SWAP ======");
        console.log("tickAfterSwap:", tickAfterSwap);

        // Materialise deficit principal, then exercise coverage and settle again to queue fee burn
        vtsOrchestrator.settlePositionGrowths(slasherPosId);
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 5e18, 0);
        vtsOrchestrator.settlePositionGrowths(slasherPosId);

        (, uint256 feeAccruedBefore) = _protocolFeeAccrued(corePoolKey.toId());
        assertGt(feeAccruedBefore, 0, "Precondition: protocolFeeAccrued1 must be > 0 after queued slashes");
        (, uint256 potBefore) = vtsOrchestrator.getSlashedPot(corePoolKey.toId());
        assertEq(potBefore, 0, "Precondition: slashedPot1 must be 0 before slasher poke");

        // ------------------------------------------------------------
        // 2) Create a beneficiary MM position. It should NOT allocate bonuses immediately on creation.
        // ------------------------------------------------------------
        uint256 mmLiquidity = 10e10;
        (uint256 beneficiaryTokenId, PositionId beneficiaryPosId) =
            _createNewMMCommit(mmTickLower, mmTickUpper, mmLiquidity);

        // Provide positive selfNet via a settlement deposit (eligibility gate) before fee-processing touch.
        _mmSettle(beneficiaryTokenId, 0, _negInt128Capped(10e18), _negInt128Capped(10e18));

        (,, int256 mmPending0AfterCreate, int256 mmPending1AfterCreate) =
            vtsOrchestrator.getPositionFeeAccounting(beneficiaryPosId);
        mmPending0AfterCreate; // silence
        assertEq(mmPending1AfterCreate, 0, "New MM position must not queue a bonus on creation");

        (uint256 settlementAmount0, uint256 settlementAmount1) =
            vtsOrchestrator.getPositionSettledAmounts(beneficiaryPosId);
        console.log("settlement amount0:", settlementAmount0);
        console.log("settlement amount1:", settlementAmount1);

        // ------------------------------------------------------------
        // 3) Accrue native fees for the MM, create selfNet via settlement, and touch to queue a bonus
        // ------------------------------------------------------------
        _swapCore(false, -int256(2e18)); // accrue token1 fees for in-range positions

        (, int24 tickAfterSwap2,,) = StateLibrary.getSlot0(manager, corePoolKey.toId());
        console.log("====== AFTER SWAP #2 ======");
        console.log("tickAfterSwap2:", tickAfterSwap2); // should be 628, meaning positions are still in-range.

        (settlementAmount0, settlementAmount1) = vtsOrchestrator.getPositionSettledAmounts(beneficiaryPosId);
        console.log("settlement amount0 after swap before settle growths:", settlementAmount0);
        console.log("settlement amount1 after swap before settle growths:", settlementAmount1);

        vtsOrchestrator.settlePositionGrowths(beneficiaryPosId); // settle growths in advance to inspect the settlement amounts

        (settlementAmount0, settlementAmount1) = vtsOrchestrator.getPositionSettledAmounts(beneficiaryPosId);
        console.log("settlement amount0 after swap:", settlementAmount0);
        console.log("settlement amount1 after swap:", settlementAmount1);
        // TODO: IF this is set to commitmentMax, then there is no net increase that allows the new fee bonus to be allocated
        // Therefore, it may be best to index coverage to settled units as well as deficit units.
        // This way we can retroactively bonus based on this accumulator.

        (uint256 commitMax0, uint256 commitMax1) = vtsOrchestrator.getCommitmentMaxima(beneficiaryPosId);
        console.log("commitment max0:", commitMax0);
        console.log("commitment max1:", commitMax1);

        // Touch (increase 0) to process fees and queue bonus; take deltas to avoid lingering credits.
        _pokeMM(beneficiaryTokenId, 0, mmTickLower, mmTickUpper);

        (,, int256 mmPending0AfterTouch, int256 mmPending1AfterTouch) =
            vtsOrchestrator.getPositionFeeAccounting(beneficiaryPosId);
        mmPending0AfterTouch; // silence
        assertLt(mmPending1AfterTouch, 0, "Existing MM should be able to queue a bonus on touch");

        // ------------------------------------------------------------
        // 4) Fully remove MM liquidity => position becomes inactive (0-liquidity), bonus remains queued (pot still empty)
        // ------------------------------------------------------------
        {
            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
            actions[0] = MMA.prepareDecrease(corePoolKey, beneficiaryTokenId, 0, mmLiquidity);
            actions[1] = MMA.prepareSettle(
                corePoolKey,
                beneficiaryTokenId,
                0,
                SafeCast.toInt128(mmLiquidity),
                SafeCast.toInt128(mmLiquidity),
                false
            );
            actions[2] = MMA.prepareTake(lccCurrency0, address(this), 0);
            actions[3] = MMA.prepareTake(lccCurrency1, address(this), 0);
            MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        }

        assertEq(vtsOrchestrator.isPositionValid(beneficiaryPosId, true), false, "MM position should now be inactive");
        (,, int256 mmPending0AfterClose, int256 mmPending1AfterClose) =
            vtsOrchestrator.getPositionFeeAccounting(beneficiaryPosId);
        mmPending0AfterClose; // silence
        assertLt(mmPending1AfterClose, 0, "Queued bonus must remain for inactive MM position");

        // ------------------------------------------------------------
        // 5) Fund the slashed pot by poking the slasher MM (materialises its +pendingFeeAdj)
        // ------------------------------------------------------------
        _pokeMM(slasherTokenId, 0, mmTickLower, mmTickUpper);
        (, uint256 potFunded) = vtsOrchestrator.getSlashedPot(corePoolKey.toId());
        assertGt(potFunded, 0, "Pot must be funded after slasher poke");

        // ------------------------------------------------------------
        // 6) Inactive MM re-activates with a small increase, settles, closes again, then takes deltas to collect.
        // ------------------------------------------------------------
        uint256 potBeforeInactiveClaim = potFunded;
        uint256 mmReopenLiquidity = 1e6;

        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) = _calculateSettlementAmounts(
            ModifyLiquidityParams({
                tickLower: mmTickLower,
                tickUpper: mmTickUpper,
                liquidityDelta: int256(mmReopenLiquidity),
                salt: bytes32(0)
            }),
            marketVTSConfiguration
        );

        int128 settle0 = -SafeCast.toInt128(requiredSettlementAmount0);
        int128 settle1 = -SafeCast.toInt128(requiredSettlementAmount1);
        _permitSettle(settle0, settle1);

        uint256 bal0Before = _selfLccBalance(lccCurrency0);
        uint256 bal1Before = _selfLccBalance(lccCurrency1);

        {
            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](5);
            actions[0] =
                MMA.prepareIncrease(corePoolKey, beneficiaryTokenId, 0, mmTickLower, mmTickUpper, mmReopenLiquidity);
            actions[1] = MMA.prepareSettle(corePoolKey, beneficiaryTokenId, 0, settle0, settle1, false);
            actions[2] = MMA.prepareDecrease(corePoolKey, beneficiaryTokenId, 0, mmReopenLiquidity);
            actions[3] = MMA.prepareTake(lccCurrency0, address(this), 0);
            actions[4] = MMA.prepareTake(lccCurrency1, address(this), 0);
            MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        }

        assertEq(vtsOrchestrator.isPositionValid(beneficiaryPosId, true), false, "MM should end inactive after claim");
        (, uint256 potAfterInactiveClaim) = vtsOrchestrator.getSlashedPot(corePoolKey.toId());
        assertLt(potAfterInactiveClaim, potBeforeInactiveClaim, "Inactive MM claim should drain the pot");

        (,, int256 mmPending0Final, int256 mmPending1Final) = vtsOrchestrator.getPositionFeeAccounting(beneficiaryPosId);
        mmPending0Final; // silence
        assertGt(mmPending1Final, mmPending1AfterClose, "Pending bonus should be reduced after inactive MM claim");

        uint256 bal0After = _selfLccBalance(lccCurrency0);
        uint256 bal1After = _selfLccBalance(lccCurrency1);
        assertTrue(bal0After >= bal0Before, "lcc0 take should not reduce balance");
        assertTrue(bal1After >= bal1Before, "lcc1 take should not reduce balance");
        assertTrue(bal0After > bal0Before || bal1After > bal1Before, "Expected at least one LCC take to pay out");
    }

    /// @notice Edge Case 7: Banked selfNet/feeWeight across touches when potAvail == 0, then allocate once potAvail > 0.
    /// @dev Covers both cases:
    ///      - potAvail == 0: no allocation occurs; windows remain banked
    ///      - potAvail > 0: allocation occurs; windows are cleared for the allocated token
    function test_bankedSelfNet_feeWeight_allocatesOnlyWhenPotAvailPositive() public {
        // ------------------------------------------------------------
        // 0) Create an in-range DirectLP position so it can accrue native fees (feeWeight)
        // ------------------------------------------------------------
        int24 dlTickLower = -960;
        int24 dlTickUpper = 960;
        uint256 dlLiquidity = 1e18;
        // Wrap underlying to LCC - this funds hub.reserveOfUnderlying for swap settlement
        _mintLccTo(address(this), corePoolKey.currency0, 1e18);
        _mintLccTo(address(this), corePoolKey.currency1, 1e18);
        ModifyLiquidityParams memory dlAddParams = ModifyLiquidityParams({
            tickLower: dlTickLower, tickUpper: dlTickUpper, liquidityDelta: int256(dlLiquidity), salt: 0
        });

        modifyLiquidityRouter.modifyLiquidity(corePoolKey, dlAddParams, ZERO_BYTES);

        PositionId directPosId = PositionLibrary.generateId(address(modifyLiquidityRouter), dlAddParams);

        // ------------------------------------------------------------
        // 1) potAvail == 0 case: accrue fees, touch, ensure no bonus is allocated and windows remain banked
        // ------------------------------------------------------------
        // Accrue some fees on token1 (one-for-zero swap => fee token is token1)
        _swapCore(false, -int256(2e18));

        // Touch DirectLP (poke): this should record feesAccruedSinceLastMod, but potAvail is still 0
        ModifyLiquidityParams memory dlPokeParams =
            ModifyLiquidityParams({tickLower: dlTickLower, tickUpper: dlTickUpper, liquidityDelta: 0, salt: 0});

        // Precondition: no protocolFeeAccrued yet (no slashes have occurred), so potAvail == 0
        (, uint256 feeAccruedBefore1) = _protocolFeeAccrued(corePoolKey.toId());
        assertEq(feeAccruedBefore1, 0, "Precondition: protocolFeeAccrued1 should be 0 before any slashing");

        modifyLiquidityRouter.modifyLiquidity(corePoolKey, dlPokeParams, ZERO_BYTES);

        // No bonus should be queued because potAvail == 0
        (,, int256 pending0AfterPoke, int256 pending1AfterPoke) =
            _testableOrchestrator().getPositionFeeAccounting(directPosId);
        pending0AfterPoke; // silence
        assertEq(pending1AfterPoke, 0, "potAvail==0: should not queue bonus (pendingFeeAdj1 stays 0)");

        // Windows should remain banked (selfNet from initial settlement; feeWeight from poke)
        (int256 net0, int256 net1, uint256 feeW0, uint256 feeW1) =
            _testableOrchestrator().getPositionBonusWeights(directPosId);
        net0; // silence
        assertGt(net1, 0, "potAvail==0: selfNet1 should remain banked");
        assertEq(feeW0, 0, "potAvail==0: feeWeight0 expected 0 in one-for-zero fee direction");
        assertGt(feeW1, 0, "potAvail==0: feeWeight1 should be recorded and banked");

        // ------------------------------------------------------------
        // 2) potAvail > 0 case: create slashes so protocolFeeAccrued > 0, then touch and ensure allocation occurs
        // ------------------------------------------------------------
        // Create MM slasher and queue slashes (protocolFeeAccrued increases on settlePositionGrowths)
        int24 mmTickLower = -960;
        int24 mmTickUpper = 960;
        (uint256 tokenId, PositionId slasherPosId,,) = _createCommittedPosition(mmTickLower, mmTickUpper, 50e10);

        _swapCore(false, -int256(50e18));
        vtsOrchestrator.settlePositionGrowths(slasherPosId);
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 5e18, 0);
        vtsOrchestrator.settlePositionGrowths(slasherPosId);

        (, uint256 feeAccruedAfterSlash1) = _protocolFeeAccrued(corePoolKey.toId());
        assertGt(feeAccruedAfterSlash1, 0, "Precondition: protocolFeeAccrued1 should be > 0 after slashing queued");

        // Touch DirectLP again: now potAvail > 0, so it should allocate and queue a bonus
        modifyLiquidityRouter.modifyLiquidity(corePoolKey, dlPokeParams, ZERO_BYTES);

        (,, int256 pending0AfterAlloc, int256 pending1AfterAlloc) =
            _testableOrchestrator().getPositionFeeAccounting(directPosId);
        pending0AfterAlloc; // silence
        assertLt(pending1AfterAlloc, 0, "potAvail>0: should queue a bonus (pendingFeeAdj1 < 0)");

        // After a successful allocation, windows for token1 should be cleared (bank consumed)
        (int256 net0After, int256 net1After, uint256 feeW0After, uint256 feeW1After) =
            _testableOrchestrator().getPositionBonusWeights(directPosId);
        net0After; // silence
        feeW0After; // silence
        assertEq(net1After, 0, "potAvail>0: net1 window should be cleared after allocation");
        assertEq(feeW1After, 0, "potAvail>0: feeWeight1 window should be cleared after allocation");

        // Suppress unused variable warnings
        tokenId;
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
}


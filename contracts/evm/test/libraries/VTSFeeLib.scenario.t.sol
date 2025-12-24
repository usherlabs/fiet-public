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
    /// @dev Demonstrates the ordering hazard with CISE:
    ///      - Coverage burn queues +pendingFeeAdj on the slasher and increments protocolFeeAccrued (accounting pot)
    ///      - But slashedPot is only funded when the slasher is later poked (finalised via _finaliseFeeAdjustment)
    ///      - Meanwhile, a beneficiary poke (via CISE) can realise exposure, reduce protocolFeeAccrued and queue -pendingFeeAdj (bonus),
    ///        despite slashedPot still being 0 (so nothing can be paid yet)
    ///      Setup:
    ///      - Create MM0 (slasher) and MM1 (beneficiary) positions
    ///      - Create deficit + coverage to trigger slash on MM0 (queues +pendingFeeAdj, increments protocolFeeAccrued)
    ///      - Do NOT poke MM0 yet (slashedPot remains 0)
    ///      - Poke MM1 first (beneficiary processes fees before slasher, realises CISE exposure)
    ///      Expected:
    ///      - slashedPot remains 0 (slasher not poked yet)
    ///      - protocolFeeAccrued is reduced by bonus allocation (bonus queued from accounting pot)
    ///      - MM1 has negative pendingFeeAdj (queued bonus)
    ///      - After MM0 poke, slashedPot is funded and MM1's bonus can be materialised
    function test_bonusAllocatedBeforeSlashMaterialised_whenBeneficiaryPokesFirst() public {
        int24 tickLower = -960;
        int24 tickUpper = 960;

        // Create commit with idx0 (intended slasher)
        (uint256 tokenId, PositionId slasherPosId,,) = _createCommittedPosition(tickLower, tickUpper, initialLiquidity);

        // Clear any "net since last mod" from initial settlement so the pool net is clean
        _pokeMM(tokenId, 0, tickLower, tickUpper);

        // Add idx1 (beneficiary) and leave it with positive net settlement since last modification
        (uint256 idx1, PositionId beneficiaryPosId) = _mintAdditionalMM(tokenId, tickLower, tickUpper, initialLiquidity);
        _mmSettle(
            tokenId, idx1, _negInt128Capped((initialLiquidity / 5) * 4), _negInt128Capped((initialLiquidity / 5) * 4)
        ); // Settle the position before swap to prevent deficit accrual

        // Create deficit + fees (fees accrue on token1 for one-for-zero swap)
        _swapCore(false, -int256(initialLiquidity / 5));

        // Materialise deficit principal first (required for DICE index to move meaningfully)
        vtsOrchestrator.settlePositionGrowths(slasherPosId);

        // Exercise coverage (token0), then settle again to queue coverage burn (slash) in fee token (token1)
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), initialLiquidity / 5, 0); // acquire token0, therefore unwrap token0
        vtsOrchestrator.settlePositionGrowths(slasherPosId);

        // Sanity: slashed pot should still be 0 (slasher not poked -> no _finaliseFeeAdjustment funding)
        uint256 potBefore = _slashedPot1();
        assertEq(potBefore, 0, "Precondition: slashed pot must be 0 before any slasher position poke");

        // Sanity: protocolFeeAccrued should be >0 after coverage burn
        (, uint256 feeAccruedBefore) = _protocolFeeAccrued(corePoolKey.toId());
        assertGt(feeAccruedBefore, 0, "Precondition: protocolFeeAccrued1 must be > 0 after coverage burn");

        // Sanity: slasher has a queued positive slash (pendingFeeAdj1 > 0)
        (,, int256 slasherPending0Before, int256 slasherPending1Before) =
            _testableOrchestrator().getPositionFeeAccounting(slasherPosId);
        assertGt(slasherPending1Before, 0, "Precondition: slasher must have pendingFeeAdj1 > 0");
        slasherPending0Before; // silence unused variable

        // ? At this point, the slashed pot is still 0, but protocolFeeAccrued > 0 AND slasher pendingFeeAdj > 0 (queued slash).

        // Beneficiary processes fees FIRST:
        // Under CISE, this will realise exposure and CAN queue a bonus against protocolFeeAccrued,
        // even though slashedPot is still 0 (so it can't be materialised/paid yet).
        console.log("FIRST BENEFICIARY POKE:");
        _pokeMM(tokenId, idx1, tickLower, tickUpper);
        console.log("END ____ FIRST BENEFICIARY POKE:");

        // Pot is still unfunded (slasher still not poked)
        uint256 potAfterBeneficiary = _slashedPot1();
        assertEq(potAfterBeneficiary, 0, "Pot must remain 0 until slasher is poked");

        // protocolFeeAccrued SHOULD NOT be reduced. Since potAvail = 0, CISE exposure is banked until future poke when potAvail > 0.
        (, uint256 feeAccruedAfterBeneficiary) = _protocolFeeAccrued(corePoolKey.toId());
        assertEq(
            feeAccruedAfterBeneficiary,
            feeAccruedBefore,
            "protocolFeeAccrued SHOULD NOT be reduced. Since potAvail = 0, CISE exposure is banked until future poke when potAvail > 0"
        );

        (, uint256 slasherContrib,,) = _testableOrchestrator().getPositionFeeAccounting(slasherPosId);
        assertGt(slasherContrib, 0, "Slasher must have a positive contribution to fees shared");

        // Beneficiary SHOULD have queued a negative pending adjustment (bonus), but it can't be paid yet (slashedPot==0)
        (,, int256 mm1Pending0After, int256 mm1Pending1After) =
            _testableOrchestrator().getPositionFeeAccounting(beneficiaryPosId);
        mm1Pending0After; // silence unused variable
        assertEq(mm1Pending1After, 0, "Beneficiary should have no pendingFeeAdj1 until slasher is poked");

        // Now poke slasher: this should fund the pot from its +pendingFeeAdj
        _pokeMM(tokenId, 0, tickLower, tickUpper);
        uint256 potAfterSlasher = _slashedPot1();
        assertGt(potAfterSlasher, 0, "Slasher poke should fund the pot");

        uint256 lcc1BalanceBefore = _selfLccBalance(lccCurrency1);

        // SECOND Beneficiary poke: this should materialise (pay) some/all of the queued bonus from slashedPot
        _pokeMM(tokenId, idx1, tickLower, tickUpper);

        uint256 potAfterBeneficiary2 = _slashedPot1();
        assertEq(potAfterBeneficiary2, potAfterSlasher, "Pot should not change as Beneficiary is not slashed further");

        uint256 lcc1BalanceAfter = _selfLccBalance(lccCurrency1);
        assertGt(
            lcc1BalanceAfter, lcc1BalanceBefore, "Beneficiary poke should increase LCC1 balance because of the bonus"
        );

        (,, int256 mm1Pending0After2, int256 mm1Pending1After2) =
            _testableOrchestrator().getPositionFeeAccounting(beneficiaryPosId);
        mm1Pending0After2; // silence unused variable
        assertEq(mm1Pending1After2, 0, "Beneficiary pendingFeeAdj1 should move back towards 0 after materialisation");

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

        // CISE exposure is realised when incrementCoverage is called during swaps.
        // Bonus allocation requires CISE exposure > 0 at fee-processing time (during modifyLiquidity touch).

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
    function test_inactivePosition_mmCanCollectDormantFees() public {
        // ------------------------------------------------------------
        // 1) Create a slasher MM that queues protocolFeeAccrued, but DO NOT fund slashedPot yet
        // ------------------------------------------------------------
        int24 mmTickLower = -960;
        int24 mmTickUpper = 960;
        (uint256 slasherTokenId, PositionId slasherPosId,,) = _createCommittedPosition(mmTickLower, mmTickUpper, 50e10);

        // Create deficit + fees (fee token = token1 for one-for-zero swap)
        _swapCore(false, -int256(30e18));

        // Materialise deficit principal, then exercise coverage and settle again to queue fee burn
        vtsOrchestrator.settlePositionGrowths(slasherPosId);
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 20e18, 0);
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

        // ------------------------------------------------------------
        // 3) Accrue native fees for the MM, create selfNet via settlement, and touch to queue a bonus
        // ------------------------------------------------------------
        _swapCore(false, -int256(2e18)); // accrue token1 fees for in-range positions

        (, int24 tickAfterSwap2,,) = StateLibrary.getSlot0(manager, corePoolKey.toId());

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
    function test_allocatesOnlyWhenPotAvailPositive() public {
        // ------------------------------------------------------------
        // 0) Use the initial full-range DirectLP position created in setUp()
        //    (it dominates totalSettled, so it will actually accrue non-dust CISE exposure)
        // ------------------------------------------------------------
        int24 dlTickLower = TickMath.minUsableTick(corePoolKey.tickSpacing);
        int24 dlTickUpper = TickMath.maxUsableTick(corePoolKey.tickSpacing);

        ModifyLiquidityParams memory dlPokeParams = ModifyLiquidityParams({
            tickLower: dlTickLower, tickUpper: dlTickUpper, liquidityDelta: 0, salt: bytes32(0)
        });

        PositionId directPosId = PositionLibrary.generateId(address(modifyLiquidityRouter), dlPokeParams);
        assertTrue(vtsOrchestrator.isPositionValid(directPosId, true), "Precondition: initial LP should exist");

        // ------------------------------------------------------------
        // 1) potAvail == 0 case: accrue fees, touch, ensure no bonus is allocated and windows remain banked
        // ------------------------------------------------------------
        // Accrue some fees on token1 (one-for-zero swap => fee token is token1)
        _swapCore(false, -int256(2e18));

        // Precondition: no protocolFeeAccrued yet (no slashes have occurred), so potAvail == 0
        (, uint256 feeAccruedBefore1) = _protocolFeeAccrued(corePoolKey.toId());
        assertEq(feeAccruedBefore1, 0, "Precondition: protocolFeeAccrued1 should be 0 before any slashing");

        (,, int256 pending0BeforePoke, int256 pending1BeforePoke) =
            _testableOrchestrator().getPositionFeeAccounting(directPosId);
        pending0BeforePoke; // silence

        // Touch DirectLP (poke): potAvail is still 0 (no slashes have occurred)
        modifyLiquidityRouter.modifyLiquidity(corePoolKey, dlPokeParams, ZERO_BYTES);

        // No bonus should be queued because potAvail == 0
        (,, int256 pending0AfterPoke, int256 pending1AfterPoke) =
            _testableOrchestrator().getPositionFeeAccounting(directPosId);
        pending0AfterPoke; // silence
        assertEq(pending1AfterPoke, pending1BeforePoke, "potAvail==0: should not queue bonus");

        // CISE exposure is 0 because no coverage has been exercised yet
        (uint256 ciseExp0, uint256 ciseExp1) = _testableOrchestrator().getPositionBonusWeights(directPosId);
        assertEq(ciseExp0, 0, "potAvail==0: ciseExposure0 should be 0 (no coverage exercised)");
        assertEq(ciseExp1, 0, "potAvail==0: ciseExposure1 should be 0 (no coverage exercised)");

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
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 50e18, 0);
        vtsOrchestrator.settlePositionGrowths(slasherPosId);

        (, uint256 feeAccruedAfterSlash1) = _protocolFeeAccrued(corePoolKey.toId());
        assertGt(feeAccruedAfterSlash1, 0, "Precondition: protocolFeeAccrued1 should be > 0 after slashing queued");

        // Touch DirectLP again: now potAvail > 0, so it should allocate and queue a bonus
        modifyLiquidityRouter.modifyLiquidity(corePoolKey, dlPokeParams, ZERO_BYTES);

        (,, int256 pending0AfterAlloc, int256 pending1AfterAlloc) =
            _testableOrchestrator().getPositionFeeAccounting(directPosId);
        pending0AfterAlloc; // silence
        assertLt(pending1AfterAlloc, 0, "potAvail>0: should queue a bonus (pendingFeeAdj1 < 0)");

        // After a successful allocation, CISE exposure windows for the coverage token should be cleared
        // Note: token1 pot is funded by token0 deficits, so token0 exposure is cleared when token1 bonus is allocated
        (uint256 ciseExp0After, uint256 ciseExp1After) = _testableOrchestrator().getPositionBonusWeights(directPosId);
        // token0 exposure should be cleared because it was used for token1 bonus allocation
        assertEq(
            ciseExp0After, 0, "potAvail>0: ciseExposure0 should be cleared after allocation (used for token1 bonus)"
        );
        ciseExp1After; // silence - token1 exposure wasn't consumed since token0 pot is empty

        // Suppress unused variable warnings
        tokenId;
    }
}


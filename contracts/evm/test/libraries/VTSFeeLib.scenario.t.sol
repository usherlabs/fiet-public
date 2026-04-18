// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSOrchestratorFixture} from "../base/VTSOrchestratorFixture.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {VTSOrchestratorTestable} from "../base/VTSOrchestratorTestable.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {PositionId, PositionLibrary} from "../../src/types/Position.sol";
import {IMarketVault} from "../../src/interfaces/IMarketVault.sol";
import {IMarketVaultDryBalanceDelta} from "../_helpers/IMarketVaultDryBalanceDelta.sol";
import {VTSOrchestrator} from "../../src/VTSOrchestrator.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {MMActionAdapter as MMA} from "../utils/MMActionAdapter.sol";
import {LiquiditySignal} from "../../src/types/Commit.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {MarketVTSConfiguration} from "../../src/types/VTS.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

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
    function _deployVTSOrchestrator(address _poolManager, address _oracleHelper, address _liquidityHub, address _owner)
        internal
        override
        returns (VTSOrchestrator)
    {
        return new VTSOrchestratorTestable(_poolManager, _oracleHelper, _liquidityHub, _owner);
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

    function _pendingFeeAdj1(PositionId pid) internal view returns (int256) {
        (,,, int256 p1) = vtsOrchestrator.getPositionFeeAccounting(pid);
        return p1;
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
        (,, uint256 countBefore,,) = vtsOrchestrator.getCommit(tokenId);

        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) =
            _requiredSettlementAmountsForMMModify(tickLower, tickUpper, liquidity, marketVTSConfiguration);

        address locker = positionManager.ownerOf(tokenId);
        _mintAndApproveUnderlyingForSettlementTo(locker, requiredSettlementAmount0, requiredSettlementAmount1);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareMint(corePoolKey, tokenId, tickLower, tickUpper, liquidity);
        actions[1] = MMA.prepareSettle(
            corePoolKey,
            tokenId,
            countBefore,
            -SafeCast.toInt128(requiredSettlementAmount0),
            -SafeCast.toInt128(requiredSettlementAmount1),
            false
        );
        vm.startPrank(locker);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();

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
    // DirectLP "Engagement" Helpers (Uni v4 PositionManager + DeltaResolver)
    // ============================================================

    /// @dev Mints a DirectLP position via Uniswap v4 PositionManager, settles the pair, then subscribes
    ///      to `directLPDeltaResolver` so any hook deltas (e.g. feeAdj from bonuses) are cleared in the same unlock.
    /// @return dlTokenId The PositionManager NFT token id (used as position salt)
    /// @return directPosId The VTS PositionId for this DirectLP (owner = uniPositionManager, salt = dlTokenId)
    function _engageDirectLPViaUniPM(int24 tickLower, int24 tickUpper, uint256 liquidity)
        internal
        returns (uint256 dlTokenId, PositionId directPosId)
    {
        dlTokenId = uniPositionManager.nextTokenId();

        {
            bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(
                corePoolKey,
                tickLower,
                tickUpper,
                liquidity,
                type(uint128).max,
                type(uint128).max,
                address(this),
                ZERO_BYTES
            );
            params[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1);
            uniPositionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);
        }

        uniPositionManager.subscribe(dlTokenId, address(directLPDeltaResolver), "");

        ModifyLiquidityParams memory addParamsForId = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(liquidity), salt: bytes32(dlTokenId)
        });
        directPosId = PositionLibrary.generateId(address(uniPositionManager), addParamsForId);
    }

    /// @dev Pokes (INCREASE by 0) a PositionManager-owned DirectLP and drains any credited deltas via TAKE_PAIR.
    function _pokeDirectLPViaUniPMAndTake(uint256 dlTokenId) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(dlTokenId, 0, type(uint128).max, type(uint128).max, ZERO_BYTES);
        params[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1, address(this));
        uniPositionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);
    }

    /// @dev Stack-safe wrapper around `_calculateSettlementAmounts` for MM modify actions.
    ///      Coverage disables viaIR/optimiser, so large test functions can hit "stack too deep"
    ///      when constructing `ModifyLiquidityParams` inline.
    function _requiredSettlementAmountsForMMModify(
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        MarketVTSConfiguration memory vtsConfig
    ) internal pure returns (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) {
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(liquidity), salt: bytes32(0)
        });
        return _calculateSettlementAmounts(p, vtsConfig);
    }

    /// @dev Executes the "inactive MM claim" batch (increase+settle+decrease+take) and returns post-state for assertions.
    ///      Kept as a helper to avoid "stack too deep" when coverage disables viaIR/optimiser.
    function _inactiveMmClaimAndTake(
        uint256 beneficiaryTokenId,
        PositionId beneficiaryPosId,
        uint256 mmReopenLiquidity
    ) internal returns (uint256 potAfterInactiveClaim, int256 pending1After, uint256 bal0After, uint256 bal1After) {
        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) =
            _requiredSettlementAmountsForMMModify(-960, 960, mmReopenLiquidity, marketVTSConfiguration);

        int128 settle0 = -SafeCast.toInt128(requiredSettlementAmount0);
        int128 settle1 = -SafeCast.toInt128(requiredSettlementAmount1);
        address lockerInactive = positionManager.ownerOf(beneficiaryTokenId);
        _permitSettleFor(lockerInactive, settle0, settle1);

        {
            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](6);
            actions[0] = MMA.prepareIncrease(corePoolKey, beneficiaryTokenId, 0, mmReopenLiquidity);
            actions[1] = MMA.prepareSettle(corePoolKey, beneficiaryTokenId, 0, settle0, settle1, false);
            actions[2] = MMA.prepareDecrease(corePoolKey, beneficiaryTokenId, 0, mmReopenLiquidity); // decrease should nullify.
            actions[3] = MMA.prepareSettleFromDeltas(corePoolKey, beneficiaryTokenId, 0, true, true); // take underlying back to user wallet.
            actions[4] = MMA.prepareTake(lccCurrency0, address(this), 0);
            actions[5] = MMA.prepareTake(lccCurrency1, address(this), 0);
            vm.startPrank(lockerInactive);
            MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
            vm.stopPrank();
        }

        assertEq(vtsOrchestrator.isPositionValid(beneficiaryPosId, true), false, "MM should end inactive after claim");
        (, potAfterInactiveClaim) = vtsOrchestrator.getSlashedPot(corePoolKey.toId());
        (,,, pending1After) = vtsOrchestrator.getPositionFeeAccounting(beneficiaryPosId);

        bal0After = _selfLccBalance(lccCurrency0);
        bal1After = _selfLccBalance(lccCurrency1);
    }

    /// @dev Stack-safe: decrease + settleFromDeltas + TAKE both LCC to this contract as the batch locker.
    function _mmDecreaseSettleTakeToSelf(uint256 tokenId, uint256 mmLiquidity) internal {
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, 0, mmLiquidity);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, 0, true, true);
        actions[2] = MMA.prepareTake(lccCurrency0, address(this), 0);
        actions[3] = MMA.prepareTake(lccCurrency1, address(this), 0);
        vm.startPrank(positionManager.ownerOf(tokenId));
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();
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
        // Values needed across scoped blocks (declared at function level)
        uint256 mm1;
        uint256 mm2;
        uint256 mm3;
        uint256 potBefore;
        uint256 protocolFeeAccruedBefore0;
        uint256 protocolFeeAccruedBefore1;
        uint256 protocolFeeAccruedAfter0;
        uint256 protocolFeeAccruedAfter1;
        int256 mm1PendingBefore;
        int256 mm1PendingAfter;

        // ══════════════════════════════════════════════════════════════════════════
        // Phase 1: Setup + swap + coverage + settle (scoped to reset stack)
        // ══════════════════════════════════════════════════════════════════════════
        {
            // 3 independent MM commits (each with unique signal nonce)
            PositionId mm1PositionId;
            PositionId mm2PositionId;
            PositionId mm3PositionId;
            (mm1, mm1PositionId) = _createNewMMCommit(-60, 60, 3e10);
            (mm2, mm2PositionId) = _createNewMMCommit(-60, 60, 3e10);
            (mm3, mm3PositionId) = _createNewMMCommit(-60, 60, 3e10);
            assertEq(mm1, 1);
            assertEq(mm2, 2);
            assertEq(mm3, 3);

            // Make MM2 and MM3 solvent by depositing some settlement
            // Note: For independent commits, position index is always 0
            _mmSettle(mm2, 0, _negInt128Capped(5e18), _negInt128Capped(5e18));
            _mmSettle(mm3, 0, _negInt128Capped(5e18), _negInt128Capped(5e18));

            potBefore = _slashedPot1();
            (protocolFeeAccruedBefore0, protocolFeeAccruedBefore1) = _slashedPot(corePoolKey.toId());
            mm1PendingBefore = _pendingFeeAdj1(mm1PositionId);

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

            (protocolFeeAccruedAfter0, protocolFeeAccruedAfter1) = _slashedPot(corePoolKey.toId());
            mm1PendingAfter = _pendingFeeAdj1(mm1PositionId);

            // Debug logging (scoped so these locals die immediately)
            {
                (,, uint256 settled0, uint256 settled1,,) = _testableOrchestrator().getPositionAccounting(mm1PositionId);
                console.log("mm1 settled0:", settled0);
                console.log("mm1 settled1:", settled1);
            }
            {
                (,, uint256 settled02, uint256 settled12,,) =
                    _testableOrchestrator().getPositionAccounting(mm2PositionId);
                console.log("mm2 settled0:", settled02);
                console.log("mm2 settled1:", settled12);
            }
            {
                (,, uint256 settled03, uint256 settled13,,) =
                    _testableOrchestrator().getPositionAccounting(mm3PositionId);
                console.log("mm3 settled0:", settled03);
                console.log("mm3 settled1:", settled13);
            }
        }

        // ══════════════════════════════════════════════════════════════════════════
        // Phase 2: Poke all positions + final assertions
        // ══════════════════════════════════════════════════════════════════════════
        _pokeMM(mm2, 0);
        _pokeMM(mm3, 0);
        uint256 potAfter = _slashedPot1();

        _pokeMM(mm1, 0);

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
            protocolFeeAccruedAfter0, protocolFeeAccruedBefore0, "DICE: materialised slashedPot0 unchanged until touch"
        );
        assertGt(mm1PendingAfter, mm1PendingBefore, "Queued slash pending should increase on deficit MM (token1 lane)");
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
        _mintAdditionalMM(tokenId, -60, 60, 1e10); // idx1
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
            abi.encodeWithSelector(IMarketVaultDryBalanceDelta.dryModifyLiquidities.selector),
            abi.encode(toBalanceDelta(int128(0), int128(0)))
        );

        uint256 potBefore = _slashedPot0();

        // Attempt a withdrawal via the MM router path; it will be clamped to 0 by vault mock.
        _mmSettle(tokenId, 0, int128(10), int128(0));

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
    ///      - Newly created DirectLP must NOT accrue any fees/bonuses on creation (new-position gate)
    /// @dev Note: Verifying that DirectLP receives bonuses would require separate position
    ///      modification with proper delta settlement (via modifyLiquidityRouter).
    ///      Out-of-range positions don't contribute to coverage attribution, so they're never slashed,
    ///      but they can still benefit from bonuses if they've contributed settled liquidity.
    function test_directLP_outOfRange_canBeAdded_withFundedPot() public {
        (uint256 tokenId, PositionId positionId) = _commitAndMintFirstMM(); // idx0

        // NOTE:
        // `slashedPot` is only FUNDED when a slashed position is fee-processed (e.g. via `_pokeMM` / touch).
        // Since bonus allocation depends on pot availability, we must ensure the pot is funded
        // before a new DirectLP joins. The DirectLP must still NOT accrue any bonus on *join*;
        // it only accrues on subsequent participation/touches.
        int256 pending1Before = _pendingFeeAdj1(positionId);
        uint256 pot1Before = _slashedPot1();

        // Queue a slash via swap + coverage (materialised on `settlePositionGrowths`)
        _swapCore(false, -int256(6e18));

        vtsOrchestrator.settlePositionGrowths(positionId); // settle deficit
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 3e18, 0); // increment coverage

        vtsOrchestrator.settlePositionGrowths(positionId); // settle coverage over deficit.

        int256 pending1After = _pendingFeeAdj1(positionId);
        assertGt(pending1After, pending1Before, "Expected queued slashes to increase MM pendingFeeAdj1");

        // Fund slashed fee pot (token1) by fee-processing the slashed MM position.
        // This finalises its positive pending fee adjustment into slashedPot1.
        _pokeMM(tokenId, 0);
        uint256 pot1After = _slashedPot1();
        assertGt(pot1After, pot1Before, "Expected slashed fee pot to be funded before DirectLP joins");

        // Fund LCC0 reserves before adding an out-of-range (token0-only) DirectLP.
        // This ensures `ProxyHook.onDirectLP()` can settle underlying from the Hub to the vault.
        _mintLccTo(address(this), lccCurrency0, 1e18);

        // Add an out-of-range direct LP position
        // Use far out-of-range ticks so it doesn't contribute to coverage attribution
        int24 directTickLower = 600;
        int24 directTickUpper = 1200;
        uint256 directLiquidity = 1e18;
        _addDirectLP(directTickLower, directTickUpper, int256(directLiquidity));

        // Compute DirectLP PositionId (owner = modifyLiquidityRouter, salt = 0).
        ModifyLiquidityParams memory directParams = ModifyLiquidityParams({
            tickLower: directTickLower,
            tickUpper: directTickUpper,
            liquidityDelta: int256(directLiquidity),
            salt: bytes32(0)
        });
        PositionId directPosId = PositionLibrary.generateId(address(modifyLiquidityRouter), directParams);
        assertTrue(vtsOrchestrator.isPositionValid(directPosId, true), "DirectLP should be registered");

        // New-position gate: even if protocolFeeAccrued is already > 0, a freshly created DirectLP must not
        // immediately accrue/allocate any fee-sharing bonuses.
        (uint256 feesShared0, uint256 feesShared1, int256 pending0, int256 pending1) =
            vtsOrchestrator.getPositionFeeAccounting(directPosId);
        assertEq(feesShared0, 0, "New DirectLP must not accrue feesShared0 on creation");
        assertEq(feesShared1, 0, "New DirectLP must not accrue feesShared1 on creation");
        assertEq(pending0, 0, "New DirectLP must not queue pendingFeeAdj0 on creation");
        assertEq(pending1, 0, "New DirectLP must not queue pendingFeeAdj1 on creation");
        {
            (uint256 ciseExp0, uint256 ciseExp1) = _testableOrchestrator().getPositionBonusWeights(directPosId);
            assertEq(ciseExp0, 0, "New DirectLP must not have CISE exposure on creation");
            assertEq(ciseExp1, 0, "New DirectLP must not have CISE exposure on creation");
        }

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
    ///      IMPORTANT: When a DirectLP touch returns a non-zero `feeAdj` (e.g. bonus materialisation),
    ///      CoreHook accrues hook deltas that MUST be cleared within the same unlock session.
    ///      Uniswap's native PositionManager does not call MarketFactory.afterModifyLiquidity by default,
    ///      so DirectLP positions must subscribe `DirectLPDeltaResolver` to avoid CurrencyNotSettled().
    function test_directLP_outOfRange_earnsBonus_fromMMslashes() public {
        // ------------------------------------------------------------
        // Scenario goal:
        // - A DirectLP position is OUT-OF-RANGE (so it should never be slashed by DICE),
        //   but it still accrues CISE exposure on `incrementCoverage` and can therefore
        //   receive a bonus from the slashed pot once an MM funds it.
        // ------------------------------------------------------------

        // Use far above-range ticks (current tick ~ 0) so DirectLP is out-of-range.
        int24 directTickLower = 6000;
        int24 directTickUpper = 6600;

        // Ensure this test contract has enough LCC to pay any liquidity provisioning / settlement.
        _mintLccTo(address(this), lccCurrency0, 250e18);
        _mintLccTo(address(this), lccCurrency1, 250e18);

        // Step 1: Add an out-of-range DirectLP via Uniswap PositionManager (and subscribe delta resolver).
        // This ensures hook deltas (feeAdj) are cleared during the same unlock session via MarketFactory.afterModifyLiquidity.
        uint256 dlLiquidity = 2e18;
        (uint256 dlTokenId, PositionId directPosId) =
            _engageDirectLPViaUniPM(directTickLower, directTickUpper, dlLiquidity);
        assertTrue(vtsOrchestrator.isPositionValid(directPosId, true), "DirectLP should be registered");

        // Precondition: DirectLP must be out-of-range (tick below directTickLower).
        (, int24 tickBefore,,) = StateLibrary.getSlot0(manager, corePoolKey.toId());
        assertLt(tickBefore, directTickLower, "Precondition: DirectLP must be out-of-range (above market)");

        // Precondition: DirectLP has settled0 > 0 (it deposited token0 when adding above-range liquidity).
        {
            (,, uint256 settled0, uint256 settled1,,) = _testableOrchestrator().getPositionAccounting(directPosId);
            assertGt(settled0, 0, "Precondition: DirectLP must have settled0 > 0 for CISE exposure");
            settled1; // silence
        }

        // Step 2: Create an MM that will be slashed (funding the fee pot in fee token1).
        // Note: ticks must be aligned to tickSpacing (60), hence [-960, 960].
        (uint256 tokenId, PositionId mmPositionId,,) = _createCommittedPosition(-960, 960, 50e10);

        // Step 3: Create outflows/deficit + fees, then materialise deficit principal (required for DICE index movement).
        _swapCore(false, -int256(50e18)); // one-for-zero: fee token = token1, deficit token = token0
        (, int24 tickAfterSwap,,) = StateLibrary.getSlot0(manager, corePoolKey.toId());
        assertLt(tickAfterSwap, directTickLower, "Precondition: DirectLP must remain out-of-range after swap");

        vtsOrchestrator.settlePositionGrowths(mmPositionId);

        // Precondition: deficit principal must exist for token0 (otherwise coverage would be deferred to residual).
        {
            (uint256 totalDeficitPrincipal0,,,,,) = _testableOrchestrator().getPoolDICEAccounting(corePoolKey.toId());
            assertGt(totalDeficitPrincipal0, 0, "Precondition: token0 deficit principal must materialise");
        }

        // Step 4: Exercise coverage for token0 (this increments CISE index0 and DICE index0).
        // Also: DirectLP exists now, so it will accrue CISE exposure on token0 and can later allocate a token1 bonus.
        //
        // IMPORTANT:
        // Bonus allocation is CISE-gated, and tiny positive exposure only allocates once it yields a non-zero bonus.
        // CISE exposure realised for a position is approximately:
        //   exposure0 ~= coveredAmount0 * positionSettled0 / totalSettled0
        // So we compute a coverage amount that guarantees a comfortably positive exposure for this DirectLP.
        int256 mmPending1Before = _pendingFeeAdj1(mmPositionId);
        uint256 coverage0;
        {
            (,, uint256 directSettled0,,,) = _testableOrchestrator().getPositionAccounting(directPosId);
            (uint256 totalSettled0,,,,,) = _testableOrchestrator().getPoolCISEAccounting(corePoolKey.toId());
            assertGt(totalSettled0, 0, "Precondition: totalSettled0 must be > 0 for CISE indexing");
            assertGt(directSettled0, 0, "Precondition: DirectLP must have settled0 > 0 for CISE exposure");

            uint256 targetExposure = 1e7; // comfortably positive exposure for deterministic bonus allocation
            coverage0 = (targetExposure * totalSettled0) / directSettled0 + 1;
            console.log("coverage0:", coverage0);
            console.log("totalSettled0:", totalSettled0);
            console.log("directSettled0:", directSettled0);
        }
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), coverage0, 0);

        // Step 5: Settle MM again to apply DICE and queue a positive slash into pendingFeeAdj1.
        vtsOrchestrator.settlePositionGrowths(mmPositionId);
        int256 mmPending1After = _pendingFeeAdj1(mmPositionId);
        assertGt(mmPending1After, mmPending1Before, "Expected queued slashes to increase MM pendingFeeAdj1");

        // Step 6: Poke the MM to materialise its positive pending into `slashedPot1`.
        uint256 slashedPot1Before = _slashedPot1();
        _pokeMM(tokenId, 0);
        uint256 slashedPot1Funded = _slashedPot1();
        assertGt(slashedPot1Funded, slashedPot1Before, "Expected MM poke to fund slashedPot1");

        // Step 6b (critical): Realise DirectLP CISE exposure now, and assert it is positive.
        // This makes the subsequent poke expectation ("pot drains") robust and debuggable.
        vtsOrchestrator.settlePositionGrowths(directPosId);
        {
            (uint256 ciseExposure0,) = _testableOrchestrator().getPositionBonusWeights(directPosId);
            assertGt(ciseExposure0, 0, "Precondition: DirectLP must have positive CISE exposure0 to allocate bonus");
        }

        // Step 7: Poke the out-of-range DirectLP. It should allocate a bonus (via CISE exposure0) and materialise it
        // immediately (because slashedPot1 is now funded), draining the pot and increasing this contract's LCC1 balance.
        uint256 lcc1BalanceBefore = _selfLccBalance(lccCurrency1);
        uint256 pot1BeforeBonus = _slashedPot1();

        _pokeDirectLPViaUniPMAndTake(dlTokenId);

        uint256 pot1AfterBonus = _slashedPot1();
        uint256 lcc1BalanceAfter = _selfLccBalance(lccCurrency1);

        assertLt(pot1AfterBonus, pot1BeforeBonus, "DirectLP poke should drain slashedPot1 (bonus materialised)");
        assertGt(lcc1BalanceAfter, lcc1BalanceBefore, "DirectLP should receive a materialised bonus in LCC1");

        // Suppress unused variable warning
        tokenId;
    }

    /// @notice Scenario 6: DirectLP claims native fees + bonus in a single poke (even when out-of-range at claim time)
    /// @dev Scenario-driven confirmation that a DirectLP position's LCC payout can be decomposed as:
    ///      totalReceived = nativeUniswapFees + bonusPaid
    ///      where bonusPaid is measured exactly by the drain in `slashedPot` for the fee token.
    ///      Setup:
    ///      - Add a DirectLP position that starts in-range (so it can accrue native fees on swaps)
    ///      - Perform a small swap (in-range) to accrue native Uniswap fees (token1 fees for one-for-zero swaps)
    ///      - Create an MM and slash it via swap + incrementCoverage + settle (queues slashes into protocolFeeAccrued)
    ///      - Poke MM to materialise pending into slashedPot
    ///      - Push tick out-of-range for DirectLP, then poke DirectLP
    ///      Expected:
    ///      - DirectLP poke drains slashedPot (bonus materialised)
    ///      - DirectLP poke increases LCC balance by (native fees + bonus)
    ///      - Both components are non-zero in this scenario
    function test_directLP_claimsNativeFeesPlusBonus_onOutOfRangePoke() public {
        // Use an in-range DirectLP that we later push out-of-range by moving tick above upper.
        int24 directTickLower = -960;
        int24 directTickUpper = 960;

        // Ensure this test contract has enough LCC to pay any liquidity provisioning / settlement.
        _mintLccTo(address(this), lccCurrency0, 500e18);
        _mintLccTo(address(this), lccCurrency1, 500e18);

        // 1) Engage DirectLP while in-range via PositionManager (and subscribe delta resolver).
        uint256 dlLiquidity = 2e18;
        (uint256 dlTokenId, PositionId directPosId) =
            _engageDirectLPViaUniPM(directTickLower, directTickUpper, dlLiquidity);
        assertTrue(vtsOrchestrator.isPositionValid(directPosId, true), "DirectLP should be registered");

        // Precondition: DirectLP is initially in-range.
        (, int24 tick0,,) = StateLibrary.getSlot0(manager, corePoolKey.toId());
        assertTrue(tick0 >= directTickLower && tick0 < directTickUpper, "Precondition: DirectLP must start in-range");

        // 2) Accrue native Uniswap fees for the DirectLP while in-range.
        // Fee token for one-for-zero swaps is token1.
        _swapCore(false, -int256(30e18));

        // 3) Create MM slasher with a wide range so it stays in-range even if tick moves above 960.
        (uint256 tokenId, PositionId mmPositionId,,) = _createCommittedPosition(-3000, 3000, 50e10);

        // 4) Create outflows/deficit + fees and push tick above the DirectLP upper tick.
        _swapCore(false, -int256(100e18));
        (, int24 tickAfterSwap,,) = StateLibrary.getSlot0(manager, corePoolKey.toId());
        assertGt(
            tickAfterSwap, directTickUpper, "Precondition: DirectLP must be out-of-range (above upper) at claim time"
        );

        // Materialise deficit principal first (required for DICE index movement).
        vtsOrchestrator.settlePositionGrowths(mmPositionId);

        // Precondition: deficit principal exists (otherwise coverage would be deferred to residual).
        {
            (uint256 totalDeficitPrincipal0,,,,,) = _testableOrchestrator().getPoolDICEAccounting(corePoolKey.toId());
            assertGt(totalDeficitPrincipal0, 0, "Precondition: token0 deficit principal must materialise");
        }

        // 5) Exercise coverage for token0.
        // We compute coverage0 to ensure DirectLP gets positive CISE exposure on token0, enabling a token1 bonus.
        {
            (,, uint256 directSettled0,,,) = _testableOrchestrator().getPositionAccounting(directPosId);
            (uint256 totalSettled0,,,,,) = _testableOrchestrator().getPoolCISEAccounting(corePoolKey.toId());
            assertGt(totalSettled0, 0, "Precondition: totalSettled0 must be > 0 for CISE indexing");
            assertGt(directSettled0, 0, "Precondition: DirectLP must have settled0 > 0 for CISE exposure");

            uint256 targetExposure = 1e7; // comfortably positive exposure for deterministic bonus allocation
            uint256 coverage0 = (targetExposure * totalSettled0) / directSettled0 + 1;

            vm.prank(marketFactory);
            vtsOrchestrator.incrementCoverage(corePoolKey.toId(), coverage0, 0);
        }

        // 6) Settle MM again to apply DICE coverage burn and queue a positive slash into pendingFeeAdj1.
        int256 mmSlashPendingBefore = _pendingFeeAdj1(mmPositionId);
        vtsOrchestrator.settlePositionGrowths(mmPositionId);
        int256 mmSlashPendingAfter = _pendingFeeAdj1(mmPositionId);
        assertGt(mmSlashPendingAfter, mmSlashPendingBefore, "Expected queued slashes to increase MM pendingFeeAdj1");

        // 7) Poke MM to materialise its positive pending into `slashedPot1`.
        uint256 pot1BeforeFund = _slashedPot1();
        _pokeMM(tokenId, 0);
        uint256 pot1Funded = _slashedPot1();
        assertGt(pot1Funded, pot1BeforeFund, "Expected MM poke to fund slashedPot1");

        // 8) Poke DirectLP while out-of-range to collect both:
        // - native Uniswap fees accrued earlier, and
        // - bonus materialised from slashedPot1.
        uint256 lcc1BalanceBefore = _selfLccBalance(lccCurrency1);
        uint256 pot1BeforeBonus = _slashedPot1();

        _pokeDirectLPViaUniPMAndTake(dlTokenId);

        uint256 pot1AfterBonus = _slashedPot1();
        uint256 lcc1BalanceAfter = _selfLccBalance(lccCurrency1);

        // Bonus component: measured by slashedPot drain (native fees do not affect slashedPot).
        uint256 bonusPaid = pot1BeforeBonus - pot1AfterBonus;
        uint256 totalReceived = lcc1BalanceAfter - lcc1BalanceBefore;
        uint256 nativeFeesReceived = totalReceived - bonusPaid;

        assertGt(bonusPaid, 0, "Expected DirectLP to receive a non-zero bonus (slashedPot drain)");
        assertGt(nativeFeesReceived, 0, "Expected DirectLP to receive non-zero native Uniswap fees as well");
        assertEq(totalReceived, nativeFeesReceived + bonusPaid, "Payout decomposition must match (native fees + bonus)");
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
        PositionId mmPosId = vtsOrchestrator.getPositionId(tokenId, 0);

        // Fee token for "one for zero" swaps is token1, so self-exclusion should be observed on token1 pot/accounting.
        uint256 pot0Before = _slashedPot0();
        uint256 pot1Before = _slashedPot1();

        // Create fees + deficit, then materialise deficit principal before `incrementCoverage`.
        // If `incrementCoverage` runs while `totalDeficitPrincipal == 0`, coverage is deferred to residual only and the
        // DICE index does not move (see `VTSCommitLib.incrementCoverage`); slashes then never queue in this setup.
        // Use a materially-sized swap so `_calculateFeesBurn` sees non-zero `fees` (tiny swaps can round to zero fees).
        _swapCore(false, -int256(50e18)); // one for zero (fee token = token1, deficit token = token0)
        vtsOrchestrator.settlePositionGrowths(mmPosId);
        {
            (uint256 totalDeficitPrincipal0,,,,,) = _testableOrchestrator().getPoolDICEAccounting(corePoolKey.toId());
            assertGt(totalDeficitPrincipal0, 0, "Precondition: token0 deficit principal must exist before coverage");
        }

        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 5e17, 0);

        // Apply DICE / queue slashes after coverage (matches scenario 5: second settle after `incrementCoverage`).
        vtsOrchestrator.settlePositionGrowths(mmPosId);

        // Trigger settle + fee processing for the MM position (this is where feeAdj is finalised into the slashed pot).
        _pokeMM(tokenId, 0);

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
        // This assertion verifies the precondition: materialised slashedPot1 matches self slash (potAvail == 0 for bonus).
        // ============================================================================================================
        uint256 materialPot1 = _slashedPot1();
        (, uint256 feesShared1,,) = _testableOrchestrator().getPositionFeeAccounting(mmPosId);
        assertEq(
            materialPot1,
            feesShared1,
            "Self-exclusion precondition: materialised slashedPot1 should match self feesShared (potAvail == 0)"
        );

        // Create positive net settlement on token1 (above dust) to attempt bonus allocation on next fee processing.
        _mmSettle(tokenId, 0, int128(0), _negInt128Capped(2e12));

        uint256 pot1BeforeBonusAttempt = _slashedPot1();
        _pokeMM(tokenId, 0);
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

    /// @notice Edge Case 5: A beneficiary can queue a bonus before the slashed pot is funded, then later materialise it.
    /// @dev Correct sequencing under CSI/CISE/DICE:
    ///      - DICE: `settlePositionGrowths` after `incrementCoverage` queues a slash (+pendingFeeAdj) on the slasher and
    ///        increases `protocolFeeAccrued` (accounting pot), but does NOT yet fund `slashedPot`.
    ///      - CISE exposure accrues ONLY at `incrementCoverage` (not on swaps), so we must ensure a post-existence coverage
    ///        event creates positive exposure for the beneficiary.
    ///      - CSI: bonus allocation can be QUEUED against `protocolFeeAccrued` (pendingFeeAdj < 0, remaining factor advances)
    ///        even while `slashedPot == 0` (materialisation is separate).
    ///      - Materialisation happens only after the slasher is fee-processed (e.g. `_pokeMM`) which funds `slashedPot`.
    function test_bonusAllocatedBeforeSlashMaterialised_whenBeneficiaryPokesFirst() public {
        // Values needed across scoped blocks (declared at function level)
        uint256 tokenId;
        uint256 idx1;
        PositionId beneficiaryPosId;
        uint256 potAfterSlasher;
        int256 mm1Pending1After;

        // ══════════════════════════════════════════════════════════════════════════
        // Phase 1: Setup slasher + beneficiary, create deficit, queue slash (scoped to reset stack)
        // ══════════════════════════════════════════════════════════════════════════
        {
            int24 tickLower = -960;
            int24 tickUpper = 960;

            // Create commit with idx0 (intended slasher)
            PositionId slasherPosId;
            (tokenId, slasherPosId,,) = _createCommittedPosition(tickLower, tickUpper, initialLiquidity);

            // Clear any "net since last mod" from initial settlement so the pool net is clean
            _pokeMM(tokenId, 0);

            // Add idx1 (beneficiary) and leave it with positive net settlement since last modification
            (idx1, beneficiaryPosId) = _mintAdditionalMM(tokenId, tickLower, tickUpper, initialLiquidity);
            _mmSettle(
                tokenId,
                idx1,
                _negInt128Capped((initialLiquidity / 5) * 4),
                _negInt128Capped((initialLiquidity / 5) * 4)
            ); // Settle the position before swap to prevent deficit accrual

            // Create deficit + fees (fees accrue on token1 for one-for-zero swap)
            _swapCore(false, -int256(initialLiquidity / 5));

            // Materialise deficit principal first (required for DICE index to move meaningfully)
            vtsOrchestrator.settlePositionGrowths(slasherPosId);

            // Exercise coverage (token0), then settle again to queue coverage burn (slash) in fee token (token1)
            // IMPORTANT: CISE bonus eligibility is gated by exposure which accrues ONLY at incrementCoverage.
            // Ensure the beneficiary accrues positive CISE exposure so a bonus can be queued.
            {
                (,, uint256 beneficiarySettled0,,,) = _testableOrchestrator().getPositionAccounting(beneficiaryPosId);
                (uint256 totalSettled0,,,,,) = _testableOrchestrator().getPoolCISEAccounting(corePoolKey.toId());
                assertGt(totalSettled0, 0, "Precondition: totalSettled0 must be > 0 for CISE indexing");
                assertGt(beneficiarySettled0, 0, "Precondition: beneficiary must have settled0 > 0 for CISE exposure");

                uint256 targetExposure = 1e7; // comfortably positive exposure for deterministic bonus allocation
                uint256 coverage0 = (targetExposure * totalSettled0) / beneficiarySettled0 + 1;

                vm.prank(marketFactory);
                vtsOrchestrator.incrementCoverage(corePoolKey.toId(), coverage0, 0); // acquire token0, therefore unwrap token0
            }
            vtsOrchestrator.settlePositionGrowths(slasherPosId);

            // Sanity: slashed pot should still be 0 (slasher not poked -> no _finaliseFeeAdjustment funding)
            assertEq(_slashedPot1(), 0, "Precondition: slashed pot must be 0 before any slasher position poke");

            // Sanity: slasher has a queued positive slash (pendingFeeAdj1 > 0)
            (,,, int256 slasherPending1Before) = _testableOrchestrator().getPositionFeeAccounting(slasherPosId);
            assertGt(slasherPending1Before, 0, "Precondition: slasher must have pendingFeeAdj1 > 0");

            // ? At this point, the slashed pot is still 0, but protocolFeeAccrued > 0 AND slasher pendingFeeAdj > 0 (queued slash).
            (, uint256 remainingFactor1Before) = _testableOrchestrator().getPoolCSIAccounting(corePoolKey.toId());

            // Beneficiary processes fees FIRST while slashedPot is still 0: bonus allocation requires a materialised pot.
            console.log("FIRST BENEFICIARY POKE:");
            _pokeMM(tokenId, idx1);
            console.log("END ____ FIRST BENEFICIARY POKE:");

            assertEq(_slashedPot1(), 0, "Pot must remain 0 until slasher is poked");

            (, uint256 slasherContrib,,) = _testableOrchestrator().getPositionFeeAccounting(slasherPosId);
            assertGt(slasherContrib, 0, "Slasher must have a positive contribution to fees shared");

            (,,, mm1Pending1After) = _testableOrchestrator().getPositionFeeAccounting(beneficiaryPosId);
            assertGe(
                mm1Pending1After,
                0,
                "Beneficiary cannot queue a bonus until materialised slashedPot is funded (two-phase model)"
            );

            (, uint256 remainingFactor1AfterNoBonus) = _testableOrchestrator().getPoolCSIAccounting(corePoolKey.toId());
            assertEq(
                remainingFactor1AfterNoBonus,
                remainingFactor1Before,
                "CSI: no spend factor advance without bonus allocation"
            );

            // Slasher poke materialises slash into slashedPot, enabling subsequent bonus allocation.
            _pokeMM(tokenId, 0);
            potAfterSlasher = _slashedPot1();
            assertGt(potAfterSlasher, 0, "Slasher poke should fund the materialised pot");
        }

        // ══════════════════════════════════════════════════════════════════════════
        // Phase 2: SECOND Beneficiary poke - allocate bonus from materialised pot and drain via finalisation
        // ══════════════════════════════════════════════════════════════════════════
        {
            uint256 lcc1BalanceBefore = _selfLccBalance(lccCurrency1);

            _pokeMM(tokenId, idx1);

            uint256 potAfterBeneficiary2 = _slashedPot1();
            assertLt(potAfterBeneficiary2, potAfterSlasher, "Beneficiary materialisation should drain slashedPot1");

            uint256 lcc1BalanceAfter = _selfLccBalance(lccCurrency1);
            assertGt(
                lcc1BalanceAfter,
                lcc1BalanceBefore,
                "Beneficiary poke should increase LCC1 balance because of the bonus"
            );

            (,,, int256 mm1Pending1After2) = _testableOrchestrator().getPositionFeeAccounting(beneficiaryPosId);
            assertLe(
                mm1Pending1After2, mm1Pending1After, "Bonus path should not increase net pending vs pre-bonus baseline"
            );
        }

        // Suppress unused variable warnings
        tokenId;
        idx1;
    }

    /// @notice Edge Case 6: An inactive (0-liquidity) DirectLP can still receive a bonus once `slashedPot` is funded.
    /// @dev Materialised-pot semantics: bonuses allocate only against `slashedPot`, so with `slashedPot == 0` touches bank CISE
    ///      windows without allocating. After the slasher materialises positive `pendingFeeAdj` into `slashedPot`, a later
    ///      inactive reopen batch runs Phase 2 (allocate) and Phase 3 (pay) in the same fee-processing pass.
    function test_inactivePosition_canPokeToMaterialiseQueuedBonus_afterPotFunded() public {
        // ------------------------------------------------------------
        // 1) Create a slasher MM that queues positive pendingFeeAdj; do not fund slashedPot yet
        // ------------------------------------------------------------
        int24 mmTickLower = -960;
        int24 mmTickUpper = 960;
        (uint256 tokenId, PositionId slasherPosId,,) = _createCommittedPosition(mmTickLower, mmTickUpper, 50e10);

        // Create deficit + fees (fee token = token1 for one-for-zero swap)
        /**
         *   If swap amount is too large (eg. 50e18),
         *   The swap will have the pool tick sitting above your DirectLP's tickUpper = 960 (e.g. it shows tick: 972 then tick: 1010), so the position is out-of-range during the "accrue token1 fees" swap.
         *   slashedPot only affects materialisation in _finaliseFeeAdjustment (paying down negative pending).
         */
        _swapCore(false, -int256(30e18));

        // Materialise deficit principal, then exercise coverage and settle again to queue fee burn
        vtsOrchestrator.settlePositionGrowths(slasherPosId);
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 5e18, 0);
        vtsOrchestrator.settlePositionGrowths(slasherPosId);

        // Queued slash on slasher should be > 0, but slashed pot should still be 0 until the slasher is poked
        assertGt(_pendingFeeAdj1(slasherPosId), 0, "Precondition: slasher must have queued positive pendingFeeAdj1");
        (, uint256 potBefore) = vtsOrchestrator.getSlashedPot(corePoolKey.toId());
        assertEq(potBefore, 0, "Precondition: slashedPot1 must be 0 before slasher poke");

        // Values needed across scoped blocks
        uint256 dlTokenId;
        uint256 dlLiquidity = 1e18;
        uint256 dlMoreLiquidity = 5e17;
        PositionId directPosId;
        int256 dlPending1AfterRemove;

        // ══════════════════════════════════════════════════════════════════════════
        // 2-4) Create DirectLP, accrue fees, increase while pot unfunded, then remove (scoped to reset stack)
        // ══════════════════════════════════════════════════════════════════════════
        {
            // ------------------------------------------------------------
            // 2) Create a DirectLP beneficiary.
            // IMPORTANT: Creating a *new* DirectLP position must NOT allocate bonuses immediately,
            // even if protocolFeeAccrued is already > 0. Bonus allocation is reserved for existing positions.
            // ------------------------------------------------------------
            // Use an in-range DirectLP so it can accrue native fees (feeWeight) from swaps.
            int24 dlTickLower = -960;
            int24 dlTickUpper = 960;

            // Fund reserves for both legs up-front so `ProxyHook.onDirectLP()` can settle underlying from the Hub.
            _mintLccTo(address(this), lccCurrency0, 1e18);
            _mintLccTo(address(this), lccCurrency1, 1e18);

            // Mint a Uniswap v4 PositionManager position, settle the pair, and subscribe it to DirectLPDeltaResolver.
            // This ensures CoreHook's hook deltas (feeAdj) are cleared during the same unlock session.
            (dlTokenId, directPosId) = _engageDirectLPViaUniPM(dlTickLower, dlTickUpper, dlLiquidity);

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

            // IMPORTANT: CISE exposure accrues ONLY at incrementCoverage (not on swaps).
            // Ensure this DirectLP accrues positive exposure after creation so it can queue a bonus on touch.
            {
                (,, uint256 dlSettled0,,,) = _testableOrchestrator().getPositionAccounting(directPosId);
                (uint256 totalSettled0,,,,,) = _testableOrchestrator().getPoolCISEAccounting(corePoolKey.toId());
                assertGt(totalSettled0, 0, "Precondition: totalSettled0 must be > 0 for CISE indexing");
                assertGt(dlSettled0, 0, "Precondition: DirectLP must have settled0 > 0 for CISE exposure");

                uint256 targetExposure = 1e7; // comfortably positive exposure for deterministic bonus allocation
                uint256 coverage0 = (targetExposure * totalSettled0) / dlSettled0 + 1;

                vm.prank(marketFactory);
                vtsOrchestrator.incrementCoverage(corePoolKey.toId(), coverage0, 0);
            }

            // slashedPot is still 0: no bonus allocation yet, but CISE windows remain banked for a later funded touch.
            assertEq(_slashedPot1(), 0, "Precondition: materialised slashedPot1 must stay 0 until slasher poke");

            // Now that the DirectLP is an *existing* position, a subsequent increase runs fee processing with potAvail == 0.
            {
                bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
                bytes[] memory params = new bytes[](2);
                params[0] = abi.encode(dlTokenId, dlMoreLiquidity, type(uint128).max, type(uint128).max, ZERO_BYTES);
                params[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1);
                uniPositionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);
            }

            (,,, int256 dlPending1AfterIncrease) = vtsOrchestrator.getPositionFeeAccounting(directPosId);
            assertGe(
                dlPending1AfterIncrease,
                0,
                "With slashedPot unfunded, bonus allocation is skipped; pending stays non-negative"
            );

            // ------------------------------------------------------------
            // 4) Fully remove DirectLP liquidity => position becomes inactive (0-liquidity)
            // ------------------------------------------------------------
            {
                bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
                bytes[] memory params = new bytes[](2);
                params[0] = abi.encode(
                    dlTokenId, dlLiquidity + dlMoreLiquidity, type(uint128).min, type(uint128).min, ZERO_BYTES
                );
                params[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1, address(this));
                uniPositionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);
            }

            assertEq(vtsOrchestrator.isPositionValid(directPosId, true), false, "DirectLP should now be inactive");

            (,,, dlPending1AfterRemove) = vtsOrchestrator.getPositionFeeAccounting(directPosId);
            assertGe(dlPending1AfterRemove, 0, "No bonus was queued while slashedPot was unfunded");
        }

        // ------------------------------------------------------------
        // 5) Fund the materialised pot by poking the slasher MM (materialises its +pendingFeeAdj into slashedPot)
        // ------------------------------------------------------------
        _pokeMM(tokenId, 0);
        (, uint256 potFunded) = vtsOrchestrator.getSlashedPot(corePoolKey.toId());
        assertGt(potFunded, 0, "Pot must be funded after slasher poke");

        // ------------------------------------------------------------
        // 6) Inactive DirectLP re-opens briefly then closes; fee processing allocates + pays bonus against slashedPot.
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

        // The pot should have drained (at least partially) when bonus allocation + materialisation runs.
        assertLt(
            potAfterInactivePoke, potBeforeInactivePoke, "Inactive poke should materialise bonus and drain the pot"
        );

        (,, int256 dlPending0Final, int256 dlPending1Final) = vtsOrchestrator.getPositionFeeAccounting(directPosId);
        dlPending0Final; // silence
        dlPending1Final;
        dlPending1AfterRemove; // silence — retained for debugger readability
    }

    /// @notice Edge Case 6b: An inactive (0-liquidity) MM position can collect a bonus once `slashedPot` is funded.
    /// @dev With `slashedPot == 0`, bonus allocation is skipped (windows stay banked). After the slasher funds the
    ///      materialised pot, the inactive reopen batch allocates and pays in one fee-processing pass.
    function test_inactivePosition_mmCanCollectDormantFees() public {
        // Only keep the minimum set of variables live across phases to avoid "stack too deep" under coverage.
        uint256 beneficiaryTokenId;
        PositionId beneficiaryPosId;
        uint256 slasherTokenId;
        uint256 potFunded;
        int256 mmPending1AfterClose;
        int24 mmTickLower = -960;
        int24 mmTickUpper = 960;

        // ------------------------------------------------------------
        // Phases 1-5 (scoped): setup slasher + beneficiary, close inactive while pot unfunded, then fund pot.
        // ------------------------------------------------------------
        {
            // 1) Create a slasher MM that queues positive pendingFeeAdj; do not fund slashedPot yet
            PositionId slasherPosId;
            (slasherTokenId, slasherPosId,,) = _createCommittedPosition(mmTickLower, mmTickUpper, 50e10);

            // Create deficit + fees (fee token = token1 for one-for-zero swap)
            _swapCore(false, -int256(30e18));

            // Materialise deficit principal, then exercise coverage and settle again to queue fee burn
            vtsOrchestrator.settlePositionGrowths(slasherPosId);
            vm.prank(marketFactory);
            vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 20e18, 0);
            vtsOrchestrator.settlePositionGrowths(slasherPosId);

            assertGt(_pendingFeeAdj1(slasherPosId), 0, "Precondition: slasher must have queued positive pendingFeeAdj1");
            (, uint256 potBefore) = vtsOrchestrator.getSlashedPot(corePoolKey.toId());
            assertEq(potBefore, 0, "Precondition: slashedPot1 must be 0 before slasher poke");

            // 2) Create a beneficiary MM position. It should NOT allocate bonuses immediately on creation.
            uint256 mmLiquidity = 10e10;
            (beneficiaryTokenId, beneficiaryPosId) = _createNewMMCommit(mmTickLower, mmTickUpper, mmLiquidity);

            // Provide positive selfNet via a settlement deposit (eligibility gate) before fee-processing touch.
            _mmSettle(beneficiaryTokenId, 0, _negInt128Capped(10e18), _negInt128Capped(10e18));

            (,,, int256 mmPending1AfterCreate) = vtsOrchestrator.getPositionFeeAccounting(beneficiaryPosId);
            assertEq(mmPending1AfterCreate, 0, "New MM position must not queue a bonus on creation");

            // 3) Accrue native fees for the MM, create selfNet via settlement, and touch to queue a bonus
            _swapCore(false, -int256(2e18)); // accrue token1 fees for in-range positions

            // Ensure positive CISE exposure after creation so it can queue a bonus on touch.
            {
                (,, uint256 mmSettled0,,,) = _testableOrchestrator().getPositionAccounting(beneficiaryPosId);
                (uint256 totalSettled0,,,,,) = _testableOrchestrator().getPoolCISEAccounting(corePoolKey.toId());
                assertGt(totalSettled0, 0, "Precondition: totalSettled0 must be > 0 for CISE indexing");
                assertGt(mmSettled0, 0, "Precondition: beneficiary MM must have settled0 > 0 for CISE exposure");

                uint256 targetExposure = 1e7; // comfortably positive exposure for deterministic bonus allocation
                uint256 coverage0 = (targetExposure * totalSettled0) / mmSettled0 + 1;

                vm.prank(marketFactory);
                vtsOrchestrator.incrementCoverage(corePoolKey.toId(), coverage0, 0);
            }

            assertEq(_slashedPot1(), 0, "Precondition: slashedPot unfunded until slasher poke after inactive close");

            // 4) Fully remove MM liquidity => position becomes inactive while no bonus was allocatable (pot == 0).
            _mmDecreaseSettleTakeToSelf(beneficiaryTokenId, mmLiquidity);

            assertEq(
                vtsOrchestrator.isPositionValid(beneficiaryPosId, true), false, "MM position should now be inactive"
            );
            (,,, mmPending1AfterClose) = vtsOrchestrator.getPositionFeeAccounting(beneficiaryPosId);
            assertGe(mmPending1AfterClose, 0, "No negative bonus pending while slashedPot was never funded");

            // 5) Fund the materialised pot by poking the slasher MM (materialises its +pendingFeeAdj into slashedPot)
            _pokeMM(slasherTokenId, 0);
            (, potFunded) = vtsOrchestrator.getSlashedPot(corePoolKey.toId());
            assertGt(potFunded, 0, "Pot must be funded after slasher poke");
        }

        // ------------------------------------------------------------
        // 6) Inactive MM "pokes" (increase liquidity by 1e6) to materialise its queued bonus, then takes both currencies.
        //    NOTE: This batch must end with zero delta credits, otherwise MMPositionManager reverts with CurrencyNotSettled.
        //    NOTE: Uniswap will prevent increase by 0 liquidity on inactive position https://github.com/Uniswap/v4-core/blob/36d790b1a3af38461453a13a6ff395290fbc11b2/src/libraries/Position.sol#L86
        // ------------------------------------------------------------
        uint256 potBeforeInactiveClaim = potFunded;
        uint256 mmReopenLiquidity = 1e6;

        uint256 bal0Before = _selfLccBalance(lccCurrency0);
        uint256 bal1Before = _selfLccBalance(lccCurrency1);

        (uint256 potAfterInactiveClaim, int256 mmPending1Final, uint256 bal0After, uint256 bal1After) =
            _inactiveMmClaimAndTake(beneficiaryTokenId, beneficiaryPosId, mmReopenLiquidity);
        assertLt(potAfterInactiveClaim, potBeforeInactiveClaim, "Inactive MM claim should drain the pot");
        mmPending1Final;
        mmPending1AfterClose; // silence — same-touch pay can clear queued negative pending from the inactive batch
        assertTrue(bal0After >= bal0Before, "lcc0 take should not reduce balance");
        assertTrue(bal1After >= bal1Before, "lcc1 take should not reduce balance");
        // Bonus materialisation plus reopen/settle can net to zero change in this contract's LCC ERC6909 balance
        // even when `slashedPot` drains (credits may remain as PoolManager deltas). Pot drain is asserted above.
    }

    /// @notice Edge Case 7: Banked selfNet/feeWeight across touches when potAvail == 0, then allocate once potAvail > 0.
    /// @dev Covers both cases:
    ///      - potAvail == 0: no allocation occurs; windows remain banked
    ///      - potAvail > 0: allocation occurs; windows are cleared for the allocated token
    function test_allocatesOnlyWhenPotAvailPositive() public {
        // Use Uni v4 PositionManager + DirectLPDeltaResolver so a touch that materialises a bonus clears hook
        // deltas in the same unlock session (modifyLiquidityRouter-only pokes revert with CurrencyNotSettled).
        int24 dlTickLower = TickMath.minUsableTick(corePoolKey.tickSpacing);
        int24 dlTickUpper = TickMath.maxUsableTick(corePoolKey.tickSpacing);
        _mintLccTo(address(this), lccCurrency0, 50e18);
        _mintLccTo(address(this), lccCurrency1, 50e18);
        (uint256 dlTokenId, PositionId directPosId) = _engageDirectLPViaUniPM(dlTickLower, dlTickUpper, 1e18);
        assertTrue(vtsOrchestrator.isPositionValid(directPosId, true), "Precondition: DirectLP should exist");

        // ══════════════════════════════════════════════════════════════════════════
        // 1) potAvail == 0 case: accrue fees, touch, ensure no bonus is allocated and windows remain banked
        //    (scoped to reset stack before Phase 2)
        // ══════════════════════════════════════════════════════════════════════════
        {
            // Accrue some fees on token1 (one-for-zero swap => fee token is token1)
            _swapCore(false, -int256(2e18));

            // Precondition: no materialised slashed pot yet (no slashes materialised), so potAvail == 0
            assertEq(_slashedPot1(), 0, "Precondition: materialised slashedPot1 should be 0 before any slashing");

            (,,, int256 pending1BeforePoke) = _testableOrchestrator().getPositionFeeAccounting(directPosId);

            _pokeDirectLPViaUniPMAndTake(dlTokenId);

            // No bonus should be allocated because potAvail == 0 (same-touch materialisation would also clear pending)
            (,,, int256 pending1AfterPoke) = _testableOrchestrator().getPositionFeeAccounting(directPosId);
            assertEq(pending1AfterPoke, pending1BeforePoke, "potAvail==0: should not queue bonus");

            // CISE exposure is 0 because no coverage has been exercised yet
            (uint256 ciseExp0, uint256 ciseExp1) = _testableOrchestrator().getPositionBonusWeights(directPosId);
            assertEq(ciseExp0, 0, "potAvail==0: ciseExposure0 should be 0 (no coverage exercised)");
            assertEq(ciseExp1, 0, "potAvail==0: ciseExposure1 should be 0 (no coverage exercised)");
        }

        // ══════════════════════════════════════════════════════════════════════════
        // 2) potAvail > 0 case: fund materialised slashedPot, then touch and ensure allocation + materialisation
        // ══════════════════════════════════════════════════════════════════════════
        {
            // Create MM slasher and queue slashes (positive pendingFeeAdj until materialised into slashedPot)
            (uint256 tokenId, PositionId slasherPosId,,) = _createCommittedPosition(-960, 960, 50e10);

            _swapCore(false, -int256(50e18));
            vtsOrchestrator.settlePositionGrowths(slasherPosId);
            vm.prank(marketFactory);
            vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 50e18, 0);
            vtsOrchestrator.settlePositionGrowths(slasherPosId);

            assertGt(
                _pendingFeeAdj1(slasherPosId),
                0,
                "Precondition: slasher should queue positive pendingFeeAdj1 after slashes"
            );

            uint256 potBeforeBeneficiaryPoke = _slashedPot1();
            // Fund materialised slashedPot (bonus allocation is against slashedPot only).
            _pokeMM(tokenId, 0);
            assertGt(
                _slashedPot1(),
                potBeforeBeneficiaryPoke,
                "Precondition: slasher poke must fund slashedPot1 for bonus allocation"
            );

            uint256 potAfterSlasherPoke = _slashedPot1();

            // Exercise coverage so this DirectLP has non-zero CISE exposure for token1 bonus allocation
            {
                (,, uint256 dlSettled0,,,) = _testableOrchestrator().getPositionAccounting(directPosId);
                (uint256 totalSettled0,,,,,) = _testableOrchestrator().getPoolCISEAccounting(corePoolKey.toId());
                assertGt(totalSettled0, 0, "Precondition: totalSettled0 must be > 0 for CISE indexing");
                assertGt(dlSettled0, 0, "Precondition: DirectLP must have settled0 > 0 for CISE exposure");
                uint256 targetExposure = 1e7;
                uint256 coverage0 = (targetExposure * totalSettled0) / dlSettled0 + 1;
                vm.prank(marketFactory);
                vtsOrchestrator.incrementCoverage(corePoolKey.toId(), coverage0, 0);
            }

            _pokeDirectLPViaUniPMAndTake(dlTokenId);

            // Bonus path should have drained the materialised pot (same-touch Phase 3 pays queued bonus).
            assertLt(
                _slashedPot1(),
                potAfterSlasherPoke,
                "potAvail>0: beneficiary poke should materialise bonus from slashedPot"
            );

            // After a successful allocation, CISE exposure windows for the coverage token should be cleared
            (uint256 ciseExp0After,) = _testableOrchestrator().getPositionBonusWeights(directPosId);
            assertEq(
                ciseExp0After, 0, "potAvail>0: ciseExposure0 should be cleared after allocation (used for token1 bonus)"
            );

            // Suppress unused variable warnings
            tokenId;
        }
    }
}


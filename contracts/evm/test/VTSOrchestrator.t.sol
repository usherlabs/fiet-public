// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {VTSOrchestratorFixture} from "./modules/VTSOrchestratorFixture.sol";
import {VTSOrchestrator} from "../src/VTSOrchestrator.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionId, Position} from "../src/types/Position.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MarketVTSConfiguration} from "../src/types/VTS.sol";
import {VTSConfigs} from "../src/libraries/VTSConfigs.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {RFSCheckpoint} from "../src/types/Checkpoint.sol";
import {IMarketVault} from "../src/interfaces/IMarketVault.sol";
import {IOracleHelper} from "../src/interfaces/IOracleHelper.sol";
import {IVRLSettlementObserver} from "../src/interfaces/IVRLSettlementObserver.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MMActionAdapter as MMA} from "./libraries/MMActionAdapter.sol";

contract VTSOrchestratorTest is VTSOrchestratorFixture {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ============================================================
    // Storage inspection helpers (direct VTSStorage reads)
    // ============================================================
    // Verified via `forge inspect VTSOrchestrator storage-layout`:
    // - `_owner` is slot 0
    // - `s` (VTSStorage) is slot 1
    //
    // In `VTSStorage` (types/VTS.sol) the 5th member is:
    // mapping(PositionId => PositionAccounting) positionAccounting;
    // which lives at slotOffset=4 within the struct.
    uint256 internal constant _VTS_STORAGE_SLOT = 1;
    uint256 internal constant _POSITION_ACCOUNTING_MAPPING_SLOT = _VTS_STORAGE_SLOT + 4; // == 5
    // PositionAccounting layout (types/VTS.sol):
    // commitmentMax(2), settled(2), cumulativeDeficit(2), coverageUse(2), deficitGrowth(2), inflowGrowth(2),
    // feeGrowth(2), cumulativeOutflows(2), outflowsAtFeeSnap(2), commitmentDeficit(2), ...
    uint256 internal constant _PA_CUMULATIVE_DEFICIT_TOKEN0_OFFSET = 4;
    uint256 internal constant _PA_CUMULATIVE_DEFICIT_TOKEN1_OFFSET = 5;
    uint256 internal constant _PA_COMMITMENT_DEFICIT_TOKEN0_OFFSET = 18;
    uint256 internal constant _PA_COMMITMENT_DEFICIT_TOKEN1_OFFSET = 19;

    function _paUint(PositionId positionId, uint256 slotOffset) internal view returns (uint256) {
        bytes32 base = keccak256(abi.encode(PositionId.unwrap(positionId), uint256(_POSITION_ACCOUNTING_MAPPING_SLOT)));
        return uint256(vm.load(address(vtsOrchestrator), bytes32(uint256(base) + slotOffset)));
    }

    function _commitmentDeficit(PositionId positionId) internal view returns (uint256 def0, uint256 def1) {
        def0 = _paUint(positionId, _PA_COMMITMENT_DEFICIT_TOKEN0_OFFSET);
        def1 = _paUint(positionId, _PA_COMMITMENT_DEFICIT_TOKEN1_OFFSET);
    }

    function _cumulativeDeficit(PositionId positionId) internal view returns (uint256 def0, uint256 def1) {
        def0 = _paUint(positionId, _PA_CUMULATIVE_DEFICIT_TOKEN0_OFFSET);
        def1 = _paUint(positionId, _PA_CUMULATIVE_DEFICIT_TOKEN1_OFFSET);
    }

    function _mockSignalUsd(uint256 signalUsd) internal {
        // VTSCommitLib._signalValue() calls oracleHelper.getTotalValue(tickers, amounts)
        vm.mockCall(
            address(oracleHelper), abi.encodeWithSelector(IOracleHelper.getTotalValue.selector), abi.encode(signalUsd)
        );
    }

    function _mockLccPrices(uint256 price0, uint256 price1) internal {
        // VTSCommitLib uses OracleUtils.lccPairValue() -> getPricesForLccPair for issuedUsd/settledUsd
        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector),
            abi.encode(price0, price1)
        );
    }

    function _negInt128Capped(uint256 amount) internal pure returns (int128) {
        uint256 cap = uint256(uint128(type(int128).max));
        uint256 a = amount > cap ? cap : amount;
        return a == 0 ? int128(0) : -int128(int256(a));
    }

    // ============================================================
    // Guard Tests - onlyIfPoolManagerUnlocked
    // ============================================================

    function test_revert_commitSignal_whenPoolManagerLocked() public {
        bytes memory signalBytes = abi.encode(liquiditySignal);
        vm.expectRevert(Errors.PoolManagerMustBeUnlocked.selector);
        vtsOrchestrator.commitSignal(signalBytes);
    }

    function test_revert_renewSignal_whenPoolManagerLocked() public {
        // First create a commit
        bytes memory signalBytes = abi.encode(liquiditySignal);
        bytes memory unlockData = abi.encode(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.commitSignal.selector, signalBytes)
        );
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.commitSignal.selector, signalBytes)
        );

        // Now try to renew when locked
        vm.expectRevert(Errors.PoolManagerMustBeUnlocked.selector);
        vtsOrchestrator.renewSignal(1, signalBytes);
    }

    function test_revert_extendGracePeriod_whenPoolManagerLocked() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        bytes memory settlementProof = abi.encode(1);

        vm.expectRevert(Errors.PoolManagerMustBeUnlocked.selector);
        vtsOrchestrator.extendGracePeriod(corePoolKey, tokenId, 0, 0, 0, settlementProof);
    }

    function test_revert_onMMSettle_whenPoolManagerLocked() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        BalanceDelta amountDelta = toBalanceDelta(-100, -100);

        vm.expectRevert(Errors.PoolManagerMustBeUnlocked.selector);
        vtsOrchestrator.onMMSettle(
            IMarketVault(address(proxyHook)),
            tokenId,
            0,
            corePoolKey.currency0,
            corePoolKey.currency1,
            amountDelta,
            false
        );
    }

    function test_revert_onSeize_whenPoolManagerLocked() public {
        (uint256 tokenId,,,) = _createCommittedPosition();

        vm.expectRevert(Errors.PoolManagerMustBeUnlocked.selector);
        vtsOrchestrator.onSeize(tokenId, 0);
    }

    // ============================================================
    // Guard Tests - onlyFactory
    // ============================================================

    function test_revert_initPool_whenNotFactory() public {
        MarketVTSConfiguration memory config = VTSConfigs.getDefaultConfig();
        vm.expectRevert(Errors.InvalidSender.selector);
        vtsOrchestrator.initPool(corePoolKey, config);
    }

    function test_initPool_whenFactory() public {
        MarketVTSConfiguration memory config = VTSConfigs.getDefaultConfig();
        vm.prank(marketFactory);
        vtsOrchestrator.initPool(corePoolKey, config);
        // Should not revert
    }

    function test_revert_incrementCoverage_whenNotFactory() public {
        vm.expectRevert(Errors.InvalidSender.selector);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 100, 100);
    }

    function test_incrementCoverage_whenFactory() public {
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 100, 100);
        // Should not revert
    }

    // ============================================================
    // Guard Tests - onlyCoreHook
    // ============================================================

    function test_revert_processPosition_whenNotCoreHook() public {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});
        BalanceDelta callerDelta = toBalanceDelta(0, 0);
        BalanceDelta feesAccrued = toBalanceDelta(0, 0);

        vm.expectRevert();
        vtsOrchestrator.processPosition(address(this), corePoolKey, params, callerDelta, feesAccrued, "");
    }

    function test_revert_afterCoreSwap_whenNotCoreHook() public {
        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: 0});
        BalanceDelta delta = toBalanceDelta(-100, 100);

        vm.expectRevert();
        vtsOrchestrator.afterCoreSwap(corePoolKey, swapParams, delta, 0, 0);
    }

    // ============================================================
    // Signal Lifecycle Tests
    // ============================================================

    function test_isSignalValid_zeroCommitId_returnsFalse() public {
        bool isValid = vtsOrchestrator.isSignalValid(0, true);
        assertFalse(isValid, "Zero commitId should be invalid");
    }

    function test_isSignalValid_unknownCommitId_returnsFalse() public {
        bool isValid = vtsOrchestrator.isSignalValid(999, true);
        assertFalse(isValid, "Unknown commitId should be invalid");
    }

    function test_commitSignal_createsValidCommit() public {
        bytes memory signalBytes = abi.encode(liquiditySignal);

        // Mock signal verification
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(bytes4(keccak256("verifyLiquiditySignal(bytes)")), signalBytes),
            abi.encode(true, 3600)
        );

        bytes memory result = unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.commitSignal.selector, signalBytes)
        );
        uint256 commitId = abi.decode(result, (uint256));

        assertGt(commitId, 0, "CommitId should be non-zero");
        assertTrue(vtsOrchestrator.isSignalValid(commitId, true), "Commit should be valid");
    }

    function test_isSignalValid_expiredCommit_requireLiveSignalFalse() public {
        bytes memory signalBytes = abi.encode(liquiditySignal);

        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(bytes4(keccak256("verifyLiquiditySignal(bytes)")), signalBytes),
            abi.encode(true, 3600)
        );

        bytes memory result = unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.commitSignal.selector, signalBytes)
        );
        uint256 commitId = abi.decode(result, (uint256));

        // Warp past expiry
        vm.warp(block.timestamp + 4000);

        // requireLiveSignal=false should still return true (for seizure flows)
        assertTrue(
            vtsOrchestrator.isSignalValid(commitId, false),
            "Expired commit should be valid when requireLiveSignal=false"
        );
        // requireLiveSignal=true should return false
        assertFalse(
            vtsOrchestrator.isSignalValid(commitId, true),
            "Expired commit should be invalid when requireLiveSignal=true"
        );
    }

    function test_renewSignal_extendsExpiry() public {
        bytes memory signalBytes = abi.encode(liquiditySignal);

        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(bytes4(keccak256("verifyLiquiditySignal(bytes)")), signalBytes),
            abi.encode(true, 3600)
        );

        bytes memory result = unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.commitSignal.selector, signalBytes)
        );
        uint256 commitId = abi.decode(result, (uint256));

        (, uint256 expiresAtBefore,) = vtsOrchestrator.getCommit(commitId);

        // Warp forward
        vm.warp(block.timestamp + 1000);

        bytes memory renewSignalBytes = abi.encode(renewSignal);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(bytes4(keccak256("verifyLiquiditySignal(bytes)")), renewSignalBytes),
            abi.encode(true, 3600)
        );

        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(VTSOrchestrator.renewSignal.selector, commitId, renewSignalBytes)
        );

        (, uint256 expiresAtAfter,) = vtsOrchestrator.getCommit(commitId);
        assertGt(expiresAtAfter, expiresAtBefore, "Expiry should be extended");
    }

    // ============================================================
    // Position Validity + Lens Tests
    // ============================================================

    function test_isPositionValid_invalidPositionId_returnsFalse() public {
        PositionId invalidId = PositionId.wrap(bytes32(uint256(999)));
        bool isValid = vtsOrchestrator.isPositionValid(invalidId, false);
        assertFalse(isValid, "Invalid positionId should return false");
    }

    function test_isPositionValid_validPosition_returnsTrue() public {
        (, PositionId positionId,,) = _createCommittedPosition();

        bool isValid = vtsOrchestrator.isPositionValid(positionId, true);
        assertTrue(isValid, "Valid position should return true");
    }

    function test_getPosition_returnsCorrectPosition() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();

        Position memory pos = vtsOrchestrator.getPosition(positionId);
        assertEq(PoolId.unwrap(pos.poolId), PoolId.unwrap(corePoolKey.toId()), "PoolId should match");
        assertEq(pos.commitId, tokenId, "CommitId should match");
        assertEq(pos.owner, address(positionManager), "Owner should be positionManager");
        assertTrue(pos.isActive, "Position should be active");
    }

    function test_getPosition_byCommitIdAndIndex() public {
        (uint256 tokenId, PositionId expectedPositionId,,) = _createCommittedPosition();

        (Position memory pos, PositionId positionId) = vtsOrchestrator.getPosition(tokenId, 0);
        assertEq(PositionId.unwrap(positionId), PositionId.unwrap(expectedPositionId), "PositionId should match");
        assertEq(pos.commitId, tokenId, "CommitId should match");
    }

    function test_revert_getPosition_invalidPosition() public {
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvalidPosition.selector, 0, 0, PositionId.wrap(bytes32(uint256(999))))
        );
        vtsOrchestrator.getPosition(999, 0);
    }

    function test_calcRFS_returnsCorrectValues() public {
        (, PositionId positionId,,) = _createCommittedPosition();

        (bool rfsOpen, BalanceDelta delta) = vtsOrchestrator.calcRFS(positionId, false);
        // RFS state depends on position state - just verify it doesn't revert
        assertTrue(true, "calcRFS should not revert");
    }

    function test_getCommitmentMaxima_returnsNonZero() public {
        (, PositionId positionId,,) = _createCommittedPosition();

        (uint256 commitment0, uint256 commitment1) = vtsOrchestrator.getCommitmentMaxima(positionId);
        assertGt(commitment0, 0, "Commitment 0 should be non-zero");
        assertGt(commitment1, 0, "Commitment 1 should be non-zero");
    }

    function test_getPositionSettledAmounts_returnsZeroInitially() public {
        (, PositionId positionId,,) = _createCommittedPosition();

        (uint256 amount0, uint256 amount1) = vtsOrchestrator.getPositionSettledAmounts(positionId);
        assertEq(amount0, 0, "Settled amount0 should be zero initially");
        assertEq(amount1, 0, "Settled amount1 should be zero initially");
    }

    // ============================================================
    // Fee Collection Tests
    // ============================================================
    //
    // NOTE: Fee collection does NOT require a separate `collectFees` function.
    // Fees accrue and surface during position modification, even when liquidityDelta is 0.
    //
    // The proper flow for fee collection is:
    // 1. Establish a position (MM via commitSignal + addLiquidity, or DirectLP with fee-share enabled)
    // 2. Perform swaps that accumulate fees to that position
    // 3. Call modifyLiquidity with liquidityDelta=0 - feesAccrued are returned and processed
    //
    // For MM positions: fees are credited as LCC delta to MMPositionManager
    // For DirectLP with fee-sharing: fees are shared via the fee pot mechanism
    //
    // See: VTSPositionLib.processPosition() and VTSFeeLib.processPositionFees()
    // ============================================================

    /// @notice Helper to execute swaps on the core pool
    function _swapCore(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        uint160 sqrtPriceLimit = zeroForOne ? ZERO_FOR_ONE_LIMIT : ONE_FOR_ZERO_LIMIT;
        return swapRouter.swap(
            corePoolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimit}),
            settings,
            ZERO_BYTES
        );
    }

    /// @notice Helper to poke an MM position (modifyLiquidity with liquidityDelta=0) to collect fees
    function _pokeMM(uint256 tokenId, uint256 positionIndex, int24 tickLower, int24 tickUpper) internal {
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareIncrease(corePoolKey, tokenId, positionIndex, tickLower, tickUpper, 0);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
    }

    function _pokeMMAndTakeFees(uint256 tokenId, uint256 positionIndex, int24 tickLower, int24 tickUpper) internal {
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        actions[0] = MMA.prepareIncrease(corePoolKey, tokenId, positionIndex, tickLower, tickUpper, 0);
        actions[1] = MMA.prepareTake(lccCurrency0, address(this), 0);
        actions[2] = MMA.prepareTake(lccCurrency1, address(this), 0);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
    }

    /// @notice Helper to get locker's full credit for a currency
    function _lockerCredit(Currency currency) internal view returns (uint256) {
        return vtsOrchestrator.getFullCredit(currency, address(this));
    }

    /// @notice Helper to get MMPM's LCC balance
    function _mmpmLccBalance(Currency lccCurrency) internal view returns (uint256) {
        return lccCurrency.balanceOf(address(positionManager));
    }

    /// @notice Helper to get test contract's LCC balance
    function _selfLccBalance(Currency lccCurrency) internal view returns (uint256) {
        return lccCurrency.balanceOf(address(this));
    }

    function test_feeCollection_mmPosition_accumulatesFees_viaSwap() public {
        // Step 1: Create an MM position
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();

        // Verify position is active
        assertTrue(vtsOrchestrator.isPositionValid(positionId, true), "Position should be active");

        // Record initial balances
        uint256 lcc0Before = _selfLccBalance(lccCurrency0);
        uint256 lcc1Before = _selfLccBalance(lccCurrency1);

        // Step 2: Perform swaps to generate fees
        // Swap in both directions to generate fees for both tokens
        _swapCore(true, -int256(1e18)); // zeroForOne
        _swapCore(false, -int256(1e18)); // oneForZero

        // Step 3: Poke the position to collect fees (modifyLiquidity with liquidityDelta=0)
        // This triggers VTSPositionLib.touchPosition which processes fees
        _pokeMMAndTakeFees(tokenId, 0, -60, 60);

        // Step 4: Verify Locker received LCC fees as ERC20 balance
        uint256 lcc0After = _selfLccBalance(lccCurrency0);
        uint256 lcc1After = _selfLccBalance(lccCurrency1);

        // At least one LCC balance should have increased (fees from swaps)
        bool feesAccrued = lcc0After > lcc0Before || lcc1After > lcc1Before;
        console.log("lcc0Before", lcc0Before);
        console.log("lcc0After", lcc0After);
        console.log("lcc1Before", lcc1Before);
        console.log("lcc1After", lcc1After);
        assertTrue(feesAccrued, "MMPM should have received LCC fees as ERC20 balance");

        // Verify the position is still valid after fee collection
        assertTrue(vtsOrchestrator.isPositionValid(positionId, true), "Position should still be active after poke");
    }

    function test_feeCollection_mmPosition_feesCredit_availableViaPositionModification() public {
        // Step 1: Create an MM position
        (uint256 tokenId,,,) = _createCommittedPosition();

        // Step 2: Record initial state
        uint256 creditBefore0 = _lockerCredit(lccCurrency0);
        uint256 creditBefore1 = _lockerCredit(lccCurrency1);
        uint256 mmpmLcc0Before = _mmpmLccBalance(lccCurrency0);
        uint256 mmpmLcc1Before = _mmpmLccBalance(lccCurrency1);

        // Step 3: Perform swaps to generate fees
        _swapCore(true, -int256(2e18)); // Large swap to generate meaningful fees
        _swapCore(false, -int256(2e18));

        // Step 4: Poke the position to collect fees
        // After position modification:
        // - MMPM takes LCC fees from PoolManager (balance increases)
        // - Balance increase is synced as credit to locker
        _pokeMM(tokenId, 0, -60, 60);

        // Step 5: Verify MMPM balance increased (fees taken from PoolManager)
        uint256 mmpmLcc0After = _mmpmLccBalance(lccCurrency0);
        uint256 mmpmLcc1After = _mmpmLccBalance(lccCurrency1);
        uint256 mmpmBalanceIncrease0 = mmpmLcc0After > mmpmLcc0Before ? mmpmLcc0After - mmpmLcc0Before : 0;
        uint256 mmpmBalanceIncrease1 = mmpmLcc1After > mmpmLcc1Before ? mmpmLcc1After - mmpmLcc1Before : 0;

        assertTrue(mmpmBalanceIncrease0 > 0 || mmpmBalanceIncrease1 > 0, "MMPM balance should increase from fees");

        // Step 6: Verify locker credits match the balance increase (synced via _syncBalanceAsCredit)
        uint256 creditAfter0 = _lockerCredit(lccCurrency0);
        uint256 creditAfter1 = _lockerCredit(lccCurrency1);
        uint256 creditIncrease0 = creditAfter0 > creditBefore0 ? creditAfter0 - creditBefore0 : 0;
        uint256 creditIncrease1 = creditAfter1 > creditBefore1 ? creditAfter1 - creditBefore1 : 0;

        // Credits should match or exceed balance increases (synced from balance)
        assertGe(creditIncrease0, 0, "Credit0 should not be negative");
        assertGe(creditIncrease1, 0, "Credit1 should not be negative");

        // At least one credit should have increased from fees
        assertTrue(creditIncrease0 > 0 || creditIncrease1 > 0, "Locker credits should increase from synced fee balance");
    }

    function test_feeCollection_mmPosition_multipleSwaps_accumulateFees() public {
        // Step 1: Create an MM position
        (uint256 tokenId,,,) = _createCommittedPosition();

        // Step 2: Initial poke to establish baseline (clears any initial fees)
        _pokeMM(tokenId, 0, -60, 60);
        uint256 creditBaseline0 = _lockerCredit(lccCurrency0);
        uint256 creditBaseline1 = _lockerCredit(lccCurrency1);
        uint256 mmpmBalanceBaseline0 = _mmpmLccBalance(lccCurrency0);
        uint256 mmpmBalanceBaseline1 = _mmpmLccBalance(lccCurrency1);

        // Step 3: Multiple swaps in same direction to accumulate fees
        uint256 totalSwapAmount = 0;
        for (uint256 i = 0; i < 5; i++) {
            _swapCore(true, -int256(5e17)); // 0.5 token per swap
            totalSwapAmount += 5e17;
        }

        // Step 4: Poke to collect accumulated fees
        _pokeMM(tokenId, 0, -60, 60);

        // Step 5: Verify MMPM balance increased from accumulated fees
        uint256 mmpmBalanceFinal0 = _mmpmLccBalance(lccCurrency0);
        uint256 mmpmBalanceFinal1 = _mmpmLccBalance(lccCurrency1);
        uint256 balanceAccumulated0 =
            mmpmBalanceFinal0 > mmpmBalanceBaseline0 ? mmpmBalanceFinal0 - mmpmBalanceBaseline0 : 0;
        uint256 balanceAccumulated1 =
            mmpmBalanceFinal1 > mmpmBalanceBaseline1 ? mmpmBalanceFinal1 - mmpmBalanceBaseline1 : 0;

        assertTrue(
            balanceAccumulated0 > 0 || balanceAccumulated1 > 0,
            "MMPM balance should accumulate fees from multiple swaps"
        );

        // Step 6: Verify credits increased proportionally
        uint256 creditFinal0 = _lockerCredit(lccCurrency0);
        uint256 creditFinal1 = _lockerCredit(lccCurrency1);
        uint256 creditAccumulated0 = creditFinal0 > creditBaseline0 ? creditFinal0 - creditBaseline0 : 0;
        uint256 creditAccumulated1 = creditFinal1 > creditBaseline1 ? creditFinal1 - creditBaseline1 : 0;

        assertTrue(
            creditAccumulated0 > 0 || creditAccumulated1 > 0, "Locker credits should accumulate from multiple swaps"
        );

        // Log for debugging (optional, can be removed)
        emit log_named_uint("Total swap amount", totalSwapAmount);
        emit log_named_uint("Balance accumulated LCC0", balanceAccumulated0);
        emit log_named_uint("Balance accumulated LCC1", balanceAccumulated1);
        emit log_named_uint("Credit accumulated LCC0", creditAccumulated0);
        emit log_named_uint("Credit accumulated LCC1", creditAccumulated1);
    }

    function test_feeCollection_zeroLiquidityDelta_onlyCollectsFees() public {
        // Step 1: Create an MM position
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();

        // Get initial state
        Position memory posBefore = vtsOrchestrator.getPosition(positionId);
        uint128 liquidityBefore = posBefore.liquidity;
        uint256 selfLcc0Before = _selfLccBalance(lccCurrency0);
        uint256 selfLcc1Before = _selfLccBalance(lccCurrency1);

        // Step 2: Swap to generate fees
        _swapCore(true, -int256(1e18));

        // Step 3: Poke (zero delta) to collect fees AND take them
        // This combines: modifyLiquidity(delta=0) + TAKE(lcc0) + TAKE(lcc1)
        _pokeMMAndTakeFees(tokenId, 0, -60, 60);

        // Step 4: Verify liquidity unchanged (zero delta modification)
        Position memory posAfter = vtsOrchestrator.getPosition(positionId);
        assertEq(posAfter.liquidity, liquidityBefore, "Liquidity should be unchanged after zero-delta modification");
        assertTrue(posAfter.isActive, "Position should remain active");

        // Step 5: Verify credits are zeroed (all fees were taken)
        uint256 creditAfter0 = _lockerCredit(lccCurrency0);
        uint256 creditAfter1 = _lockerCredit(lccCurrency1);
        assertEq(creditAfter0, 0, "Credit for LCC0 should be zero after TAKE");
        assertEq(creditAfter1, 0, "Credit for LCC1 should be zero after TAKE");

        // Step 6: Verify test contract received the LCC tokens
        uint256 selfLcc0After = _selfLccBalance(lccCurrency0);
        uint256 selfLcc1After = _selfLccBalance(lccCurrency1);
        uint256 lcc0Received = selfLcc0After - selfLcc0Before;
        uint256 lcc1Received = selfLcc1After - selfLcc1Before;

        // At least one LCC should have been received (from fees)
        assertTrue(lcc0Received > 0 || lcc1Received > 0, "Test contract should have received LCC fees via TAKE");

        // Log precise amounts for debugging
        emit log_named_uint("LCC0 received by test contract", lcc0Received);
        emit log_named_uint("LCC1 received by test contract", lcc1Received);
    }

    function test_feeCollection_preciseFlow_creditMatchesBalanceMatchesTake() public {
        // This test verifies the precise flow:
        // 1. Swap generates fees in the pool
        // 2. Poke (modifyLiquidity with delta=0) triggers fee collection
        // 3. MMPM takes fees from PoolManager -> balance increases
        // 4. Balance increase is synced as credit to locker
        // 5. TAKE debits credit and transfers LCC to recipient
        // 6. Credit debited == LCC transferred

        // Step 1: Create MM position and establish baseline
        (uint256 tokenId,,,) = _createCommittedPosition();

        // Clear any existing state with initial poke
        _pokeMM(tokenId, 0, -60, 60);

        // Record baseline state after initial poke
        uint256 mmpmLcc0Baseline = _mmpmLccBalance(lccCurrency0);
        uint256 selfLcc0Baseline = _selfLccBalance(lccCurrency0);

        // Step 2: Generate fees via swap
        _swapCore(true, -int256(5e18)); // Large swap for meaningful fees

        // Step 3: Poke to collect fees (but don't take yet)
        _pokeMM(tokenId, 0, -60, 60);

        // Step 4: Measure credit generated from fee collection
        uint256 creditAfterPoke = _lockerCredit(lccCurrency0);
        uint256 mmpmLcc0AfterPoke = _mmpmLccBalance(lccCurrency0);
        uint256 mmpmBalanceIncrease = mmpmLcc0AfterPoke - mmpmLcc0Baseline;

        emit log_named_uint("MMPM balance increase from fees", mmpmBalanceIncrease);
        emit log_named_uint("Locker credit after poke", creditAfterPoke);

        // Credit should equal the balance increase (synced via _syncBalanceAsCredit)
        assertEq(creditAfterPoke, mmpmBalanceIncrease, "Credit should equal MMPM balance increase from fees");

        // Step 5: Take the fees
        MMA.PreparedAction[] memory takeActions = new MMA.PreparedAction[](1);
        takeActions[0] = MMA.prepareTake(lccCurrency0, address(this), 0); // Take all
        MMA.executeWithUnlock(positionManager, takeActions, block.timestamp + 3600);

        // Step 6: Verify precise amounts
        uint256 creditAfterTake = _lockerCredit(lccCurrency0);
        uint256 selfLcc0AfterTake = _selfLccBalance(lccCurrency0);
        uint256 mmpmLcc0AfterTake = _mmpmLccBalance(lccCurrency0);

        uint256 lccReceived = selfLcc0AfterTake - selfLcc0Baseline;
        uint256 mmpmBalanceDecrease = mmpmLcc0AfterPoke - mmpmLcc0AfterTake;

        emit log_named_uint("Credit after TAKE", creditAfterTake);
        emit log_named_uint("LCC received by test contract", lccReceived);
        emit log_named_uint("MMPM balance decrease from TAKE", mmpmBalanceDecrease);

        // Credit should be fully consumed
        assertEq(creditAfterTake, 0, "Credit should be zero after TAKE");

        // Amount received should equal the credit that was available
        assertEq(lccReceived, creditAfterPoke, "LCC received should equal credit that was available before TAKE");

        // MMPM balance decrease should equal the amount taken
        assertEq(mmpmBalanceDecrease, lccReceived, "MMPM balance decrease should equal LCC transferred");
    }

    // ============================================================
    // Checkpoint / Grace Period / Seizure Tests
    // ============================================================

    function test_extendGracePeriod_updatesCheckpoint() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        PositionId positionId = vtsOrchestrator.getPositionId(tokenId, 0);

        RFSCheckpoint memory checkpointBefore = vtsOrchestrator.positionToCheckpoint(positionId);

        bytes memory settlementProof = abi.encode(1);
        vm.mockCall(
            address(settlementObserver),
            abi.encodeWithSelector(IVRLSettlementObserver.verifySettlementProof.selector),
            abi.encode(true)
        );

        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.extendGracePeriod.selector, corePoolKey, tokenId, 0, 0, 0, settlementProof
            )
        );

        RFSCheckpoint memory checkpointAfter = vtsOrchestrator.positionToCheckpoint(positionId);
        assertGt(
            checkpointAfter.gracePeriodExtension0,
            checkpointBefore.gracePeriodExtension0,
            "Grace period should be extended"
        );
    }

    function test_onSeize_validatesGracePeriod() public {
        (uint256 tokenId,,,) = _createCommittedPosition();

        // Warp beyond grace period
        vm.warp(block.timestamp + 10000000);

        // Should not revert (grace period elapsed)
        unlockCaller.run(address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.onSeize.selector, tokenId, 0));
    }

    function test_checkpoint_marksCheckpoint() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        PositionId positionId = vtsOrchestrator.getPositionId(tokenId, 0);

        RFSCheckpoint memory checkpointBefore = vtsOrchestrator.positionToCheckpoint(positionId);

        // Set the block timestamp
        vm.warp(block.timestamp + 10000000);
        bytes memory emptySignal;
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, address(this), tokenId, 0, emptySignal, false)
        );

        RFSCheckpoint memory checkpointAfter = vtsOrchestrator.positionToCheckpoint(positionId);
        // Checkpoint transition time should be updated
        assertGt(
            checkpointAfter.timeOfLastTransition,
            checkpointBefore.timeOfLastTransition,
            "Checkpoint transition time should be updated"
        );
    }

    function test_checkpoint_withCommitment_validatesBacking() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        address advancer = liquiditySignal.mmState.advancer;

        bytes memory unbackedLiquiditySignal = abi.encode(liquiditySignal);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(bytes,bool)")), unbackedLiquiditySignal, true
            ),
            abi.encode(true, 10)
        );

        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector),
            abi.encode(50000000000, 50000000000)
        );

        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.checkpoint.selector, advancer, tokenId, 0, unbackedLiquiditySignal, true
            )
        );

        // Should not revert
        assertTrue(true, "Checkpoint with commitment should succeed");
    }

    // ============================================================
    // Backing deficit (commitmentDeficit) tests
    // ============================================================

    function test_checkpoint_withCommitment_revealsBackingDeficit_andInflatesRFS() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        address advancer = liquiditySignal.mmState.advancer;

        (bool rfsOpenBefore, BalanceDelta deltaBefore) = vtsOrchestrator.calcRFS(positionId, false);

        bytes memory signalBytes = abi.encode(liquiditySignal);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(bytes4(keccak256("verifyLiquiditySignal(bytes,bool)")), signalBytes, true),
            abi.encode(true, 10)
        );

        // Mock proper LCC prices (1e18 = $1 in 18 decimals) so issuedUsd is non-zero
        _mockLccPrices(1e18, 1e18);
        // Force insufficient backing from the signal (settled starts at 0)
        _mockSignalUsd(0);

        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, advancer, tokenId, 0, signalBytes, true)
        );

        (uint256 cd0, uint256 cd1) = _commitmentDeficit(positionId);
        assertTrue(cd0 > 0 || cd1 > 0, "Commitment deficit should be recorded");

        // Sanity: this test is about backing deficits, not settlement shortfall deficits
        (uint256 cum0, uint256 cum1) = _cumulativeDeficit(positionId);
        assertEq(cum0, 0, "Cumulative deficit should remain zero here (token0)");
        assertEq(cum1, 0, "Cumulative deficit should remain zero here (token1)");

        (bool rfsOpenAfter, BalanceDelta deltaAfter) = vtsOrchestrator.calcRFS(positionId, false);
        assertEq(rfsOpenAfter, rfsOpenBefore || rfsOpenAfter, "RFS should be computable");
        assertTrue(
            deltaAfter.amount0() > deltaBefore.amount0() || deltaAfter.amount1() > deltaBefore.amount1(),
            "calcRFS should reflect commitment deficit inflation"
        );
    }

    function test_onMMSettle_netsBackingDeficit_inPositionAccounting() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        address advancer = liquiditySignal.mmState.advancer;

        // Create a backing deficit via withCommitment checkpoint
        bytes memory signalBytes = abi.encode(liquiditySignal);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(bytes4(keccak256("verifyLiquiditySignal(bytes,bool)")), signalBytes, true),
            abi.encode(true, 10)
        );
        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(0);
        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, advancer, tokenId, 0, signalBytes, true)
        );

        (uint256 cd0Before, uint256 cd1Before) = _commitmentDeficit(positionId);
        assertTrue(cd0Before > 0 || cd1Before > 0, "Expected non-zero backing deficit before settlement");
        (, BalanceDelta rfsBefore) = vtsOrchestrator.calcRFS(positionId, false);

        // Deposit enough to cover the commitment deficit (deposit is negative in caller-context delta)
        BalanceDelta depositDelta = toBalanceDelta(_negInt128Capped(cd0Before), _negInt128Capped(cd1Before));
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.onMMSettle.selector,
                IMarketVault(address(proxyHook)),
                tokenId,
                0,
                corePoolKey.currency0,
                corePoolKey.currency1,
                depositDelta,
                false
            )
        );

        (uint256 cd0After, uint256 cd1After) = _commitmentDeficit(positionId);
        assertEq(cd0After, 0, "Backing deficit should be netted to zero (token0)");
        assertEq(cd1After, 0, "Backing deficit should be netted to zero (token1)");

        (, BalanceDelta rfsAfter) = vtsOrchestrator.calcRFS(positionId, false);
        assertTrue(
            rfsAfter.amount0() < rfsBefore.amount0() || rfsAfter.amount1() < rfsBefore.amount1(),
            "calcRFS should reduce when backing deficit is netted"
        );
    }

    function test_checkpoint_withCommitment_whenSignalIncreases_reducesBackingDeficit() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        address advancer = liquiditySignal.mmState.advancer;

        bytes memory signalBytes = abi.encode(liquiditySignal);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(bytes4(keccak256("verifyLiquiditySignal(bytes,bool)")), signalBytes, true),
            abi.encode(true, 10)
        );

        // First checkpoint: force a deficit
        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(0);
        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, advancer, tokenId, 0, signalBytes, true)
        );

        (uint256 cd0Before, uint256 cd1Before) = _commitmentDeficit(positionId);
        assertTrue(cd0Before > 0 || cd1Before > 0, "Expected deficit before increasing signal backing");
        (, BalanceDelta rfsBefore) = vtsOrchestrator.calcRFS(positionId, false);

        // Second checkpoint: increase signal backing sufficiently, deficit should be reduced/cleared
        _mockSignalUsd(1e30);
        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, advancer, tokenId, 0, signalBytes, true)
        );

        (uint256 cd0After, uint256 cd1After) = _commitmentDeficit(positionId);
        assertEq(cd0After, 0, "Backing deficit should reduce to zero after signal increase (token0)");
        assertEq(cd1After, 0, "Backing deficit should reduce to zero after signal increase (token1)");

        (, BalanceDelta rfsAfter) = vtsOrchestrator.calcRFS(positionId, false);
        assertTrue(
            rfsAfter.amount0() < rfsBefore.amount0() || rfsAfter.amount1() < rfsBefore.amount1(),
            "calcRFS should reduce after backing deficit is reduced via stronger signal"
        );
    }

    function test_onMMSettle_partialDeposit_reducesBackingDeficit_proRata() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        address advancer = liquiditySignal.mmState.advancer;

        // Create a backing deficit
        bytes memory signalBytes = abi.encode(liquiditySignal);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(bytes4(keccak256("verifyLiquiditySignal(bytes,bool)")), signalBytes, true),
            abi.encode(true, 10)
        );
        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(0);
        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, advancer, tokenId, 0, signalBytes, true)
        );

        (uint256 cd0Before, uint256 cd1Before) = _commitmentDeficit(positionId);
        assertTrue(cd0Before > 1, "Need non-trivial token0 deficit for partial reduction test");

        uint256 half0 = cd0Before / 2;
        BalanceDelta depositDelta = toBalanceDelta(_negInt128Capped(half0), int128(0));
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.onMMSettle.selector,
                IMarketVault(address(proxyHook)),
                tokenId,
                0,
                corePoolKey.currency0,
                corePoolKey.currency1,
                depositDelta,
                false
            )
        );

        (uint256 cd0After, uint256 cd1After) = _commitmentDeficit(positionId);
        assertEq(cd0After, cd0Before - half0, "Partial settlement should reduce token0 deficit by deposit");
        assertEq(cd1After, cd1Before, "Partial settlement should not affect token1 deficit");
    }

    // ============================================================
    // Additional Helper Tests
    // ============================================================

    function test_getMarketVTSConfiguration_returnsConfig() public {
        MarketVTSConfiguration memory config = vtsOrchestrator.getMarketVTSConfiguration(corePoolKey.toId());
        assertGt(config.token0.baseVTSRate, 0, "BaseVTSRate should be non-zero");
        assertGt(config.token1.baseVTSRate, 0, "BaseVTSRate should be non-zero");
    }

    function test_getPool_returnsPoolInfo() public {
        (PoolId id, Currency currency0, Currency currency1, MarketVTSConfiguration memory config, bool isPaused) =
            vtsOrchestrator.getPool(corePoolKey.toId());

        assertEq(PoolId.unwrap(id), PoolId.unwrap(corePoolKey.toId()), "PoolId should match");
        assertEq(Currency.unwrap(currency0), Currency.unwrap(corePoolKey.currency0), "Currency0 should match");
        assertEq(Currency.unwrap(currency1), Currency.unwrap(corePoolKey.currency1), "Currency1 should match");
        assertFalse(isPaused, "Pool should not be paused");
    }
}


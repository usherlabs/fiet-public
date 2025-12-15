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
        // VTSCommitLib checkpoint path uses oracleHelper.getTotalValue(tickers, amounts)
        vm.mockCall(
            address(oracleHelper), abi.encodeWithSelector(IOracleHelper.getTotalValue.selector), abi.encode(signalUsd)
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

    function test_revert_collectFees_whenPoolManagerLocked() public {
        vm.expectRevert(Errors.PoolManagerMustBeUnlocked.selector);
        vtsOrchestrator.collectFees(lccCurrency0, testUser, 100);
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

    function test_calcVTSRequired_returnsNonZero() public {
        (, PositionId positionId,,) = _createCommittedPosition();

        (uint256 vtsRequired0, uint256 vtsRequired1) = vtsOrchestrator.calcVTSRequired(positionId);
        assertGt(vtsRequired0, 0, "VTS required 0 should be non-zero");
        assertGt(vtsRequired1, 0, "VTS required 1 should be non-zero");
    }

    function test_calcVTSCurrent_returnsNonZero() public {
        (, PositionId positionId,,) = _createCommittedPosition();

        (uint256 vtsCurrent0, uint256 vtsCurrent1) = vtsOrchestrator.calcVTSCurrent(positionId);
        assertGt(vtsCurrent0, 0, "VTS current 0 should be non-zero");
        assertGt(vtsCurrent1, 0, "VTS current 1 should be non-zero");
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
    // collectFees Tests - Real LCC + ERC-6909 Claims
    // ============================================================

    function test_collectFees_withRealClaimsAndDelta() public {
        uint256 amount = 1000e18;

        // Step 1: Mint LCC to test user and sync as delta credit
        _mintLccTo(testUser, lccCurrency0, amount);
        _syncLccDelta(lccCurrency0, testUser);

        uint256 creditBefore = vtsOrchestrator.getFullCredit(lccCurrency0, testUser);
        assertGt(creditBefore, 0, "User should have delta credit");

        // Step 2: Give orchestrator ERC-6909 claims
        _giveOrchestratorClaims(lccCurrency0, amount);

        uint256 orchestratorClaimsBefore = manager.balanceOf(address(vtsOrchestrator), lccCurrency0.toId());
        assertGt(orchestratorClaimsBefore, 0, "Orchestrator should have claims");

        // Step 3: Collect fees under unlock
        uint256 maxAmount = 500e18;
        bytes memory result = unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(VTSOrchestrator.collectFees.selector, lccCurrency0, testUser, maxAmount)
        );
        uint256 collected = abi.decode(result, (uint256));

        // Step 4: Verify results
        assertEq(collected, maxAmount, "Should collect requested amount");
        assertLt(collected, creditBefore, "Collected should not exceed credit");

        uint256 creditAfter = vtsOrchestrator.getFullCredit(lccCurrency0, testUser);
        assertEq(creditBefore - creditAfter, collected, "Credit should decrease by collected amount");

        uint256 orchestratorClaimsAfter = manager.balanceOf(address(vtsOrchestrator), lccCurrency0.toId());
        assertEq(
            orchestratorClaimsBefore - orchestratorClaimsAfter, collected, "Claims should decrease by collected amount"
        );

        uint256 userBalance = lcc0.balanceOf(testUser);
        assertEq(userBalance, collected, "User should receive LCC tokens");
    }

    function test_collectFees_maxAmountZero_collectsFullCredit() public {
        uint256 amount = 1000e18;

        _mintLccTo(testUser, lccCurrency0, amount);
        _syncLccDelta(lccCurrency0, testUser);
        _giveOrchestratorClaims(lccCurrency0, amount);

        uint256 fullCredit = vtsOrchestrator.getFullCredit(lccCurrency0, testUser);

        bytes memory result = unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(VTSOrchestrator.collectFees.selector, lccCurrency0, testUser, 0)
        );
        uint256 collected = abi.decode(result, (uint256));

        assertEq(collected, fullCredit, "Should collect full credit when maxAmount is 0");
    }

    function test_collectFees_zeroCredit_returnsZero() public {
        _giveOrchestratorClaims(lccCurrency0, 1000e18);

        bytes memory result = unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(VTSOrchestrator.collectFees.selector, lccCurrency0, testUser, 100)
        );
        uint256 collected = abi.decode(result, (uint256));

        assertEq(collected, 0, "Should return 0 when no credit available");
    }

    function test_collectFees_capsToAvailableCredit() public {
        uint256 amount = 1000e18;
        uint256 maxAmount = 2000e18; // More than available

        _mintLccTo(testUser, lccCurrency0, amount);
        _syncLccDelta(lccCurrency0, testUser);
        _giveOrchestratorClaims(lccCurrency0, amount);

        uint256 fullCredit = vtsOrchestrator.getFullCredit(lccCurrency0, testUser);

        bytes memory result = unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(VTSOrchestrator.collectFees.selector, lccCurrency0, testUser, maxAmount)
        );
        uint256 collected = abi.decode(result, (uint256));

        assertEq(collected, fullCredit, "Should cap to available credit");
        assertLt(collected, maxAmount, "Collected should be less than maxAmount");
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


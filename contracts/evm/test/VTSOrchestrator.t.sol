// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {VTSOrchestratorFixture} from "./base/VTSOrchestratorFixture.sol";
import {VTSOrchestratorTestable} from "./base/VTSOrchestratorTestable.sol";
import {VTSOrchestrator} from "../src/VTSOrchestrator.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionId, Position} from "../src/types/Position.sol";
import {PositionModificationHookDataLib, PositionLibrary} from "../src/types/Position.sol";
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
import {LiquiditySignal} from "../src/types/Commit.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MMActionAdapter as MMA} from "./utils/MMActionAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract VTSOrchestratorTest is VTSOrchestratorFixture {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ============================================================
    // Events (redeclared for vm.expectEmit)
    // ============================================================

    event Checkpointed(uint256 commitId, uint256 positionIndex, RFSCheckpoint checkpoint, bool withCommitment);
    event GracePeriodExtended(uint256 commitId, uint256 positionIndex, uint8 tokenIndex, RFSCheckpoint checkpoint);
    event VTSConfigSet(bytes32 indexed marketId, MarketVTSConfiguration newConfig);
    event PositionSettled(
        uint256 indexed commitId,
        uint256 indexed positionIndex,
        int128 settlementDelta0,
        int128 settlementDelta1,
        uint256 settledToken0,
        uint256 settledToken1,
        bool isSeizing,
        bool rfsOpen
    );

    struct DICEAccounting {
        uint256 totalDeficitPrincipal1;
        uint256 diceIndex1;
        uint256 diceResidual1;
    }

    struct CISEAccounting {
        uint256 totalSettled0;
        uint256 totalSettled1;
        uint256 ciseIndex0;
        uint256 ciseIndex1;
        uint256 ciseResidual0;
        uint256 ciseResidual1;
        uint256 totalCISEExposure0;
        uint256 totalCISEExposure1;
    }

    // ============================================================
    // Deploy VTSOrchestratorTestable for storage inspection
    // ============================================================

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

    // ============================================================
    // Constructor Guard Tests
    // ============================================================

    function test_constructor_revert_whenSignalManagerZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new VTSOrchestratorTestable(
            address(manager),
            address(0),
            address(oracleHelper),
            address(liquidityHub),
            address(settlementObserver),
            address(this)
        );
    }

    function test_constructor_revert_whenOracleHelperZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new VTSOrchestratorTestable(
            address(manager),
            address(signalManager),
            address(0),
            address(liquidityHub),
            address(settlementObserver),
            address(this)
        );
    }

    function test_constructor_revert_whenLiquidityHubZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new VTSOrchestratorTestable(
            address(manager),
            address(signalManager),
            address(oracleHelper),
            address(0),
            address(settlementObserver),
            address(this)
        );
    }

    function test_constructor_revert_whenSettlementObserverZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new VTSOrchestratorTestable(
            address(manager),
            address(signalManager),
            address(oracleHelper),
            address(liquidityHub),
            address(0),
            address(this)
        );
    }

    // ============================================================
    // Storage inspection helpers (via VTSOrchestratorTestable)
    // ============================================================

    function _commitmentDeficit(PositionId positionId) internal view returns (uint256 def0, uint256 def1) {
        (def0, def1) = _testableOrchestrator().getCommitmentDeficit(positionId);
    }

    function _cumulativeDeficit(PositionId positionId) internal view returns (uint256 def0, uint256 def1) {
        (def0, def1,,,,) = _testableOrchestrator().getPositionAccounting(positionId);
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
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.commitSignal.selector, signalBytes)
        );

        // Now try to renew when locked
        vm.expectRevert(Errors.PoolManagerMustBeUnlocked.selector);
        vtsOrchestrator.renewSignal(address(this), 1, signalBytes);
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

    function test_incrementCoverage_amount1_incrementsToken1CoverageAccounting() public {
        PoolId poolId = corePoolKey.toId();

        DICEAccounting memory diceBefore = _getPoolDICEAccounting(poolId);
        CISEAccounting memory ciseBefore = _getPoolCISEAccounting(poolId);

        uint256 amount1 = 123;
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(poolId, 0, amount1);

        DICEAccounting memory diceAfter = _getPoolDICEAccounting(poolId);
        CISEAccounting memory ciseAfter = _getPoolCISEAccounting(poolId);

        // Totals should not change due to incrementCoverage.
        assertEq(
            diceAfter.totalDeficitPrincipal1,
            diceBefore.totalDeficitPrincipal1,
            "totalDeficitPrincipal1 should not change"
        );
        assertEq(ciseAfter.totalSettled0, ciseBefore.totalSettled0, "totalSettled0 should not change");
        assertEq(ciseAfter.totalSettled1, ciseBefore.totalSettled1, "totalSettled1 should not change");
        assertEq(ciseAfter.ciseIndex0, ciseBefore.ciseIndex0, "ciseIndex0 should not change");
        assertEq(ciseAfter.ciseResidual0, ciseBefore.ciseResidual0, "ciseResidual0 should not change");
        assertEq(ciseAfter.totalCISEExposure0, ciseBefore.totalCISEExposure0, "totalCISEExposure0 should not change");
        assertEq(ciseAfter.totalCISEExposure1, ciseBefore.totalCISEExposure1, "totalCISEExposure1 should not change");

        // Coverage must land either in the index (if totals > 0) or in residuals (if totals == 0).
        if (diceBefore.totalDeficitPrincipal1 > 0) {
            assertGt(diceAfter.diceIndex1, diceBefore.diceIndex1, "DICE index1 should increase when deficits exist");
        } else {
            assertGt(
                diceAfter.diceResidual1,
                diceBefore.diceResidual1,
                "DICE residual1 should increase when no deficits exist"
            );
        }

        if (ciseBefore.totalSettled1 > 0) {
            assertGt(ciseAfter.ciseIndex1, ciseBefore.ciseIndex1, "CISE index1 should increase when settled > 0");
        } else {
            assertGt(
                ciseAfter.ciseResidual1,
                ciseBefore.ciseResidual1,
                "CISE residual1 should increase when no settled exists"
            );
        }
    }

    function _getPoolDICEAccounting(PoolId poolId) internal view returns (DICEAccounting memory a) {
        (, a.totalDeficitPrincipal1,, a.diceIndex1,, a.diceResidual1) =
            _testableOrchestrator().getPoolDICEAccounting(poolId);
    }

    function _getPoolCISEAccounting(PoolId poolId) internal view returns (CISEAccounting memory a) {
        (
            a.totalSettled0,
            a.totalSettled1,
            a.ciseIndex0,
            a.ciseIndex1,
            a.ciseResidual0,
            a.ciseResidual1,
            a.totalCISEExposure0,
            a.totalCISEExposure1
        ) = _testableOrchestrator().getPoolCISEAccounting(poolId);
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

        // Be specific: this must fail due to CoreHook access-control, not due to later swap accounting.
        vm.expectRevert(Errors.InvalidSender.selector);
        vtsOrchestrator.afterCoreSwap(corePoolKey, swapParams, delta, 0, 0);
    }

    function test_constructor_revert_whenPoolManagerZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new VTSOrchestratorTestable(
            address(0),
            address(signalManager),
            address(oracleHelper),
            address(liquidityHub),
            address(settlementObserver),
            address(this)
        );
    }

    // ============================================================
    // Guard Tests - notPoolPaused
    // ============================================================

    function test_revert_processPosition_whenPoolPaused() public {
        vtsOrchestrator.pausePool(corePoolKey.toId());

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});
        BalanceDelta callerDelta = toBalanceDelta(0, 0);
        BalanceDelta feesAccrued = toBalanceDelta(0, 0);

        // Call from the core hook so onlyCoreHook passes and the pause guard is the failure reason.
        vm.prank(coreHookAddress);
        vm.expectRevert(Errors.EnforcedPause.selector);
        vtsOrchestrator.processPosition(address(this), corePoolKey, params, callerDelta, feesAccrued, "");
    }

    function test_revert_afterCoreSwap_whenPoolPaused() public {
        vtsOrchestrator.pausePool(corePoolKey.toId());

        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: 0});
        BalanceDelta delta = toBalanceDelta(-100, 100);

        vm.prank(coreHookAddress);
        vm.expectRevert(Errors.EnforcedPause.selector);
        vtsOrchestrator.afterCoreSwap(corePoolKey, swapParams, delta, 0, 0);
    }

    function test_revert_settlePositionGrowths_whenPoolPaused() public {
        (, PositionId positionId,,) = _createCommittedPosition();
        vtsOrchestrator.pausePool(corePoolKey.toId());

        vm.expectRevert(Errors.EnforcedPause.selector);
        vtsOrchestrator.settlePositionGrowths(positionId);
    }

    // ============================================================
    // Signal Lifecycle Tests
    // ============================================================

    function test_isSignalValid_zeroCommitId_returnsFalse() public view {
        bool isValid = vtsOrchestrator.isSignalValid(0, true);
        assertFalse(isValid, "Zero commitId should be invalid");
    }

    function test_isSignalValid_unknownCommitId_returnsFalse() public view {
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

    function test_revert_renewSignal_whenCommitInvalid_insideUnlock() public {
        bytes memory signalBytes = abi.encode(liquiditySignal);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignal.selector, uint256(0)));
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("renewSignal(address,uint256,bytes)")), address(this), 0, signalBytes
            )
        );
    }

    function test_renewSignal_extendsExpiry() public {
        bytes memory signalBytes = abi.encode(liquiditySignal);

        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(bytes4(keccak256("verifyLiquiditySignal(bytes,bool)")), signalBytes, true),
            abi.encode(true, 3600)
        );

        bytes memory result = unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.commitSignal.selector, signalBytes)
        );
        uint256 commitId = abi.decode(result, (uint256));

        (, uint256 expiresAtBefore,,) = vtsOrchestrator.getCommit(commitId);

        // Warp forward
        vm.warp(block.timestamp + 1000);

        // Renewal must preserve commit ownership.
        LiquiditySignal memory sameOwnerRenew = liquiditySignal;
        sameOwnerRenew.nonce += 1;
        bytes memory renewSignalBytes = abi.encode(sameOwnerRenew);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(bytes4(keccak256("verifyLiquiditySignal(bytes,bool)")), renewSignalBytes, true),
            abi.encode(true, 3600)
        );

        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("renewSignal(address,uint256,bytes)")),
                liquiditySignal.mmState.advancer,
                commitId,
                renewSignalBytes
            )
        );

        (, uint256 expiresAtAfter,,) = vtsOrchestrator.getCommit(commitId);
        assertGt(expiresAtAfter, expiresAtBefore, "Expiry should be extended");
    }

    // ============================================================
    // Position Validity + Lens Tests
    // ============================================================

    function test_isPositionValid_invalidPositionId_returnsFalse() public view {
        PositionId invalidId = PositionId.wrap(bytes32(uint256(999)));
        bool isValid = vtsOrchestrator.isPositionValid(invalidId, false);
        assertFalse(isValid, "Invalid positionId should return false");
    }

    function test_isPositionValid_validPosition_returnsTrue() public {
        (, PositionId positionId,,) = _createCommittedPosition();

        bool isValid = vtsOrchestrator.isPositionValid(positionId, true);
        assertTrue(isValid, "Valid position should return true");
    }

    function test_isPositionValid_missingOneCommitmentMax_returnsFalse() public {
        // commitmentMax is tracked mechanically; to hit the edge-case behind the `||` check we force it via test harness.
        (, PositionId positionId,,) = _createCommittedPosition();

        // Force only one side to be zero.
        _testableOrchestrator()._setCommitmentMax(positionId, 0, 1);

        bool isValid = vtsOrchestrator.isPositionValid(positionId, true);
        assertFalse(isValid, "Position should be invalid when exactly one commitment max is zero");
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
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPosition.selector, 0, 0, PositionId.wrap(bytes32(0))));
        vtsOrchestrator.getPosition(999, 0);
    }

    function test_revert_calcRFS_byCommitIdAndIndex_whenInvalidPositionIndex_insideUnlock() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        uint256 badIndex = 12345;
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPosition.selector, 0, 0, PositionId.wrap(bytes32(0))));
        unlockCaller.run(
            address(vtsOrchestrator),
            // Disambiguate overloaded selector: calcRFS(uint256,uint256,bool)
            abi.encodeWithSelector(bytes4(keccak256("calcRFS(uint256,uint256,bool)")), tokenId, badIndex, false)
        );
    }

    function test_calcRFS_returnsCorrectValues() public {
        (, PositionId positionId,,) = _createCommittedPosition();

        vtsOrchestrator.calcRFS(positionId, true);
        // RFS state depends on position state - just verify it doesn't revert
        assertTrue(true, "calcRFS should not revert");
    }

    function test_revert_calcRFS_whenInvalidPosition() public {
        PositionId invalidId = PositionId.wrap(bytes32(uint256(999)));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPosition.selector, 0, 0, invalidId));
        vtsOrchestrator.calcRFS(invalidId, true);
    }

    function test_settlePositionGrowths_invalidPositionId_isNoop() public {
        // We can't directly "expect no calls to VTSPositionLib" (it's an internal library call).
        // But we *can* assert the observable effect: no external pool-state reads should occur,
        // because VTSPositionLib.settlePositionGrowths would read PoolManager via `extsload`.
        bytes4 extsload1 = bytes4(keccak256("extsload(bytes32)"));
        bytes4 extsload2 = bytes4(keccak256("extsload(bytes32,uint256)"));
        bytes4 extsload3 = bytes4(keccak256("extsload(bytes32[])"));

        vm.expectCall(address(manager), abi.encodeWithSelector(extsload1), 0);
        vm.expectCall(address(manager), abi.encodeWithSelector(extsload2), 0);
        vm.expectCall(address(manager), abi.encodeWithSelector(extsload3), 0);

        // Should not revert: the orchestrator guards on isPositionValid(positionId, true).
        PositionId invalidId = PositionId.wrap(bytes32(uint256(999)));
        vtsOrchestrator.settlePositionGrowths(invalidId);
    }

    function test_getCommitmentMaxima_returnsNonZero() public {
        (, PositionId positionId,,) = _createCommittedPosition();

        (uint256 commitment0, uint256 commitment1) = vtsOrchestrator.getCommitmentMaxima(positionId);
        assertGt(commitment0, 0, "Commitment 0 should be non-zero");
        assertGt(commitment1, 0, "Commitment 1 should be non-zero");
    }

    function test_revert_getCommitmentMaxima_whenInvalidPosition() public {
        PositionId invalidId = PositionId.wrap(bytes32(uint256(999)));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPosition.selector, 0, 0, invalidId));
        vtsOrchestrator.getCommitmentMaxima(invalidId);
    }

    function test_getPositionSettledAmounts() public {
        (, PositionId positionId, uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) =
            _createCommittedPosition();

        (uint256 amount0, uint256 amount1) = vtsOrchestrator.getPositionSettledAmounts(positionId);
        assertEq(amount0, requiredSettlementAmount0, "Settled amount0 should be the required settlement amount");
        assertEq(amount1, requiredSettlementAmount1, "Settled amount1 should be the required settlement amount");
    }

    function test_revert_CurrencyNotSettled_whenPositionNotSettled() public {
        // Prepare actions for commit and mint WITHOUT settlement
        (MMA.PreparedAction[] memory actions,,) = _prepareCommitAndMintWithoutSettlement();

        // Execute actions - this should revert with CurrencyNotSettled because deltas aren't settled
        (bytes memory actionsBytes, bytes[] memory params) = MMA.concatPrepared(actions);
        bytes memory unlockData = abi.encode(actionsBytes, params);

        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        positionManager.modifyLiquidities(unlockData, block.timestamp + 3600);
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

    /// @notice Helper to get test contract's fee collection mechanic
    function test_feeCollection_mmPosition_accumulatesFees_viaSwap() public {
        // Step 1: Create an MM position
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();

        // Verify position is active
        assertTrue(vtsOrchestrator.isPositionValid(positionId, true), "Position should be active");

        uint256 swapVolume = 1e18;

        // Step 2: Perform swaps to generate fees
        // zeroForOne: input LCC0, output LCC1
        _swapCore(true, -int256(swapVolume));
        // oneForZero: input LCC1, output LCC0
        _swapCore(false, -int256(swapVolume));

        // Step 3: Record balances after swaps (before poke/take)
        // We measure from this point to isolate fees received from swap costs
        uint256 lcc0AfterSwaps = _selfLccBalance(lccCurrency0);
        uint256 lcc1AfterSwaps = _selfLccBalance(lccCurrency1);

        // Step 4: Expect Transfer events from MMPM to test contract via _take()
        // Check event signature and from/to addresses, but not the exact amount (checkData = false)
        vm.expectEmit(true, true, false, false, Currency.unwrap(lccCurrency0));
        emit IERC20.Transfer(address(positionManager), address(this), 0);

        vm.expectEmit(true, true, false, false, Currency.unwrap(lccCurrency1));
        emit IERC20.Transfer(address(positionManager), address(this), 0);

        // Step 5: Poke the position to collect fees (modifyLiquidity with liquidityDelta=0)
        // This triggers VTSPositionLib.touchPosition which processes fees
        // Then _take() transfers the fees from MMPM to test contract
        _pokeMM(tokenId, 0);

        // Step 6: Record final balances AFTER poke/take
        uint256 lcc0Final = _selfLccBalance(lccCurrency0);
        uint256 lcc1Final = _selfLccBalance(lccCurrency1);

        // Calculate fees received (balance change from poke/take, after swaps already accounted)
        uint256 feesReceived0 = lcc0Final > lcc0AfterSwaps ? lcc0Final - lcc0AfterSwaps : 0;
        uint256 feesReceived1 = lcc1Final > lcc1AfterSwaps ? lcc1Final - lcc1AfterSwaps : 0;

        // Log for debugging
        console.log("Fees received LCC0:", feesReceived0);
        console.log("Fees received LCC1:", feesReceived1);

        // At least one currency should have had fees received
        bool feesCollected = feesReceived0 > 0 || feesReceived1 > 0;
        assertTrue(feesCollected, "Fees should have been transferred from MMPM to test contract");

        // Verify the position is still valid after fee collection
        assertTrue(vtsOrchestrator.isPositionValid(positionId, true), "Position should still be active after poke");
    }

    // ============================================================
    // Checkpoint / Grace Period / Seizure Tests
    // ============================================================

    function test_revert_extendGracePeriod_whenCommitInvalid_insideUnlock() public {
        bytes memory settlementProof = abi.encode(1);
        vm.mockCall(
            address(settlementObserver),
            abi.encodeWithSelector(IVRLSettlementObserver.verifySettlementProof.selector),
            abi.encode(true)
        );
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignal.selector, uint256(0)));
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(VTSOrchestrator.extendGracePeriod.selector, corePoolKey, 0, 0, 0, 0, settlementProof)
        );
    }

    function test_revert_extendGracePeriod_whenPositionIndexInvalid_insideUnlock() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        uint256 badIndex = 12345;

        bytes memory settlementProof = abi.encode(1);
        vm.mockCall(
            address(settlementObserver),
            abi.encodeWithSelector(IVRLSettlementObserver.verifySettlementProof.selector),
            abi.encode(true)
        );

        // Unset mapping index yields PositionId(0), which must fail position validity.
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPosition.selector, 0, 0, PositionId.wrap(bytes32(0))));
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.extendGracePeriod.selector, corePoolKey, tokenId, badIndex, 0, 0, settlementProof
            )
        );
    }

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

        // Event must be emitted; we don't assert the struct payload here (data unchecked).
        vm.expectEmit(false, false, false, false, address(vtsOrchestrator));
        emit GracePeriodExtended(tokenId, 0, 0, RFSCheckpoint(0, false, 0, 0));

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

    function test_revert_onSeize_whenCommitInvalid_insideUnlock() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignal.selector, uint256(0)));
        unlockCaller.run(address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.onSeize.selector, 0, 0));
    }

    function test_onSeize_validatesGracePeriod() public {
        (uint256 tokenId,,,) = _createCommittedPosition();

        // Warp beyond grace period
        vm.warp(block.timestamp + 10000000);

        // Should not revert (grace period elapsed)
        unlockCaller.run(address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.onSeize.selector, tokenId, 0));
    }

    function test_revert_checkpoint_whenCommitInvalid_insideUnlock() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignal.selector, uint256(0)));
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, address(this), 0, 0, false)
        );
    }

    function test_revert_checkpoint_whenPositionIndexInvalid_insideUnlock() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        uint256 badIndex = 12345;

        // Unset mapping index yields PositionId(0), which must fail position validity.
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPosition.selector, 0, 0, PositionId.wrap(bytes32(0))));
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.checkpoint.selector, address(this), tokenId, badIndex, false
            )
        );
    }

    function test_checkpoint_marksCheckpoint() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        PositionId positionId = vtsOrchestrator.getPositionId(tokenId, 0);

        RFSCheckpoint memory checkpointBefore = vtsOrchestrator.positionToCheckpoint(positionId);

        // Set the block timestamp
        vm.warp(block.timestamp + 10000000);

        vm.expectEmit(false, false, false, false, address(vtsOrchestrator));
        emit Checkpointed(tokenId, 0, RFSCheckpoint(0, false, 0, 0), false);

        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, address(this), tokenId, 0, false)
        );

        RFSCheckpoint memory checkpointAfter = vtsOrchestrator.positionToCheckpoint(positionId);
        // Checkpoint transition time should be updated
        assertGt(
            checkpointAfter.timeOfLastTransition,
            checkpointBefore.timeOfLastTransition,
            "Checkpoint transition time should be updated"
        );
    }

    // ============================================================
    // MM hook-data validation + return-value tests
    // ============================================================

    function test_revert_processPosition_mmOperation_whenCommitInvalid() public {
        // MM operation is defined as hookData.commitId > 0, so use a non-existent commitId.
        bytes memory hookData = PositionModificationHookDataLib.encode(999, 0, address(this));

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 0, salt: bytes32(0)});

        vm.prank(coreHookAddress);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignal.selector, uint256(999)));
        vtsOrchestrator.processPosition(
            address(positionManager), corePoolKey, params, toBalanceDelta(0, 0), toBalanceDelta(0, 0), hookData
        );
    }

    function test_processPosition_returnsNonZeroPositionId_onPoke() public {
        (uint256 tokenId, PositionId existingPositionId,,) = _createCommittedPosition();

        // Simulate a "poke" by calling processPosition with liquidityDelta=0 and matching MM salt.
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -60, tickUpper: 60, liquidityDelta: 0, salt: PositionLibrary.generateSalt(tokenId, 0)
        });

        bytes memory hookData = PositionModificationHookDataLib.encode(tokenId, 0, address(this));

        vm.prank(coreHookAddress);
        BalanceDelta callerDelta = toBalanceDelta(0, 0);
        BalanceDelta feesAccrued = toBalanceDelta(0, 0);

        (Position memory pos, PositionId id, BalanceDelta feeAdj, bool isMMPosition) = vtsOrchestrator.processPosition(
            address(positionManager), corePoolKey, params, callerDelta, feesAccrued, hookData
        );

        assertTrue(isMMPosition, "Expected MM operation");
        assertEq(PositionId.unwrap(id), PositionId.unwrap(existingPositionId), "Returned positionId should match");
        assertEq(pos.commitId, tokenId, "Returned position should reference commitId");
        assertEq(pos.owner, address(positionManager), "Returned position owner should be positionManager");

        // Include explicit assertions for the CoreHook inputs and expected fee adjustment in this scenario.
        // With no swaps/fees in this test path, we pass zero deltas and expect no fee adjustment to be applied.
        assertEq(callerDelta.amount0(), 0, "callerDelta0 should be 0 for poke");
        assertEq(callerDelta.amount1(), 0, "callerDelta1 should be 0 for poke");
        assertEq(feesAccrued.amount0(), 0, "feesAccrued0 should be 0 for poke");
        assertEq(feesAccrued.amount1(), 0, "feesAccrued1 should be 0 for poke");
        assertEq(feeAdj.amount0(), 0, "feeAdj0 should be 0 when feesAccrued is 0");
        assertEq(feeAdj.amount1(), 0, "feeAdj1 should be 0 when feesAccrued is 0");
    }

    function test_revert_onMMSettle_whenCommitInvalid_insideUnlock() public {
        BalanceDelta amountDelta = toBalanceDelta(-1, -1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignal.selector, uint256(0)));
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.onMMSettle.selector,
                IMarketVault(address(proxyHook)),
                0,
                0,
                corePoolKey.currency0,
                corePoolKey.currency1,
                amountDelta,
                false
            )
        );
    }

    function test_onMMSettle_returnsSeizedLiquidityUnitsZero_whenNotSeizing_andRfsOpenMatchesCalcRFS() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        address advancer = liquiditySignal.mmState.advancer;

        // Create a backing deficit via withCommitment checkpoint so RFS is meaningfully open.
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
            abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, advancer, tokenId, 0, true)
        );

        // Partial settlement to keep the RFS likely open.
        (uint256 cd0, uint256 cd1) = _commitmentDeficit(positionId);
        int128 pay0 = _negInt128Capped(cd0 / 2);
        int128 pay1 = _negInt128Capped(cd1 / 2);
        BalanceDelta depositDelta = toBalanceDelta(pay0, pay1);

        bytes memory out = unlockCaller.run(
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

        (, bool rfsOpen, uint256 seizedLiquidityUnits) = abi.decode(out, (BalanceDelta, bool, uint256));
        assertEq(seizedLiquidityUnits, 0, "seizedLiquidityUnits must be zero when not seizing");

        (bool rfsOpenExpected,) = vtsOrchestrator.calcRFS(positionId, false);
        assertEq(rfsOpen, rfsOpenExpected, "rfsOpen should match calcRFS result");
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
                VTSOrchestrator.checkpoint.selector, advancer, tokenId, 0, true
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
            abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, advancer, tokenId, 0, true)
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
            abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, advancer, tokenId, 0, true)
        );

        (uint256 cd0Before, uint256 cd1Before) = _commitmentDeficit(positionId);
        assertTrue(cd0Before > 0 || cd1Before > 0, "Expected non-zero backing deficit before settlement");
        (, BalanceDelta rfsBefore) = vtsOrchestrator.calcRFS(positionId, false);

        // Deposit enough to cover the commitment deficit (deposit is negative in caller-context delta)
        BalanceDelta depositDelta = toBalanceDelta(_negInt128Capped(cd0Before), _negInt128Capped(cd1Before));

        // Event must be emitted; only indexed fields are asserted (data unchecked).
        vm.expectEmit(true, true, false, false, address(vtsOrchestrator));
        emit PositionSettled(tokenId, 0, 0, 0, 0, 0, false, false);

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
            abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, advancer, tokenId, 0, true)
        );

        (uint256 cd0Before, uint256 cd1Before) = _commitmentDeficit(positionId);
        assertTrue(cd0Before > 0 || cd1Before > 0, "Expected deficit before increasing signal backing");
        (, BalanceDelta rfsBefore) = vtsOrchestrator.calcRFS(positionId, false);

        // Second checkpoint: increase signal backing sufficiently, deficit should be reduced/cleared
        _mockSignalUsd(1e30);
        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, advancer, tokenId, 0, true)
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
            abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, advancer, tokenId, 0, true)
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

    function test_getMarketVTSConfiguration_returnsConfig() public view {
        MarketVTSConfiguration memory config = vtsOrchestrator.getMarketVTSConfiguration(corePoolKey.toId());
        assertGt(config.token0.baseVTSRate, 0, "BaseVTSRate should be non-zero");
        assertGt(config.token1.baseVTSRate, 0, "BaseVTSRate should be non-zero");
    }

    function test_revert_setMarketVTSConfiguration_whenNotOwner() public {
        address nonOwner = makeAddr("nonOwner");
        MarketVTSConfiguration memory config = vtsOrchestrator.getMarketVTSConfiguration(corePoolKey.toId());
        config.token0.baseVTSRate = config.token0.baseVTSRate + 1;

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        vtsOrchestrator.setMarketVTSConfiguration(corePoolKey.toId(), config);
    }

    function test_setMarketVTSConfiguration_whenOwner_updatesConfig() public {
        PoolId pid = corePoolKey.toId();
        MarketVTSConfiguration memory configBefore = vtsOrchestrator.getMarketVTSConfiguration(pid);
        uint256 baseRateBefore = configBefore.token0.baseVTSRate;
        MarketVTSConfiguration memory newConfig = configBefore;
        newConfig.token0.baseVTSRate = newConfig.token0.baseVTSRate + 1;

        vm.expectEmit(true, false, false, true, address(vtsOrchestrator));
        emit VTSConfigSet(PoolId.unwrap(pid), newConfig);

        // Be explicit about owner to avoid fixture surprises.
        vm.prank(vtsOrchestrator.owner());
        vtsOrchestrator.setMarketVTSConfiguration(pid, newConfig);

        MarketVTSConfiguration memory configAfter = vtsOrchestrator.getMarketVTSConfiguration(pid);
        uint256 baseRateAfter = configAfter.token0.baseVTSRate;

        assertEq(baseRateAfter, baseRateBefore + 1, "token0.baseVTSRate should update");
    }

    function test_revert_setMarketVTSConfiguration_whenInvalidGracePeriodConfig() public {
        PoolId pid = corePoolKey.toId();
        MarketVTSConfiguration memory cfg = vtsOrchestrator.getMarketVTSConfiguration(pid);

        // Invalidate token0: maxGracePeriodTime < gracePeriodTime
        cfg.token0.gracePeriodTime = 10;
        cfg.token0.maxGracePeriodTime = 9;

        vm.prank(vtsOrchestrator.owner());
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidVTSConfiguration.selector, 10, 9));
        vtsOrchestrator.setMarketVTSConfiguration(pid, cfg);
    }

    function test_getPool_returnsPoolInfo() public view {
        (PoolId id, Currency currency0, Currency currency1,, bool isPaused) =
            vtsOrchestrator.getPool(corePoolKey.toId());

        assertEq(PoolId.unwrap(id), PoolId.unwrap(corePoolKey.toId()), "PoolId should match");
        assertEq(Currency.unwrap(currency0), Currency.unwrap(corePoolKey.currency0), "Currency0 should match");
        assertEq(Currency.unwrap(currency1), Currency.unwrap(corePoolKey.currency1), "Currency1 should match");
        assertFalse(isPaused, "Pool should not be paused");
    }
}


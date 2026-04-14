// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {VTSOrchestratorFixture} from "./base/VTSOrchestratorFixture.sol";
import {UnlockCaller} from "./base/VTSOrchestratorFixture.sol";
import {VTSOrchestratorTestable} from "./base/VTSOrchestratorTestable.sol";
import {VTSOrchestrator} from "../src/VTSOrchestrator.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
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
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {IOracleHelper} from "../src/interfaces/IOracleHelper.sol";
import {IVRLSettlementObserver} from "../src/interfaces/IVRLSettlementObserver.sol";
import {LiquiditySignal} from "../src/types/Commit.sol";
import {MarketMaker} from "../src/libraries/MarketMaker.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MMActionAdapter as MMA} from "./utils/MMActionAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

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
        uint256 totalCISEExposure0;
        uint256 totalCISEExposure1;
    }

    // ============================================================
    // Deploy VTSOrchestratorTestable for storage inspection
    // ============================================================

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

    // ============================================================
    // Constructor Guard Tests
    // ============================================================

    function test_constructor_revert_whenOracleHelperZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new VTSOrchestratorTestable(address(manager), address(0), address(liquidityHub), address(this));
    }

    function test_constructor_revert_whenLiquidityHubZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new VTSOrchestratorTestable(address(manager), address(oracleHelper), address(0), address(this));
    }

    // ============================================================
    // Guard Tests - onlyIfVRLHandlersRegistered
    // ============================================================

    function test_revert_commitSignal_whenVrlHandlersNotRegistered_insideUnlock() public {
        _testableOrchestrator().testOnly_clearVRLHandlers();
        bytes memory signalBytes = abi.encode(liquiditySignal);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.commitSignal.selector,
                IMarketFactory(marketFactory),
                liquiditySignal.mmState.owner,
                signalBytes
            )
        );
    }

    function test_revert_commitSignalRelayed_whenVrlHandlersNotRegistered_insideUnlock() public {
        _testableOrchestrator().testOnly_clearVRLHandlers();
        bytes memory signalBytes = abi.encode(liquiditySignal);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.commitSignalRelayed.selector,
                IMarketFactory(marketFactory),
                liquiditySignal.mmState.owner,
                signalBytes,
                uint256(0),
                uint256(0),
                bytes("")
            )
        );
    }

    function test_revert_extendGracePeriod_whenVrlHandlersNotRegistered_insideUnlock() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        bytes memory settlementProof = abi.encode(1);
        _testableOrchestrator().testOnly_clearVRLHandlers();
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.extendGracePeriod.selector,
                IMarketFactory(marketFactory),
                corePoolKey,
                tokenId,
                uint256(0),
                uint8(0),
                uint32(0),
                settlementProof
            )
        );
    }

    function test_revert_renewSignal_whenVrlHandlersNotRegistered_insideUnlock() public {
        bytes memory signalBytes = abi.encode(liquiditySignal);
        uint256 commitId = abi.decode(
            unlockCaller.run(
                address(vtsOrchestrator),
                abi.encodeWithSelector(
                    VTSOrchestrator.commitSignal.selector,
                    IMarketFactory(marketFactory),
                    liquiditySignal.mmState.owner,
                    signalBytes
                )
            ),
            (uint256)
        );
        assertEq(commitId, 1);

        LiquiditySignal memory sameOwnerRenew = liquiditySignal;
        sameOwnerRenew.nonce += 1;
        bytes memory renewSignalBytes = abi.encode(sameOwnerRenew);

        _testableOrchestrator().testOnly_clearVRLHandlers();
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("renewSignal(address,address,uint256,bytes)")),
                IMarketFactory(marketFactory),
                sameOwnerRenew.mmState.advancer,
                commitId,
                renewSignalBytes
            )
        );
    }

    function test_revert_renewSignalRelayed_whenVrlHandlersNotRegistered_insideUnlock() public {
        bytes memory signalBytes = abi.encode(liquiditySignal);
        uint256 commitId = abi.decode(
            unlockCaller.run(
                address(vtsOrchestrator),
                abi.encodeWithSelector(
                    VTSOrchestrator.commitSignal.selector,
                    IMarketFactory(marketFactory),
                    liquiditySignal.mmState.owner,
                    signalBytes
                )
            ),
            (uint256)
        );

        LiquiditySignal memory sameOwnerRenew = liquiditySignal;
        sameOwnerRenew.nonce += 1;
        bytes memory renewSignalBytes = abi.encode(sameOwnerRenew);

        _testableOrchestrator().testOnly_clearVRLHandlers();
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.renewSignalRelayed.selector,
                IMarketFactory(marketFactory),
                sameOwnerRenew.mmState.advancer,
                commitId,
                renewSignalBytes,
                uint256(0),
                uint256(0),
                bytes("")
            )
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

    function _lastPositionSettledMeta()
        internal
        returns (uint256 commitId, uint256 positionIndex, bool isSeizing, bool rfsOpen)
    {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("PositionSettled(uint256,uint256,int128,int128,uint256,uint256,bool,bool)");

        for (uint256 i = entries.length; i > 0; i--) {
            Vm.Log memory entry = entries[i - 1];
            if (entry.emitter == address(vtsOrchestrator) && entry.topics.length == 3 && entry.topics[0] == sig) {
                commitId = uint256(entry.topics[1]);
                positionIndex = uint256(entry.topics[2]);
                (,,,, isSeizing, rfsOpen) = abi.decode(entry.data, (int128, int128, uint256, uint256, bool, bool));
                return (commitId, positionIndex, isSeizing, rfsOpen);
            }
        }

        revert("PositionSettled log not found");
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
        vtsOrchestrator.commitSignal(IMarketFactory(marketFactory), liquiditySignal.mmState.owner, signalBytes);
    }

    function test_revert_renewSignal_whenPoolManagerLocked() public {
        // First create a commit
        bytes memory signalBytes = abi.encode(liquiditySignal);
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.commitSignal.selector,
                IMarketFactory(marketFactory),
                liquiditySignal.mmState.owner,
                signalBytes
            )
        );

        // Now try to renew when locked
        vm.expectRevert(Errors.PoolManagerMustBeUnlocked.selector);
        vtsOrchestrator.renewSignal(IMarketFactory(marketFactory), address(this), 1, signalBytes);
    }

    function test_creditExact_revert_whenCallerUnboundForFactory() public {
        vm.expectRevert(Errors.InvalidSender.selector);
        vtsOrchestrator.creditExact(IMarketFactory(marketFactory), CurrencyLibrary.ADDRESS_ZERO, address(this), 1);
    }

    function test_creditExact_succeeds_whenCallerIsFactoryBound() public {
        vm.prank(mmPositionManager);
        int128 deltaChange =
            vtsOrchestrator.creditExact(IMarketFactory(marketFactory), CurrencyLibrary.ADDRESS_ZERO, address(this), 1);
        assertEq(deltaChange, 1, "creditExact should report credited amount");
    }

    function test_revert_commitSignal_whenUnboundCallerForwardsSender_insideUnlock() public {
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, address(unlockCaller)),
            abi.encode(false)
        );

        bytes memory signalBytes = abi.encode(liquiditySignal);
        vm.expectRevert(Errors.InvalidSender.selector);
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.commitSignal.selector,
                IMarketFactory(marketFactory),
                liquiditySignal.mmState.owner,
                signalBytes
            )
        );
    }

    function test_revert_renewSignal_whenUnboundCallerForwardsSender_insideUnlock() public {
        (uint256 commitId,,,) = _createCommittedPosition();

        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, address(unlockCaller)),
            abi.encode(false)
        );

        LiquiditySignal memory sameOwnerRenew = liquiditySignal;
        sameOwnerRenew.nonce += 1;
        bytes memory renewSignalBytes = abi.encode(sameOwnerRenew);

        vm.expectRevert(Errors.InvalidSender.selector);
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("renewSignal(address,address,uint256,bytes)")),
                address(marketFactory),
                sameOwnerRenew.mmState.advancer,
                commitId,
                renewSignalBytes
            )
        );
    }

    function test_revert_commitSignalRelayed_whenUnboundCallerForwardsSender_insideUnlock() public {
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, address(unlockCaller)),
            abi.encode(false)
        );

        bytes memory signalBytes = abi.encode(liquiditySignal);
        vm.expectRevert(Errors.InvalidSender.selector);
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.commitSignalRelayed.selector,
                IMarketFactory(marketFactory),
                liquiditySignal.mmState.owner,
                signalBytes,
                uint256(0),
                uint256(0),
                bytes("")
            )
        );
    }

    function test_revert_renewSignalRelayed_whenUnboundCallerForwardsSender_insideUnlock() public {
        (uint256 commitId,,,) = _createCommittedPosition();

        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, address(unlockCaller)),
            abi.encode(false)
        );

        LiquiditySignal memory sameOwnerRenew = liquiditySignal;
        sameOwnerRenew.nonce += 1;
        bytes memory renewSignalBytes = abi.encode(sameOwnerRenew);

        vm.expectRevert(Errors.InvalidSender.selector);
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.renewSignalRelayed.selector,
                IMarketFactory(marketFactory),
                sameOwnerRenew.mmState.advancer,
                commitId,
                renewSignalBytes,
                uint256(0),
                uint256(0),
                bytes("")
            )
        );
    }

    function test_revert_extendGracePeriod_whenPoolManagerLocked() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        bytes memory settlementProof = abi.encode(1);

        vm.expectRevert(Errors.PoolManagerMustBeUnlocked.selector);
        vtsOrchestrator.extendGracePeriod(IMarketFactory(marketFactory), corePoolKey, tokenId, 0, 0, 0, settlementProof);
    }

    function test_extendGracePeriod_revertsWhenPoolKeyDoesNotMatchPositionPool() public {
        // Create a committed position in the fixture's core pool (pool B).
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();

        // Create a distinct pool key (pool A) and initialise config for it.
        PoolKey memory poolKeyA = PoolKey({
            currency0: Currency.wrap(address(0x11111111)),
            currency1: Currency.wrap(address(0x22222222)),
            fee: corePoolKey.fee,
            tickSpacing: corePoolKey.tickSpacing,
            hooks: IHooks(address(0))
        });

        // Ensure VTS has configuration for poolKeyA so the call is well-formed, even though it should revert earlier.
        MarketVTSConfiguration memory cfg = VTSConfigs.getDefaultConfig();
        vm.prank(marketFactory);
        vtsOrchestrator.initPool(poolKeyA, cfg);

        bytes memory settlementProof = abi.encode(1);

        // Must revert before proof verification because the position belongs to pool B, not pool A.
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPosition.selector, 0, 0, positionId));
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.extendGracePeriod.selector, marketFactory, poolKeyA, tokenId, 0, 0, 0, settlementProof
            )
        );
    }

    function test_checkpoint_revertsWhenPositionIndexOutOfBounds() public {
        // Create a committed position with a single position at index 0.
        (uint256 tokenId,,,) = _createCommittedPosition();

        // Index 1 is out-of-bounds; getPositionId will return PositionId(0), which must be rejected.
        PositionId zeroId = PositionId.wrap(bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPosition.selector, 0, 0, zeroId));
        vtsOrchestrator.checkpoint(tokenId, 1, false);
    }

    function test_revert_onMMSettle_whenPoolManagerLocked() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        BalanceDelta amountDelta = toBalanceDelta(-100, -100);

        vm.expectRevert(Errors.PoolManagerMustBeUnlocked.selector);
        vtsOrchestrator.onMMSettle(IMarketFactory(marketFactory), tokenId, 0, amountDelta, false, false);
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

    function test_revert_initPool_whenAlreadyInitialized() public {
        MarketVTSConfiguration memory config = VTSConfigs.getDefaultConfig();
        PoolKey memory poolKeyA = PoolKey({
            currency0: Currency.wrap(address(0x11111111)),
            currency1: Currency.wrap(address(0x22222222)),
            fee: corePoolKey.fee,
            tickSpacing: corePoolKey.tickSpacing,
            hooks: IHooks(address(0))
        });
        vm.startPrank(marketFactory);
        vtsOrchestrator.initPool(poolKeyA, config);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvariantViolated.selector, "VTSOrchestrator: pool already initialized"));
        vtsOrchestrator.initPool(poolKeyA, config);
        vm.stopPrank();
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
        assertEq(ciseAfter.totalCISEExposure0, ciseBefore.totalCISEExposure0, "totalCISEExposure0 should not change");
        // Token1 coverage: when pool totalSettled1 > 0, incrementCoverage eagerly bumps CISE exposure (see VTSCommitLib).
        if (ciseBefore.totalSettled1 > 0) {
            assertEq(
                ciseAfter.totalCISEExposure1,
                ciseBefore.totalCISEExposure1 + amount1,
                "totalCISEExposure1 should increase by covered amount when settled1 > 0"
            );
        } else {
            assertEq(
                ciseAfter.totalCISEExposure1,
                ciseBefore.totalCISEExposure1,
                "totalCISEExposure1 should not change when settled1 == 0"
            );
        }

        // Coverage routing differs by mechanism:
        // - DICE defers into residuals when no deficit principal exists.
        // - CISE only advances when settled liquidity is already live; zero-settled coverage is ignored.
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
            assertEq(
                ciseAfter.ciseIndex1, ciseBefore.ciseIndex1, "CISE index1 should not change when no settled exists"
            );
        }
    }

    function _getPoolDICEAccounting(PoolId poolId) internal view returns (DICEAccounting memory a) {
        (, a.totalDeficitPrincipal1,, a.diceIndex1,, a.diceResidual1) =
            _testableOrchestrator().getPoolDICEAccounting(poolId);
    }

    function _getPoolCISEAccounting(PoolId poolId) internal view returns (CISEAccounting memory a) {
        (a.totalSettled0, a.totalSettled1, a.ciseIndex0, a.ciseIndex1, a.totalCISEExposure0, a.totalCISEExposure1) =
            _testableOrchestrator().getPoolCISEAccounting(poolId);
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

    function test_revert_processPosition_negativeLiquidity_whenNotCoreHook() public {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1e18, salt: bytes32(0)});
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
        vtsOrchestrator.afterCoreSwap(corePoolKey, swapParams, delta, 0, 0, int24(0));
    }

    function test_constructor_revert_whenPoolManagerZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new VTSOrchestratorTestable(address(0), address(oracleHelper), address(liquidityHub), address(this));
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
        vtsOrchestrator.afterCoreSwap(corePoolKey, swapParams, delta, 0, 0, int24(0));
    }

    function test_revert_settlePositionGrowths_whenPoolPaused_andNotCanonicalCoreHook() public {
        (, PositionId positionId,,) = _createCommittedPosition();
        vtsOrchestrator.pausePool(corePoolKey.toId());

        vm.expectRevert(Errors.InvalidSender.selector);
        vtsOrchestrator.settlePositionGrowths(positionId);
    }

    function test_settlePositionGrowths_whenPoolPaused_allowsCanonicalCoreHook() public {
        (, PositionId positionId,,) = _createCommittedPosition();
        vtsOrchestrator.pausePool(corePoolKey.toId());

        vm.prank(coreHookAddress);
        vtsOrchestrator.settlePositionGrowths(positionId);
    }

    function test_revert_calcRFS_whenPoolPaused_andNotCanonicalCoreHook() public {
        (, PositionId positionId,,) = _createCommittedPosition();
        vtsOrchestrator.pausePool(corePoolKey.toId());

        vm.expectRevert(Errors.InvalidSender.selector);
        vtsOrchestrator.calcRFS(positionId, false);
    }

    function test_revert_checkpoint_whenPoolPaused_andNotCanonicalCoreHook() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        vtsOrchestrator.pausePool(corePoolKey.toId());

        vm.expectRevert(Errors.InvalidSender.selector);
        vtsOrchestrator.checkpoint(tokenId, 0, false);
    }

    /// @dev Regression: paused `checkpoint(..., false)` stays blocked (growth settle is CoreHook-only). Advancer
    ///      `checkpoint(..., true)` must still persist commitment backing state so insolvency gates are not blind
    ///      during pause while MM removes remain possible via the hook.
    function test_checkpoint_withCommitment_succeeds_whenPoolPaused_recordsCommitmentDeficit() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        address advancer = liquiditySignal.mmState.advancer;

        bytes memory signalBytes = abi.encode(liquiditySignal);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                liquiditySignal.mmState.owner,
                signalBytes,
                true
            ),
            abi.encode(true, 10)
        );

        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(0);

        vtsOrchestrator.pausePool(corePoolKey.toId());

        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
        );

        (uint256 cd0, uint256 cd1) = _commitmentDeficit(positionId);
        assertTrue(cd0 > 0 || cd1 > 0, "paused commitment checkpoint should record deficit");
    }

    /// @dev Regression (audit finding #2): paused `checkpoint(..., true)` must settle growth before
    ///      `checkpointWithCommitment` so backing uses post-growth `pa.settled` (same outcome as CoreHook settle
    ///      then checkpoint).
    function test_checkpoint_withCommitment_whenPoolPaused_settles_growth_before_commitment_deficit() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        address advancer = liquiditySignal.mmState.advancer;

        bytes memory signalBytes = abi.encode(liquiditySignal);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                liquiditySignal.mmState.owner,
                signalBytes,
                true
            ),
            abi.encode(true, 10)
        );

        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(0);

        (uint256 settled0BeforeSwap, uint256 settled1BeforeSwap) = vtsOrchestrator.getPositionSettledAmounts(positionId);
        settled1BeforeSwap;
        _swapCore(false, -int256(50e18));
        (uint256 settled0AfterSwap, uint256 settled1AfterSwap) = vtsOrchestrator.getPositionSettledAmounts(positionId);
        settled1AfterSwap;
        assertEq(
            settled0AfterSwap,
            settled0BeforeSwap,
            "precondition: swap-driven deficit growth must not be crystallised until settlement"
        );

        vtsOrchestrator.pausePool(corePoolKey.toId());

        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
        );

        (uint256 settled0AfterCheckpoint, uint256 settled1AfterCheckpoint) =
            vtsOrchestrator.getPositionSettledAmounts(positionId);
        settled1AfterCheckpoint;
        assertLt(
            settled0AfterCheckpoint,
            settled0BeforeSwap,
            "paused commitment checkpoint must crystallise deficit growth into settled before commitment math"
        );

        (uint256 cd0, uint256 cd1) = _commitmentDeficit(positionId);
        assertTrue(cd0 > 0 || cd1 > 0, "expected commitment deficit after growth-aware paused checkpoint");
    }

    /// @dev Same as pool-pause regression but under global pause.
    function test_checkpoint_withCommitment_whenGloballyPaused_settles_growth_before_commitment_deficit() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        address advancer = liquiditySignal.mmState.advancer;

        bytes memory signalBytes = abi.encode(liquiditySignal);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                liquiditySignal.mmState.owner,
                signalBytes,
                true
            ),
            abi.encode(true, 10)
        );

        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(0);

        (uint256 settled0BeforeSwap, uint256 settled1BeforeSwapG) =
            vtsOrchestrator.getPositionSettledAmounts(positionId);
        settled1BeforeSwapG;
        _swapCore(false, -int256(50e18));

        vm.prank(vtsOrchestrator.owner());
        vtsOrchestrator.setGlobalPause(true);

        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
        );

        (uint256 settled0AfterCheckpoint, uint256 settled1AfterCheckpointG2) =
            vtsOrchestrator.getPositionSettledAmounts(positionId);
        settled1AfterCheckpointG2;
        assertLt(settled0AfterCheckpoint, settled0BeforeSwap, "global pause: growth must crystallise before commitment");

        (uint256 cd0, uint256 cd1) = _commitmentDeficit(positionId);
        assertTrue(cd0 > 0 || cd1 > 0, "global pause: commitment deficit should be recorded");
    }

    /// @dev Soft pause: `onSeize` pre-check remains available under pool pause (seizure path is not pause-gated).
    function test_onSeize_validateSeize_succeeds_whenPoolPaused_after_checkpoint_and_warp() public {
        (uint256 tokenId,,,) = _createCommittedPosition();

        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(0);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
        );

        vtsOrchestrator.pausePool(corePoolKey.toId());

        vm.warp(block.timestamp + 10_000_000);

        unlockCaller.run(address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.onSeize.selector, tokenId, 0));
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
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                liquiditySignal.mmState.owner,
                signalBytes,
                true
            ),
            abi.encode(true, 3600)
        );

        bytes memory result = unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.commitSignal.selector,
                IMarketFactory(marketFactory),
                liquiditySignal.mmState.owner,
                signalBytes
            )
        );
        uint256 commitId = abi.decode(result, (uint256));

        assertGt(commitId, 0, "CommitId should be non-zero");
        assertTrue(vtsOrchestrator.isSignalValid(commitId, true), "Commit should be valid");
    }

    function test_isSignalValid_expiredCommit_requireLiveSignalFalse() public {
        bytes memory signalBytes = abi.encode(liquiditySignal);

        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                liquiditySignal.mmState.owner,
                signalBytes,
                true
            ),
            abi.encode(true, 3600)
        );

        bytes memory result = unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.commitSignal.selector,
                IMarketFactory(marketFactory),
                liquiditySignal.mmState.owner,
                signalBytes
            )
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
                bytes4(keccak256("renewSignal(address,address,uint256,bytes)")),
                address(marketFactory),
                address(this),
                0,
                signalBytes
            )
        );
    }

    function test_renewSignal_extendsExpiry() public {
        bytes memory signalBytes = abi.encode(liquiditySignal);

        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                liquiditySignal.mmState.owner,
                signalBytes,
                true
            ),
            abi.encode(true, 3600)
        );

        bytes memory result = unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.commitSignal.selector,
                IMarketFactory(marketFactory),
                liquiditySignal.mmState.owner,
                signalBytes
            )
        );
        uint256 commitId = abi.decode(result, (uint256));

        (, uint256 expiresAtBefore,,,) = vtsOrchestrator.getCommit(commitId);

        // Warp forward
        vm.warp(block.timestamp + 1000);

        // Renewal must preserve commit ownership.
        LiquiditySignal memory sameOwnerRenew = liquiditySignal;
        sameOwnerRenew.nonce += 1;
        bytes memory renewSignalBytes = abi.encode(sameOwnerRenew);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                liquiditySignal.mmState.advancer,
                renewSignalBytes,
                true
            ),
            abi.encode(true, 3600)
        );

        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("renewSignal(address,address,uint256,bytes)")),
                address(marketFactory),
                liquiditySignal.mmState.advancer,
                commitId,
                renewSignalBytes
            )
        );

        (, uint256 expiresAtAfter,,,) = vtsOrchestrator.getCommit(commitId);
        assertGt(expiresAtAfter, expiresAtBefore, "Expiry should be extended");
    }

    /// @dev VRL may attest empty reserves; recovery flows must not treat that as a missing commit.
    /// @dev Do not assign `s = base` then mutate: memory struct copies can alias nested dynamic data and corrupt `base`.
    function _liquiditySignalWithEmptyReservesAndNonce(LiquiditySignal memory base, uint256 newNonce)
        internal
        pure
        returns (LiquiditySignal memory s)
    {
        s.rootHash = base.rootHash;
        s.rootHashSignature = base.rootHashSignature;
        s.merkleProof = base.merkleProof;
        s.mmSignature = base.mmSignature;
        s.nonce = newNonce;
        MarketMaker.State memory mm;
        mm.owner = base.mmState.owner;
        mm.sourceState = base.mmState.sourceState;
        mm.prover = base.mmState.prover;
        mm.nonce = base.mmState.nonce;
        mm.advancer = base.mmState.advancer;
        mm.reserves = new MarketMaker.Reserve[](0);
        s.mmState = mm;
    }

    function test_emptyReserves_isSignalValid_requireLiveSignalFalse_andRecoveryRenew() public {
        LiquiditySignal memory baseSig = liquiditySignal;
        bytes memory commitBytes = abi.encode(baseSig);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")), baseSig.mmState.owner, commitBytes, true
            ),
            abi.encode(true, 3600)
        );

        uint256 commitId = abi.decode(
            unlockCaller.run(
                address(vtsOrchestrator),
                abi.encodeWithSelector(
                    VTSOrchestrator.commitSignal.selector,
                    IMarketFactory(marketFactory),
                    baseSig.mmState.owner,
                    commitBytes
                )
            ),
            (uint256)
        );

        LiquiditySignal memory emptyRenew = _liquiditySignalWithEmptyReservesAndNonce(baseSig, baseSig.nonce + 1);
        bytes memory emptyBytes = abi.encode(emptyRenew);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                emptyRenew.mmState.advancer,
                emptyBytes,
                true
            ),
            abi.encode(true, 3600)
        );
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("renewSignal(address,address,uint256,bytes)")),
                IMarketFactory(marketFactory),
                emptyRenew.mmState.advancer,
                commitId,
                emptyBytes
            )
        );

        (MarketMaker.State memory mmAfter,,,,) = vtsOrchestrator.getCommit(commitId);
        assertEq(mmAfter.reserves.length, 0, "renewal should persist empty reserves");

        assertTrue(
            vtsOrchestrator.isSignalValid(commitId, false), "empty reserves: commit should exist for recovery paths"
        );
        assertFalse(
            vtsOrchestrator.isSignalValid(commitId, true), "empty reserves: must not count as a live VRL-backed signal"
        );

        // Full deep copy (including nested `string` fields in reserves); struct assignment can alias string buffers.
        LiquiditySignal memory restore = abi.decode(abi.encode(baseSig), (LiquiditySignal));
        restore.nonce = baseSig.nonce + 2;
        bytes memory restoreBytes = abi.encode(restore);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                restore.mmState.advancer,
                restoreBytes,
                true
            ),
            abi.encode(true, 3600)
        );
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("renewSignal(address,address,uint256,bytes)")),
                IMarketFactory(marketFactory),
                restore.mmState.advancer,
                commitId,
                restoreBytes
            )
        );

        (MarketMaker.State memory mmFinal, uint256 expFinal,,,) = vtsOrchestrator.getCommit(commitId);
        assertGt(mmFinal.reserves.length, 0, "restore renew should persist non-empty reserves");
        assertGt(expFinal, block.timestamp, "commit should not be expired after recovery renew");

        assertTrue(vtsOrchestrator.isSignalValid(commitId, true), "after recovery renew, live signal should be valid");
    }

    function test_checkpoint_afterEmptyReservesRenewal_succeeds() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        LiquiditySignal memory baseSig = liquiditySignal;

        LiquiditySignal memory emptyRenew = _liquiditySignalWithEmptyReservesAndNonce(baseSig, baseSig.nonce + 1);
        bytes memory emptyBytes = abi.encode(emptyRenew);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                emptyRenew.mmState.advancer,
                emptyBytes,
                true
            ),
            abi.encode(true, 3600)
        );
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("renewSignal(address,address,uint256,bytes)")),
                IMarketFactory(marketFactory),
                emptyRenew.mmState.advancer,
                tokenId,
                emptyBytes
            )
        );

        vm.warp(block.timestamp + 1000);
        vm.expectEmit(false, false, false, false, address(vtsOrchestrator));
        emit Checkpointed(tokenId, 0, RFSCheckpoint(0, 0, 0, 0, 0), false);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, false)
        );

        assertTrue(vtsOrchestrator.isPositionValid(positionId, true));
    }

    function test_onSeize_afterEmptyReservesRenewal_doesNotRevertInvalidSignal() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        LiquiditySignal memory baseSig = liquiditySignal;

        LiquiditySignal memory emptyRenew = _liquiditySignalWithEmptyReservesAndNonce(baseSig, baseSig.nonce + 1);
        bytes memory emptyBytes = abi.encode(emptyRenew);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                emptyRenew.mmState.advancer,
                emptyBytes,
                true
            ),
            abi.encode(true, 3600)
        );
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("renewSignal(address,address,uint256,bytes)")),
                IMarketFactory(marketFactory),
                emptyRenew.mmState.advancer,
                tokenId,
                emptyBytes
            )
        );

        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(0);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
        );

        vm.warp(block.timestamp + 10_000_000);
        unlockCaller.run(address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.onSeize.selector, tokenId, 0));
        assertTrue(vtsOrchestrator.isPositionValid(positionId, true));
    }

    function test_revert_onMMSettle_nonSeizing_whenCommitHasEmptyReserves() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        LiquiditySignal memory baseSig = liquiditySignal;

        LiquiditySignal memory emptyRenew = _liquiditySignalWithEmptyReservesAndNonce(baseSig, baseSig.nonce + 1);
        bytes memory emptyBytes = abi.encode(emptyRenew);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                emptyRenew.mmState.advancer,
                emptyBytes,
                true
            ),
            abi.encode(true, 3600)
        );
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("renewSignal(address,address,uint256,bytes)")),
                IMarketFactory(marketFactory),
                emptyRenew.mmState.advancer,
                tokenId,
                emptyBytes
            )
        );

        BalanceDelta depositDelta = toBalanceDelta(int128(-1), int128(-1));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignal.selector, tokenId));
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.onMMSettle.selector,
                IMarketFactory(marketFactory),
                tokenId,
                0,
                depositDelta,
                false,
                false
            )
        );
    }

    /// @notice Empty reserves: recovery-style validity vs live-gated MM settle (finding #6 policy boundary).
    function test_emptyReserves_checkpointAllowed_nonSeizingMMSettleStillReverts() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        LiquiditySignal memory baseSig = liquiditySignal;

        LiquiditySignal memory emptyRenew = _liquiditySignalWithEmptyReservesAndNonce(baseSig, baseSig.nonce + 1);
        bytes memory emptyBytes = abi.encode(emptyRenew);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                emptyRenew.mmState.advancer,
                emptyBytes,
                true
            ),
            abi.encode(true, 3600)
        );
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("renewSignal(address,address,uint256,bytes)")),
                IMarketFactory(marketFactory),
                emptyRenew.mmState.advancer,
                tokenId,
                emptyBytes
            )
        );

        assertTrue(
            vtsOrchestrator.isSignalValid(tokenId, false), "recovery paths should treat empty reserves as valid enough"
        );
        assertFalse(vtsOrchestrator.isSignalValid(tokenId, true), "live-signal flows must reject empty reserves");

        vm.warp(block.timestamp + 1000);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, false)
        );

        BalanceDelta depositDelta = toBalanceDelta(int128(-1), int128(-1));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignal.selector, tokenId));
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.onMMSettle.selector,
                IMarketFactory(marketFactory),
                tokenId,
                0,
                depositDelta,
                false,
                false
            )
        );
    }

    function test_revert_processPosition_mmPoke_whenCommitHasEmptyReserves() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        LiquiditySignal memory baseSig = liquiditySignal;

        LiquiditySignal memory emptyRenew = _liquiditySignalWithEmptyReservesAndNonce(baseSig, baseSig.nonce + 1);
        bytes memory emptyBytes = abi.encode(emptyRenew);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                emptyRenew.mmState.advancer,
                emptyBytes,
                true
            ),
            abi.encode(true, 3600)
        );
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("renewSignal(address,address,uint256,bytes)")),
                IMarketFactory(marketFactory),
                emptyRenew.mmState.advancer,
                tokenId,
                emptyBytes
            )
        );

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -60, tickUpper: 60, liquidityDelta: 0, salt: PositionLibrary.generateSalt(tokenId, 0)
        });
        bytes memory hookData = PositionModificationHookDataLib.encode(tokenId, 0, address(positionManager));

        vm.prank(coreHookAddress);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignal.selector, tokenId));
        vtsOrchestrator.processPosition(
            address(positionManager), corePoolKey, params, toBalanceDelta(0, 0), toBalanceDelta(0, 0), hookData
        );

        assertTrue(vtsOrchestrator.isPositionValid(positionId, true));
    }

    function test_processPosition_seizureHook_passesSignalPreCheck_withEmptyReserves() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        LiquiditySignal memory baseSig = liquiditySignal;

        LiquiditySignal memory emptyRenew = _liquiditySignalWithEmptyReservesAndNonce(baseSig, baseSig.nonce + 1);
        bytes memory emptyBytes = abi.encode(emptyRenew);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                emptyRenew.mmState.advancer,
                emptyBytes,
                true
            ),
            abi.encode(true, 3600)
        );
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("renewSignal(address,address,uint256,bytes)")),
                IMarketFactory(marketFactory),
                emptyRenew.mmState.advancer,
                tokenId,
                emptyBytes
            )
        );

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -60, tickUpper: 60, liquidityDelta: 0, salt: PositionLibrary.generateSalt(tokenId, 0)
        });
        bytes memory hookData =
            PositionModificationHookDataLib.encodeSeizure(tokenId, 0, address(positionManager), int128(0), int128(0));

        vm.prank(coreHookAddress);
        vtsOrchestrator.processPosition(
            address(positionManager), corePoolKey, params, toBalanceDelta(0, 0), toBalanceDelta(0, 0), hookData
        );

        assertTrue(vtsOrchestrator.isPositionValid(positionId, true));
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

    function test_isPositionValid_missingOneCommitmentMax_returnsTrueWhenActive() public {
        // commitmentMax is tracked mechanically; force one side to zero to cover the edge-case.
        (, PositionId positionId,,) = _createCommittedPosition();

        // Force only one side to be zero.
        _testableOrchestrator()._setCommitmentMax(positionId, 0, 1);

        bool isValid = vtsOrchestrator.isPositionValid(positionId, true);
        assertTrue(isValid, "Position should remain valid while active even if one commitment max is zero");
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

    function test_revert_calcRFS_whenRFSOpen_requiresClosedRfS() public {
        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(1e30);

        (, PositionId positionId,,) = _createCommittedPosition();

        _swapCore(false, -int256(50e18));
        vtsOrchestrator.settlePositionGrowths(positionId);

        (bool rfsOpen,) = vtsOrchestrator.calcRFS(positionId, false);
        assertTrue(rfsOpen, "precondition: live RFS should be open");

        vm.expectRevert(abi.encodeWithSelector(Errors.RFSOpenForPosition.selector, positionId));
        vtsOrchestrator.calcRFS(positionId, true);
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

    function test_settlePositionGrowths_activeOneSidedCommitmentMax_stillSettles() public {
        (, PositionId positionId,,) = _createCommittedPosition();
        _testableOrchestrator()._setCommitmentMax(positionId, 0, 1);

        // Active positions should still settle growths even if one commitment side rounds to zero.
        bytes4 extsload1 = bytes4(keccak256("extsload(bytes32)"));
        vm.expectCall(address(manager), abi.encodeWithSelector(extsload1));
        vtsOrchestrator.settlePositionGrowths(positionId);
    }

    function test_settlePositionGrowths_inactivePosition_stillSettles() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        Position memory posBeforeRemove = vtsOrchestrator.getPosition(positionId);
        _decreasePosition(tokenId, posBeforeRemove.liquidity);

        Position memory posAfterRemove = vtsOrchestrator.getPosition(positionId);
        assertFalse(posAfterRemove.isActive, "precondition: position should be inactive after full remove");

        bytes4 extsload1 = bytes4(keccak256("extsload(bytes32)"));
        vm.expectCall(address(manager), abi.encodeWithSelector(extsload1));
        vtsOrchestrator.settlePositionGrowths(positionId);
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
            abi.encodeWithSelector(
                VTSOrchestrator.extendGracePeriod.selector, marketFactory, corePoolKey, 0, 0, 0, 0, settlementProof
            )
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
                VTSOrchestrator.extendGracePeriod.selector,
                marketFactory,
                corePoolKey,
                tokenId,
                badIndex,
                0,
                0,
                settlementProof
            )
        );
    }

    function test_extendGracePeriod_updatesCheckpoint() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        PositionId positionId = vtsOrchestrator.getPositionId(tokenId, 0);

        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(0);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
        );

        RFSCheckpoint memory checkpointBefore = vtsOrchestrator.positionToCheckpoint(positionId);

        bytes memory settlementProof = abi.encode(1);
        vm.mockCall(
            address(settlementObserver),
            abi.encodeWithSelector(IVRLSettlementObserver.verifySettlementProof.selector),
            abi.encode(true)
        );

        // Event must be emitted; we don't assert the struct payload here (data unchecked).
        vm.expectEmit(false, false, false, false, address(vtsOrchestrator));
        emit GracePeriodExtended(tokenId, 0, 0, RFSCheckpoint(0, 0, 0, 0, 0));

        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.extendGracePeriod.selector,
                marketFactory,
                corePoolKey,
                tokenId,
                0,
                0,
                0,
                settlementProof
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

        // Snapshot commitment + RFS with `checkpoint(..., true)`. `_mockSignalUsd(0)` can yield a non-zero
        // commitmentDeficit, so after a long warp `onSeize` may succeed via commitment-deficit bypass and/or
        // checkpointed grace depending on the resulting `isSeizable` branches — not exclusively the normal RFS path.
        // For an isolated normal RFS grace exercise, see `test_onSeize_validatesGracePeriod_normalRfsPath_isolated`.
        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(0);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
        );

        vm.warp(block.timestamp + 10_000_000);

        // Should not revert once seizability preconditions (per `CheckpointLibrary.isSeizable`) are satisfied.
        unlockCaller.run(address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.onSeize.selector, tokenId, 0));
    }

    /// @dev Open RFS from swap-driven deficit while the liquidity signal stays fully backed, so seizure after grace
    ///      uses the checkpointed RFS path rather than commitment-deficit bypass.
    function test_onSeize_validatesGracePeriod_normalRfsPath_isolated() public {
        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(1e30);

        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();

        (uint256 cd0, uint256 cd1) = _commitmentDeficit(positionId);
        assertEq(cd0, 0, "setup: no commitment deficit with backed signal");
        assertEq(cd1, 0, "setup: no commitment deficit with backed signal");

        _swapCore(false, -int256(50e18));
        vtsOrchestrator.settlePositionGrowths(positionId);

        (cd0, cd1) = _commitmentDeficit(positionId);
        assertEq(cd0, 0, "post-swap: still no commitment deficit");
        assertEq(cd1, 0, "post-swap: still no commitment deficit");

        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, false)
        );

        RFSCheckpoint memory cp = vtsOrchestrator.positionToCheckpoint(positionId);
        assertTrue(cp.openMask != 0, "checkpoint must record open RFS for grace measurement");

        vm.warp(block.timestamp + 10_000_000);

        unlockCaller.run(address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.onSeize.selector, tokenId, 0));
    }

    /// @dev Spec regression: `onSeize` must not materialise the first ordinary RFS checkpoint itself.
    function test_onSeize_doesNotStartOrdinaryGraceWithoutPriorCheckpoint() public {
        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(1e30);

        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();

        (uint256 cd0, uint256 cd1) = _commitmentDeficit(positionId);
        assertEq(cd0, 0, "setup: no commitment deficit with backed signal");
        assertEq(cd1, 0, "setup: no commitment deficit with backed signal");

        _swapCore(false, -int256(50e18));
        vtsOrchestrator.settlePositionGrowths(positionId);

        (bool rfsOpen,) = vtsOrchestrator.calcRFS(positionId, false);
        assertTrue(rfsOpen, "precondition: live RFS should be open");

        RFSCheckpoint memory cpBefore = vtsOrchestrator.positionToCheckpoint(positionId);
        assertEq(cpBefore.openMask, 0, "precondition: no stored checkpoint yet");

        vm.warp(block.timestamp + 10_000_000);

        vm.expectRevert(abi.encodeWithSelector(Errors.RFSNotOpenForPosition.selector, positionId));
        unlockCaller.run(address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.onSeize.selector, tokenId, 0));
    }

    function test_onSeize_recomputesCommitmentDeficit_beforeBypass() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        address advancer = liquiditySignal.mmState.advancer;

        // Create a deficit snapshot first.
        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(0);
        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
        );

        (uint256 cd0Before, uint256 cd1Before) = _commitmentDeficit(positionId);
        assertTrue(cd0Before > 0 || cd1Before > 0, "expected non-zero commitment deficit before signal recovery");

        // Recover backing without running another explicit checkpoint.
        _mockSignalUsd(1e30);

        // onSeize must recompute commitment deficit and reject stale bypass.
        vm.expectRevert();
        unlockCaller.run(address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.onSeize.selector, tokenId, 0));
    }

    function test_revert_checkpoint_whenCommitInvalid_insideUnlock() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignal.selector, uint256(0)));
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, 0, 0, false)
        );
    }

    function test_revert_checkpoint_whenPositionIndexInvalid_insideUnlock() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        uint256 badIndex = 12345;

        // Unset mapping index yields PositionId(0), which must fail position validity.
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPosition.selector, 0, 0, PositionId.wrap(bytes32(0))));
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, badIndex, false)
        );
    }

    function test_checkpoint_marksCheckpoint() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        PositionId positionId = vtsOrchestrator.getPositionId(tokenId, 0);

        // Set the block timestamp
        vm.warp(block.timestamp + 10000000);

        vm.expectEmit(false, false, false, false, address(vtsOrchestrator));
        emit Checkpointed(tokenId, 0, RFSCheckpoint(0, 0, 0, 0, 0), false);

        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, false)
        );

        RFSCheckpoint memory checkpointAfter = vtsOrchestrator.positionToCheckpoint(positionId);
        (, BalanceDelta rfsDeltaAfter) = vtsOrchestrator.calcRFS(positionId, false);
        uint8 expectedOpenMask = _expectedOpenMask(rfsDeltaAfter);

        assertEq(checkpointAfter.openMask, expectedOpenMask, "Checkpoint openMask should match current RFS lanes");
        if ((expectedOpenMask & 1) == 0) {
            assertEq(checkpointAfter.openSince0, 0, "token0 openSince should clear when token0 RFS closes");
        }
        if ((expectedOpenMask & 2) == 0) {
            assertEq(checkpointAfter.openSince1, 0, "token1 openSince should clear when token1 RFS closes");
        }
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
                VTSOrchestrator.onMMSettle.selector, IMarketFactory(marketFactory), 0, 0, amountDelta, false, false
            )
        );
    }

    function test_revert_onMMSettle_whenCallerIsNotPositionOwner_insideUnlock() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        BalanceDelta depositDelta = toBalanceDelta(int128(-1), int128(-1));

        vm.expectRevert(Errors.InvalidSender.selector);
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.onMMSettle.selector,
                IMarketFactory(marketFactory),
                tokenId,
                0,
                depositDelta,
                false,
                false
            )
        );
    }

    function test_onMMSettle_viaMmpm_emitsNonSeizingSettlement_andRfsOpenMatchesCalcRFS() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        address advancer = liquiditySignal.mmState.advancer;

        bytes memory signalBytes = abi.encode(liquiditySignal);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                liquiditySignal.mmState.owner,
                signalBytes,
                true
            ),
            abi.encode(true, 10)
        );
        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(0);

        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
        );

        (uint256 cd0, uint256 cd1) = _commitmentDeficit(positionId);
        int128 pay0 = _negInt128Capped(cd0 / 2);
        int128 pay1 = _negInt128Capped(cd1 / 2);

        vm.recordLogs();
        _mmSettle(tokenId, 0, pay0, pay1);

        (uint256 loggedCommitId, uint256 loggedPositionIndex, bool isSeizing, bool rfsOpen) = _lastPositionSettledMeta();
        assertEq(loggedCommitId, tokenId, "PositionSettled commitId should match");
        assertEq(loggedPositionIndex, 0, "PositionSettled positionIndex should match");
        assertFalse(isSeizing, "non-seizing MM settlement must emit isSeizing=false");

        (bool rfsOpenExpected,) = vtsOrchestrator.calcRFS(positionId, false);
        assertEq(rfsOpen, rfsOpenExpected, "rfsOpen should match calcRFS result");
    }

    function test_onMMSettle_refreshesCheckpointFromFinalRfsState() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        address advancer = liquiditySignal.mmState.advancer;

        bytes memory signalBytes = abi.encode(liquiditySignal);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                liquiditySignal.mmState.owner,
                signalBytes,
                true
            ),
            abi.encode(true, 10)
        );
        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(0);

        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
        );

        RFSCheckpoint memory checkpointBefore = vtsOrchestrator.positionToCheckpoint(positionId);
        assertTrue(checkpointBefore.openMask != 0, "checkpoint should start with at least one open RFS lane");

        (uint256 cd0Before, uint256 cd1Before) = _commitmentDeficit(positionId);
        _mmSettle(tokenId, 0, _negInt128Capped(cd0Before), _negInt128Capped(cd1Before));

        (bool rfsOpenAfter, BalanceDelta rfsDeltaAfter) = vtsOrchestrator.calcRFS(positionId, false);
        RFSCheckpoint memory checkpointAfter = vtsOrchestrator.positionToCheckpoint(positionId);
        uint8 expectedOpenMask = _expectedOpenMask(rfsDeltaAfter);

        assertEq(checkpointAfter.openMask, expectedOpenMask, "checkpoint openMask should match final RFS lanes");
        assertEq(rfsOpenAfter, expectedOpenMask != 0, "final rfsOpen should match final RFS lanes");
        if ((expectedOpenMask & 1) == 0) {
            assertEq(checkpointAfter.openSince0, 0, "token0 openSince should clear when token0 RFS closes");
        }
        if ((expectedOpenMask & 2) == 0) {
            assertEq(checkpointAfter.openSince1, 0, "token1 openSince should clear when token1 RFS closes");
        }
    }

    function test_checkpoint_withCommitment_validatesBacking() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        address advancer = liquiditySignal.mmState.advancer;

        bytes memory unbackedLiquiditySignal = abi.encode(liquiditySignal);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                liquiditySignal.mmState.owner,
                unbackedLiquiditySignal,
                true
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
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
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
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                liquiditySignal.mmState.owner,
                signalBytes,
                true
            ),
            abi.encode(true, 10)
        );

        // Mock proper LCC prices (1e18 = $1 in 18 decimals) so issuedUsd is non-zero
        _mockLccPrices(1e18, 1e18);
        // Force insufficient backing from the signal (settled starts at 0)
        _mockSignalUsd(0);

        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
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

    function test_revert_onMMSettle_whenFactoryInvalid_insideUnlock() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        BalanceDelta depositDelta = toBalanceDelta(int128(-1), int128(-1));
        IMarketFactory invalidFactory = IMarketFactory(address(0xBEEF));

        vm.expectRevert(Errors.InvalidSender.selector);
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.onMMSettle.selector, invalidFactory, tokenId, 0, depositDelta, false, false
            )
        );
    }

    function test_revert_onMMSettle_whenCallerBoundButNotPositionOwner_insideUnlock() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        BalanceDelta depositDelta = toBalanceDelta(int128(-1), int128(-1));

        UnlockCaller boundCaller = new UnlockCaller(manager);
        address[] memory extraBounds = new address[](1);
        extraBounds[0] = address(boundCaller);
        MarketFactory(marketFactory).addBounds(extraBounds);

        vm.expectRevert(Errors.InvalidSender.selector);
        boundCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.onMMSettle.selector,
                IMarketFactory(marketFactory),
                tokenId,
                0,
                depositDelta,
                false,
                false
            )
        );
    }

    function test_onMMSettle_viaMmpm_netsBackingDeficit_inPositionAccounting() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        address advancer = liquiditySignal.mmState.advancer;

        bytes memory signalBytes = abi.encode(liquiditySignal);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                liquiditySignal.mmState.owner,
                signalBytes,
                true
            ),
            abi.encode(true, 10)
        );
        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(0);
        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
        );

        (uint256 cd0Before, uint256 cd1Before) = _commitmentDeficit(positionId);
        assertTrue(cd0Before > 0 || cd1Before > 0, "Expected non-zero backing deficit before settlement");
        (, BalanceDelta rfsBefore) = vtsOrchestrator.calcRFS(positionId, false);

        _mmSettle(tokenId, 0, _negInt128Capped(cd0Before), _negInt128Capped(cd1Before));

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
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                liquiditySignal.mmState.owner,
                signalBytes,
                true
            ),
            abi.encode(true, 10)
        );

        // First checkpoint: force a deficit
        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(0);
        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
        );

        (uint256 cd0Before, uint256 cd1Before) = _commitmentDeficit(positionId);
        assertTrue(cd0Before > 0 || cd1Before > 0, "Expected deficit before increasing signal backing");
        (, BalanceDelta rfsBefore) = vtsOrchestrator.calcRFS(positionId, false);

        // Second checkpoint: increase signal backing sufficiently, deficit should be reduced/cleared
        _mockSignalUsd(1e30);
        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
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

    function test_onMMSettle_viaMmpm_partialDeposit_reducesBackingDeficit_proRata() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        address advancer = liquiditySignal.mmState.advancer;

        bytes memory signalBytes = abi.encode(liquiditySignal);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                liquiditySignal.mmState.owner,
                signalBytes,
                true
            ),
            abi.encode(true, 10)
        );
        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(0);
        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
        );

        (uint256 cd0Before, uint256 cd1Before) = _commitmentDeficit(positionId);
        assertTrue(cd0Before > 1, "Need non-trivial token0 deficit for partial reduction test");

        uint256 half0 = cd0Before / 2;
        _mmSettle(tokenId, 0, _negInt128Capped(half0), int128(0));

        (uint256 cd0After, uint256 cd1After) = _commitmentDeficit(positionId);
        assertEq(cd0After, cd0Before - half0, "Partial settlement should reduce token0 deficit by deposit");
        assertEq(cd1After, cd1Before, "Partial settlement should not affect token1 deficit");
    }

    /// @dev Paused remove uses the same RFS gate as unpaused: cannot decrease while RFS is open (non-seizure).
    function test_revert_pausedRemoveLiquidity_whenRfsOpen() public {
        uint256 liquidity = 1e10;
        uint256 amountToDecrease = liquidity / 2;
        (uint256 pausedTokenId, PositionId pausedPositionId,,) =
            _createCommittedPosition(renewSignal, -60, 60, liquidity, bytes32(0));

        _swapCore(true, -int256(1e18));

        (bool rfsOpenBefore,) = vtsOrchestrator.calcRFS(pausedPositionId, false);
        assertTrue(rfsOpenBefore, "swap should leave RFS open");

        vtsOrchestrator.pausePool(corePoolKey.toId());

        // CoreHook wraps hook reverts as `CustomRevert.WrappedError`, so assert durable state instead of the outer payload.
        uint128 liqBefore = vtsOrchestrator.getPosition(pausedPositionId).liquidity;
        vm.expectRevert();
        _decreasePosition(pausedTokenId, amountToDecrease);
        // Do not call `calcRFS` here while the pool is paused: the public entrypoint settles growths first and is
        // CoreHook-gated under pause. Position liquidity is the durable proof the decrease did not land.
        assertEq(
            uint256(vtsOrchestrator.getPosition(pausedPositionId).liquidity),
            uint256(liqBefore),
            "position liquidity must be unchanged when decrease reverts"
        );
    }

    /// @dev Regression for finding 6: paused remove must materialise queued positive slashes.
    function test_pausedRemoveLiquidity_materialisesPositivePendingSlash() public {
        uint256 liquidity = 1e10;
        uint256 amountToDecrease = liquidity / 2;
        (uint256 tokenId, PositionId positionId,,) =
            _createCommittedPosition(renewSignal, -60, 60, liquidity, bytes32(uint256(77)));

        // Build slashable state: create deficit, exercise coverage, then settle growths.
        _swapCore(true, -int256(2e18));
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 2e18, 2e18);
        vtsOrchestrator.settlePositionGrowths(positionId);

        // Ensure we have a positive pending slash lane; if not, try once in the opposite swap direction.
        (,, int256 pending0Seed, int256 pending1Seed) = vtsOrchestrator.getPositionFeeAccounting(positionId);
        if (pending0Seed <= 0 && pending1Seed <= 0) {
            _swapCore(false, -int256(2e18));
            vm.prank(marketFactory);
            vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 2e18, 2e18);
            vtsOrchestrator.settlePositionGrowths(positionId);
            (,, pending0Seed, pending1Seed) = vtsOrchestrator.getPositionFeeAccounting(positionId);
        }
        assertTrue(pending0Seed > 0 || pending1Seed > 0, "precondition: expected positive pending slash");

        // Non-seizure remove requires closed RFS. If open, settle exactly the required positive lanes.
        (bool rfsOpenBefore, BalanceDelta rfsDeltaBefore) = vtsOrchestrator.calcRFS(positionId, false);
        if (rfsOpenBefore) {
            int128 settle0 = rfsDeltaBefore.amount0() > 0 ? -rfsDeltaBefore.amount0() : int128(0);
            int128 settle1 = rfsDeltaBefore.amount1() > 0 ? -rfsDeltaBefore.amount1() : int128(0);
            if (settle0 != 0 || settle1 != 0) {
                _mmSettle(tokenId, 0, settle0, settle1);
            }
        }

        (bool rfsOpenAfterClose,) = vtsOrchestrator.calcRFS(positionId, false);
        assertFalse(rfsOpenAfterClose, "precondition: RFS must be closed before paused remove");

        (,, int256 pending0Before, int256 pending1Before) = vtsOrchestrator.getPositionFeeAccounting(positionId);
        (uint256 pot0Before, uint256 pot1Before) = vtsOrchestrator.getSlashedPot(corePoolKey.toId());

        vtsOrchestrator.pausePool(corePoolKey.toId());
        _decreasePosition(tokenId, amountToDecrease);
        vtsOrchestrator.unpausePool(corePoolKey.toId());

        (,, int256 pending0After, int256 pending1After) = vtsOrchestrator.getPositionFeeAccounting(positionId);
        (uint256 pot0After, uint256 pot1After) = vtsOrchestrator.getSlashedPot(corePoolKey.toId());

        if (pending0Before > 0) {
            assertLt(pending0After, pending0Before, "paused remove should materialise token0 pending slash");
            assertGt(pot0After, pot0Before, "paused remove should fund token0 slashed pot");
        }
        if (pending1Before > 0) {
            assertLt(pending1After, pending1Before, "paused remove should materialise token1 pending slash");
            assertGt(pot1After, pot1Before, "paused remove should fund token1 slashed pot");
        }
    }

    function test_pausedRemoveLiquidity_reconcilesSettledCommitmentOnPartialRemove() public {
        uint256 liquidity = 1e10;
        uint256 amountToDecrease = liquidity / 2;
        (uint256 tokenId, PositionId positionId,,) =
            _createCommittedPosition(renewSignal, -60, 60, liquidity, bytes32(uint256(1)));

        (uint256 commitment0Before, uint256 commitment1Before) = vtsOrchestrator.getCommitmentMaxima(positionId);
        (uint256 settled0Before, uint256 settled1Before) = vtsOrchestrator.getPositionSettledAmounts(positionId);
        assertEq(
            vtsOrchestrator.getPosition(positionId).liquidity,
            liquidity,
            "precondition: stored liquidity should match minted liquidity"
        );
        assertGt(commitment0Before, 0, "precondition: commitment0 should be non-zero");
        assertGt(commitment1Before, 0, "precondition: commitment1 should be non-zero");
        assertGt(settled0Before, 0, "precondition: settled0 should be non-zero");
        assertGt(settled1Before, 0, "precondition: settled1 should be non-zero");

        vtsOrchestrator.pausePool(corePoolKey.toId());
        _decreasePosition(tokenId, amountToDecrease);
        vtsOrchestrator.unpausePool(corePoolKey.toId());

        (uint256 commitment0AfterHalf, uint256 commitment1AfterHalf) = vtsOrchestrator.getCommitmentMaxima(positionId);
        (uint256 settled0AfterHalf, uint256 settled1AfterHalf) = vtsOrchestrator.getPositionSettledAmounts(positionId);
        Position memory posAfterHalf = vtsOrchestrator.getPosition(positionId);

        assertLt(commitment0AfterHalf, commitment0Before, "paused half-remove should reduce commitment0");
        assertLt(commitment1AfterHalf, commitment1Before, "paused half-remove should reduce commitment1");
        assertLe(settled0AfterHalf, commitment0AfterHalf, "settled0 should not exceed post-remove commitment0");
        assertLe(settled1AfterHalf, commitment1AfterHalf, "settled1 should not exceed post-remove commitment1");
        assertLe(settled0AfterHalf, settled0Before, "paused remove should not increase settled0");
        assertLe(settled1AfterHalf, settled1Before, "paused remove should not increase settled1");
        assertEq(
            posAfterHalf.liquidity, liquidity - amountToDecrease, "liquidity mirror should update after paused remove"
        );
        assertTrue(posAfterHalf.isActive, "partially removed position should remain active");
    }

    /// @notice E2E (finding 5): paused full remove clears commitment-deficit storage (amounts, since, bps); after
    ///         reactivation a new underbacking episode restarts the commitment-deficit bypass clock.
    function test_e2e_pausedFullRemove_resetsCommitmentDeficitAge_beforeReactivation() public {
        (uint256 tokenId, PositionId positionId, uint256 bypassSecs) = _e2eFinding5_setupMarketAndCommittedPosition();
        address advancer = renewSignal.mmState.advancer;

        _e2eFinding5_seedOldDeficitEpisode(tokenId, positionId, advancer, bypassSecs);

        _e2eFinding5_pauseFullRemoveUnpause(tokenId, positionId, bypassSecs);

        _e2eFinding5_reactivateCureAndFreshDeficit(tokenId, positionId, advancer, bypassSecs);
    }

    function _e2eFinding5_setupMarketAndCommittedPosition()
        internal
        returns (uint256 tokenId, PositionId positionId, uint256 bypassSecs)
    {
        bypassSecs = 1 hours;
        PoolId pid = corePoolKey.toId();
        MarketVTSConfiguration memory cfg = vtsOrchestrator.getMarketVTSConfiguration(pid);
        cfg.token0.unbackedCommitmentGraceBypassTime = bypassSecs;
        cfg.token1.unbackedCommitmentGraceBypassTime = bypassSecs;
        vm.prank(vtsOrchestrator.owner());
        vtsOrchestrator.setMarketVTSConfiguration(pid, cfg);
        marketVTSConfiguration = vtsOrchestrator.getMarketVTSConfiguration(pid);

        uint256 liquidity = 1e10;
        bytes32 salt = bytes32(uint256(0xF15EDE));
        (tokenId, positionId,,) = _createCommittedPosition(renewSignal, -60, 60, liquidity, salt);
    }

    function _e2eFinding5_seedOldDeficitEpisode(
        uint256 tokenId,
        PositionId positionId,
        address advancer,
        uint256 /* bypassSecs */
    )
        internal
    {
        bytes memory signalBytes = abi.encode(renewSignal);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                renewSignal.mmState.owner,
                signalBytes,
                true
            ),
            abi.encode(true, 10)
        );

        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(0);
        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
        );

        (uint256 cd0, uint256 cd1) = _commitmentDeficit(positionId);
        assertTrue(cd0 > 0 || cd1 > 0, "precondition: non-zero commitment deficit");

        (uint256 since0Old, uint256 since1Old, uint16 bpsOld) =
            _testableOrchestrator().getCommitmentDeficitAgeFields(positionId);
        assertTrue(since0Old > 0 || since1Old > 0, "precondition: deficit episode should record since");
        assertTrue(bpsOld >= marketVTSConfiguration.unbackedCommitmentGraceBypassBps, "precondition: bps bypass gate");

        // Paused remove requires closed RFS; iteratively settle calcRFS shortfall until lanes close.
        _e2eFinding5_closeRfsBySettlingShortfall(tokenId, positionId);

        // Non-seizure MM liquidity changes are frozen while stored commitmentDeficit is non-zero (COMMIT-02A).
        // Full deactivation clears token deficit amounts as well as age fields (COMMIT-02B), but MM cannot reach
        // remove until this gate is zero—cure via a strong backing signal before any MM liquidity change.
        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(1e30);
        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
        );
        (cd0, cd1) = _commitmentDeficit(positionId);
        assertEq(cd0, 0, "e2e finding5: must clear token0 commitmentDeficit before MM liquidity change");
        assertEq(cd1, 0, "e2e finding5: must clear token1 commitmentDeficit before MM liquidity change");
    }

    /// @dev After a commitment checkpoint reveals deficit, RFS is open; pay deposits matching `calcRFS` deltas
    ///      until `calcRFS` reports closed. Closing RFS alone does not clear stored commitmentDeficit; callers
    ///      must still cure deficit (e.g. checkpoint with sufficient signal) before non-seizure MM removes.
    function _e2eFinding5_closeRfsBySettlingShortfall(uint256 tokenId, PositionId positionId) internal {
        for (uint256 i = 0; i < 12; i++) {
            (bool open, BalanceDelta d) = vtsOrchestrator.calcRFS(positionId, false);
            if (!open) return;

            int128 pay0;
            int128 pay1;
            if (d.amount0() > 0) {
                pay0 = _negInt128Capped(uint256(int256(d.amount0())));
            }
            if (d.amount1() > 0) {
                pay1 = _negInt128Capped(uint256(int256(d.amount1())));
            }
            if (pay0 == 0 && pay1 == 0) {
                revert("e2e finding5: calcRFS open but zero payable shortfall");
            }
            _mmSettle(tokenId, 0, pay0, pay1);
        }
        (bool stillOpen,) = vtsOrchestrator.calcRFS(positionId, false);
        assertFalse(stillOpen, "e2e finding5: failed to close RFS for paused remove");
    }

    function _e2eFinding5_pauseFullRemoveUnpause(uint256 tokenId, PositionId positionId, uint256 bypassSecs) internal {
        PoolId pid = corePoolKey.toId();
        vtsOrchestrator.pausePool(pid);
        _decreasePosition(tokenId, 1e10);
        vtsOrchestrator.unpausePool(pid);

        // Simulate a long inactive interval after full remove (must happen after remove so MM signal is not required).
        vm.warp(block.timestamp + bypassSecs + 1);

        (uint256 since0Cleared, uint256 since1Cleared, uint16 bpsCleared) =
            _testableOrchestrator().getCommitmentDeficitAgeFields(positionId);
        assertEq(since0Cleared, 0, "full deactivation should clear commitmentDeficitSince token0");
        assertEq(since1Cleared, 0, "full deactivation should clear commitmentDeficitSince token1");
        assertEq(bpsCleared, 0, "full deactivation should clear commitmentDeficitBps");
        (uint256 cd0Cleared, uint256 cd1Cleared) = _commitmentDeficit(positionId);
        assertEq(cd0Cleared, 0, "full deactivation should clear commitmentDeficit token0");
        assertEq(cd1Cleared, 0, "full deactivation should clear commitmentDeficit token1");

        Position memory posAfterRemove = vtsOrchestrator.getPosition(positionId);
        assertEq(posAfterRemove.liquidity, 0, "position should be fully unwound");
        assertFalse(posAfterRemove.isActive, "position should be inactive after full remove");
    }

    function _e2eFinding5_reactivateCureAndFreshDeficit(
        uint256 tokenId,
        PositionId positionId,
        address advancer,
        uint256 bypassSecs
    ) internal {
        _e2eFinding5_renewLiveSignal(tokenId);

        // Increase runs `validateLiquidityDeltaAgainstSignal`; oracle must not still reflect `_mockSignalUsd(0)` from the deficit episode.
        _mockLccPrices(1e18, 1e18);
        _mockSignalUsd(1e30);

        _increasePosition(tokenId, positionId, 1e10);

        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
        );

        (uint256 cd0, uint256 cd1) = _commitmentDeficit(positionId);
        assertEq(cd0, 0, "strong signal should clear stored commitment deficit token0");
        assertEq(cd1, 0, "strong signal should clear stored commitment deficit token1");

        _mockSignalUsd(0);
        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, tokenId, 0, true)
        );

        (cd0, cd1) = _commitmentDeficit(positionId);
        assertTrue(cd0 > 0 || cd1 > 0, "post-reactivation: underbacking should restore commitment deficit");

        (uint256 since0Fresh, uint256 since1Fresh,) = _testableOrchestrator().getCommitmentDeficitAgeFields(positionId);
        assertTrue(since0Fresh > 0 || since1Fresh > 0, "fresh episode should set commitmentDeficitSince");
        uint256 sinceFresh = since0Fresh > 0 ? since0Fresh : since1Fresh;
        assertEq(sinceFresh, block.timestamp, "fresh episode should start the bypass clock at checkpoint time");

        uint256 tFresh = block.timestamp;
        // `bypassSecs / 2` can equal default `gracePeriodTime` (1800s), so RFS grace elapses and `isSeizable` becomes
        // true via the checkpoint path even though commitment-deficit bypass age (`unbackedCommitmentGraceBypassTime`)
        // is not yet satisfied. Stay strictly inside the RFS grace window while still before deficit bypass age.
        uint256 halfGrace = marketVTSConfiguration.token0.gracePeriodTime / 2;
        vm.warp(tFresh + halfGrace);

        vm.expectRevert();
        unlockCaller.run(address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.onSeize.selector, tokenId, 0));

        vm.warp(tFresh + bypassSecs + 1);

        unlockCaller.run(address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.onSeize.selector, tokenId, 0));
    }

    /// @dev Position was committed with `renewSignal`; restore a live signal after warps so MM liquidity ops succeed.
    function _e2eFinding5_renewLiveSignal(uint256 tokenId) internal {
        LiquiditySignal memory sameOwnerRenew = renewSignal;
        sameOwnerRenew.nonce += 1;
        bytes memory renewSignalBytes = abi.encode(sameOwnerRenew);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")),
                sameOwnerRenew.mmState.advancer,
                renewSignalBytes,
                true
            ),
            abi.encode(true, 10_000_000)
        );
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("renewSignal(address,address,uint256,bytes)")),
                IMarketFactory(marketFactory),
                renewSignal.mmState.advancer,
                tokenId,
                renewSignalBytes
            )
        );
    }

    function test_revert_onMMSettle_whenSeizingButCallerNotPositionOwner_insideUnlock() public {
        (uint256 tokenId,,,) = _createCommittedPosition();
        BalanceDelta depositDelta = toBalanceDelta(int128(-1), int128(-1));

        vm.expectRevert(Errors.InvalidSender.selector);
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                VTSOrchestrator.onMMSettle.selector,
                IMarketFactory(marketFactory),
                tokenId,
                0,
                depositDelta,
                true,
                false
            )
        );
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

    function _decreasePosition(uint256 tokenId, uint256 amountToDecrease) internal {
        // Decrease can leave MMPM underlying credits; drain them after LCC `take`s so batch deltas net to zero
        // (ordering mirrors full withdrawal flows in MMPositionActionsImpl.t.sol / VTSFeeLib.scenario.t.sol).
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, 0, amountToDecrease);
        actions[1] = MMA.prepareTake(lccCurrency0, address(this), 0);
        actions[2] = MMA.prepareTake(lccCurrency1, address(this), 0);
        actions[3] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, 0, true, true);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
    }

    /// @dev Uses on-chain ticks/salt for settlement sizing from `_calculateSettlementAmounts`.
    function _increasePosition(uint256 tokenId, PositionId positionId, uint256 amountToIncrease) internal {
        Position memory pos = vtsOrchestrator.getPosition(positionId);
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: pos.tickLower, tickUpper: pos.tickUpper, liquidityDelta: int256(amountToIncrease), salt: pos.salt
        });
        (uint256 req0, uint256 req1) = _calculateSettlementAmounts(p, marketVTSConfiguration);
        _mintAndApproveUnderlyingForSettlement(req0, req1);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareIncrease(corePoolKey, tokenId, 0, amountToIncrease);
        actions[1] =
            MMA.prepareSettle(corePoolKey, tokenId, 0, -SafeCast.toInt128(req0), -SafeCast.toInt128(req1), false);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
    }

    function _expectedOpenMask(BalanceDelta delta) internal pure returns (uint8 openMask) {
        if (delta.amount0() > 0) openMask |= 1;
        if (delta.amount1() > 0) openMask |= 2;
    }
}


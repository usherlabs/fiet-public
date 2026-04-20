// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";

import {E2EBase} from "./E2EBase.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Token} from "../../setup/MockERC20.s.sol";

import {LiquiditySignal} from "src/types/Commit.sol";
import {MarketMaker} from "src/libraries/MarketMaker.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {ILCC} from "src/interfaces/ILCC.sol";
import {MMPositionManager} from "src/MMPositionManager.sol";
import {IVTSOrchestrator} from "src/interfaces/IVTSOrchestrator.sol";
import {Position, PositionId} from "src/types/Position.sol";
import {LiquidityUtils} from "src/libraries/LiquidityUtils.sol";
import {MarketVTSConfiguration} from "src/types/VTS.sol";
import {ILiquidityHub} from "src/interfaces/ILiquidityHub.sol";
import {IVRLSignalManager} from "src/interfaces/IVRLSignalManager.sol";
import {MMActions} from "src/libraries/MMActions.sol";
import {Errors} from "src/libraries/Errors.sol";

abstract contract MME2EBase is E2EBase {
    using MarketMaker for MarketMaker.State;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    struct UnwrapSnapshot {
        uint256 liquid;
        uint256 queue;
        uint256 lcc;
        uint256 underlying;
    }

    struct PositionSeed {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    // ============================================================
    // MM matrix E2E: scenario kinds, position/buffer profiles, snapshots
    // ============================================================

    enum MME2EScenarioKind {
        ExtremeUnserviceableRemnant,
        ServiceableRoundTrip,
        ServiceableReserveShaped,
        ModestNonExtreme,
        WideOrDeepStress
    }

    /// @dev Optional bundle for future scenario runners (wrap/swap sizing × scenario kind).
    struct ScenarioProfileE2E {
        string name;
        uint256 wrapAmount;
        uint128 swapAmount;
        MME2EScenarioKind kind;
    }

    struct PositionProfileE2E {
        string name;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    struct BufferModeE2E {
        string name;
        bool seedDirectLP;
        uint256 wrapAmountPerAsset;
        uint256 amountMaxPerAsset;
    }

    struct ExitSnapshotE2E {
        uint256 positionIndex;
        uint256 eff0;
        uint256 eff1;
        uint256 overflow0;
        uint256 overflow1;
        uint256 inactiveRemnantCount;
    }

    struct MakerHealthSnapshotE2E {
        int24 tickCurrent;
        uint256 eff0;
        uint256 eff1;
        uint256 overflow0;
        uint256 overflow1;
        uint256 commitment0;
        uint256 commitment1;
        /// @dev False after burn or whenever `getCommitmentMaxima` cannot be queried (active-position-only lens).
        bool commitmentMaximaAvailable;
        uint256 poolTotalSettled0;
        uint256 poolTotalSettled1;
        uint256 poolTotalDeficitPrincipal0;
        uint256 poolTotalDeficitPrincipal1;
        uint256 inactiveRemnantCount;
    }

    /// @dev Matches the legacy `MarketMaker.s.sol` large-sweep trading phase.
    uint256 internal constant MM_E2E_WRAP_FOR_SWAPS_LARGE = 50_000e18;
    uint128 internal constant MM_E2E_BIG_SWAP_IN = 5_000e18;

    uint256 internal constant MM_E2E_WRAP_FOR_MODEST = 1_200e18;
    uint128 internal constant MM_E2E_MODEST_SWAP_IN = 10e18;

    /// @dev Gentler “reserve-shaped” cumulative swap size per leg (both directions) per round.
    uint128 internal constant MM_E2E_RESERVE_SHAPED_LEG_SWAP = 500e18;

    /// @dev Default DirectLP full-range buffer (aligned with `Swap.s.sol` seeding caps).
    uint256 internal constant MM_E2E_BUFFER_WRAP_PER_ASSET = 1_200e18;
    uint256 internal constant MM_E2E_BUFFER_AMOUNT_MAX_PER_ASSET = 1_000e18;

    /// @dev Reserve-replenishing swaps after an inactive drain stall (see Endogenous vs Exogenous Liquidity spec).
    uint256 internal constant MM_E2E_REBALANCE_WRAP_PER_LEG = 50_000e18;
    uint128 internal constant MM_E2E_REBALANCE_SWAP_CHUNK = 2_500e18;
    uint256 internal constant MM_E2E_REBALANCE_MAX_ROUNDS = 4;

    function _mmPositionProfilesAll() internal pure returns (PositionProfileE2E[] memory p) {
        p = new PositionProfileE2E[](4);
        p[0] = PositionProfileE2E({name: "tightTiny", tickLower: -60, tickUpper: 60, liquidity: 1e10});
        p[1] = PositionProfileE2E({name: "tightMaterial", tickLower: -60, tickUpper: 60, liquidity: 1e15});
        p[2] = PositionProfileE2E({name: "wideMaterial", tickLower: -600, tickUpper: 600, liquidity: 1e12});
        p[3] = PositionProfileE2E({name: "wideDeep", tickLower: -1200, tickUpper: 1200, liquidity: 1e15});
    }

    function _mmBufferModesAll() internal pure returns (BufferModeE2E[] memory b) {
        b = new BufferModeE2E[](2);
        b[0] =
            BufferModeE2E({name: "NoDirectLPBuffer", seedDirectLP: false, wrapAmountPerAsset: 0, amountMaxPerAsset: 0});
        b[1] = BufferModeE2E({
            name: "FullRangeDirectLPBuffer",
            seedDirectLP: true,
            wrapAmountPerAsset: MM_E2E_BUFFER_WRAP_PER_ASSET,
            amountMaxPerAsset: MM_E2E_BUFFER_AMOUNT_MAX_PER_ASSET
        });
    }

    function _createMmPositionFromProfile(StandaloneMarket memory m, uint256 mmPk, PositionProfileE2E memory profile)
        internal
        returns (uint256 commitId)
    {
        return _createMmPosition(m, mmPk, profile.tickLower, profile.tickUpper, profile.liquidity);
    }

    /// @dev Seeds exogenous full-range core liquidity when `buf.seedDirectLP` is enabled.
    function _seedDirectLPBufferIfEnabled(StandaloneMarket memory m, uint256 directLpPk, BufferModeE2E memory buf)
        internal
        returns (uint256 tokenId)
    {
        if (!buf.seedDirectLP) return 0;
        return _addCoreLiquidityFullRange(m, directLpPk, buf.wrapAmountPerAsset, buf.amountMaxPerAsset);
    }

    function _snapshotExitState(StandaloneMarket memory m, uint256 commitId, uint256 positionIndex)
        internal
        view
        returns (ExitSnapshotE2E memory s)
    {
        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);
        PositionId pid = vts.getPositionId(commitId, positionIndex);
        (s.eff0, s.eff1) = vts.getPositionSettledAmounts(pid);
        (s.overflow0, s.overflow1) = vts.getPositionSettledOverflowAmounts(pid);
        (,,,, s.inactiveRemnantCount) = vts.getCommit(commitId);
        s.positionIndex = positionIndex;
    }

    /// @notice Snapshots tick, per-position accounting, pool totals, and commitment maxima when the position is still active.
    /// @dev `IVTSOrchestrator.getCommitmentMaxima` is `onlyPositionValid(..., requireActive=true)`; after a full burn the
    ///      position is inactive so maxima are omitted (`commitmentMaximaAvailable == false`, commitment fields zero).
    function _snapshotMakerHealth(StandaloneMarket memory m, uint256 commitId, uint256 positionIndex)
        internal
        view
        returns (MakerHealthSnapshotE2E memory h)
    {
        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);
        PoolKey memory key = _corePoolKey(m);
        PoolId poolId = key.toId();
        (, h.tickCurrent,,) = IPoolManager(config.poolManager).getSlot0(poolId);
        PositionId pid = vts.getPositionId(commitId, positionIndex);
        (h.eff0, h.eff1) = vts.getPositionSettledAmounts(pid);
        (h.overflow0, h.overflow1) = vts.getPositionSettledOverflowAmounts(pid);
        Position memory pos = vts.getPosition(pid);
        if (pos.isActive) {
            (h.commitment0, h.commitment1) = vts.getCommitmentMaxima(pid);
            h.commitmentMaximaAvailable = true;
        } else {
            h.commitment0 = 0;
            h.commitment1 = 0;
            h.commitmentMaximaAvailable = false;
        }
        (h.poolTotalSettled0, h.poolTotalSettled1) = vts.getPoolTotalSettled(poolId);
        (h.poolTotalDeficitPrincipal0, h.poolTotalDeficitPrincipal1) = vts.getPoolTotalDeficitPrincipal(poolId);
        (,,,, h.inactiveRemnantCount) = vts.getCommit(commitId);
    }

    function _logMakerHealth(string memory label, MakerHealthSnapshotE2E memory h) internal view {
        console.log("--- Maker health:", label);
        console.log("tick:", int256(h.tickCurrent));
        console.log("eff0:", h.eff0);
        console.log("eff1:", h.eff1);
        console.log("overflow0:", h.overflow0);
        console.log("overflow1:", h.overflow1);
        if (h.commitmentMaximaAvailable) {
            console.log("commitment0:", h.commitment0);
            console.log("commitment1:", h.commitment1);
        } else {
            console.log("commitment0/1: n/a (inactive position; getCommitmentMaxima is active-only)");
        }
        console.log("poolTotalSettled0:", h.poolTotalSettled0);
        console.log("poolTotalSettled1:", h.poolTotalSettled1);
        console.log("poolDeficitPrincipal0:", h.poolTotalDeficitPrincipal0);
        console.log("poolDeficitPrincipal1:", h.poolTotalDeficitPrincipal1);
        console.log("inactiveRemnantCount:", h.inactiveRemnantCount);
    }

    function _makerHealthEffectiveSum(MakerHealthSnapshotE2E memory h) internal pure returns (uint256) {
        return h.eff0 + h.eff1;
    }

    function _makerHealthOverflowSum(MakerHealthSnapshotE2E memory h) internal pure returns (uint256) {
        return h.overflow0 + h.overflow1;
    }

    function _makerHealthDeficitSum(MakerHealthSnapshotE2E memory h) internal pure returns (uint256) {
        return h.poolTotalDeficitPrincipal0 + h.poolTotalDeficitPrincipal1;
    }

    function _mmProfileNameEq(PositionProfileE2E memory p, string memory nm) internal pure returns (bool) {
        return keccak256(bytes(p.name)) == keccak256(bytes(nm));
    }

    function _isTightTinyProfile(PositionProfileE2E memory p) internal pure returns (bool) {
        return p.tickLower == -60 && p.tickUpper == 60 && p.liquidity == 1e10;
    }

    function _assertMakerHealthNotWorseWithBuffer(
        MakerHealthSnapshotE2E memory buffered,
        MakerHealthSnapshotE2E memory unbuffered
    ) internal pure {
        uint256 b = _makerHealthEffectiveSum(buffered) + _makerHealthDeficitSum(buffered);
        uint256 u = _makerHealthEffectiveSum(unbuffered) + _makerHealthDeficitSum(unbuffered);
        // Matrix comparisons should be bounded, not brittle. When the baseline is effectively zero, tolerate
        // only dust-sized residuals from the buffered path while still rejecting material regressions.
        uint256 tolerance = (u / 50) + 1e13;
        require(b <= u + tolerance, "e2e: buffered run materially worse than unbuffered (effective+deficit)");
    }

    function _assertMakerHealthImprovedOrStable(
        MakerHealthSnapshotE2E memory after_,
        MakerHealthSnapshotE2E memory before_
    ) internal pure {
        uint256 a = _makerHealthEffectiveSum(after_);
        uint256 b = _makerHealthEffectiveSum(before_);
        require(a <= b + (b / 100) + 1, "e2e: maker health regressed beyond tolerance");
    }

    function _assertTickNotExtreme(StandaloneMarket memory m) internal view {
        PoolKey memory key = _corePoolKey(m);
        (, int24 tick,,) = IPoolManager(config.poolManager).getSlot0(key.toId());
        int24 lo = TickMath.MIN_TICK + 10_000;
        int24 hi = TickMath.MAX_TICK - 10_000;
        require(tick > lo && tick < hi, "e2e: tick unexpectedly pinned near boundary");
    }

    function _assertUnserviceableRemnantAfterBurn(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        uint256 positionIndex
    ) internal {
        ExitSnapshotE2E memory snap = _snapshotExitState(m, commitId, positionIndex);
        require(snap.eff0 > 0 || snap.eff1 > 0, "e2e: expected inactive economic remnant");
        bool progressed = _attemptInactiveDrainOnce(m, mmPk, commitId, positionIndex);
        require(!progressed, "e2e: expected inactive drain to stall immediately (unserviceable)");
        _assertCommitNotDrainedOnDecommit(m, mmPk, commitId);
    }

    function _assertDrainableAndFullyDrained(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        uint256 positionIndex,
        uint256 maxDrainIters
    ) internal {
        _drainInactivePositionSurplus(m, mmPk, commitId, positionIndex, maxDrainIters);
        (uint256 e0, uint256 e1) =
            _getEffectiveSettledPair(IVTSOrchestrator(m.stack.contracts.vtsOrchestrator), commitId, positionIndex);
        require(e0 == 0 && e1 == 0, "e2e: expected fully drained inactive surplus");
    }

    function _assertImprovedServiceabilityVsBaseline(
        MakerHealthSnapshotE2E memory candidate,
        MakerHealthSnapshotE2E memory baselineTightTiny
    ) internal pure {
        uint256 c = _makerHealthEffectiveSum(candidate);
        uint256 b = _makerHealthEffectiveSum(baselineTightTiny);
        // Bounded relational check: wider/deeper profiles should not exhibit materially worse stranded economics.
        require(c <= b + (b / 20) + 2, "e2e: wide/deep profile materially worse vs tightTiny baseline");
    }

    /// @notice After a burn, inactive economic attribution can remain non-zero while vault reserve clamps block withdrawal;
    ///         this is “unserviceable overflow” / inactive remnant (economic vs immediately serviceable).
    /// @dev Asserts overflow-bearing inactive state and that decommit is blocked until the remnant clears.
    function _assertRecognisedUnserviceableOverflowBeforeRebalance(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        uint256 positionIndex
    ) internal {
        ExitSnapshotE2E memory s = _snapshotExitState(m, commitId, positionIndex);
        require(s.eff0 > 0 || s.eff1 > 0, "e2e: stalled drain but zero inactive effective settled (unexpected)");
        require(s.overflow0 > 0 || s.overflow1 > 0, "e2e: stalled drain but zero inactive overflow (unexpected)");
        require(s.inactiveRemnantCount > 0, "e2e: stalled drain but zero inactive remnant count (unexpected)");

        _logMakerHealth(
            "recognised unserviceable overflow (pre-rebalance)", _snapshotMakerHealth(m, commitId, positionIndex)
        );

        _assertCommitNotDrainedOnDecommit(m, mmPk, commitId);
    }

    /// @dev Directional exact-input swaps: push currency0 or currency1 into the core pool to grow the matching
    ///      `marketLiquidityReserves` slice so a later `SETTLE_POSITION` withdrawal can clear inactive overflow.
    ///      See `agents/spec/Endogenous vs Exogenous Liquidity Considerations.md` (heal lane N by swapping N in).
    function _rebalanceStrandedLanesForInactiveDrain(
        StandaloneMarket memory m,
        uint256 takerPk,
        uint256 eff0,
        uint256 eff1,
        uint128 swapChunk,
        uint256 wrapAmount
    ) internal {
        uint128 antiPinChunk = swapChunk / 1000;
        if (antiPinChunk == 0) antiPinChunk = 1;

        if (eff0 > 0) {
            (, int24 tickCurrent,,) = IPoolManager(config.poolManager).getSlot0(_corePoolKey(m).toId());
            if (tickCurrent <= TickMath.MIN_TICK + 1) {
                console.log("e2e: anti-pin nudge - currency1 in before healing currency0 lane");
                _mintAndSwap(m, takerPk, wrapAmount, false, antiPinChunk);
            }
            console.log("e2e: reserve rebalance - currency0 in (zeroForOne=true), chunk:", swapChunk);
            _mintAndSwap(m, takerPk, wrapAmount, true, swapChunk);
        }
        if (eff1 > 0) {
            (, int24 tickCurrent,,) = IPoolManager(config.poolManager).getSlot0(_corePoolKey(m).toId());
            if (tickCurrent >= TickMath.MAX_TICK - 1) {
                console.log("e2e: anti-pin nudge - currency0 in before healing currency1 lane");
                _mintAndSwap(m, takerPk, wrapAmount, true, antiPinChunk);
            }
            console.log("e2e: reserve rebalance - currency1 in (zeroForOne=false), chunk:", swapChunk);
            _mintAndSwap(m, takerPk, wrapAmount, false, swapChunk);
        }
    }

    function _assertInactiveSurplusFullyResolvedForDecommit(
        StandaloneMarket memory m,
        uint256 commitId,
        uint256 positionIndex
    ) internal view {
        ExitSnapshotE2E memory s = _snapshotExitState(m, commitId, positionIndex);
        require(s.eff0 == 0 && s.eff1 == 0, "e2e: inactive effective settled must be zero before decommit");
        require(s.inactiveRemnantCount == 0, "e2e: inactive remnant must be cleared before decommit");
    }

    /// @dev Treat protocol-configured residual dust as acceptable after bounded rebalance, while still asserting
    ///      that the commit remains blocked until the remnant clears. This mirrors the MMCoverage harness semantics.
    function _classifyTerminalInactiveDustOrRevert(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        uint256 positionIndex
    ) internal {
        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);
        (uint256 eff0Left, uint256 eff1Left) = _getEffectiveSettledPair(vts, commitId, positionIndex);
        uint256 toleratedResidual = vts.getMarketVTSConfiguration(_corePoolKey(m).toId()).minResidualUnits;
        if (toleratedResidual == 0) toleratedResidual = 1;
        require(
            eff0Left + eff1Left <= toleratedResidual,
            "e2e: inactive surplus not cleared after reserve rebalance (lanes still unserviceable)"
        );
        _assertCommitNotDrainedOnDecommit(m, mmPk, commitId);
        console.log("OK: classified terminal dust remnant after bounded rebalance");
    }

    /// @dev Close RFS → burn + realise credits → drain inactive surplus; if stalled, assert unserviceable overflow,
    ///      perform bounded directional reserve replenishment swaps, re-drain, then decommit (unwrap separately).
    function _closeRfsBurnDrainRebalanceDecommitAndTakeAllLccs(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 rebalanceTakerPk,
        uint256 commitId,
        uint256 positionIndex,
        uint256 maxRebalanceRounds,
        uint128 rebalanceSwapChunk,
        uint256 rebalanceWrapAmount
    ) internal {
        require(positionIndex == 0, "e2e: helper is single-position only");
        _settleRfsIfOpen(m, mmPk, commitId);
        _burnAndRealiseExitCredits(m, mmPk, commitId, positionIndex);

        _logMakerHealth("after burn (pre-drain)", _snapshotMakerHealth(m, commitId, positionIndex));

        bool drained = _drainInactivePositionSurplusBestEffort(m, mmPk, commitId, positionIndex, 32);

        if (!drained) {
            _assertRecognisedUnserviceableOverflowBeforeRebalance(m, mmPk, commitId, positionIndex);

            for (uint256 r = 0; r < maxRebalanceRounds; r++) {
                (uint256 eff0, uint256 eff1) = _getEffectiveSettledPair(
                    IVTSOrchestrator(m.stack.contracts.vtsOrchestrator), commitId, positionIndex
                );
                if (eff0 == 0 && eff1 == 0) {
                    drained = true;
                    break;
                }

                console.log("e2e: reserve rebalance round:", r);
                _rebalanceStrandedLanesForInactiveDrain(
                    m, rebalanceTakerPk, eff0, eff1, rebalanceSwapChunk, rebalanceWrapAmount
                );

                _logMakerHealth(
                    "after reserve rebalance + pool trade", _snapshotMakerHealth(m, commitId, positionIndex)
                );

                drained = _drainInactivePositionSurplusBestEffort(m, mmPk, commitId, positionIndex, 32);
                if (drained) {
                    break;
                }
            }

            if (!drained) {
                _classifyTerminalInactiveDustOrRevert(m, mmPk, commitId, positionIndex);
                return;
            }
        }

        _assertInactiveSurplusFullyResolvedForDecommit(m, commitId, positionIndex);

        _logMakerHealth("after drain (pre-decommit)", _snapshotMakerHealth(m, commitId, positionIndex));

        _decommitAndTakeAllLccs(m, mmPk, commitId);
        console.log("OK: burned + drained inactive surplus (+ optional reserve rebalance) + decommitted");
    }

    /// @dev Single-position (`positionIndex == 0`) variant with default rebalance sizing.
    function _closeRfsBurnDrainRebalanceDecommitAndTakeAllLccs(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 rebalanceTakerPk,
        uint256 commitId
    ) internal {
        _closeRfsBurnDrainRebalanceDecommitAndTakeAllLccs(
            m,
            mmPk,
            rebalanceTakerPk,
            commitId,
            0,
            MM_E2E_REBALANCE_MAX_ROUNDS,
            MM_E2E_REBALANCE_SWAP_CHUNK,
            MM_E2E_REBALANCE_WRAP_PER_LEG
        );
    }

    function _assertUnwrapInvariant(
        uint256 lccSpent,
        uint256 underlyingDelta,
        uint256 queueBefore,
        uint256 queueAfter,
        uint256 liquidBalanceBefore
    ) internal pure returns (uint256 predictedAnnulledQueue) {
        uint256 transferableWithoutQueue = liquidBalanceBefore > queueBefore ? (liquidBalanceBefore - queueBefore) : 0;
        if (lccSpent > transferableWithoutQueue) {
            uint256 bleedIntoQueue = lccSpent - transferableWithoutQueue;
            predictedAnnulledQueue = bleedIntoQueue > queueBefore ? queueBefore : bleedIntoQueue;
        }

        require(
            underlyingDelta + queueAfter == lccSpent + queueBefore - predictedAnnulledQueue,
            "unwrap: redemption mismatch"
        );
    }

    function _runUnwrapAction(
        StandaloneMarket memory m,
        uint256 mmPk,
        address lcc,
        uint256 approveAmount,
        uint256 unwrapAmount
    ) internal {
        address mm = vm.addr(mmPk);
        vm.startBroadcast(mmPk);
        {
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));

            // UNWRAP_LCC(payerIsUser=true) pulls LCC from the MM via transferFrom.
            // Approve exactly what we currently hold.
            IERC20(lcc).approve(address(mmpm), approveAmount);

            bytes memory actions = abi.encodePacked(bytes1(uint8(MMActions.UNWRAP_LCC)));
            bytes[] memory params = new bytes[](1);
            params[0] = abi.encode(lcc, unwrapAmount, mm, true);
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();
    }

    /// @dev Best-effort queue collection for a specific LCC and commitment bucket.
    /// If reserve or custody cannot support settlement yet, this action is a no-op by design.
    function _collectAvailableLiquidity(
        StandaloneMarket memory m,
        uint256 mmPk,
        address lcc,
        uint256 tokenId,
        uint256 maxAmount
    ) internal {
        vm.startBroadcast(mmPk);
        {
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
            bytes memory actions = abi.encodePacked(bytes1(uint8(MMActions.COLLECT_AVAILABLE_LIQUIDITY)));
            bytes[] memory params = new bytes[](1);
            params[0] = abi.encode(lcc, tokenId, maxAmount);
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();
    }

    function _loadUnwrapSnapshot(ILiquidityHub hub, address lcc, address owner, address underlying)
        internal
        view
        returns (UnwrapSnapshot memory snap)
    {
        (uint256 wrappedBefore, uint256 marketDerivedBefore) = ILCC(lcc).balancesOf(owner);
        snap.liquid = wrappedBefore + marketDerivedBefore;
        snap.queue = hub.settleQueue(lcc, owner);
        snap.lcc = IERC20(lcc).balanceOf(owner);
        snap.underlying = IERC20(underlying).balanceOf(owner);
    }

    function _targetUnwrapAmount(uint256 requestedAmount, uint256 liquid, uint256 queued)
        internal
        pure
        returns (uint256)
    {
        uint256 unwrapHeadroom = liquid > queued ? (liquid - queued) : 0;
        if (requestedAmount == 0) return unwrapHeadroom;
        return requestedAmount > unwrapHeadroom ? unwrapHeadroom : requestedAmount;
    }

    function _executeMMActions(MMPositionManager mmpm, bytes memory actions, bytes[] memory params, uint256 deadline)
        internal
    {
        mmpm.modifyLiquidities(abi.encode(actions, params), deadline);
    }

    /// @dev Fee “poke”: no-op increase (0) to touch the position, then TAKE both pool currencies to wallet.
    function _pokePosition(StandaloneMarket memory m, uint256 mmPk, uint256 commitId)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        return _pokePosition(m, mmPk, commitId, true);
    }

    /// @dev Some scenarios intentionally touch inactive / out-of-range MM positions, so zero realised LCC change can be valid.
    function _pokePosition(StandaloneMarket memory m, uint256 mmPk, uint256 commitId, bool expectLccChange)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        address mm = vm.addr(mmPk);
        PoolKey memory corePoolKey = _corePoolKey(m);

        address lcc0 = Currency.unwrap(corePoolKey.currency0);
        address lcc1 = Currency.unwrap(corePoolKey.currency1);

        uint256 lcc0Before = IERC20(lcc0).balanceOf(mm);
        uint256 lcc1Before = IERC20(lcc1).balanceOf(mm);

        vm.startBroadcast(mmPk);
        {
            // IMPORTANT: The unlock batch must end with no residual deltas, so we TAKE both currencies after touching.
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
            bytes memory actions = abi.encodePacked(
                bytes1(uint8(MMActions.INCREASE_LIQUIDITY)),
                bytes1(uint8(MMActions.TAKE)),
                bytes1(uint8(MMActions.TAKE))
            );
            bytes[] memory params = new bytes[](3);
            params[0] = abi.encode(corePoolKey, commitId, 0, 0);
            params[1] = abi.encode(corePoolKey.currency0, mm, 0);
            params[2] = abi.encode(corePoolKey.currency1, mm, 0);
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();

        uint256 lcc0After = IERC20(lcc0).balanceOf(mm);
        uint256 lcc1After = IERC20(lcc1).balanceOf(mm);

        amount0 = lcc0After - lcc0Before;
        amount1 = lcc1After - lcc1Before;
        if (expectLccChange) require(amount0 > 0 || amount1 > 0, "poke: expected some LCC change");

        console.log("OK: position poked");
        console.log("fee lcc0 taken:", amount0);
        console.log("fee lcc1 taken:", amount1);
    }

    /// @dev CHECKPOINT a position via MMPositionManager. Pass non-empty `bytes` to run commitment backing (`withCommitment=true`).
    function _checkpointPosition(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        uint256 positionIndex,
        bytes memory liquiditySignal
    ) internal {
        vm.startBroadcast(mmPk);
        {
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
            mmpm.checkpoint(commitId, positionIndex, liquiditySignal.length > 0);
        }
        vm.stopBroadcast();
    }

    /// @dev Explicit checkpoint variant (avoids the non-empty-bytes sentinel).
    function _checkpointPosition(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        uint256 positionIndex,
        bool withCommitment
    ) internal {
        vm.startBroadcast(mmPk);
        {
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
            mmpm.checkpoint(commitId, positionIndex, withCommitment);
        }
        vm.stopBroadcast();
    }

    // --- Seizure E2E helpers (guarantor path; mirrors `contracts/evm/test/marketmaker/MMPositionActionsImpl.t.sol`) ---

    /// @dev Warp duration past RFS grace used in protocol tests (`_openSeizeWindow`).
    uint256 internal constant SEIZURE_GRACE_WARP = 300_000 + 1;

    /// @dev Default swap size to open RFS on a stressed MM position (exact-input on core pool).
    uint128 internal constant SEIZURE_SWAP_AMOUNT_IN = 1 ether;

    /// @dev Generous seizure settlement caps (orchestrator clamps to required settlement).
    uint256 internal constant SEIZURE_SETTLE_AMOUNT_MAX = 10_000 ether;

    /// @notice Deficit-causing swap + checkpoint + time warp so `onSeize` can succeed (per-position).
    function _openSeizeWindowForPosition(
        StandaloneMarket memory m,
        uint256 takerPk,
        uint256 mmPk,
        uint256 commitId,
        uint256 positionIndex,
        uint256 wrapForSwap
    ) internal {
        _mintAndSwap(m, takerPk, wrapForSwap, true, SEIZURE_SWAP_AMOUNT_IN);
        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);
        (, bool rfsOpen,) = vts.calcRFS(commitId, positionIndex, false);
        require(rfsOpen, "e2e seizure: expected RFS open after stress swap");
        _checkpointPosition(m, mmPk, commitId, positionIndex, false);
        vm.warp(block.timestamp + SEIZURE_GRACE_WARP);
    }

    /// @notice After a single swap, checkpoint multiple position indices then warp once (same RFS episode).
    function _openSeizeWindowForPositions(
        StandaloneMarket memory m,
        uint256 takerPk,
        uint256 mmPk,
        uint256 commitId,
        uint256[] memory positionIndices,
        uint256 wrapForSwap
    ) internal {
        _mintAndSwap(m, takerPk, wrapForSwap, true, SEIZURE_SWAP_AMOUNT_IN);
        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);
        for (uint256 i = 0; i < positionIndices.length; i++) {
            (, bool rfsOpen,) = vts.calcRFS(commitId, positionIndices[i], false);
            require(rfsOpen, "e2e seizure: expected RFS open for each position index after stress swap");
        }
        _checkpointPositionsBatch(m, mmPk, commitId, positionIndices, false);
        vm.warp(block.timestamp + SEIZURE_GRACE_WARP);
    }

    /// @dev Batch checkpoint for one commitment across multiple position indices.
    function _checkpointPositionsBatch(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        uint256[] memory positionIndices,
        bool withCommitment
    ) internal {
        vm.startBroadcast(mmPk);
        {
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
            uint256 actionCount = positionIndices.length;
            bytes memory actions = new bytes(actionCount);
            bytes[] memory params = new bytes[](actionCount);
            for (uint256 i = 0; i < actionCount; i++) {
                actions[i] = bytes1(uint8(MMActions.CHECKPOINT));
                params[i] = abi.encode(commitId, positionIndices[i], withCommitment);
            }
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();
    }

    /// @dev Mint an additional MM pool position on an existing commitment (`MINT_POSITION` + `SETTLE_POSITION`).
    function _mintAdditionalMmPosition(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liq
    ) internal {
        address mm = vm.addr(mmPk);
        MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
        PoolKey memory key = _corePoolKey(m);
        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);

        (,, uint256 positionCount,,) = vts.getCommit(commitId);
        uint256 newIndex = positionCount;

        (uint256 settle0, uint256 settle1) =
            _baseSettlementAmounts(m.stack.contracts.vtsOrchestrator, key, tickLower, tickUpper, liq);

        vm.startBroadcast(mmPk);
        Token(m.underlying0).mint(mm, settle0);
        Token(m.underlying1).mint(mm, settle1);
        _approveTokenForSpenderAndPermit2(m.underlying0, address(mmpm));
        _approveTokenForSpenderAndPermit2(m.underlying1, address(mmpm));

        bytes memory actions =
            abi.encodePacked(bytes1(uint8(MMActions.MINT_POSITION)), bytes1(uint8(MMActions.SETTLE_POSITION)));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, commitId, tickLower, tickUpper, uint256(liq));
        params[1] = abi.encode(key, commitId, newIndex, -int128(int256(settle0)), -int128(int256(settle1)), false);
        _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        vm.stopBroadcast();
    }

    /// @dev Commit + mint + settle many positions in one MM batch.
    function _createMmPositionBatch(StandaloneMarket memory m, uint256 mmPk, PositionSeed[] memory seeds)
        internal
        returns (uint256 commitId)
    {
        address mm = vm.addr(mmPk);
        uint256 lastVerified = IVRLSignalManager(m.stack.contracts.signalManager).mmNonce(mm);
        return _createMmPositionBatch(m, mmPk, seeds, lastVerified + 1);
    }

    /// @dev Commit + mint + settle many positions in one MM batch, with explicit signal nonce.
    function _createMmPositionBatch(
        StandaloneMarket memory m,
        uint256 mmPk,
        PositionSeed[] memory seeds,
        uint256 signalNonce
    ) internal returns (uint256 commitId) {
        require(seeds.length > 0, "mmpm: empty position seed set");
        address mm = vm.addr(mmPk);
        bytes memory liquiditySignalBytes = _buildSingleLeafLiquiditySignal(mmPk, signalNonce);
        MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
        commitId = mmpm.nextTokenId();
        _fundAndExecuteCreateMmPositionBatch(m, mmPk, commitId, liquiditySignalBytes, seeds);

        require(mmpm.ownerOf(commitId) == mm, "mmpm: owner mismatch");
    }

    function _fundAndExecuteCreateMmPositionBatch(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        bytes memory liquiditySignalBytes,
        PositionSeed[] memory seeds
    ) internal {
        MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
        PoolKey memory key = _corePoolKey(m);
        address mm = vm.addr(mmPk);
        (uint256[] memory settle0, uint256[] memory settle1, uint256 totalSettle0, uint256 totalSettle1) =
            _computeSeedSettlements(m.stack.contracts.vtsOrchestrator, key, seeds);

        vm.startBroadcast(mmPk);
        Token(m.underlying0).mint(mm, totalSettle0);
        Token(m.underlying1).mint(mm, totalSettle1);
        IERC20(m.underlying0).approve(address(mmpm), totalSettle0);
        IERC20(m.underlying1).approve(address(mmpm), totalSettle1);
        (bytes memory actions, bytes[] memory params) =
            _buildCreateMmBatch(key, commitId, liquiditySignalBytes, seeds, settle0, settle1);
        _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        vm.stopBroadcast();
    }

    function _computeSeedSettlements(address vtsOrchestrator, PoolKey memory key, PositionSeed[] memory seeds)
        internal
        view
        returns (uint256[] memory settle0, uint256[] memory settle1, uint256 totalSettle0, uint256 totalSettle1)
    {
        uint256 positionCount = seeds.length;
        settle0 = new uint256[](positionCount);
        settle1 = new uint256[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            (settle0[i], settle1[i]) = _baseSettlementAmounts(
                vtsOrchestrator, key, seeds[i].tickLower, seeds[i].tickUpper, seeds[i].liquidity
            );
            totalSettle0 += settle0[i];
            totalSettle1 += settle1[i];
        }
    }

    function _buildCreateMmBatch(
        PoolKey memory key,
        uint256 commitId,
        bytes memory liquiditySignalBytes,
        PositionSeed[] memory seeds,
        uint256[] memory settle0,
        uint256[] memory settle1
    ) internal pure returns (bytes memory actions, bytes[] memory params) {
        uint256 positionCount = seeds.length;
        uint256 actionCount = 1 + (positionCount * 2);
        actions = new bytes(actionCount);
        params = new bytes[](actionCount);
        actions[0] = bytes1(uint8(MMActions.COMMIT_SIGNAL));
        params[0] = abi.encode(liquiditySignalBytes, bytes(""));
        for (uint256 i = 0; i < positionCount; i++) {
            uint256 mintIdx = 1 + (2 * i);
            uint256 settleIdx = mintIdx + 1;
            actions[mintIdx] = bytes1(uint8(MMActions.MINT_POSITION));
            actions[settleIdx] = bytes1(uint8(MMActions.SETTLE_POSITION));
            params[mintIdx] =
                abi.encode(key, commitId, seeds[i].tickLower, seeds[i].tickUpper, uint256(seeds[i].liquidity));
            params[settleIdx] =
                abi.encode(key, commitId, i, -int128(int256(settle0[i])), -int128(int256(settle1[i])), false);
        }
    }

    /// @dev Guarantor batch: `SEIZE_POSITION` -> `SETTLE_FROM_DELTAS` -> `TAKE` x2 (clears v4 deltas per DELTA-01).
    function _guarantorSeizeSettleFromDeltasAndTake(
        StandaloneMarket memory m,
        uint256 guarantorPk,
        uint256 commitId,
        uint256 positionIndex,
        uint256 amount0,
        uint256 amount1
    ) internal {
        uint256[] memory positionIndices = new uint256[](1);
        uint256[] memory amount0Caps = new uint256[](1);
        uint256[] memory amount1Caps = new uint256[](1);
        positionIndices[0] = positionIndex;
        amount0Caps[0] = amount0;
        amount1Caps[0] = amount1;
        _guarantorSeizeManySettleFromDeltasAndTake(m, guarantorPk, commitId, positionIndices, amount0Caps, amount1Caps);
    }

    /// @dev Multi-position guarantor seize batch:
    ///      (SEIZE_POSITION -> SETTLE_POSITION_FROM_DELTAS) x N, then TAKE x2 once.
    function _guarantorSeizeManySettleFromDeltasAndTake(
        StandaloneMarket memory m,
        uint256 guarantorPk,
        uint256 commitId,
        uint256[] memory positionIndices,
        uint256[] memory amount0Caps,
        uint256[] memory amount1Caps
    ) internal {
        uint256 positionCount = positionIndices.length;
        require(positionCount > 0, "e2e seize: empty position set");
        require(
            positionCount == amount0Caps.length && positionCount == amount1Caps.length,
            "e2e seize: array length mismatch"
        );
        address guarantor = vm.addr(guarantorPk);
        PoolKey memory key = _corePoolKey(m);

        uint256 totalAmount0;
        uint256 totalAmount1;
        for (uint256 i = 0; i < positionCount; i++) {
            totalAmount0 += amount0Caps[i];
            totalAmount1 += amount1Caps[i];
        }

        vm.startBroadcast(guarantorPk);
        Token(m.underlying0).mint(guarantor, totalAmount0);
        Token(m.underlying1).mint(guarantor, totalAmount1);
        IERC20(m.underlying0).approve(address(m.stack.contracts.mmPositionManager), totalAmount0);
        IERC20(m.underlying1).approve(address(m.stack.contracts.mmPositionManager), totalAmount1);

        MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
        (bytes memory actions, bytes[] memory params) =
            _buildGuarantorMultiSeizeBatch(key, commitId, positionIndices, amount0Caps, amount1Caps, guarantor);
        _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        vm.stopBroadcast();
    }

    function _buildGuarantorMultiSeizeBatch(
        PoolKey memory key,
        uint256 commitId,
        uint256[] memory positionIndices,
        uint256[] memory amount0Caps,
        uint256[] memory amount1Caps,
        address guarantor
    ) internal pure returns (bytes memory actions, bytes[] memory params) {
        uint256 positionCount = positionIndices.length;
        uint256 actionCount = (positionCount * 2) + 2;
        actions = new bytes(actionCount);
        params = new bytes[](actionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            uint256 actionBase = 2 * i;
            actions[actionBase] = bytes1(uint8(MMActions.SEIZE_POSITION));
            actions[actionBase + 1] = bytes1(uint8(MMActions.SETTLE_POSITION_FROM_DELTAS));
            params[actionBase] =
                _encodeSeizePositionParams(key, commitId, positionIndices[i], amount0Caps[i], amount1Caps[i]);
            params[actionBase + 1] = _encodeSettleFromDeltasParams(key, commitId, positionIndices[i]);
        }
        actions[actionCount - 2] = bytes1(uint8(MMActions.TAKE));
        actions[actionCount - 1] = bytes1(uint8(MMActions.TAKE));
        params[actionCount - 2] = abi.encode(key.currency0, guarantor, 0);
        params[actionCount - 1] = abi.encode(key.currency1, guarantor, 0);
    }

    function _encodeSeizePositionParams(
        PoolKey memory key,
        uint256 commitId,
        uint256 positionIndex,
        uint256 amount0Cap,
        uint256 amount1Cap
    ) internal pure returns (bytes memory) {
        return abi.encode(key, commitId, positionIndex, amount0Cap, amount1Cap, false);
    }

    function _encodeSettleFromDeltasParams(PoolKey memory key, uint256 commitId, uint256 positionIndex)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(key, commitId, positionIndex, true, true);
    }

    /// @dev AUTH-01A regression: unapproved `SETTLE_POSITION` on the same commitment must revert `NotApproved` after a completed seize batch.
    function _assertNotApprovedOnGuarantorSettleAfterSeize(
        StandaloneMarket memory m,
        uint256 guarantorPk,
        uint256 commitId,
        uint256 positionIndex
    ) internal {
        address guarantor = vm.addr(guarantorPk);
        PoolKey memory key = _corePoolKey(m);
        MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));

        bytes memory actions = abi.encodePacked(bytes1(uint8(MMActions.SETTLE_POSITION)));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(key, commitId, positionIndex, -int128(1), -int128(1), false);
        // Keep this as a local assertion (no broadcast tx), otherwise replay simulation fails on the intentional revert.
        vm.prank(guarantor);
        try mmpm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600) {
            revert("e2e: expected NotApproved on post-seize settle");
        } catch (bytes memory err) {
            require(err.length >= 4, "e2e: empty revert");
            bytes4 sel;
            assembly {
                sel := mload(add(err, 32))
            }
            require(sel == Errors.NotApproved.selector, "e2e: expected NotApproved selector");
        }
    }

    /// @dev Script-local assertion for the blocked decommit path. Use try/catch instead of `expectRevert`
    ///      so forge-script simulations can keep running after the intentional revert.
    function _assertCommitNotDrainedOnDecommit(StandaloneMarket memory m, uint256 mmPk, uint256 commitId) internal {
        address mm = vm.addr(mmPk);
        PoolKey memory corePoolKey = _corePoolKey(m);
        MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));

        bytes memory actions = abi.encodePacked(
            bytes1(uint8(MMActions.DECOMMIT_SIGNAL)), bytes1(uint8(MMActions.TAKE)), bytes1(uint8(MMActions.TAKE))
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(commitId);
        params[1] = abi.encode(corePoolKey.currency0, mm, 0);
        params[2] = abi.encode(corePoolKey.currency1, mm, 0);

        vm.prank(mm);
        try mmpm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600) {
            revert("e2e: expected CommitNotDrained on decommit");
        } catch (bytes memory err) {
            require(err.length >= 36, "e2e: malformed CommitNotDrained revert");
            bytes4 sel;
            uint256 revertedCommitId;
            assembly {
                sel := mload(add(err, 32))
                revertedCommitId := mload(add(err, 36))
            }
            require(sel == Errors.CommitNotDrained.selector, "e2e: expected CommitNotDrained selector");
            require(revertedCommitId == commitId, "e2e: CommitNotDrained commitId mismatch");
        }
    }

    /// @dev Optionally fund+wrap for a taker, then execute a single exact-input swap.
    /// If `wrapAmount == 0`, funding/wrapping is skipped and only the swap is executed.
    /// @return amountOut Amount of tokenOut received from the swap
    function _mintAndSwap(
        StandaloneMarket memory m,
        uint256 takerPk,
        uint256 wrapAmount,
        bool zeroForOne,
        uint128 swapAmount
    ) internal returns (uint256 amountOut) {
        _logTick("tick (before swap)", _corePoolKey(m));
        address taker = vm.addr(takerPk);

        // Fund taker and wrap underlying -> LCC so taker can trade core pool currencies.
        if (wrapAmount > 0) {
            // IMPORTANT: `zeroForOne` is defined relative to the *sorted pool currencies* (currency0/currency1),
            // not `m.underlying0/m.underlying1`. To ensure we fund the correct input token, derive the input LCC
            // from the PoolKey and then wrap its underlying.
            PoolKey memory key = _corePoolKey(m);
            address tokenIn = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);

            vm.startBroadcast(takerPk);
            address underlying = ILCC(tokenIn).underlying();
            Token(underlying).mint(taker, wrapAmount);
            _wrapAndMintLcc(ILiquidityHub(m.stack.contracts.liquidityHub), m.marketId, underlying, taker, wrapAmount);
            vm.stopBroadcast();
        }

        (,,, amountOut) = _swapExactInputSingle(m, takerPk, zeroForOne, swapAmount, 0);
        console.log("OK: swap complete");
        console.log("zeroForOne:", zeroForOne);
        console.log("amountIn:", swapAmount);
        console.log("amountOut:", amountOut);
        _logTick("tick (after swap)", _corePoolKey(m));
    }

    /// @dev Fund a taker with underlying, wrap -> LCC, then swap in both directions.
    /// @return amountOut0 Amount of token0 received from the 1 -> 0 swap
    /// @return amountOut1 Amount of token1 received from the 0 -> 1 swap
    function _swapBothDirections(StandaloneMarket memory m, uint256 takerPk, uint256 wrapAmount, uint128 swapAmount)
        internal
        returns (uint256 amountOut0, uint256 amountOut1)
    {
        // One swap in each direction. Fund+wrap both currencies once for symmetric inputs.
        if (wrapAmount > 0) {
            address taker = vm.addr(takerPk);
            ILiquidityHub hub = ILiquidityHub(m.stack.contracts.liquidityHub);
            vm.startBroadcast(takerPk);
            Token(m.underlying0).mint(taker, wrapAmount);
            Token(m.underlying1).mint(taker, wrapAmount);
            _wrapAndMintLccPair(hub, m, taker, wrapAmount);
            vm.stopBroadcast();
        }

        amountOut1 = _mintAndSwap(m, takerPk, 0, true, swapAmount); // 0 -> 1
        amountOut0 = _mintAndSwap(m, takerPk, 0, false, swapAmount); // 1 -> 0
        console.log("OK: swap both directions complete");
    }

    /// @dev Large two-way sweep + poke (legacy extreme path).
    function _runExtremeTradingPhase(StandaloneMarket memory m, uint256 mmPk, uint256 takerPk, uint256 commitId)
        internal
    {
        _swapBothDirections(m, takerPk, MM_E2E_WRAP_FOR_SWAPS_LARGE, MM_E2E_BIG_SWAP_IN);
        _pokePosition(m, mmPk, commitId);
    }

    /// @dev Adaptive return toward the starting tick after an extreme sweep, then poke.
    function _runAdaptiveRoundTripTradingPhase(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 takerPk,
        uint256 commitId,
        uint128 bigSwapAmount,
        uint128 adaptiveStep,
        uint256 maxAdaptiveIters
    ) internal {
        PoolKey memory key = _corePoolKey(m);
        (, int24 tickStart,,) = IPoolManager(config.poolManager).getSlot0(key.toId());
        _swapBothDirections(m, takerPk, MM_E2E_WRAP_FOR_SWAPS_LARGE, bigSwapAmount);

        uint256 i;
        for (; i < maxAdaptiveIters; i++) {
            (, int24 tickCur,,) = IPoolManager(config.poolManager).getSlot0(key.toId());
            int256 diff = int256(tickCur) - int256(tickStart);
            if (diff < 120 && diff > -120) break;
            if (diff > 0) {
                _mintAndSwap(m, takerPk, MM_E2E_WRAP_FOR_SWAPS_LARGE, true, adaptiveStep);
            } else {
                _mintAndSwap(m, takerPk, MM_E2E_WRAP_FOR_SWAPS_LARGE, false, adaptiveStep);
            }
        }
        _pokePosition(m, mmPk, commitId, false);
    }

    /// @dev Small two-way swaps (non-extreme trading volume).
    function _runModestTradingPhase(StandaloneMarket memory m, uint256 mmPk, uint256 takerPk, uint256 commitId)
        internal
    {
        _swapBothDirections(m, takerPk, MM_E2E_WRAP_FOR_MODEST, MM_E2E_MODEST_SWAP_IN);
        _pokePosition(m, mmPk, commitId, false);
    }

    /// @dev Several modest rounds without a single extreme sweep (reserve-shaped / non-pathological trading).
    function _runReserveShapedTradingAndExitSetup(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 takerPk,
        uint256 commitId
    ) internal {
        for (uint256 r = 0; r < 3; r++) {
            _swapBothDirections(m, takerPk, MM_E2E_WRAP_FOR_SWAPS_LARGE, MM_E2E_RESERVE_SHAPED_LEG_SWAP);
        }
        _pokePosition(m, mmPk, commitId, false);
    }

    /// @dev Wide/deeper MM stress: large swaps on profiles that are not ultra-tight.
    function _runWideOrDeepStressTradingPhase(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 takerPk,
        uint256 commitId
    ) internal {
        _swapBothDirections(m, takerPk, MM_E2E_WRAP_FOR_SWAPS_LARGE, MM_E2E_BIG_SWAP_IN);
        _pokePosition(m, mmPk, commitId, false);
    }

    /// @dev Settle a position to a given amount of underlying0 and underlying1
    function _settleToPosition(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        int128 amount0,
        int128 amount1
    ) internal {
        require(amount0 > 0 && amount1 > 0, "settleToPosition: amounts must be > 0");
        address mm = vm.addr(mmPk);
        MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));

        vm.startBroadcast(mmPk);
        // Ensure MM has enough underlying to settle.
        Token(m.underlying0).mint(mm, uint256(uint128(amount0)));
        Token(m.underlying1).mint(mm, uint256(uint128(amount1)));
        IERC20(m.underlying0).approve(address(mmpm), uint256(uint128(amount0)));
        IERC20(m.underlying1).approve(address(mmpm), uint256(uint128(amount1)));

        PoolKey memory key = _corePoolKey(m);
        bytes memory actions = abi.encodePacked(bytes1(uint8(MMActions.SETTLE_POSITION)));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(key, commitId, 0, -amount0, -amount1, false);
        _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        vm.stopBroadcast();
    }

    /// @dev Log the tick of a pool
    function _logTick(string memory label, PoolKey memory key) internal view {
        (, int24 tick,,) = IPoolManager(config.poolManager).getSlot0(key.toId());
        console.log(label, tick);
    }

    function _baseSettlementAmounts(
        address vtsOrchestratorAddr,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liq
    ) internal view returns (uint256 settle0, uint256 settle1) {
        IVTSOrchestrator vts = IVTSOrchestrator(vtsOrchestratorAddr);
        MarketVTSConfiguration memory vtsCfg = vts.getMarketVTSConfiguration(key.toId());
        (uint256 c0, uint256 c1) = LiquidityUtils.calculateCommitmentMaxima(tickLower, tickUpper, liq);
        (settle0, settle1) =
            LiquidityUtils.getBaseSettlementAmounts(c0, c1, vtsCfg.token0.baseVTSRate, vtsCfg.token1.baseVTSRate);
    }

    function _executeCreatePositionBatch(
        MMPositionManager mmpm,
        PoolKey memory key,
        uint256 commitId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liq,
        bytes memory liquiditySignalBytes,
        uint256 settle0,
        uint256 settle1
    ) internal {
        bytes memory actions = abi.encodePacked(
            bytes1(uint8(MMActions.COMMIT_SIGNAL)),
            bytes1(uint8(MMActions.MINT_POSITION)),
            bytes1(uint8(MMActions.SETTLE_POSITION))
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(liquiditySignalBytes, bytes(""));
        params[1] = abi.encode(key, commitId, tickLower, tickUpper, liq);
        params[2] = abi.encode(key, commitId, 0, -int128(int256(settle0)), -int128(int256(settle1)), false);
        _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
    }

    /// @dev Create a new position for a market maker
    function _createMmPosition(StandaloneMarket memory m, uint256 mmPk, int24 tickLower, int24 tickUpper, uint128 liq)
        internal
        returns (uint256 commitId)
    {
        address mm = vm.addr(mmPk);
        uint256 lastVerified = IVRLSignalManager(m.stack.contracts.signalManager).mmNonce(mm);
        return _createMmPosition(m, mmPk, tickLower, tickUpper, liq, lastVerified + 1);
    }

    /// @dev Create a new position for a market maker with an explicit VRL signal nonce.
    function _createMmPosition(
        StandaloneMarket memory m,
        uint256 mmPk,
        int24 tickLower,
        int24 tickUpper,
        uint128 liq,
        uint256 signalNonce
    ) internal returns (uint256 commitId) {
        address mm = vm.addr(mmPk);

        MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
        PoolKey memory key = _corePoolKey(m);

        bytes memory liquiditySignalBytes = _buildSingleLeafLiquiditySignal(mmPk, signalNonce);
        (uint256 settle0, uint256 settle1) =
            _baseSettlementAmounts(m.stack.contracts.vtsOrchestrator, key, tickLower, tickUpper, liq);

        commitId = mmpm.nextTokenId();

        vm.startBroadcast(mmPk);
        Token(m.underlying0).mint(mm, settle0);
        Token(m.underlying1).mint(mm, settle1);
        IERC20(m.underlying0).approve(address(mmpm), settle0);
        IERC20(m.underlying1).approve(address(mmpm), settle1);

        _executeCreatePositionBatch(
            mmpm, key, commitId, tickLower, tickUpper, liq, liquiditySignalBytes, settle0, settle1
        );
        vm.stopBroadcast();

        require(mmpm.ownerOf(commitId) == mm, "mmpm: owner mismatch");
    }

    /// @dev Close RFS (so burn can succeed), then burn → realise delta credits → drain inactive economic remnant → decommit → TAKE.
    function _closeRfsBurnDecommitAndTakeAllLccs(StandaloneMarket memory m, uint256 mmPk, uint256 commitId) internal {
        _settleRfsIfOpen(m, mmPk, commitId);
        _burnDecommitAndTakeAllLccs(m, mmPk, commitId);
    }

    /// @dev Settle the RFS if it is open
    function _settleRfsIfOpen(StandaloneMarket memory m, uint256 mmPk, uint256 commitId) internal {
        address mm = vm.addr(mmPk);
        PoolKey memory corePoolKey = _corePoolKey(m);

        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);
        (, bool rfsOpen, BalanceDelta rfsDelta) = vts.calcRFS(commitId, 0, false);
        int128 d0 = rfsDelta.amount0();
        int128 d1 = rfsDelta.amount1();

        if (!rfsOpen) {
            vts.calcRFS(commitId, 0, true);
            return;
        }

        // If delta > 0, settlement is required; we deposit with negative amounts.
        int128 settle0 = d0 > 0 ? -type(int128).max : int128(0);
        int128 settle1 = d1 > 0 ? -type(int128).max : int128(0);

        vm.startBroadcast(mmPk);
        {
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));

            if (d0 > 0) {
                _mintAndApproveForSpenderAndPermit2(
                    ILCC(Currency.unwrap(corePoolKey.currency0)).underlying(),
                    mm,
                    address(mmpm),
                    uint256(int256(type(int128).max))
                );
            }
            if (d1 > 0) {
                _mintAndApproveForSpenderAndPermit2(
                    ILCC(Currency.unwrap(corePoolKey.currency1)).underlying(),
                    mm,
                    address(mmpm),
                    uint256(int256(type(int128).max))
                );
            }

            bytes memory actions = abi.encodePacked(bytes1(uint8(MMActions.SETTLE_POSITION)));
            bytes[] memory params = new bytes[](1);
            params[0] = abi.encode(corePoolKey, commitId, 0, settle0, settle1, false);
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();

        vts.calcRFS(commitId, 0, true);
    }

    /// @dev Clamp a uint withdraw request to positive int128 for SETTLE_POSITION (positive lane = withdrawal).
    function _withdrawRequestInt128(uint256 amountWei) internal pure returns (int128) {
        if (amountWei == 0) return int128(0);
        uint256 cap = uint256(uint128(type(int128).max));
        uint256 clipped = amountWei > cap ? cap : amountWei;
        return SafeCast.toInt128(int256(uint256(clipped)));
    }

    /// @return eff0 token0 effective settled (live + overflow)
    /// @return eff1 token1 effective settled (live + overflow)
    function _getEffectiveSettledPair(IVTSOrchestrator vts, uint256 commitId, uint256 positionIndex)
        internal
        view
        returns (uint256 eff0, uint256 eff1)
    {
        PositionId pid = vts.getPositionId(commitId, positionIndex);
        return vts.getPositionSettledAmounts(pid);
    }

    /// @dev Burn inactive liquidity, settle from hook deltas, and sweep credited LCC balances to the MM wallet.
    function _burnAndRealiseExitCredits(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        uint256 positionIndex
    ) internal {
        address mm = vm.addr(mmPk);
        PoolKey memory corePoolKey = _corePoolKey(m);

        vm.startBroadcast(mmPk);
        {
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
            bytes memory actions = abi.encodePacked(
                bytes1(uint8(MMActions.BURN_POSITION)),
                bytes1(uint8(MMActions.SETTLE_POSITION_FROM_DELTAS)),
                bytes1(uint8(MMActions.TAKE)),
                bytes1(uint8(MMActions.TAKE))
            );
            bytes[] memory params = new bytes[](4);
            params[0] = abi.encode(corePoolKey, commitId, positionIndex, uint128(0), uint128(0));
            params[1] = abi.encode(corePoolKey, commitId, positionIndex, true, true);
            params[2] = abi.encode(corePoolKey.currency0, mm, 0);
            params[3] = abi.encode(corePoolKey.currency1, mm, 0);
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();
    }

    /// @dev One inactive SETTLE attempt; returns whether effective settled strictly decreased.
    function _attemptInactiveDrainOnce(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        uint256 positionIndex
    ) internal returns (bool progressed) {
        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);
        PoolKey memory corePoolKey = _corePoolKey(m);

        (uint256 eff0Before, uint256 eff1Before) = _getEffectiveSettledPair(vts, commitId, positionIndex);
        if (eff0Before == 0 && eff1Before == 0) {
            return false;
        }

        console.log("e2e: inactive surplus before drain, eff0:", eff0Before, "eff1:", eff1Before);

        vm.startBroadcast(mmPk);
        {
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
            bytes memory actions = abi.encodePacked(bytes1(uint8(MMActions.SETTLE_POSITION)));
            bytes[] memory params = new bytes[](1);
            params[0] = abi.encode(
                corePoolKey,
                commitId,
                positionIndex,
                _withdrawRequestInt128(eff0Before),
                _withdrawRequestInt128(eff1Before),
                false
            );
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();

        (uint256 eff0After, uint256 eff1After) = _getEffectiveSettledPair(vts, commitId, positionIndex);
        progressed = eff0After < eff0Before || eff1After < eff1Before;
    }

    /// @notice After burn, repeatedly SETTLE (withdraw) until inactive effective settled is zero, or revert if progress stalls.
    /// @dev Burn can leave surplus in `settledOverflow` that `SETTLE_POSITION_FROM_DELTAS` alone does not clear; decommit requires no inactive remnant.
    function _drainInactivePositionSurplus(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        uint256 positionIndex,
        uint256 maxIterations
    ) internal {
        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);

        uint256 cap = maxIterations == 0 ? 32 : maxIterations;

        for (uint256 i = 0; i < cap; i++) {
            (uint256 eff0Before, uint256 eff1Before) = _getEffectiveSettledPair(vts, commitId, positionIndex);
            if (eff0Before == 0 && eff1Before == 0) {
                return;
            }

            bool progressed = _attemptInactiveDrainOnce(m, mmPk, commitId, positionIndex);
            if (!progressed) {
                revert("e2e: inactive surplus settle made no progress (check vault liquidity / queue)");
            }
        }

        (uint256 left0, uint256 left1) = _getEffectiveSettledPair(vts, commitId, positionIndex);
        require(left0 == 0 && left1 == 0, "e2e: inactive economic remnant remains after max drain iterations");
    }

    /// @dev Best-effort drain loop that stops when progress stalls (does not revert on stall).
    function _drainInactivePositionSurplusBestEffort(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        uint256 positionIndex,
        uint256 maxIterations
    ) internal returns (bool fullyDrained) {
        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);
        uint256 cap = maxIterations == 0 ? 32 : maxIterations;
        for (uint256 i = 0; i < cap; i++) {
            (uint256 e0, uint256 e1) = _getEffectiveSettledPair(vts, commitId, positionIndex);
            if (e0 == 0 && e1 == 0) {
                return true;
            }
            if (!_attemptInactiveDrainOnce(m, mmPk, commitId, positionIndex)) {
                break;
            }
        }
        (uint256 e0f, uint256 e1f) = _getEffectiveSettledPair(vts, commitId, positionIndex);
        fullyDrained = e0f == 0 && e1f == 0;
    }

    /// @dev Decommit the signal and sweep any remaining LCC credits for both pool currencies.
    function _decommitAndTakeAllLccs(StandaloneMarket memory m, uint256 mmPk, uint256 commitId) internal {
        address mm = vm.addr(mmPk);
        PoolKey memory corePoolKey = _corePoolKey(m);

        vm.startBroadcast(mmPk);
        {
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
            bytes memory actions = abi.encodePacked(
                bytes1(uint8(MMActions.DECOMMIT_SIGNAL)), bytes1(uint8(MMActions.TAKE)), bytes1(uint8(MMActions.TAKE))
            );
            bytes[] memory params = new bytes[](3);
            params[0] = abi.encode(commitId);
            params[1] = abi.encode(corePoolKey.currency0, mm, 0);
            params[2] = abi.encode(corePoolKey.currency1, mm, 0);
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();
    }

    /// @dev Burn, settle-from-deltas, drain inactive surplus on index `positionIndex`, decommit, and sweep LCC credits.
    function _burnDecommitAndTakeAllLccs(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        uint256 positionIndex
    ) internal {
        require(positionIndex == 0, "e2e: helper is single-position only");
        _burnAndRealiseExitCredits(m, mmPk, commitId, positionIndex);
        _drainInactivePositionSurplus(m, mmPk, commitId, positionIndex, 32);
        _decommitAndTakeAllLccs(m, mmPk, commitId);
        console.log("OK: burned + withdrew-from-deltas + drained inactive surplus + decommitted");
    }

    /// @dev Same as `_burnDecommitAndTakeAllLccs(m, mmPk, commitId, 0)` for single-position E2E.
    function _burnDecommitAndTakeAllLccs(StandaloneMarket memory m, uint256 mmPk, uint256 commitId) internal {
        _burnDecommitAndTakeAllLccs(m, mmPk, commitId, 0);
    }

    /// @dev Backwards-compatible helper for callsites that do not provide a commitment bucket.
    function _unwrapLcc(StandaloneMarket memory m, address lcc, uint256 mmPk, uint256 unwrapAmount, bool assertBalance)
        internal
        returns (uint256 underlyingDelta)
    {
        return _unwrapLcc(m, lcc, mmPk, unwrapAmount, assertBalance, 0);
    }

    /// @dev Unwraps LCC balances held by `mmPk` back to underlying tokens.
    /// `unwrapAmount == 0` unwraps the maximum currently allowed by Hub headroom.
    function _unwrapLcc(
        StandaloneMarket memory m,
        address lcc,
        uint256 mmPk,
        uint256 unwrapAmount,
        bool assertBalance,
        uint256 commitId
    ) internal returns (uint256 underlyingDelta) {
        address owner = vm.addr(mmPk);
        ILiquidityHub hub = ILiquidityHub(m.stack.contracts.liquidityHub);
        address underlying = ILCC(lcc).underlying();

        // Try to consume any queue that can already be settled from custody/reserves.
        if (hub.settleQueue(lcc, owner) > 0) {
            _collectAvailableLiquidity(m, mmPk, lcc, commitId, type(uint256).max);
        }

        UnwrapSnapshot memory before = _loadUnwrapSnapshot(hub, lcc, owner, underlying);
        uint256 targetUnwrapAmount = _targetUnwrapAmount(unwrapAmount, before.liquid, before.queue);
        if (targetUnwrapAmount == 0) {
            console.log("skip unwrap: no available headroom");
            console.log("unwrap queue before:", before.queue);
            return 0;
        }

        _runUnwrapAction(m, mmPk, lcc, before.lcc, targetUnwrapAmount);

        UnwrapSnapshot memory afterState = _loadUnwrapSnapshot(hub, lcc, owner, underlying);

        uint256 lccSpent = before.lcc - afterState.lcc;
        underlyingDelta = afterState.underlying - before.underlying;

        console.log("unwrap spent lcc:", lccSpent);
        console.log("unwrap underlying received:", underlyingDelta);
        console.log("unwrap queue after:", afterState.queue);

        // Stronger invariant predicated on existing state (queue may already exist).
        if (assertBalance) {
            uint256 predictedAnnulledQueue =
                _assertUnwrapInvariant(lccSpent, underlyingDelta, before.queue, afterState.queue, before.liquid);
            console.log("unwrap queue before:", before.queue);
            console.log("unwrap predicted queue annulled:", predictedAnnulledQueue);
        }
    }

    /// @dev Unwraps LCC balances held by `mmPk` back to underlying tokens.
    /// `unwrapAmount == 0` unwraps the maximum currently allowed by Hub headroom.
    function _unwrapAllLccsAndAssert(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        uint256 unwrapAmount,
        bool assertBalance
    ) internal returns (uint256 underlying0Delta, uint256 underlying1Delta) {
        PoolKey memory corePoolKey = _corePoolKey(m);

        address lcc0 = Currency.unwrap(corePoolKey.currency0);
        address lcc1 = Currency.unwrap(corePoolKey.currency1);

        underlying0Delta = _unwrapLcc(m, lcc0, mmPk, unwrapAmount, assertBalance, commitId);
        underlying1Delta = _unwrapLcc(m, lcc1, mmPk, unwrapAmount, assertBalance, commitId);
    }

    // ============================================================
    // Signal utilities (MM-specific)
    // ============================================================

    function _packSig(uint8 v, bytes32 r, bytes32 s) internal pure returns (bytes memory) {
        return abi.encodePacked(r, s, v);
    }

    /// @dev Signs an Ethereum message with a private key
    function _signEthMessage(uint256 pk, bytes32 messageHash) internal pure returns (bytes memory sig) {
        bytes32 ethSigned = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSigned);
        sig = _packSig(v, r, s);
    }

    /// @dev Rounds down to nearest multiple of `tickSpacing` (handles negative ticks).
    function _floorTick(int24 tick, int24 tickSpacing) internal pure returns (int24 rounded) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && (tick % tickSpacing) != 0) compressed -= 1;
        rounded = compressed * tickSpacing;
    }

    /// @dev Builds a single-leaf LiquiditySignal (MMPositionManager commit path).
    function _buildSingleLeafLiquiditySignal(uint256 mmPk, uint256 nonce)
        internal
        view
        returns (bytes memory signalBytes)
    {
        address mm = vm.addr(mmPk);

        MarketMaker.State memory st;
        st.owner = mm;
        st.sourceState = "e2e.sourceState";
        st.prover = "e2e.prover";
        st.nonce = "e2e.nonce";
        // MMPositionManager forwards locker as hook-data sender on MM ops;
        // keep advancer aligned with the E2E MM actor to satisfy sender guards.
        st.advancer = mm;
        st.expiryAt = block.timestamp + 1 days;
        st.reserves = new MarketMaker.Reserve[](2);
        st.reserves[0] = MarketMaker.Reserve({asset: "BTC", amount: 1e20});
        st.reserves[1] = MarketMaker.Reserve({asset: "USDT", amount: 5e18});

        bytes32 leafHash = st.toLeafHash();
        bytes32 rootHash = leafHash;

        // MM authorizes the signal by signing the leafHash (verifier checks recovered == mmState.owner).
        bytes memory mmSig = _signEthMessage(mmPk, leafHash);

        // Canister (in E2E: deployer EOA) signs (nonce, rootHash).
        bytes32 rootMsg = keccak256(abi.encodePacked(nonce, rootHash));
        bytes memory rootSig = _signEthMessage(_getDeployerPrivateKey(), rootMsg);

        bytes32[] memory proof = new bytes32[](0);
        LiquiditySignal memory sig = LiquiditySignal({
            nonce: nonce,
            rootHash: rootHash,
            rootHashSignature: rootSig,
            merkleProof: proof,
            mmState: st,
            mmSignature: mmSig
        });

        signalBytes = abi.encode(sig);
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSLibTestBase} from "../base/VTSLibTestBase.sol";
import {VTSCommitLibHarness} from "./harnesses/VTSCommitLibHarness.sol";

import {VTSCommitLib} from "../../src/libraries/VTSCommitLib.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {IOracleHelper} from "../../src/interfaces/IOracleHelper.sol";
import {IVRLSignalManager} from "../../src/interfaces/IVRLSignalManager.sol";
import {LiquiditySignal} from "../../src/types/Commit.sol";
import {MarketMaker} from "../../src/libraries/MarketMaker.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionId} from "../../src/types/Position.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";

contract MockOracleHelper is IOracleHelper {
    uint256 internal _price0 = 1e18;
    uint256 internal _price1 = 1e18;
    uint256 internal _totalValue;
    address internal _expectedLcc0;
    address internal _expectedLcc1;
    bool internal _enforcePair;

    function setPrices(uint256 p0, uint256 p1) external {
        _price0 = p0;
        _price1 = p1;
    }

    function setTotalValue(uint256 v) external {
        _totalValue = v;
    }

    function setExpectedLccPair(address lcc0, address lcc1, bool enforce) external {
        _expectedLcc0 = lcc0;
        _expectedLcc1 = lcc1;
        _enforcePair = enforce;
    }

    // ===== IOracleHelper =====

    function oracle() external pure returns (address) {
        return address(0);
    }

    function tickerHashToAsset(bytes32) external pure returns (address) {
        return address(0);
    }

    function registerTicker(string calldata, address) external pure {
        revert("MockOracleHelper: not implemented");
    }

    function getAssetByTicker(string calldata) external pure returns (address) {
        return address(0);
    }

    function getPriceByTicker(string calldata) external pure returns (uint256) {
        return 0;
    }

    function validateMarketOracles(address, address) external pure {
        // no-op
    }

    function getTotalValue(string[] memory, uint256[] memory) external view returns (uint256) {
        return _totalValue;
    }

    function getPriceForLcc(address) external view returns (uint256 price) {
        // Used by other libs; not needed for VTSCommitLib tests.
        // Return price0 for determinism.
        return _price0;
    }

    function getPricesForLccPair(address lcc0, address lcc1) external view returns (uint256 price0, uint256 price1) {
        if (_enforcePair) {
            // Fail fast if library passes unexpected currencies (kills mutants that skip/garble currency assignment).
            // Note: ordering matters because OracleUtils.lccPairValue passes (lcc0, lcc1) consistently.
            require(lcc0 == _expectedLcc0 && lcc1 == _expectedLcc1, "MockOracleHelper: unexpected pair");
        }
        return (_price0, _price1);
    }
}

contract MockSignalManager is IVRLSignalManager {
    // ===== IVRLSignalManager (unused surface area: stubbed) =====

    function getVerifier() external pure returns (address) {
        return address(0);
    }

    function mmNonce(address) external pure returns (uint256) {
        return 0;
    }

    function submitAuthNonce(address) external pure returns (uint256) {
        return 0;
    }

    function submitter() external pure returns (address) {
        return address(0xBEEF);
    }

    function setVerifier(address) external pure {
        revert("MockSignalManager: not implemented");
    }

    function verifyLiquiditySignal(address, bytes memory liquiditySignal, bool) external view returns (bool, uint256) {
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        return (true, signal.mmState.expiryAt - block.timestamp);
    }

    function verifyLiquiditySignalRelayed(
        address,
        uint256,
        bytes memory liquiditySignal,
        uint256,
        uint256,
        bytes memory,
        address,
        bool
    ) external view returns (bool, uint256) {
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        return (true, signal.mmState.expiryAt - block.timestamp);
    }
}

contract VTSCommitLibTest is VTSLibTestBase {
    VTSCommitLibHarness internal harness;
    MockOracleHelper internal oracle;
    MockSignalManager internal sigMgr;

    PoolId internal poolId;
    PositionId internal positionId;
    uint256 internal commitId;

    address internal mmOwner;
    address internal advancer;

    int24 internal constant TL = -60;
    int24 internal constant TU = 60;
    uint128 internal constant LIQ = 1e18;

    function setUp() public override {
        super.setUp();

        harness = new VTSCommitLibHarness();
        oracle = new MockOracleHelper();
        sigMgr = new MockSignalManager();

        poolId = corePoolKey.toId();
        harness.setupPool(poolId, corePoolKey.currency0, corePoolKey.currency1);

        mmOwner = makeAddr("mmOwner");
        advancer = makeAddr("advancer");

        commitId = harness.commitSignal(sigMgr, advancer, oracle, _makeSignal(mmOwner, advancer));
        assertEq(
            harness.getCommitAuthorisedRelayer(commitId),
            address(harness),
            "authorised relayer is harness (orchestrator caller)"
        );

        positionId = _generatePositionId(DEFAULT_OWNER, TL, TU, DEFAULT_SALT);
        harness.setupPosition(positionId, poolId, commitId, TL, TU, LIQ);

        // Enforce currency arguments for lccPairValue() calls to make currency-assignment mutants observable.
        oracle.setExpectedLccPair(Currency.unwrap(corePoolKey.currency0), Currency.unwrap(corePoolKey.currency1), true);
    }

    // ============================================================
    // commitSignal / renewSignal
    // ============================================================

    function test_commitSignal_revertsOnEmptySignal() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLiquiditySignal.selector, 0, 0, 0));
        harness.commitSignal(IVRLSignalManager(makeAddr("signalManager")), address(this), oracle, "");
    }

    function test_commitSignal_incrementsAndStoresState() public {
        uint256 beforeNext = harness.getNextCommitId();

        address owner2 = makeAddr("owner2");
        address adv2 = makeAddr("adv2");

        uint256 newCommitId = harness.commitSignal(sigMgr, owner2, oracle, _makeSignal(owner2, adv2, 1234));

        assertEq(newCommitId, beforeNext + 1, "commitId should increment");
        assertEq(harness.getNextCommitId(), newCommitId, "nextCommitId should match latest");
        assertEq(harness.getCommitOwner(newCommitId), owner2, "commit owner should be saved");
        assertEq(harness.getCommitAdvancer(newCommitId), adv2, "commit advancer should be saved");
        assertEq(harness.getCommitAuthorisedRelayer(newCommitId), address(harness), "authorised relayer is harness");
        assertEq(harness.getCommitExpiresAt(newCommitId), block.timestamp + 1234, "expiry should be set");
    }

    function test_renewSignal_revertsOnEmptySignal() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLiquiditySignal.selector, 0, 0, 0));
        harness.renewSignal(sigMgr, oracle, commitId, "");
    }

    function test_renewSignal_updatesStateAndExpiry() public {
        address owner2 = mmOwner;
        address adv2 = makeAddr("adv2");

        vm.prank(adv2);
        harness.renewSignal(sigMgr, oracle, commitId, _makeSignal(owner2, adv2, 777));

        assertEq(harness.getCommitOwner(commitId), owner2, "owner should remain immutable");
        assertEq(harness.getCommitAdvancer(commitId), adv2, "advancer should update");
        assertEq(harness.getCommitExpiresAt(commitId), block.timestamp + 777, "expiry should update");
    }

    function test_renewSignal_revertsWhenOwnerChanges() public {
        address newOwner = makeAddr("newOwner");
        address adv = address(this);

        vm.expectRevert(Errors.InvalidSender.selector);
        harness.renewSignal(sigMgr, oracle, commitId, _makeSignal(newOwner, adv));
    }

    function test_renewSignal_revertsWhenCallerNotAdvancer() public {
        address adv = makeAddr("adv");

        vm.expectRevert(Errors.InvalidSender.selector);
        harness.renewSignal(sigMgr, oracle, commitId, _makeSignal(mmOwner, adv));
    }

    // ============================================================
    // validateLiquidityDelta
    // ============================================================

    function test_validateLiquidityDelta_success_whenBacked() public {
        (uint160 sqrtPriceX96, int24 tick,,) = _getSlot0(poolId);

        VTSCommitLib.LiquidityDeltaParams memory p = VTSCommitLib.LiquidityDeltaParams({
            currency0: corePoolKey.currency0,
            currency1: corePoolKey.currency1,
            sqrtPriceX96: sqrtPriceX96,
            currentTick: tick,
            tickLower: TL,
            tickUpper: TU,
            liquidityDelta: int256(uint256(LIQ))
        });

        // Provide plenty of backing (signal + settled).
        harness.setPositionSettled(positionId, 0, 0);
        oracle.setTotalValue(1_000_000e18);

        (bool ok, uint256 issued, uint256 settled, uint256 signal) =
            harness.validateLiquidityDelta(oracle, commitId, positionId, p, false);

        assertTrue(ok, "should be sufficiently backed");
        assertGt(issued, 0, "issued should be non-zero");
        assertEq(settled, 0, "settled should be zero");
        assertEq(signal, 1_000_000e18, "signal should match mock");
    }

    function test_validateLiquidityDelta_success_whenBackedBySettledOnly() public {
        (uint160 sqrtPriceX96, int24 tick,,) = _getSlot0(poolId);

        VTSCommitLib.LiquidityDeltaParams memory p = VTSCommitLib.LiquidityDeltaParams({
            currency0: corePoolKey.currency0,
            currency1: corePoolKey.currency1,
            sqrtPriceX96: sqrtPriceX96,
            currentTick: tick,
            tickLower: TL,
            tickUpper: TU,
            liquidityDelta: int256(uint256(LIQ))
        });

        // Signal provides zero backing; settled must carry the validation.
        oracle.setTotalValue(0);

        // Compute issued USD first (settled initially 0).
        harness.setPositionSettled(positionId, 0, 0);
        (, uint256 issuedBefore,, uint256 signalBefore) =
            harness.validateLiquidityDelta(oracle, commitId, positionId, p, false);
        assertEq(signalBefore, 0, "signal should be zero");
        assertGt(issuedBefore, 0, "issued should be non-zero");

        // With prices at 1e18, USD value equals token amounts; settle enough to cover issued.
        uint256 settled0 = issuedBefore + 1;
        uint256 settled1 = 0;
        harness.setPositionSettled(positionId, settled0, settled1);

        (bool ok, uint256 issued, uint256 settled, uint256 signal) =
            harness.validateLiquidityDelta(oracle, commitId, positionId, p, false);

        assertTrue(ok, "should be backed by settled alone");
        assertEq(signal, 0, "signal should remain zero");
        assertEq(issued, issuedBefore, "issued should be stable");
        assertEq(settled, settled0 + settled1, "settled USD should equal token amounts at p=1");
    }

    function test_validateLiquidityDelta_success_whenBackedBySettledOverflowOnly() public {
        (uint160 sqrtPriceX96, int24 tick,,) = _getSlot0(poolId);

        VTSCommitLib.LiquidityDeltaParams memory p = VTSCommitLib.LiquidityDeltaParams({
            currency0: corePoolKey.currency0,
            currency1: corePoolKey.currency1,
            sqrtPriceX96: sqrtPriceX96,
            currentTick: tick,
            tickLower: TL,
            tickUpper: TU,
            liquidityDelta: int256(uint256(LIQ))
        });

        oracle.setTotalValue(0);
        harness.setPositionSettled(positionId, 0, 0);

        (, uint256 issuedBefore,,) = harness.validateLiquidityDelta(oracle, commitId, positionId, p, false);
        assertGt(issuedBefore, 0, "issued should be non-zero");

        // Live settled zero; economic backing sits entirely in overflow (still priced in validateLiquidityDelta).
        harness.setPositionSettledOverflow(positionId, issuedBefore + 1, 0);

        (bool ok, uint256 issued, uint256 settled, uint256 signal) =
            harness.validateLiquidityDelta(oracle, commitId, positionId, p, false);

        assertTrue(ok, "should be backed by overflow alone");
        assertEq(signal, 0, "signal should remain zero");
        assertEq(issued, issuedBefore, "issued should be stable");
        assertEq(settled, issuedBefore + 1, "settled USD should include overflow at p=1");
    }

    function test_validateLiquidityDelta_reverts_whenInsufficientBacking_andFlagTrue() public {
        (uint160 sqrtPriceX96, int24 tick,,) = _getSlot0(poolId);

        VTSCommitLib.LiquidityDeltaParams memory p = VTSCommitLib.LiquidityDeltaParams({
            currency0: corePoolKey.currency0,
            currency1: corePoolKey.currency1,
            sqrtPriceX96: sqrtPriceX96,
            currentTick: tick,
            tickLower: TL,
            tickUpper: TU,
            liquidityDelta: int256(uint256(LIQ))
        });

        harness.setPositionSettled(positionId, 0, 0);
        oracle.setTotalValue(0);

        (bool ok, uint256 issued, uint256 settled, uint256 signal) =
            harness.validateLiquidityDelta(oracle, commitId, positionId, p, false);

        assertTrue(!ok, "should be insufficiently backed");
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLiquiditySignal.selector, issued, signal, settled));
        harness.validateLiquidityDelta(oracle, commitId, positionId, p, true);
    }

    /// @notice Regression (COMMIT-01): cumulative post-add issuance must be checked, not incremental slice alone.
    /// @dev Uses a fixed reference liquidity `LIQ`, measures `issued(LIQ)`, sets signal `S` between ~54% and ~70% of
    ///      that issued value, splits `LIQ` into `L1` and `d` (~6:5) so each slice’s isolated issued USD stays below
    ///      `S` while `issued(LIQ)` exceeds `S`. Hard-revert mode must reject the post-add total but accept each slice.
    function test_validateLiquidityDelta_postAddTotal_notIncrementalSliceAlone() public {
        harness.setPositionSettled(positionId, 0, 0);

        int256 LtotI = int256(uint256(LIQ));
        uint256 issuedRef = _issuedUsdForLiquidity(LtotI);
        assertGt(issuedRef, 0, "pre: issued USD at LIQ must be non-zero");

        uint256 S = (issuedRef * 7) / 10;
        assertGt(issuedRef, S);
        oracle.setTotalValue(S);

        uint256 LtotU = uint256(LIQ);
        uint256 L1 = (LtotU * 6) / 11;
        uint256 d = LtotU - L1;
        assertGt(L1, 0);
        assertGt(d, 0);

        uint256 issuedTot = _issuedUsdForLiquidity(LtotI);
        uint256 issued1 = _issuedUsdForLiquidity(int256(L1));
        uint256 issuedD = _issuedUsdForLiquidity(int256(d));

        assertEq(issuedTot, issuedRef, "total issued at LIQ should match reference");
        assertGt(issuedTot, S, "post-add total issued must exceed signal backing");
        assertLt(issued1, S, "6/11 slice issued alone must stay under signal");
        assertLt(issuedD, S, "5/11 slice issued in isolation must stay under signal");

        // Build params before `expectRevert` so argument evaluation does not consume the expected revert slot.
        VTSCommitLib.LiquidityDeltaParams memory pTot = _liquidityDeltaParamsForLiquidity(LtotI);
        VTSCommitLib.LiquidityDeltaParams memory pD = _liquidityDeltaParamsForLiquidity(int256(d));
        VTSCommitLib.LiquidityDeltaParams memory p1 = _liquidityDeltaParamsForLiquidity(int256(L1));

        // Full encoded error: `expectRevert(bytes4)` only matches a 4-byte revert, not custom-error calldata.
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLiquiditySignal.selector, issuedTot, S, uint256(0)));
        harness.validateLiquidityDelta(oracle, commitId, positionId, pTot, true);

        harness.validateLiquidityDelta(oracle, commitId, positionId, pD, true);
        harness.validateLiquidityDelta(oracle, commitId, positionId, p1, true);
    }

    function test_validateLiquidityDelta_reverts_whenSignalHasTooManyUniqueReserveTickers() public {
        LiquiditySignal memory poisonSig =
            abi.decode(_makeSignalWithUniqueReserveCount(mmOwner, address(this), 101), (LiquiditySignal));
        harness.setCommitMmState(commitId, poisonSig.mmState);

        VTSCommitLib.LiquidityDeltaParams memory p = _defaultLiquidityDeltaParams();
        oracle.setTotalValue(1_000_000e18);

        vm.expectRevert(abi.encodeWithSelector(Errors.MMReserveTickerLimitExceeded.selector, 101, 100));
        harness.validateLiquidityDelta(oracle, commitId, positionId, p, false);
    }

    function test_renewSignal_reverts_whenReserveTickerCountExceedsMax() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.MMReserveTickerLimitExceeded.selector, 101, 100));
        harness.renewSignal(sigMgr, oracle, commitId, _makeSignalWithUniqueReserveCount(mmOwner, address(this), 101));
    }

    function test_commitSignal_reverts_whenReserveTickerCountExceedsMax() public {
        address owner2 = makeAddr("owner2cap");
        address adv2 = makeAddr("adv2cap");
        vm.expectRevert(abi.encodeWithSelector(Errors.MMReserveTickerLimitExceeded.selector, 101, 100));
        harness.commitSignal(sigMgr, adv2, oracle, _makeSignalWithUniqueReserveCount(owner2, adv2, 101));
    }

    function test_validateLiquidityDelta_allowsSignalAtMaxUniqueReserveTickers() public {
        harness.renewSignal(sigMgr, oracle, commitId, _makeSignalWithUniqueReserveCount(mmOwner, address(this), 100));

        VTSCommitLib.LiquidityDeltaParams memory p = _defaultLiquidityDeltaParams();
        oracle.setTotalValue(1_000_000e18);

        (bool ok,,,) = harness.validateLiquidityDelta(oracle, commitId, positionId, p, false);
        assertTrue(ok, "exact max unique reserve tickers should be accepted");
    }

    // ============================================================
    // checkpoint
    // ============================================================

    function test_checkpoint_zeroIssuedValue_zerosDeficitAndReturns() public {
        uint256 t0 = 1_000_000;
        vm.warp(t0);
        // Make issuedUsd == 0 by setting liquidity to 0.
        PositionId pid = _generatePositionId(DEFAULT_OWNER, TL, TU, bytes32(uint256(123)));
        harness.setupPosition(pid, poolId, commitId, TL, TU, 0);

        harness.setPositionCommitmentDeficit(pid, 123, 456);
        harness.setPositionCommitmentDeficitSince(pid, t0 - 10, t0 - 10);
        oracle.setTotalValue(0);

        harness.checkpoint(manager, oracle, commitId, pid);

        (uint256 d0, uint256 d1) = harness.getPositionCommitmentDeficit(pid);
        assertEq(d0, 0, "deficit0 should be cleared");
        assertEq(d1, 0, "deficit1 should be cleared");
        assertEq(harness.getPositionCommitmentDeficitBps(pid), 0, "deficit bps should be zero when issued is zero");
        (uint256 since0, uint256 since1) = harness.getPositionCommitmentDeficitSince(pid);
        assertEq(since0, 0, "deficit0 age should be cleared");
        assertEq(since1, 0, "deficit1 age should be cleared");
    }

    function test_checkpoint_sufficientBacking_clearsDeficit_whenSurplusCovers() public {
        // Set an existing deficit.
        uint256 deficit0 = 1e18;
        uint256 deficit1 = 1e18;
        harness.setPositionCommitmentDeficit(positionId, deficit0, deficit1);
        harness.setPositionSettled(positionId, 0, 0);

        uint256 issuedUsd = _computeIssuedUsd();
        uint256 deficitUsd = deficit0 + deficit1; // prices are 1e18 and amounts are in 18d

        // backingUsd = signalUsd + settledUsd. Here: settledUsd = 0, so signalUsd sets surplus.
        oracle.setTotalValue(issuedUsd + deficitUsd);

        harness.checkpoint(manager, oracle, commitId, positionId);

        (uint256 d0, uint256 d1) = harness.getPositionCommitmentDeficit(positionId);
        assertEq(d0, 0, "deficit0 should be cleared");
        assertEq(d1, 0, "deficit1 should be cleared");
        assertEq(harness.getPositionCommitmentDeficitBps(positionId), 0, "deficit bps should clear when fully backed");
    }

    function test_checkpoint_countsSettledOverflow_towardBacking_whenLiveSettledAloneWouldBeShort() public {
        uint256 issuedUsd = _computeIssuedUsd();
        assertGt(issuedUsd, 100, "issued USD should be large enough for headroom test");

        oracle.setTotalValue(0);
        harness.setPositionCommitmentDeficit(positionId, 0, 0);

        // Live settled alone: issuedUsd - 50 < issuedUsd -> would be under-backed if overflow were ignored.
        // Effective settled token0: (issuedUsd - 50) + 100 > issuedUsd at 1:1 prices -> fully backed.
        harness.setPositionSettled(positionId, issuedUsd - 50, 0);
        harness.setPositionSettledOverflow(positionId, 100, 0);

        harness.checkpoint(manager, oracle, commitId, positionId);

        assertEq(harness.getPositionCommitmentDeficitBps(positionId), 0, "deficit bps should clear with overflow");
        (uint256 d0, uint256 d1) = harness.getPositionCommitmentDeficit(positionId);
        assertEq(d0, 0, "deficit0 should be clear");
        assertEq(d1, 0, "deficit1 should be clear");
    }

    function test_checkpoint_sufficientBacking_reducesDeficit_proRata_whenSurplusPartial() public {
        uint256 deficit0 = 10e18;
        uint256 deficit1 = 10e18;
        harness.setPositionCommitmentDeficit(positionId, deficit0, deficit1);
        harness.setPositionSettled(positionId, 0, 0);

        uint256 issuedUsd = _computeIssuedUsd();

        // Surplus smaller than deficitUsd (20e18) -> pro-rata reduction path.
        uint256 surplusUsd = 5e18;
        oracle.setTotalValue(issuedUsd + surplusUsd);

        harness.checkpoint(manager, oracle, commitId, positionId);

        (uint256 d0, uint256 d1) = harness.getPositionCommitmentDeficit(positionId);
        uint256 currentDeficitUsd = deficit0 + deficit1; // prices are 1e18 in mock
        uint256 reduce0 = FullMath.mulDiv(deficit0, surplusUsd, currentDeficitUsd);
        uint256 reduce1 = FullMath.mulDiv(deficit1, surplusUsd, currentDeficitUsd);
        assertEq(d0, deficit0 - reduce0, "deficit0 should reduce pro-rata");
        assertEq(d1, deficit1 - reduce1, "deficit1 should reduce pro-rata");
        assertEq(harness.getPositionCommitmentDeficitBps(positionId), 0, "deficit bps should clear when fully backed");
    }

    function test_checkpoint_insufficientBacking_setsDeficitFromBps() public {
        // No backing (signal=0, settled=0) -> deficit should become non-zero.
        harness.setPositionSettled(positionId, 0, 0);
        harness.setPositionCommitmentDeficit(positionId, 0, 0);
        oracle.setTotalValue(0);

        harness.checkpoint(manager, oracle, commitId, positionId);

        (uint256 d0, uint256 d1) = harness.getPositionCommitmentDeficit(positionId);
        (uint160 sqrtPriceX96, int24 currentTick,,) = _getSlot0(poolId);
        (uint256 eff0, uint256 eff1) =
            LiquidityUtils.calculateEffectiveTokenAmounts(sqrtPriceX96, currentTick, TL, TU, int256(uint256(LIQ)));
        assertEq(d0, eff0, "deficit0 should equal effective token0 when backing=0");
        assertEq(d1, eff1, "deficit1 should equal effective token1 when backing=0");
        assertEq(
            harness.getPositionCommitmentDeficitBps(positionId),
            LiquidityUtils.BPS_DENOMINATOR,
            "deficit bps should be 100%"
        );
        (uint256 since0, uint256 since1) = harness.getPositionCommitmentDeficitSince(positionId);
        assertEq(since0, block.timestamp, "deficit0 age should initialise at first non-zero deficit");
        assertEq(since1, block.timestamp, "deficit1 age should initialise at first non-zero deficit");
    }

    function test_checkpoint_insufficientBacking_preservesDeficitSince_whenAlreadyDeficient() public {
        harness.setPositionSettled(positionId, 0, 0);
        harness.setPositionCommitmentDeficit(positionId, 0, 0);
        oracle.setTotalValue(0);

        vm.warp(1_000_000);
        harness.checkpoint(manager, oracle, commitId, positionId);
        (uint256 since0First, uint256 since1First) = harness.getPositionCommitmentDeficitSince(positionId);

        vm.warp(1_000_100);
        harness.checkpoint(manager, oracle, commitId, positionId);
        (uint256 since0Second, uint256 since1Second) = harness.getPositionCommitmentDeficitSince(positionId);

        assertEq(since0Second, since0First, "deficit0 age should not reset while deficit remains non-zero");
        assertEq(since1Second, since1First, "deficit1 age should not reset while deficit remains non-zero");
    }

    function test_checkpoint_partialBacking_setsDeficitFromBps() public {
        // Partial backing (signal only), still insufficient: deficit should be proportional.
        harness.setPositionSettled(positionId, 0, 0);
        harness.setPositionCommitmentDeficit(positionId, 0, 0);

        uint256 issuedUsd = _computeIssuedUsd();
        uint256 backingUsd = issuedUsd / 2;
        oracle.setTotalValue(backingUsd);

        harness.checkpoint(manager, oracle, commitId, positionId);

        (uint256 d0, uint256 d1) = harness.getPositionCommitmentDeficit(positionId);
        (uint160 sqrtPriceX96, int24 currentTick,,) = _getSlot0(poolId);
        (uint256 eff0, uint256 eff1) =
            LiquidityUtils.calculateEffectiveTokenAmounts(sqrtPriceX96, currentTick, TL, TU, int256(uint256(LIQ)));

        uint256 deficitUsd = issuedUsd - backingUsd;
        uint256 deficitBps = FullMath.mulDiv(deficitUsd, LiquidityUtils.BPS_DENOMINATOR, issuedUsd);
        uint256 exp0 = FullMath.mulDiv(eff0, deficitBps, LiquidityUtils.BPS_DENOMINATOR);
        uint256 exp1 = FullMath.mulDiv(eff1, deficitBps, LiquidityUtils.BPS_DENOMINATOR);

        assertEq(d0, exp0, "deficit0 should match proportional deficit bps");
        assertEq(d1, exp1, "deficit1 should match proportional deficit bps");
        assertEq(
            harness.getPositionCommitmentDeficitBps(positionId),
            uint16(deficitBps),
            "deficit bps should match computed bps"
        );
    }

    function test_checkpoint_expiredSignal_treatsSignalUsdAsZero() public {
        // Make the stored signal expire quickly, but set oracle signal value high; checkpoint should still treat it as 0.
        harness.setPositionSettled(positionId, 0, 0);
        harness.setPositionCommitmentDeficit(positionId, 0, 0);

        // Renew updates expiresAt; sender must equal advancer in the signal.
        harness.renewSignal(sigMgr, oracle, commitId, _makeSignal(mmOwner, address(this), 1));

        vm.warp(block.timestamp + 2);

        oracle.setTotalValue(1_000_000e18);
        harness.checkpoint(manager, oracle, commitId, positionId);

        (uint256 d0, uint256 d1) = harness.getPositionCommitmentDeficit(positionId);
        (uint160 sqrtPriceX96, int24 currentTick,,) = _getSlot0(poolId);
        (uint256 eff0, uint256 eff1) =
            LiquidityUtils.calculateEffectiveTokenAmounts(sqrtPriceX96, currentTick, TL, TU, int256(uint256(LIQ)));
        assertEq(d0, eff0, "expired signal should contribute 0 backing");
        assertEq(d1, eff1, "expired signal should contribute 0 backing");
        assertEq(
            harness.getPositionCommitmentDeficitBps(positionId),
            LiquidityUtils.BPS_DENOMINATOR,
            "expired signal path should yield 100% deficit bps"
        );
    }

    /**
     *   @dev
     *  In VTSCommitLib.checkpointWithCommitment, there’s a branch that says: if backing is sufficient (via signalUsd > 0)
     *  and the USD value of the existing stored deficit is zero, then the library should force-clear the
     *  stored commitmentDeficit.token0/token1 to 0.
     */
    function test_checkpoint_clearsDeficit_whenDeficitUsdIsZeroButUnitsNonZero() public {
        // Make token0 have zero USD price; deficit in token0 then has zero USD value.
        oracle.setPrices(0, 1e18);

        // Existing deficit expressed only in token0 units (but worth 0 USD now).
        harness.setPositionCommitmentDeficit(positionId, 123e18, 0);
        harness.setPositionSettled(positionId, 0, 0);

        // Ensure issuedUsd > 0 and backing is sufficient.
        oracle.setTotalValue(1_000_000e18);

        harness.checkpoint(manager, oracle, commitId, positionId);

        (uint256 d0, uint256 d1) = harness.getPositionCommitmentDeficit(positionId);
        assertEq(d0, 0, "deficit0 should be cleared when its USD value is zero");
        assertEq(d1, 0, "deficit1 should be cleared");
        assertEq(
            harness.getPositionCommitmentDeficitBps(positionId), 0, "deficit bps should clear when sufficiently backed"
        );
    }

    function test_checkpoint_sufficientBacking_clearsDeficitSince_forTokensCleared() public {
        uint256 t0 = 1_000_000;
        vm.warp(t0);
        harness.setCommitExpiresAt(commitId, t0 + 1 days);
        harness.setPositionCommitmentDeficit(positionId, 123e18, 0);
        harness.setPositionCommitmentDeficitSince(positionId, t0 - 100, 0);
        harness.setPositionSettled(positionId, 0, 0);
        oracle.setTotalValue(1_000_000e18);

        harness.checkpoint(manager, oracle, commitId, positionId);

        (uint256 since0, uint256 since1) = harness.getPositionCommitmentDeficitSince(positionId);
        assertEq(since0, 0, "deficit0 age should clear when token0 deficit is cleared");
        assertEq(since1, 0, "deficit1 age should remain zero");
    }

    // ============================================================
    // helpers
    // ============================================================

    function _makeSignal(address owner, address adv) internal view returns (bytes memory) {
        return _makeSignal(owner, adv, 365 days);
    }

    function _makeSignal(address owner, address adv, uint256 ttlSeconds) internal view returns (bytes memory) {
        MarketMaker.Reserve[] memory reserves = new MarketMaker.Reserve[](0);
        MarketMaker.State memory mmState = MarketMaker.State({
            owner: owner,
            reserves: reserves,
            sourceState: "",
            prover: "",
            nonce: "",
            advancer: adv,
            expiryAt: block.timestamp + ttlSeconds
        });

        LiquiditySignal memory sig = LiquiditySignal({
            nonce: 1,
            rootHash: bytes32(0),
            rootHashSignature: "",
            merkleProof: new bytes32[](0),
            mmState: mmState,
            mmSignature: ""
        });

        return abi.encode(sig);
    }

    function _makeSignalWithUniqueReserveCount(address owner, address adv, uint256 reserveCount)
        internal
        view
        returns (bytes memory)
    {
        return _makeSignalWithUniqueReserveCount(owner, adv, reserveCount, 365 days);
    }

    function _makeSignalWithUniqueReserveCount(address owner, address adv, uint256 reserveCount, uint256 ttlSeconds)
        internal
        view
        returns (bytes memory)
    {
        MarketMaker.Reserve[] memory reserves = new MarketMaker.Reserve[](reserveCount);
        for (uint256 i = 0; i < reserveCount; i++) {
            reserves[i] = MarketMaker.Reserve({asset: string.concat("TK", vm.toString(i)), amount: 1e18});
        }
        return _encodeSignal(owner, adv, reserves, ttlSeconds);
    }

    function _encodeSignal(address owner, address adv, MarketMaker.Reserve[] memory reserves, uint256 ttlSeconds)
        internal
        view
        returns (bytes memory)
    {
        MarketMaker.State memory mmState = MarketMaker.State({
            owner: owner,
            reserves: reserves,
            sourceState: "",
            prover: "",
            nonce: "",
            advancer: adv,
            expiryAt: block.timestamp + ttlSeconds
        });

        LiquiditySignal memory sig = LiquiditySignal({
            nonce: 1,
            rootHash: bytes32(0),
            rootHashSignature: "",
            merkleProof: new bytes32[](0),
            mmState: mmState,
            mmSignature: ""
        });

        return abi.encode(sig);
    }

    function _liquidityDeltaParamsForLiquidity(int256 liquidityAmount)
        internal
        view
        returns (VTSCommitLib.LiquidityDeltaParams memory p)
    {
        (uint160 sqrtPriceX96, int24 tick,,) = _getSlot0(poolId);
        p = VTSCommitLib.LiquidityDeltaParams({
            currency0: corePoolKey.currency0,
            currency1: corePoolKey.currency1,
            sqrtPriceX96: sqrtPriceX96,
            currentTick: tick,
            tickLower: TL,
            tickUpper: TU,
            liquidityDelta: liquidityAmount
        });
    }

    function _issuedUsdForLiquidity(int256 liquidityAmount) internal view returns (uint256 issued) {
        (, issued,,) = harness.validateLiquidityDelta(
            oracle, commitId, positionId, _liquidityDeltaParamsForLiquidity(liquidityAmount), false
        );
    }

    function _defaultLiquidityDeltaParams() internal view returns (VTSCommitLib.LiquidityDeltaParams memory p) {
        return _liquidityDeltaParamsForLiquidity(int256(uint256(LIQ)));
    }

    function _computeIssuedUsd() internal view returns (uint256 issuedUsd) {
        (uint160 sqrtPriceX96, int24 tick,,) = _getSlot0(poolId);

        VTSCommitLib.LiquidityDeltaParams memory p = VTSCommitLib.LiquidityDeltaParams({
            currency0: corePoolKey.currency0,
            currency1: corePoolKey.currency1,
            sqrtPriceX96: sqrtPriceX96,
            currentTick: tick,
            tickLower: TL,
            tickUpper: TU,
            liquidityDelta: int256(uint256(LIQ))
        });

        (, issuedUsd,,) = harness.validateLiquidityDelta(oracle, commitId, positionId, p, false);
    }
}


// SPDX-License-Identifier: BUSL-1.1
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

contract MockOracleHelper is IOracleHelper {
    uint256 internal _price0 = 1e18;
    uint256 internal _price1 = 1e18;
    uint256 internal _totalValue;

    function setPrices(uint256 p0, uint256 p1) external {
        _price0 = p0;
        _price1 = p1;
    }

    function setTotalValue(uint256 v) external {
        _totalValue = v;
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

    function getPricesForLccPair(address, address) external view returns (uint256 price0, uint256 price1) {
        return (_price0, _price1);
    }
}

contract MockSignalManager is IVRLSignalManager {
    uint256 internal _expirySeconds = 3600;

    function setExpirySeconds(uint256 s) external {
        _expirySeconds = s;
    }

    // ===== IVRLSignalManager (unused surface area: stubbed) =====

    function getVerifier() external pure returns (address) {
        return address(0);
    }

    function signalExpiryInSeconds() external view returns (uint256) {
        return _expirySeconds;
    }

    function mmNonce(address) external pure returns (uint256) {
        return 0;
    }

    function setVerifier(address) external pure {
        revert("MockSignalManager: not implemented");
    }

    function setSignalExpiryInSeconds(uint256) external pure {
        revert("MockSignalManager: not implemented");
    }

    function verifyLiquiditySignal(LiquiditySignal memory) external view returns (bool, uint256) {
        return (true, _expirySeconds);
    }

    function verifyLiquiditySignal(bytes memory) external view returns (bool, uint256) {
        return (true, _expirySeconds);
    }

    function verifyLiquiditySignal(bytes memory, bool) external view returns (bool, uint256) {
        return (true, _expirySeconds);
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

        commitId = harness.commitSignal(sigMgr, _makeSignal(mmOwner, advancer));

        positionId = _generatePositionId(DEFAULT_OWNER, TL, TU, DEFAULT_SALT);
        harness.setupPosition(positionId, poolId, commitId, TL, TU, LIQ);
    }

    // ============================================================
    // commitSignal / renewSignal
    // ============================================================

    function test_commitSignal_revertsOnEmptySignal() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLiquiditySignal.selector, 0, 0, 0));
        harness.commitSignal(IVRLSignalManager(makeAddr("signalManager")), "");
    }

    function test_commitSignal_incrementsAndStoresState() public {
        uint256 beforeNext = harness.getNextCommitId();

        address owner2 = makeAddr("owner2");
        address adv2 = makeAddr("adv2");
        sigMgr.setExpirySeconds(1234);

        uint256 newCommitId = harness.commitSignal(sigMgr, _makeSignal(owner2, adv2));

        assertEq(newCommitId, beforeNext + 1, "commitId should increment");
        assertEq(harness.getNextCommitId(), newCommitId, "nextCommitId should match latest");
        assertEq(harness.getCommitOwner(newCommitId), owner2, "commit owner should be saved");
        assertEq(harness.getCommitAdvancer(newCommitId), adv2, "commit advancer should be saved");
        assertEq(harness.getCommitExpiresAt(newCommitId), block.timestamp + 1234, "expiry should be set");
    }

    function test_renewSignal_revertsOnEmptySignal() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLiquiditySignal.selector, 0, 0, 0));
        harness.renewSignal(sigMgr, commitId, "");
    }

    function test_renewSignal_updatesStateAndExpiry() public {
        address owner2 = mmOwner;
        address adv2 = makeAddr("adv2");
        sigMgr.setExpirySeconds(777);

        harness.renewSignal(sigMgr, commitId, _makeSignal(owner2, adv2));

        assertEq(harness.getCommitOwner(commitId), owner2, "owner should update");
        assertEq(harness.getCommitAdvancer(commitId), adv2, "advancer should update");
        assertEq(harness.getCommitExpiresAt(commitId), block.timestamp + 777, "expiry should update");
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

    // ============================================================
    // incrementCoverage
    // ============================================================

    function test_incrementCoverage_earlyReturns_onInvalidTokenIndex_orZeroAmount() public {
        // invalid token index
        harness.incrementCoverage(poolId, 2, 100);
        assertEq(harness.getCoverageResidualDICE(poolId, 0), 0, "no-op");
        assertEq(harness.getCoverageResidualCISE(poolId, 0), 0, "no-op");

        // zero amount
        harness.incrementCoverage(poolId, 0, 0);
        assertEq(harness.getCoverageResidualDICE(poolId, 0), 0, "no-op");
        assertEq(harness.getCoverageResidualCISE(poolId, 0), 0, "no-op");
    }

    function test_incrementCoverage_updatesIndexes_whenTotalsNonZero() public {
        uint256 covered = 50e18;

        // totalPrincipal > 0 -> coveragePerDeficitIndexX128
        harness.setPoolTotalDeficitPrincipal(poolId, 0, 200e18);
        // totalSettled > 0 -> coveragePerSettledIndexX128
        harness.setPoolTotalSettled(poolId, 0, 500e18);

        harness.incrementCoverage(poolId, 0, covered);

        uint256 expectedDice = FullMath.mulDiv(covered, FixedPoint128.Q128, 200e18);
        uint256 expectedCise = FullMath.mulDiv(covered, FixedPoint128.Q128, 500e18);

        assertEq(harness.getCoveragePerDeficitIndexX128(poolId, 0), expectedDice, "DICE index should advance");
        assertEq(harness.getCoveragePerSettledIndexX128(poolId, 0), expectedCise, "CISE index should advance");
        assertEq(harness.getCoverageResidualDICE(poolId, 0), 0, "no DICE residual");
        assertEq(harness.getCoverageResidualCISE(poolId, 0), 0, "no CISE residual");
    }

    function test_incrementCoverage_updatesResiduals_whenTotalsZero() public {
        uint256 covered = 7e18;

        // totals default to 0 in harness storage
        harness.incrementCoverage(poolId, 1, covered);

        assertEq(harness.getCoverageResidualDICE(poolId, 1), covered, "DICE residual should accrue");
        assertEq(harness.getCoverageResidualCISE(poolId, 1), covered, "CISE residual should accrue");
        assertEq(harness.getCoveragePerDeficitIndexX128(poolId, 1), 0, "no DICE index");
        assertEq(harness.getCoveragePerSettledIndexX128(poolId, 1), 0, "no CISE index");
    }

    // ============================================================
    // checkpoint
    // ============================================================

    function test_checkpoint_revertsOnEmptySignal() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLiquiditySignal.selector, 0, 0, 0));
        harness.checkpoint(manager, sigMgr, oracle, advancer, commitId, positionId, "");
    }

    function test_checkpoint_revertsOnInvalidSender() public {
        // sender mismatch (sender != advancer on signal)
        vm.expectRevert(Errors.InvalidSender.selector);
        harness.checkpoint(manager, sigMgr, oracle, makeAddr("notAdvancer"), commitId, positionId, _makeSignal(mmOwner, advancer));
    }

    function test_checkpoint_zeroIssuedValue_zerosDeficitAndReturns() public {
        // Make issuedUsd == 0 by setting liquidity to 0.
        PositionId pid = _generatePositionId(DEFAULT_OWNER, TL, TU, bytes32(uint256(123)));
        harness.setupPosition(pid, poolId, commitId, TL, TU, 0);

        harness.setPositionCommitmentDeficit(pid, 123, 456);
        oracle.setTotalValue(0);

        harness.checkpoint(manager, sigMgr, oracle, advancer, commitId, pid, _makeSignal(mmOwner, advancer));

        (uint256 d0, uint256 d1) = harness.getPositionCommitmentDeficit(pid);
        assertEq(d0, 0, "deficit0 should be cleared");
        assertEq(d1, 0, "deficit1 should be cleared");
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

        harness.checkpoint(manager, sigMgr, oracle, advancer, commitId, positionId, _makeSignal(mmOwner, advancer));

        (uint256 d0, uint256 d1) = harness.getPositionCommitmentDeficit(positionId);
        assertEq(d0, 0, "deficit0 should be cleared");
        assertEq(d1, 0, "deficit1 should be cleared");
    }

    function test_checkpoint_sufficientBacking_reducesDeficit_proRata_whenSurplusPartial() public {
        uint256 deficit0 = 10e18;
        uint256 deficit1 = 10e18;
        harness.setPositionCommitmentDeficit(positionId, deficit0, deficit1);
        harness.setPositionSettled(positionId, 0, 0);

        uint256 issuedUsd = _computeIssuedUsd();

        // Surplus smaller than deficitUsd (20e18) -> pro-rata reduction path.
        oracle.setTotalValue(issuedUsd + 5e18);

        harness.checkpoint(manager, sigMgr, oracle, advancer, commitId, positionId, _makeSignal(mmOwner, advancer));

        (uint256 d0, uint256 d1) = harness.getPositionCommitmentDeficit(positionId);
        assertLt(d0, deficit0, "deficit0 should reduce");
        assertLt(d1, deficit1, "deficit1 should reduce");
        assertGt(d0, 0, "deficit0 should remain");
        assertGt(d1, 0, "deficit1 should remain");
    }

    function test_checkpoint_insufficientBacking_setsDeficitFromBps() public {
        // No backing (signal=0, settled=0) -> deficit should become non-zero.
        harness.setPositionSettled(positionId, 0, 0);
        harness.setPositionCommitmentDeficit(positionId, 0, 0);
        oracle.setTotalValue(0);

        harness.checkpoint(manager, sigMgr, oracle, advancer, commitId, positionId, _makeSignal(mmOwner, advancer));

        (uint256 d0, uint256 d1) = harness.getPositionCommitmentDeficit(positionId);
        assertTrue(d0 > 0 || d1 > 0, "deficit should be set");
    }

    // ============================================================
    // helpers
    // ============================================================

    function _makeSignal(address owner, address adv) internal pure returns (bytes memory) {
        MarketMaker.Reserve[] memory reserves = new MarketMaker.Reserve[](0);
        MarketMaker.State memory mmState = MarketMaker.State({
            owner: owner,
            reserves: reserves,
            sourceState: "",
            prover: "",
            nonce: "",
            advancer: adv
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



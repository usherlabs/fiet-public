// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {CheckpointLibrary} from "../../src/libraries/Checkpoint.sol";
import {Errors} from "../../src/libraries/Errors.sol";

import {VTSStorage} from "../../src/types/VTS.sol";
import {PositionId, Position} from "../../src/types/Position.sol";
import {RFSCheckpoint} from "../../src/types/Checkpoint.sol";
import {IVRLSettlementObserver} from "../../src/interfaces/IVRLSettlementObserver.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract VRLSettlementObserverMock is IVRLSettlementObserver {
    bool internal _isValid;
    bool internal _revertOnInvalid;
    address internal constant _SUBMITTER = address(0xBEEF);

    function setValidity(bool isValid) external {
        _isValid = isValid;
    }

    function setRevertOnInvalid(bool shouldRevert) external {
        _revertOnInvalid = shouldRevert;
    }

    // Unused in these tests
    function addVerifier(address) external pure returns (uint32) {
        return 0;
    }

    function nullifyVerifier(uint32) external pure {}
    function allowVerifierForTokens(uint32, address[] memory) external pure {}
    function disallowVerifierForTokens(uint32, address[] memory) external pure {}

    function submitter() external pure returns (address) {
        return _SUBMITTER;
    }

    function verifySettlementProof(PoolKey memory, uint8, uint32, bytes memory, bool revertOnInvalid)
        external
        view
        returns (bool isProofValid)
    {
        if (!_isValid && (_revertOnInvalid || revertOnInvalid)) {
            revert Errors.InvalidProof();
        }
        return _isValid;
    }
}

contract CheckpointHarness {
    VTSStorage internal s;

    function setPosition(PositionId positionId, PoolId poolId) external {
        Position storage p = s.positions[positionId];
        p.poolId = poolId;
    }

    function setCheckpoint(
        PositionId positionId,
        uint256 timeOfLastTransition,
        bool isOpen,
        uint256 ext0,
        uint256 ext1
    ) external {
        s.positions[positionId].checkpoint.timeOfLastTransition = timeOfLastTransition;
        s.positions[positionId].checkpoint.isOpen = isOpen;
        s.positions[positionId].checkpoint.gracePeriodExtension0 = ext0;
        s.positions[positionId].checkpoint.gracePeriodExtension1 = ext1;
    }

    function setGracePeriods(PoolId poolId, uint256 grace0, uint256 grace1, uint256 max0, uint256 max1) external {
        s.pools[poolId].vtsConfig.token0.gracePeriodTime = grace0;
        s.pools[poolId].vtsConfig.token1.gracePeriodTime = grace1;
        s.pools[poolId].vtsConfig.token0.maxGracePeriodTime = max0;
        s.pools[poolId].vtsConfig.token1.maxGracePeriodTime = max1;
    }

    function setUnbackedCommitmentGraceBypassBps(PoolId poolId, uint16 bps) external {
        s.pools[poolId].vtsConfig.unbackedCommitmentGraceBypassBps = bps;
    }

    function setUnbackedCommitmentGraceBypassConfig(
        PoolId poolId,
        uint256 bypassTime0,
        uint256 bypassTime1,
        uint256 threshold0,
        uint256 threshold1
    ) external {
        s.pools[poolId].vtsConfig.token0.unbackedCommitmentGraceBypassTime = bypassTime0;
        s.pools[poolId].vtsConfig.token1.unbackedCommitmentGraceBypassTime = bypassTime1;
        s.pools[poolId].vtsConfig.token0.unbackedCommitmentGraceBypassThreshold = threshold0;
        s.pools[poolId].vtsConfig.token1.unbackedCommitmentGraceBypassThreshold = threshold1;
    }

    function setCommitPosition(uint256 commitId, uint256 positionIndex, PositionId positionId) external {
        s.commits[commitId].positions[positionIndex] = positionId;
    }

    function setCommitmentDeficit(PositionId positionId, uint256 deficit0, uint256 deficit1) external {
        s.positionAccounting[positionId].commitmentDeficit.token0 = deficit0;
        s.positionAccounting[positionId].commitmentDeficit.token1 = deficit1;
    }

    function setCommitmentDeficitSince(PositionId positionId, uint256 since0, uint256 since1) external {
        s.positionAccounting[positionId].commitmentDeficitSince.token0 = since0;
        s.positionAccounting[positionId].commitmentDeficitSince.token1 = since1;
    }

    function setCommitmentDeficitBps(PositionId positionId, uint16 bps) external {
        s.positionAccounting[positionId].commitmentDeficitBps = bps;
    }

    function isSeizable(uint256 commitId, uint256 positionIndex, bool revertOnFalse) external view returns (bool) {
        return CheckpointLibrary.isSeizable(s, commitId, positionIndex, revertOnFalse);
    }

    function extendGracePeriod(
        IVRLSettlementObserver settlementObserver,
        PoolKey memory poolKey,
        PositionId positionId,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) external {
        CheckpointLibrary.extendGracePeriod(
            s, settlementObserver, poolKey, positionId, settlementTokenIndex, verifierIndex, settlementProof
        );
    }

    function mark(PositionId positionId, bool isOpen) external {
        CheckpointLibrary.markCheckpoint(s, positionId, isOpen);
    }

    function get(PositionId positionId) external view returns (RFSCheckpoint memory) {
        return s.positions[positionId].checkpoint;
    }
}

contract CheckpointLibraryTest is Test {
    CheckpointHarness internal h;
    VRLSettlementObserverMock internal observer;

    uint256 internal constant COMMIT_ID = 1;
    uint256 internal constant POSITION_INDEX = 0;
    PositionId internal constant PID = PositionId.wrap(bytes32(uint256(123)));

    function _defaultPoolKey() internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
    }

    function setUp() public {
        h = new CheckpointHarness();
        observer = new VRLSettlementObserverMock();

        // Wire commit -> positionId
        h.setCommitPosition(COMMIT_ID, POSITION_INDEX, PID);
    }

    function test_markCheckpoint_setsIsOpen_andResetsExtensionsOnChange() public {
        // set non-zero extensions so we can see reset
        h.setCheckpoint(PID, 10, false, 7, 9);

        vm.warp(1234);
        h.mark(PID, true);

        RFSCheckpoint memory cp = h.get(PID);
        assertTrue(cp.isOpen);
        assertEq(cp.timeOfLastTransition, 1234);
        assertEq(cp.gracePeriodExtension0, 0);
        assertEq(cp.gracePeriodExtension1, 0);

        // Calling mark with the same state should be a no-op (timestamp should not change).
        vm.warp(2000);
        h.mark(PID, true);
        RFSCheckpoint memory cp2 = h.get(PID);
        assertEq(cp2.timeOfLastTransition, 1234);
    }

    function test_isSeizable_returnsTrueOnCommitmentDeficit() public {
        PoolKey memory key = _defaultPoolKey();
        PoolId poolId = key.toId();
        h.setPosition(PID, poolId);
        h.setUnbackedCommitmentGraceBypassBps(poolId, 500);
        h.setCommitmentDeficit(PID, 1, 0);
        h.setCommitmentDeficitBps(PID, 600);
        assertTrue(h.isSeizable(COMMIT_ID, POSITION_INDEX, false));
    }

    function test_isSeizable_commitmentDeficitBelowBypassThreshold_requiresNormalGracePath() public {
        PoolKey memory key = _defaultPoolKey();
        PoolId poolId = key.toId();
        h.setPosition(PID, poolId);
        h.setGracePeriods(poolId, 100, 100, 1_000, 1_000);
        h.setUnbackedCommitmentGraceBypassBps(poolId, 500);
        h.setCommitmentDeficit(PID, 1, 0);
        h.setCommitmentDeficitBps(PID, 499);
        h.setCheckpoint(PID, block.timestamp, true, 0, 0);
        assertFalse(h.isSeizable(COMMIT_ID, POSITION_INDEX, false));
    }

    function test_isSeizable_commitmentDeficitAtBypassThreshold_returnsTrue() public {
        PoolKey memory key = _defaultPoolKey();
        PoolId poolId = key.toId();
        h.setPosition(PID, poolId);
        h.setUnbackedCommitmentGraceBypassBps(poolId, 500);
        h.setCommitmentDeficit(PID, 1, 0);
        h.setCommitmentDeficitBps(PID, 500);
        assertTrue(h.isSeizable(COMMIT_ID, POSITION_INDEX, false));
    }

    function test_isSeizable_commitmentDeficitBelowBps_AndThresholdsUnset_doesNotBypass() public {
        PoolKey memory key = _defaultPoolKey();
        PoolId poolId = key.toId();
        h.setPosition(PID, poolId);
        h.setGracePeriods(poolId, 100, 100, 1_000, 1_000);
        h.setUnbackedCommitmentGraceBypassBps(poolId, 500);
        h.setUnbackedCommitmentGraceBypassConfig(poolId, 0, 0, 0, 0);
        h.setCommitmentDeficit(PID, 1_000_000, 0);
        h.setCommitmentDeficitBps(PID, 499);
        h.setCheckpoint(PID, block.timestamp, true, 0, 0);
        assertFalse(h.isSeizable(COMMIT_ID, POSITION_INDEX, false));
    }

    function test_isSeizable_commitmentDeficitBelowBps_token0ThresholdBypasses() public {
        PoolKey memory key = _defaultPoolKey();
        PoolId poolId = key.toId();
        h.setPosition(PID, poolId);
        h.setUnbackedCommitmentGraceBypassBps(poolId, 500);
        h.setUnbackedCommitmentGraceBypassConfig(poolId, 0, 0, 1_000, 0);
        h.setCommitmentDeficit(PID, 1_000, 0);
        h.setCommitmentDeficitBps(PID, 499);
        assertTrue(h.isSeizable(COMMIT_ID, POSITION_INDEX, false));
    }

    function test_isSeizable_commitmentDeficitBelowBps_token1ThresholdBypasses() public {
        PoolKey memory key = _defaultPoolKey();
        PoolId poolId = key.toId();
        h.setPosition(PID, poolId);
        h.setUnbackedCommitmentGraceBypassBps(poolId, 500);
        h.setUnbackedCommitmentGraceBypassConfig(poolId, 0, 0, 0, 2_000);
        h.setCommitmentDeficit(PID, 0, 2_000);
        h.setCommitmentDeficitBps(PID, 499);
        assertTrue(h.isSeizable(COMMIT_ID, POSITION_INDEX, false));
    }

    function test_isSeizable_commitmentDeficitBelowBps_token0ThresholdBoundaryBypasses() public {
        PoolKey memory key = _defaultPoolKey();
        PoolId poolId = key.toId();
        h.setPosition(PID, poolId);
        h.setUnbackedCommitmentGraceBypassBps(poolId, 500);
        h.setUnbackedCommitmentGraceBypassConfig(poolId, 0, 0, 1_000, 0);
        h.setCommitmentDeficit(PID, 999, 0);
        h.setCommitmentDeficitBps(PID, 499);
        assertFalse(h.isSeizable(COMMIT_ID, POSITION_INDEX, false));

        h.setCommitmentDeficit(PID, 1_000, 0);
        assertTrue(h.isSeizable(COMMIT_ID, POSITION_INDEX, false));
    }

    function test_isSeizable_commitmentDeficitBypassTime_notElapsed_blocksBypass() public {
        uint256 t0 = 1_000_000;
        vm.warp(t0);
        PoolKey memory key = _defaultPoolKey();
        PoolId poolId = key.toId();
        h.setPosition(PID, poolId);
        h.setUnbackedCommitmentGraceBypassBps(poolId, 500);
        h.setUnbackedCommitmentGraceBypassConfig(poolId, 100, 0, 0, 0);
        h.setCommitmentDeficit(PID, 1, 0);
        h.setCommitmentDeficitBps(PID, 600);
        h.setCommitmentDeficitSince(PID, t0 - 99, 0);
        assertFalse(h.isSeizable(COMMIT_ID, POSITION_INDEX, false));
    }

    function test_isSeizable_commitmentDeficitBypassTime_elapsed_allowsBypass() public {
        uint256 t0 = 1_000_000;
        vm.warp(t0);
        PoolKey memory key = _defaultPoolKey();
        PoolId poolId = key.toId();
        h.setPosition(PID, poolId);
        h.setUnbackedCommitmentGraceBypassBps(poolId, 500);
        h.setUnbackedCommitmentGraceBypassConfig(poolId, 100, 0, 0, 0);
        h.setCommitmentDeficit(PID, 1, 0);
        h.setCommitmentDeficitBps(PID, 600);
        h.setCommitmentDeficitSince(PID, t0 - 100, 0);
        assertTrue(h.isSeizable(COMMIT_ID, POSITION_INDEX, false));
    }

    function test_isSeizable_returnsFalseWhenRfsClosed_andDoesNotRevertWhenRevertOnFalseFalse() public {
        h.setCheckpoint(PID, block.timestamp, false, 0, 0);
        assertFalse(h.isSeizable(COMMIT_ID, POSITION_INDEX, false));
    }

    function test_isSeizable_revertsWhenRfsClosed_andRevertOnFalseTrue() public {
        h.setCheckpoint(PID, block.timestamp, false, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(Errors.RFSNotOpenForPosition.selector, PID));
        h.isSeizable(COMMIT_ID, POSITION_INDEX, true);
    }

    function test_isSeizable_returnsFalseWhenGracePeriodNotElapsed_andRevertOnFalseFalse() public {
        PoolKey memory key = _defaultPoolKey();
        PoolId poolId = key.toId();

        h.setPosition(PID, poolId);
        h.setGracePeriods(poolId, 100, 200, 1_000, 1_000);

        // Open RFS, but just transitioned now => timeSince = 0.
        h.setCheckpoint(PID, block.timestamp, true, 0, 0);
        assertFalse(h.isSeizable(COMMIT_ID, POSITION_INDEX, false));
    }

    function test_isSeizable_revertsWhenGracePeriodNotElapsed_andRevertOnFalseTrue() public {
        PoolKey memory key = _defaultPoolKey();
        PoolId poolId = key.toId();

        h.setPosition(PID, poolId);
        h.setGracePeriods(poolId, 100, 200, 1_000, 1_000);

        uint256 t0 = 1_000_000;
        h.setCheckpoint(PID, t0, true, 0, 0);
        vm.warp(t0); // ensure block.timestamp == checkpoint.timeOfLastTransition

        RFSCheckpoint memory expected = h.get(PID);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.GracePeriodNotElapsed.selector, COMMIT_ID, POSITION_INDEX, PID, expected)
        );
        h.isSeizable(COMMIT_ID, POSITION_INDEX, true);
    }

    function test_isSeizable_returnsTrueWhenToken0GraceElapsed() public {
        PoolKey memory key = _defaultPoolKey();
        PoolId poolId = key.toId();

        h.setPosition(PID, poolId);
        h.setGracePeriods(poolId, 100, 10_000, 1_000, 20_000);

        uint256 t0 = 777;
        h.setCheckpoint(PID, t0, true, 0, 0);

        vm.warp(t0 + 101);
        assertTrue(h.isSeizable(COMMIT_ID, POSITION_INDEX, false));
    }

    function test_isSeizable_returnsTrueWhenToken1GraceElapsed() public {
        PoolKey memory key = _defaultPoolKey();
        PoolId poolId = key.toId();

        h.setPosition(PID, poolId);
        h.setGracePeriods(poolId, 10_000, 100, 20_000, 1_000);

        uint256 t0 = 888;
        h.setCheckpoint(PID, t0, true, 0, 0);

        vm.warp(t0 + 101);
        assertTrue(h.isSeizable(COMMIT_ID, POSITION_INDEX, false));
    }

    function test_extendGracePeriod_revertsOnInvalidTokenIndex() public {
        PoolKey memory key = _defaultPoolKey();
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenIndex.selector, uint8(2)));
        h.extendGracePeriod(observer, key, PID, 2, 0, hex"");
    }

    function test_extendGracePeriod_extendsToken0Grace_andCapsAtMaxMinusGrace() public {
        PoolKey memory key = _defaultPoolKey();
        PoolId poolId = key.toId();

        h.setPosition(PID, poolId);
        // grace=100, max=250 => maxExtension = 150
        h.setGracePeriods(poolId, 100, 100, 250, 250);
        h.setCheckpoint(PID, block.timestamp, true, 0, 0);

        observer.setValidity(true);

        // 1st extension => +100
        h.extendGracePeriod(observer, key, PID, 0, 7, hex"abcd");
        assertEq(h.get(PID).gracePeriodExtension0, 100);

        // 2nd extension would make 200, but cap at 150.
        h.extendGracePeriod(observer, key, PID, 0, 7, hex"abcd");
        assertEq(h.get(PID).gracePeriodExtension0, 150);
    }

    function test_extendGracePeriod_extendsToken1Grace() public {
        PoolKey memory key = _defaultPoolKey();
        PoolId poolId = key.toId();

        h.setPosition(PID, poolId);
        h.setGracePeriods(poolId, 50, 60, 1_000, 1_000);
        h.setCheckpoint(PID, block.timestamp, true, 0, 0);

        observer.setValidity(true);

        h.extendGracePeriod(observer, key, PID, 1, 9, hex"beef");
        assertEq(h.get(PID).gracePeriodExtension1, 60);
    }
}


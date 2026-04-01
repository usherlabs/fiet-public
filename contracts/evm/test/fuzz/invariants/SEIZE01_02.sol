// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {CheckpointLibrary} from "../../../src/libraries/Checkpoint.sol";
import {Errors} from "../../../src/libraries/Errors.sol";
import {VTSStorage} from "../../../src/types/VTS.sol";
import {PositionId, Position} from "../../../src/types/Position.sol";
import {RFSCheckpoint} from "../../../src/types/Checkpoint.sol";
import {IVRLSettlementObserver} from "../../../src/interfaces/IVRLSettlementObserver.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {MockSettlementObserver} from "../mocks/MockSettlementObserver.sol";

/// @notice Echidna harness for SEIZE-01 and SEIZE-02.
contract SEIZE01_02 {
    uint256 internal constant MAX_VACUOUS_ATTEMPTS = 14;
    CheckpointHarness internal h;
    MockSettlementObserver internal observer;
    PoolKey internal key;
    PoolId internal poolId;

    uint256 internal constant COMMIT_ID = 1;
    uint256 internal constant POSITION_INDEX = 0;
    PositionId internal constant PID = PositionId.wrap(bytes32(uint256(123)));

    bool internal checked01;
    bool internal lastOk01;
    bool internal checked02;
    bool internal lastOk02;
    uint256 internal seize01Attempts;
    uint256 internal seize02Attempts;
    uint256 internal seize01Checks;
    uint256 internal seize02Checks;

    constructor() {
        h = new CheckpointHarness();
        observer = new MockSettlementObserver();
        key = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
        poolId = key.toId();
        h.setPosition(PID, poolId);
        h.setCommitPosition(COMMIT_ID, POSITION_INDEX, PID);
        h.setGracePeriods(poolId, 100, 100, 1_000, 1_000);
        h.setUnbackedCommitmentGraceBypassBps(poolId, 500);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_seize_01_commitment_bypass(
        uint16 deficitBps,
        uint96 deficit0,
        uint96 deficit1,
        uint40 since0,
        uint40 since1,
        uint16 bypassBps,
        uint32 bypassTime0,
        uint32 bypassTime1,
        uint96 threshold0,
        uint96 threshold1
    ) external {
        unchecked {
            seize01Attempts++;
        }
        checked01 = false;
        lastOk01 = true;
        uint256 age0 = uint256(since0) % (block.timestamp + 1);
        uint256 age1 = uint256(since1) % (block.timestamp + 1);
        h.setCheckpoint(PID, block.timestamp, false, 0, 0);
        h.setCommitmentDeficit(PID, uint256(deficit0), uint256(deficit1));
        h.setCommitmentDeficitBps(PID, deficitBps);
        h.setCommitmentDeficitSince(PID, block.timestamp - age0, block.timestamp - age1);
        h.setUnbackedCommitmentGraceBypassBps(poolId, bypassBps);
        h.setBypassTokenParams(poolId, bypassTime0, bypassTime1, uint256(threshold0), uint256(threshold1));
        checked01 = true;
        bool expectedTrue = _expectedCommitmentBypass(
            deficitBps, deficit0, deficit1, age0, age1, bypassBps, bypassTime0, bypassTime1, threshold0, threshold1
        );
        bool got = h.isSeizable(COMMIT_ID, POSITION_INDEX, false);
        seize01Checks++;
        lastOk01 = got == expectedTrue;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_seize_01_open_lane_grace_elapsed(
        uint40 since0,
        uint40 since1,
        uint8 openMask,
        uint16 grace0,
        uint16 grace1
    ) external {
        unchecked {
            seize01Attempts++;
        }
        checked01 = false;
        lastOk01 = true;
        uint256 nowTs = block.timestamp;
        uint256 age0 = uint256(since0) % (nowTs + 1);
        uint256 age1 = uint256(since1) % (nowTs + 1);
        h.setGracePeriods(poolId, grace0, grace1, 10_000, 10_000);
        h.setCheckpointMask(PID, openMask & 3, nowTs - age0, nowTs - age1, 0, 0);
        h.setCommitmentDeficit(PID, 0, 0);
        h.setCommitmentDeficitBps(PID, 0);

        bool lane0Eligible = (openMask & 1) != 0 && age0 >= uint256(grace0);
        bool lane1Eligible = (openMask & 2) != 0 && age1 >= uint256(grace1);
        bool expectedTrue = lane0Eligible || lane1Eligible;
        bool got = h.isSeizable(COMMIT_ID, POSITION_INDEX, false);
        checked01 = true;
        seize01Checks++;
        lastOk01 = got == expectedTrue;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_seize_02_extend_grace_requires_valid_proof(
        bool validProof,
        uint8 settlementTokenIndex,
        bool tokenAllowed,
        bool verifierActive
    ) external {
        unchecked {
            seize02Attempts++;
        }
        checked02 = false;
        lastOk02 = true;
        uint8 tokenIndex = settlementTokenIndex % 2;
        h.setCheckpointMask(PID, tokenIndex == 0 ? 1 : 2, block.timestamp, block.timestamp, 0, 0);
        observer.setValidity(validProof);
        uint32 verifierIndex = h.registerVerifier(observer);
        h.setVerifierAllowed(observer, verifierIndex, key, tokenIndex, tokenAllowed);
        if (!verifierActive) {
            h.nullifyVerifier(observer, verifierIndex);
        }

        bool reverted;
        try h.extendGracePeriod(observer, key, PID, tokenIndex, verifierIndex, hex"01") {
            reverted = false;
        } catch {
            reverted = true;
        }

        checked02 = true;
        bool shouldSucceed = validProof && tokenAllowed && verifierActive;
        seize02Checks++;
        lastOk02 = shouldSucceed ? !reverted : reverted;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_seize_02_invalid_token_index_reverts(uint8 badTokenIndex) external {
        unchecked {
            seize02Attempts++;
        }
        checked02 = false;
        lastOk02 = true;
        if (badTokenIndex <= 1) {
            badTokenIndex = 2;
        }
        observer.setValidity(true);
        uint32 verifierIndex = h.registerVerifier(observer);
        h.setVerifierAllowed(observer, verifierIndex, key, 0, true);

        bool reverted;
        try h.extendGracePeriod(observer, key, PID, badTokenIndex, verifierIndex, hex"01") {
            reverted = false;
        } catch {
            reverted = true;
        }
        checked02 = true;
        seize02Checks++;
        lastOk02 = reverted;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_seize_02_closed_lane_reverts(uint8 settlementTokenIndex) external {
        unchecked {
            seize02Attempts++;
        }
        checked02 = false;
        lastOk02 = true;
        uint8 tokenIndex = settlementTokenIndex % 2;
        // Open the opposite lane only.
        h.setCheckpointMask(PID, tokenIndex == 0 ? 2 : 1, block.timestamp, block.timestamp, 0, 0);
        observer.setValidity(true);
        uint32 verifierIndex = h.registerVerifier(observer);
        h.setVerifierAllowed(observer, verifierIndex, key, tokenIndex, true);

        bool reverted;
        try h.extendGracePeriod(observer, key, PID, tokenIndex, verifierIndex, hex"01") {
            reverted = false;
        } catch {
            reverted = true;
        }
        checked02 = true;
        seize02Checks++;
        lastOk02 = reverted;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_seize_01_token_lane_scoped_and_aggregated() external view returns (bool) {
        if (seize01Checks == 0) {
            return seize01Attempts < MAX_VACUOUS_ATTEMPTS;
        }
        return !checked01 || lastOk01;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_seize_02_valid_verifier_required() external view returns (bool) {
        if (seize02Checks == 0) {
            return seize02Attempts < MAX_VACUOUS_ATTEMPTS;
        }
        return !checked02 || lastOk02;
    }

    function _expectedCommitmentBypass(
        uint16 deficitBps,
        uint96 deficit0,
        uint96 deficit1,
        uint256 age0,
        uint256 age1,
        uint16 bypassBps,
        uint32 bypassTime0,
        uint32 bypassTime1,
        uint96 threshold0,
        uint96 threshold1
    ) internal pure returns (bool expectedTrue) {
        bool bpsBypass = deficitBps >= bypassBps;
        bool token0AgeMet = bypassTime0 == 0 || age0 >= uint256(bypassTime0);
        bool token1AgeMet = bypassTime1 == 0 || age1 >= uint256(bypassTime1);
        bool token0Threshold = uint256(threshold0) > 0 && uint256(deficit0) >= uint256(threshold0);
        bool token1Threshold = uint256(threshold1) > 0 && uint256(deficit1) >= uint256(threshold1);
        return (deficit0 > 0 && token0AgeMet && (bpsBypass || token0Threshold))
            || (deficit1 > 0 && token1AgeMet && (bpsBypass || token1Threshold));
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
        s.positions[positionId].checkpoint.openMask = isOpen ? 3 : 0;
        s.positions[positionId].checkpoint.openSince0 = isOpen ? timeOfLastTransition : 0;
        s.positions[positionId].checkpoint.openSince1 = isOpen ? timeOfLastTransition : 0;
        s.positions[positionId].checkpoint.gracePeriodExtension0 = ext0;
        s.positions[positionId].checkpoint.gracePeriodExtension1 = ext1;
    }

    function setCheckpointMask(
        PositionId positionId,
        uint8 openMask,
        uint256 openSince0,
        uint256 openSince1,
        uint256 ext0,
        uint256 ext1
    ) external {
        s.positions[positionId].checkpoint.openMask = openMask;
        s.positions[positionId].checkpoint.openSince0 = openSince0;
        s.positions[positionId].checkpoint.openSince1 = openSince1;
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

    function setCommitPosition(uint256 commitId, uint256 positionIndex, PositionId positionId) external {
        s.commits[commitId].positions[positionIndex] = positionId;
    }

    function setCommitmentDeficit(PositionId positionId, uint256 deficit0, uint256 deficit1) external {
        s.positionAccounting[positionId].commitmentDeficit.token0 = deficit0;
        s.positionAccounting[positionId].commitmentDeficit.token1 = deficit1;
    }

    function setCommitmentDeficitBps(PositionId positionId, uint16 bps) external {
        s.positionAccounting[positionId].commitmentDeficitBps = bps;
    }

    function setCommitmentDeficitSince(PositionId positionId, uint256 since0, uint256 since1) external {
        s.positionAccounting[positionId].commitmentDeficitSince.token0 = since0;
        s.positionAccounting[positionId].commitmentDeficitSince.token1 = since1;
    }

    function setBypassTokenParams(
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

    function registerVerifier(MockSettlementObserver settlementObserver) external returns (uint32) {
        return settlementObserver.addVerifier(address(0x1234));
    }

    function setVerifierAllowed(
        MockSettlementObserver settlementObserver,
        uint32 verifierIndex,
        PoolKey memory key,
        uint8 settlementTokenIndex,
        bool allowed
    ) external {
        address[] memory tokens = new address[](1);
        address tokenForLane =
            settlementTokenIndex == 0 ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        tokens[0] = tokenForLane;
        if (allowed) {
            settlementObserver.allowVerifierForTokens(verifierIndex, tokens);
            return;
        }
        settlementObserver.allowVerifierForTokens(verifierIndex, tokens);
        settlementObserver.disallowVerifierForTokens(verifierIndex, tokens);
    }

    function nullifyVerifier(MockSettlementObserver settlementObserver, uint32 verifierIndex) external {
        settlementObserver.nullifyVerifier(verifierIndex);
    }

    function get(PositionId positionId) external view returns (RFSCheckpoint memory) {
        return s.positions[positionId].checkpoint;
    }
}


// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * E2E: Cross-market delta / produced-credit regression
 *
 * Goal:
 * - Deploy one stack and four markets that **share the same underlying asset pair** (distinct LCCs per market).
 * - Drive a multi-step MM journey that intentionally crosses markets, then assert **durable accounting equivalence**
 *   between:
 *   1) the same program executed as staged batches, and
 *   2) the compacted single-batch program.
 * - Keep compacted execution as a smoke path, but move correctness to staged-vs-compacted end-state equality.
 * - After each staged batch, assert durable expectations (positions + protocol fees on idle pools); do not assert
 *   wallet LCC balances mid-run (transient credits are batch-scoped per `DELTA-01`).
 * - Staged slices that are not the final segment append an 8-lane `TAKE` sweep so each `MMPositionManager` unlock ends
 *   with zero currency deltas (`_afterBatch` / `CurrencyNotSettled`); the compacted batch already ends with that sweep.
 *
 * Env:
 * - LP_PRIVATE_KEY: MM actor (same as other MM E2E scripts)
 * - PRIVATE_KEY: deployer (via `_getDeployerPrivateKey()` in `E2EBase`)
 */

import {MME2EBase} from "./base/MME2EBase.sol";

import {console} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MMPositionManager} from "src/MMPositionManager.sol";
import {MMActions} from "src/libraries/MMActions.sol";
import {IVTSOrchestrator} from "src/interfaces/IVTSOrchestrator.sol";
import {PositionId, Position} from "src/types/Position.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract CrossMarketDeltaRegressionE2E is MME2EBase {
    uint24 internal constant CORE_POOL_FEE = 3000;
    int24 internal constant TICK_LOWER = -60;
    int24 internal constant TICK_UPPER = 60;
    uint128 internal constant LIQUIDITY = 1e10;

    /// @dev Must match `_buildBatchActions` / `_buildBatchParams` length (single source of truth).
    uint256 internal constant BATCH_LEN = 20;
    /// @dev Trailing LCC lane sweep in `_buildBatchActions` (indices 12..19); reused after staged slices A–D.
    uint256 internal constant TAKE_SWEEP_LEN = 8;

    MMPositionManager internal s_mmpm;
    PoolKey internal s_keyA;
    PoolKey internal s_keyB;
    PoolKey internal s_keyC;
    PoolKey internal s_keyD;
    uint256 internal s_commitA;
    uint256 internal s_commitB;
    uint256 internal s_commitC;
    uint256 internal s_commitD;
    uint256 internal s_decAmount;
    address internal s_underlying0;
    address internal s_underlying1;
    address internal s_vtsOrchestrator;

    // Staged checkpoints over the compacted 20-action program.
    // Each non-final boundary is placed after a "...FROM_DELTAS" consumer so the preceding unlock can end with
    // zero underlying-token deltas before the trailing TAKE sweep runs.
    uint256 internal constant STAGE_A_END = 3; // [0,3)  A settle -> B mint-from-deltas
    uint256 internal constant STAGE_B_END = 6; // [3,6)  B settle -> B increase-from-deltas
    uint256 internal constant STAGE_C_END = 9; // [6,9)  B settle -> C settle-from-deltas
    uint256 internal constant STAGE_D_END = 12; // [9,12) C settle -> D mint-from-deltas
    uint256 internal constant STAGE_E_END = 20; // [12,20) trailing TAKE sweep only

    struct DurablePositionState {
        address owner;
        bytes32 poolId;
        uint256 commitId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool isActive;
        bytes32 salt;
        uint8 openMask;
        uint256 openSince0;
        uint256 openSince1;
        uint256 gracePeriodExtension0;
        uint256 gracePeriodExtension1;
        bytes32 positionId;
        uint256 settled0;
        uint256 settled1;
        uint256 positionCount;
        uint256 activePositionCount;
        uint256 inactiveRemnantCount;
        address tokenOwner;
    }

    struct DurableSnapshot {
        uint256 mmUnderlying0;
        uint256 mmUnderlying1;
        uint256[8] mmLccBalances;
        uint256[8] managerLccBalances;
        DurablePositionState posA;
        DurablePositionState posB;
        DurablePositionState posC;
        DurablePositionState posD;
        /// @dev Keccak over every position index under the commit (not only index 0).
        bytes32 digestA;
        bytes32 digestB;
        bytes32 digestC;
        bytes32 digestD;
        /// @dev Pool-level durable aggregates (A–D) for CISE total settled and DICE deficit principal.
        uint256[4] poolTotalSettled0;
        uint256[4] poolTotalSettled1;
        uint256[4] poolDeficitPrincipal0;
        uint256[4] poolDeficitPrincipal1;
        uint256[4] protocolFee0;
        uint256[4] protocolFee1;
    }

    function _loadMmPrivateKey() internal view returns (uint256 mmPk) {
        mmPk = uint256(
            _requireEnvBytes32("LP_PRIVATE_KEY", "Missing LP_PRIVATE_KEY env var (anvil keys can be used directly)")
        );
    }

    function _prepareCrossMarketBatch(address mm, uint256 mmPk) internal {
        StandaloneMarket memory mA = _deployAndCreateMarket(mm, CORE_POOL_FEE);

        s_mmpm = MMPositionManager(payable(mA.stack.contracts.mmPositionManager));
        s_keyA = _corePoolKey(mA);
        s_commitA = _createMmPosition(mA, mmPk, TICK_LOWER, TICK_UPPER, LIQUIDITY);

        StandaloneMarket memory nextMarket = _createMarketFromStackWithUnderlyings(
            mA.stack, mm, CORE_POOL_FEE, mA.underlying0, mA.underlying1, false
        );
        s_keyB = _corePoolKey(nextMarket);
        s_commitB = _createMmPosition(nextMarket, mmPk, TICK_LOWER, TICK_UPPER, LIQUIDITY);

        nextMarket = _createMarketFromStackWithUnderlyings(
            mA.stack, mm, CORE_POOL_FEE, mA.underlying0, mA.underlying1, false
        );
        s_keyC = _corePoolKey(nextMarket);
        s_commitC = _createMmPosition(nextMarket, mmPk, TICK_LOWER, TICK_UPPER, LIQUIDITY);

        nextMarket = _createMarketFromStackWithUnderlyings(
            mA.stack, mm, CORE_POOL_FEE, mA.underlying0, mA.underlying1, false
        );
        s_keyD = _corePoolKey(nextMarket);
        s_commitD = _createMmPosition(nextMarket, mmPk, TICK_LOWER, TICK_UPPER, LIQUIDITY);

        s_decAmount = uint256(LIQUIDITY / 8);
        require(s_decAmount > 0, "regression: decrease amount must be non-zero");
        s_underlying0 = mA.underlying0;
        s_underlying1 = mA.underlying1;
        s_vtsOrchestrator = mA.stack.contracts.vtsOrchestrator;
    }

    /// @dev Runs the compacted cross-market MM batch (must call `_prepareCrossMarketBatch` in the same script run first).
    /// Internal only: external `this.*` calls would route through the ephemeral script address and trip Foundry’s
    /// script safety checks.
    /// @param recipient Locker credit sweep recipient for trailing `TAKE` actions (same as MM in `_runScenario`).
    /// @param mmPk MM private key (broadcast signer).
    function _runCrossMarketAtomicBatch(address recipient, uint256 mmPk) internal {
        require(address(s_mmpm) != address(0), "CrossMarket: call _prepareCrossMarketBatch first");
        require(recipient != address(0), "CrossMarket: recipient is zero");
        bytes memory actions = _buildBatchActions();
        bytes[] memory params = _buildBatchParams(recipient);
        _runBatch(actions, params, mmPk);
    }

    /// @dev Runs the same logical program as staged batches to expose stable checkpoint surfaces between steps.
    /// Between batches we assert **durable** state only (positions, protocol fees, etc.), not transient intra-batch
    /// credits (see `DELTA-01` in `INVARIANTS.md`).
    function _runCrossMarketStagedBatches(address recipient, uint256 mmPk) internal {
        bytes memory actions = _buildBatchActions();
        bytes[] memory params = _buildBatchParams(recipient);

        DurableSnapshot memory prev = _captureDurableSnapshot(recipient);

        _runBatchRange(actions, params, 0, STAGE_A_END, recipient, mmPk, "A: A decrease+settle -> B mint-from-deltas");
        DurableSnapshot memory afterA = _captureDurableSnapshot(recipient);
        _assertAfterStageA(prev, afterA);
        prev = afterA;

        _runBatchRange(
            actions, params, STAGE_A_END, STAGE_B_END, recipient, mmPk, "B: B decrease+settle+increase-from-deltas"
        );
        DurableSnapshot memory afterB = _captureDurableSnapshot(recipient);
        _assertAfterStageB(prev, afterB);
        prev = afterB;

        _runBatchRange(
            actions, params, STAGE_B_END, STAGE_C_END, recipient, mmPk, "C: B settle path -> C settle-from-deltas"
        );
        DurableSnapshot memory afterC = _captureDurableSnapshot(recipient);
        _assertAfterStageC(prev, afterC);
        prev = afterC;

        _runBatchRange(actions, params, STAGE_C_END, STAGE_D_END, recipient, mmPk, "D: C decrease+settle -> D mint");
        DurableSnapshot memory afterD = _captureDurableSnapshot(recipient);
        _assertAfterStageD(prev, afterD);
        prev = afterD;

        _runBatchRange(actions, params, STAGE_D_END, STAGE_E_END, recipient, mmPk, "E: TAKE sweep");
        DurableSnapshot memory afterE = _captureDurableSnapshot(recipient);
        _assertAfterStageE(prev, afterE);
    }

    function _runBatch(bytes memory actions, bytes[] memory params, uint256 mmPk) internal {
        require(actions.length == params.length, "CrossMarket: actions/params length mismatch");
        vm.startBroadcast(mmPk);
        _executeMMActions(s_mmpm, actions, params, block.timestamp + 3600);
        vm.stopBroadcast();
    }

    function _runBatchRange(
        bytes memory allActions,
        bytes[] memory allParams,
        uint256 start,
        uint256 end,
        address recipient,
        uint256 mmPk,
        string memory label
    ) internal {
        require(end > start, "CrossMarket: invalid staged range");
        require(end <= allActions.length && end <= allParams.length, "CrossMarket: staged range out of bounds");
        uint256 n = end - start;
        // Final segment [STAGE_D_END, STAGE_E_END) already is the 8-lane TAKE sweep (batch indices 12..19).
        // Earlier segments must append that sweep so each unlock clears locker credits (otherwise `CurrencyNotSettled`).
        bool appendLaneTakeSweep = end < STAGE_E_END;
        uint256 takeN = appendLaneTakeSweep ? TAKE_SWEEP_LEN : 0;
        bytes memory actions = new bytes(n + takeN);
        bytes[] memory params = new bytes[](n + takeN);
        for (uint256 i = 0; i < n; ++i) {
            actions[i] = allActions[start + i];
            params[i] = allParams[start + i];
        }
        for (uint256 j = 0; j < takeN; ++j) {
            actions[n + j] = bytes1(uint8(MMActions.TAKE));
            params[n + j] = _takeSweepParamAt(j, recipient);
        }
        _runBatch(actions, params, mmPk);
        console.log("OK: staged batch");
        console.log(label);
    }

    function _takeSweepParamAt(uint256 laneIndex, address recipient) internal view returns (bytes memory) {
        require(laneIndex < TAKE_SWEEP_LEN, "CrossMarket: take sweep lane index");
        if (laneIndex == 0) return _takeParam(s_keyA.currency0, recipient);
        if (laneIndex == 1) return _takeParam(s_keyA.currency1, recipient);
        if (laneIndex == 2) return _takeParam(s_keyB.currency0, recipient);
        if (laneIndex == 3) return _takeParam(s_keyB.currency1, recipient);
        if (laneIndex == 4) return _takeParam(s_keyC.currency0, recipient);
        if (laneIndex == 5) return _takeParam(s_keyC.currency1, recipient);
        if (laneIndex == 6) return _takeParam(s_keyD.currency0, recipient);
        return _takeParam(s_keyD.currency1, recipient);
    }

    function _buildBatchActions() internal pure returns (bytes memory actions) {
        actions = new bytes(BATCH_LEN);
        actions[0] = bytes1(uint8(MMActions.DECREASE_LIQUIDITY));
        actions[1] = bytes1(uint8(MMActions.SETTLE_POSITION));
        actions[2] = bytes1(uint8(MMActions.MINT_POSITION_FROM_DELTAS));
        actions[3] = bytes1(uint8(MMActions.DECREASE_LIQUIDITY));
        actions[4] = bytes1(uint8(MMActions.SETTLE_POSITION));
        actions[5] = bytes1(uint8(MMActions.INCREASE_LIQUIDITY_FROM_DELTAS));
        actions[6] = bytes1(uint8(MMActions.DECREASE_LIQUIDITY));
        actions[7] = bytes1(uint8(MMActions.SETTLE_POSITION));
        actions[8] = bytes1(uint8(MMActions.SETTLE_POSITION_FROM_DELTAS));
        actions[9] = bytes1(uint8(MMActions.DECREASE_LIQUIDITY));
        actions[10] = bytes1(uint8(MMActions.SETTLE_POSITION));
        actions[11] = bytes1(uint8(MMActions.MINT_POSITION_FROM_DELTAS));
        actions[12] = bytes1(uint8(MMActions.TAKE));
        actions[13] = bytes1(uint8(MMActions.TAKE));
        actions[14] = bytes1(uint8(MMActions.TAKE));
        actions[15] = bytes1(uint8(MMActions.TAKE));
        actions[16] = bytes1(uint8(MMActions.TAKE));
        actions[17] = bytes1(uint8(MMActions.TAKE));
        actions[18] = bytes1(uint8(MMActions.TAKE));
        actions[19] = bytes1(uint8(MMActions.TAKE));
    }

    function _buildBatchParams(address recipient)
        internal
        view
        returns (bytes[] memory params)
    {
        params = new bytes[](BATCH_LEN);
        params[0] = _param0();
        params[1] = _param1();
        params[2] = _param2();
        params[3] = _param3();
        params[4] = _param4();
        params[5] = _param5();
        params[6] = _param6();
        params[7] = _param7();
        params[8] = _param8();
        params[9] = _param9();
        params[10] = _param10();
        params[11] = _param11();
        params[12] = _takeParam(s_keyA.currency0, recipient);
        params[13] = _takeParam(s_keyA.currency1, recipient);
        params[14] = _takeParam(s_keyB.currency0, recipient);
        params[15] = _takeParam(s_keyB.currency1, recipient);
        params[16] = _takeParam(s_keyC.currency0, recipient);
        params[17] = _takeParam(s_keyC.currency1, recipient);
        params[18] = _takeParam(s_keyD.currency0, recipient);
        params[19] = _takeParam(s_keyD.currency1, recipient);
    }

    function _param0() internal view returns (bytes memory) {
        return abi.encode(s_keyA, s_commitA, 0, s_decAmount);
    }

    function _param1() internal view returns (bytes memory) {
        return abi.encode(s_keyA, s_commitA, 0, type(int128).max, type(int128).max, true);
    }

    function _param2() internal view returns (bytes memory) {
        return abi.encode(s_keyB, s_commitB, TICK_LOWER, TICK_UPPER, type(uint128).max, type(uint128).max, false);
    }

    function _param3() internal view returns (bytes memory) {
        return abi.encode(s_keyB, s_commitB, 0, s_decAmount);
    }

    function _param4() internal view returns (bytes memory) {
        return abi.encode(s_keyB, s_commitB, 0, type(int128).max, type(int128).max, true);
    }

    function _param5() internal view returns (bytes memory) {
        return abi.encode(s_keyB, s_commitB, 0, type(uint128).max, type(uint128).max, false);
    }

    function _param6() internal view returns (bytes memory) {
        return abi.encode(s_keyB, s_commitB, 0, s_decAmount);
    }

    function _param7() internal view returns (bytes memory) {
        return abi.encode(s_keyB, s_commitB, 0, type(int128).max, type(int128).max, true);
    }

    function _param8() internal view returns (bytes memory) {
        return abi.encode(s_keyC, s_commitC, 0, false, false);
    }

    function _param9() internal view returns (bytes memory) {
        return abi.encode(s_keyC, s_commitC, 0, s_decAmount);
    }

    function _param10() internal view returns (bytes memory) {
        return abi.encode(s_keyC, s_commitC, 0, type(int128).max, type(int128).max, true);
    }

    function _param11() internal view returns (bytes memory) {
        return abi.encode(s_keyD, s_commitD, TICK_LOWER, TICK_UPPER, type(uint128).max, type(uint128).max, false);
    }

    function _takeParam(Currency lane, address recipient) internal pure returns (bytes memory) {
        return abi.encode(lane, recipient, 0);
    }

    function _lccLanes() internal view returns (address[8] memory lanes) {
        lanes[0] = Currency.unwrap(s_keyA.currency0);
        lanes[1] = Currency.unwrap(s_keyA.currency1);
        lanes[2] = Currency.unwrap(s_keyB.currency0);
        lanes[3] = Currency.unwrap(s_keyB.currency1);
        lanes[4] = Currency.unwrap(s_keyC.currency0);
        lanes[5] = Currency.unwrap(s_keyC.currency1);
        lanes[6] = Currency.unwrap(s_keyD.currency0);
        lanes[7] = Currency.unwrap(s_keyD.currency1);
    }

    function _capturePositionState(uint256 commitId) internal view returns (DurablePositionState memory st) {
        IVTSOrchestrator vts = IVTSOrchestrator(s_vtsOrchestrator);
        (Position memory p, PositionId pid) = vts.getPosition(commitId, 0);
        st.owner = p.owner;
        st.poolId = PoolId.unwrap(p.poolId);
        st.commitId = p.commitId;
        st.tickLower = p.tickLower;
        st.tickUpper = p.tickUpper;
        st.liquidity = p.liquidity;
        st.isActive = p.isActive;
        st.salt = p.salt;
        st.openMask = p.checkpoint.openMask;
        st.openSince0 = p.checkpoint.openSince0;
        st.openSince1 = p.checkpoint.openSince1;
        st.gracePeriodExtension0 = p.checkpoint.gracePeriodExtension0;
        st.gracePeriodExtension1 = p.checkpoint.gracePeriodExtension1;
        st.positionId = PositionId.unwrap(pid);
        (st.settled0, st.settled1) = vts.getPositionSettledAmounts(pid);
        (, , st.positionCount, st.activePositionCount, st.inactiveRemnantCount) = vts.getCommit(commitId);
        st.tokenOwner = s_mmpm.ownerOf(commitId);
    }

    /// @dev Fingerprint of all position rows for a commit so staged vs compacted cannot diverge on non-zero indices only.
    function _commitAllPositionsDigest(uint256 commitId) internal view returns (bytes32) {
        IVTSOrchestrator vts = IVTSOrchestrator(s_vtsOrchestrator);
        (,, uint256 positionCount,, uint256 inactiveRemnantCount) = vts.getCommit(commitId);
        bytes32 h = keccak256(abi.encode(commitId, positionCount, inactiveRemnantCount));
        for (uint256 i = 0; i < positionCount; ++i) {
            (Position memory p, PositionId pid) = vts.getPosition(commitId, i);
            (uint256 settled0, uint256 settled1) = vts.getPositionSettledAmounts(pid);
            h = keccak256(abi.encode(h, i, p, pid, settled0, settled1));
        }
        return h;
    }

    function _captureDurableSnapshot(address mm) internal view returns (DurableSnapshot memory snap) {
        IVTSOrchestrator vts = IVTSOrchestrator(s_vtsOrchestrator);
        address[8] memory lanes = _lccLanes();
        snap.mmUnderlying0 = IERC20(s_underlying0).balanceOf(mm);
        snap.mmUnderlying1 = IERC20(s_underlying1).balanceOf(mm);
        for (uint256 i = 0; i < lanes.length; ++i) {
            snap.mmLccBalances[i] = IERC20(lanes[i]).balanceOf(mm);
            snap.managerLccBalances[i] = IERC20(lanes[i]).balanceOf(address(s_mmpm));
        }

        snap.posA = _capturePositionState(s_commitA);
        snap.posB = _capturePositionState(s_commitB);
        snap.posC = _capturePositionState(s_commitC);
        snap.posD = _capturePositionState(s_commitD);

        snap.digestA = _commitAllPositionsDigest(s_commitA);
        snap.digestB = _commitAllPositionsDigest(s_commitB);
        snap.digestC = _commitAllPositionsDigest(s_commitC);
        snap.digestD = _commitAllPositionsDigest(s_commitD);

        (snap.poolTotalSettled0[0], snap.poolTotalSettled1[0]) = vts.getPoolTotalSettled(s_keyA.toId());
        (snap.poolTotalSettled0[1], snap.poolTotalSettled1[1]) = vts.getPoolTotalSettled(s_keyB.toId());
        (snap.poolTotalSettled0[2], snap.poolTotalSettled1[2]) = vts.getPoolTotalSettled(s_keyC.toId());
        (snap.poolTotalSettled0[3], snap.poolTotalSettled1[3]) = vts.getPoolTotalSettled(s_keyD.toId());
        (snap.poolDeficitPrincipal0[0], snap.poolDeficitPrincipal1[0]) =
            vts.getPoolTotalDeficitPrincipal(s_keyA.toId());
        (snap.poolDeficitPrincipal0[1], snap.poolDeficitPrincipal1[1]) =
            vts.getPoolTotalDeficitPrincipal(s_keyB.toId());
        (snap.poolDeficitPrincipal0[2], snap.poolDeficitPrincipal1[2]) =
            vts.getPoolTotalDeficitPrincipal(s_keyC.toId());
        (snap.poolDeficitPrincipal0[3], snap.poolDeficitPrincipal1[3]) =
            vts.getPoolTotalDeficitPrincipal(s_keyD.toId());

        (snap.protocolFee0[0], snap.protocolFee1[0]) = vts.getProtocolFeeAccrued(s_keyA.toId());
        (snap.protocolFee0[1], snap.protocolFee1[1]) = vts.getProtocolFeeAccrued(s_keyB.toId());
        (snap.protocolFee0[2], snap.protocolFee1[2]) = vts.getProtocolFeeAccrued(s_keyC.toId());
        (snap.protocolFee0[3], snap.protocolFee1[3]) = vts.getProtocolFeeAccrued(s_keyD.toId());
    }

    function _assertPositionStateEq(DurablePositionState memory lhs, DurablePositionState memory rhs, string memory label)
        internal
        pure
    {
        require(lhs.owner == rhs.owner, string.concat(label, ": owner mismatch"));
        require(lhs.poolId == rhs.poolId, string.concat(label, ": poolId mismatch"));
        require(lhs.commitId == rhs.commitId, string.concat(label, ": commitId mismatch"));
        require(lhs.tickLower == rhs.tickLower, string.concat(label, ": tickLower mismatch"));
        require(lhs.tickUpper == rhs.tickUpper, string.concat(label, ": tickUpper mismatch"));
        require(lhs.liquidity == rhs.liquidity, string.concat(label, ": liquidity mismatch"));
        require(lhs.isActive == rhs.isActive, string.concat(label, ": isActive mismatch"));
        require(lhs.salt == rhs.salt, string.concat(label, ": salt mismatch"));
        require(lhs.openMask == rhs.openMask, string.concat(label, ": openMask mismatch"));
        require(lhs.openSince0 == rhs.openSince0, string.concat(label, ": openSince0 mismatch"));
        require(lhs.openSince1 == rhs.openSince1, string.concat(label, ": openSince1 mismatch"));
        require(
            lhs.gracePeriodExtension0 == rhs.gracePeriodExtension0, string.concat(label, ": gracePeriodExtension0 mismatch")
        );
        require(
            lhs.gracePeriodExtension1 == rhs.gracePeriodExtension1, string.concat(label, ": gracePeriodExtension1 mismatch")
        );
        require(lhs.positionId == rhs.positionId, string.concat(label, ": positionId mismatch"));
        require(lhs.settled0 == rhs.settled0, string.concat(label, ": settled0 mismatch"));
        require(lhs.settled1 == rhs.settled1, string.concat(label, ": settled1 mismatch"));
        require(lhs.positionCount == rhs.positionCount, string.concat(label, ": positionCount mismatch"));
        require(lhs.activePositionCount == rhs.activePositionCount, string.concat(label, ": activePositionCount mismatch"));
        require(lhs.inactiveRemnantCount == rhs.inactiveRemnantCount, string.concat(label, ": inactiveRemnantCount mismatch"));
        require(lhs.tokenOwner == rhs.tokenOwner, string.concat(label, ": tokenOwner mismatch"));
    }

    function _assertSnapshotsEq(DurableSnapshot memory staged, DurableSnapshot memory compacted) internal pure {
        require(staged.mmUnderlying0 == compacted.mmUnderlying0, "diff: mm underlying0 mismatch");
        require(staged.mmUnderlying1 == compacted.mmUnderlying1, "diff: mm underlying1 mismatch");
        for (uint256 i = 0; i < staged.mmLccBalances.length; ++i) {
            require(staged.mmLccBalances[i] == compacted.mmLccBalances[i], "diff: mm lcc balance mismatch");
            require(staged.managerLccBalances[i] == compacted.managerLccBalances[i], "diff: manager lcc balance mismatch");
        }
        _assertPositionStateEq(staged.posA, compacted.posA, "posA");
        _assertPositionStateEq(staged.posB, compacted.posB, "posB");
        _assertPositionStateEq(staged.posC, compacted.posC, "posC");
        _assertPositionStateEq(staged.posD, compacted.posD, "posD");
        require(staged.digestA == compacted.digestA, "diff: commit digest A mismatch");
        require(staged.digestB == compacted.digestB, "diff: commit digest B mismatch");
        require(staged.digestC == compacted.digestC, "diff: commit digest C mismatch");
        require(staged.digestD == compacted.digestD, "diff: commit digest D mismatch");
        for (uint256 p = 0; p < 4; ++p) {
            require(staged.poolTotalSettled0[p] == compacted.poolTotalSettled0[p], "diff: poolTotalSettled0 mismatch");
            require(staged.poolTotalSettled1[p] == compacted.poolTotalSettled1[p], "diff: poolTotalSettled1 mismatch");
            require(
                staged.poolDeficitPrincipal0[p] == compacted.poolDeficitPrincipal0[p],
                "diff: poolDeficitPrincipal0 mismatch"
            );
            require(
                staged.poolDeficitPrincipal1[p] == compacted.poolDeficitPrincipal1[p],
                "diff: poolDeficitPrincipal1 mismatch"
            );
        }
        for (uint256 j = 0; j < staged.protocolFee0.length; ++j) {
            require(staged.protocolFee0[j] == compacted.protocolFee0[j], "diff: protocolFee0 mismatch");
            require(staged.protocolFee1[j] == compacted.protocolFee1[j], "diff: protocolFee1 mismatch");
        }
    }

    function _positionStateFingerprint(DurablePositionState memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(p));
    }

    function _assertPositionStateChanged(DurablePositionState memory prev, DurablePositionState memory curr, string memory label)
        internal
        pure
    {
        require(
            _positionStateFingerprint(prev) != _positionStateFingerprint(curr),
            string.concat(label, ": expected durable position change")
        );
    }

    function _assertMarketsUnchanged(
        DurableSnapshot memory prev,
        DurableSnapshot memory curr,
        bool unchangedA,
        bool unchangedB,
        bool unchangedC,
        bool unchangedD
    ) internal pure {
        if (unchangedA) {
            _assertPositionStateEq(prev.posA, curr.posA, "stage checkpoint: posA should be unchanged");
            require(prev.digestA == curr.digestA, "stage checkpoint: digestA should be unchanged");
        }
        if (unchangedB) {
            _assertPositionStateEq(prev.posB, curr.posB, "stage checkpoint: posB should be unchanged");
            require(prev.digestB == curr.digestB, "stage checkpoint: digestB should be unchanged");
        }
        if (unchangedC) {
            _assertPositionStateEq(prev.posC, curr.posC, "stage checkpoint: posC should be unchanged");
            require(prev.digestC == curr.digestC, "stage checkpoint: digestC should be unchanged");
        }
        if (unchangedD) {
            _assertPositionStateEq(prev.posD, curr.posD, "stage checkpoint: posD should be unchanged");
            require(prev.digestD == curr.digestD, "stage checkpoint: digestD should be unchanged");
        }
    }

    function _assertProtocolFeesUnchangedUnless(
        DurableSnapshot memory prev,
        DurableSnapshot memory curr,
        bool poolA,
        bool poolB,
        bool poolC,
        bool poolD
    ) internal pure {
        if (poolA) {
            require(prev.protocolFee0[0] == curr.protocolFee0[0], "stage: pool A protocolFee0 unexpected change");
            require(prev.protocolFee1[0] == curr.protocolFee1[0], "stage: pool A protocolFee1 unexpected change");
        }
        if (poolB) {
            require(prev.protocolFee0[1] == curr.protocolFee0[1], "stage: pool B protocolFee0 unexpected change");
            require(prev.protocolFee1[1] == curr.protocolFee1[1], "stage: pool B protocolFee1 unexpected change");
        }
        if (poolC) {
            require(prev.protocolFee0[2] == curr.protocolFee0[2], "stage: pool C protocolFee0 unexpected change");
            require(prev.protocolFee1[2] == curr.protocolFee1[2], "stage: pool C protocolFee1 unexpected change");
        }
        if (poolD) {
            require(prev.protocolFee0[3] == curr.protocolFee0[3], "stage: pool D protocolFee0 unexpected change");
            require(prev.protocolFee1[3] == curr.protocolFee1[3], "stage: pool D protocolFee1 unexpected change");
        }
    }

    function _assertAfterStageA(DurableSnapshot memory prev, DurableSnapshot memory curr) internal pure {
        require(curr.posA.liquidity < prev.posA.liquidity, "stageA: posA liquidity should decrease");
        require(curr.posB.positionCount > prev.posB.positionCount, "stageA: commit B should gain a position");
        _assertMarketsUnchanged(prev, curr, false, false, true, true);
        _assertProtocolFeesUnchangedUnless(prev, curr, false, false, true, true);
    }

    function _assertAfterStageB(DurableSnapshot memory prev, DurableSnapshot memory curr) internal pure {
        _assertPositionStateChanged(prev.posB, curr.posB, "stageB: posB");
        _assertMarketsUnchanged(prev, curr, true, false, true, true);
        _assertProtocolFeesUnchangedUnless(prev, curr, true, false, true, true);
    }

    function _assertAfterStageC(DurableSnapshot memory prev, DurableSnapshot memory curr) internal pure {
        _assertPositionStateChanged(prev.posB, curr.posB, "stageC: posB");
        _assertPositionStateChanged(prev.posC, curr.posC, "stageC: posC");
        _assertMarketsUnchanged(prev, curr, true, false, false, true);
        _assertProtocolFeesUnchangedUnless(prev, curr, true, false, false, true);
    }

    function _assertAfterStageD(DurableSnapshot memory prev, DurableSnapshot memory curr) internal pure {
        _assertPositionStateChanged(prev.posC, curr.posC, "stageD: posC");
        require(curr.posD.positionCount > prev.posD.positionCount, "stageD: commit D should gain a position");
        _assertMarketsUnchanged(prev, curr, true, true, false, false);
        _assertProtocolFeesUnchangedUnless(prev, curr, true, true, false, false);
    }

    function _assertAfterStageE(DurableSnapshot memory prev, DurableSnapshot memory curr) internal pure {
        _assertMarketsUnchanged(prev, curr, true, true, true, true);
        _assertProtocolFeesUnchangedUnless(prev, curr, true, true, true, true);
    }

    function _runScenario() internal {
        _initNetwork();
        uint256 mmPk = _loadMmPrivateKey();
        address mm = vm.addr(mmPk);
        _prepareCrossMarketBatch(mm, mmPk);

        uint256 stagedStartSnapshot = vm.snapshotState();
        _runCrossMarketStagedBatches(mm, mmPk);
        DurableSnapshot memory staged = _captureDurableSnapshot(mm);
        require(vm.revertToState(stagedStartSnapshot), "CrossMarket: failed to revert staged snapshot");

        _runCrossMarketAtomicBatch(mm, mmPk);
        console.log("OK: cross-market atomic batch");
        DurableSnapshot memory compacted = _captureDurableSnapshot(mm);
        _assertSnapshotsEq(staged, compacted);
        console.log("OK: staged and compacted outcomes match");
    }

    /// @notice Entrypoint for `forge script`: deploy stack, run cross-market scenario, assert postconditions.
    function run() external {
        console.log("=== E2E: CrossMarketDeltaRegression ===");
        _runScenario();
        console.log("OK: CrossMarketDeltaRegression complete");
    }
}

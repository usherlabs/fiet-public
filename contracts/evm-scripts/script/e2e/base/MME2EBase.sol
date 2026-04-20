// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";

import {E2EBase} from "./E2EBase.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
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
import {PositionId} from "src/types/Position.sol";
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
        IERC20(m.underlying0).approve(address(mmpm), settle0);
        IERC20(m.underlying1).approve(address(mmpm), settle1);

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

        uint256 fund0 = d0 > 0 ? uint256(int256(type(int128).max)) : 0;
        uint256 fund1 = d1 > 0 ? uint256(int256(type(int128).max)) : 0;

        vm.startBroadcast(mmPk);
        {
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));

            if (fund0 > 0) {
                Token(m.underlying0).mint(mm, fund0);
                IERC20(m.underlying0).approve(address(mmpm), fund0);
            }
            if (fund1 > 0) {
                Token(m.underlying1).mint(mm, fund1);
                IERC20(m.underlying1).approve(address(mmpm), fund1);
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
        PoolKey memory corePoolKey = _corePoolKey(m);

        uint256 cap = maxIterations == 0 ? 32 : maxIterations;

        for (uint256 i = 0; i < cap; i++) {
            (uint256 eff0Before, uint256 eff1Before) = _getEffectiveSettledPair(vts, commitId, positionIndex);
            if (eff0Before == 0 && eff1Before == 0) {
                return;
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
            bool progressed = eff0After < eff0Before || eff1After < eff1Before;
            if (!progressed) {
                revert("e2e: inactive surplus settle made no progress (check vault liquidity / queue)");
            }
        }

        (uint256 left0, uint256 left1) = _getEffectiveSettledPair(vts, commitId, positionIndex);
        require(left0 == 0 && left1 == 0, "e2e: inactive economic remnant remains after max drain iterations");
    }

    /// @dev Burn, settle-from-deltas, optionally drain inactive surplus on index `positionIndex`, decommit, and sweep LCC credits.
    function _burnDecommitAndTakeAllLccs(
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

        _drainInactivePositionSurplus(m, mmPk, commitId, positionIndex, 32);

        vm.startBroadcast(mmPk);
        {
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
            bytes memory actions =
                abi.encodePacked(bytes1(uint8(MMActions.DECOMMIT_SIGNAL)), bytes1(uint8(MMActions.TAKE)), bytes1(uint8(MMActions.TAKE)));
            bytes[] memory params = new bytes[](3);
            params[0] = abi.encode(commitId);
            params[1] = abi.encode(corePoolKey.currency0, mm, 0);
            params[2] = abi.encode(corePoolKey.currency1, mm, 0);
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();

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

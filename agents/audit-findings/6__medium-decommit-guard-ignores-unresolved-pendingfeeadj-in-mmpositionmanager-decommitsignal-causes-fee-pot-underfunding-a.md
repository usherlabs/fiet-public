[Medium] Decommit guard ignores unresolved pendingFeeAdj in MMPositionManager._decommitSignal causes fee pot underfunding and stranded bonuses

# Description

[MMPositionManager._decommitSignal allows burning a commitment NFT](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/MMPositionManager.sol#L337-L361) once there are no active positions and no inactive positions with live settled amounts, but it does not ensure per-position [pendingFeeAdj](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/types/VTS.sol#L175-L183) is zero. Since fee materialization runs only during modify-liquidity touches, burning the NFT makes those paths unreachable, leaving positive slashes uncollected into the slashed pot or negative bonuses unpaid to the user.

Per-position fee state is tracked in [PositionAccounting.pendingFeeAdj (+slash, -bonus)](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/types/VTS.sol#L175-L183). VTS fee materialization (positive funding to the slashed pot and negative draining for bonuses) only occurs in [VTSFeeLib._processPositionFees](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSFeeLib.sol#L553-L571), which is executed from [VTSPositionLib.touchPosition during modify-liquidity](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSPositionLib.sol#L1196-L1202). [MMPositionManager._decommitSignal permits decommit when (activePositionCount == 0) and (inactiveRemnantCount == 0)](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/MMPositionManager.sol#L337-L361), where inactiveRemnantCount counts only inactive positions with non-zero live pa.settled. It ignores pendingFeeAdj. After decommit, all MM modify-liquidity paths [require assertApprovedOrOwner(tokenId)](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/MMPositionActionsImpl.sol#L542) and become unreachable, while [settlePositionGrowths](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/VTSOrchestrator.sol#L511-L526) and onMMSettle do not materialize pendingFeeAdj. Thus, a position may close with zero settled and still have non-zero pendingFeeAdj that can never be finalized: positive pending slashes evade funding the shared slashed pot; negative pending bonuses remain stranded and never paid to the user.

# Severity

**Impact Explanation:** [Medium] The issue causes direct, material loss of yield/fees: positive slashes that should fund the shared pot remain uncollected, and negative bonuses owed to users remain unpaid. There is no direct principal loss or freezing of funds.

**Likelihood Explanation:** [Medium] Exploitation requires feasible but non-trivial conditions: accumulating non-zero pendingFeeAdj at close, avoiding intervening touches (e.g., increases that would fully materialize positives), and timing the final decrease so feesAccrued caps do not clear all positives. These constraints are realistic but not guaranteed in every case.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Malicious MM times final remove-liquidity to leave excess positive pendingFeeAdj (capped materialization due to small feesAccrued), clamps settled to zero, and decommits. After NFT burn, no fee-materialization path is reachable, so the slashed pot is underfunded by the orphaned positive pending.
#### Preconditions / Assumptions
- (a). There exists an MM commitment (tokenId) with at least one associated MM position.
- (b). The position has accumulated positive pendingFeeAdj (e.g., via coverage burn pipeline) prior to final closure.
- (c). No subsequent add-liquidity touches occur that would fully materialize positive pending; the attacker times the final decrease so feesAccrued is small, capping same-touch materialization.
- (d). Final remove-liquidity and clamp leave the position inactive with pa.settled == 0, enabling decommit.

### Scenario 2.
An honest MM accumulates negative pendingFeeAdj (bonus) when the slashed pot is low. They later remove liquidity to zero (no live settled) and decommit. With the NFT burned, fee materialization can no longer run, so the user’s accrued bonus remains permanently unpaid.
#### Preconditions / Assumptions
- (a). The position has queued negative pendingFeeAdj (bonus) from prior touches where the slashed pot was insufficient to fully materialize it.
- (b). Final remove-liquidity leaves the position inactive with pa.settled == 0, enabling decommit.
- (c). The MM decommits before any future touch with a sufficiently funded pot could materialize the bonus.

### Scenario 3.
Across many commitments, MMs decommit with non-zero pendingFeeAdj (both positive and negative). Because post-decommit fee materialization is impossible, the slashed pot is systematically underfunded and many accrued bonuses remain unmaterialized, causing persistent fee/yield misallocation.
#### Preconditions / Assumptions
- (a). Multiple MMs/positions across the pool accumulate non-zero pendingFeeAdj near closure.
- (b). They decommit with positions inactive and zero settled, while pendingFeeAdj remains non-zero.
- (c). No post-decommit mechanism exists to finalize pendingFeeAdj.

# Proposed fix

## MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/MMPositionManager.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {ERC721Permit_v4} from "v4-periphery/src/base/ERC721Permit_v4.sol";
 import {ReentrancyLock} from "v4-periphery/src/base/ReentrancyLock.sol";
 import {Multicall_v4} from "v4-periphery/src/base/Multicall_v4.sol";
 import {BaseActionsRouter} from "v4-periphery/src/base/BaseActionsRouter.sol";
 import {FietNativeWrapper} from "./modules/NativeWrapper.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 import {PositionId, Position} from "./types/Position.sol";
 import {LiquiditySignal} from "./types/Commit.sol";
 import {MarketMaker} from "./libraries/MarketMaker.sol";
 import {ICommitmentDescriptor} from "./interfaces/ICommitmentDescriptor.sol";
 import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
 import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
 import {PositionManagerQueueCustodian} from "./modules/PositionManagerQueueCustodian.sol";
 import {PositionManagerEntrypoint} from "./modules/PositionManagerEntrypoint.sol";
 import {Permit2Forwarder} from "v4-periphery/src/base/Permit2Forwarder.sol";
 import {MMActions} from "./libraries/MMActions.sol";
 import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
 import {MMHelpers} from "./libraries/MMHelpers.sol";
 import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {IEndpointUnwrapAdmission} from "./interfaces/IEndpointUnwrapAdmission.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
 
 /// @title MMPositionManager
 /// @notice Entry point for VRL commitment position management
 /// @dev Handles commitment lifecycle (ERC721) and utility operations locally
 /// @dev Delegates position operations to MMPMActionsImpl via delegatecall
 contract MMPositionManager is
     ERC721Permit_v4,
     IMMPositionManager,
     IEndpointUnwrapAdmission,
     ReentrancyLock,
     Multicall_v4,
     Permit2Forwarder,
     BaseActionsRouter,
     FietNativeWrapper,
     PositionManagerEntrypoint,
     PositionManagerQueueCustodian
 {
     /// @dev Aggregates constructor dependencies so unoptimised builds avoid stack-too-deep in the inheritance init list.
     struct MMPositionManagerInit {
         IPoolManager poolManager;
         address marketFactory;
         address vtsOrchestrator;
         address canonicalCustody;
         address descriptor;
         IWETH9 weth9;
         IAllowanceTransfer permit2;
         address actionsImpl;
         address queueCustodianAddr;
     }
 
     using MMCalldataDecoder for bytes;
     using CurrencyTransfer for Currency;
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Events
     // ═══════════════════════════════════════════════════════════════════════════
 
     event SignalCommitted(uint256 tokenId);
     event SignalDecommitted(uint256 tokenId, uint256 positionCount);
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Immutables
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice The implementation contract for position operations
     address public immutable commitmentDescriptor;
     /// @notice Shared custodian that holds queued MM-backed LCC by commit bucket
     IMMQueueCustodian public immutable queueCustodian;
 
     /// @dev Custody bucket for `UNWRAP_LCC` shortfalls: not tied to a commitment NFT (`tokenId == 0` matches
     ///      `COLLECT_AVAILABLE_LIQUIDITY` utility collects).
     ///
     ///      `UNWRAP_LCC` forwards the LCC backing each newly queued shortfall from this contract into the queue
     ///      custodian (`_forwardUnwrapQueuedLccToCustodian`), so physical LCC tracks the Hub obligation for that
     ///      beneficiary. The Hub queue and custodian are separate ledgers: if `settleQueue[lcc][beneficiary]` is later
     ///      annulled by other LCC flows (e.g. LCC-02 `annulSettlementBeforeTransfer` on a different transfer), the Hub
     ///      obligation can drop while utility custody still holds the prior slice. The beneficiary (batch locker)
     ///      operating through MMPM is then entitled to receive that mismatch as LCC: the delta
     ///      `custodied - hubQueued` is released to them in `_reconcileUtilityCustodyWithHubQueue` on the next
     ///      utility `UNWRAP_LCC` or utility collect (`tokenId == 0`). Commit buckets (`tokenId > 0`) are unchanged.
     ///      Unwrap headroom and post-transfer queue snapshots are handled separately (`LiquidityHub`
     ///      `_unwrapEffectiveFromBalance`, `_unwrapLccFromUser`).
     uint256 private constant _UNWRAP_QUEUE_CUSTODY_TOKEN_ID = 0;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Constructor
     // ═══════════════════════════════════════════════════════════════════════════
 
     constructor(MMPositionManagerInit memory p)
         ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
         BaseActionsRouter(p.poolManager)
         Permit2Forwarder(p.permit2)
         FietNativeWrapper(p.weth9)
         PositionManagerEntrypoint(p.marketFactory, p.vtsOrchestrator, p.canonicalCustody, p.actionsImpl)
     {
         if (p.queueCustodianAddr == address(0) || p.queueCustodianAddr.code.length == 0) {
             revert Errors.InvalidAddress(p.queueCustodianAddr);
         }
         commitmentDescriptor = p.descriptor;
         queueCustodian = IMMQueueCustodian(p.queueCustodianAddr);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Modifiers
     // ═══════════════════════════════════════════════════════════════════════════
 
     modifier checkDeadline(uint256 deadline) {
         _checkDeadline(deadline);
         _;
     }
 
     function _checkDeadline(uint256 deadline) internal view {
         if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);
     }
 
     /// @notice Requires PoolManager to be locked (not within an active batch)
     modifier onlyIfPoolManagerLocked() {
         _onlyIfPoolManagerLocked();
         _;
     }
 
     function _onlyIfPoolManagerLocked() internal view {
         if (poolManager.isUnlocked()) revert Errors.PoolManagerMustBeLocked();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // BaseActionsRouter Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc BaseActionsRouter
     function msgSender() public view override(BaseActionsRouter, PositionManagerBase) returns (address) {
         return _getLocker();
     }
 
     /// @inheritdoc PositionManagerQueueCustodian
     function _queueCustodian() internal view override(PositionManagerQueueCustodian) returns (IMMQueueCustodian) {
         return queueCustodian;
     }
 
     /// @inheritdoc IEndpointUnwrapAdmission
     function unwrapAdmissionCredit(address lcc, address beneficiary) external view returns (uint256) {
         return queueCustodian.queued(_UNWRAP_QUEUE_CUSTODY_TOKEN_ID, lcc, beneficiary);
     }
 
     /// @inheritdoc FietNativeWrapper
     function _canonicalMarketFactory() internal view override returns (IMarketFactory) {
         return marketFactory;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _liquidityHub() internal view override returns (ILiquidityHub) {
         return liquidityHub;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Entry Points with Hooks
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Executes a batch of liquidity modifications
     /// @dev Mirrors v4 PositionManager.modifyLiquidities
     function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
         external
         payable
         isNotLocked
         checkDeadline(deadline)
     {
         _beforeBatch();
         _executeActions(unlockData);
         _afterBatch();
     }
 
     /// @notice Executes actions without acquiring a new unlock
     /// @dev Mirrors v4 PositionManager.modifyLiquiditiesWithoutUnlock
     function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params)
         external
         payable
         isNotLocked
     {
         _beforeBatch();
         _executeActionsWithoutUnlock(actions, params);
         _afterBatch();
     }
 
     /// @notice Get the next token ID that will be assigned
     /// @dev Returns the next commit ID from VTSOrchestrator, matching Uniswap PositionManager interface
     /// @return The next token ID (will be assigned on next commitSignal call)
     function nextTokenId() public view returns (uint256) {
         return vtsOrchestrator.nextCommitId();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Action Routing (Comparison-Based)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles action execution with comparison-based routing
     /// @dev Actions <= SETTLE_POSITION_FROM_DELTAS delegate to impl (position operations)
     /// @dev Actions >= COMMIT_SIGNAL and < TAKE handled locally (commitments)
     /// @dev Actions >= TAKE handled locally (utilities)
     function _handleAction(uint256 action, bytes calldata params) internal virtual override {
         // Position actions (<= SETTLE_POSITION_FROM_DELTAS) → delegate to impl
         if (action <= MMActions.SETTLE_POSITION_FROM_DELTAS) {
             _delegateToImpl(abi.encodeWithSelector(IMMActionsImpl.handleAction.selector, action, params));
             return;
         }
 
         // Commitment actions (>= COMMIT_SIGNAL and < TAKE) → handle locally
         if (action >= MMActions.COMMIT_SIGNAL && action < MMActions.TAKE) {
             _handleCommitmentAction(action, params);
             return;
         }
 
         // Currency/utility actions (>= TAKE) → handle locally
         _handleUtilityAction(action, params);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Commitment Actions (ERC721 + Signal Management)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles commitment-level actions
     /// @param action The action code
     /// @param params The encoded parameters for the action
     function _handleCommitmentAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.COMMIT_SIGNAL) {
             (bytes calldata liquiditySignal, bytes calldata relayParams) = params.decodeCommitSignalParams();
             _commitSignal(liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.RENEW_SIGNAL) {
             (uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) =
                 params.decodeTokenIdAndBytes();
             _renewSignal(tokenId, liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.DECOMMIT_SIGNAL) {
             uint256 tokenId = params.decodeDecommitSignalParams();
             _decommitSignal(tokenId);
             return;
         }
         if (action == MMActions.CHECKPOINT) {
             (uint256 tokenId, uint256 positionIndex, bool withCommitment) = params.decodeCheckpointParams();
             _checkpoint(tokenId, positionIndex, withCommitment);
             return;
         }
         if (action == MMActions.EXTEND_GRACE_PERIOD) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint8 settlementTokenIndex,
                 uint32 verifierIndex,
                 bytes calldata settlementProof
             ) = params.decodeExtendGracePeriodParams();
             _extendGracePeriod(poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @notice Commits a liquidity signal and mints a commitment NFT
     /// @dev Fresh commit is owner-authenticated: VRL sees `signal.mmState.owner` as the proof principal.
     ///      Direct commit requires `msgSender() == mmState.owner` and mints the NFT to `mmState.owner`.
     ///      Relayed commit passes EIP-712 `RelayAuth.sender` as this `sender` (`address(0)` means `mmState.owner`; otherwise
     ///      must equal `msgSender()` here).
     /// @param liquiditySignal The ABI-encoded LiquiditySignal to verify and record
     /// @param relayParams Empty for direct commit; otherwise `(deadline, authNonce, authSig, sender)`.
     /// @return tokenId The commitment NFT id created
     function _commitSignal(bytes calldata liquiditySignal, bytes calldata relayParams)
         internal
         returns (uint256 tokenId)
     {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         address mmOwner = signal.mmState.owner;
 
         if (relayParams.length == 0) {
             if (msgSender() != mmOwner) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignal(marketFactory, liquiditySignal);
             _mint(mmOwner, tokenId);
         } else {
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address sender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address mintRecipient = sender == address(0) ? mmOwner : sender;
             if (msgSender() != mintRecipient) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignalRelayed(
                 marketFactory, liquiditySignal, deadline, authNonce, authSig, sender
             );
             _mint(mintRecipient, tokenId);
         }
         emit SignalCommitted(tokenId);
     }
 
     /// @notice Renews an existing signal with new parameters
     /// @dev Direct renew (no relay) requires the batch locker to equal `signal.mmState.advancer`, matching ordinary
     ///      non-seizing MM ops (`locker == advancer`). Relayed renew: EIP-712 `RelayAuth.sender` must be `address(0)`
     ///      (locker must still be advancer) or `signal.mmState.advancer`; the batch locker (`msgSender()`) must match
     ///      the signed sender when non-zero, or be the advancer when the signed sender is zero.
     /// @param tokenId The commitment NFT token ID
     /// @param liquiditySignal The new liquidity signal
     function _renewSignal(uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) internal {
         if (relayParams.length == 0) {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             if (msgSender() != signal.mmState.advancer) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignal(marketFactory, tokenId, liquiditySignal);
         } else {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address relaySender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address adv = signal.mmState.advancer;
             if (msgSender() != adv && msgSender() != relaySender) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignalRelayed(
                 marketFactory, tokenId, liquiditySignal, deadline, authNonce, authSig, relaySender
             );
         }
     }
 
     /// @notice Decommits a signal and burns the commitment NFT
     /// @param tokenId The commitment NFT token ID
     function _decommitSignal(uint256 tokenId) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
+        // TODO: Also require commit-level `pendingFeeAdjNonzeroCount == 0` (no unfinalized fees) before allowing decommit.
+        // Expose and check this via VTSOrchestrator once the counter is added and maintained in VTSFeeLib.
         // Check if commit has any active positions (burned positions are inactive)
         (,, uint256 positionCount, uint256 activePositionCount, uint256 inactiveRemnantCount) =
             vtsOrchestrator.getCommit(tokenId);
         if (activePositionCount > 0) {
             revert Errors.CommitNotEmpty(tokenId);
         }
         // Inactive positions may still hold withdrawable `pa.settled` (SETTLE-03); burning the NFT would strand it
         // because MM settlement paths require `assertApprovedOrOwner` against this tokenId. Tracked in O(1) via
         // `Commit.inactiveRemnantCount` (see VTSPositionLib._syncInactiveRemnantAfterActiveTransition /
         // `_syncInactiveRemnantAfterSettledPairChange`).
         if (inactiveRemnantCount > 0) {
             revert Errors.CommitNotDrained(tokenId);
         }
 
         _burn(tokenId);
         emit SignalDecommitted(tokenId, uint256(positionCount));
     }
 
     /// @notice Marks a checkpoint for a position, optionally running commitment backing checks
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function _checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) internal {
         vtsOrchestrator.checkpoint(tokenId, positionIndex, withCommitment);
     }
 
     /// @notice Extends grace period for a commitment via proof
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param settlementTokenIndex The settlement token index
     /// @param verifierIndex The verifier index
     /// @param settlementProof The settlement proof
     function _extendGracePeriod(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint8 settlementTokenIndex,
         uint32 verifierIndex,
         bytes calldata settlementProof
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         vtsOrchestrator.extendGracePeriod(
             marketFactory, poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof
         );
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Utility Actions (Currency Operations)
     // ═══════════════════════════════════════════════════════════════════════════
 
     function _handleUtilityAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.TAKE) {
             (Currency currency, address to, uint256 maxAmount) = params.decodeTakeParams();
             _take(currency, to, maxAmount);
             return;
         }
         if (action == MMActions.UNWRAP_LCC) {
             (address lccAddr, uint256 amount, address recipient, bool payerIsUser) = params.decodeUnwrapLccParams();
             address to = _resolveStrictRecipient(recipient);
             if (payerIsUser) {
                 _unwrapLccFromUser(lccAddr, to, amount);
             } else {
                 _unwrapLccFromDeltas(lccAddr, to, amount);
             }
             return;
         }
         if (action == MMActions.WRAP_NATIVE) {
             uint256 amount = params.decodeUint256();
             _wrapNative(amount);
             return;
         }
         if (action == MMActions.UNWRAP_NATIVE) {
             (uint256 amount, bool payerIsUser) = params.decodeUint256AndBool();
             _unwrapNative(amount, payerIsUser);
             return;
         }
         if (action == MMActions.COLLECT_AVAILABLE_LIQUIDITY) {
             (address lcc, uint256 tokenId, uint256 maxAmount) = params.decodeCollectLiquidityParams();
             _collectAvailableLiquidity(lcc, tokenId, maxAmount);
             return;
         }
         if (action == MMActions.SYNC) {
             Currency currency = params.decodeSyncParams();
             _sync(currency);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @dev UNWRAP_LCC payout may only go to the locker or MMPM; arbitrary third-party recipients are disallowed.
     function _resolveStrictRecipient(address recipient) internal view returns (address) {
         address to = _mapRecipient(recipient);
         if (to != msgSender() && to != address(this)) {
             revert Errors.NotApproved(to);
         }
         return to;
     }
 
     /// @dev Hub `unwrapTo`, measure incremental queue for `queueKey`, forward queued LCC to custodian when needed.
     ///      Caller must run `_reconcileUtilityCustodyWithHubQueue` first where required (before `transferFrom` on user path).
     function _unwrapToQueueForward(
         address lccAddr,
         Currency lccCurrency,
         address payoutTo,
         address queueKey,
         uint256 toUnwrap
     ) private {
         uint256 qBefore = liquidityHub.settleQueue(lccAddr, queueKey);
         liquidityHub.unwrapTo(lccAddr, payoutTo, queueKey, toUnwrap);
         uint256 queued = liquidityHub.settleQueue(lccAddr, queueKey) - qBefore;
         if (queued > 0) {
             _forwardUnwrapQueuedLccToCustodian(lccCurrency, queueKey, queued);
         }
     }
 
     /// @notice Unwraps LCC tokens to underlying asset using deltas (locker credit)
     /// @dev Native-backed LCC: Hub pays ETH to MMPM only (never direct to the locker during `unwrapTo`), so a payable
     ///      locker cannot re-enter between queue write and custody forward. The locker receives native credit and must
     ///      `TAKE(ADDRESS_ZERO, ...)` to withdraw ETH.
     function _unwrapLccFromDeltas(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         // Native: payout to MMPM first; ERC20: direct payout per `to`.
         address payoutTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? payoutTo.balance : IERC20(underlying).balanceOf(to);
         uint256 toUnwrap = vtsOrchestrator.take(lccCurrency, msgSender(), requested);
 
         if (toUnwrap > 0) {
             address queueTo = msgSender();
             _reconcileUtilityCustodyWithHubQueue(lccAddr, queueTo);
             _unwrapToQueueForward(lccAddr, lccCurrency, payoutTo, queueTo, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? payoutTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
 
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
     }
 
     /// @notice Unwraps LCC tokens to underlying asset by pulling from the locker/user
     /// @dev Native-backed LCC: Hub pays ETH to MMPM only; see `_unwrapLccFromDeltas` NatSpec.
     ///      Split into a private helper to avoid stack-too-deep in unoptimised builds.
     function _unwrapLccFromUser(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         address payer = msgSender();
         uint256 toUnwrap = lcc.balanceOf(payer);
         if (requested > 0) {
             toUnwrap = Math.min(toUnwrap, requested);
         }
 
         return _unwrapLccFromUserWithAmount(lccAddr, lccCurrency, to, payer, toUnwrap, isNativeUnderlying, underlying);
     }
 
     /// @dev Pull, unwrap-to-queue, and credit; isolated to keep `_unwrapLccFromUser` stack shallow.
     function _unwrapLccFromUserWithAmount(
         address lccAddr,
         Currency lccCurrency,
         address to,
         address payer,
         uint256 toUnwrap,
         bool isNativeUnderlying,
         address underlying
     ) private returns (uint256 unwrapped) {
         address payoutTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? payoutTo.balance : IERC20(underlying).balanceOf(to);
         if (toUnwrap > 0) {
             _reconcileUtilityCustodyWithHubQueue(lccAddr, payer);
             // Pull only from the locker/user (never arbitrary third parties).
             // Snapshot queue *after* transfer: non-protocol -> protocol triggers annulment of queued
             // settlement (LCC-02), so the baseline for this unwrap's incremental queue must be post-annul.
             lccCurrency.transferFrom(payer, address(this), toUnwrap);
             _unwrapToQueueForward(lccAddr, lccCurrency, payoutTo, payer, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? payoutTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
     }
 
     /// @notice Moves Hub-queued shortfall LCC off this contract into beneficiary-scoped custody so it is not FCFS
     ///         router dust (see `DELTA-02` / `HUB-02A` in `INVARIANTS.md`).
     /// @dev Caller must have already invoked `liquidityHub.unwrapTo`; `amount` is the incremental queue delta for
     ///      `beneficiary` on this unwrap. For `_unwrapLccFromUser`, the delta is measured from the queue state
     ///      after `transferFrom` (post-annul) through `unwrapTo`; for `_unwrapLccFromDeltas`, from immediately before
     ///      `unwrapTo` (no LCC transfer annul in between).
     ///
     ///      Because this forwards physical LCC into the custodian while `LiquidityHub` owns queue accounting, a later
     ///      annulment of `settleQueue` (from unrelated LCC transfers by the same beneficiary) does not automatically
     ///      pull LCC back out of the custodian. The beneficiary remains entitled to the resulting excess
     ///      (`custodied - live hubQueued`); see `_reconcileUtilityCustodyWithHubQueue`.
     function _forwardUnwrapQueuedLccToCustodian(Currency lccCurrency, address beneficiary, uint256 amount) private {
         if (amount == 0) return;
         if (beneficiary == address(0)) revert Errors.InvalidAddress(beneficiary);
 
         IMMQueueCustodian custodian = queueCustodian;
         address cust = address(custodian);
         if (cust == address(0) || cust == address(this)) return;
 
         uint256 bal = IERC20(Currency.unwrap(lccCurrency)).balanceOf(address(this));
         if (bal < amount) revert Errors.InsufficientBalance(bal, amount);
 
         lccCurrency.transfer(cust, amount);
         custodian.record(_UNWRAP_QUEUE_CUSTODY_TOKEN_ID, Currency.unwrap(lccCurrency), beneficiary, amount);
     }
 
     /// @notice If utility-bucket (`tokenId == 0`) custody exceeds the beneficiary's live Hub queue, release the excess
     ///         LCC to the beneficiary (scan #22 finding #3 narrowed).
     /// @dev `UNWRAP_LCC` had forwarded queued-backing LCC into the custodian; if `settleQueue` is later reduced
     ///      independently (annulment via other LCC movements), the custodian can still hold the full prior slice.
     ///      The beneficiary (batch locker) is entitled to that gap as LCC: we release `custodied - hubQueued`, i.e. the
     ///      amount that was annulled from the Hub queue without a matching decrement of utility custody. Commit-scoped
     ///      custody (`tokenId > 0`) is not touched. Called before utility `UNWRAP_LCC` and before
     ///      `COLLECT_AVAILABLE_LIQUIDITY` when `tokenId == 0`.
     function _reconcileUtilityCustodyWithHubQueue(address lccAddr, address beneficiary) private {
         if (beneficiary == address(0)) return;
         IMMQueueCustodian custodian = queueCustodian;
         address cust = address(custodian);
         if (cust == address(0) || cust == address(this)) return;
 
         uint256 hubQueued = liquidityHub.settleQueue(lccAddr, beneficiary);
         uint256 custodied = custodian.queued(_UNWRAP_QUEUE_CUSTODY_TOKEN_ID, lccAddr, beneficiary);
         if (custodied <= hubQueued) return;
 
         uint256 excess = custodied - hubQueued;
         custodian.release(_UNWRAP_QUEUE_CUSTODY_TOKEN_ID, lccAddr, beneficiary, excess);
     }
 
     /// @notice Collects available liquidity from settlement queue
     /// @dev Intersects three caps: caller's Hub queue, underlying reserve availability, and this caller's
     ///      beneficiary-scoped slice in the queue custodian for `tokenId`. Without the beneficiary key, a locker
     ///      with any queue could pair it with another party's commit custody bucket.
     ///
     ///      Intended model (queue-gated collect):
     ///      - This path exists to release custodied LCC and then call `processSettlementFor`, which burns the
     ///        caller's LCC and clears their Hub `settleQueue` entry. If `settleQueue(lcc, locker) == 0`, this
     ///        function is a no-op by design — e.g. some flows (including certain seizure shapes) may record LCC
     ///        in the custodian for the locker without creating a per-LCC queue entry; those are not settled here.
     ///      - Arbitrary `processSettlementFor` calls cannot drain another party's custody: settlement still
     ///        requires the recipient's market-derived LCC balance; beneficiary-scoped custody ensures collect
     ///        only debits the slice matching the caller's queue.
     /// @param lcc The LCC token address
     /// @param tokenId The commitment NFT token ID bucket to collect from
     /// @param maxAmount The maximum amount to collect
     function _collectAvailableLiquidity(address lcc, uint256 tokenId, uint256 maxAmount) internal {
         address locker = msgSender();
         if (tokenId == _UNWRAP_QUEUE_CUSTODY_TOKEN_ID) {
             _reconcileUtilityCustodyWithHubQueue(lcc, locker);
         }
         liquidityHub.settleFromCustodian(lcc, address(queueCustodian), tokenId, locker, maxAmount);
     }
 
     /// @notice Syncs currency balance as credit to delta
     /// @param currency The currency to sync
     /// @dev owner is always address(this) (MMPM) and target is always msgSender() (locker)
     function _sync(Currency currency) internal {
         // Native ETH sync must be source-aware (exact amount) and is handled by dedicated flows.
         if (currency == CurrencyLibrary.ADDRESS_ZERO) {
             revert Errors.InvalidAddress(address(0));
         }
         vtsOrchestrator.sync(marketFactory, currency, address(this), msgSender());
     }
 
     /// @notice Wraps native ETH to WETH
     /// @param amount The amount of ETH to wrap (0 for max available from deltas)
     function _wrapNative(uint256 amount) internal {
         uint256 takeAmount = vtsOrchestrator.take(CurrencyLibrary.ADDRESS_ZERO, msgSender(), amount);
         if (amount > 0 && amount > takeAmount) {
             revert Errors.InsufficientBalance(takeAmount, amount);
         } else if (amount == 0) {
             amount = takeAmount;
         }
         if (amount == 0) {
             return;
         }
 
         _wrap(amount);
         Currency weth = Currency.wrap(address(WETH9));
         _syncBalanceAsCredit(weth);
     }
 
     /// @notice Unwraps WETH to native ETH
     /// @param amount The amount of WETH to unwrap (0 for max)
     /// @param payerIsUser Whether the payer is the user (true) or deltas (false)
     function _unwrapNative(uint256 amount, bool payerIsUser) internal {
         Currency weth = Currency.wrap(address(WETH9));
         if (payerIsUser) {
             address payer = msgSender();
             if (amount == 0) {
                 amount = weth.balanceOf(payer);
             }
             // Use CurrencyTransfer with Permit2 fallback for user transfers
             weth.transferFrom(payer, address(this), amount);
         } else {
             uint256 takeAmount = vtsOrchestrator.take(weth, msgSender(), amount);
             if (amount > 0 && amount > takeAmount) {
                 revert Errors.InsufficientBalance(takeAmount, amount);
             } else if (amount == 0) {
                 amount = takeAmount;
             }
             if (amount == 0) {
                 return;
             }
         }
         _unwrap(amount);
         _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Returns the token URI for a given token id using the commitment descriptor contract
     function tokenURI(uint256 tokenId) public view override returns (string memory) {
         if (commitmentDescriptor == address(0)) {
             revert Errors.CommitmentDescriptorNotSet();
         }
         return ICommitmentDescriptor(commitmentDescriptor).tokenURI(tokenId);
     }
 
     /// @dev Overrides transferFrom to revert if pool manager is locked
     /// @dev Prevents transfers while an unlock session is active (mid-batch)
     function transferFrom(address from, address to, uint256 id) public virtual override onlyIfPoolManagerLocked {
         super.transferFrom(from, to, id);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // View Functions (delegate to impl via staticcall)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPosition(uint256 tokenId, uint256 positionIndex)
         external
         view
         returns (
             Position memory, /* position */
             PositionId /* positionId */
         )
     {
         return vtsOrchestrator.getPosition(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPositionId(uint256 tokenId, uint256 positionIndex) external view returns (PositionId) {
         return vtsOrchestrator.getPositionId(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     function commitOf(uint256 tokenId)
         external
         view
         returns (
             MarketMaker.State memory state,
             uint256 expiresAt,
             uint256 positionCount,
             uint256 activePositionCount,
             uint256 inactiveRemnantCount
         )
     {
         return vtsOrchestrator.getCommit(tokenId);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // No-Locking Checkpoint Functions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Marks a checkpoint for a single position, optionally running backing checks
     /// @param tokenId The ERC721 token id (commitment NFT id)
     /// @param positionIndex The index of the position within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) external onlyIfPoolManagerLocked {
         _checkpoint(tokenId, positionIndex, withCommitment);
     }
 }
```

## Commit.sol

File: `contracts/evm/src/types/Commit.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/types/Commit.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {MarketMaker} from "../libraries/MarketMaker.sol";
 import {PositionId} from "./Position.sol";
 
 /// The parameters of the proof to verify the state of the market maker
 struct LiquiditySignal {
     /// The nonce of the liquidity signal which should always be incrementing
     uint256 nonce;
     /// The hash of the root merkle tree
     bytes32 rootHash;
     /// The canister's signature of the root state hash
     bytes rootHashSignature;
     /// The merkle proof of mm state data we want to verify in the merkle tree
     bytes32[] merkleProof;
     /// The state of the market maker
     MarketMaker.State mmState;
     /// The signature of the state of the market maker
     bytes mmSignature;
 }
 
 /// @notice Core Commit struct for state management (Bunni-style)
 struct Commit {
     /// MarketMaker state
     MarketMaker.State mmState;
     /// @notice The only address allowed as VTS `owner` on the CoreHook MM path (`processPosition` router) for this commit.
     /// @dev Set once at commit creation from the actual `VTSOrchestrator` caller (e.g. `MMPositionManager`). This binds
     ///      MM liquidity operations to the integration surface that created the commit, so `factory.bounds(owner)` alone
     ///      cannot authorise a different bound endpoint to issue LCC or operate positions under another party's commit.
     ///      Renewals do not rotate this field (immutable binding). `address(0)` means legacy commits predating this field;
     ///      those retain the previous authorisation model (bounds + advancer locker only).
     address authorisedRelayer;
     /// Expiration timestamp
     uint256 expiresAt;
     /// Mapping of position index to PositionId (avoids arrays)
     mapping(uint256 => PositionId) positions;
     /// Count of positions (for management)
     uint256 positionCount;
     /// Count of active positions
     uint256 activePositionCount;
     /// Inactive positions that still hold live `pa.settled` (withdrawable via MM settle paths; blocks decommit)
     uint256 inactiveRemnantCount;
+    // TODO: Add `pendingFeeAdjNonzeroCount` (uint256) to gate decommit on no unfinalized fees (pendingFeeAdj == 0 for all positions).
 }
```

## VTSFeeLib.sol

File: `contracts/evm/src/libraries/VTSFeeLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSFeeLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
 import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
 import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
 
 import {
     VTSStorage,
     PositionAccounting,
     PoolAccounting,
     TokenPairUint,
     TokenPairInt,
     TokenPairLib
 } from "../types/VTS.sol";
 import {PositionId, Position} from "../types/Position.sol";
 import {LiquidityUtils} from "./LiquidityUtils.sol";
 
 /// @title VTSFeeLib
 /// @notice Fee processing, slashed pot management, and coverage burn logic for VTS
 /// @author Fiet Protocol
 library VTSFeeLib {
     using SafeCast for uint256;
     using SafeCast for int256;
     using TokenPairLib for TokenPairUint;
     using TokenPairLib for TokenPairInt;
 
     /// @dev Internal struct to keep fee-burn helper signatures below stack-too-deep thresholds.
     struct FeesBurnParams {
         PoolId poolId;
         uint8 deficitTokenIndex;
         uint8 feeTokenIndex;
         uint256 burnBase;
         uint128 positionLiquidity;
         uint256 outflowFloor;
         bool consumeResidualFeeBacking;
     }
 
     struct FeesBurnResolution {
         uint256 totalFees;
         uint256 bankedFees;
         uint256 ofDelta;
         uint256 snap;
     }
 
     struct FeesBurnComputation {
         uint256 freshFees;
         uint256 bankedFees;
         uint256 snap;
         uint256 ofDelta;
         uint256 totalFees;
         uint256 bps;
         uint256 consumedBurnBase;
         uint256 consumedTotalFees;
         uint256 feesBurn;
         uint256 consumedBankedFees;
         uint256 consumedFreshFees;
     }
 
     // --------------------------------------------------
     // Fee Adjustment Helpers
     // --------------------------------------------------
 
     /// @dev Queue a bonus for a single token using CISE (Coverage-Indexed Settled Exposure).
     /// @notice CISE replaces selfNet as the primary eligibility gate, fixing the commitmentMax clamp bug.
     ///         Positions accrue exposure when incrementCoverage is called, proportional to their settled liquidity.
     ///         CSI remaining-share factors are used for self-exclusion to ensure positions can receive bonuses
     ///         even after their contributed slashes have been distributed to others.
     /// @param pa The position accounting storage reference
     /// @param paPool The pool accounting storage reference
     /// @param feeTokenIndex The fee token index (0 or 1) - the pot from which bonus is allocated
     /// @param coverageTokenIndex The coverage token index (opposite of feeTokenIndex) - the token whose exposure is used
     /// @param ciseExposure The position's realised CISE exposure since last allocation (from coverageTokenIndex)
     /// @return allocated True iff a non-zero bonus was queued (i.e. pendingFeeAdj was decreased).
     function _queueBonusForToken(
         PositionAccounting storage pa,
         PoolAccounting storage paPool,
         uint8 feeTokenIndex,
         uint8 coverageTokenIndex,
         uint256 ciseExposure
     ) internal returns (bool allocated) {
         // CISE: Use exposure as eligibility gate instead of selfNet
         if (ciseExposure == 0) return false;
 
         // CSI: Sync remaining contribution shares before reading selfRemaining
         _syncFeesSharedRemainingForToken(pa, paPool, feeTokenIndex);
 
         // Bonuses are allocated only against the materialised slashed pot (positive `pendingFeeAdj` must be
         // materialised in `_processPositionFees` before this runs).
         uint256 pot = paPool.slashedPot.get(feeTokenIndex);
 
         // CSI: feesShared is stored as remaining self-contribution (not lifetime)
         uint256 selfRemaining = pa.feesShared.get(feeTokenIndex);
         uint256 potAvail = pot > selfRemaining ? (pot - selfRemaining) : 0;
 
         if (potAvail == 0) return false;
 
         // CISE: Denominator is the pool-wide allocatable coverage window, updated eagerly on `incrementCoverage`
         // and decremented on allocation; not lazily summed from per-touch position realisations. Coverage exercised
         // while `totalSettled == 0` is excluded upstream because no settled liquidity was live to earn that weight.
         uint256 totalExposure = paPool.totalCISEExposureSinceLastMod.get(coverageTokenIndex);
         if (totalExposure == 0) return false;
 
         // bonus = potAvail * ciseExposure / totalExposure (round up so dust does not strand eligible exposure)
         uint256 bonus = FullMath.mulDivRoundingUp(potAvail, ciseExposure, totalExposure);
         if (bonus > potAvail) bonus = potAvail;
         if (bonus == 0) return false;
 
         // CSI: Update the cumulative remaining-share factor for this epoch.
         // Note: Under consistent accounting, total remaining shares == current pot (pre-spend).
         if (pot > 0) _advanceFeesSharedFactor(paPool, feeTokenIndex, pot, bonus);
 
         // Queue negative pending (bonus increases payout at materialisation); `slashedPot` is drained when
         // negative `pendingFeeAdj` is materialised in `_finaliseNegativeFeeAdjustment`.
         int256 currentPending = pa.pendingFeeAdj.get(feeTokenIndex);
         pa.pendingFeeAdj.set(feeTokenIndex, currentPending - bonus.toInt256());
         return true;
     }
 
     /// @dev After bonus allocation, clear/decrement per-position and per-pool CISE windows so future allocations don't double-count.
     /// @param pa The position accounting storage reference
     /// @param paPool The pool accounting storage reference
     /// @param coverageTokenIndex The coverage token index - the token whose exposure was used for allocation
     /// @param ciseExposure The position's CISE exposure for the coverage token
     function _cleanupAfterAllocationForToken(
         PositionAccounting storage pa,
         PoolAccounting storage paPool,
         uint8 coverageTokenIndex,
         uint256 ciseExposure
     ) internal {
         if (ciseExposure == 0) return;
 
         // CISE: Clear position exposure window and decrement pool total
         uint256 curExposure = paPool.totalCISEExposureSinceLastMod.get(coverageTokenIndex);
         paPool.totalCISEExposureSinceLastMod
             .set(coverageTokenIndex, ciseExposure > curExposure ? 0 : (curExposure - ciseExposure));
         pa.ciseExposureSinceLastMod.set(coverageTokenIndex, 0);
     }
 
     // --------------------------------------------------
     // CSI Remaining-Factor Helpers
     // --------------------------------------------------
 
     /// @dev Sync a position's remaining feesShared (self-contribution still embedded in the pot)
     ///      against the pool remaining-share factor for the current spend epoch.
     /// @notice Must be called BEFORE incrementing feesShared (slash) or reading selfRemaining (bonus)
     /// @param pa The position accounting storage reference
     /// @param paPool The pool accounting storage reference
     /// @param tokenIndex The token index (0 or 1)
     function _syncFeesSharedRemainingForToken(
         PositionAccounting storage pa,
         PoolAccounting storage paPool,
         uint8 tokenIndex
     ) internal {
         uint256 epochNow = _currentFeesSharedEpoch(paPool, tokenIndex);
         if (epochNow == 0) return;
 
         uint256 epochLast = pa.feesSharedEpoch.get(tokenIndex);
         uint256 factorNow = paPool.feesSharedRemainingFactorX128.get(tokenIndex);
 
         if (epochLast != epochNow) {
             if (pa.feesShared.get(tokenIndex) != 0) {
                 pa.feesShared.set(tokenIndex, 0);
             }
             pa.feesSharedEpoch.set(tokenIndex, epochNow);
             pa.feesSharedRemainingFactorLastX128.set(tokenIndex, factorNow);
             return;
         }
 
         uint256 factorLast = pa.feesSharedRemainingFactorLastX128.get(tokenIndex);
         if (factorNow == factorLast) return;
 
         uint256 sharesRemaining = pa.feesShared.get(tokenIndex);
         if (sharesRemaining > 0) {
             uint256 updatedShares;
             if (factorLast == 0) {
                 // No spend had been realised against this position in the current epoch yet. A zero pool factor is still
                 // the identity state until the first bonus allocation stores a non-zero remaining-share factor.
                 // Keep remaining shares conservative for tiny balances so self-exclusion does not collapse early.
                 updatedShares = factorNow == 0
                     ? sharesRemaining
                     : FullMath.mulDivRoundingUp(sharesRemaining, factorNow, FixedPoint128.Q128);
             } else {
                 // Round up so partial spend does not floor tiny remaining self-contribution to zero.
                 updatedShares = factorNow == 0 ? 0 : FullMath.mulDivRoundingUp(sharesRemaining, factorNow, factorLast);
             }
 
             if (updatedShares != sharesRemaining) {
                 pa.feesShared.set(tokenIndex, updatedShares);
             }
         }
 
         pa.feesSharedEpoch.set(tokenIndex, epochNow);
         pa.feesSharedRemainingFactorLastX128.set(tokenIndex, factorNow);
     }
 
     function _currentFeesSharedEpoch(PoolAccounting storage paPool, uint8 tokenIndex)
         private
         view
         returns (uint256 epoch)
     {
         epoch = paPool.feesSharedEpoch.get(tokenIndex);
     }
 
     function _beginFeesSharedEpochIfNeeded(PoolAccounting storage paPool, uint8 tokenIndex) internal {
         uint256 epoch = paPool.feesSharedEpoch.get(tokenIndex);
         if (epoch == 0) {
             paPool.feesSharedEpoch.set(tokenIndex, 1);
             return;
         }
 
         uint256 factor = paPool.feesSharedRemainingFactorX128.get(tokenIndex);
         uint256 materialPot = paPool.slashedPot.get(tokenIndex);
         if (factor == 0 && materialPot == 0) {
             paPool.feesSharedEpoch.set(tokenIndex, epoch + 1);
         }
     }
 
     function _advanceFeesSharedFactor(PoolAccounting storage paPool, uint8 tokenIndex, uint256 pot, uint256 bonus)
         private
     {
         if (paPool.feesSharedEpoch.get(tokenIndex) == 0) {
             paPool.feesSharedEpoch.set(tokenIndex, 1);
         }
 
         uint256 currentFactor = paPool.feesSharedRemainingFactorX128.get(tokenIndex);
         uint256 factorBase = currentFactor == 0 ? FixedPoint128.Q128 : currentFactor;
         uint256 nextFactor = FullMath.mulDivRoundingUp(factorBase, pot - bonus, pot);
         paPool.feesSharedRemainingFactorX128.set(tokenIndex, nextFactor);
     }
 
     function _prepareFeeShareMint(PositionAccounting storage pa, PoolAccounting storage paPool, uint8 feeTokenIndex)
         internal
     {
         _beginFeesSharedEpochIfNeeded(paPool, feeTokenIndex);
         _syncFeesSharedRemainingForToken(pa, paPool, feeTokenIndex);
     }
 
     /// @notice Calculate fees and checkpoint snapshots for coverage burn
     /// @dev Extracted to keep position-side DICE orchestration small.
     function _calculateFeesBurn(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId,
         FeesBurnParams memory params
     ) internal returns (uint256, uint256, uint256, uint256) {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         FeesBurnComputation memory c;
 
         {
             Position memory pos = s.positions[positionId];
             (uint256 fg0, uint256 fg1) =
                 StateLibrary.getFeeGrowthInside(poolManager, params.poolId, pos.tickLower, pos.tickUpper);
             uint256 fg = params.feeTokenIndex == 0 ? fg0 : fg1;
 
             uint256 lastFeeGrowth = pa.feeGrowthInsideLast.get(params.feeTokenIndex);
             if (params.positionLiquidity > 0 && fg > lastFeeGrowth) {
                 c.freshFees = FullMath.mulDiv(fg - lastFeeGrowth, uint256(params.positionLiquidity), FixedPoint128.Q128);
             }
             if (params.consumeResidualFeeBacking) {
                 c.bankedFees = pa.pendingResidualFeeBacking.get(params.feeTokenIndex);
             }
         }
 
         uint256 cumulativeOutflows = pa.cumulativeOutflows.get(params.deficitTokenIndex);
         c.snap = pa.outflowsAtFeeSnap.get(params.deficitTokenIndex);
         if (params.outflowFloor > c.snap) {
             c.snap = params.outflowFloor;
         }
         c.ofDelta = cumulativeOutflows >= c.snap ? (cumulativeOutflows - c.snap) : 0;
 
         c.totalFees = c.freshFees + c.bankedFees;
         if (c.totalFees == 0 || c.ofDelta == 0) {
             return (0, 0, 0, 0);
         }
 
         c.bps = s.pools[params.poolId].vtsConfig.coverageFeeShare;
         if (c.bps == 0) {
             return (0, 0, 0, 0);
         }
         if (c.bps > LiquidityUtils.BPS_DENOMINATOR) {
             c.bps = LiquidityUtils.BPS_DENOMINATOR;
         }
 
         c.consumedBurnBase = params.burnBase <= c.ofDelta ? params.burnBase : c.ofDelta;
         c.consumedTotalFees = FullMath.mulDiv(c.totalFees, c.consumedBurnBase, c.ofDelta);
         c.feesBurn = FullMath.mulDiv(c.consumedTotalFees, c.bps, LiquidityUtils.BPS_DENOMINATOR);
         if (c.feesBurn == 0) {
             return (0, 0, 0, 0);
         }
 
         c.consumedBankedFees = c.consumedTotalFees <= c.bankedFees ? c.consumedTotalFees : c.bankedFees;
         c.consumedFreshFees = c.consumedTotalFees - c.consumedBankedFees;
         pa.outflowsAtFeeSnap.set(params.deficitTokenIndex, c.snap + c.consumedBurnBase);
 
         return (c.feesBurn, c.consumedBurnBase, c.consumedFreshFees, c.consumedBankedFees);
     }
 
     /// @notice Apply a precomputed burn base for a position and return the consumed outflow share
     function _applyBurnBase(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId,
         PoolId poolId,
         uint8 tokenIndex,
         uint256 burnBase,
         uint128 positionLiquidity,
         uint256 outflowFloor,
         bool consumeResidualFeeBacking
     ) internal returns (uint256 consumedBurnBase) {
         if (burnBase == 0) return 0;
 
         uint8 feeTokenIndex = tokenIndex == 0 ? 1 : 0;
         uint256 feesBurn;
         uint256 consumedFreshFees;
         uint256 consumedBankedFees;
         FeesBurnParams memory params = FeesBurnParams({
             poolId: poolId,
             deficitTokenIndex: tokenIndex,
             feeTokenIndex: feeTokenIndex,
             burnBase: burnBase,
             positionLiquidity: positionLiquidity,
             outflowFloor: outflowFloor,
             consumeResidualFeeBacking: consumeResidualFeeBacking
         });
         (feesBurn, consumedBurnBase, consumedFreshFees, consumedBankedFees) =
             _calculateFeesBurn(s, poolManager, positionId, params);
 
         if (feesBurn == 0) return 0;
 
         _finaliseBurnAccounting(
             s, positionId, poolId, feeTokenIndex, positionLiquidity, consumedFreshFees, consumedBankedFees, feesBurn
         );
     }
 
     function _finaliseBurnAccounting(
         VTSStorage storage s,
         PositionId positionId,
         PoolId poolId,
         uint8 feeTokenIndex,
         uint128 positionLiquidity,
         uint256 consumedFreshFees,
         uint256 consumedBankedFees,
         uint256 feesBurn
     ) private {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         if (consumedBankedFees > 0) {
             uint256 currentBacking = pa.pendingResidualFeeBacking.get(feeTokenIndex);
             pa.pendingResidualFeeBacking
                 .set(feeTokenIndex, consumedBankedFees > currentBacking ? 0 : (currentBacking - consumedBankedFees));
         }
 
         if (positionLiquidity > 0 && consumedFreshFees > 0) {
             uint256 liquidity = uint256(positionLiquidity);
             uint256 carryIn = pa.feeBurnGrowthRemainder.get(feeTokenIndex);
             (uint256 growthInc, uint256 newCarry) =
                 LiquidityUtils.feeBurnGrowthIncWithRemainder(consumedFreshFees, liquidity, carryIn);
             pa.feeBurnGrowthRemainder.set(feeTokenIndex, newCarry);
             pa.feeGrowthInsideLast.set(feeTokenIndex, pa.feeGrowthInsideLast.get(feeTokenIndex) + growthInc);
         }
 
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         _prepareFeeShareMint(pa, paPool, feeTokenIndex);
         pa.feesShared.set(feeTokenIndex, pa.feesShared.get(feeTokenIndex) + feesBurn);
+        // TODO: When updating pendingFeeAdj here, update the commit-level `pendingFeeAdjNonzeroCount` on zero-boundary crossings.
         pa.pendingFeeAdj.set(feeTokenIndex, pa.pendingFeeAdj.get(feeTokenIndex) + feesBurn.toInt256());
     }
 
     // --------------------------------------------------
     // CISE (Coverage-Indexed Settled Exposure) Helpers
     // --------------------------------------------------
 
     /// @notice Peek the current pending fee adjustments for a position without mutating state
     /// @param s The central VTS storage
     /// @param positionId The position ID
     /// @return adj0 The pending fee adjustment for token0 (+slash, -bonus)
     /// @return adj1 The pending fee adjustment for token1 (+slash, -bonus)
     function _peekFeeAdjustment(VTSStorage storage s, PositionId positionId)
         internal
         view
         returns (int256 adj0, int256 adj1)
     {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         adj0 = pa.pendingFeeAdj.token0;
         adj1 = pa.pendingFeeAdj.token1;
     }
 
     /// @notice Increase the slashed pot accounting for a pool/token
     /// @dev Only updates accounting state. Actual ERC6909 mint is handled by CoreHook.settleHookDeltasToPot
     /// @param s The central VTS storage
     /// @param poolId The pool ID
     /// @param tokenIndex The token index (0 or 1)
     /// @param amount The amount to fund
     function _fundFeePot(VTSStorage storage s, PoolId poolId, uint8 tokenIndex, uint256 amount) internal {
         if (amount == 0) return;
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         uint256 currentPot = paPool.slashedPot.get(tokenIndex);
         paPool.slashedPot.set(tokenIndex, currentPot + amount);
     }
 
     /// @notice Decrease the slashed pot accounting when settling bonuses
     /// @dev Only updates accounting state. Actual ERC6909 burn is handled by CoreHook.settleHookDeltasToPot
     /// @param s The central VTS storage
     /// @param poolId The pool ID
     /// @param tokenIndex The token index (0 or 1)
     /// @param amount The amount to drain
     function _drainFeePot(VTSStorage storage s, PoolId poolId, uint8 tokenIndex, uint256 amount) internal {
         if (amount == 0) return;
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         uint256 pot = paPool.slashedPot.get(tokenIndex);
         // Clamp to available pot to avoid underflow; caller must have already bounded the amount
         if (amount > pot) amount = pot;
         paPool.slashedPot.set(tokenIndex, pot - amount);
     }
 
     /// @notice Materialise positive `pendingFeeAdj` into `slashedPot` up to per-leg caps (SETTLE-03 on decreases).
     function _finalisePositiveFeeAdjustment(
         VTSStorage storage s,
         PositionId positionId,
         PoolId poolId,
         uint256 positiveCap0,
         uint256 positiveCap1
     ) internal returns (BalanceDelta adj) {
         (int256 pend0, int256 pend1) = _peekFeeAdjustment(s, positionId);
         int256 mat0 = 0;
         int256 mat1 = 0;
 
         if (pend0 > 0) {
             uint256 pendPos0 = uint256(pend0);
             uint256 pay0 = pendPos0 < positiveCap0 ? pendPos0 : positiveCap0;
             if (pay0 > 0) {
                 _fundFeePot(s, poolId, 0, pay0);
                 mat0 = pay0.toInt256();
             }
         }
 
         if (pend1 > 0) {
             uint256 pendPos1 = uint256(pend1);
             uint256 pay1 = pendPos1 < positiveCap1 ? pendPos1 : positiveCap1;
             if (pay1 > 0) {
                 _fundFeePot(s, poolId, 1, pay1);
                 mat1 = pay1.toInt256();
             }
         }
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
+        // TODO: After mutating pendingFeeAdj here, update commit-level `pendingFeeAdjNonzeroCount` on zero-boundary crossings.
+        // TODO: After mutating pendingFeeAdj here, update commit-level `pendingFeeAdjNonzeroCount` on zero-boundary crossings.
         pa.pendingFeeAdj.token0 = pend0 - mat0;
         pa.pendingFeeAdj.token1 = pend1 - mat1;
 
         adj = LiquidityUtils.safeToBalanceDelta(mat0, mat1);
     }
 
     /// @notice Materialise negative `pendingFeeAdj` by draining `slashedPot` (bonuses queued after positive phase).
     function _finaliseNegativeFeeAdjustment(VTSStorage storage s, PositionId positionId, PoolId poolId)
         internal
         returns (BalanceDelta adj)
     {
         (int256 pend0, int256 pend1) = _peekFeeAdjustment(s, positionId);
         int256 mat0 = 0;
         int256 mat1 = 0;
 
         if (pend0 < 0) {
             uint256 need0 = uint256(-pend0);
             PoolAccounting storage paPool = s.poolAccounting[poolId];
             uint256 pot0 = paPool.slashedPot.token0;
             uint256 pay0 = pot0 < need0 ? pot0 : need0;
             if (pay0 > 0) {
                 _drainFeePot(s, poolId, 0, pay0);
                 mat0 = -pay0.toInt256();
             }
         }
 
         if (pend1 < 0) {
             uint256 need1 = uint256(-pend1);
             PoolAccounting storage paPool = s.poolAccounting[poolId];
             uint256 pot1 = paPool.slashedPot.token1;
             uint256 pay1 = pot1 < need1 ? pot1 : need1;
             if (pay1 > 0) {
                 _drainFeePot(s, poolId, 1, pay1);
                 mat1 = -pay1.toInt256();
             }
         }
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         pa.pendingFeeAdj.token0 = pend0 - mat0;
         pa.pendingFeeAdj.token1 = pend1 - mat1;
 
         adj = LiquidityUtils.safeToBalanceDelta(mat0, mat1);
     }
 
     /// @notice Finalise pending fee adjustments with optional per-leg caps on positive slash materialisation
     /// @dev Positive pending adjustment (`pend > 0`) is materialised at most up to `positiveCap*` for each leg.
     ///      Any unmaterialised remainder stays queued in `pendingFeeAdj` for future touches.
     ///      Negative pending (`pend < 0`) bonus materialisation drains `slashedPot`.
     /// @dev Updates accounting state only. Actual ERC6909 mint/burn is handled by CoreHook.settleHookDeltasToPot.
     ///      Positive pending (`pend > 0`) materialises at most `positiveCap*` per leg; pass `type(uint256).max` on both
     ///      legs for uncapped behaviour. Any unmaterialised positive remainder stays in `pendingFeeAdj`.
     /// @dev Not used on the production fee-sharing path: `_processPositionFees` runs Phase 2 (bonus allocation)
     ///      between `_finalisePositiveFeeAdjustment` and `_finaliseNegativeFeeAdjustment`. Exposed for
     ///      `VTSFeeLibHarness` / unit tests that exercise positive+negative materialisation without Phase 2.
     /// @param s The central VTS storage
     /// @param positionId The position ID
     /// @param poolId The pool ID
     /// @return adj The materialised delta as BalanceDelta for the hook to apply this call only
     //#olympix-ignore-reentrancy
     function _finaliseFeeAdjustment(
         VTSStorage storage s,
         PositionId positionId,
         PoolId poolId,
         uint256 positiveCap0,
         uint256 positiveCap1
     ) internal returns (BalanceDelta adj) {
         BalanceDelta adjPos = _finalisePositiveFeeAdjustment(s, positionId, poolId, positiveCap0, positiveCap1);
         BalanceDelta adjNeg = _finaliseNegativeFeeAdjustment(s, positionId, poolId);
         return adjPos + adjNeg;
     }
 
     /// @notice Uncapped finalisation (`positiveCap* = max`).
     function _finaliseFeeAdjustment(VTSStorage storage s, PositionId positionId, PoolId poolId)
         internal
         returns (BalanceDelta adj)
     {
         return _finaliseFeeAdjustment(s, positionId, poolId, type(uint256).max, type(uint256).max);
     }
 
     /// @notice Consolidated fee processing for a position during modification (three phases)
     /// @dev Phase 1: materialise positive `pendingFeeAdj` into `slashedPot` (capped per leg on decreases).
     ///      Phase 2: allocate bonuses from the materialised pot via CISE/CSI (queues negative pending).
     ///      Phase 3: materialise negative pending by draining `slashedPot`.
     ///      Updates accounting state only. Actual ERC6909 mint/burn is handled by CoreHook.settleHookDeltasToPot.
     ///      Pass `type(uint256).max` for both caps for uncapped positive slash materialisation.
     /// @param s The central VTS storage
     /// @param positionId The position ID
     /// @return adj The materialised fee adjustment delta
     function _processPositionFees(
         VTSStorage storage s,
         PositionId positionId,
         uint256 positiveCap0,
         uint256 positiveCap1
     ) internal returns (BalanceDelta adj) {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
 
         // If fee sharing is disabled, skip processing (fees handled natively by Uniswap)
         if (!_isFeeSharingEnabled(s, poolId)) {
             return toBalanceDelta(0, 0);
         }
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         PoolAccounting storage paPool = s.poolAccounting[poolId];
 
         // Phase 1 — fund `slashedPot` from positive pending before bonus allocation.
         BalanceDelta adjPos = _finalisePositiveFeeAdjustment(s, positionId, poolId, positiveCap0, positiveCap1);
 
         // Read CISE exposure for bonus allocation
         // Note: Raw exposure values per coverage token
         uint256 ciseExposure0 = pa.ciseExposureSinceLastMod.token0;
         uint256 ciseExposure1 = pa.ciseExposureSinceLastMod.token1;
 
         // Phase 2 — queue bonuses using CISE exposure (coverage-indexed settled exposure)
         // Token direction mapping: fee pot in token T is funded by deficits in the opposite token.
         // - token0 pot ← token1 deficit coverage → use token1 exposure for token0 bonus
         // - token1 pot ← token0 deficit coverage → use token0 exposure for token1 bonus
         // This fixes the commitmentMax clamp bug where selfNet stays 0 for fully-settled positions
         bool allocated0 = _queueBonusForToken(pa, paPool, 0, 1, ciseExposure1);
         bool allocated1 = _queueBonusForToken(pa, paPool, 1, 0, ciseExposure0);
 
         // Banked exposure:
         // Only clear/decrement the windows if we actually queued a bonus for that token.
         // This ensures contributions remain eligible if potAvail was 0 at touch time.
         if (allocated0) _cleanupAfterAllocationForToken(pa, paPool, 1, ciseExposure1);
         if (allocated1) _cleanupAfterAllocationForToken(pa, paPool, 0, ciseExposure0);
 
         // Phase 3 — drain `slashedPot` for queued bonuses (and any other negative pending).
         BalanceDelta adjNeg = _finaliseNegativeFeeAdjustment(s, positionId, poolId);
         return adjPos + adjNeg;
     }
 
     /// @notice Uncapped fee processing (`positiveCap* = max`).
     function _processPositionFees(VTSStorage storage s, PositionId positionId) internal returns (BalanceDelta adj) {
         return _processPositionFees(s, positionId, type(uint256).max, type(uint256).max);
     }
 
     /// @dev Check if fee sharing is enabled for a pool
     function _isFeeSharingEnabled(VTSStorage storage s, PoolId p) internal view returns (bool) {
         return s.pools[p].vtsConfig.coverageFeeShare > 0;
     }
 
     // --------------------------------------------------
     // Residual / coverage burn orchestration (linked from VTSPositionLib)
     // --------------------------------------------------
 
     /// @dev Residual fee backing is episode-scoped: once the matching burn base is exhausted,
     ///      any leftover backing on the opposite fee lane must not survive into a later residual episode.
     function _clearResolvedResidualFeeBacking(PositionAccounting storage pa, uint8 deficitTokenIndex) internal {
         if (pa.pendingResidualBurnBase.get(deficitTokenIndex) != 0) return;
 
         uint8 feeTokenIndex = deficitTokenIndex == 0 ? 1 : 0;
         pa.pendingResidualFeeBacking.set(feeTokenIndex, 0);
     }
 
     /// @dev Shared residual-backing capture: banks `liquidityScale * (fg - feeGrowthInsideLast)` per fee lane when
     ///      `pendingResidualBurnBase` implies that lane. Uses `getPositionInfo` fee growth (position snapshot after
     ///      modifyLiquidity), which stays authoritative after full removes that clear ticks.
     /// @param advanceFeeGrowthCheckpoint If true (full deactivation), set `feeGrowthInsideLast` to `fg` whenever
     ///        `fg > last`. If false (partial decrease), leave `feeGrowthInsideLast` unchanged for surviving liquidity.
     function _accumulateResidualFeeBackingForLanes(
         PositionAccounting storage pa,
         uint256 fg0,
         uint256 fg1,
         bool needFeeToken0,
         bool needFeeToken1,
         uint256 liquidityScale,
         bool advanceFeeGrowthCheckpoint
     ) private {
         if (needFeeToken0) {
             uint256 last0 = pa.feeGrowthInsideLast.token0;
             if (fg0 > last0) {
                 uint256 backing0 = FullMath.mulDiv(fg0 - last0, liquidityScale, FixedPoint128.Q128);
                 if (backing0 > 0) pa.pendingResidualFeeBacking.token0 += backing0;
                 if (advanceFeeGrowthCheckpoint) pa.feeGrowthInsideLast.token0 = fg0;
             }
         }
 
         if (needFeeToken1) {
             uint256 last1 = pa.feeGrowthInsideLast.token1;
             if (fg1 > last1) {
                 uint256 backing1 = FullMath.mulDiv(fg1 - last1, liquidityScale, FixedPoint128.Q128);
                 if (backing1 > 0) pa.pendingResidualFeeBacking.token1 += backing1;
                 if (advanceFeeGrowthCheckpoint) pa.feeGrowthInsideLast.token1 = fg1;
             }
         }
     }
 
     /// @dev Loads pending-residual lanes, reads post-modify position fee growth from PoolManager, then banks backing.
     ///      Prefer `getPositionInfo` over range `getFeeGrowthInside` on full deactivation: after a full remove, Uniswap
     ///      may clear boundary ticks so range-based reads can be wrong; the position snapshot from `modifyLiquidity` is authoritative.
     function _captureResidualFeeBackingForLiquidityScale(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         uint128 liquidityScale,
         bool advanceFeeGrowthCheckpoint
     ) private {
         if (liquidityScale == 0) return;
 
         PositionAccounting storage pa = s.positionAccounting[id];
         bool needFeeToken0 = pa.pendingResidualBurnBase.token1 > 0;
         bool needFeeToken1 = pa.pendingResidualBurnBase.token0 > 0;
         if (!needFeeToken0 && !needFeeToken1) return;
 
         Position memory pos = s.positions[id];
         (, uint256 fg0, uint256 fg1) = StateLibrary.getPositionInfo(poolManager, pos.poolId, PositionId.unwrap(id));
 
         _accumulateResidualFeeBackingForLanes(
             pa, fg0, fg1, needFeeToken0, needFeeToken1, uint256(liquidityScale), advanceFeeGrowthCheckpoint
         );
     }
 
     /// @notice Freeze unresolved residual-burn fee backing before a position deactivates to zero liquidity.
     /// @dev Captures fee growth accrued up to the remove call on the fee token lanes needed by pending residual burn.
     function _captureResidualFeeBackingOnDeactivation(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         uint128 liquidityBeforeRemove
     ) internal {
         _captureResidualFeeBackingForLiquidityScale(s, poolManager, id, liquidityBeforeRemove, true);
     }
 
     /// @notice Bank fee-token backing for removed liquidity during a partial decrease while a residual episode is open.
     /// @dev Unlike full deactivation, does not advance `feeGrowthInsideLast`: remaining live liquidity keeps the same
     ///      baseline so `freshFees` on later burns still include its share of growth since the last checkpoint.
     function _captureResidualFeeBackingOnPartialDecrease(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         uint128 removedLiquidity
     ) internal {
         _captureResidualFeeBackingForLiquidityScale(s, poolManager, id, removedLiquidity, false);
     }
 
     /// @notice Apply banked residual-derived DICE burn against later outflow windows only
     function _applyBankedResidualBurn(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         PoolId p,
         uint8 tokenIndex,
         uint128 positionLiquidity
     ) internal {
         PositionAccounting storage pa = s.positionAccounting[id];
         uint256 pendingBurnBase = pa.pendingResidualBurnBase.get(tokenIndex);
         if (pendingBurnBase == 0) return;
 
         uint256 outflowFloor = pa.pendingResidualBurnOutflowsFloor.get(tokenIndex);
         uint256 consumedBurnBase =
             _applyBurnBase(s, poolManager, id, p, tokenIndex, pendingBurnBase, positionLiquidity, outflowFloor, true);
         if (consumedBurnBase > 0) {
             pa.pendingResidualBurnBase.set(tokenIndex, pendingBurnBase - consumedBurnBase);
             if (pendingBurnBase == consumedBurnBase) {
                 pa.pendingResidualBurnOutflowsFloor.set(tokenIndex, 0);
                 _clearResolvedResidualFeeBacking(pa, tokenIndex);
             }
         }
     }
 
     // --------------------------------------------------
     // DICE / CISE coverage settlement (linked from VTSPositionLib.settlePositionGrowths)
     // --------------------------------------------------
 
     /// @notice Flush any pending deficit-indexed coverage residual into the DICE index
     function _flushCoverageResidualIfNeeded(VTSStorage storage s, PoolId poolId, uint8 tokenIndex) internal {
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         uint256 residual = paPool.coverageResidualDICE.get(tokenIndex);
         uint256 principal = paPool.totalDeficitPrincipal.get(tokenIndex);
 
         if (residual > 0 && principal > 0) {
             uint256 deltaIndex = FullMath.mulDiv(residual, FixedPoint128.Q128, principal);
             uint256 currentIndex = paPool.coveragePerResidualDeficitIndexX128.get(tokenIndex);
             paPool.coveragePerResidualDeficitIndexX128.set(tokenIndex, currentIndex + deltaIndex);
             paPool.coverageResidualDICE.set(tokenIndex, 0);
         }
     }
 
     function _settleCISEForToken(PositionAccounting storage pa, PoolAccounting storage paPool, uint8 tokenIndex)
         internal
     {
         uint256 indexNow = paPool.coveragePerSettledIndexX128.get(tokenIndex);
         uint256 indexLast = pa.ciseIndexLastX128.get(tokenIndex);
 
         if (indexNow != indexLast) {
             pa.ciseIndexLastX128.set(tokenIndex, indexNow);
         }
 
         uint256 deltaIndex = indexNow - indexLast;
         if (deltaIndex > 0) {
             uint256 settled = pa.settled.get(tokenIndex);
             uint256 exposure = FullMath.mulDiv(settled, deltaIndex, FixedPoint128.Q128);
             if (exposure > 0) {
                 pa.ciseExposureSinceLastMod.set(tokenIndex, pa.ciseExposureSinceLastMod.get(tokenIndex) + exposure);
             }
         }
     }
 
     function _settleDICEForToken(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId,
         PoolId poolId,
         uint8 tokenIndex,
         uint128 liq
     ) internal {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         uint256 deficitPrincipal = pa.cumulativeDeficit.get(tokenIndex);
 
         _clearResolvedResidualFeeBacking(pa, tokenIndex);
 
         {
             uint256 residualIndexNow = s.poolAccounting[poolId].coveragePerResidualDeficitIndexX128.get(tokenIndex);
             uint256 residualIndexLast = pa.residualCoverageIndexLastX128.get(tokenIndex);
 
             if (residualIndexNow != residualIndexLast) {
                 pa.residualCoverageIndexLastX128.set(tokenIndex, residualIndexNow);
             }
 
             uint256 deltaResidualIndex = residualIndexNow - residualIndexLast;
             if (deltaResidualIndex > 0 && deficitPrincipal > 0) {
                 uint256 residualCov = FullMath.mulDiv(deficitPrincipal, deltaResidualIndex, FixedPoint128.Q128);
                 if (residualCov > 0) {
                     pa.pendingResidualBurnBase.set(tokenIndex, pa.pendingResidualBurnBase.get(tokenIndex) + residualCov);
 
                     uint256 curOutflows = pa.cumulativeOutflows.get(tokenIndex);
                     uint256 existingFloor = pa.pendingResidualBurnOutflowsFloor.get(tokenIndex);
                     if (curOutflows > existingFloor) {
                         pa.pendingResidualBurnOutflowsFloor.set(tokenIndex, curOutflows);
                     }
                 }
             }
         }
 
         {
             uint256 indexNow = s.poolAccounting[poolId].coveragePerDeficitIndexX128.get(tokenIndex);
             uint256 indexLast = pa.coverageIndexLastX128.get(tokenIndex);
 
             if (indexNow != indexLast) {
                 pa.coverageIndexLastX128.set(tokenIndex, indexNow);
             }
 
             uint256 deltaIndex = indexNow - indexLast;
             if (deltaIndex > 0 && deficitPrincipal > 0) {
                 uint256 cov = FullMath.mulDiv(deficitPrincipal, deltaIndex, FixedPoint128.Q128);
                 if (cov > 0) {
                     _applyCoverageBurn(s, poolManager, positionId, poolId, tokenIndex, cov, liq);
                 }
             }
         }
 
         _applyBankedResidualBurn(s, poolManager, positionId, poolId, tokenIndex, liq);
     }
 
     function _settleDeficitIndexedCoverageUsage(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
         internal
     {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
         uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));
 
         _settleDICEForToken(s, poolManager, positionId, poolId, 0, liq);
         _settleDICEForToken(s, poolManager, positionId, poolId, 1, liq);
     }
 
     function _settleSettledIndexedCoverageUsage(VTSStorage storage s, PositionId positionId) internal {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
 
         _settleCISEForToken(s.positionAccounting[positionId], s.poolAccounting[poolId], 0);
         _settleCISEForToken(s.positionAccounting[positionId], s.poolAccounting[poolId], 1);
     }
 
     /// @notice Apply coverage burn for a position (deficit-indexed coverage exercise → fee share)
     /// @dev Fees accrue on the input token, not the deficit token.
     function _applyCoverageBurn(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         PoolId p,
         uint8 tokenIndex,
         uint256 cov,
         uint128 positionLiquidity
     ) internal {
         PositionAccounting storage pa = s.positionAccounting[id];
 
         uint256 burnBase;
         {
             uint256 d = pa.cumulativeDeficit.get(tokenIndex);
             uint256 settled = pa.settled.get(tokenIndex);
             if (d == 0 && settled == 0) return;
 
             uint256 cEff = cov <= (d + settled) ? cov : (d + settled);
             if (d == 0) return;
             burnBase = cEff < d ? cEff : d;
 
             if (burnBase == 0) return;
         }
 
         _applyBurnBase(s, poolManager, id, p, tokenIndex, burnBase, positionLiquidity, 0, false);
     }
 }
 
 /// @title VTSFeeLinkedLib
 /// @notice Library for VTS fee processing
 /// @dev Operates on VTSStorage storage struct via storage pointers
 library VTSFeeLinkedLib {
     /// @notice Prepares CSI state before minting fresh fee-share contributions for a position
     /// @dev Advances the spend epoch if needed, then syncs the position's remaining self-share
     ///      against the current pool factor before the caller increases `pendingFeeAdj` / `feesShared`.
     /// @param pa The position accounting storage reference
     /// @param paPool The pool accounting storage reference
     /// @param feeTokenIndex The fee token index receiving the newly minted contribution
     function beforeFeeShareMint(PositionAccounting storage pa, PoolAccounting storage paPool, uint8 feeTokenIndex)
         external
     {
         VTSFeeLib._prepareFeeShareMint(pa, paPool, feeTokenIndex);
     }
 
     /// @notice Processes the fees for a position after touch
     /// @dev Updates accounting state only. Actual ERC6909 mint/burn is handled by CoreHook.settleHookDeltasToPot
     /// @param s The VTS storage
     /// @param positionId The position ID
     /// @return adj The materialised fee adjustment delta
     function afterTouchPosition(VTSStorage storage s, PositionId positionId) external returns (BalanceDelta adj) {
         return VTSFeeLib._processPositionFees(s, positionId);
     }
 
     /// @notice Processes position fees after touch with optional per-leg caps on positive slash materialisation.
     /// @dev Positive caps limit only the current-touch materialisation (`feeAdj`) for `pendingFeeAdj > 0`. Any excess
     ///      remains queued in `pendingFeeAdj`.
     function afterTouchPositionWithPositiveCaps(
         VTSStorage storage s,
         PositionId positionId,
         uint256 positiveCap0,
         uint256 positiveCap1
     ) external returns (BalanceDelta adj) {
         return VTSFeeLib._processPositionFees(s, positionId, positiveCap0, positiveCap1);
     }
 
     /// @notice Apply the fee-burn pipeline for a position and return the consumed outflow share
     function applyBurnBase(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId,
         PoolId poolId,
         uint8 tokenIndex,
         uint256 burnBase,
         uint128 positionLiquidity,
         uint256 outflowFloor,
         bool consumeResidualFeeBacking
     ) external returns (uint256 consumedBurnBase) {
         return VTSFeeLib._applyBurnBase(
             s,
             poolManager,
             positionId,
             poolId,
             tokenIndex,
             burnBase,
             positionLiquidity,
             outflowFloor,
             consumeResidualFeeBacking
         );
     }
 
     /// @notice Episode-scoped cleanup when pending residual burn base is zero (DICE settle path)
     function clearResolvedResidualFeeBacking(PositionAccounting storage pa, uint8 deficitTokenIndex) external {
         VTSFeeLib._clearResolvedResidualFeeBacking(pa, deficitTokenIndex);
     }
 
     /// @notice Freeze unresolved residual-burn fee backing before deactivation to zero liquidity
     function captureResidualFeeBackingOnDeactivation(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         uint128 liquidityBeforeRemove
     ) external {
         VTSFeeLib._captureResidualFeeBackingOnDeactivation(s, poolManager, id, liquidityBeforeRemove);
     }
 
     /// @notice Bank historical fee backing for the removed liquidity slice on partial decrease (residual episode open)
     function captureResidualFeeBackingOnPartialDecrease(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         uint128 removedLiquidity
     ) external {
         VTSFeeLib._captureResidualFeeBackingOnPartialDecrease(s, poolManager, id, removedLiquidity);
     }
 
     /// @notice Apply banked residual-derived burn against eligible outflow windows
     function applyBankedResidualBurn(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         PoolId p,
         uint8 tokenIndex,
         uint128 positionLiquidity
     ) external {
         VTSFeeLib._applyBankedResidualBurn(s, poolManager, id, p, tokenIndex, positionLiquidity);
     }
 
     /// @notice Apply coverage burn from deficit-indexed coverage exercise
     function applyCoverageBurn(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         PoolId p,
         uint8 tokenIndex,
         uint256 cov,
         uint128 positionLiquidity
     ) external {
         VTSFeeLib._applyCoverageBurn(s, poolManager, id, p, tokenIndex, cov, positionLiquidity);
     }
 
     /// @notice Flush pending deficit-indexed coverage residual into the DICE index when principal becomes non-zero
     function flushCoverageResidualIfNeeded(VTSStorage storage s, PoolId poolId, uint8 tokenIndex) external {
         VTSFeeLib._flushCoverageResidualIfNeeded(s, poolId, tokenIndex);
     }
 
     /// @notice Settle settled-indexed coverage usage (CISE) for both tokens
     function settleSettledIndexedCoverageUsage(VTSStorage storage s, PositionId positionId) external {
         VTSFeeLib._settleSettledIndexedCoverageUsage(s, positionId);
     }
 
     /// @notice Settle deficit-indexed coverage usage (DICE) for both tokens
     function settleDeficitIndexedCoverageUsage(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
         external
     {
         VTSFeeLib._settleDeficitIndexedCoverageUsage(s, poolManager, positionId);
     }
 }
```

# Related findings

## [Low] Missing cumulativeDeficit check in MMPositionManager._decommitSignal burn gate causes persistent pool accounting distortion and skewed coverage/fee distribution

### Description

[MMPositionManager._decommitSignal](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/MMPositionManager.sol#L336-L357) allows burning a commitment NFT when there are no active positions and no inactive settled remnants, but does not ensure that positions under the commit have zero cumulativeDeficit. After the burn, MM settlement entrypoints (which [require NFT ownership/approval](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/MMPositionActionsImpl.sol#L496-L503)) are unreachable, leaving any remaining cumulativeDeficit and the pool’s totalDeficitPrincipal orphaned and permanently distorting DICE/CISE coverage and fee-burn allocation.

The decommit path in [MMPositionManager._decommitSignal](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/MMPositionManager.sol#L336-L357) [only checks activePositionCount and inactiveRemnantCount](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/MMPositionManager.sol#L336-L357) ([inactiveRemnantCount (which tracks inactive positions with non-zero pa.settled)](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/types/Commit.sol#L41-L44)). It omits any check for non-zero cumulativeDeficit on positions under the commit. Positions can reach a "deficit-only inactive" state (liquidity=0, settled=0 via [clamp on full deactivation](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSPositionLib.sol#L1336-L1356), cumulativeDeficit>0 from prior swap-incurred outflows). In that state, inactiveRemnantCount is zero, permitting decommit (burn). After the NFT is burned, MM settlement operations in MMPositionActionsImpl (e.g., _settle, _increase, _decrease, etc.) [require NFT ownership/approval](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/MMPositionActionsImpl.sol#L496-L503), which is no longer attainable since ownerOf(tokenId) reverts for a burned token. As a result, per-position cumulativeDeficit and the pool’s totalDeficitPrincipal ([incremented on deficit growth](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSPositionLib.sol#L542-L580) and [decremented only when positive settlement nets cumulativeDeficit](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSPositionLib.sol#L146-L162)) remain stranded. DICE/CISE coverage and fee-burn calculations that [rely on totalDeficitPrincipal as a denominator](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSCommitLib.sol#L204-L213) are depressed by non-serviceable principal. Additionally, orphans typically do not materialise positive pending slashes into the pot (materialisation runs during position "touch"). This yields long-lived yield distribution skew for other pool participants without directly stealing principal funds.

### Severity

**Impact Explanation:** [Medium] The issue causes a material, persistent loss of yield/fees for other pool participants by depressing coverage-per-deficit index increments (denominator bloated by orphan principal) and often underfunding the slashed pot (orphans seldom materialise pending slashes). It does not directly steal principal or freeze funds.

**Likelihood Explanation:** [Low] Reaching the precise end-state requires swap-incurred deficits and staged full deactivation to zero-settled with remaining cumulativeDeficit, followed by decommit. The behavior is primarily griefing/non-profitable for an attacker and similar orphaning is already possible by idling without decommit, reducing the incremental incentive to exploit.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
An MM generates swap-incurred deficits on its positions, fully removes liquidity so settled is clamped to zero while cumulativeDeficit remains, then decommits (burns) the NFT. Settlement entrypoints become unreachable post-burn, orphaning the position’s deficits and depressing coverage-per-deficit allocations for other LPs/MMs.
#### Preconditions / Assumptions
- (a). A live pool with an MM-managed commit and one or more positions
- (b). Normal swap activity creates deficit growth exceeding pa.settled, increasing pa.cumulativeDeficit and pool totalDeficitPrincipal
- (c). MM fully deactivates positions (liquidity → 0), clamping settled to 0 while cumulativeDeficit remains > 0
- (d). activePositionCount == 0 and inactiveRemnantCount == 0 at commit level
- (e). MM calls decommit, burning the NFT

### Scenario 2.
A colluding or sybil MM repeats the above across many commits/positions, accumulating large orphaned principal in the pool. This significantly skews DICE/CISE allocation long-term, under-rewarding honest participants.
#### Preconditions / Assumptions
- (a). Multiple commits/positions under the same pool controlled by a single actor or colluding actors
- (b). Repeated creation of cumulativeDeficit via swaps and full deactivation to zero-settled, leaving cumulativeDeficit > 0
- (c). Decommit (burn) for each such commit once inactiveRemnantCount == 0
- (d). Accumulation of orphaned principal across many positions

### Scenario 3.
An honest operator inadvertently decommits after fully deactivating positions that retained cumulativeDeficit but no settled remnant. This unintentionally orphans deficits, causing sustained skew in coverage/fee distribution against other participants.
#### Preconditions / Assumptions
- (a). Honest operator with a commit deactivates positions to zero liquidity
- (b). Positions end up with settled==0 and cumulativeDeficit>0 (deficit-only inactive state)
- (c). Operator executes decommit (burn) without realising deficits remain

### Proposed fix

#### MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/MMPositionManager.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {ERC721Permit_v4} from "v4-periphery/src/base/ERC721Permit_v4.sol";
 import {ReentrancyLock} from "v4-periphery/src/base/ReentrancyLock.sol";
 import {Multicall_v4} from "v4-periphery/src/base/Multicall_v4.sol";
 import {BaseActionsRouter} from "v4-periphery/src/base/BaseActionsRouter.sol";
 import {FietNativeWrapper} from "./modules/NativeWrapper.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 import {PositionId, Position} from "./types/Position.sol";
 import {LiquiditySignal} from "./types/Commit.sol";
 import {MarketMaker} from "./libraries/MarketMaker.sol";
 import {ICommitmentDescriptor} from "./interfaces/ICommitmentDescriptor.sol";
 import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
 import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
 import {PositionManagerQueueCustodian} from "./modules/PositionManagerQueueCustodian.sol";
 import {PositionManagerEntrypoint} from "./modules/PositionManagerEntrypoint.sol";
 import {Permit2Forwarder} from "v4-periphery/src/base/Permit2Forwarder.sol";
 import {MMActions} from "./libraries/MMActions.sol";
 import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
 import {MMHelpers} from "./libraries/MMHelpers.sol";
 import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {IEndpointUnwrapAdmission} from "./interfaces/IEndpointUnwrapAdmission.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
 
 /// @title MMPositionManager
 /// @notice Entry point for VRL commitment position management
 /// @dev Handles commitment lifecycle (ERC721) and utility operations locally
 /// @dev Delegates position operations to MMPMActionsImpl via delegatecall
 contract MMPositionManager is
     ERC721Permit_v4,
     IMMPositionManager,
     IEndpointUnwrapAdmission,
     ReentrancyLock,
     Multicall_v4,
     Permit2Forwarder,
     BaseActionsRouter,
     FietNativeWrapper,
     PositionManagerEntrypoint,
     PositionManagerQueueCustodian
 {
     /// @dev Aggregates constructor dependencies so unoptimised builds avoid stack-too-deep in the inheritance init list.
     struct MMPositionManagerInit {
         IPoolManager poolManager;
         address marketFactory;
         address vtsOrchestrator;
         address canonicalCustody;
         address descriptor;
         IWETH9 weth9;
         IAllowanceTransfer permit2;
         address actionsImpl;
         address queueCustodianAddr;
     }
 
     using MMCalldataDecoder for bytes;
     using CurrencyTransfer for Currency;
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Events
     // ═══════════════════════════════════════════════════════════════════════════
 
     event SignalCommitted(uint256 tokenId);
     event SignalDecommitted(uint256 tokenId, uint256 positionCount);
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Immutables
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice The implementation contract for position operations
     address public immutable commitmentDescriptor;
     /// @notice Shared custodian that holds queued MM-backed LCC by commit bucket
     IMMQueueCustodian public immutable queueCustodian;
 
     /// @dev Custody bucket for `UNWRAP_LCC` shortfalls: not tied to a commitment NFT (`tokenId == 0` matches
     ///      `COLLECT_AVAILABLE_LIQUIDITY` utility collects).
     ///
     ///      `UNWRAP_LCC` forwards the LCC backing each newly queued shortfall from this contract into the queue
     ///      custodian (`_forwardUnwrapQueuedLccToCustodian`), so physical LCC tracks the Hub obligation for that
     ///      beneficiary. The Hub queue and custodian are separate ledgers: if `settleQueue[lcc][beneficiary]` is later
     ///      annulled by other LCC flows (e.g. LCC-02 `annulSettlementBeforeTransfer` on a different transfer), the Hub
     ///      obligation can drop while utility custody still holds the prior slice. The beneficiary (batch locker)
     ///      operating through MMPM is then entitled to receive that mismatch as LCC: the delta
     ///      `custodied - hubQueued` is released to them in `_reconcileUtilityCustodyWithHubQueue` on the next
     ///      utility `UNWRAP_LCC` or utility collect (`tokenId == 0`). Commit buckets (`tokenId > 0`) are unchanged.
     ///      Unwrap headroom and post-transfer queue snapshots are handled separately (`LiquidityHub`
     ///      `_unwrapEffectiveFromBalance`, `_unwrapLccFromUser`).
     uint256 private constant _UNWRAP_QUEUE_CUSTODY_TOKEN_ID = 0;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Constructor
     // ═══════════════════════════════════════════════════════════════════════════
 
     constructor(MMPositionManagerInit memory p)
         ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
         BaseActionsRouter(p.poolManager)
         Permit2Forwarder(p.permit2)
         FietNativeWrapper(p.weth9)
         PositionManagerEntrypoint(p.marketFactory, p.vtsOrchestrator, p.canonicalCustody, p.actionsImpl)
     {
         if (p.queueCustodianAddr == address(0) || p.queueCustodianAddr.code.length == 0) {
             revert Errors.InvalidAddress(p.queueCustodianAddr);
         }
         commitmentDescriptor = p.descriptor;
         queueCustodian = IMMQueueCustodian(p.queueCustodianAddr);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Modifiers
     // ═══════════════════════════════════════════════════════════════════════════
 
     modifier checkDeadline(uint256 deadline) {
         _checkDeadline(deadline);
         _;
     }
 
     function _checkDeadline(uint256 deadline) internal view {
         if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);
     }
 
     /// @notice Requires PoolManager to be locked (not within an active batch)
     modifier onlyIfPoolManagerLocked() {
         _onlyIfPoolManagerLocked();
         _;
     }
 
     function _onlyIfPoolManagerLocked() internal view {
         if (poolManager.isUnlocked()) revert Errors.PoolManagerMustBeLocked();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // BaseActionsRouter Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc BaseActionsRouter
     function msgSender() public view override(BaseActionsRouter, PositionManagerBase) returns (address) {
         return _getLocker();
     }
 
     /// @inheritdoc PositionManagerQueueCustodian
     function _queueCustodian() internal view override(PositionManagerQueueCustodian) returns (IMMQueueCustodian) {
         return queueCustodian;
     }
 
     /// @inheritdoc IEndpointUnwrapAdmission
     function unwrapAdmissionCredit(address lcc, address beneficiary) external view returns (uint256) {
         return queueCustodian.queued(_UNWRAP_QUEUE_CUSTODY_TOKEN_ID, lcc, beneficiary);
     }
 
     /// @inheritdoc FietNativeWrapper
     function _canonicalMarketFactory() internal view override returns (IMarketFactory) {
         return marketFactory;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _liquidityHub() internal view override returns (ILiquidityHub) {
         return liquidityHub;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Entry Points with Hooks
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Executes a batch of liquidity modifications
     /// @dev Mirrors v4 PositionManager.modifyLiquidities
     function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
         external
         payable
         isNotLocked
         checkDeadline(deadline)
     {
         _beforeBatch();
         _executeActions(unlockData);
         _afterBatch();
     }
 
     /// @notice Executes actions without acquiring a new unlock
     /// @dev Mirrors v4 PositionManager.modifyLiquiditiesWithoutUnlock
     function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params)
         external
         payable
         isNotLocked
     {
         _beforeBatch();
         _executeActionsWithoutUnlock(actions, params);
         _afterBatch();
     }
 
     /// @notice Get the next token ID that will be assigned
     /// @dev Returns the next commit ID from VTSOrchestrator, matching Uniswap PositionManager interface
     /// @return The next token ID (will be assigned on next commitSignal call)
     function nextTokenId() public view returns (uint256) {
         return vtsOrchestrator.nextCommitId();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Action Routing (Comparison-Based)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles action execution with comparison-based routing
     /// @dev Actions <= SETTLE_POSITION_FROM_DELTAS delegate to impl (position operations)
     /// @dev Actions >= COMMIT_SIGNAL and < TAKE handled locally (commitments)
     /// @dev Actions >= TAKE handled locally (utilities)
     function _handleAction(uint256 action, bytes calldata params) internal virtual override {
         // Position actions (<= SETTLE_POSITION_FROM_DELTAS) → delegate to impl
         if (action <= MMActions.SETTLE_POSITION_FROM_DELTAS) {
             _delegateToImpl(abi.encodeWithSelector(IMMActionsImpl.handleAction.selector, action, params));
             return;
         }
 
         // Commitment actions (>= COMMIT_SIGNAL and < TAKE) → handle locally
         if (action >= MMActions.COMMIT_SIGNAL && action < MMActions.TAKE) {
             _handleCommitmentAction(action, params);
             return;
         }
 
         // Currency/utility actions (>= TAKE) → handle locally
         _handleUtilityAction(action, params);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Commitment Actions (ERC721 + Signal Management)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles commitment-level actions
     /// @param action The action code
     /// @param params The encoded parameters for the action
     function _handleCommitmentAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.COMMIT_SIGNAL) {
             (bytes calldata liquiditySignal, bytes calldata relayParams) = params.decodeCommitSignalParams();
             _commitSignal(liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.RENEW_SIGNAL) {
             (uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) =
                 params.decodeTokenIdAndBytes();
             _renewSignal(tokenId, liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.DECOMMIT_SIGNAL) {
             uint256 tokenId = params.decodeDecommitSignalParams();
             _decommitSignal(tokenId);
             return;
         }
         if (action == MMActions.CHECKPOINT) {
             (uint256 tokenId, uint256 positionIndex, bool withCommitment) = params.decodeCheckpointParams();
             _checkpoint(tokenId, positionIndex, withCommitment);
             return;
         }
         if (action == MMActions.EXTEND_GRACE_PERIOD) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint8 settlementTokenIndex,
                 uint32 verifierIndex,
                 bytes calldata settlementProof
             ) = params.decodeExtendGracePeriodParams();
             _extendGracePeriod(poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @notice Commits a liquidity signal and mints a commitment NFT
     /// @dev Fresh commit is owner-authenticated: VRL sees `signal.mmState.owner` as the proof principal.
     ///      Direct commit requires `msgSender() == mmState.owner` and mints the NFT to `mmState.owner`.
     ///      Relayed commit passes EIP-712 `RelayAuth.sender` as this `sender` (`address(0)` means `mmState.owner`; otherwise
     ///      must equal `msgSender()` here).
     /// @param liquiditySignal The ABI-encoded LiquiditySignal to verify and record
     /// @param relayParams Empty for direct commit; otherwise `(deadline, authNonce, authSig, sender)`.
     /// @return tokenId The commitment NFT id created
     function _commitSignal(bytes calldata liquiditySignal, bytes calldata relayParams)
         internal
         returns (uint256 tokenId)
     {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         address mmOwner = signal.mmState.owner;
 
         if (relayParams.length == 0) {
             if (msgSender() != mmOwner) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignal(marketFactory, liquiditySignal);
             _mint(mmOwner, tokenId);
         } else {
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address sender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address mintRecipient = sender == address(0) ? mmOwner : sender;
             if (msgSender() != mintRecipient) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignalRelayed(
                 marketFactory, liquiditySignal, deadline, authNonce, authSig, sender
             );
             _mint(mintRecipient, tokenId);
         }
         emit SignalCommitted(tokenId);
     }
 
     /// @notice Renews an existing signal with new parameters
     /// @dev Direct renew (no relay) requires the batch locker to equal `signal.mmState.advancer`, matching ordinary
     ///      non-seizing MM ops (`locker == advancer`). Relayed renew: EIP-712 `RelayAuth.sender` must be `address(0)`
     ///      (locker must still be advancer) or `signal.mmState.advancer`; the batch locker (`msgSender()`) must match
     ///      the signed sender when non-zero, or be the advancer when the signed sender is zero.
     /// @param tokenId The commitment NFT token ID
     /// @param liquiditySignal The new liquidity signal
     function _renewSignal(uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) internal {
         if (relayParams.length == 0) {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             if (msgSender() != signal.mmState.advancer) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignal(marketFactory, tokenId, liquiditySignal);
         } else {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address relaySender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address adv = signal.mmState.advancer;
             if (msgSender() != adv && msgSender() != relaySender) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignalRelayed(
                 marketFactory, tokenId, liquiditySignal, deadline, authNonce, authSig, relaySender
             );
         }
     }
 
     /// @notice Decommits a signal and burns the commitment NFT
     /// @param tokenId The commitment NFT token ID
     function _decommitSignal(uint256 tokenId) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         // Check if commit has any active positions (burned positions are inactive)
         (,, uint256 positionCount, uint256 activePositionCount, uint256 inactiveRemnantCount) =
             vtsOrchestrator.getCommit(tokenId);
         if (activePositionCount > 0) {
             revert Errors.CommitNotEmpty(tokenId);
         }
         // Inactive positions may still hold withdrawable `pa.settled` (SETTLE-03); burning the NFT would strand it
         // because MM settlement paths require `assertApprovedOrOwner` against this tokenId. Tracked in O(1) via
         // `Commit.inactiveRemnantCount` (see VTSPositionLib._syncInactiveRemnantAfterActiveTransition /
         // `_syncInactiveRemnantAfterSettledPairChange`).
         if (inactiveRemnantCount > 0) {
             revert Errors.CommitNotDrained(tokenId);
         }
+        // TODO: Also block decommit when any position under this commit has non-zero cumulativeDeficit.
+        // Recommend: query a new VTSOrchestrator view (e.g., getCommitDeficitPositionCount(tokenId)) and
+        // revert with a dedicated error when > 0 to avoid orphaning pool principal after burn.
 
         _burn(tokenId);
         emit SignalDecommitted(tokenId, uint256(positionCount));
     }
 
     /// @notice Marks a checkpoint for a position, optionally running commitment backing checks
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function _checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) internal {
         vtsOrchestrator.checkpoint(tokenId, positionIndex, withCommitment);
     }
 
     /// @notice Extends grace period for a commitment via proof
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param settlementTokenIndex The settlement token index
     /// @param verifierIndex The verifier index
     /// @param settlementProof The settlement proof
     function _extendGracePeriod(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint8 settlementTokenIndex,
         uint32 verifierIndex,
         bytes calldata settlementProof
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         vtsOrchestrator.extendGracePeriod(
             marketFactory, poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof
         );
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Utility Actions (Currency Operations)
     // ═══════════════════════════════════════════════════════════════════════════
 
     function _handleUtilityAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.TAKE) {
             (Currency currency, address to, uint256 maxAmount) = params.decodeTakeParams();
             _take(currency, to, maxAmount);
             return;
         }
         if (action == MMActions.UNWRAP_LCC) {
             (address lccAddr, uint256 amount, address recipient, bool payerIsUser) = params.decodeUnwrapLccParams();
             address to = _resolveStrictRecipient(recipient);
             if (payerIsUser) {
                 _unwrapLccFromUser(lccAddr, to, amount);
             } else {
                 _unwrapLccFromDeltas(lccAddr, to, amount);
             }
             return;
         }
         if (action == MMActions.WRAP_NATIVE) {
             uint256 amount = params.decodeUint256();
             _wrapNative(amount);
             return;
         }
         if (action == MMActions.UNWRAP_NATIVE) {
             (uint256 amount, bool payerIsUser) = params.decodeUint256AndBool();
             _unwrapNative(amount, payerIsUser);
             return;
         }
         if (action == MMActions.COLLECT_AVAILABLE_LIQUIDITY) {
             (address lcc, uint256 tokenId, uint256 maxAmount) = params.decodeCollectLiquidityParams();
             _collectAvailableLiquidity(lcc, tokenId, maxAmount);
             return;
         }
         if (action == MMActions.SYNC) {
             Currency currency = params.decodeSyncParams();
             _sync(currency);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @dev UNWRAP_LCC payout may only go to the locker or MMPM; arbitrary third-party recipients are disallowed.
     function _resolveStrictRecipient(address recipient) internal view returns (address) {
         address to = _mapRecipient(recipient);
         if (to != msgSender() && to != address(this)) {
             revert Errors.NotApproved(to);
         }
         return to;
     }
 
     /// @dev Hub `unwrapTo`, measure incremental queue for `queueKey`, forward queued LCC to custodian when needed.
     ///      Caller must run `_reconcileUtilityCustodyWithHubQueue` first where required (before `transferFrom` on user path).
     function _unwrapToQueueForward(
         address lccAddr,
         Currency lccCurrency,
         address payoutTo,
         address queueKey,
         uint256 toUnwrap
     ) private {
         uint256 qBefore = liquidityHub.settleQueue(lccAddr, queueKey);
         liquidityHub.unwrapTo(lccAddr, payoutTo, queueKey, toUnwrap);
         uint256 queued = liquidityHub.settleQueue(lccAddr, queueKey) - qBefore;
         if (queued > 0) {
             _forwardUnwrapQueuedLccToCustodian(lccCurrency, queueKey, queued);
         }
     }
 
     /// @notice Unwraps LCC tokens to underlying asset using deltas (locker credit)
     /// @dev Native-backed LCC: Hub pays ETH to MMPM only (never direct to the locker during `unwrapTo`), so a payable
     ///      locker cannot re-enter between queue write and custody forward. The locker receives native credit and must
     ///      `TAKE(ADDRESS_ZERO, ...)` to withdraw ETH.
     function _unwrapLccFromDeltas(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         // Native: payout to MMPM first; ERC20: direct payout per `to`.
         address payoutTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? payoutTo.balance : IERC20(underlying).balanceOf(to);
         uint256 toUnwrap = vtsOrchestrator.take(lccCurrency, msgSender(), requested);
 
         if (toUnwrap > 0) {
             address queueTo = msgSender();
             _reconcileUtilityCustodyWithHubQueue(lccAddr, queueTo);
             _unwrapToQueueForward(lccAddr, lccCurrency, payoutTo, queueTo, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? payoutTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
 
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
     }
 
     /// @notice Unwraps LCC tokens to underlying asset by pulling from the locker/user
     /// @dev Native-backed LCC: Hub pays ETH to MMPM only; see `_unwrapLccFromDeltas` NatSpec.
     ///      Split into a private helper to avoid stack-too-deep in unoptimised builds.
     function _unwrapLccFromUser(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         address payer = msgSender();
         uint256 toUnwrap = lcc.balanceOf(payer);
         if (requested > 0) {
             toUnwrap = Math.min(toUnwrap, requested);
         }
 
         return _unwrapLccFromUserWithAmount(lccAddr, lccCurrency, to, payer, toUnwrap, isNativeUnderlying, underlying);
     }
 
     /// @dev Pull, unwrap-to-queue, and credit; isolated to keep `_unwrapLccFromUser` stack shallow.
     function _unwrapLccFromUserWithAmount(
         address lccAddr,
         Currency lccCurrency,
         address to,
         address payer,
         uint256 toUnwrap,
         bool isNativeUnderlying,
         address underlying
     ) private returns (uint256 unwrapped) {
         address payoutTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? payoutTo.balance : IERC20(underlying).balanceOf(to);
         if (toUnwrap > 0) {
             _reconcileUtilityCustodyWithHubQueue(lccAddr, payer);
             // Pull only from the locker/user (never arbitrary third parties).
             // Snapshot queue *after* transfer: non-protocol -> protocol triggers annulment of queued
             // settlement (LCC-02), so the baseline for this unwrap's incremental queue must be post-annul.
             lccCurrency.transferFrom(payer, address(this), toUnwrap);
             _unwrapToQueueForward(lccAddr, lccCurrency, payoutTo, payer, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? payoutTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
     }
 
     /// @notice Moves Hub-queued shortfall LCC off this contract into beneficiary-scoped custody so it is not FCFS
     ///         router dust (see `DELTA-02` / `HUB-02A` in `INVARIANTS.md`).
     /// @dev Caller must have already invoked `liquidityHub.unwrapTo`; `amount` is the incremental queue delta for
     ///      `beneficiary` on this unwrap. For `_unwrapLccFromUser`, the delta is measured from the queue state
     ///      after `transferFrom` (post-annul) through `unwrapTo`; for `_unwrapLccFromDeltas`, from immediately before
     ///      `unwrapTo` (no LCC transfer annul in between).
     ///
     ///      Because this forwards physical LCC into the custodian while `LiquidityHub` owns queue accounting, a later
     ///      annulment of `settleQueue` (from unrelated LCC transfers by the same beneficiary) does not automatically
     ///      pull LCC back out of the custodian. The beneficiary remains entitled to the resulting excess
     ///      (`custodied - live hubQueued`); see `_reconcileUtilityCustodyWithHubQueue`.
     function _forwardUnwrapQueuedLccToCustodian(Currency lccCurrency, address beneficiary, uint256 amount) private {
         if (amount == 0) return;
         if (beneficiary == address(0)) revert Errors.InvalidAddress(beneficiary);
 
         IMMQueueCustodian custodian = queueCustodian;
         address cust = address(custodian);
         if (cust == address(0) || cust == address(this)) return;
 
         uint256 bal = IERC20(Currency.unwrap(lccCurrency)).balanceOf(address(this));
         if (bal < amount) revert Errors.InsufficientBalance(bal, amount);
 
         lccCurrency.transfer(cust, amount);
         custodian.record(_UNWRAP_QUEUE_CUSTODY_TOKEN_ID, Currency.unwrap(lccCurrency), beneficiary, amount);
     }
 
     /// @notice If utility-bucket (`tokenId == 0`) custody exceeds the beneficiary's live Hub queue, release the excess
     ///         LCC to the beneficiary (scan #22 finding #3 narrowed).
     /// @dev `UNWRAP_LCC` had forwarded queued-backing LCC into the custodian; if `settleQueue` is later reduced
     ///      independently (annulment via other LCC movements), the custodian can still hold the full prior slice.
     ///      The beneficiary (batch locker) is entitled to that gap as LCC: we release `custodied - hubQueued`, i.e. the
     ///      amount that was annulled from the Hub queue without a matching decrement of utility custody. Commit-scoped
     ///      custody (`tokenId > 0`) is not touched. Called before utility `UNWRAP_LCC` and before
     ///      `COLLECT_AVAILABLE_LIQUIDITY` when `tokenId == 0`.
     function _reconcileUtilityCustodyWithHubQueue(address lccAddr, address beneficiary) private {
         if (beneficiary == address(0)) return;
         IMMQueueCustodian custodian = queueCustodian;
         address cust = address(custodian);
         if (cust == address(0) || cust == address(this)) return;
 
         uint256 hubQueued = liquidityHub.settleQueue(lccAddr, beneficiary);
         uint256 custodied = custodian.queued(_UNWRAP_QUEUE_CUSTODY_TOKEN_ID, lccAddr, beneficiary);
         if (custodied <= hubQueued) return;
 
         uint256 excess = custodied - hubQueued;
         custodian.release(_UNWRAP_QUEUE_CUSTODY_TOKEN_ID, lccAddr, beneficiary, excess);
     }
 
     /// @notice Collects available liquidity from settlement queue
     /// @dev Intersects three caps: caller's Hub queue, underlying reserve availability, and this caller's
     ///      beneficiary-scoped slice in the queue custodian for `tokenId`. Without the beneficiary key, a locker
     ///      with any queue could pair it with another party's commit custody bucket.
     ///
     ///      Intended model (queue-gated collect):
     ///      - This path exists to release custodied LCC and then call `processSettlementFor`, which burns the
     ///        caller's LCC and clears their Hub `settleQueue` entry. If `settleQueue(lcc, locker) == 0`, this
     ///        function is a no-op by design — e.g. some flows (including certain seizure shapes) may record LCC
     ///        in the custodian for the locker without creating a per-LCC queue entry; those are not settled here.
     ///      - Arbitrary `processSettlementFor` calls cannot drain another party's custody: settlement still
     ///        requires the recipient's market-derived LCC balance; beneficiary-scoped custody ensures collect
     ///        only debits the slice matching the caller's queue.
     /// @param lcc The LCC token address
     /// @param tokenId The commitment NFT token ID bucket to collect from
     /// @param maxAmount The maximum amount to collect
     function _collectAvailableLiquidity(address lcc, uint256 tokenId, uint256 maxAmount) internal {
         address locker = msgSender();
         if (tokenId == _UNWRAP_QUEUE_CUSTODY_TOKEN_ID) {
             _reconcileUtilityCustodyWithHubQueue(lcc, locker);
         }
         liquidityHub.settleFromCustodian(lcc, address(queueCustodian), tokenId, locker, maxAmount);
     }
 
     /// @notice Syncs currency balance as credit to delta
     /// @param currency The currency to sync
     /// @dev owner is always address(this) (MMPM) and target is always msgSender() (locker)
     function _sync(Currency currency) internal {
         // Native ETH sync must be source-aware (exact amount) and is handled by dedicated flows.
         if (currency == CurrencyLibrary.ADDRESS_ZERO) {
             revert Errors.InvalidAddress(address(0));
         }
         vtsOrchestrator.sync(marketFactory, currency, address(this), msgSender());
     }
 
     /// @notice Wraps native ETH to WETH
     /// @param amount The amount of ETH to wrap (0 for max available from deltas)
     function _wrapNative(uint256 amount) internal {
         uint256 takeAmount = vtsOrchestrator.take(CurrencyLibrary.ADDRESS_ZERO, msgSender(), amount);
         if (amount > 0 && amount > takeAmount) {
             revert Errors.InsufficientBalance(takeAmount, amount);
         } else if (amount == 0) {
             amount = takeAmount;
         }
         if (amount == 0) {
             return;
         }
 
         _wrap(amount);
         Currency weth = Currency.wrap(address(WETH9));
         _syncBalanceAsCredit(weth);
     }
 
     /// @notice Unwraps WETH to native ETH
     /// @param amount The amount of WETH to unwrap (0 for max)
     /// @param payerIsUser Whether the payer is the user (true) or deltas (false)
     function _unwrapNative(uint256 amount, bool payerIsUser) internal {
         Currency weth = Currency.wrap(address(WETH9));
         if (payerIsUser) {
             address payer = msgSender();
             if (amount == 0) {
                 amount = weth.balanceOf(payer);
             }
             // Use CurrencyTransfer with Permit2 fallback for user transfers
             weth.transferFrom(payer, address(this), amount);
         } else {
             uint256 takeAmount = vtsOrchestrator.take(weth, msgSender(), amount);
             if (amount > 0 && amount > takeAmount) {
                 revert Errors.InsufficientBalance(takeAmount, amount);
             } else if (amount == 0) {
                 amount = takeAmount;
             }
             if (amount == 0) {
                 return;
             }
         }
         _unwrap(amount);
         _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Returns the token URI for a given token id using the commitment descriptor contract
     function tokenURI(uint256 tokenId) public view override returns (string memory) {
         if (commitmentDescriptor == address(0)) {
             revert Errors.CommitmentDescriptorNotSet();
         }
         return ICommitmentDescriptor(commitmentDescriptor).tokenURI(tokenId);
     }
 
     /// @dev Overrides transferFrom to revert if pool manager is locked
     /// @dev Prevents transfers while an unlock session is active (mid-batch)
     function transferFrom(address from, address to, uint256 id) public virtual override onlyIfPoolManagerLocked {
         super.transferFrom(from, to, id);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // View Functions (delegate to impl via staticcall)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPosition(uint256 tokenId, uint256 positionIndex)
         external
         view
         returns (
             Position memory, /* position */
             PositionId /* positionId */
         )
     {
         return vtsOrchestrator.getPosition(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPositionId(uint256 tokenId, uint256 positionIndex) external view returns (PositionId) {
         return vtsOrchestrator.getPositionId(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     function commitOf(uint256 tokenId)
         external
         view
         returns (
             MarketMaker.State memory state,
             uint256 expiresAt,
             uint256 positionCount,
             uint256 activePositionCount,
             uint256 inactiveRemnantCount
         )
     {
         return vtsOrchestrator.getCommit(tokenId);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // No-Locking Checkpoint Functions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Marks a checkpoint for a single position, optionally running backing checks
     /// @param tokenId The ERC721 token id (commitment NFT id)
     /// @param positionIndex The index of the position within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) external onlyIfPoolManagerLocked {
         _checkpoint(tokenId, positionIndex, withCommitment);
     }
 }
```

#### VTSPositionLib.sol

File: `contracts/evm/src/libraries/VTSPositionLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSPositionLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
 import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
 import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {RFSCheckpoint} from "../types/Checkpoint.sol";
 import {
     VTSStorage,
     PositionAccounting,
     PoolAccounting,
     GrowthPair,
     MarketVTSConfiguration,
     TokenPairUint,
     TokenPairInt,
     TokenPairLib,
     PositionContext,
     TouchPositionParams,
     TouchPositionResult
 } from "../types/VTS.sol";
 import {
     PositionId,
     Position,
     PositionLibrary,
     PositionModificationHookData,
     PositionModificationHookDataLib
 } from "../types/Position.sol";
 import {Pool} from "../types/Pool.sol";
 import {LiquidityUtils} from "./LiquidityUtils.sol";
 import {Errors} from "./Errors.sol";
 import {VTSFeeLinkedLib} from "./VTSFeeLib.sol";
 import {VTSCommitLib} from "./VTSCommitLib.sol";
 import {VTSPositionMMOpsLib} from "./VTSPositionMMOpsLib.sol";
 import {IMarketVault} from "../interfaces/IMarketVault.sol";
 
 /// @title VTSPositionLib
 /// @notice Position lifecycle, registration, RFS, settlement, seizure, and growth accounting for VTS
 /// @dev External functions (called via VTSPositionLib.func()) have no underscore prefix.
 ///      Internal functions (called only within this library) have underscore prefix.
 /// @author Fiet Protocol
 library VTSPositionLib {
     using SafeCast for uint256;
     using SafeCast for int256;
     using SafeCast for int128;
     using TokenPairLib for TokenPairUint;
     using TokenPairLib for TokenPairInt;
     using StateLibrary for IPoolManager;
     using PoolIdLibrary for PoolKey;
 
     // ============ INTERNAL STRUCTS ============
 
     /// @dev Internal struct to reduce stack depth in `VTSPositionMMOpsLib` liquidity increase.
     struct LiquidityIncreaseParams {
         address owner;
         uint256 commitId;
         PositionId positionId;
         BalanceDelta principalDelta;
     }
 
     /// @dev Internal struct to reduce stack depth in _deltaAndCheckpointGrowth
     struct GrowthParams {
         PoolId poolId;
         int24 tickLower;
         int24 tickUpper;
         int24 tickCurrent;
         uint128 liquidity;
         uint256 global0;
         uint256 global1;
         bool isInflow;
     }
 
     // Maximum positive magnitude representable in int128
     uint256 internal constant INT128_MAX_U = uint256(type(uint128).max) >> 1;
 
     // --------------------------------------------------
     // Commitment Tracking
     // --------------------------------------------------
 
     /// @notice Sets `commitmentMax` from live Uniswap position liquidity (single source of truth).
     /// @dev Per-delta rounded add/subtract bookkeeping is not equivalent to rounding once on the total;
     ///      incremental `ceil` arithmetic can drift below the true maxima for the remaining range.
     ///      Always derive from `liveLiquidity` after any modify that changes pool position liquidity.
     /// @param s The central VTS storage
     /// @param positionId The position id
     /// @param liveLiquidity Current position liquidity from PoolManager after the modify
     function _trackCommitment(VTSStorage storage s, PositionId positionId, uint128 liveLiquidity) internal {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         if (liveLiquidity == 0) {
             pa.commitmentMax.token0 = 0;
             pa.commitmentMax.token1 = 0;
             return;
         }
         Position memory pos = s.positions[positionId];
         (uint256 c0, uint256 c1) = LiquidityUtils.calculateCommitmentMaxima(pos.tickLower, pos.tickUpper, liveLiquidity);
         pa.commitmentMax.token0 = c0;
         pa.commitmentMax.token1 = c1;
     }
 
     // --------------------------------------------------
     // Settlement Updates
     // --------------------------------------------------
 
     /// @notice Applies a settled delta to the pool-wide `totalSettled` aggregate
     /// @param paPool The pool accounting storage reference
     /// @param tokenIndex The token index (0 or 1)
     /// @param settledDelta The signed settled delta to apply
     function _applyPoolTotalSettledDelta(PoolAccounting storage paPool, uint8 tokenIndex, int256 settledDelta) private {
         if (settledDelta == 0) return;
 
         uint256 currentTotalSettled = paPool.totalSettled.get(tokenIndex);
 
         if (settledDelta >= 0) {
             paPool.totalSettled.set(tokenIndex, currentTotalSettled + uint256(settledDelta));
         } else {
             uint256 decSettled = uint256(-settledDelta);
             if (decSettled > currentTotalSettled) {
                 revert Errors.InvariantViolated("pool totalSettled underflow");
             }
             paPool.totalSettled.set(tokenIndex, currentTotalSettled - decSettled);
         }
     }
 
     /// @notice Updates pool accounting for settlement changes
     /// @dev Extracted to reduce stack depth in _updateSettlement
     /// @param s The central VTS storage
     /// @param id The position id
     /// @param tokenIndex The token index (0 or 1)
     /// @param cur The previous settled amount
     /// @param next The new settled amount
     /// @param cumulativeDeficitCoverage The amount of cumulativeDeficit that was covered
     /// @return applied The helper-applied amount (cumulativeDeficit coverage + settled change)
     function _updatePoolAccounting(
         VTSStorage storage s,
         PositionId id,
         uint8 tokenIndex,
         uint256 cur,
         uint256 next,
         uint256 cumulativeDeficitCoverage
     ) private returns (int256 applied) {
         Position memory pos = s.positions[id];
         PoolAccounting storage paPool = s.poolAccounting[pos.poolId];
 
         int256 settledDelta = next.toInt256() - cur.toInt256();
 
         // DICE: Track pool-wide cumulative deficit principal decrease when cumulativeDeficit is netted.
         // commitmentDeficit is an insolvency gate and is intentionally excluded from totalDeficitPrincipal.
         if (cumulativeDeficitCoverage > 0) {
             uint256 currentPrincipal = paPool.totalDeficitPrincipal.get(tokenIndex);
             // Safely decrement (should not underflow if accounting is consistent)
             uint256 newPrincipal =
                 cumulativeDeficitCoverage > currentPrincipal ? 0 : currentPrincipal - cumulativeDeficitCoverage;
             paPool.totalDeficitPrincipal.set(tokenIndex, newPrincipal);
         }
 
         // CISE: Track pool-wide totalSettled aggregate
         _applyPoolTotalSettledDelta(paPool, tokenIndex, settledDelta);
 
         // Return helper-consumed amount: cumulativeDeficit coverage + settled change
         // Deposits (positive delta to _updateSettlement): returns positive value
         // Withdrawals (negative delta to _updateSettlement): returns negative value (0 + negative settledDelta)
         applied = cumulativeDeficitCoverage.toInt256() + settledDelta;
     }
 
     /// @notice "Silent" update settlement helper wrapper for contexts where we deliberately don't need the applied return value
     /// @dev Consumes the return value so static analysers don't flag ignored returns.
     function _sUpdateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta) internal {
         int256 applied = _updateSettlement(s, id, tokenIndex, delta);
         applied;
     }
 
     /// @dev Nets a positive settlement delta against `commitmentDeficit` for one lane; isolated to reduce stack depth in `_vUpdateSettlement`.
     function _netCommitmentDeficitOnPositiveDelta(PositionAccounting storage pa, uint8 tokenIndex, int256 delta)
         private
         returns (int256 newDelta, uint256 commitmentDeficitCovered)
     {
         uint256 cd = pa.commitmentDeficit.get(tokenIndex);
         if (delta <= 0 || cd == 0) return (delta, 0);
 
         uint256 coverCd = uint256(delta) > cd ? cd : uint256(delta);
         if (coverCd == 0) return (delta, 0);
 
         uint256 nextCd = cd - coverCd;
         pa.commitmentDeficit.set(tokenIndex, nextCd);
         if (nextCd == 0) {
             pa.commitmentDeficitSince.set(tokenIndex, 0);
         }
         return (delta - int256(coverCd), coverCd);
     }
 
     /// @notice Verbose settlement update: returns total economic consumption and the `pa.settled` lane delta separately.
     /// @dev `totalApplied` matches legacy `_updateSettlement` return (deficit coverage + settled change).
     ///      `settledDeltaOnly` is `next - cur` on `pa.settled` for this lane only; amounts that cure
     ///      `cumulativeDeficit` / `commitmentDeficit` without increasing settled appear only in `totalApplied`.
     function _vUpdateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta)
         internal
         returns (int256 totalApplied, int256 settledDeltaOnly)
     {
         if (delta == 0) return (0, 0);
 
         PositionAccounting storage pa = s.positionAccounting[id];
         (uint256 oldRemnantS0, uint256 oldRemnantS1) = (pa.settled.token0, pa.settled.token1);
         (totalApplied, settledDeltaOnly) = _vUpdateSettlementCore(s, id, tokenIndex, delta, pa);
         _syncInactiveRemnantAfterSettledPairChange(s, id, oldRemnantS0, oldRemnantS1);
     }
 
     /// @dev Core settlement mutation split from `_vUpdateSettlement` to avoid stack-too-deep in the outer wrapper.
     function _vUpdateSettlementCore(
         VTSStorage storage s,
         PositionId id,
         uint8 tokenIndex,
         int256 delta,
         PositionAccounting storage pa
     ) private returns (int256 totalApplied, int256 settledDeltaOnly) {
         // Read current values in scoped block
         uint256 cur;
         uint256 c;
         uint256 cumulativeDef;
         {
             cur = pa.settled.get(tokenIndex);
             c = pa.commitmentMax.get(tokenIndex);
             cumulativeDef = pa.cumulativeDeficit.get(tokenIndex);
         }
 
         uint256 next = cur;
         // Track deficit netting by source:
         // - cumulativeDeficitCoverage: decrements pool totalDeficitPrincipal (DICE denominator)
         // - totalDeficitCoverage: used for applied return semantics
         uint256 cumulativeDeficitCoverage = 0;
         uint256 totalDeficitCoverage = 0;
 
         if (delta > 0) {
             // Auto-net any lingering deficit first
             if (cumulativeDef > 0) {
                 uint256 cover = uint256(delta) > cumulativeDef ? cumulativeDef : uint256(delta);
                 if (cover > 0) {
                     cumulativeDef -= cover;
                     delta -= int256(cover);
                     cumulativeDeficitCoverage += cover;
                     totalDeficitCoverage += cover;
                 }
             }
 
             {
                 uint256 coveredCd;
                 (delta, coveredCd) = _netCommitmentDeficitOnPositiveDelta(pa, tokenIndex, delta);
                 totalDeficitCoverage += coveredCd;
             }
 
             // If position-level commitment deficit is fully cured, clear any stored severity bps.
             if (pa.commitmentDeficit.token0 == 0 && pa.commitmentDeficit.token1 == 0) {
                 pa.commitmentDeficitBps = 0;
             }
 
             if (delta > 0) {
                 next = cur + uint256(delta);
                 if (next > c) {
                     // clamp to commitment maxima
                     next = c;
                 }
             }
         } else {
             // Negative delta: reduce settled, never create deficit here
             uint256 subtract = uint256(-delta);
             if (cur < subtract) {
                 subtract = cur;
             }
             next = cur - subtract;
         }
 
         // Write back updated settlement
         pa.settled.set(tokenIndex, next);
         pa.cumulativeDeficit.set(tokenIndex, cumulativeDef);
 
         settledDeltaOnly = next.toInt256() - cur.toInt256();
 
         // Update pool accounting via helper function.
+        // TODO: If this nets cumulativeDeficit for this lane to 0 and both lanes are now 0,
+        // decrement s.commits[pos.commitId].nonzeroCumulativeDeficitCount (with underflow guard).
         // This returns cumulativeDeficitCoverage + settledDelta.
         totalApplied = _updatePoolAccounting(s, id, tokenIndex, cur, next, cumulativeDeficitCoverage);
 
         // Preserve existing semantics: include both cumulativeDeficit and commitmentDeficit netting in applied.
         if (totalDeficitCoverage > cumulativeDeficitCoverage) {
             totalApplied += SafeCast.toInt256(totalDeficitCoverage - cumulativeDeficitCoverage);
         }
     }
 
     /// @dev Increments/decrements `Commit.inactiveRemnantCount` when `isActive` flips but settled pair is unchanged
     ///      (liquidity mirror transition). O(1); no commit-wide scan.
     function _syncInactiveRemnantAfterActiveTransition(
         VTSStorage storage s,
         PositionId positionId,
         bool wasActive,
         uint256 settled0,
         uint256 settled1
     ) private {
         Position storage pos = s.positions[positionId];
         uint256 commitId = pos.commitId;
         if (commitId == 0) return;
 
         bool hasSettled = settled0 > 0 || settled1 > 0;
         bool oldShould = !wasActive && hasSettled;
         bool newShould = !pos.isActive && hasSettled;
         if (oldShould == newShould) return;
 
         if (newShould) {
             unchecked {
                 s.commits[commitId].inactiveRemnantCount++;
             }
         } else {
             uint256 cnt = s.commits[commitId].inactiveRemnantCount;
             if (cnt == 0) {
                 revert Errors.InvariantViolated("inactive remnant count underflow");
             }
             unchecked {
                 s.commits[commitId].inactiveRemnantCount = cnt - 1;
             }
         }
     }
 
     /// @dev Increments/decrements `Commit.inactiveRemnantCount` when only the settled pair changes while inactive.
     function _syncInactiveRemnantAfterSettledPairChange(
         VTSStorage storage s,
         PositionId positionId,
         uint256 oldS0,
         uint256 oldS1
     ) private {
         Position storage pos = s.positions[positionId];
         uint256 commitId = pos.commitId;
         if (commitId == 0) return;
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         bool inactive = !pos.isActive;
         bool oldShould = inactive && (oldS0 > 0 || oldS1 > 0);
         bool newShould = inactive && (pa.settled.token0 > 0 || pa.settled.token1 > 0);
         if (oldShould == newShould) return;
 
         if (newShould) {
             unchecked {
                 s.commits[commitId].inactiveRemnantCount++;
             }
         } else {
             uint256 cnt = s.commits[commitId].inactiveRemnantCount;
             if (cnt == 0) {
                 revert Errors.InvariantViolated("inactive remnant count underflow");
             }
             unchecked {
                 s.commits[commitId].inactiveRemnantCount = cnt - 1;
             }
         }
     }
 
     /// @notice Updates the settlement amount by a delta which could be positive or negative
     /// @dev Shared by both local settlement flows and `VTSLifecycleLinkedLib`'s MM settlement path.
     ///      Nets against cumulative deficit, then derived commit deficit, then applies to settled.
     /// @param s The central VTS storage
     /// @param id The position id
     /// @param tokenIndex The token index (0 or 1)
     /// @param delta The delta of the settlement
     /// @return applied The total amount applied (deficit coverage + settled increase)
     function _updateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta)
         internal
         returns (int256 applied)
     {
         (applied,) = _vUpdateSettlement(s, id, tokenIndex, delta);
     }
 
     // --------------------------------------------------
     // Growth Accounting Helper Functions
     // --------------------------------------------------
 
     /// @notice Compute inside growth for a position range using Uniswap-style "global/outside" accounting.
     /// @dev This mirrors Uniswap v4 core fee accounting:
     ///      - Branching formula: `Pool.getFeeGrowthInside()` in
     ///        `contracts/evm/lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol`
     ///      - Unchecked arithmetic is used intentionally to match Uniswap's modulo \(2^{256}\) behaviour.
     ///
     ///      Intuition:
     ///      - `global*` accumulators are "amount-per-liquidity-unit" in Q128.
     ///      - `outsideMap[poolId][tick]` stores growth on the _other_ side of that tick relative to the current tick,
     ///        maintained by flipping on each tick cross (see `VTSSwapLib._flipOutside`, derived from `Pool.crossTick`).
     ///      - "inside growth" for [tickLower, tickUpper) depends on where the current tick sits relative to the range.
     /// @param poolId The pool ID
     /// @param tickLower The lower tick
     /// @param tickUpper The upper tick
     /// @param tickCurrent The current pool tick
     /// @param global0 The global growth for token0
     /// @param global1 The global growth for token1
     /// @param outsideMap The outside growth mapping (deficitGrowthOutside or inflowGrowthOutside)
     /// @return inside0 The inside growth for token0
     /// @return inside1 The inside growth for token1
     function _growthInside(
         PoolId poolId,
         int24 tickLower,
         int24 tickUpper,
         int24 tickCurrent,
         uint256 global0,
         uint256 global1,
         mapping(PoolId => mapping(int24 => GrowthPair)) storage outsideMap
     ) private view returns (uint256 inside0, uint256 inside1) {
         GrowthPair memory lower = outsideMap[poolId][tickLower];
         GrowthPair memory upper = outsideMap[poolId][tickUpper];
         inside0 = _growthInsideSingle(global0, lower.token0, upper.token0, tickCurrent, tickLower, tickUpper);
         inside1 = _growthInsideSingle(global1, lower.token1, upper.token1, tickCurrent, tickLower, tickUpper);
     }
 
     /// @notice Compute inside growth for a single token, branching on current tick (Uniswap-style)
     /// @dev Derived from Uniswap v4 core `Pool.getFeeGrowthInside()`:
     ///      `contracts/evm/lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol`.
     ///
     ///      Why branching matters:
     ///      - Growth accrues to the active tick/liquidity at the moment it occurs (in our case, per swap segment).
     ///      - A position should only accrue growth while it is in-range (i.e. while current tick is within its bounds).
     ///      - When out-of-range, the position's "inside growth" should remain stable until price re-enters the range.
     ///
     ///      Why `unchecked`:
     ///      - Uniswap treats these accumulators as values modulo \(2^{256}\) (wraparound is acceptable and expected).
     function _growthInsideSingle(
         uint256 global,
         uint256 outsideLower,
         uint256 outsideUpper,
         int24 tickCurrent,
         int24 tickLower,
         int24 tickUpper
     ) private pure returns (uint256 inside) {
         unchecked {
             if (tickCurrent < tickLower) {
                 // Current tick below range: inside = outsideLower - outsideUpper
                 inside = outsideLower - outsideUpper;
             } else if (tickCurrent >= tickUpper) {
                 // Current tick at/above range: inside = outsideUpper - outsideLower
                 inside = outsideUpper - outsideLower;
             } else {
                 // Current tick inside range: inside = global - outsideLower - outsideUpper
                 inside = global - outsideLower - outsideUpper;
             }
         }
     }
 
     /// @notice Compute delta and checkpoint for growth settlement
     /// @dev This is the exact same pattern as Uniswap fees:
     ///      owed = (growthInsideNow - growthInsideLast) * liquidity / Q128, then checkpoint growthInsideLast = growthInsideNow.
     ///
     ///      We checkpoint *before* liquidity changes (see `CoreHook._beforeAddLiquidity/_beforeRemoveLiquidity`) to ensure:
     ///      - no retroactive capture (new liquidity cannot claim historical accrual), and
     ///      - fair attribution across partial adds/removes.
     /// @param pa The position accounting storage reference
     /// @param outsideMap The outside growth mapping
     /// @param p Growth parameters bundled in a struct (poolId, ticks, liquidity, globals, growthType)
     /// @return add0 The attributed growth delta for token0
     /// @return add1 The attributed growth delta for token1
     function _deltaAndCheckpointGrowth(
         PositionAccounting storage pa,
         mapping(PoolId => mapping(int24 => GrowthPair)) storage outsideMap,
         GrowthParams memory p
     ) private returns (uint256 add0, uint256 add1) {
         (uint256 inside0, uint256 inside1) = _growthInside(
             p.poolId, p.tickLower, p.tickUpper, p.tickCurrent, p.global0, p.global1, outsideMap
         );
 
         // Read last snapshots based on field identifier
         uint256 lastSnap0;
         uint256 lastSnap1;
         if (!p.isInflow) {
             lastSnap0 = pa.deficitGrowthInsideLast.token0;
             lastSnap1 = pa.deficitGrowthInsideLast.token1;
             pa.deficitGrowthInsideLast.token0 = inside0;
             pa.deficitGrowthInsideLast.token1 = inside1;
         } else {
             lastSnap0 = pa.inflowGrowthInsideLast.token0;
             lastSnap1 = pa.inflowGrowthInsideLast.token1;
             pa.inflowGrowthInsideLast.token0 = inside0;
             pa.inflowGrowthInsideLast.token1 = inside1;
         }
 
         unchecked {
             uint256 d0 = inside0 - lastSnap0;
             uint256 d1 = inside1 - lastSnap1;
             if (p.liquidity > 0) {
                 if (d0 > 0) {
                     add0 = FullMath.mulDiv(d0, uint256(p.liquidity), FixedPoint128.Q128);
                 }
                 if (d1 > 0) {
                     add1 = FullMath.mulDiv(d1, uint256(p.liquidity), FixedPoint128.Q128);
                 }
             }
         }
     }
 
     /// @notice Settle deficit growth for a position into cumulativeDeficit in raw token units
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     //#olympix-ignore-reentrancy
     function _settlePositionDeficitGrowth(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
         internal
     {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         // Calculate growth delta in scoped block
         uint256 add0;
         uint256 add1;
         {
             (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, poolId);
             uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));
 
             (add0, add1) = _deltaAndCheckpointGrowth(
                 pa,
                 s.deficitGrowthOutside,
                 GrowthParams({
                     poolId: poolId,
                     tickLower: pos.tickLower,
                     tickUpper: pos.tickUpper,
                     tickCurrent: tickCurrent,
                     liquidity: liq,
                     global0: paPool.deficitGrowthGlobal.token0,
                     global1: paPool.deficitGrowthGlobal.token1,
                     isInflow: false
                 })
             );
         }
 
         // Process token0 deficit in scoped block
         if (add0 > 0) {
             // Track full attributed outflows for fee sharing normalisation window
             pa.cumulativeOutflows.token0 += add0;
 
             // Consume settled coverage first, then accrue shortfall to deficit
             uint256 s0 = pa.settled.token0;
             if (s0 >= add0) {
                 _sUpdateSettlement(s, positionId, 0, -add0.toInt256());
             } else {
                 uint256 deficitIncrease = add0 - s0;
                 pa.cumulativeDeficit.token0 += deficitIncrease;
+                // TODO: If this toggles cumulativeDeficit from 0 -> >0 for this position, increment
+                // s.commits[pos.commitId].nonzeroCumulativeDeficitCount (commit-level O(1) counter).
                 // DICE: Track pool-wide deficit principal increase
                 paPool.totalDeficitPrincipal.token0 += deficitIncrease;
                 // DICE: Flush any pending coverage residual now that principal exists
                 VTSFeeLinkedLib.flushCoverageResidualIfNeeded(s, poolId, 0);
                 _sUpdateSettlement(s, positionId, 0, -s0.toInt256());
             }
         }
 
         // Process token1 deficit in scoped block
         if (add1 > 0) {
             pa.cumulativeOutflows.token1 += add1;
             uint256 s1 = pa.settled.token1;
             if (s1 >= add1) {
                 _sUpdateSettlement(s, positionId, 1, -add1.toInt256());
             } else {
                 uint256 deficitIncrease = add1 - s1;
                 pa.cumulativeDeficit.token1 += deficitIncrease;
+                // NOTE: Mirror the 0 -> >0 toggle handling for token1 as above (increment commit-level counter).
+                // Avoid double-incrementing when both lanes toggle in the same call.
                 // DICE: Track pool-wide deficit principal increase
                 paPool.totalDeficitPrincipal.token1 += deficitIncrease;
                 // DICE: Flush any pending coverage residual now that principal exists
                 VTSFeeLinkedLib.flushCoverageResidualIfNeeded(s, poolId, 1);
                 _sUpdateSettlement(s, positionId, 1, -s1.toInt256());
             }
         }
     }
 
     /// @notice Settle inflow growth for a position: first extinguish deficits, then credit remaining as proactive liquidity
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     function _settlePositionInflowGrowth(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
         internal
     {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
         // Current tick is required for correct inside-growth branching (Uniswap-style).
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, poolId);
         uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));
 
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         (uint256 add0, uint256 add1) = _deltaAndCheckpointGrowth(
             pa,
             s.inflowGrowthOutside,
             GrowthParams({
                 poolId: poolId,
                 tickLower: pos.tickLower,
                 tickUpper: pos.tickUpper,
                 tickCurrent: tickCurrent,
                 liquidity: liq,
                 global0: paPool.inflowGrowthGlobal.token0,
                 global1: paPool.inflowGrowthGlobal.token1,
                 isInflow: true
             })
         );
 
         // Token0: net against deficit first
         if (add0 > 0) {
             // Auto-net and apply via centralised updater
             _sUpdateSettlement(s, positionId, 0, add0.toInt256());
         }
 
         // Token1: net against deficit first
         if (add1 > 0) {
             // Auto-net and apply via centralised updater
             _sUpdateSettlement(s, positionId, 1, add1.toInt256());
         }
     }
 
     /// @dev If Uniswap position liquidity changed without `touchPosition` (e.g. paused remove-liquidity in CoreHook),
     ///      `feeBurnGrowthRemainder` is invalid for the new denominator; clear it.
     ///      We do not overwrite `pos.liquidity` here: harness-only setups may diverge from PoolManager reads; the next
     ///      `touchPosition` still updates the mirror. DICE/coverage burn uses `StateLibrary.getPositionLiquidity` for L.
     function _reconcileLiquidityMirrorAndFeeBurnRemainder(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId
     ) private {
         Position storage pos = s.positions[positionId];
         if (pos.owner == address(0)) return;
 
         uint128 liqLive = StateLibrary.getPositionLiquidity(poolManager, pos.poolId, PositionId.unwrap(positionId));
         if (uint256(pos.liquidity) != uint256(liqLive)) {
             PositionAccounting storage pa = s.positionAccounting[positionId];
             pa.feeBurnGrowthRemainder.token0 = 0;
             pa.feeBurnGrowthRemainder.token1 = 0;
         }
     }
 
     /// @notice Settle both deficit, inflow, and coverage growth for a position
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     //#olympix-ignore-reentrancy
     function settlePositionGrowths(VTSStorage storage s, IPoolManager poolManager, PositionId positionId) public {
         _reconcileLiquidityMirrorAndFeeBurnRemainder(s, poolManager, positionId);
 
         VTSFeeLinkedLib.settleSettledIndexedCoverageUsage(s, positionId);
 
         _settlePositionDeficitGrowth(s, poolManager, positionId);
         // DICE ordering invariant:
         // Before decreasing cumulativeDeficit, we must reconcile the position up to the current
         // coverage-per-deficit index. If inflow netting runs first, the position shrinks principal
         // before we apply already-exercised coverage, understating burn and letting it evade charges
         // incurred while that principal was outstanding.
         VTSFeeLinkedLib.settleDeficitIndexedCoverageUsage(s, poolManager, positionId);
         // Only after DICE has been settled may inflow repay/net principal.
         _settlePositionInflowGrowth(s, poolManager, positionId);
     }
 
     // --------------------------------------------------
     // Position Registration and Management
     // --------------------------------------------------
 
     /// @notice Register a new position in VTSStorage
     /// @param s The VTS storage
     /// @param owner The owner of the position
     /// @param poolId The pool id
     /// @param params The modify liquidity params
     function _registerPosition(
         VTSStorage storage s,
         address owner,
         PoolId poolId,
         ModifyLiquidityParams calldata params
     ) internal {
         // Derive position id consistent with Uniswap position keying
         PositionId id = PositionLibrary.generateId(owner, params);
 
         // Check if already registered
         if (s.positions[id].owner != address(0)) {
             revert Errors.AlreadyRegistered(id);
         }
 
         // Register the position in VTSStorage
         s.positions[id] = Position({
             owner: owner,
             poolId: poolId,
             commitId: 0, // Will be set when position is associated with a commit
             tickLower: params.tickLower,
             tickUpper: params.tickUpper,
             liquidity: SafeCast.toUint128(uint256(params.liquidityDelta)),
             isActive: true,
             salt: params.salt,
             checkpoint: RFSCheckpoint({
                 openMask: 0, openSince0: 0, openSince1: 0, gracePeriodExtension0: 0, gracePeriodExtension1: 0
             })
         });
     }
 
     function _rfsOpenMask(BalanceDelta delta) internal pure returns (uint8 openMask) {
         if (delta.amount0() > 0) {
             openMask |= 1;
         }
         if (delta.amount1() > 0) {
             openMask |= 2;
         }
     }
 
     /// @notice Link a position to a commit
     /// @param s The VTS storage
     /// @param positionId The position id
     /// @param commitId The token id (commit id)
     function _linkPositionToCommit(VTSStorage storage s, PositionId positionId, uint256 commitId) internal {
         // validate there is an existing commit for the token id
         if (s.commits[commitId].expiresAt <= block.timestamp) {
             revert Errors.InvalidSignal(commitId);
         }
 
         // Get current position count to use as index for the new position
         uint256 currentPositionCount = s.commits[commitId].positionCount;
 
         // modify the commit to include the position and update the position count
         s.commits[commitId].positions[currentPositionCount] = positionId;
         s.commits[commitId].positionCount++;
 
         // update the commitId of the position i.e associate the position with the commit
         s.positions[positionId].commitId = commitId;
     }
 
     /// @notice Calculate RFS (Required for Settlement) for a position
     /// @param s The VTS storage
     /// @param poolManager The pool manager
     /// @param id The position id
     /// @param requireClosedRfS Whether to require the RFS to be closed
     /// @return rfsOpen Whether the RFS is open
     /// @return delta The RFS delta
     function calcRFS(VTSStorage storage s, IPoolManager poolManager, PositionId id, bool requireClosedRfS)
         public
         returns (bool rfsOpen, BalanceDelta delta)
     {
         // Settle position growths before calculating RFS
         settlePositionGrowths(s, poolManager, id);
 
         (rfsOpen, delta) = getRFS(s, id);
         if (requireClosedRfS && rfsOpen) {
             revert Errors.RFSOpenForPosition(id);
         }
     }
 
     /// @dev Snapshot parameters for init position
     struct SnapshotParams {
         PoolId poolId;
         int24 tickLower;
         int24 tickUpper;
         int24 tickCurrent;
     }
 
     /// @dev Initialise deficit growth snapshot
     function _initDeficitSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         (uint256 d0, uint256 d1) = _growthInside(
             sp.poolId,
             sp.tickLower,
             sp.tickUpper,
             sp.tickCurrent,
             paPool.deficitGrowthGlobal.token0,
             paPool.deficitGrowthGlobal.token1,
             s.deficitGrowthOutside
         );
         pa.deficitGrowthInsideLast.token0 = d0;
         pa.deficitGrowthInsideLast.token1 = d1;
     }
 
     /// @dev Initialise inflow growth snapshot
     function _initInflowSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         (uint256 i0, uint256 i1) = _growthInside(
             sp.poolId,
             sp.tickLower,
             sp.tickUpper,
             sp.tickCurrent,
             paPool.inflowGrowthGlobal.token0,
             paPool.inflowGrowthGlobal.token1,
             s.inflowGrowthOutside
         );
         pa.inflowGrowthInsideLast.token0 = i0;
         pa.inflowGrowthInsideLast.token1 = i1;
     }
 
     /// @dev Initialise fee growth snapshot
     function _initFeeSnapshot(IPoolManager poolManager, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, sp.poolId, sp.tickLower, sp.tickUpper);
         pa.feeGrowthInsideLast.token0 = fg0;
         pa.feeGrowthInsideLast.token1 = fg1;
         pa.feeBurnGrowthRemainder.token0 = 0;
         pa.feeBurnGrowthRemainder.token1 = 0;
     }
 
     /// @dev Initialise DICE coverage index snapshot
     /// @notice Sets coverageIndexLastX128 to current pool coveragePerDeficitIndexX128
     ///         to prevent new positions from inheriting historical coverage charges
     function _initCoverageSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         // DICE: Initialize coverage index checkpoint to current pool index
         // This ensures new positions don't inherit historical coverage charges
         pa.coverageIndexLastX128.token0 = paPool.coveragePerDeficitIndexX128.token0;
         pa.coverageIndexLastX128.token1 = paPool.coveragePerDeficitIndexX128.token1;
         pa.residualCoverageIndexLastX128.token0 = paPool.coveragePerResidualDeficitIndexX128.token0;
         pa.residualCoverageIndexLastX128.token1 = paPool.coveragePerResidualDeficitIndexX128.token1;
     }
 
     /// @dev Initialise CISE coverage index snapshot
     /// @notice Sets ciseIndexLastX128 to current pool coveragePerSettledIndexX128
     ///         to prevent new positions from inheriting historical settled-indexed coverage
     function _initCISESnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp) private {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         pa.ciseIndexLastX128.token0 = paPool.coveragePerSettledIndexX128.token0;
         pa.ciseIndexLastX128.token1 = paPool.coveragePerSettledIndexX128.token1;
     }
 
     /// @dev Seed per-tick outside growth snapshots when a tick is initialised by this liquidity add.
     ///      This moves first-write cost from swap-time tick crossing to modify-liquidity time.
     ///      Mirrors Uniswap initialisation semantics: if tick <= currentTick, outside starts at global, else 0.
     function _seedOutsideGrowthForNewlyInitializedTicks(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolId poolId,
         ModifyLiquidityParams calldata params
     ) private {
         if (params.liquidityDelta <= 0) return;
 
         uint128 addLiq = uint256(params.liquidityDelta).toUint128();
         (uint128 lowerGross,) = StateLibrary.getTickLiquidity(poolManager, poolId, params.tickLower);
         (uint128 upperGross,) = StateLibrary.getTickLiquidity(poolManager, poolId, params.tickUpper);
 
         bool lowerInitializedByThisAdd = lowerGross == addLiq;
         bool upperInitializedByThisAdd = upperGross == addLiq;
         if (!lowerInitializedByThisAdd && !upperInitializedByThisAdd) return;
 
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, poolId);
         PoolAccounting storage paPool = s.poolAccounting[poolId];
 
         if (lowerInitializedByThisAdd) {
             _seedOutsideAtInitializedTick(s, paPool, poolId, params.tickLower, tickCurrent);
         }
         if (upperInitializedByThisAdd && params.tickUpper != params.tickLower) {
             _seedOutsideAtInitializedTick(s, paPool, poolId, params.tickUpper, tickCurrent);
         }
     }
 
     function _seedOutsideAtInitializedTick(
         VTSStorage storage s,
         PoolAccounting storage paPool,
         PoolId poolId,
         int24 tick,
         int24 tickCurrent
     ) private {
         if (tick > tickCurrent) return;
 
         s.deficitGrowthOutside[poolId][tick].token0 = paPool.deficitGrowthGlobal.token0;
         s.deficitGrowthOutside[poolId][tick].token1 = paPool.deficitGrowthGlobal.token1;
         s.inflowGrowthOutside[poolId][tick].token0 = paPool.inflowGrowthGlobal.token0;
         s.inflowGrowthOutside[poolId][tick].token1 = paPool.inflowGrowthGlobal.token1;
     }
 
     /// @notice Checkpoint the tick-indexed growth snapshots at the current pool state.
     /// @dev Used for both first-time registration and inactive-position reactivation so zero-liquidity intervals
     ///      cannot be retroactively attributed to freshly added liquidity.
     function _checkpointTickIndexedSnapshots(VTSStorage storage s, IPoolManager poolManager, PositionId id) internal {
         Position memory pos = s.positions[id];
         PoolId p = pos.poolId;
         PositionAccounting storage pa = s.positionAccounting[id];
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, p);
 
         SnapshotParams memory sp =
             SnapshotParams({poolId: p, tickLower: pos.tickLower, tickUpper: pos.tickUpper, tickCurrent: tickCurrent});
 
         _initDeficitSnapshot(s, pa, sp);
         _initInflowSnapshot(s, pa, sp);
         _initFeeSnapshot(poolManager, pa, sp);
     }
 
     /// @notice Rebase zero-principal settlement snapshots during inactive-position reactivation.
     /// @dev Only lanes with no current settled / deficit principal are checkpointed to current pool indices.
     ///      Non-zero lanes keep their historical checkpoints so previously-earned DICE / CISE state is preserved.
     function _checkpointZeroPrincipalSettlementSnapshots(VTSStorage storage s, PositionId id) internal {
         Position memory pos = s.positions[id];
         PositionAccounting storage pa = s.positionAccounting[id];
         PoolAccounting storage paPool = s.poolAccounting[pos.poolId];
 
         if (pa.cumulativeDeficit.token0 == 0) {
             pa.coverageIndexLastX128.token0 = paPool.coveragePerDeficitIndexX128.token0;
             pa.residualCoverageIndexLastX128.token0 = paPool.coveragePerResidualDeficitIndexX128.token0;
         }
         if (pa.cumulativeDeficit.token1 == 0) {
             pa.coverageIndexLastX128.token1 = paPool.coveragePerDeficitIndexX128.token1;
             pa.residualCoverageIndexLastX128.token1 = paPool.coveragePerResidualDeficitIndexX128.token1;
         }
         if (pa.settled.token0 == 0) {
             pa.ciseIndexLastX128.token0 = paPool.coveragePerSettledIndexX128.token0;
         }
         if (pa.settled.token1 == 0) {
             pa.ciseIndexLastX128.token1 = paPool.coveragePerSettledIndexX128.token1;
         }
     }
 
     /**
      * @notice Initializes the snapshots for a position. Prevents new positions from inheriting historical tick-indexed growths.
      * @param s The central VTS storage
      * @param poolManager The pool manager contract
      * @param id The id of the position
      */
     function _initPositionSnapshots(VTSStorage storage s, IPoolManager poolManager, PositionId id) internal {
         PositionAccounting storage pa = s.positionAccounting[id];
 
         _checkpointTickIndexedSnapshots(s, poolManager, id);
 
         Position memory pos = s.positions[id];
         PoolId p = pos.poolId;
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, p);
         SnapshotParams memory sp =
             SnapshotParams({poolId: p, tickLower: pos.tickLower, tickUpper: pos.tickUpper, tickCurrent: tickCurrent});
 
         _initCoverageSnapshot(s, pa, sp);
         _initCISESnapshot(s, pa, sp);
     }
 
     /// @notice Touch a position to update its state, process fees, and handle MM-specific operations
     /// @dev Single entry point for position processing - handles registration, linking, fee processing,
     ///      delta accounting, LCC issuance/cancellation, and checkpoint marking
     /// @param s The VTS storage
     /// @param ctx The position context containing dependency references (poolManager, liquidityHub, etc.)
     /// @param p The touchPosition parameters (owner, poolKey, params, callerDelta, feesAccrued, hookData)
     /// @return result The touchPosition result (pos, id, feeAdj)
     /// @notice Decoded hook data for touch position operations
     struct TouchPositionHookData {
         bool isMMOperation;
         bool isSeizing;
         uint256 commitId;
     }
 
     /// @notice Decodes and validates hook data for touch position
     /// @dev Effective `isSeizing` is only true for MM operations (`commitId > 0`) with `seizure.isSeizing`.
     ///      Non-MM callers cannot grant seizure semantics by forging hook bytes.
     /// @param hookData The raw hook data bytes
     /// @return data The decoded hook data struct
     function _decodeHookData(bytes calldata hookData) private pure returns (TouchPositionHookData memory data) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
         data.isMMOperation = PositionModificationHookDataLib.isMMOperation(mmData);
         data.commitId = mmData.commitId;
         data.isSeizing = data.isMMOperation && mmData.seizure.isSeizing;
     }
 
     /// @notice Handles new position initialization and returns required settlement delta
     function _touchNewPosition(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolId poolId,
         address owner,
         ModifyLiquidityParams calldata params,
         PositionId positionId,
         uint128 liveLiquidityAfterModify,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         if (hookData.isMMOperation && hookData.isSeizing) {
             revert Errors.InvariantViolated("Invalid operation: Seizures cannot issue LCCs");
         }
 
         _registerPosition(s, owner, poolId, params);
 
         if (hookData.isMMOperation && hookData.commitId > 0) {
             _linkPositionToCommit(s, positionId, hookData.commitId);
         }
 
         _initPositionSnapshots(s, poolManager, positionId);
         if (uint256(params.liquidityDelta).toUint128() != liveLiquidityAfterModify) {
             revert Errors.InvariantViolated("live liquidity mismatch on new position touch");
         }
         _trackCommitment(s, positionId, liveLiquidityAfterModify);
 
         TokenPairUint memory commitmentMaxima = s.positionAccounting[positionId].commitmentMax;
 
         if (hookData.isMMOperation) {
             MarketVTSConfiguration memory vtsConfiguration = s.pools[poolId].vtsConfig;
             (uint256 amountToSettle0, uint256 amountToSettle1) = LiquidityUtils.getBaseSettlementAmounts(
                 commitmentMaxima.token0,
                 commitmentMaxima.token1,
                 vtsConfiguration.token0.baseVTSRate,
                 vtsConfiguration.token1.baseVTSRate
             );
             requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(amountToSettle0, amountToSettle1, true, true);
         } else {
             _sUpdateSettlement(s, positionId, 0, SafeCast.toInt256(commitmentMaxima.token0));
             _sUpdateSettlement(s, positionId, 1, SafeCast.toInt256(commitmentMaxima.token1));
             requiredSettlementDelta = BalanceDelta.wrap(0);
         }
     }
 
     /// @notice Handles existing position decrease: RFS gate, commitment tracking, settled clamp / MM excess delta.
     /// @param currentLiq Live PoolManager liquidity after the remove (same as unpaused `touchPosition` decrease path).
     /// @dev RFS uses `getRFS` only; growth is already settled in CoreHook `_beforeRemoveLiquidity` — avoid `calcRFS` here
     ///      so we do not re-enter `settlePositionGrowths` (would double-apply CISE / growth side-effects in the same modify).
     function _touchExistingDecrease(
         VTSStorage storage s,
         PositionId positionId,
         ModifyLiquidityParams calldata params,
         uint128 currentLiq,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         Position memory posDec = s.positions[positionId];
         if (params.tickLower != posDec.tickLower || params.tickUpper != posDec.tickUpper) {
             revert Errors.InvariantViolated("modify tick mismatch");
         }
         // Growth is already settled in CoreHook `_beforeRemoveLiquidity`; avoid `calcRFS` here so we do not
         // re-enter `settlePositionGrowths` (would double-apply CISE / growth side-effects in the same modify).
         // RFS-open removes revert unless this is an authorised MM seizure decrease (`isMMOperation && isSeizing`);
         // non-MM forged `seizure.isSeizing` is cleared in `_decodeHookData`.
         if (!(hookData.isMMOperation && hookData.isSeizing)) {
             (bool rfsOpen,) = getRFS(s, positionId);
             if (rfsOpen) {
                 revert Errors.RFSOpenForPosition(positionId);
             }
         }
         _trackCommitment(s, positionId, currentLiq);
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         (uint256 excess0, uint256 excess1) = _computeSettledExcessAgainstCommitmentMax(pa, currentLiq);
 
         if (hookData.isMMOperation) {
             requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(excess0, excess1, false, false);
         } else {
             _applySettlementClampFromExcess(s, positionId, excess0, excess1);
             requiredSettlementDelta = BalanceDelta.wrap(0);
         }
     }
 
     /// @notice Handles existing position increase and returns required settlement delta
     function _touchExistingIncrease(
         VTSStorage storage s,
         PoolId poolId,
         PositionId positionId,
         ModifyLiquidityParams calldata params,
         uint128 liveLiquidityAfterModify,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         Position memory posInc = s.positions[positionId];
         if (params.tickLower != posInc.tickLower || params.tickUpper != posInc.tickUpper) {
             revert Errors.InvariantViolated("modify tick mismatch");
         }
         _trackCommitment(s, positionId, liveLiquidityAfterModify);
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         uint256 s0 = pa.settled.token0;
         uint256 s1 = pa.settled.token1;
         TokenPairUint memory commitmentMaxima = pa.commitmentMax;
 
         if (hookData.isMMOperation) {
             if (hookData.isSeizing) {
                 revert Errors.InvariantViolated("Invalid operation: Seizures cannot issue LCCs");
             }
 
             MarketVTSConfiguration memory vtsConfiguration = s.pools[poolId].vtsConfig;
             (uint256 baseAmountToSettle0, uint256 baseAmountToSettle1) = LiquidityUtils.getBaseSettlementAmounts(
                 commitmentMaxima.token0,
                 commitmentMaxima.token1,
                 vtsConfiguration.token0.baseVTSRate,
                 vtsConfiguration.token1.baseVTSRate
             );
             uint256 excess0 = baseAmountToSettle0 > s0 ? baseAmountToSettle0 - s0 : 0;
             uint256 excess1 = baseAmountToSettle1 > s1 ? baseAmountToSettle1 - s1 : 0;
             requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(excess0, excess1, true, true);
         } else {
             _sUpdateSettlement(s, positionId, 0, SafeCast.toInt256(commitmentMaxima.token0) - SafeCast.toInt256(s0));
             _sUpdateSettlement(s, positionId, 1, SafeCast.toInt256(commitmentMaxima.token1) - SafeCast.toInt256(s1));
             requiredSettlementDelta = BalanceDelta.wrap(0);
         }
     }
 
     /// @dev Extracted to keep `touchPosition` stack-safe when branching on fee-cap policy.
     function _afterTouchPositionFees(
         VTSStorage storage s,
         PositionId positionId,
         BalanceDelta feesAccrued,
         bool capPositiveSlashToFeesAccrued
     ) private returns (BalanceDelta feeAdj) {
         if (!capPositiveSlashToFeesAccrued) {
             return VTSFeeLinkedLib.afterTouchPosition(s, positionId);
         }
         int128 fa0 = feesAccrued.amount0();
         int128 fa1 = feesAccrued.amount1();
         uint256 positiveCap0 = fa0 > 0 ? uint256(uint128(fa0)) : 0;
         uint256 positiveCap1 = fa1 > 0 ? uint256(uint128(fa1)) : 0;
         return VTSFeeLinkedLib.afterTouchPositionWithPositiveCaps(s, positionId, positiveCap0, positiveCap1);
     }
 
     //#olympix-ignore-reentrancy
     function touchPosition(VTSStorage storage s, PositionContext memory ctx, TouchPositionParams calldata p)
         external
         returns (TouchPositionResult memory result)
     {
         PoolId poolId = p.poolKey.toId();
         bool isPaused = s.isPaused || s.pools[poolId].isPaused;
         if (isPaused && p.params.liquidityDelta >= 0) {
             revert Errors.EnforcedPause();
         }
         _seedOutsideGrowthForNewlyInitializedTicks(s, ctx.poolManager, poolId, p.params);
 
         result.id = PositionLibrary.generateId(p.owner, p.params);
         Position storage posStorage = s.positions[result.id];
         bool isNewPosition = posStorage.owner == address(0);
         uint256 initialLiquidity = posStorage.liquidity;
         uint128 liq = ctx.poolManager.getPositionLiquidity(poolId, PositionId.unwrap(result.id));
 
         TouchPositionHookData memory hookData = _decodeHookData(p.hookData);
         BalanceDelta requiredSettlementDelta;
 
         if (isNewPosition) {
             if (p.params.liquidityDelta <= 0) {
                 revert Errors.InvalidPosition(0, 0, result.id);
             }
             // NEW POSITION
             requiredSettlementDelta =
                 _touchNewPosition(s, ctx.poolManager, poolId, p.owner, p.params, result.id, liq, hookData);
         } else {
             // EXISTING POSITION (active or previously inactive)
 
             // Validate no mismatch if commit ID present.
             if (hookData.isMMOperation && hookData.commitId != posStorage.commitId) {
                 revert Errors.InvariantViolated("Invalid operation: Commit ID mismatch");
             }
 
             // Insolvency freeze: do not allow non-seizure MM liquidity changes while commitment deficit persists.
             // Settlement, checkpoint(withCommitment), and seizure paths remain the intended cure/formalise surfaces.
             if (hookData.isMMOperation && !hookData.isSeizing && p.params.liquidityDelta != 0) {
                 PositionAccounting storage paGuard = s.positionAccounting[result.id];
                 if (paGuard.commitmentDeficit.token0 > 0 || paGuard.commitmentDeficit.token1 > 0) {
                     revert Errors.CommitmentDeficitBlocksLiquidityChange(result.id);
                 }
             }
 
             if (p.params.liquidityDelta < 0) {
                 // Disallow decreases on previously-inactive positions. (If liq == 0, Uniswap will revert anyway.)
                 if (!posStorage.isActive) revert Errors.NotActive(result.id);
                 requiredSettlementDelta = _touchExistingDecrease(s, result.id, p.params, liq, hookData);
                 // Mirror using live PoolManager liquidity post-modify for both paused and unpaused removes.
                 PositionAccounting storage paDec = s.positionAccounting[result.id];
                 if (liq == 0) {
                     _captureResidualFeeBackingOnFullDeactivation(
                         s, ctx.poolManager, result.id, liq, p.params.liquidityDelta
                     );
                 } else {
                     uint128 removedLiquidity = uint256(-p.params.liquidityDelta).toUint128();
                     VTSFeeLinkedLib.captureResidualFeeBackingOnPartialDecrease(
                         s, ctx.poolManager, result.id, removedLiquidity
                     );
                 }
                 _applyLiquidityMirrorTransition(s, result.id, paDec, posStorage, initialLiquidity, liq);
             } else {
                 (uint128 liveLiquidityBeforeAdd, uint128 nextLiquidity) =
                     _deriveIncreaseTransitionLiquidity(liq, p.params.liquidityDelta);
                 if (p.params.liquidityDelta > 0) {
                     // Allow re-activating a previously inactive position by adding liquidity.
                     // Logically required to build on value routing while collecting fees on inactive positions.
                     // Rebase tick-indexed snapshots first so the zero-liquidity interval is not charged/credited to
                     // the newly reactivated liquidity.
                     if (liveLiquidityBeforeAdd == 0) {
                         _checkpointTickIndexedSnapshots(s, ctx.poolManager, result.id);
                         _checkpointZeroPrincipalSettlementSnapshots(s, result.id);
                     }
                     requiredSettlementDelta =
                         _touchExistingIncrease(s, poolId, result.id, p.params, nextLiquidity, hookData);
                     if (liveLiquidityBeforeAdd > 0) {
                         _rebaseResidualFeeGrowthOnActiveIncrease(
                             s, ctx.poolManager, poolId, result.id, liveLiquidityBeforeAdd
                         );
                     }
                 } else {
                     // Allow a no-op when active (Uniswap v4 disallows this when initial liq == 0).
                     // See https://github.com/Uniswap/v4-core/blob/36d790b1a3af38461453a13a6ff395290fbc11b2/src/libraries/Position.sol#L86
                     // Refresh commitment maxima from live liquidity (e.g. mirror desync or post-migration).
                     _trackCommitment(s, result.id, liq);
                     requiredSettlementDelta = BalanceDelta.wrap(0);
                 }
                 PositionAccounting storage paRem = s.positionAccounting[result.id];
                 _applyLiquidityMirrorTransition(
                     s, result.id, paRem, posStorage, uint256(liveLiquidityBeforeAdd), nextLiquidity
                 );
             }
         }
 
         if (isNewPosition) {
             _updateStatus(s, result.id, posStorage, initialLiquidity, liq);
         }
 
         // On any liquidity decrease, cap same-touch positive `pendingFeeAdj` materialisation to the
         // per-leg informational `feesAccrued` slice; excess remains banked in `pendingFeeAdj` (SETTLE-03).
         result.feeAdj = _afterTouchPositionFees(s, result.id, p.feesAccrued, p.params.liquidityDelta < 0);
 
         if (hookData.isMMOperation) {
             VTSPositionMMOpsLib.processMMOperations(s, ctx, p, result, requiredSettlementDelta);
         }
 
         // Refresh from storage after the MM tail. `processMMOperations` is an external linked-library call; mutating
         // `TouchPositionResult` inside it does not update this caller's memory return value.
         result.pos = s.positions[result.id];
     }
 
     /// @notice Update active status based on liquidity transitions
     /// @dev Extracted to reduce stack pressure in touchPosition
     function _updateActiveStatus(
         VTSStorage storage s,
         Position storage posStorage,
         uint256 initialLiquidity,
         uint128 liq
     ) internal {
         // Update active status based on liquidity
         // Track transitions to update activePositionCount for commits
         uint256 commitId = posStorage.commitId;
 
         if (liq == 0) {
             posStorage.isActive = false;
             // Decrement activePositionCount if transitioning from active(liq > 0) to inactive(liq == 0)
             if (initialLiquidity > 0 && commitId > 0) {
                 s.commits[commitId].activePositionCount--;
             }
         } else {
             posStorage.isActive = true;
             // Increment activePositionCount if transitioning from inactive(liq == 0) to active(liq > 0)
             if (initialLiquidity == 0 && commitId > 0) {
                 s.commits[commitId].activePositionCount++;
             }
         }
     }
 
     /// @dev Runs `_updateActiveStatus` then `Commit.inactiveRemnantCount` sync in a separate stack frame.
     function _updateStatus(
         VTSStorage storage s,
         PositionId positionId,
         Position storage posStorage,
         uint256 initialLiquidity,
         uint128 liq
     ) private {
         bool wasActive = posStorage.isActive;
         PositionAccounting storage pa = s.positionAccounting[positionId];
         uint256 s0 = pa.settled.token0;
         uint256 s1 = pa.settled.token1;
         _updateActiveStatus(s, posStorage, initialLiquidity, liq);
         _syncInactiveRemnantAfterActiveTransition(s, positionId, wasActive, s0, s1);
     }
 
     function _deriveIncreaseTransitionLiquidity(uint128 liq, int256 liquidityDelta)
         internal
         pure
         returns (uint128 liveLiquidityBeforeAdd, uint128 nextLiquidity)
     {
         if (liquidityDelta <= 0) {
             return (liq, liq);
         }
 
         uint128 addedLiquidity = uint256(liquidityDelta).toUint128();
         liveLiquidityBeforeAdd = liq > addedLiquidity ? liq - addedLiquidity : 0;
         nextLiquidity = liq;
 
         // Unit harnesses may call touchPosition without pre-mutating PoolManager liquidity first.
         if (nextLiquidity == 0) nextLiquidity = liveLiquidityBeforeAdd + addedLiquidity;
     }
 
     /// @dev Rebase fee-growth checkpoints for fee lanes that still have unresolved residual burn base when adding
     ///      liquidity to an already-active position. This prevents newly added liquidity from inheriting the pre-add
     ///      fee window and double counting against already-banked historical residual backing.
     /// @param liquidityBeforeAdd Live position liquidity before this increase (pre-modify units); used to bank any
     ///        fee growth accrued on the surviving slice since `feeGrowthInsideLast` when settlement could not yet
     ///        materialise a burn (e.g. zero outflow window), so rebasing does not erase that window.
     function _rebaseResidualFeeGrowthOnActiveIncrease(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolId poolId,
         PositionId positionId,
         uint128 liquidityBeforeAdd
     ) internal {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         bool needFeeToken0 = pa.pendingResidualBurnBase.token1 > 0;
         bool needFeeToken1 = pa.pendingResidualBurnBase.token0 > 0;
         if (!needFeeToken0 && !needFeeToken1) return;
 
         Position storage pos = s.positions[positionId];
         (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, poolId, pos.tickLower, pos.tickUpper);
 
         if (needFeeToken0 && liquidityBeforeAdd > 0 && fg0 > pa.feeGrowthInsideLast.token0) {
             pa.pendingResidualFeeBacking
             .token0 += FullMath.mulDiv(
                 fg0 - pa.feeGrowthInsideLast.token0, uint256(liquidityBeforeAdd), FixedPoint128.Q128
             );
         }
         if (needFeeToken1 && liquidityBeforeAdd > 0 && fg1 > pa.feeGrowthInsideLast.token1) {
             pa.pendingResidualFeeBacking
             .token1 += FullMath.mulDiv(
                 fg1 - pa.feeGrowthInsideLast.token1, uint256(liquidityBeforeAdd), FixedPoint128.Q128
             );
         }
 
         if (needFeeToken0) pa.feeGrowthInsideLast.token0 = fg0;
         if (needFeeToken1) pa.feeGrowthInsideLast.token1 = fg1;
     }
 
     function _captureResidualFeeBackingOnFullDeactivation(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId,
         uint128 liq,
         int256 liquidityDelta
     ) internal {
         uint128 removedLiquidity = uint256(-liquidityDelta).toUint128();
         uint128 liveLiquidityBeforeRemove = (uint256(liq) + uint256(removedLiquidity)).toUint128();
         VTSFeeLinkedLib.captureResidualFeeBackingOnDeactivation(s, poolManager, positionId, liveLiquidityBeforeRemove);
     }
 
     /// @dev Compute settled excess over current commitment maxima after a decrease.
     ///      If live liquidity is zero, all settled is excess.
     function _computeSettledExcessAgainstCommitmentMax(PositionAccounting storage pa, uint128 currentLiq)
         internal
         view
         returns (uint256 excess0, uint256 excess1)
     {
         uint256 s0 = pa.settled.token0;
         uint256 s1 = pa.settled.token1;
         if (currentLiq == 0) {
             return (s0, s1);
         }
         TokenPairUint memory commitmentMaxima = pa.commitmentMax;
         excess0 = s0 > commitmentMaxima.token0 ? s0 - commitmentMaxima.token0 : 0;
         excess1 = s1 > commitmentMaxima.token1 ? s1 - commitmentMaxima.token1 : 0;
     }
 
     /// @dev Clamp settled balances downward by precomputed excess values.
     ///      For **non-seizure** MM decreases, callers pass the routed export from `VTSPositionMMOpsLib`:
     ///      `settleableDelta + queuedDelta` (vault-immediate plus shortfall-backed queue). For **seizure** MM decreases,
     ///      callers pass the seizure split export per leg: `min(excessSettled, settleableVaultLeg + burn)` where
     ///      `burn = min(principal, excessSettled)` — not `settleable + full queued principal`, so guarantor-queued
     ///      principal does not over-remove live `pa.settled` (SETTLE-03). Any remainder that could not be routed stays
     ///      in `pa.settled` until serviceable; only the vault-immediate slice is mirrored on `OwnerCurrencyDelta`.
     function _applySettlementClampFromExcess(
         VTSStorage storage s,
         PositionId positionId,
         uint256 excess0,
         uint256 excess1
     ) internal {
         if (excess0 > 0) {
             _sUpdateSettlement(s, positionId, 0, -SafeCast.toInt256(excess0));
         }
         if (excess1 > 0) {
             _sUpdateSettlement(s, positionId, 1, -SafeCast.toInt256(excess1));
         }
     }
 
     /// @dev Apply the shared liquidity mirror transition logic used by touch/reconcile.
     function _applyLiquidityMirrorTransition(
         VTSStorage storage s,
         PositionId positionId,
         PositionAccounting storage pa,
         Position storage posStorage,
         uint256 initialLiquidity,
         uint128 nextLiquidity
     ) internal {
         posStorage.liquidity = nextLiquidity;
         if (initialLiquidity != uint256(nextLiquidity)) {
             // Remainder is defined for a fixed liquidity denominator; reset on liquidity changes.
             pa.feeBurnGrowthRemainder.token0 = 0;
             pa.feeBurnGrowthRemainder.token1 = 0;
         }
         // Full deactivation: reset the entire commitment-deficit snapshot (amounts, age, severity).
         // Issued commitment is zero once liquidity is fully unwound, so there is nothing left to be insolvent for.
         // Clearing token amounts avoids stale `commitmentDeficit` with `commitmentDeficitSince == 0` after a prior
         // partial reset, which would otherwise block age-gated deficit bypass in `CheckpointLibrary.isSeizable`.
         // Non-seizure MM liquidity changes remain blocked while deficit is non-zero (`CommitmentDeficitBlocksLiquidityChange`);
         // this reset is the semantic cleanup once deactivation is actually reached (including non-MM and seizure paths).
         if (initialLiquidity > 0 && nextLiquidity == 0) {
             pa.commitmentDeficit.set(0, 0);
             pa.commitmentDeficit.set(1, 0);
             pa.commitmentDeficitSince.token0 = 0;
             pa.commitmentDeficitSince.token1 = 0;
             pa.commitmentDeficitBps = 0;
         }
         _updateStatus(s, positionId, posStorage, initialLiquidity, nextLiquidity);
     }
 
     // --------------------------------------------------
     // RFS (Required for Settlement) Functions (from VTSSettleLib)
     // --------------------------------------------------
 
     /// @notice View helper for computing RFS state and delta for a position
     /// @param s The central VTS storage
     /// @param positionId The position id
     /// @return rfsOpen Whether the RFS is open
     /// @return delta The settlement delta required/available
     function getRFS(VTSStorage storage s, PositionId positionId)
         public
         view
         returns (bool rfsOpen, BalanceDelta delta)
     {
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         // Get commitments and settled amounts in scoped block
         uint256 c0;
         uint256 c1;
         uint256 s0;
         uint256 s1;
         uint256 req0;
         uint256 req1;
         {
             c0 = pa.commitmentMax.token0;
             c1 = pa.commitmentMax.token1;
             s0 = pa.settled.token0;
             s1 = pa.settled.token1;
         }
 
         // Calculate base requirements
         {
             Position memory pos = s.positions[positionId];
             Pool memory pool = s.pools[pos.poolId];
             MarketVTSConfiguration memory cfg = pool.vtsConfig;
 
             uint256 d0 = pa.cumulativeDeficit.token0;
             uint256 d1 = pa.cumulativeDeficit.token1;
 
             (uint256 base0, uint256 base1) =
                 LiquidityUtils.getBaseSettlementAmounts(c0, c1, cfg.token0.baseVTSRate, cfg.token1.baseVTSRate);
 
             // Cap deficits by commitment and gate by base
             uint256 defReq0 = d0 < c0 ? d0 : c0;
             uint256 defReq1 = d1 < c1 ? d1 : c1;
             req0 = base0 > defReq0 ? base0 : defReq0;
             req1 = base1 > defReq1 ? base1 : defReq1;
         }
 
         // Inflate by commitment-scoped deficit (insolvency gate), clamp by commitment
         {
             uint256 cd0 = pa.commitmentDeficit.token0;
             uint256 cd1 = pa.commitmentDeficit.token1;
             if (cd0 > 0) {
                 uint256 add0 = req0 + cd0;
                 req0 = add0 > c0 ? c0 : add0;
             }
             if (cd1 > 0) {
                 uint256 add1 = req1 + cd1;
                 req1 = add1 > c1 ? c1 : add1;
             }
         }
 
         int128 amount0 = _rfsDeltaRaw(s0, req0);
         int128 amount1 = _rfsDeltaRaw(s1, req1);
 
         // Spec: amount > 0 => settlement required (RfS open); amount < 0 => withdraw allowed
         rfsOpen = (amount0 > 0) || (amount1 > 0);
         delta = toBalanceDelta(amount0, amount1);
     }
 
     /// @notice Raw RFS delta helper: positive => needs settlement, negative => withdrawable
     /// @param settled Current settled amount
     /// @param need Required amount
     /// @return deltaRaw Signed delta in raw units
     function _rfsDeltaRaw(uint256 settled, uint256 need) internal pure returns (int128 deltaRaw) {
         if (need >= settled) {
             uint256 pos = need - settled; // rfs is the needed minus the already settled
             if (pos > INT128_MAX_U) return type(int128).max;
             return pos.toInt128();
         }
         uint256 neg = settled - need; // withdrawable
         if (neg > INT128_MAX_U) return type(int128).min;
         int128 magnitude = neg.toInt128();
         return -magnitude;
     }
 
     // --------------------------------------------------
     // Settlement Functions (from VTSSettleLib)
     // --------------------------------------------------
     // MM settlement (`executeMMSettleFromParams` / `onMMSettle`) lives in `VTSLifecycleLinkedLib`.
 }
```

#### VTSOrchestrator.sol

File: `contracts/evm/src/VTSOrchestrator.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/VTSOrchestrator.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 // This contract is the central state management layer and orchestrator for VTS logic
 // Adopts Bunni-style pattern: state in storage struct, logic delegated to linked libraries.
 pragma solidity ^0.8.26;
 
 import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {PausableVTS} from "./modules/PausableVTS.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {PositionId, Position} from "./types/Position.sol";
 import {Commit} from "./types/Commit.sol";
 import {Pool} from "./types/Pool.sol";
 import {
     MarketVTSConfiguration,
     PositionAccounting,
     SettleResult,
     TouchPositionResult,
     VaultSettlementIntent,
     VTSLifecycleContext,
     VTSCoreHookContext,
     VTSCommitRouterContext
 } from "./types/VTS.sol";
 import {MarketMaker} from "./libraries/MarketMaker.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {VTSStorage} from "./types/VTS.sol";
 import {IVTSOrchestrator} from "./interfaces/IVTSOrchestrator.sol";
 import {VTSPositionLib} from "./libraries/VTSPositionLib.sol";
 import {VTSSwapLib} from "./libraries/VTSSwapLib.sol";
 import {VTSCommitLib} from "./libraries/VTSCommitLib.sol";
 import {VTSLifecycleLinkedLib} from "./libraries/VTSLifecycleLinkedLib.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
 import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
 import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {CheckpointLibrary} from "./libraries/Checkpoint.sol";
 import {RFSCheckpoint} from "./types/Checkpoint.sol";
 import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {MarketHandlerLib} from "./libraries/MarketHandlerLib.sol";
 import {VTSCurrencyDelta} from "./modules/VTSCurrencyDelta.sol";
 import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
 import {VTSFeeLib} from "./libraries/VTSFeeLib.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
 import {PoolAccounting} from "./types/VTS.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {TokenConfiguration} from "./types/VTS.sol";
 import {VTSAdmin} from "./modules/VTSAdmin.sol";
 
 /// @title VTSOrchestrator
 /// @notice Central state management layer and orchestrator for VTS logic
 /// @dev Adopts Bunni-style pattern: state managed in VTSStorage struct, complex logic delegated to linked libraries
 /// @author Fiet Protocol
 contract VTSOrchestrator is
     PausableVTS,
     VTSAdmin,
     VTSCurrencyDelta,
     ImmutableState,
     IVTSOrchestrator,
     ReentrancyGuardTransient
 {
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
     using SafeCast for uint256;
     using PoolIdLibrary for PoolKey;
 
     /// @notice Central storage pointer (passed to libraries)
     VTSStorage internal s;
 
     /// @notice OracleHelper address for price oracle operations
     IOracleHelper public immutable oracleHelper;
 
     /// @notice LiquidityHub contract for liquidity management
     ILiquidityHub internal immutable liquidityHub;
 
     // --------------------------------------------------
     // Mutation testing note
     // --------------------------------------------------
     // Olympix/Gambit will sometimes generate equivalent mutants by flipping data locations
     // (`storage` <-> `memory`) for local variables that are only read.
     //
     // These are often unkillable without adding artificial, compile-time-only scaffolding
     // (or refactoring into less readable code / more repetitive mapping reads), and there
     // is no protocol-safety upside: the behaviour is unchanged.
     //
     // We therefore accept/ignore those survivors in mutation reports for this contract.
 
     /// @notice Constructor
     /// @param _poolManager The Uniswap V4 PoolManager address
     /// @param _oracleHelper The OracleHelper address
     /// @param _liquidityHub The LiquidityHub address
     /// @param _initialOwner The initial owner of the contract
     constructor(address _poolManager, address _oracleHelper, address _liquidityHub, address _initialOwner)
         Ownable(_initialOwner)
         ImmutableState(IPoolManager(_poolManager))
     {
         if (_poolManager == address(0)) {
             revert Errors.InvalidAddress(_poolManager);
         }
         if (_oracleHelper == address(0)) {
             revert Errors.InvalidAddress(_oracleHelper);
         }
         if (_liquidityHub == address(0)) {
             revert Errors.InvalidAddress(_liquidityHub);
         }
         oracleHelper = IOracleHelper(_oracleHelper);
         liquidityHub = ILiquidityHub(_liquidityHub);
     }
 
     /// @notice Modifier to check if position is valid
     modifier onlyPositionValid(PositionId positionId) {
         _assertPositionValid(positionId, true);
         _;
     }
 
     /// @notice Requires PoolManager to be unlocked (within an active batch)
     modifier onlyIfPoolManagerUnlocked() {
         _onlyIfPoolManagerUnlocked();
         _;
     }
 
     function _onlyIfPoolManagerUnlocked() internal view {
         if (!poolManager.isUnlocked()) revert Errors.PoolManagerMustBeUnlocked();
     }
 
     /// @notice Only allow calls from registered market factory contracts via LiquidityHub
     modifier onlyFactory() {
         _onlyFactory();
         _;
     }
 
     function _onlyFactory() internal view {
         if (!liquidityHub.isFactory(msg.sender)) {
             revert Errors.InvalidSender();
         }
     }
 
     /// @notice Only allow calls from core hook contracts via LiquidityHub
     modifier onlyCoreHook(Currency currency0, Currency currency1) {
         _onlyCoreHook(currency0, currency1);
         _;
     }
 
     function _onlyCoreHook(Currency currency0, Currency currency1) internal view {
         IMarketFactory factory = liquidityHub.getFactory(Currency.unwrap(currency0), Currency.unwrap(currency1));
         MarketHandlerLib.assertCoreHook(factory, _msgSender());
     }
 
     function _assertRegisteredFactory(IMarketFactory factory) internal view {
         if (!liquidityHub.isFactory(address(factory))) revert Errors.InvalidSender();
     }
 
     function _isBoundFactoryCaller(IMarketFactory factory, address caller) internal view returns (bool) {
         _assertRegisteredFactory(factory);
         return MarketHandlerLib.isBounds(factory, caller);
     }
 
     function _assertBoundFactoryCaller(IMarketFactory factory) internal view override {
         if (!_isBoundFactoryCaller(factory, _msgSender())) revert Errors.InvalidSender();
     }
 
     function _checkOwner() internal view override(Ownable, VTSAdmin) {
         super._checkOwner();
     }
 
     /// @inheritdoc PausableVTS
     function _vtsStorage()
         internal
         view
         override(PausableVTS, VTSCurrencyDelta, VTSAdmin)
         returns (VTSStorage storage)
     {
         return s;
     }
 
     // --------------------------------------------------
     // Access Control Helpers
     // --------------------------------------------------
 
     function _assertValidTokenConfiguration(TokenConfiguration memory cfg) internal pure {
         if (cfg.maxGracePeriodTime < cfg.gracePeriodTime) {
             revert Errors.InvalidVTSConfiguration(cfg.gracePeriodTime, cfg.maxGracePeriodTime);
         }
     }
 
     function _assertValidMarketVTSConfiguration(MarketVTSConfiguration memory cfg) internal pure override {
         _assertValidTokenConfiguration(cfg.token0);
         _assertValidTokenConfiguration(cfg.token1);
         if (cfg.unbackedCommitmentGraceBypassBps > LiquidityUtils.BPS_DENOMINATOR) {
             revert Errors.InvalidAmount(cfg.unbackedCommitmentGraceBypassBps, LiquidityUtils.BPS_DENOMINATOR);
         }
     }
 
     /// @notice Check if a position is valid
     /// @param id The position id
     /// @param requireActive Whether the position must be active
     /// @return True if the position is valid
     function isPositionValid(PositionId id, bool requireActive) public view returns (bool) {
         Position memory pos = s.positions[id];
         if (pos.owner == address(0)) return false;
         if (requireActive) {
             if (!pos.isActive) return false;
             // Previously we checked if the commitment max was zero, but this exposes a vulnerability where dust maxima calculations via rounding cause incorrect outcomes.
         }
         return true;
     }
 
     /// @dev Internal assertion helper mirroring legacy registry semantics.
     /// @param id The position id
     /// @param requireActive Whether the position must be active
     /// @return isValid True if the position is valid under the requested constraints
     function _assertPositionValid(PositionId id, bool requireActive) internal view returns (bool isValid) {
         isValid = isPositionValid(id, requireActive);
         if (!isValid) {
             revert Errors.InvalidPosition(0, 0, id);
         }
     }
 
     function _assertPositionValid(PositionId id, bool requireActive, PoolId poolId)
         internal
         view
         returns (bool isValid)
     {
         isValid = isPositionValid(id, requireActive);
         if (!isValid) {
             revert Errors.InvalidPosition(0, 0, id);
         }
         Position memory pos = s.positions[id];
         if (PoolId.unwrap(pos.poolId) != PoolId.unwrap(poolId)) {
             revert Errors.InvalidPosition(0, 0, id);
         }
     }
 
     /// @notice Checks if a commit exists and optionally enforces a live VRL-backed signal
     /// @param commitId The commit identifier
     /// @param requireLiveSignal If true, requires non-empty reserves, not expired, and a non-zero owner. If false,
     ///        only requires an initialised commit with a non-zero owner (zero backing / empty reserves allowed).
     /// @return isValid True if the commit satisfies the requested constraints
     function isSignalValid(uint256 commitId, bool requireLiveSignal) public view returns (bool isValid) {
         return VTSLifecycleLinkedLib.isSignalValid(s, commitId, requireLiveSignal);
     }
 
     /// @notice Validates that a commit exists and optionally enforces a live VRL-backed signal
     /// @param commitId The commit identifier
     /// @param requireLiveSignal If true, reverts when reserves are empty or expired. If false, only reverts when the
     ///        commit is missing or has no owner.
     function _assertSignalValid(uint256 commitId, bool requireLiveSignal) internal view {
         if (!isSignalValid(commitId, requireLiveSignal)) {
             revert Errors.InvalidSignal(commitId);
         }
     }
 
     function _lifecycleContext() internal view returns (VTSLifecycleContext memory ctx) {
         ctx = VTSLifecycleContext({
             poolManager: poolManager,
             liquidityHub: liquidityHub,
             oracleHelper: oracleHelper,
             settlementObserver: settlementObserver
         });
     }
 
     function _coreHookContext() internal view returns (VTSCoreHookContext memory ctx) {
         ctx = VTSCoreHookContext({poolManager: poolManager, liquidityHub: liquidityHub, oracleHelper: oracleHelper});
     }
 
     function _commitRouterContext() internal view returns (VTSCommitRouterContext memory ctx) {
         ctx = VTSCommitRouterContext({
             liquidityHub: liquidityHub, signalManager: signalManager, oracleHelper: oracleHelper
         });
     }
 
     // --------------------------------------------------
     // Lens Functions
     // --------------------------------------------------
 
+    // TODO: Expose commit-level deficit position count, e.g.:
+    // function getCommitDeficitPositionCount(uint256 commitId) external view returns (uint256) { return s.commits[commitId].nonzeroCumulativeDeficitCount; }
     /// @notice Get position by PositionId
     /// @param positionId The position identifier
     /// @return The Position struct
     function getPosition(PositionId positionId) public view returns (Position memory) {
         return s.positions[positionId];
     }
 
     /// @notice Get position by commitId and positionIndex
     /// @param commitId The commit identifier
     /// @param positionIndex The position index within the commit
     /// @return The Position struct
     /// @return The PositionId
     function getPosition(uint256 commitId, uint256 positionIndex) public view returns (Position memory, PositionId) {
         PositionId positionId = s.commits[commitId].positions[positionIndex];
         // Assert position validity when accessing via commit/position index (used by MM helpers)
         // we need to be able to access positions that are not active for when we are withdrawing from a position that has been closed
         _assertPositionValid(positionId, false);
         return (s.positions[positionId], positionId);
     }
 
     /// @notice Get position id by commitId and positionIndex
     /// @param commitId The commit identifier
     /// @param positionIndex The position index within the commit
     /// @return The position id
     function getPositionId(uint256 commitId, uint256 positionIndex) public view returns (PositionId) {
         return s.commits[commitId].positions[positionIndex];
     }
 
     /// @notice Get the next commit ID that will be assigned
     /// @return The next commit ID (will be assigned on next commitSignal call)
     /// @dev Returns s.nextCommitId + 1 because nextCommitId starts at 0 and commitSignal uses pre-increment (++s.nextCommitId)
     function nextCommitId() public view returns (uint256) {
         return s.nextCommitId + 1;
     }
 
     /// @notice Get commit by commitId
     /// @dev Note: Cannot return Commit directly due to mapping in struct
     /// @param commitId The commit identifier
     /// @return mmState The MarketMaker state
     /// @return expiresAt The expiration timestamp
     /// @return positionCount The count of positions
     /// @return activePositionCount The count of active positions
     /// @return inactiveRemnantCount Inactive positions with non-zero live settled (blocks decommit)
     function getCommit(uint256 commitId)
         external
         view
         returns (
             MarketMaker.State memory mmState,
             uint256 expiresAt,
             uint256 positionCount,
             uint256 activePositionCount,
             uint256 inactiveRemnantCount
         )
     {
         Commit storage commit = s.commits[commitId];
         return (
             commit.mmState,
             commit.expiresAt,
             commit.positionCount,
             commit.activePositionCount,
             commit.inactiveRemnantCount
         );
     }
 
     /// @inheritdoc IVTSOrchestrator
     function getCommitAuthorisedRelayer(uint256 commitId) external view returns (address) {
         return s.commits[commitId].authorisedRelayer;
     }
 
     /// @notice Get pool by PoolId
     /// @dev Note: Cannot return Pool directly due to mapping in struct
     /// @param poolId The pool identifier
     /// @return id The pool ID
     /// @return currency0 Token0 currency
     /// @return currency1 Token1 currency
     /// @return vtsConfig The VTS configuration
     /// @return _isPaused Whether pool is paused
     function getPool(PoolId poolId)
         external
         view
         returns (
             PoolId id,
             Currency currency0,
             Currency currency1,
             MarketVTSConfiguration memory vtsConfig,
             bool _isPaused
         )
     {
         Pool storage pool = s.pools[poolId];
         return (poolId, pool.currency0, pool.currency1, pool.vtsConfig, pool.isPaused);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function getMarketVTSConfiguration(PoolId corePoolId) public view returns (MarketVTSConfiguration memory) {
         return s.pools[corePoolId].vtsConfig;
     }
 
     /// @inheritdoc IVTSOrchestrator
     function calcRFS(PositionId positionId, bool requireClosedRfS)
         public
         onlyPositionValid(positionId)
         returns (bool, BalanceDelta)
     {
         settlePositionGrowths(positionId);
         (bool rfsOpen, BalanceDelta delta) = VTSPositionLib.getRFS(s, positionId);
         if (requireClosedRfS && rfsOpen) {
             revert Errors.RFSOpenForPosition(positionId);
         }
         return (rfsOpen, delta);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function calcRFS(uint256 commitId, uint256 positionIndex, bool requireClosedRfS)
         public
         returns (PositionId, bool, BalanceDelta)
     {
         PositionId positionId = getPositionId(commitId, positionIndex);
         _assertPositionValid(positionId, true);
         settlePositionGrowths(positionId);
         (bool rfsOpen, BalanceDelta delta) = VTSPositionLib.getRFS(s, positionId);
         if (requireClosedRfS && rfsOpen) {
             revert Errors.RFSOpenForPosition(positionId);
         }
         return (positionId, rfsOpen, delta);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function getPositionSettledAmounts(PositionId positionId) external view returns (uint256 amount0, uint256 amount1) {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         return (pa.settled.token0, pa.settled.token1);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function getCommitmentMaxima(PositionId positionId)
         external
         view
         onlyPositionValid(positionId)
         returns (uint256 commitment0, uint256 commitment1)
     {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         return (pa.commitmentMax.token0, pa.commitmentMax.token1);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function getSlashedPot(PoolId poolId) external view returns (uint256 pot0, uint256 pot1) {
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         return (paPool.slashedPot.token0, paPool.slashedPot.token1);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function getPoolTotalSettled(PoolId poolId) external view returns (uint256 total0, uint256 total1) {
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         return (paPool.totalSettled.token0, paPool.totalSettled.token1);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function getPoolTotalDeficitPrincipal(PoolId poolId)
         external
         view
         returns (uint256 principal0, uint256 principal1)
     {
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         return (paPool.totalDeficitPrincipal.token0, paPool.totalDeficitPrincipal.token1);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function getPositionFeeAccounting(PositionId positionId)
         external
         view
         returns (uint256 feesShared0, uint256 feesShared1, int256 pendingFeeAdj0, int256 pendingFeeAdj1)
     {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         return (pa.feesShared.token0, pa.feesShared.token1, pa.pendingFeeAdj.token0, pa.pendingFeeAdj.token1);
     }
 
     /// @notice Get the checkpoint for a given position
     /// @param positionId The position identifier
     /// @return checkpoint The RFS checkpoint for the position
     function positionToCheckpoint(PositionId positionId) external view returns (RFSCheckpoint memory) {
         return s.positions[positionId].checkpoint;
     }
 
     // --------------------------------------------------
     // Factory Helpers
     // --------------------------------------------------
 
     /// @notice Initialize a market's configuration in the VTS state
     /// @dev Called by MarketFactory contract during market creation
     /// @param corePoolKey The core pool key
     /// @param vtsConfiguration The VTS configuration
     function initPool(PoolKey memory corePoolKey, MarketVTSConfiguration memory vtsConfiguration) external onlyFactory {
         _assertValidMarketVTSConfiguration(vtsConfiguration);
         PoolId poolId = corePoolKey.toId();
         if (Currency.unwrap(s.pools[poolId].currency0) != address(0)) {
             revert Errors.InvariantViolated("VTSOrchestrator: pool already initialized");
         }
         // Initialize the market details in the VTS state
         s.pools[poolId] = Pool({
             currency0: corePoolKey.currency0,
             currency1: corePoolKey.currency1,
             vtsConfig: vtsConfiguration,
             isPaused: false
         });
     }
 
     /// @notice Increment coverage amounts for a pool
     /// @param poolId The pool identifier
     /// @param amount0 Amount to increment for token0
     /// @param amount1 Amount to increment for token1
     function incrementCoverage(PoolId poolId, uint256 amount0, uint256 amount1) external onlyFactory {
         if (amount0 > 0) {
             VTSCommitLib.incrementCoverage(s, poolId, 0, amount0);
         }
         if (amount1 > 0) {
             VTSCommitLib.incrementCoverage(s, poolId, 1, amount1);
         }
     }
 
     // --------------------------------------------------
     // CoreHook VTS Functionality
     // --------------------------------------------------
 
     /// @notice Settle position growths before liquidity modifications
     /// @dev This entrypoint intentionally stays public while unpaused so growth crystallisation is permissionless:
     ///      anyone may refresh fee / deficit / coverage accounting without gaining authority to add liquidity,
     ///      remove liquidity, or swap on behalf of the owner.
     ///      During pause we narrow the caller back to the canonical CoreHook for the pool so remove-liquidity flows
     ///      can still preserve pre-pause attribution, while add-liquidity and swaps remain halted.
     ///      Only processes valid registered positions; inactive positions are checkpointed with zero live liquidity so
     ///      stale growth cannot be inherited on later reactivation.
     /// @param positionId The position identifier
     function settlePositionGrowths(PositionId positionId) public {
         // Only check for a registered valid position - as new positions are not yet registered in VTS when this method is called.
         if (isPositionValid(positionId, false)) {
             PoolId poolId = s.positions[positionId].poolId;
             if (s.isPaused || s.pools[poolId].isPaused) {
                 // Pause keeps the settlement path available only for canonical remove-liquidity bookkeeping.
                 // This is intentional: growth must be settled against the pre-removal position even while all other
                 // mutation surfaces that expand risk (swaps, adds, arbitrary third-party refreshes) stay shut.
                 Pool memory pool = s.pools[poolId];
                 IMarketFactory factory =
                     liquidityHub.getFactory(Currency.unwrap(pool.currency0), Currency.unwrap(pool.currency1));
                 MarketHandlerLib.assertCoreHook(factory, _msgSender());
             } else {
                 _notPoolPaused(poolId);
             }
             VTSPositionLib.settlePositionGrowths(s, poolManager, positionId);
         }
     }
 
     /// @dev Growth must be settled before `checkpointWithCommitment` reads `pa.settled`. When paused, the public
     ///      `settlePositionGrowths` entrypoint is restricted to CoreHook; this orchestrator-only path performs the
     ///      same settlement for `checkpoint(..., true)` only, so commitment checkpoints stay growth-consistent without
     ///      widening who may call the public `settlePositionGrowths` entrypoint during pause (see **PAUSE-01**).
     function _settleGrowthsBeforeCheckpoint(PositionId positionId, bool withCommitment) internal {
         if (!isPositionValid(positionId, false)) {
             return;
         }
         PoolId poolId = s.positions[positionId].poolId;
         bool poolOrGlobalPaused = s.isPaused || s.pools[poolId].isPaused;
         if (poolOrGlobalPaused && withCommitment) {
             VTSPositionLib.settlePositionGrowths(s, poolManager, positionId);
         } else {
             settlePositionGrowths(positionId);
         }
     }
 
     /// @notice Called by CoreHook after add/remove liquidity to update position state and process fees
     /// @dev Consolidates all delta management for both MM and DirectLP positions.
     ///      Pause policy is enforced inside `VTSPositionLib.touchPosition` based on `liquidityDelta` and VTS storage.
     ///      For MM positions: handles fee accounting, LCC issuance/cancellation, position linking, and delta accounting.
     ///      All position processing logic is delegated to VTSPositionLib.touchPosition.
     /// @param owner The owner of the position (e.g., MMPositionManager or other router)
     /// @param poolKey The pool key for the position
     /// @param params The modify liquidity params
     /// @param callerDelta The caller delta from poolManager.modifyLiquidity
     /// @param feesAccrued The fees accrued from poolManager.modifyLiquidity
     /// @param hookData The hook data containing PositionModificationHookData for MM operations
     /// @return pos The position struct
     /// @return id The position identifier
     /// @return feeAdj The fee adjustment delta
     /// @return isMMPosition True if this is an MM position operation with valid signal
     function processPosition(
         address owner,
         PoolKey calldata poolKey,
         ModifyLiquidityParams calldata params,
         BalanceDelta callerDelta,
         BalanceDelta feesAccrued,
         bytes calldata hookData
     )
         external
         onlyCoreHook(poolKey.currency0, poolKey.currency1)
         returns (Position memory pos, PositionId id, BalanceDelta feeAdj, bool isMMPosition)
     {
         isMMPosition = _validateMMOperationLinked(owner, poolKey, hookData);
         (pos, id, feeAdj) = _processPositionLinked(owner, poolKey, params, callerDelta, feesAccrued, hookData);
     }
 
     function _validateMMOperationLinked(address owner, PoolKey calldata poolKey, bytes calldata hookData)
         private
         view
         returns (bool isMMPosition)
     {
         VTSCoreHookContext memory ctx = _coreHookContext();
         isMMPosition = VTSLifecycleLinkedLib.validateMMOperation(s, ctx, owner, poolKey, hookData);
     }
 
     function _processPositionLinked(
         address owner,
         PoolKey calldata poolKey,
         ModifyLiquidityParams calldata params,
         BalanceDelta callerDelta,
         BalanceDelta feesAccrued,
         bytes calldata hookData
     ) private returns (Position memory pos, PositionId id, BalanceDelta feeAdj) {
         VTSCoreHookContext memory ctx = _coreHookContext();
         TouchPositionResult memory result = VTSLifecycleLinkedLib.executeProcessPositionTouch(
             s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData
         );
         pos = result.pos;
         id = result.id;
         feeAdj = result.feeAdj;
     }
 
     /// @notice Called by CoreHook after a swap to process swap-related accounting
     /// @param key The pool key
     /// @param params The swap parameters
     /// @param delta The balance delta from the swap
     /// @param sqrtPBefore The sqrt price before the swap
     /// @param liqBefore The liquidity before the swap
     /// @param tickBefore Authoritative `slot0.tick` before the swap (from CoreHook transient snapshot)
     function afterCoreSwap(
         PoolKey calldata key,
         SwapParams calldata params,
         BalanceDelta delta,
         uint160 sqrtPBefore,
         uint128 liqBefore,
         int24 tickBefore
     ) external onlyCoreHook(key.currency0, key.currency1) notPoolPaused(key.toId()) {
         VTSSwapLib.processSwap(s, poolManager, key, params, delta, sqrtPBefore, liqBefore, tickBefore);
     }
 
     // -----------------------------------------------------------------------------
     // MMPM Functionality: methods used by the MMPositionManager contract
     // -----------------------------------------------------------------------------
 
     /// @notice Commit a liquidity signal to the VTS state
     /// @dev Verifies the signal via SignalManager and stores it in the VTS state. `VTSCommitLib` derives the VRL proof
     ///      principal as `mmState.owner` from `liquiditySignal`.
     /// @param liquiditySignal The liquidity signal to commit
     /// @return commitId The commit identifier for the committed signal
     function commitSignal(IMarketFactory factory, bytes memory liquiditySignal)
         external
         onlyIfPoolManagerUnlocked
         onlyIfVRLHandlersRegistered
         nonReentrant
         returns (uint256 commitId)
     {
         commitId = VTSCommitLib.commitSignal(s, _commitRouterContext(), factory, _msgSender(), liquiditySignal);
     }
 
     /// @notice Commit a liquidity signal using sender-signed EIP-712 relayer authorisation
     /// @dev Relay auth nonces and EIP-712 `RelayAuth` recover to `mmState.owner` (derived inside `VTSCommitLib`).
     /// @param factory Market factory namespace for factory registration and bound-caller checks only. Signature
     ///        verification and replay protection are enforced by `signalManager` (EIP-712 domain bound to
     ///        `verifyingContract`) and per-sender nonces — not by per-factory validation inside the signed payload.
     function commitSignalRelayed(
         IMarketFactory factory,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig,
         address sender
     ) external onlyIfPoolManagerUnlocked onlyIfVRLHandlersRegistered nonReentrant returns (uint256 commitId) {
         commitId = VTSCommitLib.commitSignalRelayed(
             s, _commitRouterContext(), factory, _msgSender(), liquiditySignal, deadline, authNonce, authSig, sender
         );
     }
 
     /// @notice Extend the grace period for a position
     /// @dev Uses the RFSCheckpoint module to extend the grace period after validating the settlement proof
     /// @param poolKey The pool key for the position
     /// @param commitId The commit identifier
     /// @param positionIndex The position index within the commit
     /// @param settlementTokenIndex The index of the settlement token
     /// @param verifierIndex The verifier index
     /// @param settlementProof The settlement proof
     function extendGracePeriod(
         IMarketFactory factory,
         PoolKey memory poolKey,
         uint256 commitId,
         uint256 positionIndex,
         uint8 settlementTokenIndex,
         uint32 verifierIndex,
         bytes memory settlementProof
     ) external onlyIfPoolManagerUnlocked onlyIfVRLHandlersRegistered nonReentrant {
         _assertSignalValid(commitId, true);
         // Validate position exists
         PositionId positionId = getPositionId(commitId, positionIndex);
         _assertPositionValid(positionId, true, poolKey.toId());
 
         IMarketFactory canonicalFactory =
             liquidityHub.getFactory(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
         if (address(factory) != address(canonicalFactory)) revert Errors.InvalidSender();
         _assertBoundFactoryCaller(canonicalFactory);
 
         RFSCheckpoint memory checkpointOut = VTSCommitLib.extendGracePeriod(
             s, _lifecycleContext(), poolKey, positionId, settlementTokenIndex, verifierIndex, settlementProof
         );
         emit GracePeriodExtended(commitId, positionIndex, settlementTokenIndex, checkpointOut);
     }
 
     function _runOnMMSettle(
         IMarketFactory factory,
         PositionId positionId,
         PoolId poolId,
         BalanceDelta amountDelta,
         bool isSeizing,
         bool fromDeltas
     ) internal returns (SettleResult memory result) {
         return VTSLifecycleLinkedLib.onMMSettle(
             s, _lifecycleContext(), factory, positionId, poolId, amountDelta, isSeizing, fromDeltas
         );
     }
 
     function _emitPositionSettled(
         uint256 commitId,
         uint256 positionIndex,
         PositionId positionId,
         BalanceDelta settlementDelta,
         bool isSeizing,
         bool rfsOpen
     ) internal {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         emit PositionSettled(
             commitId,
             positionIndex,
             settlementDelta.amount0(),
             settlementDelta.amount1(),
             pa.settled.token0,
             pa.settled.token1,
             isSeizing,
             rfsOpen
         );
     }
 
     /// @notice Settle a market maker position
     /// @dev Called by MMPositionManager to settle a position, handling both normal settlement and seizure.
     ///      Position validation is performed inside `VTSLifecycleLinkedLib._executeMMSettleFromParams`.
     /// @param factory The market factory namespace for caller-bound validation
     /// @param commitId The commit identifier
     /// @param positionIndex The position index within the commit
     /// @param amountDelta The amount delta for settlement
     /// @param isSeizing Whether the position is being seized
     /// @param fromDeltas When true, deposit lanes consume existing positive underlying delta (settle-from-deltas).
     ///        Withdrawal lanes ignore this flag; see `VTSLifecycleLinkedLib._executeMMSettleFromParams`.
     /// @return settlementDelta The settlement balance delta
     /// @return rfsOpen Whether the RFS is open after settlement
     /// @return seizedLiquidityUnits The amount of liquidity units seized (0 if not seizing)
     /// @return vaultSettlementIntent Explicit vault execution intent for downstream custody handling
     function onMMSettle(
         IMarketFactory factory,
         uint256 commitId,
         uint256 positionIndex,
         BalanceDelta amountDelta,
         bool isSeizing,
         bool fromDeltas
     )
         external
         onlyIfPoolManagerUnlocked
         nonReentrant
         returns (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiquidityUnits, VaultSettlementIntent memory)
     {
         _assertSignalValid(commitId, !isSeizing);
         _assertBoundFactoryCaller(factory);
 
         PositionId positionId = getPositionId(commitId, positionIndex);
         _assertPositionValid(positionId, false);
 
         PoolId poolId;
         {
             Position memory pos = s.positions[positionId];
             if (_msgSender() != pos.owner) revert Errors.InvalidSender();
             poolId = pos.poolId;
         }
 
         if (isSeizing) {
             CheckpointLibrary.isSeizable(s, commitId, positionIndex, true);
         }
 
         SettleResult memory result = _runOnMMSettle(factory, positionId, poolId, amountDelta, isSeizing, fromDeltas);
         _emitPositionSettled(commitId, positionIndex, positionId, result.settlementDelta, isSeizing, result.rfsOpen);
         return (result.settlementDelta, result.rfsOpen, result.seizedLiquidityUnits, result.vaultSettlementIntent);
     }
 
     /// @notice Validate that the grace period has elapsed for a position (required before seizure)
     /// @dev Called by MMPositionManager before seizing a position. Reverts if grace period has not elapsed.
     ///      When a stored commitment deficit exists, recomputes commitment-backed checkpoint state
     ///      (`withCommitment=true`) before seizability to avoid stale bypass eligibility.
     /// @param commitId The commit identifier
     /// @param positionIndex The position index within the commit
     function onSeize(uint256 commitId, uint256 positionIndex) external onlyIfPoolManagerUnlocked nonReentrant {
         // Validate commit exists (but don't require live signal - expired signals can be seized)
         _assertSignalValid(commitId, false);
 
         PositionId positionId = getPositionId(commitId, positionIndex);
         _assertPositionValid(positionId, true);
 
         VTSCommitLib.validateSeize(s, _lifecycleContext(), commitId, positionIndex, positionId);
     }
 
     /// @notice Renew a liquidity signal for an existing commit
     /// @dev Intended for router-style callers (e.g. MMPositionManager). `VTSCommitLib` derives the VRL proof principal
     ///      as `mmState.advancer` from `liquiditySignal`.
     /// @param commitId The commit identifier to renew
     /// @param liquiditySignal The new liquidity signal
     function renewSignal(IMarketFactory factory, uint256 commitId, bytes memory liquiditySignal)
         external
         onlyIfPoolManagerUnlocked
         onlyIfVRLHandlersRegistered
         nonReentrant
     {
         // Validate commit exists (but don't require live signal - expired signals can be seized)
         _assertSignalValid(commitId, false);
         VTSCommitLib.renewSignal(s, _commitRouterContext(), factory, _msgSender(), commitId, liquiditySignal);
     }
 
     /// @notice Renew a liquidity signal using sender-signed EIP-712 relayer authorisation
     /// @dev Relay auth recovers to `mmState.advancer` (derived inside `VTSCommitLib`).
     /// @param factory Market factory namespace for factory registration and bound-caller checks only. EIP-712
     ///        verification remains under `signalManager`; renewals are tied to `commitId` and validated liquidity
     ///        signal ownership within `VTSCommitLib.renewSignalRelayed`.
     /// @param sender EIP-712 `RelayAuth.sender`: `address(0)` or `mmState.advancer` (see `VRLSignalManager`); MMPM binds locker.
     function renewSignalRelayed(
         IMarketFactory factory,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig,
         address sender
     ) external onlyIfPoolManagerUnlocked onlyIfVRLHandlersRegistered nonReentrant {
         _assertSignalValid(commitId, false);
         VTSCommitLib.renewSignalRelayed(
             s,
             _commitRouterContext(),
             factory,
             _msgSender(),
             commitId,
             liquiditySignal,
             deadline,
             authNonce,
             authSig,
             sender
         );
     }
 
     /// @notice Checkpoint a position and optionally run commitment backing checks
     /// @dev Settles growth once, optionally updates commitment deficit state, then computes/marks RFS
     ///      from that same snapshot.
     ///      Ordering matters: this prevents a fresh grace window from starting
     ///      from a later checkpoint when commitment-derived unbacking was already revealed earlier.
     /// @param commitId The commit identifier
     /// @param positionIndex The position index within the commit
     /// @param withCommitment Whether to run commitment backing checks and update position deficits
     function checkpoint(uint256 commitId, uint256 positionIndex, bool withCommitment) external nonReentrant {
         // Validate commit exists (but don't require live signal - expired signals can be seized)
         _assertSignalValid(commitId, false);
 
         PositionId positionId = getPositionId(commitId, positionIndex);
         _assertPositionValid(positionId, true);
 
         ///      When the pool (or VTS globally) is paused, public `settlePositionGrowths` is CoreHook-only so
         ///      arbitrary third parties cannot refresh growth during pause. Commitment checkpoints must still run on
         ///      growth-settled accounting (see COMMIT-02 / COMMIT-02A in `INVARIANTS.md`): for paused
         ///      `withCommitment == true` we settle via this orchestrator path only, then run the linked checkpoint.
         ///      Paused `checkpoint(..., false)` and public `calcRFS` / `settlePositionGrowths` remain CoreHook-only.
         _settleGrowthsBeforeCheckpoint(positionId, withCommitment);
 
         RFSCheckpoint memory checkpointOut = withCommitment
             ? VTSCommitLib.checkpointAfterGrowthWithCommitment(s, _lifecycleContext(), commitId, positionId)
             : VTSLifecycleLinkedLib.checkpointAfterGrowthNoCommitment(s, positionId);
         emit Checkpointed(commitId, positionIndex, checkpointOut, withCommitment);
     }
 }
```

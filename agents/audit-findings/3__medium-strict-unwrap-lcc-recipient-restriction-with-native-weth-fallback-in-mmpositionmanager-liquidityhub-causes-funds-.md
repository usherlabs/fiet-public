[Medium] Strict UNWRAP_LCC recipient restriction with native WETH fallback in MMPositionManager/LiquidityHub causes funds stuck in router contracts

# Description

A PR-introduced recipient restriction for [UNWRAP_LCC in MMPositionManager (locker or MMPM only)](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L388-L396) combined with LiquidityHub’s [native-to-WETH fallback](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/libraries/LiquidityHubLib.sol#L597-L613) can silently deliver unwrapped assets to router contracts instead of end-users. If routers lack forwarding/recovery paths, user funds can become permanently stuck.

This PR changes MMPositionManager so [UNWRAP_LCC payouts may only go to the batch locker (msgSender, typically a router) or to MMPositionManager itself](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L388-L396). Previously, arbitrary recipients (e.g., end-user EOAs) were allowed. The PR also changes LiquidityHub’s [transferUnderlying to fall back to WETH when native ETH pushes fail (e.g., non-payable contract recipients)](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/libraries/LiquidityHubLib.sol#L597-L613). If integrators adapt to the new restriction by setting the recipient to the router instead of using the recommended pattern (recipient = MMPM + a TAKE in the same batch to the end-user), unwraps will transfer underlying to the router. For native-backed LCC, ETH push to a non-payable router will succeed via WETH fallback; for ERC20-backed LCC, the ERC20 underlying is transferred to the router. Since [MMPositionManager credits deltas only when recipient is address(this)](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L415-L422), unwrap-to-router leaves no residual deltas and passes end-of-batch checks, but the assets remain at the router. If the router lacks a forwarding or recovery function, user funds are permanently stuck. This stuck-funds risk is introduced by the PR’s strict recipient policy and WETH fallback behavior.

# Severity

**Impact Explanation:** [High] User principal can be permanently frozen at a router address with no recovery path, meeting the criterion of funds blocked beyond a week with no workaround.

**Likelihood Explanation:** [Low] Exploitation relies on integrator/operator misconfiguration (choosing recipient=router rather than recipient=MMPM + TAKE) and specific router properties (non-payable and/or lacking ERC20 recovery), which are outside normal user control.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Native-backed LCC: A non-payable router updates to pass UNWRAP_LCC’s new recipient restriction by setting recipient=router. LiquidityHub’s native transfer to the router fails and [falls back to WETH, transferring WETH to the router](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/libraries/LiquidityHubLib.sol#L597-L613). [No deltas are credited in MMPositionManager](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L415-L422), the batch succeeds, and WETH remains stuck at the router if it has no recovery path.
#### Preconditions / Assumptions
- (a). Protocol is upgraded to this PR.
- (b). A non-custodial router (locker) integrates MMPositionManager and is non-payable.
- (c). Pre-PR, the router unwrapped directly to end-users. Post-PR, direct end-user recipients revert under _resolveStrictRecipient.
- (d). The router adapts by setting UNWRAP_LCC recipient to the router instead of using recipient=MMPM + TAKE in the same batch.
- (e). The LCC is native-backed (underlying == address(0)).
- (f). The router has no ERC20 WETH forwarding/recovery path.

### Scenario 2.
ERC20-backed LCC: A router updates to set UNWRAP_LCC recipient=router to avoid reverts, but lacks any ERC20 forwarding/recovery for the underlying token. LiquidityHub [transfers the ERC20 underlying to the router](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/libraries/LiquidityHubLib.sol#L617-L619). No deltas remain, the batch succeeds, and the ERC20 is stuck at the router.
#### Preconditions / Assumptions
- (a). Protocol is upgraded to this PR.
- (b). A non-custodial router (locker) integrates MMPositionManager.
- (c). Pre-PR, the router unwrapped directly to end-users. Post-PR, direct end-user recipients revert under _resolveStrictRecipient.
- (d). The router adapts by setting UNWRAP_LCC recipient to the router instead of using recipient=MMPM + TAKE in the same batch.
- (e). The LCC is ERC20-backed (underlying != address(0)).
- (f). The router lacks forwarding/recovery for the specific ERC20 underlying.

# Proposed fix

## MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol)

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
             // Commitment NFT is always minted to the locker; custody separation uses ERC-721 transfer after the batch.
             _commitSignal(liquiditySignal, msgSender(), relayParams);
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
     /// @param liquiditySignal The ABI-encoded LiquiditySignal to verify and record
     /// @param owner The locker (`msgSender()`); commitment NFT is minted to this address
     /// @return tokenId The commitment NFT id created
     function _commitSignal(bytes calldata liquiditySignal, address owner, bytes calldata relayParams)
         internal
         returns (uint256 tokenId)
     {
         if (relayParams.length == 0) {
             tokenId = vtsOrchestrator.commitSignal(marketFactory, msgSender(), liquiditySignal);
         } else {
             (uint256 deadline, uint256 authNonce, bytes memory authSig) =
                 abi.decode(relayParams, (uint256, uint256, bytes));
             tokenId = vtsOrchestrator.commitSignalRelayed(
                 marketFactory, msgSender(), liquiditySignal, deadline, authNonce, authSig
             );
         }
         _mint(owner, tokenId);
         emit SignalCommitted(tokenId);
     }
 
     /// @notice Renews an existing signal with new parameters
     /// @param tokenId The commitment NFT token ID
     /// @param liquiditySignal The new liquidity signal
     function _renewSignal(uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) internal {
         if (relayParams.length == 0) {
             vtsOrchestrator.renewSignal(marketFactory, msgSender(), tokenId, liquiditySignal);
         } else {
             (uint256 deadline, uint256 authNonce, bytes memory authSig) =
                 abi.decode(relayParams, (uint256, uint256, bytes));
             vtsOrchestrator.renewSignalRelayed(
                 marketFactory, msgSender(), tokenId, liquiditySignal, deadline, authNonce, authSig
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
 
-    /// @dev UNWRAP_LCC payout may only go to the locker or MMPM; arbitrary third-party recipients are disallowed.
+    /// @dev UNWRAP_LCC payout may only go to MMPM; locker or arbitrary third-party recipients are disallowed.
     function _resolveStrictRecipient(address recipient) internal view returns (address) {
         address to = _mapRecipient(recipient);
-        if (to != msgSender() && to != address(this)) {
+        if (to != address(this)) {
             revert Errors.NotApproved(to);
         }
         return to;
     }
 
     /// @notice Unwraps LCC tokens to underlying asset using deltas (locker credit)
     function _unwrapLccFromDeltas(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         uint256 beforeBal = isNativeUnderlying ? to.balance : IERC20(underlying).balanceOf(to);
         uint256 toUnwrap = vtsOrchestrator.take(lccCurrency, msgSender(), requested);
 
         if (toUnwrap > 0) {
             address queueTo = msgSender();
             liquidityHub.unwrapTo(lccAddr, to, queueTo, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? to.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
 
         if (to == address(this) && unwrapped > 0) {
             if (isNativeUnderlying) {
                 _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
             } else {
                 _syncBalanceAsCredit(Currency.wrap(underlying));
             }
         }
     }
 
     /// @notice Unwraps LCC tokens to underlying asset by pulling from the locker/user
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
 
         uint256 beforeBal = isNativeUnderlying ? to.balance : IERC20(underlying).balanceOf(to);
         if (toUnwrap > 0) {
             // Pull only from the locker/user (never arbitrary third parties).
             lccCurrency.transferFrom(payer, address(this), toUnwrap);
             liquidityHub.unwrapTo(lccAddr, to, payer, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? to.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
         if (to == address(this) && unwrapped > 0) {
             if (isNativeUnderlying) {
                 _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
             } else {
                 _syncBalanceAsCredit(Currency.wrap(underlying));
             }
         }
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

# Related findings

## [Medium] Silent ETH→WETH fallback in LiquidityHubLib.transferUnderlying for native payouts causes permanent stuck funds

### Description

A PR-introduced [fallback wraps ETH to WETH and transfers it when a native ETH push to the recipient fails](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/libraries/LiquidityHubLib.sol#L603-L614). This finalizes settlements/unwraps by burning LCC and clearing queues while delivering WETH to recipients that may be unable to move ERC20s, leading to permanent stuck funds. Previously, native push failures would revert and preserve the claim.

The [LiquidityHubLib.transferUnderlying function was changed to attempt a native ETH push for underlying == address(0) and, if it fails, to unconditionally wrap the ETH into WETH9 and transfer WETH to the recipient](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/libraries/LiquidityHubLib.sol#L603-L614). This helper underpins both [immediate unwrapping](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/LiquidityHub.sol#L612-L612) and [permissionless settlement of queued claims](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/LiquidityHub.sol#L983-L991). As a result, for native-backed LCC payouts, recipients that are non-payable (reject ETH) and lack ERC20 rescue/move methods can have their LCC burned and queue entries cleared while only receiving WETH that they cannot move. Before this change, failed native pushes would revert, leaving LCC and queues intact (fail-closed), allowing remediation paths. The PR also [tightened issuer-driven native queue recipients to EOAs](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/LiquidityHub.sol#L1111-L1111), but immediate unwraps and generic queued shortfalls remain susceptible. MMPM-specific flows are safe by design, but direct Hub users and generic settlements are affected.

### Severity

**Impact Explanation:** [High] Finalizes payouts by burning LCC and clearing queues while delivering WETH to ERC20-inert recipients, resulting in permanent stuck funds with no workaround.

**Likelihood Explanation:** [Low] Requires specific but plausible conditions (non-payable, ERC20-inert recipients; existing queued claims or immediate unwraps; sufficient reserves). Attacks are griefing (unprofitable) and some cases rely on user/integrator footguns.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Permissionless settlement griefing: attacker calls [processSettlementFor](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/LiquidityHub.sol#L983-L991) on a queued native-backed LCC claim for a non-payable, ERC20-inert contract recipient when reserves are available. Settlement [burns the recipient’s LCC and clears the queue](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/libraries/LiquidityHubLib.sol#L577-L577); native push fails; [fallback wraps to WETH and transfers WETH to the recipient](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/libraries/LiquidityHubLib.sol#L603-L614), which cannot move ERC20s, permanently stranding funds. Before the PR, this would revert and preserve the claim.
#### Preconditions / Assumptions
- (a). LCC is native-backed (underlying == address(0))
- (b). Recipient is a non-payable contract (rejects ETH) and ERC20-inert (no rescue/move for ERC20s)
- (c). Recipient holds sufficient market-derived LCC
- (d). A queued settlement exists for the recipient
- (e). LiquidityHub has sufficient market-derived reserve for settlement
- (f). Attacker can call processSettlementFor (permissionless)

### Scenario 2.
Immediate unwrap footgun: a non-payable, ERC20-inert contract calls [unwrap(lcc, amount)](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/LiquidityHub.sol#L626-L629) for a native-backed LCC. LiquidityHub burns LCC and attempts native transfer; it fails; fallback wraps to WETH and transfers WETH to the contract, which cannot move ERC20s, permanently stranding funds. Before the PR, this would revert, preserving LCC and allowing alternative payout routing.
#### Preconditions / Assumptions
- (a). LCC is native-backed (underlying == address(0))
- (b). Caller/recipient is a non-payable contract (rejects ETH) and ERC20-inert (no rescue/move for ERC20s)
- (c). LiquidityHub has sufficient reserves to pay immediately (no shortfall)

### Scenario 3.
Front-run restructuring: victim with a queued native-backed claim at a non-payable, ERC20-inert contract plans to move LCC or use an endpoint to unwrap to a payable address. An attacker front-runs with [processSettlementFor](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/LiquidityHub.sol#L983-L991) when reserves are available, forcing WETH payout, burning LCC and clearing the queue, leaving WETH stuck at the contract address.
#### Preconditions / Assumptions
- (a). LCC is native-backed (underlying == address(0))
- (b). Recipient is a non-payable contract (rejects ETH) and ERC20-inert (no rescue/move for ERC20s)
- (c). A queued settlement exists for the recipient
- (d). LiquidityHub has sufficient market-derived reserve for settlement
- (e). Victim has not yet restructured the claim
- (f). Attacker can front-run and call processSettlementFor (permissionless)

### Proposed fix

#### LiquidityHubLib.sol

File: `contracts/evm/src/libraries/LiquidityHubLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/libraries/LiquidityHubLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {LiquidityHubStorage, Market, UnderlyingReserve} from "../types/Liquidity.sol";
 import {LCCFactoryLib} from "./LCCFactoryLib.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {Errors} from "./Errors.sol";
 import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
 import {IMMQueueCustodian} from "../interfaces/IMMQueueCustodian.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {CurrencyTransfer} from "./CurrencyTransfer.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 
 interface ILiquidityHubWeth9 {
     function weth9() external view returns (address);
 }
 
 /// @title LiquidityHubLib
 /// @notice Library for heavy LiquidityHub operations
 /// @dev Integrates with LCCFactoryLib to reuse functions without callbacks
 ///      Uses adapter pattern to bridge LiquidityHubStorage to LCCFactoryLib functions
 library LiquidityHubLib {
     using CurrencyTransfer for Currency;
 
     // ============ INTERNAL STRUCTS ============
 
     /// @dev Internal struct to reduce stack depth in wrapWithLogic
     /// @notice Groups intermediate state for the wrap-with operation to avoid stack-too-deep errors
     struct WrapWithContext {
         /// The original amount requested to wrap
         uint256 originalAmount;
         /// Remaining amount from user's wrapped (direct) balance
         uint256 fromWrappedAmount;
         /// Remaining amount from user's market-derived balance
         uint256 fromMarketDerivedAmount;
         /// Accumulated amount to mint as direct supply
         uint256 directToMint;
         /// Accumulated amount to mint as market-derived supply
         uint256 marketToMint;
         /// Amount of target LCC to burn from Hub
         uint256 targetToBurn;
         /// Amount of backing LCC to burn from Hub
         uint256 backingToBurn;
         /// Remaining amount to process after netting
         uint256 remainingAmount;
         /// Amount queued as settlement shortfall during residual unwrap
         uint256 queuedShortfall;
     }
 
     // ============ ADAPTER FUNCTIONS ============
 
     /**
      * @notice Validates that an address is a valid LCC token
      * @dev Adapter function that accesses storage fields directly to validate LCC.
      *      Checks that the LCC has a valid market ID, market ref, and factory address.
      * @param s The liquidity hub storage
      * @param lcc The LCC token address to validate
      * @custom:reverts InvalidLcc if the address is not a valid LCC token
      */
     function assertValidLcc(LiquidityHubStorage storage s, address lcc) internal view {
         if (
             s.lccToMarket[lcc].id == bytes32(0) || s.lccToMarket[lcc].ref.length == 0
                 || s.lccToMarket[lcc].factory == address(0)
         ) {
             revert Errors.InvalidLcc(lcc);
         }
     }
 
     /**
      * @notice Gets the total balance (wrapped + market-derived) of an account for an LCC token
      * @dev Adapter function that delegates to LCCFactoryLib.balanceOf.
      *      No storage access needed as it directly calls the ILCC interface.
      * @param lccToken The LCC token address
      * @param account The account address
      * @return The total balance
      */
     function balanceOf(address lccToken, address account) internal view returns (uint256) {
         return LCCFactoryLib.balanceOf(lccToken, account);
     }
 
     /**
      * @notice Gets the bucketed balances (wrapped and market-derived) of an account for an LCC token
      * @dev Adapter function that delegates to LCCFactoryLib.balancesOf.
      *      No storage access needed as it directly calls the ILCC interface.
      * @param lccToken The LCC token address
      * @param account The account address
      * @return wrapped The wrapped (direct) balance
      * @return marketDerived The market-derived balance
      */
     function balancesOf(address lccToken, address account)
         internal
         view
         returns (uint256 wrapped, uint256 marketDerived)
     {
         return LCCFactoryLib.balancesOf(lccToken, account);
     }
 
     /**
      * @notice Mints LCC tokens to an address
      * @dev Adapter function that delegates to LCCFactoryLib.mint.
      *      No storage access needed as it directly calls the ILCCAdmin interface.
      * @param lccToken The LCC token address
      * @param to The address to mint tokens to
      * @param directAmount The amount to mint as direct supply
      * @param marketAmount The amount to mint as market-derived supply
      */
     function mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.mint(lccToken, to, directAmount, marketAmount);
     }
 
     /**
      * @notice Burns LCC tokens from an address
      * @dev Adapter function that delegates to LCCFactoryLib.burn.
      *      No storage access needed as it directly calls the ILCCAdmin interface.
      * @param lccToken The LCC token address
      * @param from The address to burn tokens from
      * @param directAmount The amount to burn from direct supply
      * @param marketAmount The amount to burn from market-derived supply
      */
     function burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.burn(lccToken, from, directAmount, marketAmount);
     }
 
     // ============ WRAP-WITH HELPER FUNCTIONS (Stack Depth Optimisation) ============
 
     /// @notice Step 0: Net against target LCC Hub queue
     /// @dev Reduces amount to process by netting against existing Hub queue for target LCC.
     ///      If Hub has a queue for the target LCC and holds target LCC tokens, we can net them:
     ///      - Burn target LCC from Hub's queue (satisfies Hub's obligation)
     ///      - Burn backing LCC that would have been used to create target LCC
     ///      - Mint target LCC as market-derived (since it came from backing LCC)
     ///      This avoids unnecessary unwrapping and reduces gas costs.
     /// @param s The liquidity hub storage
     /// @param lcc The target LCC token address
     /// @param ctx The wrap context (modified in place via return)
     /// @return Updated wrap context
     function _netAgainstTargetQueue(LiquidityHubStorage storage s, address lcc, WrapWithContext memory ctx)
         private
         returns (WrapWithContext memory)
     {
         uint256 targetQueue = s.settleQueue[lcc][address(this)];
         if (targetQueue == 0) return ctx;
 
         uint256 hubHeldTarget = balanceOf(lcc, address(this));
         uint256 netTarget = Math.min(ctx.originalAmount, Math.min(targetQueue, hubHeldTarget));
         if (netTarget == 0) return ctx;
 
         // Consume from market-derived first, then wrapped (priority-based consumption)
         {
             uint256 consumeMarket = Math.min(ctx.fromMarketDerivedAmount, netTarget);
             ctx.fromMarketDerivedAmount -= consumeMarket;
             uint256 remaining = netTarget - consumeMarket;
             if (remaining > 0) {
                 uint256 consumeWrapped = Math.min(ctx.fromWrappedAmount, remaining);
                 ctx.fromWrappedAmount -= consumeWrapped;
             }
         }
 
         // Update storage and context.
         // Netting: burn target LCC from queue, burn backing LCC, mint target LCC as market-derived.
         // Keep both per-LCC and per-underlying queue aggregates in sync.
         s.settleQueue[lcc][address(this)] = targetQueue - netTarget;
         s.totalQueued[lcc] -= netTarget;
         s.queueOfUnderlying[s.lccToUnderlying[lcc]] -= netTarget;
         ctx.targetToBurn = netTarget;
         ctx.backingToBurn += netTarget;
         ctx.marketToMint += netTarget;
 
         return ctx;
     }
 
     /// @notice Step 1: Optimise direct conversion by transferring directSupply between LCCs
     /// @dev Transfers directSupply from withLCC to target lcc without unwrapping.
     ///      This is the most gas-efficient path: we simply move directSupply between LCCs
     ///      since they share the same underlying asset. No unwrapping/underlying transfer needed.
     ///      The backing LCC's directSupply becomes the target LCC's directSupply.
     /// @param s The liquidity hub storage
     /// @param lcc The target LCC token address
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context (modified in place via return)
     /// @return Updated wrap context
     function _optimiseDirectConversion(
         LiquidityHubStorage storage s,
         address lcc,
         address withLCC,
         WrapWithContext memory ctx
     ) private returns (WrapWithContext memory) {
         if (ctx.fromWrappedAmount == 0) return ctx;
 
         uint256 directAvail = s.directSupply[withLCC];
         uint256 directConverted = Math.min(ctx.fromWrappedAmount, directAvail);
         if (directConverted > 0) {
             // Transfer directSupply: withLCC -> lcc (no unwrap needed, same underlying)
             s.directSupply[withLCC] = directAvail - directConverted;
             s.directSupply[lcc] += directConverted;
             ctx.backingToBurn += directConverted;
             ctx.directToMint += directConverted;
         }
         return ctx;
     }
 
     /// @notice Step 2: Net market-derived portion against Hub queue using lazy claimed mapping
     /// @dev Uses lazy-claimed mapping (`nettedLCCsAsUnderlying`) to prevent over-netting.
     ///      The lazy-claimed mapping tracks how much of the Hub's queue for withLCC has already
     ///      been netted in previous wrap-with operations. This prevents double-counting when
     ///      multiple wrap-with operations occur before settlement processing.
     ///      Effective queue = total queue - already netted (lazy-claimed)
     /// @param s The liquidity hub storage
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context (modified in place via return)
     /// @return Updated wrap context
     function _netMarketDerived(LiquidityHubStorage storage s, address withLCC, WrapWithContext memory ctx)
         private
         returns (WrapWithContext memory)
     {
         // Calculate remainder after Step 0 (target queue netting) and Step 1 (direct conversion).
         // IMPORTANT: remainingAmount may legitimately be 0 after Step 0; using `> 0` as a sentinel causes
         // double-counting and can lead to over-minting.
         uint256 remainderAmount = ctx.originalAmount;
         remainderAmount = remainderAmount > ctx.targetToBurn ? (remainderAmount - ctx.targetToBurn) : 0;
         remainderAmount = remainderAmount > ctx.directToMint ? (remainderAmount - ctx.directToMint) : 0;
 
         if (remainderAmount == 0) return ctx;
 
         uint256 hubQueueForWith = s.settleQueue[withLCC][address(this)];
         uint256 claimed = s.nettedLCCsAsUnderlying[withLCC];
         // Effective queue = total queue minus what's already been lazy-claimed in previous operations
         uint256 effectiveQueue = hubQueueForWith > claimed ? (hubQueueForWith - claimed) : 0;
         uint256 nettable = Math.min(remainderAmount, Math.min(ctx.fromMarketDerivedAmount, effectiveQueue));
 
         if (nettable > 0) {
             // Lazy claim: mark this portion as netted (will be reconciled during settlement processing)
             s.nettedLCCsAsUnderlying[withLCC] = claimed + nettable;
             ctx.backingToBurn += nettable;
             ctx.marketToMint += nettable;
             ctx.fromMarketDerivedAmount -= nettable;
         }
 
         // Store remainder for Step 3 (unwrapping residual)
         ctx.remainingAmount = remainderAmount;
         return ctx;
     }
 
     /// @notice Step 3: Unwrap residual using withLCC balances
     /// @dev Unwraps remaining amount using directSupply then market liquidity.
     ///      After Steps 0-2 have netted what they can, any remaining amount must be unwrapped
     ///      from the backing LCC. This consumes directSupply first (most efficient), then pulls
     ///      from market liquidity. Any shortfall is queued for settlement.
     /// @param s The liquidity hub storage
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context (modified in place via return)
     /// @return Updated wrap context
     function _unwrapResidual(LiquidityHubStorage storage s, address withLCC, WrapWithContext memory ctx)
         private
         returns (WrapWithContext memory)
     {
         // Calculate remaining after netting (marketToMint includes Step 0 + Step 2, minus Step 0's targetToBurn)
         uint256 marketFromNetting = ctx.marketToMint - ctx.targetToBurn;
         uint256 remainingAfterNet =
             ctx.remainingAmount > marketFromNetting ? ctx.remainingAmount - marketFromNetting : 0;
 
         if (remainingAfterNet == 0) return ctx;
 
         // Calculate residual wrapped for unwrap (wrapped minus what was used for direct conversion in Step 1)
         uint256 residualWrappedForUnwrap = ctx.fromWrappedAmount;
         if (ctx.directToMint > 0) {
             residualWrappedForUnwrap =
                 residualWrappedForUnwrap > ctx.directToMint ? (residualWrappedForUnwrap - ctx.directToMint) : 0;
         }
 
         // Unwrap: consumes directSupply first, then market liquidity, queues shortfall if any
         (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) = unwrapInternalLogic(
             s, withLCC, address(this), remainingAfterNet, residualWrappedForUnwrap, ctx.fromMarketDerivedAmount
         );
 
         // Track burns and mints
         ctx.backingToBurn += directUnwrapped + marketUnwrapped;
         ctx.directToMint += directUnwrapped;
         // Market-derived mint = the portion of the requested conversion that is NOT backed by directSupply.
         //
         // IMPORTANT DESIGN NOTE:
         // - We mint the target LCC 1:1 against the input `withLCC` amount (see `wrapWithPrepare` + caller transfer),
         //   even if the backing cannot be fully redeemed (unwrapped) in this transaction.
         // - `unwrapInternalLogic(...)` may redeem less market liquidity than requested; any shortfall is queued to the
         //   Hub (`queueSettlement(..., address(this), ...)`) for later reconciliation when liquidity becomes available.
         // - Therefore, `ctx.marketToMint` intentionally includes the queued/unredeemed remainder (i.e. it is "market-derived
         //   exposure", not "market liquidity actually redeemed now"). By contrast, `ctx.backingToBurn` only burns what was
         //   actually redeemed now (direct + market), and the queued portion is burned lazily during settlement processing.
         ctx.marketToMint += (remainingAfterNet - directUnwrapped);
         ctx.queuedShortfall += queuedShortfall;
 
         return ctx;
     }
 
     /// @notice Finalise burns and invariant checks for wrap-with operation
     /// @dev Clamps burns to current balances and ensures lazy-claimed never exceeds queue.
     ///      This is a safety check: if queue was processed between netting and finalisation,
     ///      we ensure lazy-claimed doesn't exceed the new (smaller) queue size.
     /// @param s The liquidity hub storage
     /// @param lcc The target LCC token address
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context
     function _finaliseBurns(LiquidityHubStorage storage s, address lcc, address withLCC, WrapWithContext memory ctx)
         private
     {
         // Clamp burns to current Hub-held balances (defensive check)
         uint256 targetToBurn = Math.min(ctx.targetToBurn, balanceOf(lcc, address(this)));
         uint256 backingToBurn = Math.min(ctx.backingToBurn, balanceOf(withLCC, address(this)));
 
         // Execute burns (protocol-bound burns, skip bucket maps)
         if (targetToBurn > 0) {
             burn(lcc, address(this), 0, targetToBurn);
         }
         if (backingToBurn > 0) {
             burn(withLCC, address(this), 0, backingToBurn);
         }
 
         // Ensure lazy-claimed never exceeds current queue (invariant check)
         // This can happen if queue was processed between netting and finalisation
         // @note: Based on the logical call flow, this should never happen.
         uint256 currentQueueWith = s.settleQueue[withLCC][address(this)];
         if (s.nettedLCCsAsUnderlying[withLCC] > currentQueueWith) {
             s.nettedLCCsAsUnderlying[withLCC] = currentQueueWith;
         }
     }
 
     // ============ MAIN WRAP-WITH FUNCTION ============
 
     /// @notice Wrap LCC using another LCC as backing, with O(1) flattening and netting
     /// @dev Multi-step strategy to efficiently convert one LCC to another sharing the same underlying:
     ///      Step 0: Net against target LCC Hub queue (if Hub has queue for target, net backing LCC against it)
     ///      Step 1: Optimise direct conversion (transfer directSupply from withLCC to target, no unwrap needed)
     ///      Step 2: Net market-derived against Hub queue for withLCC (using lazy-claimed mapping to prevent over-netting)
     ///      Step 3: Unwrap residual (consume directSupply then market liquidity, queue shortfall if any)
     ///      Final: Mint target LCC reflecting direct vs market-derived components
     ///
     ///      Priority-based balance consumption: market-derived balance is consumed first, then wrapped (direct).
     ///      This optimises gas by preferring market-derived (no directSupply manipulation) over wrapped.
     ///
     ///      Refactored into helper functions to avoid stack-too-deep in legacy pipeline (via_ir = false).
     /// @param s The liquidity hub state
     /// @param lcc The target LCC token address
     /// @param withLCC The backing LCC token address
     /// @param from The address providing the backing LCC
     /// @param amount The amount to wrap
     //#olympix-ignore-reentrancy
     function wrapWithPrepare(LiquidityHubStorage storage s, address lcc, address withLCC, address from, uint256 amount)
         internal
         view
         returns (WrapWithContext memory)
     {
         if (amount == 0) revert Errors.InvalidAmount(0, 0);
 
         // Validation: ensure withLCC is valid, not same as target, and shares underlying
         assertValidLcc(s, withLCC);
         if (lcc == withLCC) revert Errors.InvalidAddress(withLCC);
         if (s.lccToUnderlying[lcc] != s.lccToUnderlying[withLCC]) {
             revert Errors.UnderlyingAssetMismatch(s.lccToUnderlying[lcc], s.lccToUnderlying[withLCC]);
         }
 
         // Initialise context with balance checks in scoped block
         WrapWithContext memory ctx;
         ctx.originalAmount = amount;
         {
             (uint256 wrapped, uint256 marketDerived) = balancesOf(withLCC, from);
             uint256 total = wrapped + marketDerived;
             if (amount > total) revert Errors.InvalidAmount(amount, total);
             // Priority-based: use market-derived balance first, then direct (wrapped) as remainder
             // This optimises gas by preferring market-derived (no directSupply manipulation)
             ctx.fromMarketDerivedAmount = Math.min(amount, marketDerived);
             ctx.fromWrappedAmount = Math.min(wrapped, amount - ctx.fromMarketDerivedAmount); // similar pattern as LCC onTransfer bucket accounting
         }
 
         // Expects caller to securely transfer funds from (the caller) to (this) Hub
         return ctx;
     }
 
     /// @notice Wrap LCC using another LCC as backing, with O(1) flattening and netting
     /// @dev Executes the wrap-with operation using the provided context
     /// @param s The liquidity hub state
     /// @param lcc The target LCC token address
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context
     //#olympix-ignore-reentrancy
     function wrapWithContext(LiquidityHubStorage storage s, address lcc, address withLCC, WrapWithContext memory ctx)
         internal
         returns (WrapWithContext memory)
     {
         // Execute steps via helper functions (each keeps stack depth minimal)
         ctx = _netAgainstTargetQueue(s, lcc, ctx); // Step 0: Net against target queue
         ctx = _optimiseDirectConversion(s, lcc, withLCC, ctx); // Step 1: Direct conversion
         ctx = _netMarketDerived(s, withLCC, ctx); // Step 2: Net market-derived
         ctx = _unwrapResidual(s, withLCC, ctx); // Step 3: Unwrap residual
 
         // Finalise burns and invariant checks
         _finaliseBurns(s, lcc, withLCC, ctx);
         return ctx;
     }
 
     // ============ CORE LOGIC FUNCTIONS ============
 
     /**
      * @notice Core unwrap logic without external transfer
      * @dev Handles the unwrapping of LCC tokens by consuming direct supply first, then market liquidity.
      *      Any shortfall is queued for settlement. This function does not transfer underlying assets;
      *      that is handled by the calling contract.
      * @param s The liquidity hub storage
      * @param lcc The LCC token address
      * @param queueTo The recipient of the underlying asset (used for queueing shortfall)
      * @param amount The amount to unwrap
      * @param wrappedBalance The wrapped balance of the account
      * @param marketDerivedBalance The market-derived balance of the account
      * @return directUnwrapped The amount unwrapped from direct supply
      * @return marketUnwrapped The amount unwrapped from market liquidity
      * @return queuedShortfall The amount queued due to insufficient immediate liquidity
      */
     //#olympix-ignore-reentrancy
     function unwrapInternalLogic(
         LiquidityHubStorage storage s,
         address lcc,
         address queueTo,
         uint256 amount,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance
     ) internal returns (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) {
         // 1) Consume directSupply[lcc] if available
         if (wrappedBalance > 0) {
             uint256 directAvail = s.directSupply[lcc];
             directUnwrapped = Math.min(Math.min(amount, wrappedBalance), directAvail);
             if (directUnwrapped > 0) {
                 // Underlying already accounted in reserveOfUnderlying (shared pool), no transfer needed
                 s.directSupply[lcc] = directAvail - directUnwrapped;
             }
         }
 
         // 2) Pull from market liquidity; increases reserves later via confirmTake callbacks
         uint256 remainingToUnwrap = amount - directUnwrapped;
         if (remainingToUnwrap > 0 && marketDerivedBalance > 0) {
             // Get the max amount that can be unwrapped from this market
             uint256 requestFromMarket = Math.min(remainingToUnwrap, marketDerivedBalance);
 
             // Unwrap from this market's liquidity - call IMarketFactory directly
             marketUnwrapped = useMarketLiquidity(s, lcc, requestFromMarket);
 
             remainingToUnwrap -= marketUnwrapped;
         }
 
         // 3) Queue any shortfall for later processing
         if (remainingToUnwrap > 0) {
             queueSettlement(s, lcc, queueTo, remainingToUnwrap);
             queuedShortfall = remainingToUnwrap;
         }
     }
 
     /**
      * @notice Uses market liquidity to unwrap LCC tokens
      * @dev Calls the MarketFactory to use market liquidity for unwrapping.
      *      This pulls liquidity from the market pool and increases reserves via confirmTake callbacks.
      * @param s The liquidity hub storage
      * @param lcc The LCC token address
      * @param amount The amount of market liquidity to use
      * @return The actual amount of market liquidity used (may be less than requested)
      */
     function useMarketLiquidity(LiquidityHubStorage storage s, address lcc, uint256 amount) internal returns (uint256) {
         Market memory market = s.lccToMarket[lcc];
         return IMarketFactory(market.factory).useMarketLiquidity(lcc, market.id, amount);
     }
 
     /**
      * @notice Queues a settlement request for later processing
      * @dev Pure queue accounting helper: this function intentionally only mutates queue state.
      *      It does not assert immediate recipient serviceability, because queue ownership can be
      *      decoupled from current LCC custody in protocol flows (for example MM custody release).
      *      Runtime settleability is enforced by processSettlementLogic at redemption time.
      *      Updates both per-LCC queue totals and shared-underlying queue totals.
      *      Note: events are emitted by the calling contract, not this library.
      * @param s The liquidity hub storage
      * @param lcc The LCC token address
      * @param recipient The recipient address for the settlement
      * @param amount The amount to queue for settlement
      */
     function queueSettlement(LiquidityHubStorage storage s, address lcc, address recipient, uint256 amount) internal {
         s.settleQueue[lcc][recipient] += amount;
         s.totalQueued[lcc] += amount;
         s.queueOfUnderlying[s.lccToUnderlying[lcc]] += amount;
         // Event will be emitted by the calling contract
     }
 
     /// @notice Process settlement for a specific recipient using reserveOfUnderlying
     /// @dev Permissionless function that allows anyone to process settlements when liquidity is available.
     ///      Unified interface: branches behaviour based on whether recipient is address(this) (Hub) or external address.
     ///
     ///      Hub path (recipient == address(this)):
     ///      - Used when LCCs back LCCs (via wrapWithLogic)
     ///      - Burns Hub-held LCC without transferring underlying or decrementing reserves
     ///      - Reconciles lazy-claimed netting from wrapWithLogic operations
     ///      - Underlying stays in shared pool (no transfer needed)
     ///
     ///      External path (standard users):
     ///      - Checks market-derived holder balance
     ///      - Burns user's LCC tokens (market-derived supply)
     ///      - Transfers underlying assets to recipient
     ///      - Decrements reserveOfUnderlying
     ///
     ///      Important: this is the canonical runtime enforcement point for settleability.
     ///      Queue creation may be valid even when claims are not executable yet. In those cases
     ///      this function can revert (or no-op for Hub path) until reserves/custody reconcile.
     ///
     /// @param s The liquidity hub storage
     /// @param lcc The LCC token address
     /// @param recipient The recipient address to settle for (address(this) for Hub's own queue)
     /// @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
     function processSettlementLogic(LiquidityHubStorage storage s, address lcc, address recipient, uint256 maxAmount)
         internal
     {
         bool isForHub = recipient == address(this);
         uint256 queued = s.settleQueue[lcc][recipient];
         if (queued == 0) revert Errors.InvalidAmount(0, 0);
 
         address underlying = s.lccToUnderlying[lcc];
         uint256 available = s.reserveOfUnderlying[underlying].marketDerived;
 
         uint256 holderBal = 0;
         if (isForHub) {
             // Hub-specific path: burn Hub-held LCC against available reserves
             // Does NOT transfer underlying or decrement reserveOfUnderlying (underlying stays in shared pool)
             // Note: This path should only really occur when LCCs back LCCs (via wrapWithLogic)
             holderBal = balanceOf(lcc, recipient);
         } else {
             // Standard path for external recipients
             // Only check market-derived balance (wrapped balance doesn't need settlement)
             (, holderBal) = balancesOf(lcc, recipient);
         }
 
         // Calculate settlement amount: min of queued, available reserves, maxAmount, and holder balance
         uint256 toSettle = Math.min(Math.min(queued, available), Math.min(maxAmount, holderBal));
         if (toSettle == 0) {
             if (!isForHub) {
                 revert Errors.LiquidityError(lcc, toSettle);
             }
             return;
         }
 
         // Update queue state at both LCC and shared-underlying scopes.
         s.settleQueue[lcc][recipient] -= toSettle;
         s.totalQueued[lcc] -= toSettle;
         s.queueOfUnderlying[underlying] -= toSettle;
 
         if (isForHub) {
             // Reconcile lazy netting from wrapWith Step 2.
             //
             // `nettedLCCsAsUnderlying[lcc]` tracks how much of the Hub's own queued settlement for `lcc` was
             // already "netted" earlier during wrapWith (market-derived netting) WITHOUT reducing `settleQueue`
             // at that time. In other words: the queue still exists on-chain, but some of it has already been
             // economically satisfied via netting. (ie. transferred to a recipient, so we don't need to burn Hub-held LCC for that same portion)
             //
             // When we later process the Hub's queue, we still decrement `settleQueue`/`totalQueued` by `toSettle`,
             // but we must avoid double-accounting by NOT burning Hub-held LCC for the already-netted portion.
             // So we consume `claimed` first, and only burn the remaining `effectiveToBurn`.
             //
             // (The external-recipient path below uses `pay(...)`, which burns the user's LCC and transfers
             // underlying, decrementing reserves.)
             uint256 claimed = s.nettedLCCsAsUnderlying[lcc];
             uint256 decrement = Math.min(claimed, toSettle);
             if (decrement > 0) {
                 s.nettedLCCsAsUnderlying[lcc] = claimed - decrement;
             }
             // Burn the remaining amount after wrapWithLogic lazy netting has been accounted for
             uint256 effectiveToBurn = toSettle - decrement;
 
             if (effectiveToBurn > 0) {
                 // Burn Hub-held LCC; protocol-bound burn, skip bucket maps
                 burn(lcc, recipient, 0, effectiveToBurn);
             }
         } else {
             // Standard path: burn user's LCC and transfer underlying
             pay(s, lcc, recipient, recipient, 0, toSettle);
         }
     }
 
     /// @notice Transfers underlying assets to an account
     /// @param s The liquidity hub storage
     /// @param underlying The underlying asset address
     /// @param account The account to transfer the underlying assets to
     /// @param directAmount The direct reserve amount to transfer
     /// @param marketDerivedAmount The market-derived reserve amount to transfer
     function transferUnderlying(
         LiquidityHubStorage storage s,
         address underlying,
         address account,
         uint256 directAmount,
         uint256 marketDerivedAmount
     ) internal {
         uint256 amount = directAmount + marketDerivedAmount;
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[underlying];
         if (amount == 0 || directAmount > reserve.direct || marketDerivedAmount > reserve.marketDerived) {
             uint256 totalReserve = reserve.direct + reserve.marketDerived;
             revert Errors.InvalidAmount(amount, totalReserve);
         }
         reserve.direct -= directAmount;
         reserve.marketDerived -= marketDerivedAmount;
 
         if (underlying == address(0)) {
             // Attempt native push first for backwards-compatible payout behaviour.
             (bool nativeOk,) = account.call{value: amount}("");
             if (nativeOk) return;
+            // Disallow fallback to WETH for contract recipients to avoid forced finalisation to ERC20-inert addresses.
+            // Contracts that cannot accept ETH must not be silently paid in WETH; preserve fail-closed semantics.
+            if (account.code.length != 0) {
+                revert Errors.NotApproved(account);
+            }
 
             address wrappedNative = ILiquidityHubWeth9(address(this)).weth9();
             if (wrappedNative == address(0)) {
                 revert Errors.InvalidAddress(wrappedNative);
             }
 
             IWETH9(wrappedNative).deposit{value: amount}();
             Currency.wrap(wrappedNative).transfer(account, amount);
             return;
         }
 
         Currency.wrap(underlying).transfer(account, amount);
     }
 
     /// @notice Pays an outstanding settlement to an account by burning LCC tokens and transferring underlying assets
     /// @param s The liquidity hub storage
     /// @param lcc The LCC token address
     /// @param owner The owner of the LCC tokens to burn
     /// @param to The recipient of the underlying assets
     /// @param fromDirect The amount of LCC to burn from direct supply
     /// @param fromMarket The amount of LCC to burn from market-derived supply
     function pay(
         LiquidityHubStorage storage s,
         address lcc,
         address owner,
         address to,
         uint256 fromDirect,
         uint256 fromMarket
     ) internal {
         burn(lcc, owner, fromDirect, fromMarket);
         transferUnderlying(s, s.lccToUnderlying[lcc], to, fromDirect, fromMarket);
     }
 
     // ============ ISSUER / CUSTODIAN HELPERS (called via LiquidityHubLinkedLib) ============
 
     /// @dev Snapshot for `confirmTake`: reserve bump and whether `LiquidityAvailable` should emit (before Hub settlement).
     struct ConfirmTakeContext {
         uint256 hubQueueBeforeSettlement;
         address underlying;
         bytes32 marketId;
         bool emitLiquidityAvailable;
     }
 
     function confirmTakePrepare(LiquidityHubStorage storage s, address lcc, uint256 amount, bool shouldEmit)
         internal
         returns (ConfirmTakeContext memory ctx)
     {
         ctx.underlying = s.lccToUnderlying[lcc];
         s.reserveOfUnderlying[ctx.underlying].marketDerived += amount;
         ctx.hubQueueBeforeSettlement = s.settleQueue[lcc][address(this)];
         ctx.marketId = s.lccToMarket[lcc].id;
         ctx.emitLiquidityAvailable = shouldEmit && ctx.hubQueueBeforeSettlement < amount;
     }
 
     function confirmTakeBalanceInvariant(LiquidityHubStorage storage s, address underlying) internal view {
         UnderlyingReserve storage reserveTuple = s.reserveOfUnderlying[underlying];
         uint256 reserve = reserveTuple.direct + reserveTuple.marketDerived;
         uint256 actualBalance =
             underlying == address(0) ? address(this).balance : Currency.wrap(underlying).balanceOf(address(this));
         if (reserve > actualBalance) revert Errors.InsufficientBalance(actualBalance, reserve);
     }
 
     function prepareSettle(LiquidityHubStorage storage s, address lcc, uint256 amount, address issuer) internal {
         if (amount == 0) revert Errors.InvalidAmount(0, 0);
 
         address underlying = s.lccToUnderlying[lcc];
         uint256 reserveDirect = s.reserveOfUnderlying[underlying].direct;
         uint256 directAvail = s.directSupply[lcc];
         uint256 maxSettleableDirect = Math.min(reserveDirect, directAvail);
         if (maxSettleableDirect < amount) {
             revert Errors.InvalidAmount(amount, maxSettleableDirect);
         }
 
         s.reserveOfUnderlying[underlying].direct = reserveDirect - amount;
         s.directSupply[lcc] = directAvail - amount;
 
         Currency underlyingCurrency = Currency.wrap(underlying);
         if (underlyingCurrency.isAddressZero()) {
             underlyingCurrency.transfer(issuer, amount);
         } else {
             underlyingCurrency.approve(issuer, amount);
         }
     }
 
     function settleFromCustodian(
         LiquidityHubStorage storage s,
         address lcc,
         address custodian,
         uint256 tokenId,
         address recipient,
         uint256 maxAmount
     ) internal returns (uint256 settled) {
         if (recipient == address(0) || custodian == address(0) || maxAmount == 0) {
             return 0;
         }
         if (custodian.code.length == 0) {
             return 0;
         }
 
         IMMQueueCustodian queueCustodian = IMMQueueCustodian(custodian);
         uint256 queued = s.settleQueue[lcc][recipient];
         if (queued == 0) return 0;
 
         address underlying = s.lccToUnderlying[lcc];
         uint256 available = s.reserveOfUnderlying[underlying].marketDerived;
         uint256 custodied;
         try queueCustodian.queued(tokenId, lcc, recipient) returns (uint256 q) {
             custodied = q;
         } catch {
             return 0;
         }
 
         settled = Math.min(Math.min(queued, available), Math.min(maxAmount, custodied));
         if (settled == 0) return 0;
 
         try queueCustodian.release(tokenId, lcc, recipient, settled) returns (uint256 released) {
             settled = released;
         } catch {
             return 0;
         }
         if (settled == 0) return 0;
     }
 
     function annulSettlementBeforeTransfer(
         LiquidityHubStorage storage s,
         address lcc,
         address from,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance,
         uint256 amountToTransfer
     ) internal returns (uint256 toAnnul) {
         uint256 queued = s.settleQueue[lcc][from];
         uint256 liquidBalance = wrappedBalance + marketDerivedBalance;
         uint256 transferableWithoutQueue = liquidBalance > queued ? (liquidBalance - queued) : 0;
         if (amountToTransfer > transferableWithoutQueue) {
             uint256 bleedIntoQueue = amountToTransfer - transferableWithoutQueue;
             toAnnul = Math.min(bleedIntoQueue, queued);
             if (toAnnul > 0) {
                 s.settleQueue[lcc][from] -= toAnnul;
                 s.totalQueued[lcc] -= toAnnul;
                 s.queueOfUnderlying[s.lccToUnderlying[lcc]] -= toAnnul;
             }
         }
     }
 }
```

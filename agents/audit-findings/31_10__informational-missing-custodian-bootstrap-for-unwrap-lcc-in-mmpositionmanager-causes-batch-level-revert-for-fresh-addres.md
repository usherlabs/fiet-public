[Informational] Missing custodian bootstrap for UNWRAP_LCC in MMPositionManager causes batch-level revert for fresh addresses

# Description

[UNWRAP_LCC](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/MMPositionManager.sol#L404-L418) in MMPositionManager now requires a pre-deployed per-recipient MMQueueCustodian, but custodians are [only created in commit flows](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/MMPositionManager.sol#L144-L152). Fresh addresses without a prior commit cannot use UNWRAP_LCC (both wallet- and delta-funded), causing a revert. Alternatives exist (direct [LiquidityHub.unwrap](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/LiquidityHub.sol#L634) or one-time custodian bootstrap), so impact is UX/regression.

The PR removed LiquidityHub.unwrapTo endpoint flows and refactored MMPositionManager.UNWRAP_LCC to always route through [_unwrapToQueueForward](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/MMPositionManager.sol#L447-L468), which unwraps via a per-recipient MMQueueCustodian that acts as the Hub queue owner. _unwrapToQueueForward calls [MMHelpers.assertQueueCustodianForRecipient(beneficiary)](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/libraries/MMHelpers.sol#L48-L52) and requires custodianFor[beneficiary] to be non-zero. Custodians are only deployed by _commitSignal; UNWRAP_LCC has no lazy/bootstrap path. Therefore, for any address that has never committed a signal, both wallet-funded (payerIsUser=true) and delta-funded (payerIsUser=false) UNWRAP_LCC revert with [QueueCustodianNotDeployed](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/libraries/Errors.sol#L223) (or InvalidAddress on missing custodian). This is a behavior change introduced by the PR. It does not risk funds or break invariants: users can call LiquidityHub.unwrap directly for wallet-held LCC, and integrators can bootstrap a custodian once (via commit) or use simple operational workarounds. The issue is a UX/backward-compatibility regression for MMPM utility batching.

# Severity

**Impact Explanation:** [Low] This is a UX/backward-compatibility regression that causes batch-level reverts for fresh addresses in MMPM utility flows. Unwrap functionality remains available directly via LiquidityHub, and a one-time custodian bootstrap resolves it. No funds are at risk and no invariants are broken.

**Likelihood Explanation:** [Low] It affects fresh addresses that specifically use MMPM UNWRAP_LCC before any commit; for wallet-funded unwraps, a trivial direct alternative exists; for delta-funded unwraps, such fresh states are uncommon. Integrators can permanently mitigate by pre-bootstrapping custodians.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1: A fresh address A (no prior commit, no custodian) calls MMPositionManager UNWRAP_LCC with payerIsUser=true to convert wallet-held LCC to underlying credit within a single batch; _unwrapToQueueForward asserts a custodian for A and reverts, causing the batch to fail.
#### Preconditions / Assumptions
- (a). Address A has never called COMMIT_SIGNAL on MMPositionManager (custodianFor[A] == 0).
- (b). A holds LCC in their wallet.
- (c). A attempts UNWRAP_LCC via MMPositionManager with payerIsUser=true, targeting immediate underlying credit to address(this) or A.

### Scenario 2.
Scenario 2: A fresh address A (no prior commit) with LCC deltas calls MMPositionManager UNWRAP_LCC with payerIsUser=false to convert deltas to underlying credit in-batch; _unwrapToQueueForward asserts a custodian for A and reverts, causing the batch to fail.
#### Preconditions / Assumptions
- (a). Address A has never called COMMIT_SIGNAL (custodianFor[A] == 0).
- (b). A has LCC delta credit at MMPM.
- (c). A attempts UNWRAP_LCC via MMPositionManager with payerIsUser=false, targeting underlying credit on MMPM.

### Scenario 3.
Scenario 3: An integrator uses a utility-only address B (never committed) in an MMPM multicall that relies on UNWRAP_LCC as an early step; the call reverts due to missing custodian, and the entire batch fails.
#### Preconditions / Assumptions
- (a). Integrator’s address B has never called COMMIT_SIGNAL (custodianFor[B] == 0).
- (b). B’s MMPM batch relies on UNWRAP_LCC as a step before subsequent actions that depend on underlying credit inside the same batch.

# Proposed fix

## MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/MMPositionManager.sol)

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
 import {IMMQueueCustodianFactory} from "./interfaces/IMMQueueCustodianFactory.sol";
 import {MMQueueCustodian} from "./MMQueueCustodian.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
 
 /// @title MMPositionManager
 /// @notice Entry point for VRL commitment position management
 /// @dev Handles commitment lifecycle (ERC721) and utility operations locally
 /// @dev Delegates position operations to `MMPositionActionsImpl` via delegatecall (`_delegateToImpl`).
 /// @dev Seizure economics coupling (AUTH-01A): settle-only *deposits* that can reach `onMMSettle(isSeizing=true)`
 ///      without a paired liquidity decrease are rejected in the impl — including the protocol-credit branch of
 ///      `SETTLE_POSITION_FROM_DELTAS` and raw `SETTLE_POSITION` deposits — so seizure carry cannot be advanced in
 ///      isolation from `_decreaseInternal`. Only the primary settle nested inside `SEIZE_POSITION` is allow-listed
 ///      for that phase via `TransientSlots` (cleared in `_afterBatch`).
 contract MMPositionManager is
     ERC721Permit_v4,
     IMMPositionManager,
     ReentrancyLock,
     Multicall_v4,
     Permit2Forwarder,
     BaseActionsRouter,
     FietNativeWrapper,
     PositionManagerEntrypoint
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
         /// @notice Stateless deployer for `MMQueueCustodian` (authorises callers via `marketFactory.bounds`).
         address queueCustodianFactory;
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
     /// @notice Deploys queue custodians; only factory-bound MMPMs may call `deploy` on it.
     address public immutable queueCustodianFactory;
     /// @notice One queue custodian per NFT recipient domain (many commits share the same custodian).
     mapping(address recipient => address) public custodianFor;
 
     /// @dev Utility custody bucket on the recipient-keyed custodian (`UNWRAP_LCC` / utility collect).
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
         if (p.queueCustodianFactory == address(0) || p.queueCustodianFactory.code.length == 0) {
             revert Errors.InvalidAddress(p.queueCustodianFactory);
         }
         commitmentDescriptor = p.descriptor;
         queueCustodianFactory = p.queueCustodianFactory;
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
 
     /// @dev Deploys `MMQueueCustodian` for `recipient` when absent (only from `_commitSignal`).
     function _deployQueueCustodian(address recipient) internal {
         if (recipient == address(0)) revert Errors.InvalidAddress(recipient);
         if (custodianFor[recipient] != address(0)) return;
         address ca = IMMQueueCustodianFactory(queueCustodianFactory).deploy(recipient, marketFactory);
         custodianFor[recipient] = ca;
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
     /// @dev Seizure deposit gating for SETTLE_POSITION and SETTLE_POSITION_FROM_DELTAS lives in the impl, not here;
     ///      this router delegates those checks to the same delegatecall module that performs onMMSettle and carry or
     ///      liquidity coupling (see MMPositionManager contract-level dev notes above).
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
         address nftRecipient;
 
         if (relayParams.length == 0) {
             if (msgSender() != mmOwner) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignal(marketFactory, liquiditySignal);
             _mint(mmOwner, tokenId);
             nftRecipient = mmOwner;
         } else {
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address sender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address mintRecipient = sender == address(0) ? mmOwner : sender;
             if (msgSender() != mintRecipient) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignalRelayed(
                 marketFactory, liquiditySignal, deadline, authNonce, authSig, sender
             );
             _mint(mintRecipient, tokenId);
             nftRecipient = mintRecipient;
         }
         _deployQueueCustodian(nftRecipient);
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
         MMHelpers.assertQueueCustodianForCommitToken(tokenId);
 
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
 
         address owner_ = _ownerOf[tokenId];
         address custAddr = custodianFor[owner_];
         if (custAddr != address(0) && !MMQueueCustodian(payable(custAddr)).isBucketEmpty(tokenId)) {
             revert Errors.CommitCustodyNotDrained(tokenId);
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
         MMHelpers.assertQueueCustodianForCommitToken(tokenId);
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
 
     /// @dev Routes unwrap through the recipient's `MMQueueCustodian`: custodian self-unwraps on Hub, then forwards immediate underlying to `forwardUnderlyingTo`.
     function _unwrapToQueueForward(
         address lccAddr,
         Currency lccCurrency,
         address forwardUnderlyingTo,
         address beneficiary,
         uint256 toUnwrap
     ) private {
         if (toUnwrap == 0) return;
-        MMHelpers.assertQueueCustodianForRecipient(beneficiary);
         address custAddr = custodianFor[beneficiary];
-        if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
+        if (custAddr == address(0)) {
+            _deployQueueCustodian(beneficiary);
+            custAddr = custodianFor[beneficiary];
+            if (custAddr == address(0)) {
+                revert Errors.QueueCustodianNotDeployed(beneficiary);
+            }
+        }
         MMQueueCustodian custodian = MMQueueCustodian(payable(custAddr));
         lccCurrency.transfer(custAddr, toUnwrap);
         custodian.unwrapLccViaHub(
             lccAddr, forwardUnderlyingTo, beneficiary, _UNWRAP_QUEUE_CUSTODY_TOKEN_ID, toUnwrap, liquidityHub
         );
     }
 
     /// @notice Unwraps LCC tokens to underlying asset using deltas (locker credit)
     /// @dev Native-backed LCC: custodian receives ETH from Hub during `unwrap`, then forwards to MMPM in the same call
     ///      (locker `receive()` does not run during Hub execution). The locker receives native credit and must
     ///      `TAKE(ADDRESS_ZERO, ...)` to withdraw ETH.
     function _unwrapLccFromDeltas(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         // Native: forward immediate underlying to MMPM; ERC20: forward per `to`.
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         uint256 toUnwrap = vtsOrchestrator.take(lccCurrency, msgSender(), requested);
 
         if (toUnwrap > 0) {
             address beneficiary = msgSender();
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, beneficiary, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
 
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
     }
 
     /// @notice Unwraps LCC tokens to underlying asset by pulling from the locker/user
     /// @dev Native-backed LCC: custodian forwards ETH to MMPM after Hub `unwrap`; see `_unwrapLccFromDeltas` NatSpec.
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
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         if (toUnwrap > 0) {
             // Pull only from the locker/user (never arbitrary third parties).
             // Snapshot queue *after* transfer: non-protocol -> protocol triggers annulment of queued
             // settlement (LCC-02), so the baseline for this unwrap's incremental queue must be post-annul.
             lccCurrency.transferFrom(payer, address(this), toUnwrap);
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, payer, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
     }
 
     /// @notice Collects available liquidity: Hub settles the queue-owner custodian, then underlying is paid to the locker.
     /// @param lcc The LCC token address
     /// @param tokenId The commitment NFT token id, or `0` for utility-bucket collect
     /// @param maxAmount The maximum amount to collect
     function _collectAvailableLiquidity(address lcc, uint256 tokenId, uint256 maxAmount) internal {
         if (maxAmount == 0) return;
         address locker = msgSender();
         address recipientKey = tokenId == 0 ? locker : _ownerOf[tokenId];
         if (recipientKey == address(0)) revert Errors.InvalidAddress(recipientKey);
-        MMHelpers.assertQueueCustodianForRecipient(recipientKey);
         address custAddr = custodianFor[recipientKey];
-        if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
+        if (custAddr == address(0)) {
+            _deployQueueCustodian(recipientKey);
+            custAddr = custodianFor[recipientKey];
+            if (custAddr == address(0)) revert Errors.QueueCustodianNotDeployed(recipientKey);
+        }
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
 
         uint256 bucket = tokenId == 0 ? _UNWRAP_QUEUE_CUSTODY_TOKEN_ID : tokenId;
         uint256 hubQ = liquidityHub.settleQueue(lcc, custAddr);
         uint256 entitled = custodian.queued(bucket, lcc, locker);
         (, uint256 holderBal) = ILCC(lcc).balancesOf(custAddr);
         (, uint256 reserveMarket) = liquidityHub.reserveOfUnderlyingTuple(lcc);
         // Match `LiquidityHubLib.processSettlementFor`: settlement is capped by mobilised market-derived reserve.
         uint256 amount = Math.min(Math.min(maxAmount, hubQ), Math.min(Math.min(entitled, holderBal), reserveMarket));
         if (amount == 0) return;
 
         liquidityHub.processSettlementFor(lcc, custAddr, amount);
         custodian.collectUnderlyingToBeneficiary(bucket, lcc, locker, amount);
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
     /// @dev Blocks transfer while the commitment bucket still has custodied slices on this owner's queue custodian.
     function transferFrom(address from, address to, uint256 id) public virtual override onlyIfPoolManagerLocked {
         address cust = custodianFor[from];
         if (cust != address(0) && !MMQueueCustodian(payable(cust)).isBucketEmpty(id)) {
             revert Errors.CommitCustodyNotDrained(id);
         }
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

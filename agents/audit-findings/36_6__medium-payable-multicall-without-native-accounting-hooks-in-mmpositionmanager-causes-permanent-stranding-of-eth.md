[Medium] Payable multicall without native accounting hooks in MMPositionManager causes permanent stranding of ETH

# Description

[MMPositionManager](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMPositionManager.sol#L44-L51) inherits a payable external multicall that bypasses the native-ETH accounting hooks. Sending ETH to multicall with no hooked inner calls succeeds, increases the manager’s balance, and creates no recoverable credit. Because [native SYNC is disabled](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMUtilityActionsImpl.sol#L306-L311) and [TAKE-to-self is forbidden for native](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/modules/PositionManagerBase.sol#L85-L92), the ETH becomes permanently unrecoverable for the sender.

The MMPositionManager contract [inherits Multicall_v4.multicall](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMPositionManager.sol#L44-L51), which is external and payable but does not invoke the manager’s [_beforeBatch](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L64-L69)/[_afterBatch](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L72-L80) hooks that account for msg.value and enforce zero net deltas. A call to multicall with an empty calls array (or otherwise no hooked, payable inner calls) will accept msg.value and immediately return, leaving the ETH on the contract’s balance without creating any locker credit or triggering end-of-batch assertions. There is no recovery path: [native SYNC is intentionally unsupported](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMUtilityActionsImpl.sol#L306-L311), [TAKE(native, to=address(this)) is explicitly disallowed](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/modules/PositionManagerBase.sol#L85-L92), and [wrapNative requires consuming a corresponding native delta first](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMUtilityActionsImpl.sol#L323-L330) (which was never created). No sweep function exists. As a result, ETH sent this way is permanently stranded and constitutes a direct loss to the sender.

# Severity

**Impact Explanation:** [High] Funds sent via multicall are permanently unrecoverable for the sender; no on-chain workaround exists (native SYNC disabled, TAKE-to-self for native forbidden, no sweep), meeting the criterion of funds frozen/blocked indefinitely.

**Likelihood Explanation:** [Low] Exploitation requires a user or integration error (empty or invalid multicall with value) or social engineering; typical, well-formed integrations call hooked entrypoints that run accounting hooks.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Accidental or integration error: A user or dApp calls MMPositionManager.multicall with an empty array of calls and msg.value = X. The function accepts the ETH, performs no accounting, and returns successfully. The sender cannot later recover the ETH due to native SYNC being disabled and TAKE-to-self forbidden for native.
#### Preconditions / Assumptions
- (a). MMPositionManager is deployed as written, inheriting a payable Multicall_v4.multicall without overrides.
- (b). The caller (user or integrator) submits multicall with an empty calls array and non-zero msg.value.
- (c). No special roles or authorizations are required.

### Scenario 2.
Phishing or misleading UI: A malicious front-end instructs a user to call MMPositionManager.multicall with msg.value > 0 but provides an empty or invalid inner call set. The transaction succeeds, ETH is accepted and unaccounted, and the user cannot recover the funds.
#### Preconditions / Assumptions
- (a). MMPositionManager is deployed as written, inheriting a payable Multicall_v4.multicall without overrides.
- (b). A malicious or buggy UI constructs a multicall with non-zero msg.value and empty/invalid calls.
- (c). The user signs and submits the transaction to the legitimate MMPositionManager address.

# Proposed fix

## MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMPositionManager.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
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
 import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
 import {PositionManagerEntrypoint} from "./modules/PositionManagerEntrypoint.sol";
 import {Permit2Forwarder} from "v4-periphery/src/base/Permit2Forwarder.sol";
 import {MMActions} from "./libraries/MMActions.sol";
 import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
 import {MMHelpers} from "./libraries/MMHelpers.sol";
 import {MMQueueCustodianLib} from "./libraries/MMQueueCustodianLib.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {IMMQueueCustodianFactory} from "./interfaces/IMMQueueCustodianFactory.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
 
 /// @title MMPositionManager
 /// @notice Entry point for VRL commitment position management
 /// @dev Handles commitment lifecycle (ERC721) and `INITIALISE` locally; delegates utility actions (>= `TAKE`) to
 ///      `MMUtilityActionsImpl` via `_delegateToUtilityImpl`, and position operations to `MMPositionActionsImpl`.
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
     using MMQueueCustodianLib for IMMPositionManager;
 
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
         /// @notice Delegatecall module for utility actions (>= `MMActions.TAKE`); excludes `INITIALISE`.
         address utilityActionsImpl;
         /// @notice Stateless deployer for `MMQueueCustodian` (authorises callers via `marketFactory.bounds`).
         address queueCustodianFactory;
     }
 
     using MMCalldataDecoder for bytes;
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
     /// @notice One queue custodian per beneficiary domain (locker / seizer); immutable beneficiary inside the custodian.
     mapping(address recipient => address) public custodianFor;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Constructor
     // ═══════════════════════════════════════════════════════════════════════════
 
     constructor(MMPositionManagerInit memory p)
         ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
         BaseActionsRouter(p.poolManager)
         Permit2Forwarder(p.permit2)
         FietNativeWrapper(p.weth9)
         PositionManagerEntrypoint(
             p.marketFactory, p.vtsOrchestrator, p.canonicalCustody, p.actionsImpl, p.utilityActionsImpl
         )
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
 
     /// @dev Deploys `MMQueueCustodian` for `recipient` when absent (`INITIALISE`, tests).
     ///      There is no lazy deployment on unwrap/collect: queue-forward paths require `custodianFor[recipient] != 0`
     ///      (see `INVARIANTS.md`); integrators must call `INITIALISE` (or rely on tests) before those flows.
     function _deployQueueCustodian(address recipient) internal {
         if (recipient == address(0)) revert Errors.InvalidAddress(recipient);
         if (custodianFor[recipient] != address(0)) return;
         address ca = IMMQueueCustodianFactory(queueCustodianFactory).deploy(recipient, marketFactory);
         if (ca == address(0) || ca.code.length == 0) revert Errors.InvalidAddress(ca);
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
 
     /// @inheritdoc FietNativeWrapper
     function _isCustodian(address candidate) internal view override returns (bool) {
         return IMMPositionManager(address(this)).isRegisteredCustodian(candidate);
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
     /// @dev Actions >= TAKE delegate to `utilityActionsImpl` except `INITIALISE` (writes `custodianFor` here)
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
 
         // Currency/utility actions (>= TAKE) → utility impl (INITIALISE handled locally in `_handleUtilityAction`)
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
         if (action == MMActions.INITIALISE) {
             params.decodeInitialiseParams();
             _deployQueueCustodian(msgSender());
             return;
         }
         _delegateToUtilityImpl(abi.encodeWithSelector(IMMActionsImpl.handleAction.selector, action, params));
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
+
+    /// @dev Guard value-funded multicalls so at least one hooked entrypoint runs native accounting hooks.
+    function multicall(bytes[] calldata data) external payable override returns (bytes[] memory results) {
+        if (msg.value > 0) {
+            bool ok;
+            for (uint256 i; i < data.length && !ok; ++i) {
+                bytes calldata c = data[i];
+                if (c.length >= 4) {
+                    bytes4 s; assembly { s := shr(224, calldataload(c.offset)) }
+                    if (s == this.modifyLiquidities.selector || s == this.modifyLiquiditiesWithoutUnlock.selector) ok = true;
+                }
+            }
+            if (!ok) revert Errors.InvalidAmount(msg.value, 0);
+        }
+        results = new bytes[](data.length); for (uint256 i; i < data.length; ++i) { (bool success, bytes memory r) = address(this).delegatecall(data[i]); if (!success) { assembly { revert(add(r, 0x20), mload(r)) } } results[i] = r; }
+    }
 }
```

# Related findings

## [Low] Forced raw-ETH payout without receiver checks in MMPositionActionsImpl causes DoS on protocol-owned native credit withdrawals

### Description

When withdrawing protocol-owned native credits via [SETTLE_POSITION_FROM_DELTAS (payerIsUser=true, shouldTake=true)](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMPositionActionsImpl.sol#L780-L819), MMPositionActionsImpl [forces a raw ETH transfer to the locker](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMPositionActionsImpl.sol#L520-L537) with no capability check or WETH fallback. If the locker is non-payable, the call reverts, blocking redemption through this intended path.

In the SETTLE_POSITION_FROM_DELTAS flow, when payerIsUser=true and shouldTake=true, MMPositionActionsImpl [hardcodes usePositionManagerBalance=false for the settlement](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMPositionActionsImpl.sol#L780-L819). After the market vault withdraws underlying to the manager, the implementation [directly forwards any positive native deltas to the locker (Locker.get()) via a raw ETH transfer](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMPositionActionsImpl.sol#L520-L537). Unlike LiquidityHub’s hardened payout (which uses INativeSettlementReceiver gating and a WETH fallback), this MM path has no receiver capability check and no fallback. If the locker is a non-payable contract or rejects ETH, the transfer reverts and the entire withdrawal fails, causing a persistent DoS for redeeming protocol-owned native credits via this path. [The caller cannot opt into usePositionManagerBalance for this specific action shape](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMPositionActionsImpl.sol#L780-L819), so they cannot avoid the raw push. While workarounds exist (e.g., switching to a payable EOA locker context or routing credits through a position and unwinding via the Hub’s hardened path), this remains a meaningful availability issue for affected lockers.

### Severity

**Impact Explanation:** [Medium] This is a significant availability loss of an important withdrawal path (protocol-owned native credit redemption) for affected lockers, but it does not cause loss of principal and workarounds exist.

**Likelihood Explanation:** [Low] Multiple independent preconditions must align (native leg, protocol-owned credits, specific action shape, non-payable locker). Integrators and users can often avoid non-payable lockers or switch context, reducing overall likelihood.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
A user with protocol-owned native credits attempts to withdraw them via SETTLE_POSITION_FROM_DELTAS (payerIsUser=true, shouldTake=true) while their locker is a non-payable contract wallet. MMPositionActionsImpl forces a raw ETH push to the locker, which reverts, so the withdrawal fails repeatedly and the user cannot redeem these credits through this path.
#### Preconditions / Assumptions
- (a). The market has a native ETH underlying leg for the relevant token
- (b). The user holds protocol-owned underlying delta credits (address(this) credits) for that native leg
- (c). The user calls SETTLE_POSITION_FROM_DELTAS with payerIsUser=true and shouldTake=true
- (d). The locker resolved by Locker.get() is a non-payable (or ETH-rejecting) contract
- (e). The withdrawal amount is greater than zero

### Scenario 2.
An integration router used by many users serves as the locker and is non-payable. Multiple users with protocol-owned native credits attempt to withdraw via SETTLE_POSITION_FROM_DELTAS (payerIsUser=true, shouldTake=true). Each withdrawal forces a raw ETH push to the router and reverts, causing widespread DoS for this withdrawal path until the integration changes or users switch context.
#### Preconditions / Assumptions
- (a). The market uses a native ETH underlying leg
- (b). Affected users have protocol-owned underlying delta credits for that leg
- (c). Users call SETTLE_POSITION_FROM_DELTAS with payerIsUser=true and shouldTake=true through the integration
- (d). The integration router that acts as the locker is non-payable (or reverts on ETH receive)
- (e). Withdrawal amounts are greater than zero

### Proposed fix

#### MMPositionActionsImpl.sol

File: `contracts/evm/src/MMPositionActionsImpl.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMPositionActionsImpl.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
 import {PositionId, PositionLibrary, PositionModificationHookDataLib} from "./types/Position.sol";
 import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {IMarketVault} from "./interfaces/IMarketVault.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
 import {Position} from "./types/Position.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
 import {PositionManagerImpl} from "./modules/PositionManagerImpl.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {MarketHandlerLib} from "./libraries/MarketHandlerLib.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
 import {MMActions} from "./libraries/MMActions.sol";
 import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
 import {MMHelpers} from "./libraries/MMHelpers.sol";
 import {Locker} from "v4-periphery/src/libraries/Locker.sol";
 import {DelegateCallGuard} from "./modules/DelegateCallGuard.sol";
 import {VaultSettlementIntent} from "./types/VTS.sol";
 import {SlippageCheck} from "v4-periphery/src/libraries/SlippageCheck.sol";
 
 /// @title MMPositionActionsImpl
 /// @notice Implementation contract for MMPositionManager position operations
 /// @dev Called via delegatecall from MMPositionManager, shares storage context
 /// @dev Only handles position operations (actions <= SETTLE_POSITION_FROM_DELTAS)
 /// @dev ERC721 functions accessed via delegatecall context from MMPositionManager
 contract MMPositionActionsImpl is IMMActionsImpl, PositionManagerImpl, DelegateCallGuard {
     using SafeCast for uint256;
     using PositionLibrary for PositionId;
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
     using CurrencySettler for Currency;
     using CurrencyTransfer for Currency;
     using MMCalldataDecoder for bytes;
     using SlippageCheck for BalanceDelta;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Internal Structs
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @dev Internal struct to reduce stack depth in _settle
     /// @notice Groups transfer-related parameters to avoid stack-too-deep errors
     struct SettleTransferParams {
         Currency underlying0;
         Currency underlying1;
         IMarketVault vault;
         bool usePositionManagerBalance;
     }
 
     /// @dev Internal struct to reduce stack depth in _settle
     /// @notice Groups onMMSettle call parameters
     struct SettleCallParams {
         IMarketVault vault;
         IMarketFactory factory;
         uint256 tokenId;
         uint256 positionIndex;
         BalanceDelta requestedDelta;
         bool isSeizing;
         /// @dev Passed through to `onMMSettle`: affects deposit lanes only; no-op for withdrawals.
         bool fromDeltas;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Immutables (must match MMPositionManager's values)
     // ═══════════════════════════════════════════════════════════════════════════
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Constructor
     // ═══════════════════════════════════════════════════════════════════════════
 
     constructor(address _manager, address _marketFactory, address _vtsOrchestrator, address _canonicalCustody)
         PositionManagerImpl(IPoolManager(_manager), _marketFactory, _vtsOrchestrator, _canonicalCustody)
     {}
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Overrides for abstract functions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc PositionManagerBase
     function msgSender() public view override returns (address) {
         // References locker from delegatecall context - MMPositionManager
         return Locker.get();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Position Action Handler
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc IMMActionsImpl
     /// @dev Only handles position operations (actions <= SETTLE_POSITION_FROM_DELTAS)
     function handleAction(uint256 action, bytes calldata params) external payable override onlyDelegateCall {
         if (action == MMActions.SETTLE_POSITION) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 int128 amount0,
                 int128 amount1,
                 bool usePositionManagerBalance
             ) = params.decodeSettlePositionParams();
             _settle(poolKey, tokenId, positionIndex, amount0, amount1, usePositionManagerBalance);
             return;
         }
         if (action == MMActions.MINT_POSITION) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 int24 tickLower,
                 int24 tickUpper,
                 uint256 liquidity,
                 uint128 amount0Max,
                 uint128 amount1Max
             ) = params.decodeMintPositionParams();
             _mintPosition(poolKey, tokenId, tickLower, tickUpper, liquidity, amount0Max, amount1Max);
             return;
         }
         if (action == MMActions.INCREASE_LIQUIDITY) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint256 liquidity,
                 uint128 amount0Max,
                 uint128 amount1Max
             ) = params.decodeIncreaseLiquidityParams();
             _increase(poolKey, tokenId, positionIndex, liquidity, amount0Max, amount1Max);
             return;
         }
         if (action == MMActions.DECREASE_LIQUIDITY) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint256 amountToDecrease,
                 uint128 amount0Min,
                 uint128 amount1Min
             ) = params.decodeDecreaseLiquidityParams();
             _decrease(poolKey, tokenId, positionIndex, amountToDecrease, amount0Min, amount1Min);
             return;
         }
         if (action == MMActions.BURN_POSITION) {
             (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint128 amount0Min, uint128 amount1Min) =
                 params.decodeBurnPositionParams();
             _burnPosition(poolKey, tokenId, positionIndex, amount0Min, amount1Min);
             return;
         }
         if (action == MMActions.SEIZE_POSITION) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint256 amount0,
                 uint256 amount1,
                 bool usePositionManagerBalance
             ) = params.decodeSeizePositionParams();
             _seizePosition(poolKey, tokenId, positionIndex, amount0, amount1, usePositionManagerBalance);
             return;
         }
         if (action == MMActions.INCREASE_LIQUIDITY_FROM_DELTAS) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint128 amount0Max,
                 uint128 amount1Max,
                 bool payerIsUser
             ) = params.decodeIncreaseFromDeltasParams();
             _increaseFromDeltas(poolKey, tokenId, positionIndex, amount0Max, amount1Max, payerIsUser);
             return;
         }
         if (action == MMActions.MINT_POSITION_FROM_DELTAS) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 int24 tickLower,
                 int24 tickUpper,
                 uint128 amount0Max,
                 uint128 amount1Max,
                 bool payerIsUser
             ) = params.decodeMintFromDeltasParams();
             _mintFromDeltas(poolKey, tokenId, tickLower, tickUpper, amount0Max, amount1Max, payerIsUser);
             return;
         }
         if (action == MMActions.SETTLE_POSITION_FROM_DELTAS) {
             (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, bool payerIsUser, bool shouldTake) =
                 params.decodeSettleFromDeltasParams();
             _settleFromDeltas(poolKey, tokenId, positionIndex, payerIsUser, shouldTake);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Internal Helpers
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Returns the position information for a given token ID and position index
     /// @param tokenId The ERC721 tokenId (commitment NFT ID)
     /// @param positionIndex The index of the position within the commitment
     /// @return Position The position information
     /// @return PositionId The position ID
     function getPosition(uint256 tokenId, uint256 positionIndex) public view returns (Position memory, PositionId) {
         return vtsOrchestrator.getPosition(tokenId, positionIndex);
     }
 
     /// @notice Returns the position ID for a given token ID and position index
     /// @param tokenId The ERC721 tokenId (commitment NFT ID)
     /// @param positionIndex The index of the position within the commitment
     /// @return The position ID
     function getPositionId(uint256 tokenId, uint256 positionIndex) public view returns (PositionId) {
         return vtsOrchestrator.getPositionId(tokenId, positionIndex);
     }
 
     /// @notice Checks if a position is currently being seized
     /// @param positionId The position ID to check
     /// @return True if the position is being seized
     function _isSeizing(PositionId positionId) internal view returns (bool) {
         PositionId seizedPositionId = TransientSlots.getSeizedPositionId();
         return PositionId.unwrap(seizedPositionId) == PositionId.unwrap(positionId);
     }
 
     /// @notice Gets the vault for a pool key
     /// @param poolKey The pool key
     /// @return The vault
     function _getVault(PoolKey calldata poolKey) internal view returns (IMarketVault) {
         return MarketHandlerLib.getVault(marketFactory, poolKey.toId());
     }
 
     /// @dev Splits hook encoding out of `_increaseFromDeltas` / `_mintFromDeltas` to avoid stack-too-deep in unoptimised builds.
     function _encodePositionHookForRecipientKeyedCustodian(
         uint256 tokenId,
         uint256 positionIndex,
         address locker,
         bool withInHookProtocolSettlement,
         uint256 credit0,
         uint256 credit1
     ) private returns (bytes memory) {
         address qRec = _queueSettleRecipient(tokenId);
         if (withInHookProtocolSettlement) {
             return PositionModificationHookDataLib.encodeWithInHookProtocolSettlement(
                 tokenId, positionIndex, locker, qRec, credit0, credit1
             );
         }
         return PositionModificationHookDataLib.encode(tokenId, positionIndex, locker, qRec);
     }
 
     /// @notice Reverts when principal token spend exceeds user-provided maxima
     function _validateMaxIn(BalanceDelta principalDelta, uint128 amount0Max, uint128 amount1Max) internal pure {
         int256 amount0 = principalDelta.amount0();
         int256 amount1 = principalDelta.amount1();
         if (amount0 < 0 && amount0Max < uint128(uint256(-amount0))) {
             revert Errors.MaximumAmountExceeded(amount0Max, uint128(uint256(-amount0)));
         }
         if (amount1 < 0 && amount1Max < uint128(uint256(-amount1))) {
             revert Errors.MaximumAmountExceeded(amount1Max, uint128(uint256(-amount1)));
         }
     }
 
     /// @notice Settles locker's available delta credits into the position via MMPM balance.
     function _settleFromDeltasCredits(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 credit0,
         uint256 credit1
     ) internal {
         _settle(poolKey, tokenId, positionIndex, -credit0.toInt128(), -credit1.toInt128(), true);
     }
 
     /// @notice Settles protocol-owned underlying delta credits into the position without token movement.
     function _settleProtocolCreditsFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 credit0,
         uint256 credit1,
         bool isSeizing
     ) internal {
         if (credit0 == 0 && credit1 == 0) return;
         if (isSeizing) {
             revert Errors.SeizureSettleOnlyDepositDisallowed();
         }
 
         _callOnMMSettle(
             SettleCallParams({
                 vault: _getVault(poolKey),
                 factory: marketFactory,
                 tokenId: tokenId,
                 positionIndex: positionIndex,
                 requestedDelta: LiquidityUtils.safeToBalanceDelta(credit0, credit1, true, true),
                 isSeizing: isSeizing,
                 fromDeltas: true
             })
         );
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Position Actions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Seizes a position (third-party guarantor action)
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amount0 The amount of token0 for seizure settlement
     /// @param amount1 The amount of token1 for seizure settlement
     /// @param usePositionManagerBalance If true, tokens flow via MMPM balance and locker's deltas are adjusted
     function _seizePosition(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 amount0,
         uint256 amount1,
         bool usePositionManagerBalance
     ) internal {
         (Position memory position, PositionId positionId) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         if (MMHelpers.isApprovedOrOwner(msgSender(), tokenId) || position.isActive == false) {
             revert Errors.InvalidPosition(tokenId, positionIndex, positionId);
         }
 
         vtsOrchestrator.onSeize(tokenId, positionIndex);
         TransientSlots.setSeizedPositionId(positionId);
 
         // negative amounts since we are settling into a position
         TransientSlots.setSeizurePrimarySettleAllowed(true);
         (BalanceDelta settlementDelta, uint256 seizedLiquidityUnits) = _settle(
             poolKey, tokenId, positionIndex, -amount0.toInt128(), -amount1.toInt128(), usePositionManagerBalance
         );
         TransientSlots.setSeizurePrimarySettleAllowed(false);
 
         // Fail closed: a zero-liquidity decrease still runs `modifyLiquidity` and can realise accrued LCC fees to the
         // locker (seizer) without removing any position liquidity. Seizure must not proceed unless the settlement
         // phase produced a non-zero seized-liquidity amount from VTS sizing.
         if (seizedLiquidityUnits == 0) {
             revert Errors.SeizureWithoutLiquidityRemoval();
         }
 
         // Use returned maxima clamped settlementDelta
         bytes memory hookData = PositionModificationHookDataLib.encodeSeizure(
             tokenId,
             positionIndex,
             msgSender(),
             _queueSettleRecipient(tokenId),
             settlementDelta.amount0(),
             settlementDelta.amount1()
         );
 
         _decreaseInternal(
             poolKey,
             position,
             PositionLibrary.generateSalt(tokenId, positionIndex),
             tokenId,
             seizedLiquidityUnits,
             hookData,
             0,
             0
         );
     }
 
     /// @notice Calls VTS orchestrator onMMSettle with bundled parameters
     /// @dev Extracted to reduce stack depth in _settle (avoids stack-too-deep with coverage instrumentation)
     /// @param params The call parameters bundled in a struct
     /// @return settlementDelta The settlement delta
     /// @return seizedLiquidityUnits The amount of liquidity units seized
     function _callOnMMSettle(SettleCallParams memory params)
         internal
         returns (
             BalanceDelta settlementDelta,
             uint256 seizedLiquidityUnits,
             VaultSettlementIntent memory vaultSettlementIntent
         )
     {
         (settlementDelta,, seizedLiquidityUnits, vaultSettlementIntent) =
             vtsOrchestrator.onMMSettle(
                 params.factory,
                 params.tokenId,
                 params.positionIndex,
                 params.requestedDelta,
                 params.isSeizing,
                 params.fromDeltas
             );
     }
 
     /// @notice Processes settlement transfers for a position
     /// @dev Extracted to reduce stack depth in _settle (avoids stack-too-deep with coverage instrumentation)
     /// @param params The transfer parameters bundled in a struct
     /// @param settlementIntent The explicit vault settlement intent from VTS
     function _processSettlementTransfers(
         SettleTransferParams memory params,
         VaultSettlementIntent memory settlementIntent
     ) internal {
         BalanceDelta settlementDelta = settlementIntent.requestedDelta;
         // Adheres to core/LCC pool token ordering.
         int128 delta0 = settlementDelta.amount0();
         int128 delta1 = settlementDelta.amount1();
 
         address sender = msgSender();
         address custody = canonicalCustody;
 
         // Process negative deltas (inflows to vault)
         if (delta0 < 0) {
             uint256 amt0 = LiquidityUtils.safeInt128ToUint256(delta0);
             if (params.usePositionManagerBalance) {
                 // Ensure locker credit is fully consumed before moving pooled MMPM funds.
                 uint256 taken0 = vtsOrchestrator.take(params.underlying0, sender, amt0);
                 if (taken0 != amt0) {
                     revert Errors.InsufficientBalance(taken0, amt0);
                 }
                 params.underlying0.transfer(custody, amt0);
             } else {
                 // Settle IN (deposit) of native ETH MUST come from MMPM balance.
                 if (params.underlying0 == CurrencyLibrary.ADDRESS_ZERO) {
                     revert Errors.NativeTransferFromUnsupported(sender);
                 }
                 // Otherwise, pull only from the locker (msgSender()).
                 params.underlying0.transferFrom(sender, custody, amt0);
             }
         }
         if (delta1 < 0) {
             uint256 amt1 = LiquidityUtils.safeInt128ToUint256(delta1);
             if (params.usePositionManagerBalance) {
                 uint256 taken1 = vtsOrchestrator.take(params.underlying1, sender, amt1);
                 if (taken1 != amt1) {
                     revert Errors.InsufficientBalance(taken1, amt1);
                 }
                 params.underlying1.transfer(custody, amt1);
             } else {
                 if (params.underlying1 == CurrencyLibrary.ADDRESS_ZERO) {
                     revert Errors.NativeTransferFromUnsupported(sender);
                 }
                 params.underlying1.transferFrom(sender, custody, amt1);
             }
         }
 
         params.vault.modifyLiquidities(settlementIntent);
 
         // Process positive deltas (outflows from vault)
         if (params.usePositionManagerBalance) {
             // Native: exact; ERC20: exact from settlement delta (not omnibus MMPM balance sync)
             if (delta0 > 0) {
                 uint256 amt0Out = LiquidityUtils.safeInt128ToUint256(delta0);
                 _creditExact(params.underlying0, amt0Out);
             }
             if (delta1 > 0) {
                 uint256 amt1Out = LiquidityUtils.safeInt128ToUint256(delta1);
                 _creditExact(params.underlying1, amt1Out);
             }
         } else {
             // or forward to the locker.
             if (delta0 > 0) {
+                // FIXME (native-aware payout hardening):
+                // For native ETH underlying, replace direct transfer with a helper that mirrors LiquidityHubLib.transferUnderlying:
+                // - EOAs: try raw ETH, else fallback to WETH9 deposit then ERC20 transfer
+                // - Contracts: only raw-push if EIP-165 supports INativeSettlementReceiver with a fixed gas stipend; else WETH9 transfer
+                // Suggested replacement: _forwardUnderlyingToLocker(params.underlying0, sender, LiquidityUtils.safeInt128ToUint256(delta0))
                 params.underlying0.transfer(sender, LiquidityUtils.safeInt128ToUint256(delta0));
             }
             if (delta1 > 0) {
+                // See note above: apply the same native-aware payout policy to currency1.
+                // Suggested replacement: _forwardUnderlyingToLocker(params.underlying1, sender, LiquidityUtils.safeInt128ToUint256(delta1))
                 params.underlying1.transfer(sender, LiquidityUtils.safeInt128ToUint256(delta1));
             }
         }
     }
 
     /// @notice Settles underlying assets to/from a position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amount0 The amount of token0 to settle (signed)
     /// @param amount1 The amount of token1 to settle (signed)
     /// @param usePositionManagerBalance If true, tokens flow via MMPM balance and locker's deltas are adjusted.
     ///        If false, tokens flow directly from/to locker (external transfer).
     /// @return seizedLiquidityUnits The amount of liquidity units seized (if applicable)
     function _settle(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         int128 amount0,
         int128 amount1,
         bool usePositionManagerBalance
     ) internal returns (BalanceDelta, uint256) {
         if (amount0 == 0 && amount1 == 0) {
             revert Errors.InvalidDelta(0, 0);
         }
 
         // Build call params in scoped block to release intermediate variables
         SettleCallParams memory callParams;
         {
             // Position validation in nested scope
             bool isSeizing;
             {
                 Position memory position;
                 PositionId positionId;
                 (position, positionId) = getPosition(tokenId, positionIndex);
                 MMHelpers.assertPositionForPool(poolKey, position);
                 isSeizing = _isSeizing(positionId);
             }
 
             // AUTH-01A: only the primary `SEIZE_POSITION` deposit settle may bypass NFT owner checks. All follow-on
             // settles (including seizing withdrawals) require `approvedOrOwner` so a seizer cannot drain router-scoped
             // underlying credit without commitment NFT authorisation.
             bool isDepositLane = (amount0 < 0) || (amount1 < 0);
             if (isSeizing && isDepositLane && !TransientSlots.getSeizurePrimarySettleAllowed()) {
                 revert Errors.SeizureSettleOnlyDepositDisallowed();
             }
             bool inPrimarySeizeSettle = isSeizing && TransientSlots.getSeizurePrimarySettleAllowed() && isDepositLane;
             if (!inPrimarySeizeSettle) {
                 MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
             }
 
             callParams = SettleCallParams({
                 vault: _getVault(poolKey),
                 factory: marketFactory,
                 tokenId: tokenId,
                 positionIndex: positionIndex,
                 requestedDelta: toBalanceDelta(amount0, amount1),
                 isSeizing: isSeizing,
                 fromDeltas: false
             });
         }
 
         // Call onMMSettle via helper
         (
             BalanceDelta settlementDelta,
             uint256 seizedLiquidityUnits,
             VaultSettlementIntent memory vaultSettlementIntent
         ) = _callOnMMSettle(callParams);
 
         // Process settlement transfers via helper (reduces stack depth)
         _processSettlementTransfers(
             SettleTransferParams({
                 underlying0: _lccToUnderlyingCurrency(poolKey.currency0),
                 underlying1: _lccToUnderlyingCurrency(poolKey.currency1),
                 vault: callParams.vault,
                 usePositionManagerBalance: usePositionManagerBalance
             }),
             vaultSettlementIntent
         );
 
         return (settlementDelta, seizedLiquidityUnits);
     }
 
     /// @notice Burns (fully decreases) a position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     function _burnPosition(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint128 amount0Min,
         uint128 amount1Min
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         uint256 completeLiquidity = uint256(position.liquidity);
         address qRec = _queueSettleRecipient(tokenId);
         _decreaseInternal(
             poolKey,
             position,
             PositionLibrary.generateSalt(tokenId, positionIndex),
             tokenId,
             completeLiquidity,
             PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender(), qRec),
             amount0Min,
             amount1Min
         );
     }
 
     /// @notice Increases liquidity in an existing position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param liquidity The amount of liquidity to add
     /// @param amount0Max Maximum token0 principal spend (LCC leg)
     /// @param amount1Max Maximum token1 principal spend
     function _increase(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 liquidity,
         uint128 amount0Max,
         uint128 amount1Max
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
         (, BalanceDelta principalDelta) =
             _increaseInternal(poolKey, tokenId, positionIndex, position.tickLower, position.tickUpper, liquidity);
         _validateMaxIn(principalDelta, amount0Max, amount1Max);
     }
 
     /// @notice Internal helper to increase liquidity
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param liquidity The amount of liquidity to add
     /// @return positionId The position ID
     /// @return principalDelta Principal token deltas excluding informational fee accrual
     function _increaseInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity
     ) internal returns (PositionId positionId, BalanceDelta principalDelta) {
         address qRec = _queueSettleRecipient(tokenId);
         return _increaseInternal(
             poolKey,
             tokenId,
             positionIndex,
             tickLower,
             tickUpper,
             liquidity,
             PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender(), qRec)
         );
     }
 
     function _increaseInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity,
         bytes memory hookData
     ) internal returns (PositionId positionId, BalanceDelta principalDelta) {
         if (liquidity > type(uint128).max) {
             revert Errors.InvalidAmount(liquidity, type(uint128).max);
         }
 
         ModifyLiquidityParams memory params = ModifyLiquidityParams({
             tickLower: tickLower,
             tickUpper: tickUpper,
             liquidityDelta: liquidity.toInt256(),
             salt: PositionLibrary.generateSalt(tokenId, positionIndex)
         });
 
         positionId = PositionLibrary.generateId(address(this), params);
         (BalanceDelta liquidityDelta, BalanceDelta feesAccrued,) =
             _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
         principalDelta = liquidityDelta - feesAccrued;
     }
 
     /// @notice Increases liquidity using available delta credits
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amount0Max The maximum amount of token0 to spend
     /// @param amount1Max The maximum amount of token1 to spend
     /// @param payerIsUser If true, user consumes credit the protocol owes them (delta target = MMPM).
     ///        If false, uses locker's direct credit (delta target = locker).
     /// @dev Delta target semantics:
     ///      - MMPM (address(this)): Protocol owes/is owed by external sources
     ///      - Locker (msgSender()): External entity owes/is owed by protocol
     /// @dev tickLower and tickUpper are read from the position via getPosition()
     function _increaseFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint128 amount0Max,
         uint128 amount1Max,
         bool payerIsUser
     ) internal {
         address sender = msgSender();
         MMHelpers.assertApprovedOrOwner(sender, tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         // payerIsUser = true: User consumes credit protocol owes them (tracked on MMPM)
         // payerIsUser = false: Locker uses their own direct credit
         address deltaTarget = payerIsUser ? address(this) : sender;
         (uint256 liquidityFromDeltas, uint256 credit0, uint256 credit1) =
             _getLiquidityFromDeltas(poolKey, deltaTarget, position.tickLower, position.tickUpper);
         bytes memory hookData = _encodePositionHookForRecipientKeyedCustodian(
             tokenId, positionIndex, sender, payerIsUser, credit0, credit1
         );
         (, BalanceDelta principalDelta) = _increaseInternal(
             poolKey, tokenId, positionIndex, position.tickLower, position.tickUpper, liquidityFromDeltas, hookData
         );
         _validateMaxIn(principalDelta, amount0Max, amount1Max);
         if (!payerIsUser) {
             _settleFromDeltasCredits(poolKey, tokenId, positionIndex, credit0, credit1);
         }
     }
 
     /// @notice Mints a new position within a commitment
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param liquidity The amount of liquidity to mint
     /// @param amount0Max Maximum token0 principal spend (LCC leg)
     /// @param amount1Max Maximum token1 principal spend
     function _mintPosition(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity,
         uint128 amount0Max,
         uint128 amount1Max
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         (,, BalanceDelta principalDelta) = _mintPositionInternal(poolKey, tokenId, tickLower, tickUpper, liquidity);
         _validateMaxIn(principalDelta, amount0Max, amount1Max);
     }
 
     /// @notice Mints a new position using available delta credits
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param amount0Max The maximum amount of token0 to spend
     /// @param amount1Max The maximum amount of token1 to spend
     /// @param payerIsUser If true, user consumes credit the protocol owes them (delta target = MMPM).
     ///        If false, uses locker's direct credit (delta target = locker).
     /// @dev Delta target semantics:
     ///      - MMPM (address(this)): Protocol owes/is owed by external sources
     ///      - Locker (msgSender()): External entity owes/is owed by protocol
     function _mintFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint128 amount0Max,
         uint128 amount1Max,
         bool payerIsUser
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         // payerIsUser = true: User consumes credit protocol owes them (tracked on MMPM)
         // payerIsUser = false: Locker uses their own direct credit
         address deltaTarget = payerIsUser ? address(this) : msgSender();
         (uint256 liquidityFromDeltas, uint256 credit0, uint256 credit1) =
             _getLiquidityFromDeltas(poolKey, deltaTarget, tickLower, tickUpper);
         uint256 nextPositionIndex;
         (,, nextPositionIndex,,) = vtsOrchestrator.getCommit(tokenId);
         bytes memory hookData = _encodePositionHookForRecipientKeyedCustodian(
             tokenId, nextPositionIndex, msgSender(), payerIsUser, credit0, credit1
         );
         // This works as LCCs are issued, capitalised by underlying tokens owed to the MM.
         (, uint256 positionIndex, BalanceDelta principalDelta) =
             _mintPositionInternal(poolKey, tokenId, tickLower, tickUpper, liquidityFromDeltas, hookData);
         _validateMaxIn(principalDelta, amount0Max, amount1Max);
         if (!payerIsUser) {
             _settleFromDeltasCredits(poolKey, tokenId, positionIndex, credit0, credit1);
         }
     }
 
     /// @notice Settles into/from the position using available delta credits
     /// @dev Note: We can only do additional actions (such as settle in or out) on credits (deltas that are positive).
     ///      Credits represent amounts the system owes to the user, which can be settled into positions or withdrawn.
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param payerIsUser If true, use protocol delta (address(this)). If false, use locker delta (msgSender()).
     /// @param shouldTake If true, withdraw (consume credit). If false, deposit (settle credit into position).
     /// @dev Delta semantics:
     ///      - Protocol delta (address(this)): Protocol owes/is owed by external sources
     ///      - Locker delta (msgSender()): External entity owes/is owed by protocol
     function _settleFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         bool payerIsUser,
         bool shouldTake
     ) internal {
         address sender = msgSender();
 
         Currency underlying0 = _lccToUnderlyingCurrency(poolKey.currency0);
         Currency underlying1 = _lccToUnderlyingCurrency(poolKey.currency1);
 
         // Ambient seizure (AUTH-01A / audit 30_3): `SETTLE_POSITION_FROM_DELTAS` with `payerIsUser=true` and
         // `shouldTake=false` is the protocol-credit *deposit* matrix cell. It calls `onMMSettle(isSeizing=true)` without
         // any guaranteed `_decreaseInternal` coupling, so carry and sizing can advance while liquidity stays unchanged.
         // Forbid this cell whenever the batch already marked this `(tokenId, positionIndex)` as seized — even when
         // there are no protocol credits yet (otherwise the call would be a misleading no-op while still being the
         // wrong operation to schedule under seizure).
         if (payerIsUser && !shouldTake) {
             (Position memory position, PositionId positionId) = getPosition(tokenId, positionIndex);
             MMHelpers.assertPositionForPool(poolKey, position);
             if (_isSeizing(positionId)) {
                 revert Errors.SeizureSettleOnlyDepositDisallowed();
             }
         }
 
         // Behaviour matrix:
         // - shouldTake=true && payerIsUser=true:  Withdraw to locker from protocol delta via _settle
         // - shouldTake=false && payerIsUser=true: Settle protocol-owned delta credits via VTS lifecycle accounting
         // - shouldTake=true && payerIsUser=false: Withdraw to MMPM and sync credits
         // - shouldTake=false && payerIsUser=false: Settle from MMPM balance via _settle
 
         // Get protocol delta credits (address(this))
         (uint256 credit0, uint256 credit1) = _getFullCreditPair(underlying0, underlying1, address(this));
 
         if (credit0 > 0 || credit1 > 0) {
             if (shouldTake) {
                 // WITHDRAW: Move credits out as tokens
                 // Protocol owes user → withdraw to locker via _settle
                 _settle(poolKey, tokenId, positionIndex, credit0.toInt128(), credit1.toInt128(), !payerIsUser);
                 // if !payerIsUser, balance sync handled in _settle
             } else {
                 // DEPOSIT: Settle protocol-owned underlying delta credits into the position with no token movement.
                 bool isSeizing;
                 {
                     Position memory position;
                     PositionId positionId;
                     (position, positionId) = getPosition(tokenId, positionIndex);
                     MMHelpers.assertPositionForPool(poolKey, position);
                     isSeizing = _isSeizing(positionId);
                 }
 
                 if (!isSeizing) {
                     MMHelpers.assertApprovedOrOwner(sender, tokenId);
                 }
 
                 _settleProtocolCreditsFromDeltas(poolKey, tokenId, positionIndex, credit0, credit1, isSeizing);
             }
         }
         if (!payerIsUser && !shouldTake) {
             // Settle from MMPM balance (actual token movement)
             (uint256 lockerCredit0, uint256 lockerCredit1) = _getFullCreditPair(underlying0, underlying1, sender);
             _settle(poolKey, tokenId, positionIndex, -lockerCredit0.toInt128(), -lockerCredit1.toInt128(), true);
         }
     }
 
     /// @notice Internal helper to decrease liquidity
     /// @param poolKey The pool key
     /// @param position The position to decrease
     /// @param salt The position salt
     /// @param amountToDecrease The amount of liquidity to remove
     /// @param hookData The hook data for the modification
     function _decreaseInternal(
         PoolKey calldata poolKey,
         Position memory position,
         bytes32 salt,
         uint256 tokenId,
         uint256 amountToDecrease,
         bytes memory hookData,
         uint128 amount0Min,
         uint128 amount1Min
     ) internal {
         uint256 posLiq = uint256(position.liquidity);
         if (amountToDecrease > posLiq) {
             revert Errors.InvalidAmount(amountToDecrease, posLiq);
         }
 
         if (amountToDecrease > uint256(type(int256).max)) {
             amountToDecrease = uint256(type(int256).max);
         }
 
         ModifyLiquidityParams memory params = ModifyLiquidityParams({
             tickLower: position.tickLower,
             tickUpper: position.tickUpper,
             liquidityDelta: -amountToDecrease.toInt256(),
             salt: salt
         });
 
         (,, BalanceDelta mmForwardedNonFeeForMinOut) = _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
         // Min-out on immediate non-fee LCC after fee netting, not raw `callerDelta - feesAccrued` (VTS queue principal).
         mmForwardedNonFeeForMinOut.validateMinOut(amount0Min, amount1Min);
     }
 
     /// @notice Decreases liquidity from an existing position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amountToDecrease The amount of liquidity to remove
     /// @param amount0Min Minimum per-leg immediate non-fee LCC token0 after fee netting (`LiquidityUtils.forwardedNonFeeLccAmount`).
     ///        For commit positions, only the Hub-queued slice is custodied; surplus remains locker transient LCC credit.
     /// @param amount1Min Minimum per-leg immediate non-fee LCC token1 after fee netting (VTS queue principal remains `callerDelta - feesAccrued`).
     function _decrease(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 amountToDecrease,
         uint128 amount0Min,
         uint128 amount1Min
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         address qRec = _queueSettleRecipient(tokenId);
         _decreaseInternal(
             poolKey,
             position,
             PositionLibrary.generateSalt(tokenId, positionIndex),
             tokenId,
             amountToDecrease,
             PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender(), qRec),
             amount0Min,
             amount1Min
         );
     }
 
     /// @notice Internal helper to mint a new position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param liquidity The amount of liquidity to mint
     /// @return positionId The position ID
     /// @return positionIndex The position index within the commitment
     /// @return principalDelta Principal token deltas excluding informational fee accrual
     function _mintPositionInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity
     ) internal returns (PositionId positionId, uint256 positionIndex, BalanceDelta principalDelta) {
         uint256 nextPositionIndex;
         (,, nextPositionIndex,,) = vtsOrchestrator.getCommit(tokenId);
         address qRec = _queueSettleRecipient(tokenId);
         return _mintPositionInternal(
             poolKey,
             tokenId,
             tickLower,
             tickUpper,
             liquidity,
             PositionModificationHookDataLib.encode(tokenId, nextPositionIndex, msgSender(), qRec)
         );
     }
 
     function _mintPositionInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity,
         bytes memory hookData
     ) internal returns (PositionId positionId, uint256 positionIndex, BalanceDelta principalDelta) {
         if (liquidity > type(uint128).max) {
             revert Errors.InvalidAmount(liquidity, type(uint128).max);
         }
 
         (,, positionIndex,,) = vtsOrchestrator.getCommit(tokenId);
 
         ModifyLiquidityParams memory params = ModifyLiquidityParams({
             tickLower: tickLower,
             tickUpper: tickUpper,
             liquidityDelta: liquidity.toInt256(),
             salt: PositionLibrary.generateSalt(tokenId, positionIndex)
         });
 
         positionId = PositionLibrary.generateId(address(this), params);
         (BalanceDelta liquidityDelta, BalanceDelta feesAccrued,) =
             _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
         principalDelta = liquidityDelta - feesAccrued;
     }
 }
```

[High] Balance-wide ERC20 sync in MMPositionManager collect flow causes cross-locker fund theft

# Description

The new collect flow [credits ERC20 using a balance-wide sync](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L563) on the shared MMPositionManager instead of the exact released amount, allowing one locker to be credited with and withdraw other lockers’ ERC20 parked on the manager.

In the updated collect flow, after the custodian [releases underlying ERC20 to the MMPositionManager](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodian.sol#L106-L122), the locker is [credited via a balance-wide sync](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L563) rather than by the exact known amount just released. [The sync function credits the current locker up to the manager’s entire current token balance](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/OwnerCurrencyDelta.sol#L186-L193), without isolating per-locker funds. As MMPositionManager is a shared balance holder for ERC20, any ERC20 previously left on it (e.g., from prior operations or ERC20 self-takes) can be attributed to the current locker, who can then [withdraw it via TAKE](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L89-L98). [Native credits are handled correctly using exact-amount crediting](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L561), but ERC20 credits use the unsafe sync. The prior collect model did not route through MMPositionManager and therefore did not depend on balance-wide sync; [the new collect model introduced this vulnerability path](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L586-L588).

# Severity

**Impact Explanation:** [High] Direct, material loss of principal funds: an attacker can withdraw other lockers’ ERC20 parked on MMPositionManager or reduce their own debt using others’ tokens.

**Likelihood Explanation:** [Medium] Exploitation requires ERC20 balances to be present on MMPositionManager, which is a plausible and supported state (e.g., ERC20 self-take is allowed), but not guaranteed in every session.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Locker B calls collect; custodian [releases a small amount of ERC20 to MMPositionManager](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodian.sol#L106-L122); the credit step [uses a balance-wide sync](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L563) so B’s delta is increased up to the manager’s entire ERC20 balance (including funds parked by Locker A); B then calls TAKE to [withdraw all pooled ERC20 to their EOA](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L89-L98), stealing A’s tokens.
#### Preconditions / Assumptions
- (a). MMPositionManager holds ERC20 previously left by another locker (e.g., via ERC20 self-take to address(this) or prior positive settlement flows)
- (b). Attacker locker has a deployed queue custodian and a small collectible LCC amount that settles to ERC20
- (c). LiquidityHub has sufficient reserve for a small settlement

### Scenario 2.
Locker B has an ERC20 debt; collect triggers a small ERC20 release to MMPositionManager and the balance-wide sync reduces B’s debt by using ERC20 already held on the manager from other lockers; B later realizes value from their improved position while the rightful owners’ tokens are gone.
#### Preconditions / Assumptions
- (a). MMPositionManager holds ERC20 from other lockers’ prior operations
- (b). Attacker locker currently has a negative delta (debt) in the same ERC20
- (c). Attacker locker can trigger a collect event that releases a small amount of ERC20 to MMPositionManager

### Scenario 3.
The custodian already holds pre-settled underlying ERC20; collect phase 2 [releases it to MMPositionManager](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodian.sol#L106-L122) and the credit step [uses a balance-wide sync](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L563), attributing the entire manager-held ERC20 (including other lockers’ parked funds) to the current locker, who then TAKEs it out.
#### Preconditions / Assumptions
- (a). MMPositionManager holds ERC20 from other lockers
- (b). Attacker locker’s custodian already holds pre-settled underlying ERC20 attributable to their queue
- (c). Attacker locker calls collect to trigger underlying release and balance-wide sync

# Proposed fix

## MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol)

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
 
     /// @dev Deploys `MMQueueCustodian` for `recipient` when absent (`INITIALISE`, tests).
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
         if (action == MMActions.INITIALISE) {
             params.decodeInitialiseParams();
             _deployQueueCustodian(msgSender());
             return;
         }
         if (action == MMActions.COLLECT_AVAILABLE_LIQUIDITY) {
             (address lcc, uint256 maxAmount) = params.decodeCollectLiquidityParams();
             _collectAvailableLiquidity(lcc, maxAmount);
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
         MMHelpers.assertQueueCustodianForRecipient(beneficiary);
         address custAddr = custodianFor[beneficiary];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
         lccCurrency.transfer(custAddr, toUnwrap);
         custodian.unwrapLccViaHub(lccAddr, forwardUnderlyingTo, toUnwrap, liquidityHub);
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
 
     /// @notice Collects available queue liquidity for `msgSender()`’s custodian: settles the Hub queue when needed,
     ///         then releases underlying to this contract and credits the locker (withdraw via `TAKE`).
     /// @dev When the Hub queue was already cleared via permissionless `processSettlementFor`, releases from underlying
     ///      already held on the custodian (bounded per **HUB-02A** accounting).
     function _collectAvailableLiquidity(address lcc, uint256 maxAmount) internal {
         if (maxAmount == 0) return;
 
         address locker = msgSender();
         MMHelpers.assertQueueCustodianForRecipient(locker);
         address custAddr = custodianFor[locker];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         if (IMMQueueCustodian(custAddr).beneficiary() != locker) {
             revert Errors.InvalidSender();
         }
 
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
 
         uint256 remaining = _collectSettleHubQueueForCustodian(custodian, custAddr, lcc, maxAmount);
         _releasePreSettledCustodianUnderlying(custodian, custAddr, lcc, remaining);
     }
 
     /// @dev Credits the batch locker after underlying was pulled from the custodian onto this contract.
     function _creditLockerAfterCustodianUnderlyingRelease(address lcc, uint256 amount) private {
         if (amount == 0) return;
         address underlyingAddr = ILCC(lcc).underlying();
         if (underlyingAddr == address(0)) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
         } else {
-            _syncBalanceAsCredit(Currency.wrap(underlyingAddr));
+            _creditExact(Currency.wrap(underlyingAddr), amount);
         }
     }
 
     /// @dev Phase 1: settle live Hub queue where possible; returns `maxAmount` minus what was settled and released.
     function _collectSettleHubQueueForCustodian(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         uint256 maxAmount
     ) private returns (uint256 remaining) {
         uint256 hubQ = liquidityHub.settleQueue(lcc, custAddr);
         uint256 entitled = custodian.totalQueuedLcc(lcc);
         (, uint256 holderBal) = ILCC(lcc).balancesOf(custAddr);
         (, uint256 reserveMarket) = liquidityHub.reserveOfUnderlyingTuple(lcc);
 
         uint256 settleAmount = maxAmount;
         settleAmount = Math.min(settleAmount, hubQ);
         settleAmount = Math.min(settleAmount, entitled);
         settleAmount = Math.min(settleAmount, holderBal);
         settleAmount = Math.min(settleAmount, reserveMarket);
 
         if (settleAmount == 0) return maxAmount;
 
         liquidityHub.processSettlementFor(lcc, custAddr, settleAmount);
         custodian.releaseSettledUnderlyingToManager(lcc, settleAmount);
         _creditLockerAfterCustodianUnderlyingRelease(lcc, settleAmount);
         return maxAmount - settleAmount;
     }
 
     /// @dev Phase 2: underlying already on custodian after external Hub settlement.
     function _releasePreSettledCustodianUnderlying(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         uint256 remaining
     ) private {
         if (remaining == 0) return;
 
         uint256 entitled = custodian.totalQueuedLcc(lcc);
         if (entitled == 0) return;
 
         uint256 hubQLive = liquidityHub.settleQueue(lcc, custAddr);
         uint256 preSettledLcc = entitled > hubQLive ? entitled - hubQLive : 0;
 
         address underlyingAddr = ILCC(lcc).underlying();
         uint256 custodianUnderlyingBal =
             underlyingAddr == address(0) ? custAddr.balance : IERC20(underlyingAddr).balanceOf(custAddr);
 
         uint256 releaseAmount = remaining;
         releaseAmount = Math.min(releaseAmount, entitled);
         releaseAmount = Math.min(releaseAmount, preSettledLcc);
         releaseAmount = Math.min(releaseAmount, custodianUnderlyingBal);
 
         if (releaseAmount > 0) {
             custodian.releaseSettledUnderlyingToManager(lcc, releaseAmount);
             _creditLockerAfterCustodianUnderlyingRelease(lcc, releaseAmount);
         }
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

## [High] Beneficiary-scoped custody and token-agnostic collection in MM queue custody cause cross-owner pooling and drain by shared proxies

### Description

Queued principal is now attributed and recorded per-LCC under a single custodian keyed to the batch locker (beneficiary), and COLLECT_AVAILABLE_LIQUIDITY authorizes collection solely by that locker without tokenId or ERC721 ownership checks. If a shared operator/proxy executes decreases for multiple owners, all queued amounts pool under the proxy’s custodian and can later be collected and withdrawn by the proxy even after approvals are revoked or NFTs are transferred.

The MM queue custody model records queued LCC principal per LCC under custodianFor[locker] rather than per tokenId. In MMPositionActionsImpl, [_queueSettleRecipient returns custodianFor[msgSender()]](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L99-L105) and hook data encodes that as queueRecipient; _forwardQueuedLccToCustodian [transfers the queued amount to this custodian and calls IMMQueueCustodian.record(lcc, amount)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L116-L117). IMMQueueCustodian tracks only [mapping(address lcc => uint256)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodian.sol#L32) totalQueuedLcc, with no tokenId dimension. Collection is executed via MMPositionManager._collectAvailableLiquidity(lcc, maxAmount), which [only checks that IMMQueueCustodian.beneficiary() == msgSender()](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L543-L548) and [then settles and/or releases underlying to the manager, crediting the locker](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L586-L588), without any tokenId parameter or ERC721 approved-or-owner check. Approved operators can validly execute DECREASE_LIQUIDITY for multiple owners ([MMHelpers.assertApprovedOrOwner(msgSender(), tokenId)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L904)), causing all queued principal for a given LCC to be pooled under the operator’s (proxy’s) custodian. Later, the same proxy can call COLLECT_AVAILABLE_LIQUIDITY and drain the pooled entitlement, then withdraw via TAKE, even if user approvals were revoked or NFTs transferred. There is no path for individual owners to reclaim entitlements once pooled under another custodian.

### Severity

**Impact Explanation:** [High] Enables direct, material loss of users’ principal by allowing a shared proxy (or its controller) to collect and withdraw pooled queued principal owed from multiple users’ decreases.

**Likelihood Explanation:** [Medium] Exploitation depends on integrators using a shared operator/proxy as the batch locker rather than per-user wallets; this is a plausible and common pattern in DeFi but not universal.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
A shared operator/proxy is approved by multiple users and acts as the batch locker when calling DECREASE_LIQUIDITY on each user’s commitment. For each decrease, the Hub queue and custodied LCC are attributed to custodianFor[proxy] and recorded via IMMQueueCustodian.record. Later, when reserves are available, the proxy calls COLLECT_AVAILABLE_LIQUIDITY(lcc, maxAmount), which settles and/or releases underlying to the MMPositionManager and credits the proxy; the proxy then calls TAKE to withdraw the underlying to its own address, draining multiple users’ queued principal.
#### Preconditions / Assumptions
- (a). Active market and configured LiquidityHub/VTS/MMPositionManager
- (b). Multiple users with commitment NFTs and active positions in the same LCC market
- (c). A shared operator/proxy contract is set as an approved operator (setApprovalForAll) by those users
- (d). The proxy executes DECREASE_LIQUIDITY as the batch locker, causing queue attribution to custodianFor[proxy]
- (e). Reserves eventually become available to settle the queue

### Scenario 2.
After the proxy has pooled users’ queued principal under its custodian, the users revoke the proxy’s approvals or transfer/sell their NFTs. The entitlement remains under custodianFor[proxy]. Users cannot collect because their own custodians hold no entitlement for these decreases. At any later time, the proxy calls COLLECT_AVAILABLE_LIQUIDITY and TAKE to drain the pooled underlying, despite revocation or change of token ownership.
#### Preconditions / Assumptions
- (a). Existing pooled entitlement under custodianFor[proxy] created as in Scenario 1
- (b). Users revoke approvals or transfer NFTs after the decreases
- (c). Reserves become available allowing settlement
- (d). Proxy still controls its address and can call collection and withdrawal

### Scenario 3.
A widely used shared proxy accumulates substantial pooled entitlements by acting as batch locker for many users. The proxy’s control is later compromised. The attacker calls COLLECT_AVAILABLE_LIQUIDITY(lcc, maxAmount) across affected LCCs (authorized solely by beneficiary==proxy) and then TAKE to withdraw the underlying, draining many users’ pooled queued principal in bulk.
#### Preconditions / Assumptions
- (a). A widely used shared proxy has acted as the batch locker and accumulated pooled entitlements under its custodian
- (b). The proxy’s private key/control is compromised
- (c). Reserves become available to settle the queue
- (d). Attacker can invoke COLLECT_AVAILABLE_LIQUIDITY and TAKE from the compromised proxy address

### Proposed fix

#### MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol)

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
 
     /// @dev Deploys `MMQueueCustodian` for `recipient` when absent (`INITIALISE`, tests).
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
         if (action == MMActions.INITIALISE) {
             params.decodeInitialiseParams();
             _deployQueueCustodian(msgSender());
             return;
         }
         if (action == MMActions.COLLECT_AVAILABLE_LIQUIDITY) {
+            // TODO(security): Extend to accept (lcc, tokenId, maxAmount); for tokenId>0 require approved-or-owner and credit current NFT owner on collect.
             (address lcc, uint256 maxAmount) = params.decodeCollectLiquidityParams();
             _collectAvailableLiquidity(lcc, maxAmount);
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
         MMHelpers.assertQueueCustodianForRecipient(beneficiary);
         address custAddr = custodianFor[beneficiary];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
         lccCurrency.transfer(custAddr, toUnwrap);
         custodian.unwrapLccViaHub(lccAddr, forwardUnderlyingTo, toUnwrap, liquidityHub);
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
 
     /// @notice Collects available queue liquidity for `msgSender()`’s custodian: settles the Hub queue when needed,
     ///         then releases underlying to this contract and credits the locker (withdraw via `TAKE`).
     /// @dev When the Hub queue was already cleared via permissionless `processSettlementFor`, releases from underlying
+    // TODO(security): This is locker-scoped. For commit queues: use per-token custodian, accept tokenId, and credit the current NFT owner instead of the locker.
     ///      already held on the custodian (bounded per **HUB-02A** accounting).
     function _collectAvailableLiquidity(address lcc, uint256 maxAmount) internal {
         if (maxAmount == 0) return;
 
         address locker = msgSender();
         MMHelpers.assertQueueCustodianForRecipient(locker);
         address custAddr = custodianFor[locker];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         if (IMMQueueCustodian(custAddr).beneficiary() != locker) {
             revert Errors.InvalidSender();
         }
 
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
 
         uint256 remaining = _collectSettleHubQueueForCustodian(custodian, custAddr, lcc, maxAmount);
         _releasePreSettledCustodianUnderlying(custodian, custAddr, lcc, remaining);
     }
 
     /// @dev Credits the batch locker after underlying was pulled from the custodian onto this contract.
     function _creditLockerAfterCustodianUnderlyingRelease(address lcc, uint256 amount) private {
         if (amount == 0) return;
         address underlyingAddr = ILCC(lcc).underlying();
         if (underlyingAddr == address(0)) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
         } else {
             _syncBalanceAsCredit(Currency.wrap(underlyingAddr));
         }
     }
 
     /// @dev Phase 1: settle live Hub queue where possible; returns `maxAmount` minus what was settled and released.
     function _collectSettleHubQueueForCustodian(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         uint256 maxAmount
     ) private returns (uint256 remaining) {
         uint256 hubQ = liquidityHub.settleQueue(lcc, custAddr);
         uint256 entitled = custodian.totalQueuedLcc(lcc);
         (, uint256 holderBal) = ILCC(lcc).balancesOf(custAddr);
         (, uint256 reserveMarket) = liquidityHub.reserveOfUnderlyingTuple(lcc);
 
         uint256 settleAmount = maxAmount;
         settleAmount = Math.min(settleAmount, hubQ);
         settleAmount = Math.min(settleAmount, entitled);
         settleAmount = Math.min(settleAmount, holderBal);
         settleAmount = Math.min(settleAmount, reserveMarket);
 
         if (settleAmount == 0) return maxAmount;
 
         liquidityHub.processSettlementFor(lcc, custAddr, settleAmount);
         custodian.releaseSettledUnderlyingToManager(lcc, settleAmount);
         _creditLockerAfterCustodianUnderlyingRelease(lcc, settleAmount);
         return maxAmount - settleAmount;
     }
 
     /// @dev Phase 2: underlying already on custodian after external Hub settlement.
     function _releasePreSettledCustodianUnderlying(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         uint256 remaining
     ) private {
         if (remaining == 0) return;
 
         uint256 entitled = custodian.totalQueuedLcc(lcc);
         if (entitled == 0) return;
 
         uint256 hubQLive = liquidityHub.settleQueue(lcc, custAddr);
         uint256 preSettledLcc = entitled > hubQLive ? entitled - hubQLive : 0;
 
         address underlyingAddr = ILCC(lcc).underlying();
         uint256 custodianUnderlyingBal =
             underlyingAddr == address(0) ? custAddr.balance : IERC20(underlyingAddr).balanceOf(custAddr);
 
         uint256 releaseAmount = remaining;
         releaseAmount = Math.min(releaseAmount, entitled);
         releaseAmount = Math.min(releaseAmount, preSettledLcc);
         releaseAmount = Math.min(releaseAmount, custodianUnderlyingBal);
 
         if (releaseAmount > 0) {
             custodian.releaseSettledUnderlyingToManager(lcc, releaseAmount);
             _creditLockerAfterCustodianUnderlyingRelease(lcc, releaseAmount);
         }
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

#### MMCalldataDecoder.sol

File: `contracts/evm/src/libraries/MMCalldataDecoder.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/MMCalldataDecoder.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {CalldataDecoder} from "v4-periphery/src/libraries/CalldataDecoder.sol";
 
 /// @title Library for efficient calldata decoding in MMPositionManager
 /// @notice Reduces bytecode by replacing abi.decode with assembly-based decoding
 /// @dev Follows Uniswap v4 CalldataDecoder patterns for consistency
 library MMCalldataDecoder {
     using CalldataDecoder for bytes;
 
     error SliceOutOfBounds();
 
     /// @notice Mask used for offsets and lengths to ensure no overflow
     /// @dev No sane ABI encoding will pass in an offset or length greater than type(uint32).max
     uint256 constant OFFSET_OR_LENGTH_MASK = 0xffffffff;
 
     /// @notice Equivalent to SliceOutOfBounds.selector, stored in least-significant bits
     uint256 constant SLICE_ERROR_SELECTOR = 0x3b99b53d;
 
     // ═══════════════════════════════════════════════════════════════════════════════════════════
     // High Priority Decoders (Position Operations)
     // ═══════════════════════════════════════════════════════════════════════════════════════════
 
     /// @dev SETTLE_POSITION: (PoolKey, uint256, uint256, int128, int128, bool)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return amount0 The amount of token0 to settle
     /// @return amount1 The amount of token1 to settle
     /// @return usePositionManagerBalance If true, tokens flow via MMPM balance and locker's deltas are adjusted
     function decodeSettlePositionParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             uint256 positionIndex,
             int128 amount0,
             int128 amount1,
             bool usePositionManagerBalance
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amount0, amount1, usePositionManagerBalance
             // Minimum length: 0xa0 + 0x20*5 = 0x140
             if lt(params.length, 0x140) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             amount0 := calldataload(add(params.offset, 0xe0))
             amount1 := calldataload(add(params.offset, 0x100))
             usePositionManagerBalance := calldataload(add(params.offset, 0x120))
         }
     }
 
     /// @dev INCREASE_LIQUIDITY: (PoolKey, uint256, uint256, uint256)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return liquidity The amount of liquidity to add
     function decodeIncreaseLiquidityParams(bytes calldata params)
         internal
         pure
         returns (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint256 liquidity)
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, liquidity
             // Minimum length: 0xa0 + 0x20*3 = 0x100
             if lt(params.length, 0x100) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             liquidity := calldataload(add(params.offset, 0xe0))
         }
     }
 
     /// @dev MINT_POSITION: (PoolKey, uint256, int24, int24, uint256)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return tickLower The lower tick of the position
     /// @return tickUpper The upper tick of the position
     /// @return liquidity The amount of liquidity to mint
     function decodeMintPositionParams(bytes calldata params)
         internal
         pure
         returns (PoolKey calldata poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity)
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, tickLower, tickUpper, liquidity
             // Minimum length: 0xa0 + 0x20*4 = 0x120
             if lt(params.length, 0x120) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             tickLower := calldataload(add(params.offset, 0xc0))
             tickUpper := calldataload(add(params.offset, 0xe0))
             liquidity := calldataload(add(params.offset, 0x100))
         }
     }
 
     /// @dev DECREASE_LIQUIDITY: (PoolKey, uint256, uint256, uint256, uint128, uint128)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return amountToDecrease The amount of liquidity to remove
     /// @return amount0Min Minimum per-leg immediate non-fee LCC token0 out after fee netting (see `LiquidityUtils.forwardedNonFeeLccAmount`; commit surplus is locker credit)
     /// @return amount1Min Minimum immediate non-fee LCC token1 out
     function decodeDecreaseLiquidityParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             uint256 positionIndex,
             uint256 amountToDecrease,
             uint128 amount0Min,
             uint128 amount1Min
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amountToDecrease, amount0Min, amount1Min
             // Minimum length: 0xa0 + 0x20*5 = 0x140
             if lt(params.length, 0x140) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             amountToDecrease := calldataload(add(params.offset, 0xe0))
             amount0Min := calldataload(add(params.offset, 0x100))
             amount1Min := calldataload(add(params.offset, 0x120))
         }
     }
 
     /// @dev BURN_POSITION: (PoolKey, uint256, uint256, uint128, uint128)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return amount0Min Minimum per-leg immediate non-fee LCC token0 when burning (same semantics as decrease min-out)
     /// @return amount1Min Minimum immediate non-fee LCC token1 out
     function decodeBurnPositionParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             uint256 positionIndex,
             uint128 amount0Min,
             uint128 amount1Min
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amount0Min, amount1Min
             // Minimum length: 0xa0 + 0x20*4 = 0x120
             if lt(params.length, 0x120) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             amount0Min := calldataload(add(params.offset, 0xe0))
             amount1Min := calldataload(add(params.offset, 0x100))
         }
     }
 
     /// @dev SEIZE_POSITION: (PoolKey, uint256, uint256, uint256, uint256, bool)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return amount0 The amount of token0 for seizure
     /// @return amount1 The amount of token1 for seizure
     /// @return usePositionManagerBalance If true, tokens flow via MMPM balance and locker's deltas are adjusted
     function decodeSeizePositionParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             uint256 positionIndex,
             uint256 amount0,
             uint256 amount1,
             bool usePositionManagerBalance
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amount0, amount1, usePositionManagerBalance
             // Minimum length: 0xa0 + 0x20*5 = 0x140
             if lt(params.length, 0x140) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             amount0 := calldataload(add(params.offset, 0xe0))
             amount1 := calldataload(add(params.offset, 0x100))
             usePositionManagerBalance := calldataload(add(params.offset, 0x120))
         }
     }
 
     // ═══════════════════════════════════════════════════════════════════════════════════════════
     // Medium Priority Decoders (Delta Operations & Signal Management)
     // ═══════════════════════════════════════════════════════════════════════════════════════════
 
     /// @dev INCREASE_LIQUIDITY_FROM_DELTAS: (PoolKey, uint256, uint256, uint128, uint128, bool)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return amount0Max The maximum amount of token0 to spend
     /// @return amount1Max The maximum amount of token1 to spend
     /// @return payerIsUser If true, user consumes credit protocol owes them (MMPM delta).
     ///         If false, uses locker's direct credit.
     function decodeIncreaseFromDeltasParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             uint256 positionIndex,
             uint128 amount0Max,
             uint128 amount1Max,
             bool payerIsUser
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amount0Max, amount1Max, payerIsUser
             // Minimum length: 0xa0 + 0x20*5 = 0x140
             if lt(params.length, 0x140) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             amount0Max := calldataload(add(params.offset, 0xe0))
             amount1Max := calldataload(add(params.offset, 0x100))
             payerIsUser := calldataload(add(params.offset, 0x120))
         }
     }
 
     /// @dev MINT_POSITION_FROM_DELTAS: (PoolKey, uint256, int24, int24, uint128, uint128, bool)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return tickLower The lower tick of the position
     /// @return tickUpper The upper tick of the position
     /// @return amount0Max The maximum amount of token0 to spend
     /// @return amount1Max The maximum amount of token1 to spend
     /// @return payerIsUser If true, user consumes credit protocol owes them (MMPM delta).
     ///         If false, uses locker's direct credit.
     function decodeMintFromDeltasParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             int24 tickLower,
             int24 tickUpper,
             uint128 amount0Max,
             uint128 amount1Max,
             bool payerIsUser
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, tickLower, tickUpper, amount0Max, amount1Max, payerIsUser
             // Minimum length: 0xa0 + 0x20*6 = 0x160
             if lt(params.length, 0x160) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             tickLower := calldataload(add(params.offset, 0xc0))
             tickUpper := calldataload(add(params.offset, 0xe0))
             amount0Max := calldataload(add(params.offset, 0x100))
             amount1Max := calldataload(add(params.offset, 0x120))
             payerIsUser := calldataload(add(params.offset, 0x140))
         }
     }
 
     /// @dev SETTLE_POSITION_FROM_DELTAS: (PoolKey, uint256, uint256, bool, bool, bool)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return payerIsUser If true, use protocol delta (address(this)). If false, use locker delta (msgSender()).
     /// @return shouldTake If true, withdraw (consume credit). If false, deposit (settle credit into position).
     function decodeSettleFromDeltasParams(bytes calldata params)
         internal
         pure
         returns (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, bool payerIsUser, bool shouldTake)
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, payerIsUser, shouldTake
             // Minimum length: 0xa0 + 0x20*4 = 0x120
             if lt(params.length, 0x120) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             payerIsUser := calldataload(add(params.offset, 0xe0))
             shouldTake := calldataload(add(params.offset, 0x100))
         }
     }
 
     /// @dev DECOMMIT_SIGNAL: (uint256)
     /// @param params The calldata bytes to decode
     /// @return tokenId The commitment NFT token ID
     function decodeDecommitSignalParams(bytes calldata params) internal pure returns (uint256 tokenId) {
         assembly ("memory-safe") {
             // tokenId: 1 slot (0x20)
             // Minimum length: 0x20
             if lt(params.length, 0x20) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             tokenId := calldataload(params.offset)
         }
     }
 
     /// @dev EXTEND_GRACE_PERIOD: (PoolKey, uint256, uint256, uint8, uint32, bytes)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return settlementTokenIndex The index of the settlement token
     /// @return verifierIndex The verifier index
     /// @return settlementProof The settlement proof bytes
     function decodeExtendGracePeriodParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             uint256 positionIndex,
             uint8 settlementTokenIndex,
             uint32 verifierIndex,
             bytes calldata settlementProof
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId (0x20), positionIndex (0x20), settlementTokenIndex (0x20), verifierIndex (0x20)
             // settlementProof offset pointer is at 0x120 (after all fixed-size params)
             // Minimum length: 0x120 + 0x20 (offset pointer) + 0x20 (length) = 0x160
             if lt(params.length, 0x160) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             settlementTokenIndex := calldataload(add(params.offset, 0xe0))
             verifierIndex := calldataload(add(params.offset, 0x100))
 
             // Read the offset pointer for settlementProof (dynamic bytes, index 5)
             // The offset pointer is stored at params.offset + 0x120 (after all fixed-size params)
             let proofOffsetPtr := add(params.offset, 0x120)
             let proofDataOffset := add(params.offset, and(calldataload(proofOffsetPtr), OFFSET_OR_LENGTH_MASK))
 
             // Read the length of the bytes
             let proofLength := and(calldataload(proofDataOffset), OFFSET_OR_LENGTH_MASK)
 
             // Set settlementProof calldata slice
             settlementProof.offset := add(proofDataOffset, 0x20)
             settlementProof.length := proofLength
 
             // Verify the bytes string fits within params
             if lt(add(params.length, params.offset), add(settlementProof.length, settlementProof.offset)) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
         }
     }
 
     /// @dev COMMIT_SIGNAL: (bytes liquiditySignal, bytes relayParams)
     /// @param params The calldata bytes to decode
     /// @return liquiditySignal The liquidity signal bytes
     /// @return relayParams Optional relayer auth params encoded as
     ///         `(uint256 deadline, uint256 authNonce, bytes authSig, address sender)`.
     ///         When non-empty, EIP-712 `RelayAuth.sender` is supplied as `sender` (`address(0)` means mint to
     ///         `mmState.owner`; otherwise must equal the batch locker / NFT recipient) while VRL `signer` remains
     ///         `mmState.owner`.
     function decodeCommitSignalParams(bytes calldata params)
         internal
         pure
         returns (bytes calldata liquiditySignal, bytes calldata relayParams)
     {
         assembly ("memory-safe") {
             // ABI encoding: (bytes liquiditySignal, bytes relayParams)
             // Minimum length for empty bytes fields:
             // - head (2 words): offset, offset => 0x40
             // - tails (2 length words)                => 0x40
             // total                               => 0x80
             if lt(params.length, 0x80) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
         }
         // Use CalldataDecoder.toBytes for dynamic bytes (index 0 = 1st argument)
         liquiditySignal = params.toBytes(0);
         relayParams = params.toBytes(1);
     }
 
     /// @dev RENEW_SIGNAL: (uint256, bytes, bytes relayParams)
     /// @param params The calldata bytes to decode
     /// @return tokenId The commitment NFT token ID
     /// @return data The liquidity signal bytes
     /// @return relayParams Optional relayer auth params encoded as
     ///         `(uint256 deadline, uint256 authNonce, bytes authSig, address sender)` (renew: typed-data
     ///         `RelayAuth.sender` must be `address(0)`).
     function decodeTokenIdAndBytes(bytes calldata params)
         internal
         pure
         returns (uint256 tokenId, bytes calldata data, bytes calldata relayParams)
     {
         assembly ("memory-safe") {
             // ABI encoding: (uint256 tokenId, bytes data, bytes relayParams)
             // Minimum length for empty bytes fields:
             // - head (3 words): tokenId, offset, offset => 0x60
             // - tails (2 length words)                  => 0x40
             // total                                      => 0xa0
             if lt(params.length, 0xa0) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             tokenId := calldataload(params.offset)
         }
         // Use CalldataDecoder.toBytes for dynamic bytes (index 1 = 2nd argument)
         data = params.toBytes(1);
         relayParams = params.toBytes(2);
     }
 
     /// @dev CHECKPOINT: (uint256, uint256, bool)
     /// @param params The calldata bytes to decode
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The index of the position within the commitment
     /// @return withCommitment Whether to run commitment backing checks
     function decodeCheckpointParams(bytes calldata params)
         internal
         pure
         returns (uint256 tokenId, uint256 positionIndex, bool withCommitment)
     {
         assembly ("memory-safe") {
             // ABI encoding: (uint256 tokenId, uint256 positionIndex, bool withCommitment)
             // Minimum length: 3 words = 0x60
             if lt(params.length, 0x60) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             tokenId := calldataload(params.offset)
             positionIndex := calldataload(add(params.offset, 0x20))
             // Head layout: tokenId @ 0x00, positionIndex @ 0x20, withCommitment @ 0x40
             withCommitment := calldataload(add(params.offset, 0x40))
         }
     }
 
     // ═══════════════════════════════════════════════════════════════════════════════════════════
     // Low Priority Decoders (Simple Types)
     // ═══════════════════════════════════════════════════════════════════════════════════════════
 
     /// @dev UNWRAP_LCC: (address, uint256, address, bool)
     /// @param params The calldata bytes to decode
     /// @return lccAddr The LCC token address
     /// @return amount The amount to unwrap
     /// @return recipient The recipient address
     /// @return payerIsUser Whether the payer is the user
     function decodeUnwrapLccParams(bytes calldata params)
         internal
         pure
         returns (address lccAddr, uint256 amount, address recipient, bool payerIsUser)
     {
         assembly ("memory-safe") {
             if lt(params.length, 0x80) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             lccAddr := calldataload(params.offset)
             amount := calldataload(add(params.offset, 0x20))
             recipient := calldataload(add(params.offset, 0x40))
             payerIsUser := calldataload(add(params.offset, 0x60))
         }
     }
 
     /// @dev COLLECT_AVAILABLE_LIQUIDITY: `(address lcc, uint256 maxAmount)` — **0x40** bytes; locker’s custodian scope.
     /// @param params The calldata bytes to decode
     /// @return lcc The LCC token address
+    // TODO(security): Extend to also accept `(address lcc, uint256 tokenId, uint256 maxAmount)` for commit-bucket collection.
     /// @return maxAmount The maximum amount to collect
     function decodeCollectLiquidityParams(bytes calldata params)
         internal
         pure
         returns (address lcc, uint256 maxAmount)
     {
         if (params.length != 0x40) {
             revert SliceOutOfBounds();
         }
         assembly ("memory-safe") {
             lcc := calldataload(params.offset)
             maxAmount := calldataload(add(params.offset, 0x20))
         }
     }
 
     /// @dev INITIALISE: no calldata words (must be exactly empty).
     function decodeInitialiseParams(bytes calldata params) internal pure {
         if (params.length != 0) {
             revert SliceOutOfBounds();
         }
     }
 
     /// @dev UNWRAP_NATIVE: (uint256, bool)
     /// @param params The calldata bytes to decode
     /// @return amount The amount to unwrap
     /// @return payerIsUser Whether the payer is the user
     function decodeUint256AndBool(bytes calldata params) internal pure returns (uint256 amount, bool payerIsUser) {
         assembly ("memory-safe") {
             if lt(params.length, 0x40) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             amount := calldataload(params.offset)
             payerIsUser := calldataload(add(params.offset, 0x20))
         }
     }
 
     /// @dev TAKE: (Currency, address, uint256)
     /// @notice Reuses Uniswap's decodeCurrencyAddressAndUint256 pattern
     /// @param params The calldata bytes to decode
     /// @return currency The currency to take
     /// @return recipient The recipient address
     /// @return maxAmount The maximum amount to take
     function decodeTakeParams(bytes calldata params)
         internal
         pure
         returns (Currency currency, address recipient, uint256 maxAmount)
     {
         assembly ("memory-safe") {
             if lt(params.length, 0x60) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             currency := calldataload(params.offset)
             recipient := calldataload(add(params.offset, 0x20))
             maxAmount := calldataload(add(params.offset, 0x40))
         }
     }
 
     /// @dev WRAP_NATIVE: (uint256)
     /// @notice Reuses Uniswap's decodeUint256 pattern
     /// @param params The calldata bytes to decode
     /// @return amount The amount to wrap
     function decodeUint256(bytes calldata params) internal pure returns (uint256 amount) {
         assembly ("memory-safe") {
             if lt(params.length, 0x20) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             amount := calldataload(params.offset)
         }
     }
 
     /// @dev SYNC: (Currency)
     /// @param params The calldata bytes to decode
     /// @return currency The currency to sync
     /// @dev owner is always address(this) (MMPM) and target is always msgSender() (locker)
     function decodeSyncParams(bytes calldata params) internal pure returns (Currency currency) {
         assembly ("memory-safe") {
             if lt(params.length, 0x20) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             currency := calldataload(params.offset)
         }
     }
 }
```

#### MMQueueCustodian.sol

File: `contracts/evm/src/MMQueueCustodian.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodian.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 import {Errors} from "./libraries/Errors.sol";
 
 /// @dev Minimal view for `weth9()` on the LCC’s canonical Hub (same as `LiquidityHubLib.transferUnderlying`).
 interface ILiquidityHubWeth9 {
     function weth9() external view returns (address);
 }
 
 /// @title MMQueueCustodian
+/// @notice NOTE: Per-beneficiary/global-per-LCC custody; commit-bucket isolation requires a token-scoped custodian variant.
 /// @notice One queue custodian per beneficiary: Hub queue owner for that MM domain; custodied principal is global per `lcc`.
 /// @dev `COLLECT_AVAILABLE_LIQUIDITY` settles when needed, then `releaseSettledUnderlyingToManager` credits the locker
 ///      through `MMPositionManager` pull flows (`TAKE`), not direct beneficiary push payout from this contract.
 contract MMQueueCustodian is IMMQueueCustodian {
     /// @notice Custody increased (MM-backed LCC staged for later Hub settlement).
     event CustodyRecorded(address indexed lcc, uint256 amount);
 
     /// @notice Underlying released to the position manager after Hub settlement burned custodied LCC against this contract.
     event UnderlyingReleasedToManager(address indexed lcc, uint256 amount);
 
     address public immutable override positionManager;
     address public immutable override beneficiary;
 
     /// @dev Per-`lcc` custodied LCC balance (LCC units), decremented only via `releaseSettledUnderlyingToManager`.
     mapping(address lcc => uint256) private _queuedLcc;
 
     modifier onlyPositionManager() {
         if (msg.sender != positionManager) revert Errors.InvalidSender();
         _;
     }
 
     /// @dev Accept native underlying from `LiquidityHub` settlement for native-backed LCC markets.
     receive() external payable {}
 
     constructor(address _positionManager, address _beneficiary) {
         if (_positionManager == address(0) || _positionManager.code.length == 0) {
             revert Errors.InvalidAddress(_positionManager);
         }
         if (_beneficiary == address(0)) revert Errors.InvalidAddress(_beneficiary);
         positionManager = _positionManager;
         beneficiary = _beneficiary;
     }
 
     /// @inheritdoc IMMQueueCustodian
     function record(address lcc, uint256 amount) external override onlyPositionManager {
         _record(lcc, amount);
     }
 
     function _record(address lcc, uint256 amount) private {
         if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
         if (amount == 0) return;
         _queuedLcc[lcc] += amount;
         emit CustodyRecorded(lcc, amount);
     }
 
     /// @inheritdoc IMMQueueCustodian
     function totalQueuedLcc(address lcc) external view override returns (uint256) {
         return _queuedLcc[lcc];
     }
 
     /// @notice Hub `unwrap` as this contract: shortfall queues to `address(this)`; immediate underlying is forwarded to `forwardUnderlyingTo`.
     /// @dev `MMPM` must transfer `amount` LCC to this contract before calling. Native: forward to MMPM (`positionManager`) for delta credit; ERC20: forward per MM routing (`to` or MMPM).
     function unwrapLccViaHub(address lcc, address forwardUnderlyingTo, uint256 amount, ILiquidityHub hub)
         external
         onlyPositionManager
     {
         if (amount == 0) return;
         if (forwardUnderlyingTo == address(0)) revert Errors.InvalidAddress(forwardUnderlyingTo);
 
         address underlying = ILCC(lcc).underlying();
         uint256 uBalBefore =
             underlying == address(0) ? address(this).balance : IERC20(underlying).balanceOf(address(this));
 
         uint256 qBefore = hub.settleQueue(lcc, address(this));
         hub.unwrap(lcc, amount);
         uint256 queuedDelta = hub.settleQueue(lcc, address(this)) - qBefore;
 
         uint256 uBalAfter =
             underlying == address(0) ? address(this).balance : IERC20(underlying).balanceOf(address(this));
         uint256 immediateReceived = uBalAfter - uBalBefore;
 
         if (queuedDelta > 0) {
             uint256 bal = IERC20(lcc).balanceOf(address(this));
             if (bal < queuedDelta) revert Errors.InsufficientBalance(bal, queuedDelta);
             _record(lcc, queuedDelta);
         }
 
         if (immediateReceived > 0) {
             if (underlying == address(0)) {
                 _payNativeWithWethFallback(forwardUnderlyingTo, immediateReceived, lcc);
             } else {
                 Currency.wrap(underlying).transfer(forwardUnderlyingTo, immediateReceived);
             }
         }
     }
 
     /// @inheritdoc IMMQueueCustodian
     function releaseSettledUnderlyingToManager(address lcc, uint256 amount) external override onlyPositionManager {
         if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
         if (amount == 0) return;
 
         uint256 q = _queuedLcc[lcc];
         if (amount > q) revert Errors.InsufficientBalance(q, amount);
         _queuedLcc[lcc] = q - amount;
 
         address underlying = ILCC(lcc).underlying();
         address to = positionManager;
         if (underlying == address(0)) {
             _payNativeWithWethFallback(to, amount, lcc);
         } else {
             Currency.wrap(underlying).transfer(to, amount);
         }
         emit UnderlyingReleasedToManager(lcc, amount);
     }
 
     /// @dev Matches Hub native settlement liveness: direct ETH first, then wrap via canonical Hub `weth9` and transfer ERC20 WETH.
     function _payNativeWithWethFallback(address to, uint256 amount, address lcc) private {
         (bool ok,) = to.call{value: amount}("");
         if (ok) return;
 
         address wrappedNative = ILiquidityHubWeth9(ILCC(lcc).hub()).weth9();
         if (wrappedNative == address(0)) revert Errors.InvalidAddress(wrappedNative);
 
         IWETH9(wrappedNative).deposit{value: amount}();
         Currency.wrap(wrappedNative).transfer(to, amount);
     }
 }
```

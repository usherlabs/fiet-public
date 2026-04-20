[Medium] Native TAKE to WETH9 in PositionManagerEntrypoint allows WETH minting to router, enabling cross-user fund capture

# Description

The [TAKE utility path](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L74-L97) permits native ETH to be sent to WETH9, which mints WETH to the MMPositionManager (router) instead of the intended recipient or the locker. No automatic WETH credit is created for the locker, leaving WETH on the router that can later be SYNCed and TAKEn by any locker, causing cross-user value loss.

In [PositionManagerEntrypoint._take](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L74-L97), native self-take (to address(this)) is forbidden, but native transfers to arbitrary addresses (including WETH9) are allowed. When a locker calls TAKE with currency == ADDRESS_ZERO and to == address(WETH9), [CurrencyLibrary.transfer](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/lib/v4-periphery/lib/v4-core/src/types/Currency.sol#L23-L53) sends ETH to WETH9, whose payable receive mints WETH to msg.sender (the MMPositionManager), not to the locker or the specified recipient. Unlike the [WRAP_NATIVE path](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/MMPositionManager.sol#L584-L604), no _syncBalanceAsCredit(weth) occurs afterward, so no WETH credit is established for the initiating locker. The resulting WETH remains on the router and can be claimed later by any locker via [SYNC(WETH)](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/MMPositionManager.sol#L552-L568) (which credits the caller’s delta up to the router’s WETH balance) followed by TAKE(WETH) to themselves. This enables cross-user value capture whenever a victim misuses TAKE(native→WETH9) or omits a required SYNC before attempting to TAKE(WETH).

# Severity

**Impact Explanation:** [High] Direct, material loss of principal funds: a victim’s ETH delta is consumed while the resulting WETH is later withdrawn by another user.

**Likelihood Explanation:** [Low] Exploitation depends on a victim mistake (using TAKE(native→WETH9) instead of WRAP_NATIVE, or omitting SYNC before TAKE(WETH)) and on the victim not immediately salvaging the WETH within the same batch.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Victim unwraps native-backed LCC to ETH (credited to their native delta), then calls TAKE(ETH, to=WETH9). WETH is minted to MMPositionManager without credit to the victim. Later, an attacker locks a batch, calls SYNC(WETH) to credit themselves and TAKE(WETH) to withdraw the stranded WETH.
#### Preconditions / Assumptions
- (a). Canonical WETH9 with payable receive() that mints to msg.sender
- (b). MMPositionManager is a bound endpoint in the market factory namespace
- (c). LiquidityHub may send ETH to MMPositionManager (per [FietNativeWrapper.receive](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/modules/NativeWrapper.sol#L56-L59))
- (d). Victim has positive native delta (e.g., from UNWRAP_LCC)
- (e). Victim uses TAKE(ETH, to=WETH9) instead of WRAP_NATIVE and does not immediately SYNC+TAKE WETH
- (f). Attacker later becomes the locker and can execute SYNC and TAKE

### Scenario 2.
Victim funds the batch with msg.value and is credited native delta in [_beforeBatch](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L36-L53). The victim then calls TAKE(ETH, to=WETH9), minting WETH to MMPositionManager without locker credit. Attacker later SYNCs WETH to their own delta and TAKES it out.
#### Preconditions / Assumptions
- (a). Victim initiates a payable batch (msg.value > 0), causing _beforeBatch to credit native delta
- (b). MMPositionManager is bound in the factory namespace
- (c). WETH9 has standard payable receive() minting to msg.sender
- (d). Victim uses TAKE(ETH, to=WETH9) and does not SYNC+TAKE WETH in the same batch
- (e). Attacker later becomes the locker and can execute SYNC and TAKE

### Scenario 3.
Victim calls TAKE(ETH, to=WETH9) and then attempts to TAKE(WETH, to=victim) without prior SYNC(WETH), resulting in 0 take and leaving WETH on MMPositionManager. A later attacker SYNCs and TAKES the WETH.
#### Preconditions / Assumptions
- (a). WETH9 is canonical with payable receive minting to msg.sender
- (b). MMPositionManager is bound in the factory namespace
- (c). Victim uses TAKE(ETH, to=WETH9), then attempts TAKE(WETH) without prior SYNC(WETH)
- (d). Attacker later becomes the locker and can execute SYNC and TAKE

# Proposed fix

## MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/MMPositionManager.sol)

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
+            // Disallow native TAKE to WETH9: this would mint WETH to MMPM (msg.sender at WETH9)
+            // without crediting the locker, leaving WETH stranded and later claimable via SYNC.
+            if (currency == CurrencyLibrary.ADDRESS_ZERO && to == address(WETH9)) {
+                revert Errors.NotApproved(to);
+            }
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

# Related findings

## [Medium] Unauthenticated take and debit-before-transfer in MMPositionManager native TAKE flow causes permanent stranding of native ETH

### Description

VTSOrchestrator exposes a [public, unauthenticated take()](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/modules/VTSCurrencyDelta.sol#L65-L67) that mutates transient deltas. MMPositionManager’s native TAKE [debits the locker’s credit](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L91) before performing an [external ETH transfer](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L94). A malicious recipient’s fallback can reenter and call orchestrator.take(ADDRESS_ZERO, locker, 0) to burn remaining native credit without moving ETH, leaving the corresponding ETH stuck on MMPositionManager. End-of-batch checks don’t prevent this, and there is no native SYNC or native self-take path to recover.

In PositionManagerEntrypoint._take, the router first debits the active locker’s credit via [vtsOrchestrator.take(currency, locker, trueMaxAmount)](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L91) and then [transfers ETH to the recipient](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L94) using CurrencyLibrary.transfer, which [forwards all gas](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/lib/v4-periphery/lib/v4-core/src/types/Currency.sol#L48). [VTSCurrencyDelta.take](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/modules/VTSCurrencyDelta.sol#L65-L67) (on VTSOrchestrator) is public and unauthenticated and directly nets deltas via [OwnerCurrencyDelta.take](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/OwnerCurrencyDelta.sol#L105-L116). A malicious recipient of a native TAKE can reenter during its fallback, discover the active locker with [MMPositionManager.msgSender()](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/MMPositionManager.sol#L150-L152), and call VTSOrchestrator.take(ADDRESS_ZERO, locker, 0) to consume the locker’s remaining same-batch native credit without moving any ETH. Any subsequent TAKEs in the batch then see zero credit and transfer nothing, while the ETH remains on MMPositionManager. PositionManagerEntrypoint._afterBatch [only checks that transient deltas are zero and snapshots balance](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L63-L67); there is no enforcement tying native balance to deltas. MMPositionManager._sync disallows native, and native self-take to address(this) is forbidden, so the stranded ETH cannot be recovered by the user.

### Severity

**Impact Explanation:** [High] Native ETH can be permanently stranded on MMPositionManager with no recovery path for users (no native SYNC and native self-take forbidden), constituting a loss of principal.

**Likelihood Explanation:** [Low] Exploitation requires the victim to direct a native TAKE to an attacker-controlled contract and typically perform a partial withdrawal, and the attacker’s fallback must execute a specific reentrant call; the vector is primarily griefing with limited attacker profit.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Victim sends a payable batch to MMPositionManager (crediting native via _beforeBatch) and performs TAKE(native) to an attacker contract. The attacker’s fallback reenters VTSOrchestrator.take(ADDRESS_ZERO, locker, 0) to burn remaining credit; the next TAKE returns 0 and the remaining ETH stays stranded on MMPositionManager.
#### Preconditions / Assumptions
- (a). Attacker controls a contract with a payable fallback that calls VTSOrchestrator.take(ADDRESS_ZERO, locker, 0).
- (b). Victim runs a payable batch on MMPositionManager, crediting native ETH via _beforeBatch.
- (c). Victim executes TAKE(native, to=attacker contract) with maxAmount less than full available credit, leaving remaining native credit.
- (d). VTSCurrencyDelta.take is public and unauthenticated; CurrencyLibrary.transfer forwards all gas enabling fallback reentrancy.
- (e). Locker identity is retrievable via MMPositionManager.msgSender() during fallback.
- (f). No native SYNC exists and native self-take to address(this) is forbidden.

### Scenario 2.
Victim unwraps native-backed LCC from deltas, which pays ETH to MMPositionManager and credits native to the locker. The victim then TAKEs(native) to an attacker contract; its fallback burns remaining native credit, stranding ETH on MMPositionManager.
#### Preconditions / Assumptions
- (a). Victim unwraps native-backed LCC from deltas, causing LiquidityHub to pay ETH to MMPositionManager and credit native to the locker.
- (b). Victim executes TAKE(native, to=attacker contract) with maxAmount less than full available credit.
- (c). VTSCurrencyDelta.take is public and unauthenticated; native transfer forwards all gas enabling fallback reentrancy.
- (d). Locker identity is retrievable via MMPositionManager.msgSender() during fallback.
- (e). No native SYNC exists and native self-take to address(this) is forbidden.

### Scenario 3.
A settlement outflow using usePositionManagerBalance=true results in native ETH paid to MMPositionManager and native credit to the locker. The victim then TAKEs(native) to an attacker contract; its fallback burns the remaining native credit, leaving ETH stranded on MMPositionManager.
#### Preconditions / Assumptions
- (a). A settlement outflow using usePositionManagerBalance=true pays native ETH to MMPositionManager and credits native to the locker.
- (b). Victim executes TAKE(native, to=attacker contract), typically partial.
- (c). VTSCurrencyDelta.take is public and unauthenticated; native transfer forwards all gas enabling fallback reentrancy.
- (d). Locker identity is retrievable via MMPositionManager.msgSender() during fallback.
- (e). No native SYNC exists and native self-take to address(this) is forbidden.

### Proposed fix

#### PositionManagerEntrypoint.sol

File: `contracts/evm/src/modules/PositionManagerEntrypoint.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/modules/PositionManagerEntrypoint.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
 import {TransientSlots} from "../libraries/TransientSlots.sol";
 import {PositionManagerBase} from "./PositionManagerBase.sol";
 import {Errors} from "../libraries/Errors.sol";
 
 /**
  * @title PositionManagerEntrypoint
  * @notice Base contract providing entrypoint-specific functionality
  * @dev Contains functions used only by MMPositionManager (entrypoint)
  */
 abstract contract PositionManagerEntrypoint is PositionManagerBase {
     address public immutable actionsImpl;
 
     constructor(address _marketFactory, address _vtsOrchestrator, address _canonicalCustody, address _actionsImpl)
         PositionManagerBase(_marketFactory, _vtsOrchestrator, _canonicalCustody)
     {
         if (_actionsImpl == address(0) || _actionsImpl.code.length == 0) {
             revert Errors.InvalidAddress(_actionsImpl);
         }
         actionsImpl = _actionsImpl;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Delegation Helpers
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @dev Delegates a call to the implementation contract
     function _delegateToImpl(bytes memory data) internal {
         // OZ Address helper verifies target is a contract and bubbles revert reasons.
         Address.functionDelegateCall(actionsImpl, data);
     }
 
     // ------------------------------------------------------------------------------------------------
     // Batch Hooks
     // ------------------------------------------------------------------------------------------------
 
     /// @notice Hook called before batch execution
     /// @dev Credits native ETH to the locker delta using **balance-delta** accounting for the batch:
     ///      - First batch in the tx: baseline `lastSeen = balance - msg.value` so only this call's `msg.value` is
     ///        treated as new inflow (ambient ETH already on the router is not credited).
     ///      - Later batches: `fresh = balance - lastSeen`; credit `min(msg.value, fresh)` so:
     ///        - `Multicall_v4` inner `delegatecall`s share one outer `msg.value` and do not increase balance between
     ///          batches → second inner batch gets `fresh == 0` (fixes duplicate credit if we cleared a boolean per batch).
     ///        - Distinct payable top-level calls each add ETH → `fresh` matches the new wei and each call is credited once.
     ///      `_afterBatch` snapshots `address(this).balance` into transient storage for the rest of the transaction.
     function _beforeBatch() internal {
         uint256 amount = TransientSlots.nativeEthCreditAmountForBatch(address(this).balance, msg.value);
         if (amount > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
         }
     }
 
     /// @notice Hook called after batch execution
     /// @dev Clears batch-scoped seizure context, asserts deltas net to zero, then records native balance for the next
     ///      `_beforeBatch` in the same transaction (multicall-safe, multi-entrypoint-safe).
     function _afterBatch() internal {
         TransientSlots.clearSeizedPositionId();
         // Owner-scoped and market-scoped transient namespaces both resolve through the orchestrator boundary.
         vtsOrchestrator.assertNonZeroDeltas(marketFactory);
         TransientSlots.setNativeLastSeenBalance(address(this).balance);
     }
 
     // ------------------------------------------------------------------------------------------------
     // MM Utility Helpers
     // ------------------------------------------------------------------------------------------------
 
     /// @notice Takes currency from delta and transfers to recipient
     /// @dev Unified flow for both LCC and underlying currencies:
     ///      - Balance held as ERC20 by MMPM
     ///      - Delta on locker (LCC fees synced via _syncBalanceAsCredit after position modification)
     ///      - Flow: debit locker delta -> direct ERC20 transfer
     /// @param currency The currency to take
     /// @param to The recipient address
     /// @param maxAmount The maximum amount to take (0 = take full available credit)
     /// @dev Native `TAKE` to `address(this)` is disallowed: it would debit the locker's delta without moving ETH,
     ///      stranding balance on MMPM with no native `SYNC` path (see `INVARIANTS.md` DELTA-02 / audit finding on
     ///      native self-take). ERC20 self-take remains valid and recoverable via `SYNC`.
     function _take(Currency currency, address to, uint256 maxAmount) internal {
         if (currency == CurrencyLibrary.ADDRESS_ZERO && to == address(this)) {
             revert Errors.InvalidAddress(to);
         }
+        // Disallow native TAKE to contract recipients: prevents fallback reentrancy from burning remaining
+        // same-batch native credit and stranding ETH on MMPM (no native SYNC path).
+        if (currency == CurrencyLibrary.ADDRESS_ZERO && to.code.length > 0) {
+            revert Errors.NotApproved(to);
+        }
+
         address locker = msgSender();
         uint256 bal = currency.balanceOfSelf();
         // maxAmount == 0 means "take full available credit", but still cap to the actual ERC20 balance held by MMPM.
         uint256 trueMaxAmount = (maxAmount == 0) ? bal : Math.min(maxAmount, bal);
         uint256 takeAmount = vtsOrchestrator.take(currency, locker, trueMaxAmount);
 
         if (to != address(this)) {
             currency.transfer(to, takeAmount);
         }
     }
 }
```

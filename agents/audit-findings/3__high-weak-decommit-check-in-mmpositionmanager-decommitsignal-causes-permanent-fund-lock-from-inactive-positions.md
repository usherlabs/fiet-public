[High] Weak decommit check in MMPositionManager._decommitSignal causes permanent fund lock from inactive positions

# Description

[Burning the commitment NFT when no active positions remain](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionManager.sol#L290-L309) can strand withdrawable value left in inactive positions, because [all settlement/withdraw paths require NFT-based authorisation](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionActionsImpl.sol#L468-L476) which fails after burn.

[MMPositionManager._decommitSignal burns the NFT as soon as activePositionCount == 0](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionManager.sol#L290-L309), without checking whether inactive positions still hold withdrawable value (pa.settled) in VTS. [VTS explicitly supports later interactions with inactive positions](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/VTSOrchestrator.sol#L316-L323), and [residual value can remain after final decreases when vault settleability is limited and the removable principal is insufficient to fully queue the shortfall](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSPositionLib.sol#L1588-L1600). After burn, [all settlement/withdraw actions in MMPositionActionsImpl (e.g., _settle, settle-from-deltas) enforce assertApprovedOrOwner](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionActionsImpl.sol#L468-L476), [which calls ownerOf(tokenId) and reverts for a burned token](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/MMHelpers.sol#L14-L21). [Queue collection remains possible but only for the previously queued slice](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionManager.sol#L450-L469), not for the non-queued remainder in pa.settled. As a result, users who decommit after deactivation but before withdrawing inactive-position remainders can permanently lose access to those funds.

# Severity

**Impact Explanation:** [High] Funds are frozen without any on-chain workaround after NFT burn because all withdrawal paths require NFT-based authorisation, leading to permanent loss of user principal.

**Likelihood Explanation:** [Medium] Requires plausible but not universal conditions: vault shortfall at time of decrease, removable principal insufficient to fully queue shortfall, and a user decommitting upon seeing no active positions. These states are realistic in stressed or ordinary markets.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
User fully deactivates their position(s); due to limited vault settleability and capped principal removed, a remainder stays in pa.settled. Seeing no active positions (activePositionCount == 0), the user calls DECOMMIT_SIGNAL and [burns the NFT](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionManager.sol#L290-L309). Later attempts to withdraw the remainder fail because [settlement functions require NFT ownership](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionActionsImpl.sol#L468-L476) and ownerOf(tokenId) reverts for a burned token. [Only the queued portion (if any) can be collected](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionManager.sol#L450-L469); the remainder is permanently stuck.
#### Preconditions / Assumptions
- (a). Commitment NFT exists with positions now inactive (activePositionCount == 0).
- (b). Final decreases left a non-queued remainder in pa.settled due to vault shortfall > removable principal.
- (c). User calls DECOMMIT_SIGNAL (burns NFT) before withdrawing the remainder from inactive positions.

### Scenario 2.
A position has accumulated a large pa.settled over time. On the final decrease to zero liquidity, removable principal is minimal and vault settleability is low, leaving most of requiredSettlementDelta in pa.settled. The user decommits ([burns the NFT](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionManager.sol#L290-L309)). Subsequent withdrawal attempts revert due to [missing NFT ownership](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionActionsImpl.sol#L468-L476), permanently stranding a large remainder.
#### Preconditions / Assumptions
- (a). Position accumulated significant pa.settled before final decrease.
- (b). Removable principal at deactivation is small and vault settleability is low, so most remainder stays in pa.settled.
- (c). User calls DECOMMIT_SIGNAL (burns NFT) before withdrawing the remainder.

### Scenario 3.
A multi-position commitment ends with all positions inactive. Some positions retain non-queued remainders in pa.settled after their final decreases. The user decommits early ([burns the NFT](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionManager.sol#L290-L309)) because activePositionCount == 0. They can collect only the [queued slices](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionManager.sol#L450-L469); all non-queued remainders across positions are permanently stuck because [settle/withdraw paths require the NFT](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionActionsImpl.sol#L468-L476).
#### Preconditions / Assumptions
- (a). Multiple positions under the same commit; all are inactive.
- (b). At least one position retains a non-queued remainder in pa.settled after its final decrease.
- (c). User calls DECOMMIT_SIGNAL (burns NFT) before withdrawing remainders from inactive positions.

# Proposed fix

## MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionManager.sol)

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
 import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
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
 
     constructor(
         address _manager,
         address _marketFactory,
         address _vtsOrchestrator,
         address _descriptor,
         IWETH9 _weth9,
         IAllowanceTransfer _permit2,
         address _actionsImpl,
         address _queueCustodianAddr
     )
         ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
         BaseActionsRouter(IPoolManager(_manager))
         Permit2Forwarder(_permit2)
         FietNativeWrapper(_weth9)
         PositionManagerEntrypoint(_marketFactory, _vtsOrchestrator, _actionsImpl)
     {
         if (_queueCustodianAddr == address(0) || _queueCustodianAddr.code.length == 0) {
             revert Errors.InvalidAddress(_queueCustodianAddr);
         }
         commitmentDescriptor = _descriptor;
         queueCustodian = IMMQueueCustodian(_queueCustodianAddr);
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
             (bytes calldata liquiditySignal, address owner, bytes calldata relayParams) =
                 params.decodeCommitSignalParams();
             _commitSignal(liquiditySignal, _mapRecipient(owner), relayParams);
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
     /// @param owner The address to receive the commitment NFT
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
         (,, uint256 positionCount, uint256 activePositionCount) = vtsOrchestrator.getCommit(tokenId);
         if (activePositionCount > 0) {
             revert Errors.CommitNotEmpty(tokenId);
         }
+        // Ensure no residual settled value remains on any inactive position before burning
+        for (uint256 i = 0; i < positionCount; i++) {
+            PositionId pid = vtsOrchestrator.getPositionId(tokenId, i);
+            (uint256 s0, uint256 s1) = vtsOrchestrator.getPositionSettledAmounts(pid);
+            if (s0 > 0 || s1 > 0) {
+                revert Errors.CommitNotDrained(tokenId);
+            }
+        }
 
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
             if (payerIsUser) {
                 _unwrapLccFromUser(lccAddr, _mapRecipient(recipient), amount);
             } else {
                 _unwrapLccFromDeltas(lccAddr, _mapRecipient(recipient), amount);
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
         returns (MarketMaker.State memory state, uint256 expiresAt, uint256 positionCount, uint256 activePositionCount)
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

## Errors.sol

File: `contracts/evm/src/libraries/Errors.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/Errors.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 // Concept for centralised source-of-truth for Errors adopted from
 // https://github.com/pendle-finance/pendle-core-v2-public/blob/main/contracts/core/libraries/Errors.sol
 
 // Import required types for error signatures
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {PositionId} from "../types/Position.sol";
 import {RFSCheckpoint} from "../types/Checkpoint.sol";
 
 /**
  * @title Errors
  * @notice Centralised error definitions for the Fiet protocol
  * @dev This library provides a single source of truth for all revert errors used across contracts.
  *      Errors are grouped by functional area for clarity and maintainability.
  */
 library Errors {
     // ============ AUTHORISATION & ACCESS CONTROL ============
     // Errors related to authorisation, permissions, and access control
 
     /// @notice Thrown when a sender is not authorised for a specific operation
     error InvalidSender();
 
     /// @notice Thrown when the caller is not approved or is not the owner
     error NotApproved(address caller);
 
     /// @notice Thrown when a bound level transition is disallowed (immutable EXEMPT/DEX, or EXEMPT/DEX only from NONE)
     /// @param oldLevel The current bound level before the attempted update
     /// @param newLevel The requested bound level
     error InvalidBoundLevelTransition(uint8 oldLevel, uint8 newLevel);
 
     /// @notice Thrown when ETH is sent from an unauthorised sender (e.g., not from authorised protocol contracts)
     error InvalidEthSender();
 
     // ============ VALIDATION & INPUT ERRORS ============
     // Errors related to invalid inputs, parameters, and validation failures
 
     /// @notice Thrown when an invalid amount is provided (zero or out of bounds)
     /// @param amount The invalid amount (0 if not applicable)
     /// @param maxAmount The maximum allowed amount (0 if not applicable)
     error InvalidAmount(uint256 amount, uint256 maxAmount);
 
     /// @notice Thrown when exact-input amountSpecified is outside ProxyHook's supported range
     /// @param amountSpecified The provided signed amountSpecified value
     /// @param minSupported The minimum supported amountSpecified (most negative)
     /// @param maxSupported The maximum supported amountSpecified for exact-input (-1)
     error UnsupportedExactInputAmount(int256 amountSpecified, int256 minSupported, int256 maxSupported);
 
     /// @notice Thrown when an invalid address is provided (zero address or invalid for context)
     error InvalidAddress(address self);
 
     /// @notice Thrown when an invalid market is provided
     error InvalidMarket(PoolKey poolKey);
 
     /// @notice Thrown when an invalid position is provided
     /// @param commitId The token ID (0 if not applicable)
     /// @param positionIndex The position index (0 if not applicable)
     /// @param positionId The position ID (PositionId.wrap(bytes32(0)) if not applicable)
     error InvalidPosition(uint256 commitId, uint256 positionIndex, PositionId positionId);
 
     /// @notice Thrown when there are nonzero deltas after a batch of actions
     error CurrencyNotSettled();
 
     /// @notice Thrown when an invalid delta is provided
     error InvalidDelta(int128 amount0, int128 amount1);
 
     /// @notice Thrown when an invalid liquidity signal is provided
     /// @param issuedValue Total issued LCC value
     /// @param signalValue Signal value from MarketMaker reserves
     /// @param settledValue Settled value already in-market
     error InvalidLiquiditySignal(uint256 issuedValue, uint256 signalValue, uint256 settledValue);
 
     /// @notice Thrown when an MM reserve set exceeds the maximum allowed unique ticker count
     /// @param uniqueTickerCount Unique ticker count in the MM reserve set
     /// @param maxUniqueTickerCount Maximum allowed unique ticker count per MM reserve set
     error MMReserveTickerLimitExceeded(uint256 uniqueTickerCount, uint256 maxUniqueTickerCount);
 
     /// @notice Thrown when an invalid LCC token is provided
     error InvalidLcc(address lcc);
 
     /// @notice Thrown when an invalid verifier is provided (invalid address, index, or not mapped)
     error InvalidVerifier();
 
     /// @notice Thrown when an invalid nonce is provided
     error InvalidNonce(uint256 newNonce, uint256 prevNonce);
 
     /// @notice Thrown when an invalid proof is provided
     error InvalidProof();
 
     /// @notice Thrown when an invalid fee configuration is provided for exact output swaps
     error InvalidFeeForExactOut();
 
     /// @notice Thrown when price limit is already exceeded before swap
     error PriceLimitAlreadyExceeded(uint160 sqrtPriceX96, uint160 sqrtPriceLimitX96);
 
     /// @notice Thrown when price limit is outside valid tick bounds
     error PriceLimitOutOfBounds(uint160 sqrtPriceLimitX96);
 
     // ============ POOL & MARKET ERRORS ============
     // Errors related to pool creation, market operations, and pool state
 
     /// @notice Thrown when the underlying assets of two LCCs do not match
     error UnderlyingAssetMismatch(address ua1, address ua2);
 
     /// @notice Thrown when a core pool already exists
     error CorePoolAlreadyExists();
 
     /// @notice Thrown when a proxy pool already exists
     error ProxyPoolAlreadyExists();
 
     /// @notice Thrown when the core pool key has already been set
     error CorePoolKeyAlreadySet();
 
     /// @notice Thrown when market oracles are not configured
     error MarketOraclesNotConfigured();
 
     /// @notice Thrown when adding liquidity through a hook is not allowed
     error AddLiquidityThroughHookNotAllowed();
 
     /// @notice Thrown when the pool manager must be locked
     error PoolManagerMustBeLocked();
 
     /// @notice Thrown when the pool manager must be unlocked
     error PoolManagerMustBeUnlocked();
 
     /// @notice Thrown when a ticker is not registered in the oracle
     error TickerNotRegistered(string ticker);
 
     // ============ LIQUIDITY & BALANCE ERRORS ============
     // Errors related to liquidity operations, balances, and insufficient funds
 
     /// @notice Thrown when there is insufficient wrapped liquidity available
     error InsufficientLiquidity(uint256 requested, uint256 available);
 
     /// @notice Thrown when there is insufficient liquidity to take from the vault
     error InsufficientLiquidityToTake();
 
     /// @notice Thrown when there is insufficient liquidity to settle
     error InsufficientLiquidityToSettle();
 
     /// @notice Thrown when there is insufficient balance for an operation
     error InsufficientBalance(uint256 balance, uint256 needed);
 
     /// @notice Thrown when a max input slippage guard is exceeded
     /// @param maximumAmount User supplied max amount permitted
     /// @param amountRequested Actual amount requested by execution
     error MaximumAmountExceeded(uint128 maximumAmount, uint128 amountRequested);
 
     /// @notice Thrown when a liquidity error occurs
     error LiquidityError(address lcc, uint256 amount);
 
     // ============ TRANSFER & OPERATION ERRORS ============
     // Errors related to transfers, operations, and transaction validity
 
     /// @notice Thrown when a transfer is not allowed
     error TransferNotAllowed();
 
     /// @notice Thrown when direct wrap minting targets a DEX ingress sink.
     error DirectWrapToDexNotAllowed(address recipient);
 
     /// @notice Thrown when native ETH transferFrom is attempted from a non-self source
     error NativeTransferFromUnsupported(address from);
 
     /// @notice Thrown when a deadline has passed
     error DeadlinePassed(uint256 deadline);
 
     /// @notice Thrown when a signal is invalid (expired or doesn't exist)
     error InvalidSignal(uint256 commitId);
 
     /// @notice Thrown when nested ingress settlement observes a different in-flight sync currency.
     error NestedIngressSyncCurrencyMismatch(address syncedCurrency, address expectedLcc);
 
     /// @notice Thrown when an active sync window already has an unpaid LCC ingress transfer.
     error NestedIngressUnpaidTransferExists(uint256 syncedReserves, uint256 poolManagerBalance);
 
     /// @notice Thrown when synced reserves exceed poolManager token balance for the synced LCC.
     error NestedIngressInvalidSyncSnapshot(uint256 syncedReserves, uint256 poolManagerBalance);
 
     // ============ POSITION & COMMITMENT ERRORS ============
     // Errors related to positions, commitments, and position management
 
     /// @notice Thrown when a position is not active
     error NotActive(PositionId id);
 
     /// @notice Thrown when a position is already registered
     error AlreadyRegistered(PositionId id);
 
     /// @notice Thrown when RFS (Required for Settlement) is open for a position
     error RFSOpenForPosition(PositionId positionId);
 
     /// @notice Thrown when RFS (Required for Settlement) is not open for a position
     error RFSNotOpenForPosition(PositionId positionId);
 
     /// @notice Thrown when a non-seizure MM liquidity change is attempted while commitment deficit is non-zero
     error CommitmentDeficitBlocksLiquidityChange(PositionId positionId);
 
     /// @notice Thrown when a commitment descriptor is not set
     error CommitmentDescriptorNotSet();
 
     /// @notice Thrown when attempting to decommit a signal that still has positions attached
     /// @param tokenId The token ID of the commitment that cannot be decommitted
     error CommitNotEmpty(uint256 tokenId);
+    error CommitNotDrained(uint256 tokenId);
 
     // ============ PAUSE & STATE ERRORS ============
     // Errors related to contract pause state and state transitions
 
     /// @notice Thrown when an operation is attempted while the contract is paused
     error EnforcedPause();
 
     /// @notice Thrown when an operation requires the contract to be paused but it is not
     error ExpectedPause();
 
     // ============ GRACE PERIOD & CHECKPOINT ERRORS ============
     // Errors related to grace periods, checkpoints, and settlement timing
 
     /// @notice Thrown when the grace period has not elapsed for a position
     /// @param commitId The token ID (0 if not applicable)
     /// @param positionIndex The position index (0 if not applicable)
     /// @param positionId The position ID (PositionId.wrap(bytes32(0)) if not applicable)
     /// @param checkpoint The RFS checkpoint (empty struct if not applicable)
     error GracePeriodNotElapsed(
         uint256 commitId, uint256 positionIndex, PositionId positionId, RFSCheckpoint checkpoint
     );
 
     /// @notice Thrown when an invalid token index is provided
     error InvalidTokenIndex(uint8 tokenIndex);
 
     /// @notice Thrown when VTS configuration is invalid
     /// @dev Invariant: maxGracePeriodTime must be >= gracePeriodTime
     error InvalidVTSConfiguration(uint256 gracePeriodTime, uint256 maxGracePeriodTime);
 
     // ============ FACTORY & CREATION ERRORS ============
     // Errors related to factory operations and token creation
 
     /// @notice Thrown when unable to generate a unique symbol for an LCC token
     error UnableToGenerateUniqueSymbol();
 
     // ============ INVARIANT & LOGIC ERRORS ============
     // Errors related to invariant violations and logical errors
 
     /// @notice Thrown when an invariant is violated
     error InvariantViolated(string message);
 
     /// @notice Thrown when a bucket-tracked holder has ERC20 balance but no bucket accounting
     error InvalidBucketState(address account, uint256 balance);
 
     // ============ VTS ORCHESTRATOR ERRORS ============
     // Errors related to the VTS Orchestrator
 
     /// @notice Thrown when the MM Position Manager address is not set
     error MMPositionManagerNotSet();
 
     // ============ ACTION ROUTER ERRORS ============
     // Errors related to action routing and handling
 
     /// @notice Thrown when an unsupported action is requested
     /// @param action The action code that is not supported
     error UnsupportedAction(uint256 action);
 }
```

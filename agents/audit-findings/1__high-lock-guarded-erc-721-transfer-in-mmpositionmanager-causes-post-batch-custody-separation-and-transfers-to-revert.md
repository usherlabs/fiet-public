[High] Lock-guarded ERC-721 transfer in MMPositionManager causes post-batch custody separation and transfers to revert

# Description

[MMPositionManager.transferFrom](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L546-L547) is guarded to [only allow transfers while the PoolManager is locked (mid-batch)](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L123-L126). This PR changed COMMIT_SIGNAL to always [mint the commitment NFT to the locker and rely on post-batch ERC-721 transfer for custody separation](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L220-L224). As a result, normal transfers at rest revert, blocking intended custody separation and secondary transfers.

In MMPositionManager, the modifier [onlyIfPoolManagerLocked reverts when IPoolManager.isUnlocked() is true](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L123-L126). The [transferFrom override uses this modifier](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L546-L547), so ERC-721 transfers are allowed only mid-batch and revert at rest. safeTransferFrom routes through the same transferFrom (Solmate), inheriting the constraint. This PR [removed the owner parameter from COMMIT_SIGNAL decoding](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/libraries/MMCalldataDecoder.sol#L376-L387) and changed the flow to [mint the commitment NFT to msgSender() with an explicit note that custody separation will occur via ERC-721 transfer after the batch](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L220-L224). However, users cannot perform an independent external call during the locked window, and there is no router action to transfer mid-batch. Approvals (approve/setApprovalForAll/permit) do not replace title transfer for custody separation or third-party sale. Consequently, the NFT becomes effectively non-transferable at rest, breaking the newly intended workflow and freezing the asset’s transferability indefinitely.

# Severity

**Impact Explanation:** [High] The NFT’s transferability is effectively frozen at rest with no practical workaround for title transfer (e.g., sale/assignment or custody rotation), constituting an asset freeze beyond a week.

**Likelihood Explanation:** [High] Normal, intended usage (post-batch transfer) consistently triggers the revert; no special conditions or attacker capabilities are required.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Post-batch custody separation fails: A user commits a signal (NFT minted to the locker) and, after the batch completes, attempts to transfer the NFT to a custody wallet; [transferFrom](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L546-L547)/safeTransferFrom reverts due to [onlyIfPoolManagerLocked](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L118-L121).
#### Preconditions / Assumptions
- (a). This PR version is deployed (COMMIT_SIGNAL mints to msgSender and relies on post-batch ERC-721 transfer)
- (b). PoolManager isUnlocked() == true after batch (normal at-rest state)
- (c). MMPositionManager.[transferFrom](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L546-L547) is guarded by [onlyIfPoolManagerLocked](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L118-L121)
- (d). safeTransferFrom routes through transferFrom (Solmate), inheriting the guard
- (e). No router action exists to perform ERC-721 transfer mid-batch; EOAs cannot inject a separate external call during the lock

### Scenario 2.
Secondary transfer/sale blocked: A user attempts to transfer or sell the commitment NFT to another party at rest; the call reverts because the PoolManager is unlocked, effectively freezing the NFT’s transferability.
#### Preconditions / Assumptions
- (a). User holds a commitment NFT minted to the locker under this PR
- (b). PoolManager isUnlocked() == true during normal at-rest operation
- (c). [transferFrom](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L546-L547)/safeTransferFrom in MMPositionManager require locked state and thus revert at rest
- (d). No feasible mid-batch external call pathway to execute transfer

### Scenario 3.
Owner rotation/security policy blocked: An organization attempts to rotate ownership from a hot locker account to a custody account after the batch; the transfer reverts at rest, preventing policy-driven title rotation.
#### Preconditions / Assumptions
- (a). Organization uses a hot locker EOA to mint and intends to rotate ownership to a custody wallet post-batch
- (b). PoolManager isUnlocked() == true at rest
- (c). transferFrom/safeTransferFrom reverts due to onlyIfPoolManagerLocked
- (d). Approvals are insufficient as a substitute for ownership/title change

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
 
     /// @dev UNWRAP_LCC payout may only go to the locker or MMPM; arbitrary third-party recipients are disallowed.
     function _resolveStrictRecipient(address recipient) internal view returns (address) {
         address to = _mapRecipient(recipient);
         if (to != msgSender() && to != address(this)) {
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
 
-    /// @dev Overrides transferFrom to revert if pool manager is locked
+    /// @dev Overrides transferFrom to revert while the PoolManager is unlocked (mid-batch)
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

## [Medium] Forced mint-to-locker in MMPositionManager COMMIT_SIGNAL causes permanent commitment custody loss and frozen funds

### Description

The PR [removed the owner parameter from COMMIT_SIGNAL](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/libraries/MMCalldataDecoder.sol#L376-L386) and [now always mints the commitment NFT to the locker (msgSender)](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L216-L224). If the locker cannot or does not forward the NFT post-batch (e.g., ephemeral/self-destructing locker or a limited router without a forwarding path), the commitment and attached positions/value can be permanently frozen because subsequent actions [require ApprovedOrOwner](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionActionsImpl.sol#L478-L486).

This PR changes MMPositionManager so that COMMIT_SIGNAL [always mints the commitment NFT](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L274) to [msgSender()](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L130-L133) (the batch "locker"), [removing the prior owner parameter](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/libraries/MMCalldataDecoder.sol#L376-L386). During modifyLiquidities, [transferFrom is blocked by onlyIfPoolManagerLocked](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L546-L547), so custody cannot be forwarded mid-batch. Post-batch, forwarding depends entirely on the locker calling transferFrom/safeTransferFrom or setting approvals/permit. Many critical flows (e.g., decommit, increase/decrease/burn/settle) [require ApprovedOrOwner(msgSender(), tokenId)](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionActionsImpl.sol#L478-L486). If the locker is ephemeral (self-destructs) or a limited router that does not expose a follow-up forwarding call, no one can transfer, approve, or permit the NFT, permanently freezing the commitment and any attached positions/liquidity. This stuck-funds risk is introduced by the PR because previously integrators could safely mint directly to the intended end owner via the [owner parameter](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/libraries/MMCalldataDecoder.sol#L376-L386), avoiding any dependency on a post-batch transfer.

### Severity

**Impact Explanation:** [High] Commitment NFTs can be permanently stranded with no user-side workaround, freezing management and withdrawals of attached positions/value (funds frozen beyond a week, potentially indefinitely).

**Likelihood Explanation:** [Low] Scenarios require uncommon integrator patterns and/or operator mistakes (ephemeral locker without post-batch forwarding or routers lacking forwarding paths). These are plausible but not common, and depend on external integration design choices.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Ephemeral locker creates a commitment and mints a position in a single batch; COMMIT_SIGNAL mints the NFT to the ephemeral locker; transfers are blocked mid-batch; after the batch, the locker self-destructs without forwarding; the NFT is permanently stuck with no way to transfer, approve, or permit, freezing all subsequent management and withdrawals.
#### Preconditions / Assumptions
- (a). Integrator uses an ephemeral create-and-destroy-in-same-tx locker as the batch initiator (msgSender).
- (b). The batch includes COMMIT_SIGNAL (and may include position actions that attach value).
- (c). Transfers are blocked mid-batch by [onlyIfPoolManagerLocked](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/MMPositionManager.sol#L546-L547); no auto-forwarding occurs during unlock.
- (d). Post-batch, the locker self-destructs without calling transfer/approve/permit.

### Scenario 2.
A non-malicious but limited router acts as the locker and executes COMMIT_SIGNAL (+ optional position actions); the NFT is minted to the router; the router exposes no generic follow-up call or dedicated NFT forwarding method; users cannot force transfer/approval; the commitment and any attached value remain stranded indefinitely.
#### Preconditions / Assumptions
- (a). An external router/aggregator contract is used as the locker (msgSender) and lacks a generic follow-up call or a dedicated function to forward/approve the NFT.
- (b). The router executes COMMIT_SIGNAL (and may include position actions that attach value).
- (c). No subsequent router upgrade or operational path exists to transfer/approve the NFT on behalf of users.

### Proposed fix

#### MMPositionManager.sol

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
+            // IMPORTANT: To prevent stranded custody when the locker cannot post-batch forward (e.g., ephemeral/self-destructing
+            // lockers or limited routers), implement a post-batch scheduled-forwarding mechanism that records the newly
+            // minted tokenId and the intended final owner here, and executes the ERC-721 _transfer in _afterBatch().
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
 
     /// @dev UNWRAP_LCC payout may only go to the locker or MMPM; arbitrary third-party recipients are disallowed.
     function _resolveStrictRecipient(address recipient) internal view returns (address) {
         address to = _mapRecipient(recipient);
         if (to != msgSender() && to != address(this)) {
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

#### PositionManagerEntrypoint.sol

File: `contracts/evm/src/modules/PositionManagerEntrypoint.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/ae1126d8fb78f6b9d3780b7b7e12ca3d90d2d39b/contracts/evm/src/modules/PositionManagerEntrypoint.sol)

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
     /// @dev Handles native value sent with the transaction and credits the exact msg.value amount
     function _beforeBatch() internal {
         // Handle native value EXACTLY once per batch.
         uint256 amount = TransientSlots.readMsgValueOnce();
         if (amount > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
         }
     }
 
     /// @notice Hook called after batch execution
     /// @dev Asserts that deltas are non-zero after batch execution
     function _afterBatch() internal {
         // Clear any per-batch transient context to avoid same-tx leakage into subsequent batches.
         TransientSlots.clearSeizedPositionId();
         TransientSlots.clearMsgValueRead();
+        // NOTE: Execute any scheduled post-batch commitment NFT forwards (locker -> finalOwner) here, after unlock ends.
+        // Implementation should re-validate current owner == locker and use internal _transfer to avoid mid-batch guard.
         // Owner-scoped and market-scoped transient namespaces both resolve through the orchestrator boundary.
         vtsOrchestrator.assertNonZeroDeltas(marketFactory);
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
     function _take(Currency currency, address to, uint256 maxAmount) internal {
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

[Critical] Residual LCC not moved after UNWRAP_LCC in MMPositionManager causes principal theft and unserviceable queued settlements

# Description

[UNWRAP_LCC utilities in MMPositionManager](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L441) can queue shortfalls to a user but leave the unburned LCC on the shared router. Settlement later requires [burning the recipient’s LCC](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/LiquidityHubLib.sol#L577), not the router’s, making the queue unserviceable unless the user re-acquires LCC. Any locker can also publicly [SYNC](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L484) + [TAKE](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L79-L82) to withdraw those residual LCC, enabling theft or cross-user reattribution of backing.

When MMPositionManager executes UNWRAP_LCC, it [calls LiquidityHub.unwrapTo](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L441) which [burns and pays only the immediately serviceable portion](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/LiquidityHub.sol#L604-L616) and [records any remaining shortfall in settleQueue[lcc][queueTo]](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/LiquidityHubLib.sol#L450). The corresponding unburned LCC remains at the MMPositionManager address; the helpers do not return it to the user or [forward it to the MMQueueCustodian](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerImpl.sol#L189). Later, LiquidityHub.processSettlementFor for external recipients [burns the recipient’s market-derived LCC (not the router’s)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/LiquidityHubLib.sol#L577), so the queued claim is not redeemable unless the user re-acquires LCC. Meanwhile, MMPositionManager exposes public [SYNC](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L484) + [TAKE](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L79-L82) utilities that allow any locker to credit their delta from the router’s ERC20 LCC balance and then transfer those LCC out, enabling theft of the residual tokens and reattribution of backing across users. In contrast, position decrease flows explicitly [forward LCC to a beneficiary-scoped custodian slice](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerImpl.sol#L189); this safety step is missing from the UNWRAP_LCC helpers.

# Severity

**Impact Explanation:** [High] Users can suffer direct, material loss of principal (their LCC are diverted and later redeemable by others), or are forced to re-acquire LCC to make their queued claims redeemable.

**Likelihood Explanation:** [High] No special constraints are required: shortfalls are normal under constrained liquidity, and SYNC + TAKE are public and simple to execute. Clear profit incentive exists for attackers.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Opportunistic theft: A user unwraps LCC via [UNWRAP_LCC](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L441) (payerIsUser = true) and creates a shortfall. LiquidityHub queues the remainder to the user but leaves unburned LCC on MMPositionManager. An attacker then calls [SYNC](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L484)(LCC) to credit their delta from the router’s LCC balance and [TAKE](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L79-L82)(LCC) to transfer those tokens to themselves. The victim is left with a queued claim they cannot settle without re-acquiring LCC; the attacker holds the victim’s LCC and can later redeem for underlying.
#### Preconditions / Assumptions
- (a). MMPositionManager is a registered unwrap endpoint
- (b). Victim uses UNWRAP_LCC (payerIsUser = true) and a shortfall occurs (insufficient immediate liquidity)
- (c). UNWRAP_LCC helpers do not auto-return residual LCC to the user or forward to MMQueueCustodian
- (d). Attacker can call public SYNC + TAKE on MMPositionManager

### Scenario 2.
Silent cross-user reattribution: User U1 unwraps with a shortfall; residual LCC stays on MMPositionManager while the queue is attributed to U1. Later, user U2 unwraps via the same router; LiquidityHub [burns from the router’s LCC holdings](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/LiquidityHub.sol#L604-L616) for immediate underlying. U1’s queued claim remains but is unserviceable without re-acquiring LCC, effectively reassigning backing from U1 to U2.
#### Preconditions / Assumptions
- (a). User U1 previously created a shortfall via UNWRAP_LCC; residual LCC remains on MMPositionManager
- (b). Another user U2 performs UNWRAP_LCC later through the same router
- (c). LiquidityHub burns against the router’s LCC holdings for immediate payout

### Scenario 3.
Front-running UI fix-up: A UI attempts to mitigate by immediately reclaiming residual LCC with [SYNC](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L484) + [TAKE](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L79-L82) after UNWRAP_LCC. In a public mempool, an attacker front-runs these calls with their own SYNC + TAKE to drain the router’s LCC first. The victim again ends with an unserviceable queue while the attacker captures the LCC.
#### Preconditions / Assumptions
- (a). UI attempts a follow-up SYNC + TAKE after UNWRAP_LCC to reclaim residual LCC for the user
- (b). Public mempool/MEV environment allows front-running
- (c). Attacker can issue SYNC + TAKE before the UI’s transaction executes

# Proposed fix

## MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol)

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
+        uint256 shortfall = toUnwrap > unwrapped ? (toUnwrap - unwrapped) : 0;
+        if (shortfall > 0) {
+            lccCurrency.transfer(address(queueCustodian), shortfall);
+            queueCustodian.record(0, lccAddr, msgSender(), shortfall);
+        }
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
+        uint256 shortfall = toUnwrap > unwrapped ? (toUnwrap - unwrapped) : 0;
+        if (shortfall > 0) {
+            // Forward residual (unburned) LCC to the shared queue custodian and
+            // record beneficiary-scoped custody under tokenId=0 (utility unwrap bucket).
+            lccCurrency.transfer(address(queueCustodian), shortfall);
+            queueCustodian.record(0, lccAddr, payer, shortfall);
+        }
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

## [High] Balance-to-delta sync from full owner balance without provenance in MMPositionManager SYNC causes unauthorized withdrawal of stranded ERC-20/LCC/WETH

### Description

[SYNC credits the current locker’s delta up to the entire ERC-20 balance held by MMPositionManager](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/OwnerCurrencyDelta.sol#L170-L205), and [TAKE can then withdraw it](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L60-L86). Because balances can be stranded on MMPositionManager (e.g., [TAKE to the contract](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L60-L86) or [unwrap/settlement to the contract](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L439-L458)), any later locker can claim those funds via SYNC + TAKE.

[OwnerCurrencyDelta.syncBalanceAsCredit reads the owner’s raw ERC-20 balance](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/OwnerCurrencyDelta.sol#L170-L205) and raises the target’s delta to that balance (or reduces their debt) without provenance or per-flow clamping. MMPositionManager exposes this via [SYNC with owner = address(this) and target = msgSender()](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L476-L489). [PositionManagerEntrypoint._take nets deltas and only transfers tokens when the recipient is not address(this)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L60-L86), enabling users to intentionally or accidentally leave ERC-20/LCC/WETH balances on the contract while clearing deltas. [Batch finality enforces only that deltas are zero](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L54-L59), not that MMPositionManager’s ERC-20 balances are zero, so stranded balances persist across batches. A later locker can call SYNC(currency) to credit themselves up to the full contract balance for that currency and then TAKE(currency, self, 0) to withdraw it. A targeted LCC-only mitigation after decreases [attempts to strip extra credit and forward non-fee LCC to a custodian](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerImpl.sol#L160-L211), but it does not address underlyings/WETH or other flows (e.g., unwrap-to-this). [Native ETH is excluded from SYNC by design](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L476-L489), but all non-native ERC-20s (including LCC and WETH) are affected.

### Severity

**Impact Explanation:** [High] Direct, material loss of principal: any non-native ERC-20/LCC/WETH balance left on MMPositionManager can be withdrawn by a later locker via SYNC + TAKE.

**Likelihood Explanation:** [Medium] Exploitation requires residual balances on MMPositionManager. Such residues are plausible through supported flows (e.g., TAKE to the contract, unwrap-to-this, or settlement to the contract), but they are not guaranteed to exist at all times.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Later locker sweeps stranded ERC-20/LCC/WETH via SYNC + TAKE: A previous user left a positive token balance on MMPositionManager (e.g., by calling TAKE with to = address(this)). A later locker includes [SYNC(token)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L476-L489) to credit their delta up to the full on-contract balance, then [TAKE(token, to = self, 0)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L60-L86) to withdraw all stranded tokens.
#### Preconditions / Assumptions
- (a). MMPositionManager holds a positive balance of a non-native ERC-20 (including LCC/WETH) from earlier activity (e.g., a prior TAKE to address(this) or other supported flows).
- (b). Any locker can invoke MMPositionManager’s SYNC and TAKE actions.
- (c). No special privileges or external integrations are required.

### Scenario 2.
Unwrap-to-this with stale underlying present: MMPositionManager already holds stale underlying U from a prior batch. An attacker unwraps LCC to [address(this); the flow then calls balance-based sync for U](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L439-L458), crediting the attacker for both the newly unwrapped U and the stale U. The attacker immediately TAKEs U to themselves.
#### Preconditions / Assumptions
- (a). MMPositionManager holds a stale balance of the underlying ERC-20 U from a prior batch (e.g., left by a previous user who kept tokens on the contract).
- (b). The attacker performs UNWRAP_LCC with recipient = address(this), which triggers a balance-based sync of U.
- (c). The attacker includes a TAKE(U, to = self, 0) in the same batch.

### Scenario 3.
Settlement outflows to MMPositionManager with residue: MMPositionManager holds stale underlying U. A settlement with usePositionManagerBalance = true pays out U to MMPositionManager. The flow then [calls balance-based sync for U](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionActionsImpl.sol#L422-L431), crediting the current locker against the entire on-contract U balance (new payout + residue). The locker TAKEs U to themselves.
#### Preconditions / Assumptions
- (a). MMPositionManager holds a stale underlying ERC-20 U.
- (b). A settlement with positive outflow to MMPositionManager is executed using usePositionManagerBalance = true, which triggers balance-based sync of U.
- (c). The locker includes TAKE(U, to = self, 0) to withdraw the credited amount.

### Proposed fix

#### MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol)

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
+        // SECURITY: Consider removing SYNC or making it revert to avoid provenance-less balance sync to lockers.
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
+                // SECURITY: Replace balance-based sync with creditExact of measured 'unwrapped' to the locker.
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
+                // SECURITY: Replace balance-based sync with creditExact of measured 'unwrapped' to the locker.
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

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol)

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
+        // SECURITY: Disallow to == address(this) to avoid stranding tokens on-contract that can be claimed later.
+        // if (to == address(this)) revert Errors.InvalidAddress(to);
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

#### MMPositionActionsImpl.sol

File: `contracts/evm/src/MMPositionActionsImpl.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionActionsImpl.sol)

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
 import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
 import {Position} from "./types/Position.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
 import {PositionManagerQueueCustodian} from "./modules/PositionManagerQueueCustodian.sol";
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
 
 /// @title MMPositionActionsImpl
 /// @notice Implementation contract for MMPositionManager position operations
 /// @dev Called via delegatecall from MMPositionManager, shares storage context
 /// @dev Only handles position operations (actions <= SETTLE_POSITION_FROM_DELTAS)
 /// @dev ERC721 functions accessed via delegatecall context from MMPositionManager
 contract MMPositionActionsImpl is
     IMMActionsImpl,
     PositionManagerQueueCustodian,
     PositionManagerImpl,
     DelegateCallGuard
 {
     using SafeCast for uint256;
     using PositionLibrary for PositionId;
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
     using CurrencySettler for Currency;
     using CurrencyTransfer for Currency;
     using MMCalldataDecoder for bytes;
 
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
 
     /// @inheritdoc PositionManagerQueueCustodian
     function _queueCustodian() internal view override(PositionManagerQueueCustodian) returns (IMMQueueCustodian) {
         return IMMPositionManager(address(this)).queueCustodian();
     }
 
     /// @dev `beneficiary` is the batch locker (`msgSender()` in impl), matching the Hub queue recipient chosen in
     ///      `VTSPositionLib` for `planCancelWithQueue`. Custody slices are keyed by this address so collect cannot
     ///      pair an arbitrary `tokenId` bucket with another party's queue.
     function _forwardQueuedLccToCustodian(Currency currency, uint256 tokenId, address beneficiary, uint256 amount)
         internal
         override(PositionManagerImpl)
     {
         IMMQueueCustodian custodian = _queueCustodian();
         if (address(custodian) != address(0) && address(custodian) != address(this)) {
             currency.transfer(address(custodian), amount);
             if (tokenId > 0) {
                 custodian.record(tokenId, Currency.unwrap(currency), beneficiary, amount);
             }
         }
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Position Action Handler
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc IMMActionsImpl
     /// @dev Only handles position operations (actions <= SETTLE_POSITION_FROM_DELTAS)
     function handleAction(uint256 action, bytes calldata params) external override onlyDelegateCall {
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
             (PoolKey calldata poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity) =
                 params.decodeMintPositionParams();
             _mintPosition(poolKey, tokenId, tickLower, tickUpper, liquidity);
             return;
         }
         if (action == MMActions.INCREASE_LIQUIDITY) {
             (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint256 liquidity) =
                 params.decodeIncreaseLiquidityParams();
             _increase(poolKey, tokenId, positionIndex, liquidity);
             return;
         }
         if (action == MMActions.DECREASE_LIQUIDITY) {
             (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint256 amountToDecrease) =
                 params.decodeDecreaseLiquidityParams();
             _decrease(poolKey, tokenId, positionIndex, amountToDecrease);
             return;
         }
         if (action == MMActions.BURN_POSITION) {
             (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex) = params.decodeBurnPositionParams();
             _burnPosition(poolKey, tokenId, positionIndex);
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
         (BalanceDelta settlementDelta, uint256 seizedLiquidityUnits) = _settle(
             poolKey, tokenId, positionIndex, -amount0.toInt128(), -amount1.toInt128(), usePositionManagerBalance
         );
 
         // Use returned maxima clamped settlementDelta
         bytes memory hookData = PositionModificationHookDataLib.encodeSeizure(
             tokenId, positionIndex, msgSender(), settlementDelta.amount0(), settlementDelta.amount1()
         );
 
         _decreaseInternal(
             poolKey,
             position,
             PositionLibrary.generateSalt(tokenId, positionIndex),
             tokenId,
             seizedLiquidityUnits,
             hookData
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
             // Either sync received amounts (non-native) or credit exact known native deltas.
             if (delta0 > 0) {
                 uint256 amt0Out = LiquidityUtils.safeInt128ToUint256(delta0);
                 if (params.underlying0 == CurrencyLibrary.ADDRESS_ZERO) {
                     _creditExact(params.underlying0, amt0Out);
                 } else {
+                    // SECURITY: Measure before/after balances and creditExact only the diff; avoid full-balance sync.
                     _syncBalanceAsCredit(params.underlying0);
                 }
             }
             if (delta1 > 0) {
                 uint256 amt1Out = LiquidityUtils.safeInt128ToUint256(delta1);
                 if (params.underlying1 == CurrencyLibrary.ADDRESS_ZERO) {
                     _creditExact(params.underlying1, amt1Out);
                 } else {
+                    // SECURITY: Measure before/after balances and creditExact only the diff; avoid full-balance sync.
                     _syncBalanceAsCredit(params.underlying1);
                 }
             }
         } else {
             // or forward to the locker.
             if (delta0 > 0) {
                 params.underlying0.transfer(sender, LiquidityUtils.safeInt128ToUint256(delta0));
             }
             if (delta1 > 0) {
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
 
             if (!isSeizing) {
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
     function _burnPosition(PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         uint256 completeLiquidity = uint256(position.liquidity);
         _decreaseInternal(
             poolKey,
             position,
             PositionLibrary.generateSalt(tokenId, positionIndex),
             tokenId,
             completeLiquidity,
             PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender())
         );
     }
 
     /// @notice Increases liquidity in an existing position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param liquidity The amount of liquidity to add
     function _increase(PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint256 liquidity) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
         _increaseInternal(poolKey, tokenId, positionIndex, position.tickLower, position.tickUpper, liquidity);
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
         return _increaseInternal(
             poolKey,
             tokenId,
             positionIndex,
             tickLower,
             tickUpper,
             liquidity,
             PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender())
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
         (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) =
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
         bytes memory hookData = payerIsUser
             ? PositionModificationHookDataLib.encodeWithInHookProtocolSettlement(
                 tokenId, positionIndex, sender, credit0, credit1
             )
             : PositionModificationHookDataLib.encode(tokenId, positionIndex, sender);
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
     function _mintPosition(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         _mintPositionInternal(poolKey, tokenId, tickLower, tickUpper, liquidity);
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
         bytes memory hookData = payerIsUser
             ? PositionModificationHookDataLib.encodeWithInHookProtocolSettlement(
                 tokenId, nextPositionIndex, msgSender(), credit0, credit1
             )
             : PositionModificationHookDataLib.encode(tokenId, nextPositionIndex, msgSender());
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
         bytes memory hookData
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
 
         _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
     }
 
     /// @notice Decreases liquidity from an existing position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amountToDecrease The amount of liquidity to remove
     function _decrease(PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint256 amountToDecrease)
         internal
     {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         _decreaseInternal(
             poolKey,
             position,
             PositionLibrary.generateSalt(tokenId, positionIndex),
             tokenId,
             amountToDecrease,
             PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender())
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
         return _mintPositionInternal(
             poolKey,
             tokenId,
             tickLower,
             tickUpper,
             liquidity,
             PositionModificationHookDataLib.encode(tokenId, nextPositionIndex, msgSender())
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
         (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) =
             _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
         principalDelta = liquidityDelta - feesAccrued;
     }
 }
```

#### PositionManagerImpl.sol

File: `contracts/evm/src/modules/PositionManagerImpl.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerImpl.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {BalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
 import {Errors} from "../libraries/Errors.sol";
 import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
 import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
 import {LiquidityUtils} from "../libraries/LiquidityUtils.sol";
 import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
 import {PositionManagerBase} from "./PositionManagerBase.sol";
 import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
 import {IMMQueueCustodian} from "../interfaces/IMMQueueCustodian.sol";
 import {MarketHandlerLib} from "../libraries/MarketHandlerLib.sol";
 
 /**
  * @title PositionManagerImpl
  * @notice Base contract providing implementation-specific functionality
  * @dev Contains functions used only by MMPositionActionsImpl
  * @dev Inherits ImmutableState to access poolManager
  */
 abstract contract PositionManagerImpl is PositionManagerBase, ImmutableState {
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
     using CurrencySettler for Currency;
 
     constructor(IPoolManager _poolManager, address _marketFactory, address _vtsOrchestrator, address _canonicalCustody)
         ImmutableState(_poolManager)
         PositionManagerBase(_marketFactory, _vtsOrchestrator, _canonicalCustody)
     {}
 
     // ------------------------------------------------------------------------------------------------
     // CREDIT HELPERS
     // ------------------------------------------------------------------------------------------------
 
     /// @notice Gets full credit for a single currency from VTSOrchestrator
     /// @param currency The currency to get credit for
     /// @param owner The owner address
     /// @return The full credit amount
     function _getFullCredit(Currency currency, address owner) internal view returns (uint256) {
         return vtsOrchestrator.getFullCredit(currency, owner);
     }
 
     /// @notice Gets full credit pair from VTSOrchestrator
     /// @param currency0 The first currency
     /// @param currency1 The second currency
     /// @param owner The owner address
     /// @return credit0 The credit for currency0
     /// @return credit1 The credit for currency1
     function _getFullCreditPair(Currency currency0, Currency currency1, address owner)
         internal
         view
         returns (uint256, uint256)
     {
         return vtsOrchestrator.getFullCreditPair(currency0, currency1, owner);
     }
 
     /// @notice Gets full debt for a single currency from VTSOrchestrator
     /// @param currency The currency to get debt for
     /// @param owner The owner address
     /// @return The full debt amount
     function _getFullDebt(Currency currency, address owner) internal view returns (uint256) {
         return vtsOrchestrator.getFullDebt(currency, owner);
     }
 
     /// @notice Gets full debt pair from VTSOrchestrator
     /// @param currency0 The first currency
     /// @param currency1 The second currency
     /// @param owner The owner address
     /// @return debt0 The debt for currency0
     /// @return debt1 The debt for currency1
     function _getFullDebtPair(Currency currency0, Currency currency1, address owner)
         internal
         view
         returns (uint256, uint256)
     {
         return vtsOrchestrator.getFullDebtPair(currency0, currency1, owner);
     }
 
     /// @notice Gets liquidity from deltas of underlying currencies
     /// @dev Calculates how much liquidity to mint/increase from what is owed
     /// @param poolKey The pool key for the position
     /// @param owner The owner address
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @return liquidity The liquidity from deltas
     function _getLiquidityFromDeltas(PoolKey memory poolKey, address owner, int24 tickLower, int24 tickUpper)
         internal
         view
         returns (uint256 liquidity, uint256 credit0, uint256 credit1)
     {
         (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
         (credit0, credit1) = _getFullCreditPair(
             _lccToUnderlyingCurrency(poolKey.currency0), _lccToUnderlyingCurrency(poolKey.currency1), owner
         );
         if (credit0 == 0 && credit1 == 0) {
             revert Errors.InvalidDelta(0, 0);
         }
         liquidity = LiquidityAmounts.getLiquidityForAmounts(
             sqrtPriceX96,
             TickMath.getSqrtPriceAtTick(tickLower),
             TickMath.getSqrtPriceAtTick(tickUpper),
             credit0,
             credit1
         );
     }
 
     // ------------------------------------------------------------------------------------------------
     // Balance-to-Delta Sync Helpers
     // ------------------------------------------------------------------------------------------------
 
     /// @notice Syncs balance accumulation as credit for a currency pair
     /// @dev Only handles balance increases (accumulation), not decreases (consumption).
     ///      Checks MMPM's balance (address(this)) and credits locker's delta (msgSender).
     /// @param currency0 The first currency to sync
     /// @param currency1 The second currency to sync
     function _syncPairBalanceAsCredit(Currency currency0, Currency currency1) internal {
         // owner = address(this) = MMPM (balance holder)
         // target = msgSender() = locker (delta recipient)
         vtsOrchestrator.syncPair(marketFactory, currency0, currency1, address(this), msgSender());
     }
 
     /// @notice Forwards queued LCC to the queue custodian, recorded for `beneficiary` (Hub queue recipient / locker)
     /// @dev `beneficiary` must stay aligned with `VTSPositionLib` queue recipient (hook locker) so custodian slices
     ///      match `settleQueue(lcc, beneficiary)` for `COLLECT_AVAILABLE_LIQUIDITY`.
     function _forwardQueuedLccToCustodian(Currency currency, uint256 tokenId, address beneficiary, uint256 amount)
         internal
         virtual;
 
     // ------------------------------------------------------------------------------------------------
     // Liquidity Flow/Modification Handlers
     // ------------------------------------------------------------------------------------------------
 
     function _settleNegativeDeltas(PoolKey memory key, address self, int128 delta0, int128 delta1) internal {
         // Settle negative deltas: pay tokens owed to PoolManager (LP is depositing)
         if (delta0 < 0) {
             key.currency0.settle(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta0), false);
         }
         if (delta1 < 0) {
             key.currency1.settle(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta1), false);
         }
     }
 
     function _handleLccBalanceIncrease(
         PoolKey memory key,
         Currency currency,
         uint256 balanceBefore,
         uint256 balanceAfter,
         int128 feesAccruedAmount,
         address locker,
         uint256 tokenId
     ) internal {
         // Planned-cancel safety depends on adjacency:
         // this handler runs immediately after the matching PoolManager -> MMPM take and before
         // control returns to any outer MM action, so path-keyed planned cancels are consumed
         // in the same logical flow that staged them.
         // Sync LCC fee balance ONLY increases as credit to locker
         // After taking from PoolManager, MMPM now holds LCC as ERC20 - sync as takeable credit to locker
         // However, MMPM can hold LCCs queued after _decrease, therefore we extract feesAccrued from the balance change
+        // SECURITY: Prefer creditExact(netFee) and forward nonFee to custodian; avoid balance-based sync.
         uint256 prevCredit = _getFullCredit(currency, locker);
         _syncBalanceAsCredit(currency);
 
         // IMPORTANT: PoolManager returns `callerDelta` already net of the hook delta.
         // For our CoreHook, that hook delta is `feeAdj`, and the raw pool fee delta returned as `feesAccrued`
         // must be netted by `feeAdj` to get the caller's *actual* fee take for this call.
         //
         // So: netFee = max(feesAccrued - feeAdj, 0)
         uint256 inc = balanceAfter - balanceBefore;
         int256 hookDelta = poolManager.currencyDelta(address(key.hooks), currency);
         int256 netFeei = int256(feesAccruedAmount) - hookDelta;
         uint256 fee = netFeei > 0 ? uint256(netFeei) : 0;
         uint256 currentCredit = _getFullCredit(currency, locker);
         uint256 addedCredit = currentCredit > prevCredit ? (currentCredit - prevCredit) : 0;
         uint256 extra = addedCredit > fee ? (addedCredit - fee) : 0;
         if (extra > 0) {
             vtsOrchestrator.take(currency, locker, extra);
         }
 
         uint256 nonFee = inc > fee ? (inc - fee) : 0;
         if (nonFee > 0) {
             _forwardQueuedLccToCustodian(currency, tokenId, locker, nonFee);
         }
     }
 
     function _takePositiveDeltasAndHandleLcc(
         PoolKey memory key,
         address self,
         int128 delta0,
         int128 delta1,
         BalanceDelta feesAccrued,
         address locker,
         uint256 tokenId
     ) internal {
         // Take positive deltas: receive tokens owed from PoolManager (LP is withdrawing)
         // Queued principal is then forwarded to the queue custodian, where planned cancel executes on the MMPM -> custodian transfer.
         // This immediate post-modify take is the sequencing invariant that makes LiquidityHub's
         // path-keyed planned-cancel transient slots safe in the current MM decrease flow.
         if (delta0 > 0) {
             uint256 balance0Before = key.currency0.balanceOfSelf();
             key.currency0.take(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta0), false);
             uint256 balance0After = key.currency0.balanceOfSelf();
 
             if (_isLCC(key.currency0)) {
                 _handleLccBalanceIncrease(
                     key, key.currency0, balance0Before, balance0After, feesAccrued.amount0(), locker, tokenId
                 );
             }
         }
         if (delta1 > 0) {
             uint256 balance1Before = key.currency1.balanceOfSelf();
             key.currency1.take(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta1), false);
             uint256 balance1After = key.currency1.balanceOfSelf();
 
             if (_isLCC(key.currency1)) {
                 _handleLccBalanceIncrease(
                     key, key.currency1, balance1Before, balance1After, feesAccrued.amount1(), locker, tokenId
                 );
             }
         }
     }
 
     function _afterModifyLiquidity(PoolKey memory key) internal {
         // Settle CoreHook's PoolManager deltas (hook delta applied after hook returned)
         // This ensures feeAdj-based claims are minted/burned to/from the fee pot held by CoreHook
         // Must be called within PoolManager.unlockCallback, but outside of modifyLiquidity hook
         marketFactory.afterModifyLiquidity(key);
     }
 
     /// @notice Modifies liquidity in a Uniswap V4 pool and immediately settles the deltas
     /// @dev This function:
     ///      1. Reads liquidity state before modification
     ///      2. Calls poolManager.modifyLiquidity (triggers CoreHook -> VTSOrchestrator.touchAndProcessPosition)
     ///      3. Reads resulting deltas
     ///      4. Settles/takes tokens with PoolManager
     ///      For MM decreases, step (4) is the immediate follow-up that consumes the path-keyed
     ///      planned cancel staged during hook execution in `VTSPositionLib`.
     ///
     ///      All delta management (fees, LCCs, settlement accounting) is handled by VTSOrchestrator
     ///      via the hook callback, so this function only needs to handle the PoolManager settlement.
     /// @param key The pool key identifying the pool to modify
     /// @param params Parameters for the liquidity modification (tick range, delta, salt)
     /// @param tokenId Commitment token id for queued LCC custody accounting
     /// @param hookData Arbitrary data to pass to hooks (contains PositionModificationHookData)
     /// @return callerDelta The principal balance delta - includes liquidity change plus immediate fee/hook deltas
     /// @return feesAccrued Informational delta of fee growth in the modified range for this call
     function _modifySyntheticLiquidity(
         PoolKey memory key,
         ModifyLiquidityParams memory params,
         uint256 tokenId,
         bytes memory hookData
     ) internal virtual returns (BalanceDelta callerDelta, BalanceDelta feesAccrued) {
         // MM liquidity must target the factory-registered canonical core pool so CoreHook runs and VTS registers
         // the position. Otherwise modifyLiquidity can strand tokens in an unmanaged PoolManager position.
         if (address(key.hooks) != MarketHandlerLib.getCoreHook(marketFactory)) {
             revert Errors.InvalidMarket(key);
         }
         if (MarketHandlerLib.getProxyHook(marketFactory, key) == address(0)) {
             revert Errors.InvalidMarket(key);
         }
 
         address self = address(this);
 
         // Get liquidity state before modification for validation
         (uint128 liquidityBefore,,) =
             poolManager.getPositionInfo(key.toId(), self, params.tickLower, params.tickUpper, params.salt);
 
         // PoolManager returns two deltas:
         // - callerDelta: token0/token1 change plus any immediate fee/hook deltas applied to the caller - ie. if _increase with liq=0, then delta > 0 where fees > 0
         // - feesAccrued: informational delta of fee growth in the modified range for this call
         // This call triggers CoreHook -> VTSOrchestrator.processPosition which handles all delta management
         (callerDelta, feesAccrued) = poolManager.modifyLiquidity(key, params, hookData);
 
         // Get liquidity state after modification for validation
         (uint128 liquidityAfter,,) =
             poolManager.getPositionInfo(key.toId(), self, params.tickLower, params.tickUpper, params.salt);
 
         // Validate that liquidity change matches expected delta
         if (SafeCast.toInt128(liquidityBefore) + params.liquidityDelta != SafeCast.toInt128(liquidityAfter)) {
             revert Errors.InvariantViolated("liquidity change incorrect");
         }
 
         // Use callerDelta directly for settlement - this is exactly what PoolManager applied to our
         // transient storage via _accountPoolBalanceDelta(key, callerDelta, msg.sender) in modifyLiquidity.
         // The callerDelta includes: principalDelta + feesAccrued, adjusted by any hookDelta returned.
         int128 delta0 = callerDelta.amount0();
         int128 delta1 = callerDelta.amount1();
         _settleNegativeDeltas(key, self, delta0, delta1);
 
         if (delta0 > 0 || delta1 > 0) {
             _takePositiveDeltasAndHandleLcc(key, self, delta0, delta1, feesAccrued, msgSender(), tokenId);
         }
 
         _afterModifyLiquidity(key);
     }
 }
```

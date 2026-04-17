[High] Principal/forwarding basis mismatch in MM decrease flow causes stranded custodied LCC or under-collection

# Description

In MM liquidity decreases, the queued "retained principal" is computed from pool principal only ([callerDelta - feesAccrued](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L88-L93)), while the router forwards "non-fee" LCC based on post-hook fee netting ([inc - max(feesAccrued - hookDelta, 0)](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/modules/PositionManagerImpl.sol#L170-L179)). This basis mismatch makes forwarded LCC differ from the queued amount whenever feeAdj (hookDelta) ≠ 0, leading to stranded LCC in commit-bucket custody (slash) or under-collection (bonus).

During MM decreases, VTSPositionMMOpsLib computes [principalDelta = callerDelta - feesAccrued](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L88-L93) and stages [LiquidityHub.planCancelWithQueue(principalAmount=P, queueAmount=Q)](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L518-L531) for the locker. On the PoolManager → MMPM transfer, [LCC._afterTransfer triggers LiquidityHub.executePlannedCancel](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/LCC.sol#L300-L319), burning (P - Q) and queuing Q. After this burn, PositionManagerImpl._handleLccBalanceIncrease [measures inc = balanceAfter - balanceBefore](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/modules/PositionManagerImpl.sol#L170-L179) = Q + F (F = feesAccrued). It then [classifies fees using hookDelta: netFee = max(F - H, 0)](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/modules/PositionManagerImpl.sol#L170-L179). The forwarded non-fee LCC to the custodian is [forwardedNonFee = inc - netFee](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/modules/PositionManagerImpl.sol#L190-L195) = Q + F - max(F - H, 0). Therefore: - If H > 0 (slash): forwardedNonFee = Q + min(H, F) > Q. The extra LCC is forwarded into the commit-bucket custodian beyond the live Hub queue. [LiquidityHub.settleFromCustodian clamps to min(queue, available, maxAmount, custodied)](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/LiquidityHubLib.sol#L728-L739) and cannot release this excess. There is [no commit-bucket reconcile path](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/MMPositionManager.sol#L520-L549), so the excess remains stranded indefinitely unless new queue arises. - If H < 0 (bonus): forwardedNonFee = max(Q - |H|, 0) < Q, starving collection until additional LCC is custodied. This mismatch is introduced by defining queue principal as pool principal only (excluding feeAdj) while forwarding remains post-feeAdj based.

# Severity

**Impact Explanation:** [High] For slashed decreases, excess forwarded LCC beyond the live Hub queue is stranded in commit-bucket custody with no programmatic user workaround, resulting in indefinite funds freeze. For bonus decreases, collection is under-satisfied until more custody accrues.

**Likelihood Explanation:** [Medium] Requires MM decreases with planned-cancel (common) and non-zero feeAdj (plausible under coverage/fee-sharing). No trusted-role misuse or rare external failures are needed, but feeAdj ≠ 0 is not guaranteed on every decrease.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Slash (feeAdj > 0): User decreases liquidity; Q is queued, and [router forwards Q + min(H, F) to the custodian](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/modules/PositionManagerImpl.sol#L190-L195). [LiquidityHub later releases at most Q](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/LiquidityHubLib.sol#L728-L739), leaving min(H, F) LCC stranded in the commit-bucket custodian with [no release path](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/MMPositionManager.sol#L520-L549).
#### Preconditions / Assumptions
- (a). Active MM position (commit NFT tokenId > 0) with a decrease (liquidityDelta < 0)
- (b). VTSPositionMMOpsLib uses [principalDelta = callerDelta - feesAccrued](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L88-L93) for queue routing
- (c). Uniswap v4 semantics: callerDelta at hook-time includes principal + raw feesAccrued; hookDelta applies after the hook returns to the hook address
- (d). [Planned-cancel executes on PoolManager → MMPM transfer before router measures balance increase](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/LCC.sol#L300-L319)
- (e). Positive feeAdj (hookDelta > 0) on the LCC leg
- (f). [LiquidityHub.settleFromCustodian clamps to min(queue, available, maxAmount, custodied)](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/LiquidityHubLib.sol#L728-L739) and no commit-bucket reconcile utility exists

### Scenario 2.
Slash exceeds raw fees (feeAdj ≥ feesAccrued): After decrease, forwarded non-fee equals Q + F. [Custodian holds Q + F while the Hub queue is Q](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/LiquidityHubLib.sol#L728-L739), stranding F LCC indefinitely in the commit bucket.
#### Preconditions / Assumptions
- (a). All preconditions of Scenario 1
- (b). Slash magnitude feeAdj ≥ feesAccrued for the leg

### Scenario 3.
Bonus (feeAdj < 0): After decrease, forwarded non-fee equals max(Q - |H|, 0), less than the queued Q. Subsequent collection can only release the smaller custodied amount, leaving a queue remainder unsettled until further custodied LCC accrues.
#### Preconditions / Assumptions
- (a). Active MM position (commit NFT tokenId > 0) with a decrease (liquidityDelta < 0)
- (b). VTSPositionMMOpsLib uses [principalDelta = callerDelta - feesAccrued](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L88-L93) for queue routing
- (c). Uniswap v4 semantics and planned-cancel execution timing as above
- (d). Negative feeAdj (hookDelta < 0) on the LCC leg
- (e). [LiquidityHub.settleFromCustodian clamps to min(queue, available, maxAmount, custodied)](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/LiquidityHubLib.sol#L728-L739)

# Proposed fix

## IQueueCustodian.sol

File: `contracts/evm/src/interfaces/IQueueCustodian.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/interfaces/IQueueCustodian.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 /// @title IQueueCustodian
 /// @notice Minimal interface for beneficiary-scoped queued LCC custody used by LiquidityHub (`settleFromCustodian`).
 /// @dev `bucketId` is an opaque bucket key (for example commitment NFT id, or a utility sentinel such as `0` for
 ///      `UNWRAP_LCC` shortfalls). Implementations map `(bucketId, lcc, beneficiary)` to a custodied LCC slice that
 ///      must align with `LiquidityHub.settleQueue(lcc, beneficiary)` for settlement pairing.
 interface IQueueCustodian {
     /// @notice Reads custodied LCC balance for a bucket, LCC, and beneficiary slice.
     function queued(uint256 bucketId, address lcc, address beneficiary) external view returns (uint256);
 
     /// @notice Releases up to `maxAmount` of custodied LCC to `beneficiary`, debiting the slice.
     /// @return released Actual amount released (capped by slice balance).
     function release(uint256 bucketId, address lcc, address beneficiary, uint256 maxAmount)
         external
         returns (uint256 released);
+
+    // TODO(security): Introduce a sink-based excess reconciliation to avoid stranded custody.
+    // function releaseExcessToSink(uint256 bucketId, address lcc, address beneficiary, address sink, uint256 maxAmount) external returns (uint256 released);
+    // - only callable by the bound PositionManager; debits (bucketId,lcc,beneficiary) by up to excess = max(custodied - hubQueued, 0) and transfers to `sink`.
 }
```

## MMQueueCustodian.sol

File: `contracts/evm/src/MMQueueCustodian.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/MMQueueCustodian.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {Errors} from "./libraries/Errors.sol";
 
 /// @title MMQueueCustodian
 /// @notice Shared custody for queued MM-backed LCC balances, bucketed by commitment token id and beneficiary
 /// @dev Beneficiary-scoped slices prevent cross-composition: Hub queue is per-(lcc, recipient); custody must
 ///      align so COLLECT_AVAILABLE_LIQUIDITY cannot spend another recipient's LCC under the same tokenId.
 ///
 ///      Intended model:
 ///      - `beneficiary` is always the MM batch locker whose `LiquidityHub.settleQueue(lcc, beneficiary)` entry
 ///        was created for that staged principal (see `VTSPositionLib` queue recipient == hook `locker`).
 ///      - Normal decreases: locker is the authorised party acting on the commitment (typically owner or approved operator).
 ///      - Seizure decreases: locker is the seizer. Custody and queue (when present) both attribute to that locker.
 contract MMQueueCustodian is IMMQueueCustodian {
     using CurrencyTransfer for Currency;
 
     /// @notice Beneficiary-scoped custody increased (MM-backed LCC staged for later Hub settlement).
     event CustodyRecorded(uint256 indexed tokenId, address indexed lcc, address indexed beneficiary, uint256 amount);
 
     /// @notice Beneficiary-scoped custody decreased and LCC transferred out.
     event CustodyReleased(uint256 indexed tokenId, address indexed lcc, address indexed beneficiary, uint256 amount);
 
     /// @notice One-time authoriser allowed to bind the position manager.
     address public authorisedBinder;
     address public override positionManager;
 
     // tokenId => lcc => beneficiary => queued custody balance
     mapping(uint256 tokenId => mapping(address lcc => mapping(address beneficiary => uint256 amount))) private
         _queuedLcc;
 
     modifier onlyPositionManager() {
         if (msg.sender != positionManager) revert Errors.InvalidSender();
         _;
     }
 
     constructor(address _authorisedBinder) {
         if (_authorisedBinder == address(0)) revert Errors.InvalidAddress(_authorisedBinder);
         authorisedBinder = _authorisedBinder;
     }
 
     function setPositionManager(address _positionManager) external override {
         if (msg.sender != authorisedBinder) revert Errors.InvalidSender();
         if (positionManager != address(0)) revert Errors.InvalidSender();
         if (_positionManager == address(0) || _positionManager.code.length == 0) {
             revert Errors.InvalidAddress(_positionManager);
         }
         positionManager = _positionManager;
         authorisedBinder = address(0);
     }
 
     function record(uint256 tokenId, address lcc, address beneficiary, uint256 amount)
         external
         override
         onlyPositionManager
     {
         if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
         if (beneficiary == address(0)) revert Errors.InvalidAddress(beneficiary);
         if (amount == 0) return;
         _queuedLcc[tokenId][lcc][beneficiary] += amount;
         emit CustodyRecorded(tokenId, lcc, beneficiary, amount);
     }
 
     // Releases LCC to recipient before processSettlementFor is called.
     function release(uint256 tokenId, address lcc, address beneficiary, uint256 maxAmount)
         external
         override
         returns (uint256 released)
     {
         if (beneficiary == address(0)) revert Errors.InvalidAddress(beneficiary);
         if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
         if (msg.sender != positionManager) {
             (bool ok, bytes memory data) = lcc.staticcall(abi.encodeCall(ILCC.hub, ()));
             if (!ok || data.length < 32 || msg.sender != abi.decode(data, (address))) revert Errors.InvalidSender();
         }
         if (maxAmount == 0) return 0;
 
         uint256 available = _queuedLcc[tokenId][lcc][beneficiary];
         released = available < maxAmount ? available : maxAmount;
         if (released == 0) return 0;
 
         _queuedLcc[tokenId][lcc][beneficiary] = available - released;
         emit CustodyReleased(tokenId, lcc, beneficiary, released);
         Currency.wrap(lcc).transfer(beneficiary, released);
     }
 
+    // TODO(security): Add onlyPositionManager function to drain excess custody to a protocol fee-sink.
+    // function releaseExcessToSink(uint256 tokenId, address lcc, address beneficiary, address sink, uint256 maxAmount) external onlyPositionManager returns (uint256 released) {
+    //     // excess = max(_queuedLcc[tokenId][lcc][beneficiary] - hubQueued(lcc, beneficiary), 0)
+    //     // decrement custodied by `released`, transfer released to `sink`
+    // }
+
     function queued(uint256 tokenId, address lcc, address beneficiary) external view override returns (uint256) {
         return _queuedLcc[tokenId][lcc][beneficiary];
     }
 }
```

## MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/MMPositionManager.sol)

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
     /// @dev Fresh commit is owner-authenticated: VRL sees `signal.mmState.owner` as the proof principal.
     ///      Direct commit requires `locker == mmState.owner`. Relayed commit may mint the NFT to a different locker
     ///      while EIP-712 relay auth is bound to `mmState.owner` via `VRLSignalManager.submitAuthNonce[owner]`.
     /// @param liquiditySignal The ABI-encoded LiquiditySignal to verify and record
     /// @param locker The batch locker; commitment NFT is minted here (`msgSender()`)
     /// @return tokenId The commitment NFT id created
     function _commitSignal(bytes calldata liquiditySignal, address locker, bytes calldata relayParams)
         internal
         returns (uint256 tokenId)
     {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         address mmOwner = signal.mmState.owner;
 
         if (relayParams.length == 0) {
             if (msgSender() != mmOwner) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignal(marketFactory, liquiditySignal);
         } else {
             (uint256 deadline, uint256 authNonce, bytes memory authSig) =
                 abi.decode(relayParams, (uint256, uint256, bytes));
             tokenId = vtsOrchestrator.commitSignalRelayed(marketFactory, liquiditySignal, deadline, authNonce, authSig);
         }
         _mint(locker, tokenId);
         emit SignalCommitted(tokenId);
     }
 
     /// @notice Renews an existing signal with new parameters
     /// @param tokenId The commitment NFT token ID
     /// @param liquiditySignal The new liquidity signal
     function _renewSignal(uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) internal {
         if (relayParams.length == 0) {
             vtsOrchestrator.renewSignal(marketFactory, tokenId, liquiditySignal);
         } else {
             (uint256 deadline, uint256 authNonce, bytes memory authSig) =
                 abi.decode(relayParams, (uint256, uint256, bytes));
             vtsOrchestrator.renewSignalRelayed(marketFactory, tokenId, liquiditySignal, deadline, authNonce, authSig);
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
             _reconcileUtilityCustodyWithHubQueue(lccAddr, queueTo);
             uint256 qBefore = liquidityHub.settleQueue(lccAddr, queueTo);
             liquidityHub.unwrapTo(lccAddr, to, queueTo, toUnwrap);
             uint256 queued = liquidityHub.settleQueue(lccAddr, queueTo) - qBefore;
             if (queued > 0) {
                 _forwardUnwrapQueuedLccToCustodian(lccCurrency, queueTo, queued);
             }
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
             _reconcileUtilityCustodyWithHubQueue(lccAddr, payer);
             // Pull only from the locker/user (never arbitrary third parties).
             // Snapshot queue *after* transfer: non-protocol -> protocol triggers annulment of queued
             // settlement (LCC-02), so the baseline for this unwrap's incremental queue must be post-annul.
             lccCurrency.transferFrom(payer, address(this), toUnwrap);
             uint256 qBefore = liquidityHub.settleQueue(lccAddr, payer);
             liquidityHub.unwrapTo(lccAddr, to, payer, toUnwrap);
             uint256 queued = liquidityHub.settleQueue(lccAddr, payer) - qBefore;
             if (queued > 0) {
                 _forwardUnwrapQueuedLccToCustodian(lccCurrency, payer, queued);
             }
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
+        // TODO(security): Reconcile commit-bucket excess custody to protocol fee-sink before collecting:
+        // uint256 hubQueued = liquidityHub.settleQueue(lcc, locker);
+        // uint256 custodied = queueCustodian.queued(tokenId, lcc, locker);
+        // if (custodied > hubQueued) {
+        //     queueCustodian.releaseExcessToSink(tokenId, lcc, locker, feeSlashSink, custodied - hubQueued);
+        // }
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

## [High] Using pre-feeAdj principal for cancel/queue planning in VTSPositionMMOpsLib during MM decreases causes missing Hub queue and user claim when post-hook LCC take does not occur

### Description

MM decrease planning/clamping uses pre-feeAdj principal, but post-hook settlement/transfer uses net-of-feeAdj deltas. If feeAdj neutralizes or exceeds the pre-feeAdj principal+fees for a leg, no PoolManager→MMPM transfer occurs, the planned cancel is never executed, yet pa.settled is clamped, leaving no Hub queue credit for the locker and causing loss of their queued settlement claim.

The PR changed VTSPositionMMOpsLib.processMMOperations to [compute MM principal as callerDelta − feesAccrued and explicitly not subtract feeAdj](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L80-L98). During an MM decrease:
- processMMOperations [plans LiquidityHub.cancelWithQueue](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L506-L520) using this pre-feeAdj principal and [immediately clamps pa.settled by settleable+queued](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L157-L166).
- Planned cancel is only executed in [LiquidityHub.executePlannedCancel](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/LiquidityHub.sol#L1068-L1087) on LCC transfer ([LCC._afterTransfer](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/LCC.sol#L312-L316)) from PoolManager→MMPM.
- PositionManagerImpl._settleModifyLiquidityDeltas then [settles on post-hook (net-of-feeAdj) deltas](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/modules/PositionManagerImpl.sol#L170-L176). If for an LCC leg feeAdj ≥ principal+fees (H ≥ P+F), there is no take() for that leg, so executePlannedCancel never runs; no queue or burn occurs. If callerDelta==0, the tx succeeds without revert; if callerDelta<0 and MMPM has sufficient LCC, [negative deltas are paid](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/modules/PositionManagerImpl.sol#L136-L151) and the tx still succeeds. In both cases, the earlier pa.settled clamp persists without a corresponding Hub queue credit for the locker, resulting in durable accounting mismatch and the user losing their queued settlement claim for that decrease.

### Severity

**Impact Explanation:** [High] The user’s queued settlement claim is not recorded while pa.settled is decreased, resulting in direct, material loss of user entitlement and a broken accounting invariant between VTS settled amounts and Hub queues.

**Likelihood Explanation:** [Medium] feeAdj can include banked residual fee backing (not capped to this call’s fees) and can plausibly reach or exceed P+F, especially for small user-chosen decreases; the negative-net branch can be facilitated by pre-funding MMPM with LCC via allowed transfers. These are uncommon but realistic operational states.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Zero-net LCC leg: A decrease where pre-feeAdj principal P>0 for a leg but feeAdj equals P+fees (H=P+F), so post-hook callerDelta==0 for that leg. No PoolManager→MMPM transfer occurs; [executePlannedCancel is never called](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/LiquidityHub.sol#L1068-L1087); pa.settled is clamped by settleable+queued; no Hub queue is created; the locker’s queued claim is lost.
#### Preconditions / Assumptions
- (a). Locker is the position NFT owner or approved operator and initiates a normal MM decrease
- (b). For one LCC leg: pre-feeAdj principal P=(callerDelta−feesAccrued)>0
- (c). feeAdj equals P+fees for that leg (H=P+F), making post-hook callerDelta==0
- (d). No special balances or external conditions beyond standard protocol operation

### Scenario 2.
Negative-net LCC leg with MMPM funded: A decrease where feeAdj exceeds P+F (H>P+F) for a leg, making post-hook callerDelta<0. MMPM has enough LCC to pay the negative delta, so the tx succeeds without take() and executePlannedCancel never runs. pa.settled remains clamped while no Hub queue is created, causing loss of the locker’s queued claim.
#### Preconditions / Assumptions
- (a). Locker is the position NFT owner or approved operator and initiates a normal MM decrease
- (b). For one LCC leg: pre-feeAdj principal P>0 and feeAdj exceeds P+fees (H>P+F), making post-hook callerDelta<0
- (c). MMPM holds enough LCC of that leg to settle negative deltas (achievable via normal non-protocol→protocol LCC transfer or residual balances)

### Scenario 3.
Mixed per-leg outcome: In a two-token pool, one LCC leg satisfies H≥P+F (no take), while the other leg does not (normal take). The affected leg follows the no-take path (no executePlannedCancel, no queue, but clamp applied). The other leg queues correctly. The position ends with partial queue creation and a persistent mismatch; the locker loses the queued claim on the affected leg.
#### Preconditions / Assumptions
- (a). Locker is the position NFT owner or approved operator and initiates a normal MM decrease
- (b). Two-token pool where one leg meets H≥P+F (no-take) and the other leg does not (normal take)
- (c). Standard protocol operation; no special trust or cryptographic assumptions

### Proposed fix

#### VTSPositionMMOpsLib.sol

File: `contracts/evm/src/libraries/VTSPositionMMOpsLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {VTSStorage, PositionContext, TouchPositionParams, TouchPositionResult} from "../types/VTS.sol";
 import {
     PositionId,
     PositionModificationHookData,
     PositionModificationHookDataLib,
     MMIncreaseHookExtraData
 } from "../types/Position.sol";
 import {LiquidityUtils} from "./LiquidityUtils.sol";
 import {Errors} from "./Errors.sol";
 import {VTSCommitLib} from "./VTSCommitLib.sol";
 import {CheckpointLibrary} from "./Checkpoint.sol";
 import {OwnerCurrencyDelta} from "./OwnerCurrencyDelta.sol";
 import {MarketCurrencyDelta} from "./MarketCurrencyDelta.sol";
 import {VTSPositionLib} from "./VTSPositionLib.sol";
 import {IMarketVault} from "../interfaces/IMarketVault.sol";
 import {ICanonicalVault} from "../interfaces/ICanonicalVault.sol";
 
 /// @title VTSPositionMMOpsLib
 /// @notice Hot linked library: MM liquidity modify tail (LCC issue/cancel, protocol-credit, vault routing, RFS mark).
 /// @dev Registration and core `touchPosition` accounting remain in `VTSPositionLib`.
 /// @author Fiet Protocol
 library VTSPositionMMOpsLib {
     using SafeCast for uint256;
     using PoolIdLibrary for PoolKey;
     using StateLibrary for IPoolManager;
 
     /// @dev Shared protocol-credit deposit inputs for MM add and explicit settle-from-deltas paths.
     struct ProtocolCreditSettlementParams {
         IMarketVault marketVault;
         PositionId positionId;
         address owner;
         Currency lccCurrency0;
         Currency lccCurrency1;
         uint256 intendedSettle0;
         uint256 intendedSettle1;
         BalanceDelta requiredSettlementDelta;
         BalanceDelta rfsDelta;
         bool clampToRequiredSettlement;
         bool isSeizing;
     }
 
     /// @dev Shared protocol-credit deposit result.
     struct ProtocolCreditSettlementResult {
         BalanceDelta settlementDelta;
         BalanceDelta remainingRequiredSettlementDelta;
     }
 
     /// @dev Single-lane protocol-credit settlement inputs to keep helper calls below stack limits.
     struct ProtocolCreditSettlementLaneParams {
         PositionId positionId;
         address owner;
         Currency underlyingCurrency;
         uint8 tokenIndex;
         int128 currentUnderlyingDelta;
         uint256 intendedSettle;
         int128 requiredSettlementDelta;
         int128 rfsDelta;
         bool clampToRequiredSettlement;
         bool isSeizing;
     }
 
     /// @notice MM liquidity-modify tail: LCC issue/cancel, protocol-credit, vault routing, RFS checkpoint.
     /// @dev Invoked from `VTSPositionLib.touchPosition` when hook data is an MM operation. `PoolManager.modifyLiquidity`
     ///      passes hook-time `callerDelta = poolPrincipalDelta + feesAccrued` into `afterModifyLiquidity`; the hook's
     ///      returned delta is applied only after the hook returns. LCC principal for issue/cancel and queue routing must
     ///      therefore be `callerDelta - feesAccrued` (pool principal only), not net of `feeAdj`. Fee slash/bonus is
     ///      reconciled when MMPM takes LCC and classifies fee vs non-fee (`PositionManagerImpl._handleLccBalanceIncrease`).
     /// @param requiredSettlementDelta Required settlement delta computed during the touch accounting phase.
     function processMMOperations(
         VTSStorage storage s,
         PositionContext memory ctx,
         TouchPositionParams calldata p,
         TouchPositionResult memory result,
         BalanceDelta requiredSettlementDelta
     ) external {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(p.hookData);
         if (!PositionModificationHookDataLib.isMMOperation(mmData)) return;
 
         // True principal liquidity change (maps to LCC mint/burn for the position delta). `feesAccrued` is informational
         // fee collection in this modify; it is not part of principal. Do not subtract `feeAdj` here — that would double-
         // count hook settlement relative to the post-hook transfer amount the router uses for custodian forwarding.
         BalanceDelta principalDelta = p.callerDelta - p.feesAccrued;
 
         // NOTE: LCC fee credits are handled at the MMPM level via balance sync pattern.
         // After MMPM takes from PoolManager, it syncs the LCC balance as credit to locker.
         // This allows direct _take calls for LCC without a separate collectFees function.
 
         // Handle LCC issuance/cancellation based on liquidity direction
         if (p.params.liquidityDelta > 0) {
             // Adding liquidity: settle any hook-carried protocol credit before backing validation/LCC issuance.
             requiredSettlementDelta = _applyInHookProtocolSettlementForMmIncrease(
                 s, ctx, p.owner, result.id, p.poolKey, p.hookData, requiredSettlementDelta
             );
             _handleLiquidityIncrease(
                 s,
                 ctx,
                 p.poolKey,
                 p.params,
                 VTSPositionLib.LiquidityIncreaseParams({
                     owner: p.owner, commitId: mmData.commitId, positionId: result.id, principalDelta: principalDelta
                 })
             );
         } else if (p.params.liquidityDelta < 0) {
             // Re-decode hookData to get locker - scoped to free memory
             //
             // Intended beneficiary / queue recipient model (always hook-data `locker`, not a separate owner lookup):
             // - Normal liquidity decrease: locker is the party executing the batch (NFT owner or approved operator on MMPM).
             // - Seizure decrease: locker is the seizer (guarantor). Same encoding path; `isSeizing` only changes principal/settlement deltas.
             //
             // queueRecipient == MM batch locker == LiquidityHub settleQueue recipient for this decrease/seizure.
             // MMQueueCustodian records the same address as the beneficiary so COLLECT_AVAILABLE_LIQUIDITY can only
             // release LCC from the slice matching the caller's queue.
             address queueRecipient;
             {
                 queueRecipient = PositionModificationHookDataLib.getLocker(mmData);
             }
 
             // Snapshot routing: `_handleLiquidityDecrease` splits vault-immediate vs Hub queue. Only the sum of
             // those two leaves live `settled` here; any shortfall that cannot be queued stays in `pa.settled`
             // until later liquidity. Booking that remainder on `DynamicCurrencyDelta` would create batch uncleared
             // positive underlying delta (DELTA-01) while the vault cannot pay it in the same unlock.
             BalanceDelta underlyingDeltaSettlement;
             BalanceDelta exportedForSettlementClamp;
             if (mmData.seizure.isSeizing) {
                 // @note: For Seizures,
                 // - LCCs are received directly by locker simiarly to fees.
                 // - Unwrapping these LCCs draws from the MM settled amounts, either immediately or via settlement queue - allowing protocol coverage to be maintained.
                 // - For any excess, this can also be settled immediately via MM operations.
 
                 // Only cancel excess settled received.
                 (underlyingDeltaSettlement, exportedForSettlementClamp) = _handleLiquidityDecrease(
                     ctx, p.owner, p.poolKey, requiredSettlementDelta, requiredSettlementDelta, queueRecipient
                 );
             } else {
                 // Removing liquidity: Cancel LCCs without seizing.
 
+                // Gate planned cancel/queue by post-hook take: mask principal legs with no post-hook take.
+                // In hook scope, p.callerDelta is pre-feeAdj; derive post-hook delta by adding result.feeAdj.
+                BalanceDelta postHookDelta = p.callerDelta + result.feeAdj;
+                int128 pd0 = principalDelta.amount0();
+                int128 pd1 = principalDelta.amount1();
+                if (postHookDelta.amount0() <= 0) pd0 = 0;
+                if (postHookDelta.amount1() <= 0) pd1 = 0;
+                principalDelta = toBalanceDelta(pd0, pd1);
                 // @note We cannot cancel directly at this point in the flow,
                 // The LCC's are not yet deposited into the MMPM by the poolManager - as we're during modification of liquidity.
                 // Therefore, we plan to cancel the LCC's and queue the settlement once this settlement occurs.
                 // This relies on the current MM path immediately performing the matching PoolManager -> MMPM take
                 // once modifyLiquidity(...) returns, before any same-key planned cancel can be restaged.
                 (underlyingDeltaSettlement, exportedForSettlementClamp) = _handleLiquidityDecrease(
                     ctx, p.owner, p.poolKey, principalDelta, requiredSettlementDelta, queueRecipient
                 );
             }
             VTSPositionLib._applySettlementClampFromExcess(
                 s,
                 result.id,
                 LiquidityUtils.safeInt128ToUint256(exportedForSettlementClamp.amount0()),
                 LiquidityUtils.safeInt128ToUint256(exportedForSettlementClamp.amount1())
             );
 
             requiredSettlementDelta = underlyingDeltaSettlement;
         }
 
         if (!LiquidityUtils.isZeroDelta(requiredSettlementDelta)) {
             // Account underlying currency settlement obligations to MMPositionManager
             // Split model: Underlying settlement deltas on MMPM represent market liquidity claims (settle-only)
             // Balance syncs from wrap/unwrap target locker (msgSender) for takeable credits
             //
             // Accumulate per-batch: `accountUnderlyingSettlementDelta` is setter-style (targets absolute pair), so
             // multiple MM ops in the same unlock for the same owner/currency lane must add onto the current pair.
             BalanceDelta currentUnderlying =
                 OwnerCurrencyDelta.getUnderlyingDeltaPair(p.owner, p.poolKey.currency0, p.poolKey.currency1);
             OwnerCurrencyDelta.accountUnderlyingSettlementDelta(
                 p.owner,
                 LiquidityUtils.safeToBalanceDelta(
                     int256(currentUnderlying.amount0()) + int256(requiredSettlementDelta.amount0()),
                     int256(currentUnderlying.amount1()) + int256(requiredSettlementDelta.amount1())
                 ),
                 p.poolKey.currency0,
                 p.poolKey.currency1
             );
 
             if (requiredSettlementDelta.amount0() > 0) {
                 Currency underlyingCurrency0 = OwnerCurrencyDelta.lccToUnderlyingCurrency(p.poolKey.currency0);
                 ctx.marketVault
                     .decreaseLiquidityReserve(
                         underlyingCurrency0, LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount0())
                     );
                 MarketCurrencyDelta.addProduced(
                     ICanonicalVault(ctx.marketVault.canonicalVault()).marketFactory(),
                     underlyingCurrency0,
                     LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount0())
                 );
             }
             if (requiredSettlementDelta.amount1() > 0) {
                 Currency underlyingCurrency1 = OwnerCurrencyDelta.lccToUnderlyingCurrency(p.poolKey.currency1);
                 ctx.marketVault
                     .decreaseLiquidityReserve(
                         underlyingCurrency1, LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount1())
                     );
                 MarketCurrencyDelta.addProduced(
                     ICanonicalVault(ctx.marketVault.canonicalVault()).marketFactory(),
                     underlyingCurrency1,
                     LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount1())
                 );
             }
         }
 
         // Mark RFS checkpoint
         (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, result.id);
         CheckpointLibrary.markCheckpoint(s, result.id, VTSPositionLib._rfsOpenMask(rfsDelta));
     }
 
     /// @dev Shared protocol-credit deposit primitive reused by MM add and explicit settle-from-deltas paths.
     function settleFromPositiveUnderlyingDelta(VTSStorage storage s, ProtocolCreditSettlementParams memory p)
         external
         returns (ProtocolCreditSettlementResult memory result)
     {
         result = _settleFromPositiveUnderlyingDelta(s, p);
     }
 
     /// @dev Applies one protocol-credit deposit lane by consuming live positive underlying delta.
     function _consumePositiveUnderlyingDeltaForSettlementLane(
         VTSStorage storage s,
         ProtocolCreditSettlementLaneParams memory p
     ) private returns (int128 settlementDelta, int128 remainingRequiredSettlementDelta, uint256 settledIncrease) {
         remainingRequiredSettlementDelta = p.requiredSettlementDelta;
         if (p.currentUnderlyingDelta <= 0 || p.intendedSettle == 0) {
             return (0, remainingRequiredSettlementDelta, 0);
         }
         if (p.clampToRequiredSettlement && p.requiredSettlementDelta >= 0) {
             return (0, remainingRequiredSettlementDelta, 0);
         }
 
         uint256 availableCredit = LiquidityUtils.safeInt128ToUint256(p.currentUnderlyingDelta);
         uint256 requestedAmount = p.intendedSettle;
         if (requestedAmount > availableCredit) requestedAmount = availableCredit;
         if (p.clampToRequiredSettlement) {
             uint256 requiredAmount = LiquidityUtils.safeInt128ToUint256(p.requiredSettlementDelta);
             if (requestedAmount > requiredAmount) requestedAmount = requiredAmount;
         }
         if (p.isSeizing) {
             if (p.rfsDelta <= 0) return (0, remainingRequiredSettlementDelta, 0);
             uint256 maxSeizingDeposit = LiquidityUtils.safeInt128ToUint256(p.rfsDelta);
             if (requestedAmount > maxSeizingDeposit) requestedAmount = maxSeizingDeposit;
         }
         if (requestedAmount == 0) return (0, remainingRequiredSettlementDelta, 0);
 
         (int256 totalApplied, int256 settledDeltaOnly) =
             VTSPositionLib._vUpdateSettlement(s, p.positionId, p.tokenIndex, requestedAmount.toInt256());
         if (totalApplied <= 0) return (0, remainingRequiredSettlementDelta, 0);
 
         uint256 creditConsumed = uint256(totalApplied);
         OwnerCurrencyDelta.accountDelta(p.underlyingCurrency, -creditConsumed.toInt128(), p.owner);
         settlementDelta = -creditConsumed.toInt128();
         if (settledDeltaOnly > 0) {
             settledIncrease = uint256(settledDeltaOnly);
         }
         if (p.clampToRequiredSettlement) {
             // MM in-hook backing: only the portion that increases `pa.settled` satisfies the deposit requirement.
             // Deficit / commitment-deficit cure consumes credit but must not over-clear `requiredSettlementDelta`.
             if (settledDeltaOnly > 0) {
                 remainingRequiredSettlementDelta += uint256(settledDeltaOnly).toInt128();
             }
         }
     }
 
     /// @dev Shared protocol-credit deposit primitive reused by MM add and explicit settle-from-deltas paths.
     function _settleFromPositiveUnderlyingDelta(VTSStorage storage s, ProtocolCreditSettlementParams memory p)
         private
         returns (ProtocolCreditSettlementResult memory result)
     {
         BalanceDelta currentUnderlying =
             OwnerCurrencyDelta.getUnderlyingDeltaPair(p.owner, p.lccCurrency0, p.lccCurrency1);
         (int128 settle0, int128 remaining0, uint256 settledIncrease0) = _consumePositiveUnderlyingDeltaForSettlementLane(
             s,
             ProtocolCreditSettlementLaneParams({
                 positionId: p.positionId,
                 owner: p.owner,
                 underlyingCurrency: OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0),
                 tokenIndex: 0,
                 currentUnderlyingDelta: currentUnderlying.amount0(),
                 intendedSettle: p.intendedSettle0,
                 requiredSettlementDelta: p.requiredSettlementDelta.amount0(),
                 rfsDelta: p.rfsDelta.amount0(),
                 clampToRequiredSettlement: p.clampToRequiredSettlement,
                 isSeizing: p.isSeizing
             })
         );
         (int128 settle1, int128 remaining1, uint256 settledIncrease1) = _consumePositiveUnderlyingDeltaForSettlementLane(
             s,
             ProtocolCreditSettlementLaneParams({
                 positionId: p.positionId,
                 owner: p.owner,
                 underlyingCurrency: OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1),
                 tokenIndex: 1,
                 currentUnderlyingDelta: currentUnderlying.amount1(),
                 intendedSettle: p.intendedSettle1,
                 requiredSettlementDelta: p.requiredSettlementDelta.amount1(),
                 rfsDelta: p.rfsDelta.amount1(),
                 clampToRequiredSettlement: p.clampToRequiredSettlement,
                 isSeizing: p.isSeizing
             })
         );
 
         result.settlementDelta = toBalanceDelta(settle0, settle1);
         result.remainingRequiredSettlementDelta = toBalanceDelta(remaining0, remaining1);
 
         if (settle0 < 0) {
             MarketCurrencyDelta.consumeProduced(
                 ICanonicalVault(p.marketVault.canonicalVault()).marketFactory(),
                 OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0),
                 LiquidityUtils.safeInt128ToUint256(settle0)
             );
         }
         if (settle1 < 0) {
             MarketCurrencyDelta.consumeProduced(
                 ICanonicalVault(p.marketVault.canonicalVault()).marketFactory(),
                 OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1),
                 LiquidityUtils.safeInt128ToUint256(settle1)
             );
         }
         if (settledIncrease0 > 0) {
             p.marketVault
                 .increaseLiquidityReserve(OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0), settledIncrease0);
         }
         if (settledIncrease1 > 0) {
             p.marketVault
                 .increaseLiquidityReserve(OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1), settledIncrease1);
         }
     }
 
     /// @dev Settles protocol credit inside the MM add-liquidity hook path before LCC issuance/backing validation.
     function _applyInHookProtocolSettlementForMmIncrease(
         VTSStorage storage s,
         PositionContext memory ctx,
         address owner,
         PositionId positionId,
         PoolKey memory poolKey,
         bytes memory hookData,
         BalanceDelta requiredSettlementDelta
     ) private returns (BalanceDelta remainingRequiredSettlementDelta) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decode(hookData);
         MMIncreaseHookExtraData memory extra = PositionModificationHookDataLib.decodeMMIncreaseHookExtraData(mmData);
         if (!extra.settleInHook) return requiredSettlementDelta;
 
         ProtocolCreditSettlementResult memory settled = _settleFromPositiveUnderlyingDelta(
             s,
             ProtocolCreditSettlementParams({
                 marketVault: ctx.marketVault,
                 positionId: positionId,
                 owner: owner,
                 lccCurrency0: poolKey.currency0,
                 lccCurrency1: poolKey.currency1,
                 intendedSettle0: extra.intendedSettle0,
                 intendedSettle1: extra.intendedSettle1,
                 requiredSettlementDelta: requiredSettlementDelta,
                 rfsDelta: BalanceDelta.wrap(0),
                 clampToRequiredSettlement: true,
                 isSeizing: false
             })
         );
 
         remainingRequiredSettlementDelta = settled.remainingRequiredSettlementDelta;
     }
 
     // --------------------------------------------------
     // LCC Issuance/Cancellation Helpers
     // --------------------------------------------------
 
     /// @notice Handle liquidity increase (mint or add liquidity) - issues LCCs
     /// @param s The VTS storage
     /// @param ctx The position context
     /// @param poolKey The pool key
     /// @param params The modify liquidity params
     /// @param p The liquidity increase params (bundled for stack depth)
     function _handleLiquidityIncrease(
         VTSStorage storage s,
         PositionContext memory ctx,
         PoolKey memory poolKey,
         ModifyLiquidityParams memory params,
         VTSPositionLib.LiquidityIncreaseParams memory p
     ) private {
         // Calculate amounts in scoped block
         uint256 amount0;
         uint256 amount1;
         {
             // Negative delta means LP deposited tokens
             amount0 =
                 p.principalDelta.amount0() < 0 ? LiquidityUtils.safeInt128ToUint256(p.principalDelta.amount0()) : 0;
             amount1 =
                 p.principalDelta.amount1() < 0 ? LiquidityUtils.safeInt128ToUint256(p.principalDelta.amount1()) : 0;
             if (amount0 == 0 && amount1 == 0) return;
         }
 
         // Validate commitment backing in scoped block.
         // `touchPosition` updates `positions[positionId].liquidity` to post-modify liquidity before this MM tail runs,
         // so use that total for issued-value (COMMIT-01), not the incremental `params.liquidityDelta` alone.
         {
             (uint160 sqrtPriceX96, int24 currentTick,,) = ctx.poolManager.getSlot0(poolKey.toId());
             uint128 postAddLiquidity = s.positions[p.positionId].liquidity;
             VTSCommitLib.validateLiquidityDelta(
                 s,
                 ctx.oracleHelper,
                 p.commitId,
                 p.positionId,
                 VTSCommitLib.LiquidityDeltaParams({
                     currency0: poolKey.currency0,
                     currency1: poolKey.currency1,
                     sqrtPriceX96: sqrtPriceX96,
                     currentTick: currentTick,
                     tickLower: params.tickLower,
                     tickUpper: params.tickUpper,
                     liquidityDelta: SafeCast.toInt256(postAddLiquidity)
                 }),
                 true
             );
         }
 
         // Issue LCC tokens in scoped block
         {
             if (amount0 > 0) {
                 ctx.liquidityHub.issue(Currency.unwrap(poolKey.currency0), p.owner, amount0);
             }
             if (amount1 > 0) {
                 ctx.liquidityHub.issue(Currency.unwrap(poolKey.currency1), p.owner, amount1);
             }
         }
     }
 
     /// @dev Stack-isolated core for MM decrease vault vs queue split (used by `_handleLiquidityDecrease` and tests).
     // if shortfall <= principal, then yes: settleable + queued == excess
     // if shortfall > principal, then no: settleable + queued < excess
     // Therefore export != excess, and we must accomodate.
     function _computeLiquidityDecreaseRoutingSplit(
         PositionContext memory ctx,
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta
     )
         internal
         view
         returns (
             uint256 retainedPrincipal0,
             uint256 retainedPrincipal1,
             BalanceDelta settleableDelta,
             BalanceDelta queuedDelta,
             BalanceDelta underlyingDeltaSettlement,
             BalanceDelta exportedForSettlementClamp
         )
     {
         uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
         uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
         int128 req0 = requiredSettlementDelta.amount0();
         int128 req1 = requiredSettlementDelta.amount1();
 
         {
             BalanceDelta availableDelta = ctx.marketVault.dryModifyLiquidities(requiredSettlementDelta);
             BalanceDelta rawShortfall = requiredSettlementDelta - availableDelta;
             int128 shortfall0 = rawShortfall.amount0();
             int128 shortfall1 = rawShortfall.amount1();
             if (shortfall0 < 0) shortfall0 = 0;
             if (shortfall1 < 0) shortfall1 = 0;
 
             settleableDelta = toBalanceDelta(req0 - shortfall0, req1 - shortfall1);
 
             uint256 shortfallAmount0 = LiquidityUtils.safeInt128ToUint256(shortfall0);
             uint256 shortfallAmount1 = LiquidityUtils.safeInt128ToUint256(shortfall1);
             retainedPrincipal0 = shortfallAmount0 > principalAmount0 ? principalAmount0 : shortfallAmount0;
             retainedPrincipal1 = shortfallAmount1 > principalAmount1 ? principalAmount1 : shortfallAmount1;
         }
 
         queuedDelta = LiquidityUtils.safeToBalanceDelta(retainedPrincipal0, retainedPrincipal1, false, false);
         underlyingDeltaSettlement = settleableDelta;
         exportedForSettlementClamp = toBalanceDelta(
             SafeCast.toInt128(int256(settleableDelta.amount0()) + int256(queuedDelta.amount0())),
             SafeCast.toInt128(int256(settleableDelta.amount1()) + int256(queuedDelta.amount1()))
         );
     }
 
     /// @notice Handle liquidity decrease (remove liquidity or burn) - cancels LCCs
     /// @dev Stages path-keyed planned cancels for the subsequent PoolManager -> MMPM LCC transfer.
     ///      This helper is correct only because the surrounding MM decrease flow immediately
     ///      performs that transfer after `modifyLiquidity(...)` returns.
     /// @param ctx The position context
     /// @param owner The position owner
     /// @param poolKey The pool key
     /// @param principalDelta The principal delta after fee adjustments
     /// @param requiredSettlementDelta The required settlement delta from touchPosition
     /// @param queueRecipient The recipient for settlement queue (locker)
     /// @return underlyingDeltaSettlement Portion routed to `DynamicCurrencyDelta` (vault-immediate slice only).
     /// @return exportedForSettlementClamp Amount to remove from live `settled`: immediate slice plus queued principal.
     function _handleLiquidityDecrease(
         PositionContext memory ctx,
         address owner,
         PoolKey memory poolKey,
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta,
         address queueRecipient
     ) internal returns (BalanceDelta underlyingDeltaSettlement, BalanceDelta exportedForSettlementClamp) {
         uint256 retainedPrincipal0;
         uint256 retainedPrincipal1;
         (retainedPrincipal0, retainedPrincipal1,,, underlyingDeltaSettlement, exportedForSettlementClamp) =
             _computeLiquidityDecreaseRoutingSplit(ctx, principalDelta, requiredSettlementDelta);
 
         if (LiquidityUtils.isZeroDelta(principalDelta)) {
             return (underlyingDeltaSettlement, exportedForSettlementClamp);
         }
 
         uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
         uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
 
         // 3. Queue settlements via cancelWithQueue
         // Burns LCCs on transfer from PoolManager to owner (MMPM) and queues shortfall for queueRecipient (locker).
         // Only cancel LCCs for tokens that have non-zero principal delta (tokens actually removed from liquidity)
         // Process token0 cancellation
         {
             if (principalAmount0 > 0) {
                 ctx.liquidityHub
                     .planCancelWithQueue(
                         Currency.unwrap(poolKey.currency0),
                         address(ctx.poolManager),
                         owner,
                         principalAmount0,
                         retainedPrincipal0,
                         queueRecipient
                     );
             }
         }
 
         // Process token1 cancellation
         {
             if (principalAmount1 > 0) {
                 ctx.liquidityHub
                     .planCancelWithQueue(
                         Currency.unwrap(poolKey.currency1),
                         address(ctx.poolManager),
                         owner,
                         principalAmount1,
                         retainedPrincipal1,
                         queueRecipient
                     );
             }
         }
 
         // 4. Actual queued amounts are tracked in LiquidityHub as owed to queueRecipient.
         // When _collectAvailableLiquidity is called, underlying is transferred to the recipient.
         // If recipient is MMPM, the balance is synced to the locker's delta.
         // Any shortfall remainder beyond this call's cancellable principal stays in live `settled` (not transient delta).
     }
 }
```

## [Medium] Negative per-leg principal converted to positive in VTSPositionMMOpsLib MM decrease routing causes planned overburn and DoS

### Description

During MM liquidity decreases, principal is [computed as callerDelta − feesAccrued](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L93) per leg. When feeAdj (A) exceeds the removed principal (P) on a leg, this yields a negative principal that is then [converted to a positive value via abs()](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L454-L455) and used to [plan cancel/queue](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L522-L531). The resulting cancel can exceed the LCC actually transferred on that leg, causing the [transfer-hook burn to revert](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/LiquidityHub.sol#L1068) and blocking decrease/burn operations.

In MM decrease flows, VTSPositionMMOpsLib.processMMOperations sets per-leg [principalDelta = callerDelta − feesAccrued](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L93). For a given token lane, let P be the pool principal removed this call, F be feesAccrued, and A be the materialised fee adjustment (slash > 0). The code path treats callerDelta on that lane as P + F − A (post-hook). Hence principalDelta = (P + F − A) − F = P − A. If A > P on a lane, principalDelta.amountX < 0. Downstream, both the split logic and the planned cancel/queue [convert principalDelta.amountX to an unsigned value with an absolute-value helper](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L454-L455) and [call planCancelWithQueue](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L522-L531) with that amount. When the PoolManager transfer completes, [LCC._afterTransfer](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/LCC.sol#L305-L314) triggers [LiquidityHub.executePlannedCancel](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/LiquidityHub.sol#L1068), which attempts to [burn cancelAmount = abs(P − A) − queue](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/LiquidityHub.sol#L835-L867) on that lane. If abs(P − A) − queue exceeds the just-transferred amount on that lane (P + F − A), the burn reverts, causing the entire decrease/burn transaction to fail (DoS).

### Severity

**Impact Explanation:** [Medium] The issue can significantly and repeatedly block core position lifecycle operations (liquidity decreases and burns) for affected positions, constituting a substantial availability loss/DoS of core functionality. It does not generally cause direct principal loss or a global protocol outage.

**Likelihood Explanation:** [Medium] The failure requires slashed states where the per-leg fee adjustment exceeds the per-call principal removed (A > P) and fees accrued are not enough to offset it. These conditions are uncommon but realistic and can occur in practice; no trusted-role misuse or external integration failure is needed.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Decrease liquidity reverts (no queue): An MM decreases liquidity. On one token lane, feeAdj A > principal P but P + F − A > 0. principalDelta becomes P − A < 0, is [converted to abs(A − P)](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L454-L455), and used to stage [planCancelWithQueue](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L522-L531) with queue = 0. After transfer, [executePlannedCancel](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/LiquidityHub.sol#L1068) attempts to burn (A − P) > (P + F − A), causing revert and blocking the decrease.
#### Preconditions / Assumptions
- (a). Active MM position and a DECREASE_LIQUIDITY action is executed
- (b). For a token lane: P + F − A > 0 and 2A > 2P + F (equivalently A > (2P + F)/2)
- (c). No settlement shortfall to queue on that lane (queue = 0)
- (d). principalDelta is [computed as callerDelta − feesAccrued](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L93) per leg and then [converted to an unsigned amount via absolute value](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L454-L455) for cancel/queue staging

### Scenario 2.
Full burn reverts: An MM attempts to burn a position. On one token lane, A is sufficiently large relative to P and F (P + F − A > 0 and 2A > 2P + F). The same abs-based cancel staging makes the burn attempt exceed the transferred amount on that lane, reverting and preventing closure.
#### Preconditions / Assumptions
- (a). An MM invokes full position burn (complete liquidity removal)
- (b). For at least one token lane: P + F − A > 0 and 2A > 2P + F
- (c). principalDelta is [computed as callerDelta − feesAccrued](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L93) per leg and then [converted to an unsigned amount via absolute value](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L454-L455) for cancel/queue staging

### Scenario 3.
Decrease reverts despite small queue: An MM decreases liquidity. On one token lane, a small retained queue exists but 2A > 2P + F + queue, so abs-based cancel still exceeds the transferred amount on that lane. The planned burn reverts and the decrease fails.
#### Preconditions / Assumptions
- (a). Active MM position and a DECREASE_LIQUIDITY action is executed
- (b). For a token lane: P + F − A > 0 and 2A > 2P + F + queue (queue is present but small)
- (c). principalDelta is [computed as callerDelta − feesAccrued](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L93) per leg and then [converted to an unsigned amount via absolute value](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L454-L455) for cancel/queue staging

### Proposed fix

#### VTSPositionMMOpsLib.sol

File: `contracts/evm/src/libraries/VTSPositionMMOpsLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {VTSStorage, PositionContext, TouchPositionParams, TouchPositionResult} from "../types/VTS.sol";
 import {
     PositionId,
     PositionModificationHookData,
     PositionModificationHookDataLib,
     MMIncreaseHookExtraData
 } from "../types/Position.sol";
 import {LiquidityUtils} from "./LiquidityUtils.sol";
 import {Errors} from "./Errors.sol";
 import {VTSCommitLib} from "./VTSCommitLib.sol";
 import {CheckpointLibrary} from "./Checkpoint.sol";
 import {OwnerCurrencyDelta} from "./OwnerCurrencyDelta.sol";
 import {MarketCurrencyDelta} from "./MarketCurrencyDelta.sol";
 import {VTSPositionLib} from "./VTSPositionLib.sol";
 import {IMarketVault} from "../interfaces/IMarketVault.sol";
 import {ICanonicalVault} from "../interfaces/ICanonicalVault.sol";
 
 /// @title VTSPositionMMOpsLib
 /// @notice Hot linked library: MM liquidity modify tail (LCC issue/cancel, protocol-credit, vault routing, RFS mark).
 /// @dev Registration and core `touchPosition` accounting remain in `VTSPositionLib`.
 /// @author Fiet Protocol
 library VTSPositionMMOpsLib {
     using SafeCast for uint256;
     using PoolIdLibrary for PoolKey;
     using StateLibrary for IPoolManager;
 
     /// @dev Shared protocol-credit deposit inputs for MM add and explicit settle-from-deltas paths.
     struct ProtocolCreditSettlementParams {
         IMarketVault marketVault;
         PositionId positionId;
         address owner;
         Currency lccCurrency0;
         Currency lccCurrency1;
         uint256 intendedSettle0;
         uint256 intendedSettle1;
         BalanceDelta requiredSettlementDelta;
         BalanceDelta rfsDelta;
         bool clampToRequiredSettlement;
         bool isSeizing;
     }
 
     /// @dev Shared protocol-credit deposit result.
     struct ProtocolCreditSettlementResult {
         BalanceDelta settlementDelta;
         BalanceDelta remainingRequiredSettlementDelta;
     }
 
     /// @dev Single-lane protocol-credit settlement inputs to keep helper calls below stack limits.
     struct ProtocolCreditSettlementLaneParams {
         PositionId positionId;
         address owner;
         Currency underlyingCurrency;
         uint8 tokenIndex;
         int128 currentUnderlyingDelta;
         uint256 intendedSettle;
         int128 requiredSettlementDelta;
         int128 rfsDelta;
         bool clampToRequiredSettlement;
         bool isSeizing;
     }
 
     /// @notice MM liquidity-modify tail: LCC issue/cancel, protocol-credit, vault routing, RFS checkpoint.
     /// @dev Invoked from `VTSPositionLib.touchPosition` when hook data is an MM operation. `PoolManager.modifyLiquidity`
     ///      passes hook-time `callerDelta = poolPrincipalDelta + feesAccrued` into `afterModifyLiquidity`; the hook's
     ///      returned delta is applied only after the hook returns. LCC principal for issue/cancel and queue routing must
     ///      therefore be `callerDelta - feesAccrued` (pool principal only), not net of `feeAdj`. Fee slash/bonus is
     ///      reconciled when MMPM takes LCC and classifies fee vs non-fee (`PositionManagerImpl._handleLccBalanceIncrease`).
     /// @param requiredSettlementDelta Required settlement delta computed during the touch accounting phase.
     function processMMOperations(
         VTSStorage storage s,
         PositionContext memory ctx,
         TouchPositionParams calldata p,
         TouchPositionResult memory result,
         BalanceDelta requiredSettlementDelta
     ) external {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(p.hookData);
         if (!PositionModificationHookDataLib.isMMOperation(mmData)) return;
 
         // True principal liquidity change (maps to LCC mint/burn for the position delta). `feesAccrued` is informational
         // fee collection in this modify; it is not part of principal. Do not subtract `feeAdj` here — that would double-
         // count hook settlement relative to the post-hook transfer amount the router uses for custodian forwarding.
         BalanceDelta principalDelta = p.callerDelta - p.feesAccrued;
 
         // NOTE: LCC fee credits are handled at the MMPM level via balance sync pattern.
         // After MMPM takes from PoolManager, it syncs the LCC balance as credit to locker.
         // This allows direct _take calls for LCC without a separate collectFees function.
 
         // Handle LCC issuance/cancellation based on liquidity direction
         if (p.params.liquidityDelta > 0) {
             // Adding liquidity: settle any hook-carried protocol credit before backing validation/LCC issuance.
             requiredSettlementDelta = _applyInHookProtocolSettlementForMmIncrease(
                 s, ctx, p.owner, result.id, p.poolKey, p.hookData, requiredSettlementDelta
             );
             _handleLiquidityIncrease(
                 s,
                 ctx,
                 p.poolKey,
                 p.params,
                 VTSPositionLib.LiquidityIncreaseParams({
                     owner: p.owner, commitId: mmData.commitId, positionId: result.id, principalDelta: principalDelta
                 })
             );
         } else if (p.params.liquidityDelta < 0) {
             // Re-decode hookData to get locker - scoped to free memory
             //
             // Intended beneficiary / queue recipient model (always hook-data `locker`, not a separate owner lookup):
             // - Normal liquidity decrease: locker is the party executing the batch (NFT owner or approved operator on MMPM).
             // - Seizure decrease: locker is the seizer (guarantor). Same encoding path; `isSeizing` only changes principal/settlement deltas.
             //
             // queueRecipient == MM batch locker == LiquidityHub settleQueue recipient for this decrease/seizure.
             // MMQueueCustodian records the same address as the beneficiary so COLLECT_AVAILABLE_LIQUIDITY can only
             // release LCC from the slice matching the caller's queue.
             address queueRecipient;
             {
                 queueRecipient = PositionModificationHookDataLib.getLocker(mmData);
             }
 
             // Snapshot routing: `_handleLiquidityDecrease` splits vault-immediate vs Hub queue. Only the sum of
             // those two leaves live `settled` here; any shortfall that cannot be queued stays in `pa.settled`
             // until later liquidity. Booking that remainder on `DynamicCurrencyDelta` would create batch uncleared
             // positive underlying delta (DELTA-01) while the vault cannot pay it in the same unlock.
             BalanceDelta underlyingDeltaSettlement;
             BalanceDelta exportedForSettlementClamp;
             if (mmData.seizure.isSeizing) {
                 // @note: For Seizures,
                 // - LCCs are received directly by locker simiarly to fees.
                 // - Unwrapping these LCCs draws from the MM settled amounts, either immediately or via settlement queue - allowing protocol coverage to be maintained.
                 // - For any excess, this can also be settled immediately via MM operations.
 
                 // Only cancel excess settled received.
                 (underlyingDeltaSettlement, exportedForSettlementClamp) = _handleLiquidityDecrease(
                     ctx, p.owner, p.poolKey, requiredSettlementDelta, requiredSettlementDelta, queueRecipient
                 );
             } else {
                 // Removing liquidity: Cancel LCCs without seizing.
 
                 // @note We cannot cancel directly at this point in the flow,
                 // The LCC's are not yet deposited into the MMPM by the poolManager - as we're during modification of liquidity.
                 // Therefore, we plan to cancel the LCC's and queue the settlement once this settlement occurs.
                 // This relies on the current MM path immediately performing the matching PoolManager -> MMPM take
                 // once modifyLiquidity(...) returns, before any same-key planned cancel can be restaged.
                 (underlyingDeltaSettlement, exportedForSettlementClamp) = _handleLiquidityDecrease(
                     ctx, p.owner, p.poolKey, principalDelta, requiredSettlementDelta, queueRecipient
                 );
             }
             VTSPositionLib._applySettlementClampFromExcess(
                 s,
                 result.id,
                 LiquidityUtils.safeInt128ToUint256(exportedForSettlementClamp.amount0()),
                 LiquidityUtils.safeInt128ToUint256(exportedForSettlementClamp.amount1())
             );
 
             requiredSettlementDelta = underlyingDeltaSettlement;
         }
 
         if (!LiquidityUtils.isZeroDelta(requiredSettlementDelta)) {
             // Account underlying currency settlement obligations to MMPositionManager
             // Split model: Underlying settlement deltas on MMPM represent market liquidity claims (settle-only)
             // Balance syncs from wrap/unwrap target locker (msgSender) for takeable credits
             //
             // Accumulate per-batch: `accountUnderlyingSettlementDelta` is setter-style (targets absolute pair), so
             // multiple MM ops in the same unlock for the same owner/currency lane must add onto the current pair.
             BalanceDelta currentUnderlying =
                 OwnerCurrencyDelta.getUnderlyingDeltaPair(p.owner, p.poolKey.currency0, p.poolKey.currency1);
             OwnerCurrencyDelta.accountUnderlyingSettlementDelta(
                 p.owner,
                 LiquidityUtils.safeToBalanceDelta(
                     int256(currentUnderlying.amount0()) + int256(requiredSettlementDelta.amount0()),
                     int256(currentUnderlying.amount1()) + int256(requiredSettlementDelta.amount1())
                 ),
                 p.poolKey.currency0,
                 p.poolKey.currency1
             );
 
             if (requiredSettlementDelta.amount0() > 0) {
                 Currency underlyingCurrency0 = OwnerCurrencyDelta.lccToUnderlyingCurrency(p.poolKey.currency0);
                 ctx.marketVault
                     .decreaseLiquidityReserve(
                         underlyingCurrency0, LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount0())
                     );
                 MarketCurrencyDelta.addProduced(
                     ICanonicalVault(ctx.marketVault.canonicalVault()).marketFactory(),
                     underlyingCurrency0,
                     LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount0())
                 );
             }
             if (requiredSettlementDelta.amount1() > 0) {
                 Currency underlyingCurrency1 = OwnerCurrencyDelta.lccToUnderlyingCurrency(p.poolKey.currency1);
                 ctx.marketVault
                     .decreaseLiquidityReserve(
                         underlyingCurrency1, LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount1())
                     );
                 MarketCurrencyDelta.addProduced(
                     ICanonicalVault(ctx.marketVault.canonicalVault()).marketFactory(),
                     underlyingCurrency1,
                     LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount1())
                 );
             }
         }
 
         // Mark RFS checkpoint
         (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, result.id);
         CheckpointLibrary.markCheckpoint(s, result.id, VTSPositionLib._rfsOpenMask(rfsDelta));
     }
 
     /// @dev Shared protocol-credit deposit primitive reused by MM add and explicit settle-from-deltas paths.
     function settleFromPositiveUnderlyingDelta(VTSStorage storage s, ProtocolCreditSettlementParams memory p)
         external
         returns (ProtocolCreditSettlementResult memory result)
     {
         result = _settleFromPositiveUnderlyingDelta(s, p);
     }
 
     /// @dev Applies one protocol-credit deposit lane by consuming live positive underlying delta.
     function _consumePositiveUnderlyingDeltaForSettlementLane(
         VTSStorage storage s,
         ProtocolCreditSettlementLaneParams memory p
     ) private returns (int128 settlementDelta, int128 remainingRequiredSettlementDelta, uint256 settledIncrease) {
         remainingRequiredSettlementDelta = p.requiredSettlementDelta;
         if (p.currentUnderlyingDelta <= 0 || p.intendedSettle == 0) {
             return (0, remainingRequiredSettlementDelta, 0);
         }
         if (p.clampToRequiredSettlement && p.requiredSettlementDelta >= 0) {
             return (0, remainingRequiredSettlementDelta, 0);
         }
 
         uint256 availableCredit = LiquidityUtils.safeInt128ToUint256(p.currentUnderlyingDelta);
         uint256 requestedAmount = p.intendedSettle;
         if (requestedAmount > availableCredit) requestedAmount = availableCredit;
         if (p.clampToRequiredSettlement) {
             uint256 requiredAmount = LiquidityUtils.safeInt128ToUint256(p.requiredSettlementDelta);
             if (requestedAmount > requiredAmount) requestedAmount = requiredAmount;
         }
         if (p.isSeizing) {
             if (p.rfsDelta <= 0) return (0, remainingRequiredSettlementDelta, 0);
             uint256 maxSeizingDeposit = LiquidityUtils.safeInt128ToUint256(p.rfsDelta);
             if (requestedAmount > maxSeizingDeposit) requestedAmount = maxSeizingDeposit;
         }
         if (requestedAmount == 0) return (0, remainingRequiredSettlementDelta, 0);
 
         (int256 totalApplied, int256 settledDeltaOnly) =
             VTSPositionLib._vUpdateSettlement(s, p.positionId, p.tokenIndex, requestedAmount.toInt256());
         if (totalApplied <= 0) return (0, remainingRequiredSettlementDelta, 0);
 
         uint256 creditConsumed = uint256(totalApplied);
         OwnerCurrencyDelta.accountDelta(p.underlyingCurrency, -creditConsumed.toInt128(), p.owner);
         settlementDelta = -creditConsumed.toInt128();
         if (settledDeltaOnly > 0) {
             settledIncrease = uint256(settledDeltaOnly);
         }
         if (p.clampToRequiredSettlement) {
             // MM in-hook backing: only the portion that increases `pa.settled` satisfies the deposit requirement.
             // Deficit / commitment-deficit cure consumes credit but must not over-clear `requiredSettlementDelta`.
             if (settledDeltaOnly > 0) {
                 remainingRequiredSettlementDelta += uint256(settledDeltaOnly).toInt128();
             }
         }
     }
 
     /// @dev Shared protocol-credit deposit primitive reused by MM add and explicit settle-from-deltas paths.
     function _settleFromPositiveUnderlyingDelta(VTSStorage storage s, ProtocolCreditSettlementParams memory p)
         private
         returns (ProtocolCreditSettlementResult memory result)
     {
         BalanceDelta currentUnderlying =
             OwnerCurrencyDelta.getUnderlyingDeltaPair(p.owner, p.lccCurrency0, p.lccCurrency1);
         (int128 settle0, int128 remaining0, uint256 settledIncrease0) = _consumePositiveUnderlyingDeltaForSettlementLane(
             s,
             ProtocolCreditSettlementLaneParams({
                 positionId: p.positionId,
                 owner: p.owner,
                 underlyingCurrency: OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0),
                 tokenIndex: 0,
                 currentUnderlyingDelta: currentUnderlying.amount0(),
                 intendedSettle: p.intendedSettle0,
                 requiredSettlementDelta: p.requiredSettlementDelta.amount0(),
                 rfsDelta: p.rfsDelta.amount0(),
                 clampToRequiredSettlement: p.clampToRequiredSettlement,
                 isSeizing: p.isSeizing
             })
         );
         (int128 settle1, int128 remaining1, uint256 settledIncrease1) = _consumePositiveUnderlyingDeltaForSettlementLane(
             s,
             ProtocolCreditSettlementLaneParams({
                 positionId: p.positionId,
                 owner: p.owner,
                 underlyingCurrency: OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1),
                 tokenIndex: 1,
                 currentUnderlyingDelta: currentUnderlying.amount1(),
                 intendedSettle: p.intendedSettle1,
                 requiredSettlementDelta: p.requiredSettlementDelta.amount1(),
                 rfsDelta: p.rfsDelta.amount1(),
                 clampToRequiredSettlement: p.clampToRequiredSettlement,
                 isSeizing: p.isSeizing
             })
         );
 
         result.settlementDelta = toBalanceDelta(settle0, settle1);
         result.remainingRequiredSettlementDelta = toBalanceDelta(remaining0, remaining1);
 
         if (settle0 < 0) {
             MarketCurrencyDelta.consumeProduced(
                 ICanonicalVault(p.marketVault.canonicalVault()).marketFactory(),
                 OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0),
                 LiquidityUtils.safeInt128ToUint256(settle0)
             );
         }
         if (settle1 < 0) {
             MarketCurrencyDelta.consumeProduced(
                 ICanonicalVault(p.marketVault.canonicalVault()).marketFactory(),
                 OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1),
                 LiquidityUtils.safeInt128ToUint256(settle1)
             );
         }
         if (settledIncrease0 > 0) {
             p.marketVault
                 .increaseLiquidityReserve(OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0), settledIncrease0);
         }
         if (settledIncrease1 > 0) {
             p.marketVault
                 .increaseLiquidityReserve(OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1), settledIncrease1);
         }
     }
 
     /// @dev Settles protocol credit inside the MM add-liquidity hook path before LCC issuance/backing validation.
     function _applyInHookProtocolSettlementForMmIncrease(
         VTSStorage storage s,
         PositionContext memory ctx,
         address owner,
         PositionId positionId,
         PoolKey memory poolKey,
         bytes memory hookData,
         BalanceDelta requiredSettlementDelta
     ) private returns (BalanceDelta remainingRequiredSettlementDelta) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decode(hookData);
         MMIncreaseHookExtraData memory extra = PositionModificationHookDataLib.decodeMMIncreaseHookExtraData(mmData);
         if (!extra.settleInHook) return requiredSettlementDelta;
 
         ProtocolCreditSettlementResult memory settled = _settleFromPositiveUnderlyingDelta(
             s,
             ProtocolCreditSettlementParams({
                 marketVault: ctx.marketVault,
                 positionId: positionId,
                 owner: owner,
                 lccCurrency0: poolKey.currency0,
                 lccCurrency1: poolKey.currency1,
                 intendedSettle0: extra.intendedSettle0,
                 intendedSettle1: extra.intendedSettle1,
                 requiredSettlementDelta: requiredSettlementDelta,
                 rfsDelta: BalanceDelta.wrap(0),
                 clampToRequiredSettlement: true,
                 isSeizing: false
             })
         );
 
         remainingRequiredSettlementDelta = settled.remainingRequiredSettlementDelta;
     }
 
     // --------------------------------------------------
     // LCC Issuance/Cancellation Helpers
     // --------------------------------------------------
 
     /// @notice Handle liquidity increase (mint or add liquidity) - issues LCCs
     /// @param s The VTS storage
     /// @param ctx The position context
     /// @param poolKey The pool key
     /// @param params The modify liquidity params
     /// @param p The liquidity increase params (bundled for stack depth)
     function _handleLiquidityIncrease(
         VTSStorage storage s,
         PositionContext memory ctx,
         PoolKey memory poolKey,
         ModifyLiquidityParams memory params,
         VTSPositionLib.LiquidityIncreaseParams memory p
     ) private {
         // Calculate amounts in scoped block
         uint256 amount0;
         uint256 amount1;
         {
             // Negative delta means LP deposited tokens
             amount0 =
                 p.principalDelta.amount0() < 0 ? LiquidityUtils.safeInt128ToUint256(p.principalDelta.amount0()) : 0;
             amount1 =
                 p.principalDelta.amount1() < 0 ? LiquidityUtils.safeInt128ToUint256(p.principalDelta.amount1()) : 0;
             if (amount0 == 0 && amount1 == 0) return;
         }
 
         // Validate commitment backing in scoped block.
         // `touchPosition` updates `positions[positionId].liquidity` to post-modify liquidity before this MM tail runs,
         // so use that total for issued-value (COMMIT-01), not the incremental `params.liquidityDelta` alone.
         {
             (uint160 sqrtPriceX96, int24 currentTick,,) = ctx.poolManager.getSlot0(poolKey.toId());
             uint128 postAddLiquidity = s.positions[p.positionId].liquidity;
             VTSCommitLib.validateLiquidityDelta(
                 s,
                 ctx.oracleHelper,
                 p.commitId,
                 p.positionId,
                 VTSCommitLib.LiquidityDeltaParams({
                     currency0: poolKey.currency0,
                     currency1: poolKey.currency1,
                     sqrtPriceX96: sqrtPriceX96,
                     currentTick: currentTick,
                     tickLower: params.tickLower,
                     tickUpper: params.tickUpper,
                     liquidityDelta: SafeCast.toInt256(postAddLiquidity)
                 }),
                 true
             );
         }
 
         // Issue LCC tokens in scoped block
         {
             if (amount0 > 0) {
                 ctx.liquidityHub.issue(Currency.unwrap(poolKey.currency0), p.owner, amount0);
             }
             if (amount1 > 0) {
                 ctx.liquidityHub.issue(Currency.unwrap(poolKey.currency1), p.owner, amount1);
             }
         }
     }
 
     /// @dev Stack-isolated core for MM decrease vault vs queue split (used by `_handleLiquidityDecrease` and tests).
     // if shortfall <= principal, then yes: settleable + queued == excess
     // if shortfall > principal, then no: settleable + queued < excess
     // Therefore export != excess, and we must accomodate.
     function _computeLiquidityDecreaseRoutingSplit(
         PositionContext memory ctx,
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta
     )
         internal
         view
         returns (
             uint256 retainedPrincipal0,
             uint256 retainedPrincipal1,
             BalanceDelta settleableDelta,
             BalanceDelta queuedDelta,
             BalanceDelta underlyingDeltaSettlement,
             BalanceDelta exportedForSettlementClamp
         )
     {
-        uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
-        uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
+        int128 pa0 = principalDelta.amount0();
+        uint256 principalAmount0 = pa0 > 0 ? LiquidityUtils.safeInt128ToUint256(pa0) : 0;
+        int128 pa1 = principalDelta.amount1();
+        uint256 principalAmount1 = pa1 > 0 ? LiquidityUtils.safeInt128ToUint256(pa1) : 0;
         int128 req0 = requiredSettlementDelta.amount0();
         int128 req1 = requiredSettlementDelta.amount1();
 
         {
             BalanceDelta availableDelta = ctx.marketVault.dryModifyLiquidities(requiredSettlementDelta);
             BalanceDelta rawShortfall = requiredSettlementDelta - availableDelta;
             int128 shortfall0 = rawShortfall.amount0();
             int128 shortfall1 = rawShortfall.amount1();
             if (shortfall0 < 0) shortfall0 = 0;
             if (shortfall1 < 0) shortfall1 = 0;
 
             settleableDelta = toBalanceDelta(req0 - shortfall0, req1 - shortfall1);
 
             uint256 shortfallAmount0 = LiquidityUtils.safeInt128ToUint256(shortfall0);
             uint256 shortfallAmount1 = LiquidityUtils.safeInt128ToUint256(shortfall1);
             retainedPrincipal0 = shortfallAmount0 > principalAmount0 ? principalAmount0 : shortfallAmount0;
             retainedPrincipal1 = shortfallAmount1 > principalAmount1 ? principalAmount1 : shortfallAmount1;
         }
 
         queuedDelta = LiquidityUtils.safeToBalanceDelta(retainedPrincipal0, retainedPrincipal1, false, false);
         underlyingDeltaSettlement = settleableDelta;
         exportedForSettlementClamp = toBalanceDelta(
             SafeCast.toInt128(int256(settleableDelta.amount0()) + int256(queuedDelta.amount0())),
             SafeCast.toInt128(int256(settleableDelta.amount1()) + int256(queuedDelta.amount1()))
         );
     }
 
     /// @notice Handle liquidity decrease (remove liquidity or burn) - cancels LCCs
     /// @dev Stages path-keyed planned cancels for the subsequent PoolManager -> MMPM LCC transfer.
     ///      This helper is correct only because the surrounding MM decrease flow immediately
     ///      performs that transfer after `modifyLiquidity(...)` returns.
     /// @param ctx The position context
     /// @param owner The position owner
     /// @param poolKey The pool key
     /// @param principalDelta The principal delta after fee adjustments
     /// @param requiredSettlementDelta The required settlement delta from touchPosition
     /// @param queueRecipient The recipient for settlement queue (locker)
     /// @return underlyingDeltaSettlement Portion routed to `DynamicCurrencyDelta` (vault-immediate slice only).
     /// @return exportedForSettlementClamp Amount to remove from live `settled`: immediate slice plus queued principal.
     function _handleLiquidityDecrease(
         PositionContext memory ctx,
         address owner,
         PoolKey memory poolKey,
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta,
         address queueRecipient
     ) internal returns (BalanceDelta underlyingDeltaSettlement, BalanceDelta exportedForSettlementClamp) {
         uint256 retainedPrincipal0;
         uint256 retainedPrincipal1;
         (retainedPrincipal0, retainedPrincipal1,,, underlyingDeltaSettlement, exportedForSettlementClamp) =
             _computeLiquidityDecreaseRoutingSplit(ctx, principalDelta, requiredSettlementDelta);
 
         if (LiquidityUtils.isZeroDelta(principalDelta)) {
             return (underlyingDeltaSettlement, exportedForSettlementClamp);
         }
 
-        uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
-        uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
+        int128 pa0 = principalDelta.amount0();
+        uint256 principalAmount0 = pa0 > 0 ? LiquidityUtils.safeInt128ToUint256(pa0) : 0;
+        int128 pa1 = principalDelta.amount1();
+        uint256 principalAmount1 = pa1 > 0 ? LiquidityUtils.safeInt128ToUint256(pa1) : 0;
 
         // 3. Queue settlements via cancelWithQueue
         // Burns LCCs on transfer from PoolManager to owner (MMPM) and queues shortfall for queueRecipient (locker).
         // Only cancel LCCs for tokens that have non-zero principal delta (tokens actually removed from liquidity)
         // Process token0 cancellation
         {
             if (principalAmount0 > 0) {
                 ctx.liquidityHub
                     .planCancelWithQueue(
                         Currency.unwrap(poolKey.currency0),
                         address(ctx.poolManager),
                         owner,
                         principalAmount0,
                         retainedPrincipal0,
                         queueRecipient
                     );
             }
         }
 
         // Process token1 cancellation
         {
             if (principalAmount1 > 0) {
                 ctx.liquidityHub
                     .planCancelWithQueue(
                         Currency.unwrap(poolKey.currency1),
                         address(ctx.poolManager),
                         owner,
                         principalAmount1,
                         retainedPrincipal1,
                         queueRecipient
                     );
             }
         }
 
         // 4. Actual queued amounts are tracked in LiquidityHub as owed to queueRecipient.
         // When _collectAvailableLiquidity is called, underlying is transferred to the recipient.
         // If recipient is MMPM, the balance is synced to the locker's delta.
         // Any shortfall remainder beyond this call's cancellable principal stays in live `settled` (not transient delta).
     }
 }
```

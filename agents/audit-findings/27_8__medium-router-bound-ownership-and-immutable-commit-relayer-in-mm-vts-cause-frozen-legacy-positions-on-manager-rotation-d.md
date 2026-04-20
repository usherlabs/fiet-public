[Medium] Router-bound ownership and immutable commit relayer in MM/VTS cause frozen legacy positions on manager rotation/disablement

# Description

MM-managed positions and commits are permanently keyed to the original MMPositionManager address and commit relayer, preventing a new manager from operating existing positions and potentially freezing funds if the old manager is disabled without a migration path.

Positions are registered and identified using the router (MMPositionManager) address as owner via [PositionLibrary.generateId(owner, params)](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/MMPositionActionsImpl.sol#L621-L621) and [VTSPositionLib._registerPosition](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSPositionLib.sol#L640-L642). [CoreHook passes sender (the manager) into VTSOrchestrator.processPosition](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/CoreHook.sol#L169-L169), persisting owner as the manager address. MM settlement requires [msg.sender == pos.owner in VTSOrchestrator.onMMSettle](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/VTSOrchestrator.sol#L728-L731), and MM operations also enforce the commit’s [authorisedRelayer equals the original router](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L737-L741) ([VTSCommitLib](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSCommitLib.sol#L284-L285) + VTSLifecycleLinkedLib). [Commitment NFTs and approvals are scoped to the manager’s own ERC721](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/MMHelpers.sol#L14-L20), so a new router lacks the legacy NFTs/approvals. As a result, replacing or disabling the original router leaves legacy positions unmanageable (no add/remove liquidity or settlement) unless the old router remains operational or a dedicated migration is provided, leading to potential frozen funds for affected positions.

# Severity

**Impact Explanation:** [Medium] A significant but temporary DoS of withdrawals/settlements for legacy positions can occur during emergency disablement or rotation without a migration; system-wide functionality is not completely broken and permanent freezes are unlikely under trusted, diligent admin operations.

**Likelihood Explanation:** [Medium] Requires an uncommon but realistic operational state (emergency disable/rotation); does not rely on attacker behavior, but on prudent admin responses to critical issues.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Emergency disable of the original MMPositionManager (e.g., to mitigate a critical flaw) followed by deployment of a replacement router: legacy positions owned by the old router cannot be settled or have liquidity removed by the new router due to owner and authorisedRelayer checks, freezing withdrawals until the old router is re-enabled or a migration is implemented.
#### Preconditions / Assumptions
- (a). Legacy positions were created via the original MMPositionManager and registered with pos.owner set to that router
- (b). The commit’s authorisedRelayer is the original router (immutable across renewals)
- (c). Admins perform an emergency disable of the old router and bind a new router
- (d). Uniswap v4 PoolManager and hooks are canonical (per assumptions)

### Scenario 2.
Attempted force settlement of legacy positions via the new router (or any other address) after the old router is disabled: VTSOrchestrator.onMMSettle reverts because msg.sender must equal the stored position owner (the old router), so positions remain frozen until the old router is restored or a migration path exists.
#### Preconditions / Assumptions
- (a). Same as previous: legacy positions owned by the old router and commit’s authorisedRelayer set to the old router
- (b). Old router remains disabled or inaccessible during the operation
- (c). New router (or any other address) attempts to settle/modify the legacy positions
- (d). Uniswap v4 PoolManager and hooks are canonical (per assumptions)

# Proposed fix

## PositionManagerEntrypoint.sol

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
-    address public immutable actionsImpl;
+    address public actionsImpl;
 
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
 
+    /// @notice Admin upgrade of actions implementation; preserves router address to avoid stranding positions.
+    function setActionsImpl(address newImpl) external {
+        if (msg.sender != address(marketFactory)) revert Errors.InvalidSender();
+        if (newImpl == address(0) || newImpl.code.length == 0) revert Errors.InvalidAddress(newImpl);
+        actionsImpl = newImpl;
+    }
+
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

# Related findings

## [Medium] Immutable pool binding to CoreHook/VTSOrchestrator and lack of migration in MarketFactory/CoreHook/VTSOrchestrator causes potentially stuck funds

### Description

Each core pool is permanently bound to a single CoreHook and immutable VTSOrchestrator with no on-chain rebinding or state migration. During pause or forced retirement, non-MM positions with open RFS cannot remove liquidity and cannot settle while paused, leading to stuck funds. A bricking bug in the bound hook/orchestrator would also strand liquidity, as all removes must pass through the embedded hook.

Core pools embed a specific CoreHook address in the PoolKey at creation (MarketFactory._createCorePool), making the hook part of the PoolId. CoreHook holds an immutable VTSOrchestrator reference (ImmutableVTSState), and VTSOrchestrator restricts lifecycle entrypoints to the canonical CoreHook (onlyCoreHook). There is no export/import or rebinding of VTS state. Pause semantics block adds/swaps but allow decreases; however, VTSPositionLib._touchExistingDecrease reverts removal if RFS is open (except authorized MM seizure). Direct-LPs have no settle-only entrypoint while paused and thus cannot close RFS when adds/swaps are disabled, making them unable to remove during prolonged pause. MMs can settle under pause (onMMSettle is not gated by pause) and then remove. If the old hook/orchestrator must be permanently disabled or is bricked, existing positions remain tied to those contracts with no on-chain migration path, potentially resulting in permanently stuck funds.

### Severity

**Impact Explanation:** [High] In scenarios 2 and 3, funds can be permanently frozen due to lack of on-chain rebinding/migration and mandatory hook/orchestrator paths; in scenario 1, funds can be stuck for extended periods when paused and RFS is open.

**Likelihood Explanation:** [Low] Requires rare/exceptional conditions such as prolonged pause without safe unpause windows, a severe incident requiring permanent disablement, or a bricking bug in the removal path; admins are trusted and typically mitigate where possible.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Direct-LP stuck during prolonged pause with open RFS: Admin pauses a pool; a direct-LP with open RFS attempts to remove liquidity. Removal reverts due to RFS gating, and the LP cannot settle while paused (adds/swaps blocked), leaving funds stuck until unpause.
#### Preconditions / Assumptions
- (a). Pool is paused (globally or per-pool)
- (b). Victim is a direct-LP (non-MM) with open RFS on the pool
- (c). No timely unpause window provided to allow settlement or exit

### Scenario 2.
Mandatory retirement without safe unpause: A severe incident forces permanent disablement of the old orchestrator/hook. Old pools remain paused with no safe unpause window. Direct-LPs with open RFS cannot remove or settle, leading to permanently stuck funds; MMs may also be affected depending on operational disablement.
#### Preconditions / Assumptions
- (a). Severe incident mandates permanent disablement of the old orchestrator/hook
- (b). Old pools remain paused with no feasible safe unpause
- (c). Direct-LPs (and possibly MMs) still have positions on old pools

### Scenario 3.
Bricking bug in CoreHook/Orchestrator: A logic bug causes CoreHook._afterRemoveLiquidity or VTSOrchestrator.processPosition to revert on removal. Since the hook is embedded in the PoolId, all removal attempts revert and there is no rebinding or migration path, leaving all positions on the pool stuck.
#### Preconditions / Assumptions
- (a). A bricking bug exists in CoreHook/Orchestrator removal path
- (b). All removal attempts must pass through the embedded hook
- (c). No on-chain rebinding or migration to a fixed orchestrator/hook

### Proposed fix

#### VTSPositionLib.sol

File: `contracts/evm/src/libraries/VTSPositionLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSPositionLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
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
 import {VTSCommitLib} from "./VTSCommitLib.sol";
 import {VTSPositionMMOpsLib} from "./VTSPositionMMOpsLib.sol";
 import {IMarketVault} from "../interfaces/IMarketVault.sol";
 import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
 import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
 
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
 
         // Track pool-wide cumulative deficit principal decrease when cumulativeDeficit is netted.
         // commitmentDeficit is an insolvency gate and is intentionally excluded from totalDeficitPrincipal.
         if (cumulativeDeficitCoverage > 0) {
             uint256 currentPrincipal = paPool.totalDeficitPrincipal.get(tokenIndex);
             // Safely decrement (should not underflow if accounting is consistent)
             uint256 newPrincipal =
                 cumulativeDeficitCoverage > currentPrincipal ? 0 : currentPrincipal - cumulativeDeficitCoverage;
             paPool.totalDeficitPrincipal.set(tokenIndex, newPrincipal);
         }
 
         // Track pool-wide totalSettled aggregate
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
         // - cumulativeDeficitCoverage: decrements pool totalDeficitPrincipal
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
                 paPool.totalDeficitPrincipal.token0 += deficitIncrease;
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
                 paPool.totalDeficitPrincipal.token1 += deficitIncrease;
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
 
     /// @notice Settle both deficit and inflow growth for a position
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     //#olympix-ignore-reentrancy
     function settlePositionGrowths(VTSStorage storage s, IPoolManager poolManager, PositionId positionId) public {
         _settlePositionDeficitGrowth(s, poolManager, positionId);
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
     }
 
     /**
      * @notice Initializes the snapshots for a position. Prevents new positions from inheriting historical tick-indexed growths.
      * @param s The central VTS storage
      * @param poolManager The pool manager contract
      * @param id The id of the position
      */
     function _initPositionSnapshots(VTSStorage storage s, IPoolManager poolManager, PositionId id) internal {
         _checkpointTickIndexedSnapshots(s, poolManager, id);
     }
 
     /// @notice Touch a position to update its state and handle MM-specific operations
     /// @dev Single entry point for position processing - handles registration, linking, fee processing,
     ///      delta accounting, LCC issuance/cancellation, and checkpoint marking
     /// @param s The VTS storage
     /// @param ctx The position context containing dependency references (poolManager, liquidityHub, etc.)
     /// @param p The touchPosition parameters (owner, poolKey, params, callerDelta, feesAccrued, hookData)
     /// @return result The touchPosition result (pos, id)
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
+        // NOTE [mitigation]: During protocol pause, direct-LP positions cannot close RFS (adds/swaps blocked),
+        // so this guard can indefinitely block remove-liquidity. Introduce a pause-safe "settle-only" flow
+        // (facade-authenticated) to increase settled for direct-LP positions before attempting decrease.
+        //
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
 
     /// @dev Isolates the existing-position branch of `touchPosition` in its own stack frame (avoids "stack too deep"
     ///      when composed with mirror transitions).
     function _touchExistingPositionPath(
         VTSStorage storage s,
         PositionContext memory ctx,
         PoolId poolId,
         TouchPositionParams calldata p,
         PositionId positionId,
         Position storage posStorage,
         uint256 initialLiquidity,
         uint128 liq,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         // EXISTING POSITION (active or previously inactive)
 
         // Validate no mismatch if commit ID present.
         if (hookData.isMMOperation && hookData.commitId != posStorage.commitId) {
             revert Errors.InvariantViolated("Invalid operation: Commit ID mismatch");
         }
 
         // Insolvency freeze: do not allow non-seizure MM liquidity changes while commitment deficit persists.
         // Settlement, checkpoint(withCommitment), and seizure paths remain the intended cure/formalise surfaces.
         if (hookData.isMMOperation && !hookData.isSeizing && p.params.liquidityDelta != 0) {
             PositionAccounting storage paGuard = s.positionAccounting[positionId];
             if (paGuard.commitmentDeficit.token0 > 0 || paGuard.commitmentDeficit.token1 > 0) {
                 revert Errors.CommitmentDeficitBlocksLiquidityChange(positionId);
             }
         }
 
         if (p.params.liquidityDelta < 0) {
             // Disallow decreases on previously-inactive positions. (If liq == 0, Uniswap will revert anyway.)
             if (!posStorage.isActive) revert Errors.NotActive(positionId);
             requiredSettlementDelta = _touchExistingDecrease(s, positionId, p.params, liq, hookData);
             // Mirror using live PoolManager liquidity post-modify for both paused and unpaused removes.
             PositionAccounting storage paDec = s.positionAccounting[positionId];
             _applyLiquidityMirrorTransition(s, positionId, paDec, posStorage, initialLiquidity, liq);
         } else {
             (uint128 liveLiquidityBeforeAdd, uint128 nextLiquidity) =
                 _deriveIncreaseTransitionLiquidity(liq, p.params.liquidityDelta);
             if (p.params.liquidityDelta > 0) {
                 // Allow re-activating a previously inactive position by adding liquidity.
                 // Logically required to build on value routing while collecting fees on inactive positions.
                 // Rebase tick-indexed snapshots first so the zero-liquidity interval is not charged/credited to
                 // the newly reactivated liquidity.
                 if (liveLiquidityBeforeAdd == 0) {
                     _checkpointTickIndexedSnapshots(s, ctx.poolManager, positionId);
                 }
                 requiredSettlementDelta =
                     _touchExistingIncrease(s, poolId, positionId, p.params, nextLiquidity, hookData);
             } else {
                 // Allow a no-op when active (Uniswap v4 disallows this when initial liq == 0).
                 // See https://github.com/Uniswap/v4-core/blob/36d790b1a3af38461453a13a6ff395290fbc11b2/src/libraries/Position.sol#L86
                 // Refresh commitment maxima from live liquidity (e.g. mirror desync or post-migration).
                 _trackCommitment(s, positionId, liq);
                 requiredSettlementDelta = BalanceDelta.wrap(0);
             }
             PositionAccounting storage paRem = s.positionAccounting[positionId];
             _applyLiquidityMirrorTransition(
                 s, positionId, paRem, posStorage, uint256(liveLiquidityBeforeAdd), nextLiquidity
             );
         }
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
             requiredSettlementDelta =
                 _touchExistingPositionPath(s, ctx, poolId, p, result.id, posStorage, initialLiquidity, liq, hookData);
         }
 
         if (isNewPosition) {
             _updateStatus(s, result.id, posStorage, initialLiquidity, liq);
         }
 
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

[Source](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/VTSOrchestrator.sol)

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
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
 import {PoolAccounting} from "./types/VTS.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {TokenConfiguration} from "./types/VTS.sol";
 import {VTSAdmin} from "./modules/VTSAdmin.sol";
 import {Extsload} from "v4-periphery/lib/v4-core/src/Extsload.sol";
 
 /// @title VTSOrchestrator
 /// @notice Central state management layer and orchestrator for VTS logic
 /// @dev Adopts Bunni-style pattern: state managed in VTSStorage struct, complex logic delegated to linked libraries
 /// @author Fiet Protocol
 contract VTSOrchestrator is
     PausableVTS,
     VTSAdmin,
     VTSCurrencyDelta,
     Extsload,
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
 
     // --------------------------------------------------
     // CoreHook VTS Functionality
     // --------------------------------------------------
 
+    // TODO [mitigation]: Add a pause-safe, facade-authenticated settleDirectLPPosition(...) entrypoint
+    // (callable only by the market's ProxyHook) that clamps settlement to commitment maxima and updates
+    // direct-LP positions during pause, enabling RFS closure prior to remove-liquidity.
+
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
         returns (Position memory pos, PositionId id, bool isMMPosition)
     {
         isMMPosition = _validateMMOperationLinked(owner, poolKey, hookData);
         (pos, id) = _processPositionLinked(owner, poolKey, params, callerDelta, feesAccrued, hookData);
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
     ) private returns (Position memory pos, PositionId id) {
         VTSCoreHookContext memory ctx = _coreHookContext();
         TouchPositionResult memory result = VTSLifecycleLinkedLib.executeProcessPositionTouch(
             s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData
         );
         pos = result.pos;
         id = result.id;
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

#### CanonicalVault.sol

File: `contracts/evm/src/CanonicalVault.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/CanonicalVault.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
 import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
 import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {ICanonicalVault} from "./interfaces/ICanonicalVault.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
 import {VaultSettlementIntent} from "./types/VTS.sol";
 
 /**
  * @title CanonicalVault
  * @notice Factory-scoped custody layer that owns PoolManager claims and per-market underlying reserves.
  * @dev Owner-level same-underlying credits are fungible at the VTS layer, but actual custody remains market-scoped.
  *      This contract is the bridge between those two truths:
  *      - each market keeps its own underlying sub-ledger in `marketLiquidityReserves`;
  *      - same-underlying credit produced in one market can fund another market only through explicit VTS-provided
  *        settlement intent;
  *      - this contract does not own any hidden transient reconciliation subsystem.
  */
 contract CanonicalVault is ICanonicalVault, ImmutableState, ReentrancyGuardTransient {
     using CurrencySettler for Currency;
     using CurrencyTransfer for Currency;
 
     /// @dev Immutable market metadata used to validate that only registered assets mutate a market's custody state.
     struct MarketConfig {
         address facade;
         address lcc0;
         address lcc1;
         address underlying0;
         address underlying1;
         bool exists;
     }
 
     event MarketRegistered(bytes32 indexed marketId, address facade, address lcc0, address lcc1);
     event LiquidityAddedToVault(bytes32 indexed marketId, address sender, address currency, uint256 amount);
     event LiquidityTakenFromVault(bytes32 indexed marketId, address recipient, address currency, uint256 amount);
     event SwapDeficit(PoolId indexed poolId, address lccToken, address deficitRecipient, uint256 deficitAmount);
 
     ILiquidityHub public immutable liquidityHub;
     address public immutable marketFactory;
 
     mapping(bytes32 => MarketConfig) internal markets;
     mapping(address => bytes32) public facadeToMarket;
     mapping(bytes32 => mapping(address => uint256)) public marketLiquidityReserves;
     mapping(address => uint256) public totalUnderlyingReserves;
 
     constructor(address _poolManager, address _liquidityHub, address _marketFactory)
         ImmutableState(IPoolManager(_poolManager))
     {
         if (_liquidityHub == address(0)) revert Errors.InvalidAddress(_liquidityHub);
         if (_marketFactory == address(0)) revert Errors.InvalidAddress(_marketFactory);
         liquidityHub = ILiquidityHub(_liquidityHub);
         marketFactory = _marketFactory;
     }
 
     modifier onlyFactory() {
         if (msg.sender != marketFactory) revert Errors.InvalidSender();
         _;
     }
 
     modifier onlyMarketFacade(bytes32 marketId) {
         MarketConfig storage cfg = _marketConfig(marketId);
         if (cfg.facade != msg.sender || !IMarketFactory(marketFactory).isMarketFacade(marketId, msg.sender)) {
             revert Errors.InvalidSender();
         }
         _;
     }
 
     modifier onlyVTS() {
         if (msg.sender != address(IMarketFactory(marketFactory).vts())) {
             revert Errors.InvalidSender();
         }
         _;
     }
 
     function registerMarket(
         bytes32 marketId,
         address facade,
         address lcc0,
         address lcc1,
         address underlying0,
         address underlying1
     ) external onlyFactory {
         if (marketId == bytes32(0)) {
             revert Errors.InvariantViolated("CanonicalVault: zero marketId unsupported");
         }
         if (facade == address(0) || lcc0 == address(0) || lcc1 == address(0)) {
             revert Errors.InvalidSender();
         }
         if (markets[marketId].exists || facadeToMarket[facade] != bytes32(0)) {
             revert Errors.InvariantViolated("CanonicalVault: market already registered");
         }
         markets[marketId] = MarketConfig({
             facade: facade, lcc0: lcc0, lcc1: lcc1, underlying0: underlying0, underlying1: underlying1, exists: true
         });
         facadeToMarket[facade] = marketId;
         IERC6909Claims(address(poolManager)).setOperator(facade, true);
         emit MarketRegistered(marketId, facade, lcc0, lcc1);
     }
 
     function inMarketBalanceOf(bytes32 marketId, Currency currency) external view returns (uint256) {
         _assertUnderlyingConfigured(_marketConfig(marketId), currency);
         return marketLiquidityReserves[marketId][Currency.unwrap(currency)];
     }
 
     function dryModifyLiquidities(bytes32 marketId, Currency currency0, Currency currency1, BalanceDelta balanceDelta)
         external
         view
         onlyMarketFacade(marketId)
         returns (BalanceDelta)
     {
         return _dryModifyLiquidities(
             marketId,
             currency0,
             currency1,
             VaultSettlementIntent({
                 requestedDelta: balanceDelta, creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
             })
         );
     }
 
     function dryModifyLiquidities(
         bytes32 marketId,
         Currency currency0,
         Currency currency1,
         VaultSettlementIntent calldata settlementIntent
     ) external view onlyMarketFacade(marketId) returns (BalanceDelta) {
         return _dryModifyLiquidities(marketId, currency0, currency1, settlementIntent);
     }
 
     function modifyLiquidities(
         bytes32 marketId,
         Currency currency0,
         Currency currency1,
         address lcc0,
         address lcc1,
         BalanceDelta balanceDelta,
         address recipient
     ) external onlyMarketFacade(marketId) nonReentrant returns (BalanceDelta usedDelta) {
         VaultSettlementIntent memory settlementIntent = VaultSettlementIntent({
             requestedDelta: balanceDelta, creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
         });
         return _modifyLiquidities(marketId, currency0, currency1, lcc0, lcc1, settlementIntent, recipient);
     }
 
     function modifyLiquidities(
         bytes32 marketId,
         Currency currency0,
         Currency currency1,
         address lcc0,
         address lcc1,
         VaultSettlementIntent calldata settlementIntent,
         address recipient
     ) external onlyMarketFacade(marketId) nonReentrant returns (BalanceDelta usedDelta) {
         return _modifyLiquidities(marketId, currency0, currency1, lcc0, lcc1, settlementIntent, recipient);
     }
 
     function _modifyLiquidities(
         bytes32 marketId,
         Currency currency0,
         Currency currency1,
         address lcc0,
         address lcc1,
         VaultSettlementIntent memory settlementIntent,
         address recipient
     ) internal returns (BalanceDelta usedDelta) {
         MarketConfig storage cfg = _marketConfig(marketId);
         _assertUnderlyingPairConfigured(cfg, currency0, currency1);
         _assertLccPairConfigured(cfg, lcc0, lcc1);
         usedDelta = _dryModifyLiquidities(marketId, currency0, currency1, settlementIntent);
         _modifyLiquidityWithRecipient(marketId, currency0, currency1, settlementIntent, usedDelta, recipient);
         _finaliseModifyLiquidity(marketId, lcc0, lcc1, settlementIntent.requestedDelta, usedDelta, recipient);
     }
 
     function settleObligations(bytes32 marketId, address lcc0, address lcc1) external onlyMarketFacade(marketId) {
         _settleObligationsForLCC(marketId, ILCC(lcc0));
         _settleObligationsForLCC(marketId, ILCC(lcc1));
     }
 
     function settleObligationsForLCC(bytes32 marketId, address lccToken) external onlyMarketFacade(marketId) {
         _settleObligationsForLCC(marketId, ILCC(lccToken));
     }
 
     function settleUnderlyingToVaultFromHub(bytes32 marketId, address lccToken, uint256 amount)
         external
         onlyMarketFacade(marketId)
     {
         if (amount == 0) return;
         _assertLccConfigured(_marketConfig(marketId), lccToken);
         liquidityHub.prepareSettle(lccToken, amount);
         Currency uaCurrency = Currency.wrap(ILCC(lccToken).underlying());
         address payer = uaCurrency.isAddressZero() ? address(this) : address(liquidityHub);
         _settleUnderlyingToVaultFromSender(marketId, uaCurrency, payer, amount);
     }
 
     function cancelLCCWithDeficit(bytes32 marketId, address lccToken, uint256 amount, address deficitRecipient)
         external
         onlyMarketFacade(marketId)
         returns (uint256 amountToCancel)
     {
         _assertLccConfigured(_marketConfig(marketId), lccToken);
         ILCC lcc = ILCC(lccToken);
         uint256 available = marketLiquidityReserves[marketId][lcc.underlying()];
         uint256 deficitAmount;
         if (amount > available) {
             amountToCancel = available;
             deficitAmount = amount - available;
         } else {
             amountToCancel = amount;
         }
 
         if (deficitAmount > 0 && deficitRecipient == address(0)) {
             revert Errors.InvariantViolated("MarketVault: deficit requires recipient");
         }
 
         if (amountToCancel > 0) {
             liquidityHub.cancel(lccToken, address(this), amountToCancel);
         }
 
         if (deficitAmount > 0) {
             Currency.wrap(lccToken).transfer(deficitRecipient, deficitAmount);
             liquidityHub.queueForTransferRecipient(lccToken, deficitRecipient, deficitAmount);
             emit SwapDeficit(PoolId.wrap(marketId), lccToken, deficitRecipient, deficitAmount);
         }
     }
 
     function takeUnderlyingClaims(bytes32 marketId, Currency underlyingCurrency, uint256 amount)
         external
         onlyMarketFacade(marketId)
     {
         if (amount == 0) return;
         _assertUnderlyingConfigured(_marketConfig(marketId), underlyingCurrency);
         underlyingCurrency.take(poolManager, address(this), amount, true);
         _incrementReserve(marketId, underlyingCurrency, amount);
     }
 
     function settleUnderlyingFromClaims(bytes32 marketId, Currency underlyingCurrency, uint256 amount)
         external
         onlyMarketFacade(marketId)
     {
         if (amount == 0) return;
         _assertUnderlyingConfigured(_marketConfig(marketId), underlyingCurrency);
         _decrementReserve(marketId, underlyingCurrency, amount);
         underlyingCurrency.settle(poolManager, address(this), amount, true);
     }
 
     function issueAndSettleLcc(bytes32 marketId, address lccToken, uint256 amount) external onlyMarketFacade(marketId) {
         if (amount == 0) return;
         _assertLccConfigured(_marketConfig(marketId), lccToken);
         liquidityHub.issue(lccToken, address(this), amount);
         Currency.wrap(lccToken).settle(poolManager, address(this), amount, false);
     }
 
     function takeLccFromPoolManager(bytes32 marketId, address lccToken, uint256 amount)
         external
         onlyMarketFacade(marketId)
     {
         if (amount == 0) return;
         _assertLccConfigured(_marketConfig(marketId), lccToken);
         Currency.wrap(lccToken).take(poolManager, address(this), amount, false);
     }
 
     function increaseLiquidityReserve(bytes32 marketId, Currency underlyingCurrency, uint256 amount)
         external
         onlyMarketFacade(marketId)
     {
         if (amount == 0) return;
         _assertUnderlyingConfigured(_marketConfig(marketId), underlyingCurrency);
         _incrementReserve(marketId, underlyingCurrency, amount);
     }
 
     function decreaseLiquidityReserve(bytes32 marketId, Currency underlyingCurrency, uint256 amount)
         external
         onlyMarketFacade(marketId)
     {
         if (amount == 0) return;
         _assertUnderlyingConfigured(_marketConfig(marketId), underlyingCurrency);
         _decrementReserve(marketId, underlyingCurrency, amount);
     }
 
     function _dryModifyLiquidities(
         bytes32 marketId,
         Currency currency0,
         Currency currency1,
         VaultSettlementIntent memory settlementIntent
     ) internal view returns (BalanceDelta) {
         _assertUnderlyingPairConfigured(_marketConfig(marketId), currency0, currency1);
         int128 delta0 = settlementIntent.requestedDelta.amount0();
         int128 delta1 = settlementIntent.requestedDelta.amount1();
         int128 actualDelta0 = delta0;
         int128 actualDelta1 = delta1;
 
         if (delta0 > 0) {
             uint256 requested0 = LiquidityUtils.safeInt128ToUint256(delta0);
             uint256 creditBacked0 = settlementIntent.creditBackedWithdrawal0;
             if (creditBacked0 > requested0) creditBacked0 = requested0;
             uint256 settledRequested0 = requested0 - creditBacked0;
             uint256 settledAvailable0 = marketLiquidityReserves[marketId][Currency.unwrap(currency0)];
             uint256 actual0 = creditBacked0 + Math.min(settledRequested0, settledAvailable0);
             if (actual0 < requested0) actualDelta0 = SafeCast.toInt128(actual0);
         }
 
         if (delta1 > 0) {
             uint256 requested1 = LiquidityUtils.safeInt128ToUint256(delta1);
             uint256 creditBacked1 = settlementIntent.creditBackedWithdrawal1;
             if (creditBacked1 > requested1) creditBacked1 = requested1;
             uint256 settledRequested1 = requested1 - creditBacked1;
             uint256 settledAvailable1 = marketLiquidityReserves[marketId][Currency.unwrap(currency1)];
             uint256 actual1 = creditBacked1 + Math.min(settledRequested1, settledAvailable1);
             if (actual1 < requested1) actualDelta1 = SafeCast.toInt128(actual1);
         }
 
         return toBalanceDelta(actualDelta0, actualDelta1);
     }
 
     function _modifyLiquidityWithRecipient(
         bytes32 marketId,
         Currency currency0,
         Currency currency1,
         VaultSettlementIntent memory settlementIntent,
         BalanceDelta balanceDelta,
         address recipient
     ) internal {
         (int128 amount0, int128 amount1) = (balanceDelta.amount0(), balanceDelta.amount1());
 
         if (amount0 > 0) {
             uint256 requested0 = LiquidityUtils.safeInt128ToUint256(amount0);
             uint256 creditBacked0 = settlementIntent.creditBackedWithdrawal0;
             if (creditBacked0 > requested0) creditBacked0 = requested0;
             uint256 settledBacked0 = requested0 - creditBacked0;
             if (settledBacked0 > 0) {
                 _decrementReserve(marketId, currency0, settledBacked0);
             }
             _takeUnderlyingFromVaultToRecipient(marketId, currency0, recipient, requested0);
         } else if (amount0 < 0) {
             _settleUnderlyingToVaultFromSender(
                 marketId, currency0, address(this), LiquidityUtils.safeInt128ToUint256(amount0)
             );
         }
 
         if (amount1 > 0) {
             uint256 requested1 = LiquidityUtils.safeInt128ToUint256(amount1);
             uint256 creditBacked1 = settlementIntent.creditBackedWithdrawal1;
             if (creditBacked1 > requested1) creditBacked1 = requested1;
             uint256 settledBacked1 = requested1 - creditBacked1;
             if (settledBacked1 > 0) {
                 _decrementReserve(marketId, currency1, settledBacked1);
             }
             _takeUnderlyingFromVaultToRecipient(marketId, currency1, recipient, requested1);
         } else if (amount1 < 0) {
             _settleUnderlyingToVaultFromSender(
                 marketId, currency1, address(this), LiquidityUtils.safeInt128ToUint256(amount1)
             );
         }
     }
 
     function _finaliseModifyLiquidity(
         bytes32 marketId,
         address lcc0,
         address lcc1,
         BalanceDelta balanceDelta,
         BalanceDelta usedDelta,
         address recipient
     ) internal {
         if (balanceDelta.amount0() < 0) {
             _settleObligationsForLCC(marketId, ILCC(lcc0));
         }
         if (balanceDelta.amount1() < 0) {
             _settleObligationsForLCC(marketId, ILCC(lcc1));
         }
         if (recipient == address(liquidityHub)) {
             int128 used0 = usedDelta.amount0();
             if (used0 > 0) liquidityHub.confirmTake(lcc0, LiquidityUtils.safeInt128ToUint256(used0), true);
             int128 used1 = usedDelta.amount1();
             if (used1 > 0) liquidityHub.confirmTake(lcc1, LiquidityUtils.safeInt128ToUint256(used1), true);
         }
     }
 
+    // TODO [mitigation]: Expose a facade-only depositUnderlying(marketId, currency, amount) that
+    // routes into _settleUnderlyingToVaultFromSender(marketId, currency, address(this), amount),
+    // so periphery can move ERC20 into CanonicalVault then formalise as in-market reserve before VTS settlement.
+
     function _settleUnderlyingToVaultFromSender(
         bytes32 marketId,
         Currency underlyingCurrency,
         address sender,
         uint256 amount
     ) internal {
         uint256 senderBalance = underlyingCurrency.balanceOf(sender);
         if (senderBalance < amount) revert Errors.InsufficientLiquidityToSettle();
 
         underlyingCurrency.settle(poolManager, sender, amount, false);
         underlyingCurrency.take(poolManager, address(this), amount, true);
         _incrementReserve(marketId, underlyingCurrency, amount);
 
         emit LiquidityAddedToVault(marketId, sender, Currency.unwrap(underlyingCurrency), amount);
     }
 
     function _takeUnderlyingFromVaultToRecipient(
         bytes32 marketId,
         Currency underlyingCurrency,
         address recipient,
         uint256 amount
     ) internal {
         uint256 availableLiquidity = poolManager.balanceOf(address(this), underlyingCurrency.toId());
         if (availableLiquidity < amount) revert Errors.InsufficientLiquidityToTake();
 
         underlyingCurrency.settle(poolManager, address(this), amount, true);
         if (underlyingCurrency.isAddressZero() && recipient == address(liquidityHub)) {
             underlyingCurrency.take(poolManager, address(this), amount, false);
             (bool ok,) = payable(recipient).call{value: amount}("");
             if (!ok) revert Errors.InvariantViolated("Native transfer to LiquidityHub failed");
         } else {
             underlyingCurrency.take(poolManager, recipient, amount, false);
         }
 
         emit LiquidityTakenFromVault(marketId, recipient, Currency.unwrap(underlyingCurrency), amount);
     }
 
     function _takeUnderlyingFromVaultToHub(bytes32 marketId, ILCC lccToken, uint256 amount, bool shouldEmit) internal {
         Currency uaCurrency = Currency.wrap(lccToken.underlying());
         _decrementReserve(marketId, uaCurrency, amount);
         _takeUnderlyingFromVaultToRecipient(marketId, uaCurrency, address(liquidityHub), amount);
         liquidityHub.confirmTake(address(lccToken), amount, shouldEmit);
     }
 
     function _settleObligationsForLCC(bytes32 marketId, ILCC lccToken) internal {
         _assertLccConfigured(_marketConfig(marketId), address(lccToken));
         uint256 unfunded = liquidityHub.unfundedQueueOfUnderlying(address(lccToken));
         if (unfunded == 0) return;
 
         Currency uaCurrency = Currency.wrap(lccToken.underlying());
         uint256 availableLiquidity = marketLiquidityReserves[marketId][Currency.unwrap(uaCurrency)];
         uint256 amountToSettle = Math.min(unfunded, availableLiquidity);
         if (amountToSettle == 0) return;
         _takeUnderlyingFromVaultToHub(marketId, lccToken, amountToSettle, true);
     }
 
     function _incrementReserve(bytes32 marketId, Currency underlyingCurrency, uint256 amount) internal {
         address underlying = Currency.unwrap(underlyingCurrency);
         marketLiquidityReserves[marketId][underlying] += amount;
         totalUnderlyingReserves[underlying] += amount;
     }
 
     function _decrementReserve(bytes32 marketId, Currency underlyingCurrency, uint256 amount) internal {
         address underlying = Currency.unwrap(underlyingCurrency);
         uint256 current = marketLiquidityReserves[marketId][underlying];
         if (current < amount) revert Errors.InsufficientLiquidityToTake();
         marketLiquidityReserves[marketId][underlying] = current - amount;
         totalUnderlyingReserves[underlying] -= amount;
     }
 
     function _marketConfig(bytes32 marketId) internal view returns (MarketConfig storage cfg) {
         cfg = markets[marketId];
         if (!cfg.exists) revert Errors.InvalidSender();
     }
 
     function _assertUnderlyingConfigured(MarketConfig storage cfg, Currency underlyingCurrency) internal view {
         address underlying = Currency.unwrap(underlyingCurrency);
         if (underlying != cfg.underlying0 && underlying != cfg.underlying1) {
             revert Errors.InvalidSender();
         }
     }
 
     function _assertLccConfigured(MarketConfig storage cfg, address lccToken) internal view {
         if (lccToken != cfg.lcc0 && lccToken != cfg.lcc1) {
             revert Errors.InvalidSender();
         }
     }
 
     function _assertUnderlyingPairConfigured(MarketConfig storage cfg, Currency currency0, Currency currency1)
         internal
         view
     {
         if (Currency.unwrap(currency0) != cfg.underlying0 || Currency.unwrap(currency1) != cfg.underlying1) {
             revert Errors.InvalidSender();
         }
     }
 
     function _assertLccPairConfigured(MarketConfig storage cfg, address lcc0, address lcc1) internal view {
         if (lcc0 != cfg.lcc0 || lcc1 != cfg.lcc1) {
             revert Errors.InvalidSender();
         }
     }
 
     /// @notice Accepts native ETH only from PoolManager, LiquidityHub, or factory-registered protocol bounds.
     /// @dev Unlike `MarketVaultFacade.receive` (fail-closed for all senders), canonical custody allows these trusted
     ///      origins; `address(0)` is not whitelisted here (see `INVARIANTS.md` HUB-02B).
     receive() external payable {
         if (
             msg.sender != address(poolManager) && msg.sender != address(liquidityHub)
                 && !IMarketFactory(marketFactory).bounds(msg.sender)
         ) {
             revert Errors.InvalidEthSender();
         }
     }
 }
```

## [Medium] Immutable per-market facade binding in CanonicalVault/MarketFactory causes stuck reserves and blocked settlements

### Description

CanonicalVault [hard-binds each market to a single facade/proxy-hook](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/CanonicalVault.sol#L103-L111) and [gates all reserve-moving functions to that address](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/CanonicalVault.sol#L74-L80), while MarketFactory [fixes the facade mapping with no rotation path](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/MarketFactory.sol#L269-L271). There is no admin rebind or rescue mechanism. If the facade becomes unusable or must not be called, the market’s reserves and settlement flows are stranded, leading to potentially permanent stuck funds for that market.

When a market is created, MarketFactory [stores one proxy-hook (facade) for the market’s core pool](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/MarketFactory.sol#L269-L271) and [CanonicalVault.registerMarket](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/CanonicalVault.sol#L103-L111) records that facade for the marketId. CanonicalVault’s reserve-moving entrypoints (e.g., modifyLiquidities, settleObligations, settleUnderlyingToVaultFromHub, cancelLCCWithDeficit, take/settle underlying claims) are all protected by [onlyMarketFacade](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/CanonicalVault.sol#L74-L80), which requires both the stored facade match msg.sender and MarketFactory.[isMarketFacade](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/MarketFactory.sol#L527-L533) to return true for that address. MarketFactory provides no function to rotate the proxy hook for an existing market, and CanonicalVault provides no function to rebind the facade or rescue funds. If the bound facade becomes unusable (e.g., bricked by a bug) or must not be used (e.g., emergency deprecation), no other address can move the market’s reserves out of CanonicalVault or fund LiquidityHub via [confirmTake](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/CanonicalVault.sol#L429-L434), leaving settlement queues unserviceable and reserves effectively stuck.

### Severity

**Impact Explanation:** [High] Funds for the affected market can be frozen/blocked with no onchain workaround due to immutable facade binding and onlyMarketFacade gating, breaking settlement functionality and potentially causing permanent stuck funds.

**Likelihood Explanation:** [Low] The high-impact outcome depends on rare/exceptional preconditions (a fully bricked or operationally avoided facade). There is no attacker-driven path or direct incentive; the state is uncommon though plausible.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
A deployed facade (ProxyHook/MarketVaultFacade) is bricked by a bug so that its calls into CanonicalVault revert. Since all CanonicalVault reserve-moving functions require [onlyMarketFacade](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/CanonicalVault.sol#L74-L80), no operations can transfer underlying to LiquidityHub or settle obligations. LiquidityHub cannot receive market-derived reserves ([confirmTake path](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/CanonicalVault.sol#L429-L434) never executes), and queued settlements remain indefinitely blocked.
#### Preconditions / Assumptions
- (a). A market was created and registered; CanonicalVault stored the market’s facade and granted operator rights to that facade.
- (b). The market has positive per-market reserves in CanonicalVault.
- (c). LiquidityHub has nonzero external settlement queues for the market’s LCC (requiring market-derived funding).
- (d). The facade’s external calls needed to operate CanonicalVault revert (e.g., due to a bug), making it unusable.

### Scenario 2.
A severe vulnerability is discovered in the facade; admins decide not to interact with it for safety. There is no way to rebind CanonicalVault or MarketFactory to a new facade for the same marketId, and all reserve-moving functions require the old facade. Reserves remain stranded and settlement queues remain blocked, as admins avoid using the unsafe facade.
#### Preconditions / Assumptions
- (a). A market was created and registered; CanonicalVault stored the market’s facade and MarketFactory fixed the mapping.
- (b). The market has positive per-market reserves in CanonicalVault and pending settlements.
- (c). A critical vulnerability or risk is identified in the facade and admins choose not to call it.
- (d). No onchain mechanism exists to rebind CanonicalVault/MarketFactory to a new facade for this market.

### Scenario 3.
During a planned upgrade, a new facade/market is deployed. Admins attempt to migrate reserves from the old market to the new one. Moving reserves out of CanonicalVault for the old market requires calls from the old facade due to onlyMarketFacade gating. If the old facade is unusable, migration cannot proceed and the old market’s reserves remain stuck, blocking dependent settlements.
#### Preconditions / Assumptions
- (a). A market was created and has accumulated reserves in CanonicalVault.
- (b). Admins deploy a new facade/market and intend to migrate reserves.
- (c). Moving reserves out of CanonicalVault for the old market requires onlyMarketFacade calls from the old facade.
- (d). The old facade is unusable (e.g., bricked/disabled), preventing migration operations.

### Proposed fix

#### CanonicalVault.sol

File: `contracts/evm/src/CanonicalVault.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/CanonicalVault.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
 import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
 import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {ICanonicalVault} from "./interfaces/ICanonicalVault.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
 import {VaultSettlementIntent} from "./types/VTS.sol";
 
 /**
  * @title CanonicalVault
  * @notice Factory-scoped custody layer that owns PoolManager claims and per-market underlying reserves.
  * @dev Owner-level same-underlying credits are fungible at the VTS layer, but actual custody remains market-scoped.
  *      This contract is the bridge between those two truths:
  *      - each market keeps its own underlying sub-ledger in `marketLiquidityReserves`;
  *      - same-underlying credit produced in one market can fund another market only through explicit VTS-provided
  *        settlement intent;
  *      - this contract does not own any hidden transient reconciliation subsystem.
  */
 contract CanonicalVault is ICanonicalVault, ImmutableState, ReentrancyGuardTransient {
     using CurrencySettler for Currency;
     using CurrencyTransfer for Currency;
 
     /// @dev Immutable market metadata used to validate that only registered assets mutate a market's custody state.
     struct MarketConfig {
         address facade;
         address lcc0;
         address lcc1;
         address underlying0;
         address underlying1;
         bool exists;
     }
 
     event MarketRegistered(bytes32 indexed marketId, address facade, address lcc0, address lcc1);
     event LiquidityAddedToVault(bytes32 indexed marketId, address sender, address currency, uint256 amount);
     event LiquidityTakenFromVault(bytes32 indexed marketId, address recipient, address currency, uint256 amount);
     event SwapDeficit(PoolId indexed poolId, address lccToken, address deficitRecipient, uint256 deficitAmount);
 
     ILiquidityHub public immutable liquidityHub;
     address public immutable marketFactory;
 
     mapping(bytes32 => MarketConfig) internal markets;
     mapping(address => bytes32) public facadeToMarket;
     mapping(bytes32 => mapping(address => uint256)) public marketLiquidityReserves;
     mapping(address => uint256) public totalUnderlyingReserves;
 
     constructor(address _poolManager, address _liquidityHub, address _marketFactory)
         ImmutableState(IPoolManager(_poolManager))
     {
         if (_liquidityHub == address(0)) revert Errors.InvalidAddress(_liquidityHub);
         if (_marketFactory == address(0)) revert Errors.InvalidAddress(_marketFactory);
         liquidityHub = ILiquidityHub(_liquidityHub);
         marketFactory = _marketFactory;
     }
 
     modifier onlyFactory() {
         if (msg.sender != marketFactory) revert Errors.InvalidSender();
         _;
     }
 
     modifier onlyMarketFacade(bytes32 marketId) {
         MarketConfig storage cfg = _marketConfig(marketId);
         if (cfg.facade != msg.sender || !IMarketFactory(marketFactory).isMarketFacade(marketId, msg.sender)) {
             revert Errors.InvalidSender();
         }
         _;
     }
 
     modifier onlyVTS() {
         if (msg.sender != address(IMarketFactory(marketFactory).vts())) {
             revert Errors.InvalidSender();
         }
         _;
     }
 
     function registerMarket(
         bytes32 marketId,
         address facade,
         address lcc0,
         address lcc1,
         address underlying0,
         address underlying1
     ) external onlyFactory {
         if (marketId == bytes32(0)) {
             revert Errors.InvariantViolated("CanonicalVault: zero marketId unsupported");
         }
         if (facade == address(0) || lcc0 == address(0) || lcc1 == address(0)) {
             revert Errors.InvalidSender();
         }
         if (markets[marketId].exists || facadeToMarket[facade] != bytes32(0)) {
             revert Errors.InvariantViolated("CanonicalVault: market already registered");
         }
         markets[marketId] = MarketConfig({
             facade: facade, lcc0: lcc0, lcc1: lcc1, underlying0: underlying0, underlying1: underlying1, exists: true
         });
         facadeToMarket[facade] = marketId;
         IERC6909Claims(address(poolManager)).setOperator(facade, true);
         emit MarketRegistered(marketId, facade, lcc0, lcc1);
     }
 
     function inMarketBalanceOf(bytes32 marketId, Currency currency) external view returns (uint256) {
         _assertUnderlyingConfigured(_marketConfig(marketId), currency);
         return marketLiquidityReserves[marketId][Currency.unwrap(currency)];
     }
 
     function dryModifyLiquidities(bytes32 marketId, Currency currency0, Currency currency1, BalanceDelta balanceDelta)
         external
         view
         onlyMarketFacade(marketId)
         returns (BalanceDelta)
     {
         return _dryModifyLiquidities(
             marketId,
             currency0,
             currency1,
             VaultSettlementIntent({
                 requestedDelta: balanceDelta, creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
             })
         );
     }
 
     function dryModifyLiquidities(
         bytes32 marketId,
         Currency currency0,
         Currency currency1,
         VaultSettlementIntent calldata settlementIntent
     ) external view onlyMarketFacade(marketId) returns (BalanceDelta) {
         return _dryModifyLiquidities(marketId, currency0, currency1, settlementIntent);
     }
 
     function modifyLiquidities(
         bytes32 marketId,
         Currency currency0,
         Currency currency1,
         address lcc0,
         address lcc1,
         BalanceDelta balanceDelta,
         address recipient
     ) external onlyMarketFacade(marketId) nonReentrant returns (BalanceDelta usedDelta) {
         VaultSettlementIntent memory settlementIntent = VaultSettlementIntent({
             requestedDelta: balanceDelta, creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
         });
         return _modifyLiquidities(marketId, currency0, currency1, lcc0, lcc1, settlementIntent, recipient);
     }
 
     function modifyLiquidities(
         bytes32 marketId,
         Currency currency0,
         Currency currency1,
         address lcc0,
         address lcc1,
         VaultSettlementIntent calldata settlementIntent,
         address recipient
     ) external onlyMarketFacade(marketId) nonReentrant returns (BalanceDelta usedDelta) {
         return _modifyLiquidities(marketId, currency0, currency1, lcc0, lcc1, settlementIntent, recipient);
     }
 
     function _modifyLiquidities(
         bytes32 marketId,
         Currency currency0,
         Currency currency1,
         address lcc0,
         address lcc1,
         VaultSettlementIntent memory settlementIntent,
         address recipient
     ) internal returns (BalanceDelta usedDelta) {
         MarketConfig storage cfg = _marketConfig(marketId);
         _assertUnderlyingPairConfigured(cfg, currency0, currency1);
         _assertLccPairConfigured(cfg, lcc0, lcc1);
         usedDelta = _dryModifyLiquidities(marketId, currency0, currency1, settlementIntent);
         _modifyLiquidityWithRecipient(marketId, currency0, currency1, settlementIntent, usedDelta, recipient);
         _finaliseModifyLiquidity(marketId, lcc0, lcc1, settlementIntent.requestedDelta, usedDelta, recipient);
     }
 
     function settleObligations(bytes32 marketId, address lcc0, address lcc1) external onlyMarketFacade(marketId) {
         _settleObligationsForLCC(marketId, ILCC(lcc0));
         _settleObligationsForLCC(marketId, ILCC(lcc1));
     }
 
+    /// @notice Factory-gated emergency path to settle both LCC obligations for a market.
+    function emergencySettleAll(bytes32 marketId) external onlyFactory {
+        MarketConfig storage cfg = _marketConfig(marketId);
+        _settleObligationsForLCC(marketId, ILCC(cfg.lcc0));
+        _settleObligationsForLCC(marketId, ILCC(cfg.lcc1));
+    }
+
     function settleObligationsForLCC(bytes32 marketId, address lccToken) external onlyMarketFacade(marketId) {
         _settleObligationsForLCC(marketId, ILCC(lccToken));
     }
 
     function settleUnderlyingToVaultFromHub(bytes32 marketId, address lccToken, uint256 amount)
         external
         onlyMarketFacade(marketId)
     {
         if (amount == 0) return;
         _assertLccConfigured(_marketConfig(marketId), lccToken);
         liquidityHub.prepareSettle(lccToken, amount);
         Currency uaCurrency = Currency.wrap(ILCC(lccToken).underlying());
         address payer = uaCurrency.isAddressZero() ? address(this) : address(liquidityHub);
         _settleUnderlyingToVaultFromSender(marketId, uaCurrency, payer, amount);
     }
 
     function cancelLCCWithDeficit(bytes32 marketId, address lccToken, uint256 amount, address deficitRecipient)
         external
         onlyMarketFacade(marketId)
         returns (uint256 amountToCancel)
     {
         _assertLccConfigured(_marketConfig(marketId), lccToken);
         ILCC lcc = ILCC(lccToken);
         uint256 available = marketLiquidityReserves[marketId][lcc.underlying()];
         uint256 deficitAmount;
         if (amount > available) {
             amountToCancel = available;
             deficitAmount = amount - available;
         } else {
             amountToCancel = amount;
         }
 
         if (deficitAmount > 0 && deficitRecipient == address(0)) {
             revert Errors.InvariantViolated("MarketVault: deficit requires recipient");
         }
 
         if (amountToCancel > 0) {
             liquidityHub.cancel(lccToken, address(this), amountToCancel);
         }
 
         if (deficitAmount > 0) {
             Currency.wrap(lccToken).transfer(deficitRecipient, deficitAmount);
             liquidityHub.queueForTransferRecipient(lccToken, deficitRecipient, deficitAmount);
             emit SwapDeficit(PoolId.wrap(marketId), lccToken, deficitRecipient, deficitAmount);
         }
     }
 
     function takeUnderlyingClaims(bytes32 marketId, Currency underlyingCurrency, uint256 amount)
         external
         onlyMarketFacade(marketId)
     {
         if (amount == 0) return;
         _assertUnderlyingConfigured(_marketConfig(marketId), underlyingCurrency);
         underlyingCurrency.take(poolManager, address(this), amount, true);
         _incrementReserve(marketId, underlyingCurrency, amount);
     }
 
     function settleUnderlyingFromClaims(bytes32 marketId, Currency underlyingCurrency, uint256 amount)
         external
         onlyMarketFacade(marketId)
     {
         if (amount == 0) return;
         _assertUnderlyingConfigured(_marketConfig(marketId), underlyingCurrency);
         _decrementReserve(marketId, underlyingCurrency, amount);
         underlyingCurrency.settle(poolManager, address(this), amount, true);
     }
 
     function issueAndSettleLcc(bytes32 marketId, address lccToken, uint256 amount) external onlyMarketFacade(marketId) {
         if (amount == 0) return;
         _assertLccConfigured(_marketConfig(marketId), lccToken);
         liquidityHub.issue(lccToken, address(this), amount);
         Currency.wrap(lccToken).settle(poolManager, address(this), amount, false);
     }
 
     function takeLccFromPoolManager(bytes32 marketId, address lccToken, uint256 amount)
         external
         onlyMarketFacade(marketId)
     {
         if (amount == 0) return;
         _assertLccConfigured(_marketConfig(marketId), lccToken);
         Currency.wrap(lccToken).take(poolManager, address(this), amount, false);
     }
 
     function increaseLiquidityReserve(bytes32 marketId, Currency underlyingCurrency, uint256 amount)
         external
         onlyMarketFacade(marketId)
     {
         if (amount == 0) return;
         _assertUnderlyingConfigured(_marketConfig(marketId), underlyingCurrency);
         _incrementReserve(marketId, underlyingCurrency, amount);
     }
 
     function decreaseLiquidityReserve(bytes32 marketId, Currency underlyingCurrency, uint256 amount)
         external
         onlyMarketFacade(marketId)
     {
         if (amount == 0) return;
         _assertUnderlyingConfigured(_marketConfig(marketId), underlyingCurrency);
         _decrementReserve(marketId, underlyingCurrency, amount);
     }
 
     function _dryModifyLiquidities(
         bytes32 marketId,
         Currency currency0,
         Currency currency1,
         VaultSettlementIntent memory settlementIntent
     ) internal view returns (BalanceDelta) {
         _assertUnderlyingPairConfigured(_marketConfig(marketId), currency0, currency1);
         int128 delta0 = settlementIntent.requestedDelta.amount0();
         int128 delta1 = settlementIntent.requestedDelta.amount1();
         int128 actualDelta0 = delta0;
         int128 actualDelta1 = delta1;
 
         if (delta0 > 0) {
             uint256 requested0 = LiquidityUtils.safeInt128ToUint256(delta0);
             uint256 creditBacked0 = settlementIntent.creditBackedWithdrawal0;
             if (creditBacked0 > requested0) creditBacked0 = requested0;
             uint256 settledRequested0 = requested0 - creditBacked0;
             uint256 settledAvailable0 = marketLiquidityReserves[marketId][Currency.unwrap(currency0)];
             uint256 actual0 = creditBacked0 + Math.min(settledRequested0, settledAvailable0);
             if (actual0 < requested0) actualDelta0 = SafeCast.toInt128(actual0);
         }
 
         if (delta1 > 0) {
             uint256 requested1 = LiquidityUtils.safeInt128ToUint256(delta1);
             uint256 creditBacked1 = settlementIntent.creditBackedWithdrawal1;
             if (creditBacked1 > requested1) creditBacked1 = requested1;
             uint256 settledRequested1 = requested1 - creditBacked1;
             uint256 settledAvailable1 = marketLiquidityReserves[marketId][Currency.unwrap(currency1)];
             uint256 actual1 = creditBacked1 + Math.min(settledRequested1, settledAvailable1);
             if (actual1 < requested1) actualDelta1 = SafeCast.toInt128(actual1);
         }
 
         return toBalanceDelta(actualDelta0, actualDelta1);
     }
 
     function _modifyLiquidityWithRecipient(
         bytes32 marketId,
         Currency currency0,
         Currency currency1,
         VaultSettlementIntent memory settlementIntent,
         BalanceDelta balanceDelta,
         address recipient
     ) internal {
         (int128 amount0, int128 amount1) = (balanceDelta.amount0(), balanceDelta.amount1());
 
         if (amount0 > 0) {
             uint256 requested0 = LiquidityUtils.safeInt128ToUint256(amount0);
             uint256 creditBacked0 = settlementIntent.creditBackedWithdrawal0;
             if (creditBacked0 > requested0) creditBacked0 = requested0;
             uint256 settledBacked0 = requested0 - creditBacked0;
             if (settledBacked0 > 0) {
                 _decrementReserve(marketId, currency0, settledBacked0);
             }
             _takeUnderlyingFromVaultToRecipient(marketId, currency0, recipient, requested0);
         } else if (amount0 < 0) {
             _settleUnderlyingToVaultFromSender(
                 marketId, currency0, address(this), LiquidityUtils.safeInt128ToUint256(amount0)
             );
         }
 
         if (amount1 > 0) {
             uint256 requested1 = LiquidityUtils.safeInt128ToUint256(amount1);
             uint256 creditBacked1 = settlementIntent.creditBackedWithdrawal1;
             if (creditBacked1 > requested1) creditBacked1 = requested1;
             uint256 settledBacked1 = requested1 - creditBacked1;
             if (settledBacked1 > 0) {
                 _decrementReserve(marketId, currency1, settledBacked1);
             }
             _takeUnderlyingFromVaultToRecipient(marketId, currency1, recipient, requested1);
         } else if (amount1 < 0) {
             _settleUnderlyingToVaultFromSender(
                 marketId, currency1, address(this), LiquidityUtils.safeInt128ToUint256(amount1)
             );
         }
     }
 
     function _finaliseModifyLiquidity(
         bytes32 marketId,
         address lcc0,
         address lcc1,
         BalanceDelta balanceDelta,
         BalanceDelta usedDelta,
         address recipient
     ) internal {
         if (balanceDelta.amount0() < 0) {
             _settleObligationsForLCC(marketId, ILCC(lcc0));
         }
         if (balanceDelta.amount1() < 0) {
             _settleObligationsForLCC(marketId, ILCC(lcc1));
         }
         if (recipient == address(liquidityHub)) {
             int128 used0 = usedDelta.amount0();
             if (used0 > 0) liquidityHub.confirmTake(lcc0, LiquidityUtils.safeInt128ToUint256(used0), true);
             int128 used1 = usedDelta.amount1();
             if (used1 > 0) liquidityHub.confirmTake(lcc1, LiquidityUtils.safeInt128ToUint256(used1), true);
         }
     }
 
     function _settleUnderlyingToVaultFromSender(
         bytes32 marketId,
         Currency underlyingCurrency,
         address sender,
         uint256 amount
     ) internal {
         uint256 senderBalance = underlyingCurrency.balanceOf(sender);
         if (senderBalance < amount) revert Errors.InsufficientLiquidityToSettle();
 
         underlyingCurrency.settle(poolManager, sender, amount, false);
         underlyingCurrency.take(poolManager, address(this), amount, true);
         _incrementReserve(marketId, underlyingCurrency, amount);
 
         emit LiquidityAddedToVault(marketId, sender, Currency.unwrap(underlyingCurrency), amount);
     }
 
     function _takeUnderlyingFromVaultToRecipient(
         bytes32 marketId,
         Currency underlyingCurrency,
         address recipient,
         uint256 amount
     ) internal {
         uint256 availableLiquidity = poolManager.balanceOf(address(this), underlyingCurrency.toId());
         if (availableLiquidity < amount) revert Errors.InsufficientLiquidityToTake();
 
         underlyingCurrency.settle(poolManager, address(this), amount, true);
         if (underlyingCurrency.isAddressZero() && recipient == address(liquidityHub)) {
             underlyingCurrency.take(poolManager, address(this), amount, false);
             (bool ok,) = payable(recipient).call{value: amount}("");
             if (!ok) revert Errors.InvariantViolated("Native transfer to LiquidityHub failed");
         } else {
             underlyingCurrency.take(poolManager, recipient, amount, false);
         }
 
         emit LiquidityTakenFromVault(marketId, recipient, Currency.unwrap(underlyingCurrency), amount);
     }
 
     function _takeUnderlyingFromVaultToHub(bytes32 marketId, ILCC lccToken, uint256 amount, bool shouldEmit) internal {
         Currency uaCurrency = Currency.wrap(lccToken.underlying());
         _decrementReserve(marketId, uaCurrency, amount);
         _takeUnderlyingFromVaultToRecipient(marketId, uaCurrency, address(liquidityHub), amount);
         liquidityHub.confirmTake(address(lccToken), amount, shouldEmit);
     }
 
     function _settleObligationsForLCC(bytes32 marketId, ILCC lccToken) internal {
         _assertLccConfigured(_marketConfig(marketId), address(lccToken));
         uint256 unfunded = liquidityHub.unfundedQueueOfUnderlying(address(lccToken));
         if (unfunded == 0) return;
 
         Currency uaCurrency = Currency.wrap(lccToken.underlying());
         uint256 availableLiquidity = marketLiquidityReserves[marketId][Currency.unwrap(uaCurrency)];
-        uint256 amountToSettle = Math.min(unfunded, availableLiquidity);
+        uint256 claims = poolManager.balanceOf(address(this), uaCurrency.toId());
+        uint256 amountToSettle = Math.min(unfunded, Math.min(availableLiquidity, claims));
         if (amountToSettle == 0) return;
         _takeUnderlyingFromVaultToHub(marketId, lccToken, amountToSettle, true);
     }
 
     function _incrementReserve(bytes32 marketId, Currency underlyingCurrency, uint256 amount) internal {
         address underlying = Currency.unwrap(underlyingCurrency);
         marketLiquidityReserves[marketId][underlying] += amount;
         totalUnderlyingReserves[underlying] += amount;
     }
 
     function _decrementReserve(bytes32 marketId, Currency underlyingCurrency, uint256 amount) internal {
         address underlying = Currency.unwrap(underlyingCurrency);
         uint256 current = marketLiquidityReserves[marketId][underlying];
         if (current < amount) revert Errors.InsufficientLiquidityToTake();
         marketLiquidityReserves[marketId][underlying] = current - amount;
         totalUnderlyingReserves[underlying] -= amount;
     }
 
     function _marketConfig(bytes32 marketId) internal view returns (MarketConfig storage cfg) {
         cfg = markets[marketId];
         if (!cfg.exists) revert Errors.InvalidSender();
     }
 
     function _assertUnderlyingConfigured(MarketConfig storage cfg, Currency underlyingCurrency) internal view {
         address underlying = Currency.unwrap(underlyingCurrency);
         if (underlying != cfg.underlying0 && underlying != cfg.underlying1) {
             revert Errors.InvalidSender();
         }
     }
 
     function _assertLccConfigured(MarketConfig storage cfg, address lccToken) internal view {
         if (lccToken != cfg.lcc0 && lccToken != cfg.lcc1) {
             revert Errors.InvalidSender();
         }
     }
 
     function _assertUnderlyingPairConfigured(MarketConfig storage cfg, Currency currency0, Currency currency1)
         internal
         view
     {
         if (Currency.unwrap(currency0) != cfg.underlying0 || Currency.unwrap(currency1) != cfg.underlying1) {
             revert Errors.InvalidSender();
         }
     }
 
     function _assertLccPairConfigured(MarketConfig storage cfg, address lcc0, address lcc1) internal view {
         if (lcc0 != cfg.lcc0 || lcc1 != cfg.lcc1) {
             revert Errors.InvalidSender();
         }
     }
 
     /// @notice Accepts native ETH only from PoolManager, LiquidityHub, or factory-registered protocol bounds.
     /// @dev Unlike `MarketVaultFacade.receive` (fail-closed for all senders), canonical custody allows these trusted
     ///      origins; `address(0)` is not whitelisted here (see `INVARIANTS.md` HUB-02B).
     receive() external payable {
         if (
             msg.sender != address(poolManager) && msg.sender != address(liquidityHub)
                 && !IMarketFactory(marketFactory).bounds(msg.sender)
         ) {
             revert Errors.InvalidEthSender();
         }
     }
 }
```

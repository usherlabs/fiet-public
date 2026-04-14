# usherlabs: fiet-protocol analysis report

- Repository: `usherlabs/fiet-protocol`
- Analysis date: 2026-04-14
- Vulnerabilities: 3
- Warnings: 5

## Summary

This analysis reviewed the usherlabs: fiet-protocol smart contracts using Octane's automated analysis and included team feedback on findings.

The analysis identified a total of 8 issues (3 vulnerabilities, 5 warnings), including 2 high vulnerabilities.

## Vulnerabilities

### 1. [High] Unsafe uint256→int256 cast for negative tick snapshot in CoreHook afterSwap causes swap DoS

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

[CoreHook snapshots slot0.tick using uint256(int256(tick))](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/CoreHook.sol#L119) and later [reads it via int24(int256(...))](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/CoreHook.sol#L133). For negative ticks this overflows the uint256→int256 cast in Solidity 0.8.x, reverting afterSwap and bricking swaps whenever the pre-swap tick is negative.

This PR introduced transient storage of the Uniswap pool’s slot0.tick in CoreHook. In _beforeSwap, the code [stores TransientSlot.asUint256(TICK_BEFORE_SLOT).tstore(uint256(int256(tickBefore)))](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/CoreHook.sol#L119). In _afterSwap, it [reads with int24(int256(TransientSlot.asUint256(TICK_BEFORE_SLOT).tload()))](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/CoreHook.sol#L133). When tickBefore is negative (valid in Uniswap), uint256(int256(tickBefore)) produces a very large value (MSB=1). Solidity 0.8.x reverts when casting such a uint256 to int256 because it exceeds int256’s positive range. The revert occurs in _afterSwap before calling downstream logic, so the entire swap reverts. As a result, any swap that begins while the pool’s current tick is negative will always revert, causing a trading DoS. This behavior was introduced by the PR when adding tick snapshotting and [passing it into VTSOrchestrator/VTSSwapLib](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/CoreHook.sol#L138).

#### Severity

**Impact Explanation:** [Medium] Swaps revert when pre-swap tick is negative, causing a significant DoS of a core function and direct, material loss of trading fees for LPs during the outage.

**Likelihood Explanation:** [High] Negative ticks are common or reachable through normal market movement; no special constraints or trusted-role misuse are required for the failure to manifest.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Intentional bricking by pushing price below 1: An attacker executes a swap that moves the pool from a non-negative tick into a negative tick. That swap completes because its pre-swap tick was non-negative. From then on, any subsequent swap starts with a negative tick; [CoreHook._afterSwap](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/CoreHook.sol#L133) overflows on uint256→int256 cast and reverts, blocking all further swaps until fixed.
#### Preconditions / Assumptions
- (a). Pool uses CoreHook with beforeSwap/afterSwap enabled
- (b). Initial slot0.tick is non-negative (>= 0)
- (c). Price movement via a swap can push final tick below 0 (price < 1)
- (d). Canonical Uniswap v4 PoolManager semantics apply

### Scenario 2.
Immediate DoS on pools starting negative: A pool initialized with a negative slot0.tick runs [CoreHook._beforeSwap](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/CoreHook.sol#L119) which stores a large uint256 for tick. The first swap attempt executes [CoreHook._afterSwap](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/CoreHook.sol#L133), which reverts on the uint256→int256 cast, so trading is bricked from the outset.
#### Preconditions / Assumptions
- (a). Pool is initialized with slot0.tick < 0
- (b). Pool uses CoreHook with beforeSwap/afterSwap enabled
- (c). Canonical Uniswap v4 PoolManager semantics apply

### Scenario 3.
Unintentional bricking via normal activity: Normal market movement (without any attacker) crosses the price boundary into negative ticks. The crossing swap succeeds (pre-swap tick was non-negative), but subsequent swaps begin at a negative tick and revert in [CoreHook._afterSwap](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/CoreHook.sol#L133) due to the unsafe cast, halting trading and fee generation.
#### Preconditions / Assumptions
- (a). Pool uses CoreHook with beforeSwap/afterSwap enabled
- (b). Normal trading can move price across tick 0 into negative territory
- (c). Canonical Uniswap v4 PoolManager semantics apply

#### Proposed fix

##### CoreHook.sol

File: `contracts/evm/src/CoreHook.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/CoreHook.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
 import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
 import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
 import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";
 import {PositionLibrary} from "./types/Position.sol";
 import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
 import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
 import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
 import {CoreActionFlag} from "./libraries/CoreActionFlag.sol";
 import {ImmutableMarketState} from "./modules/ImmutableMarketState.sol";
 import {ImmutableVTSState} from "./modules/ImmutableVTSState.sol";
 import {MarketHandlerLib} from "./libraries/MarketHandlerLib.sol";
 import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
 import {ICoreHook} from "./interfaces/ICoreHook.sol";
 import {IVaultCoreActionHandler} from "./interfaces/IVaultCoreActionHandler.sol";
 
 /**
  * Core Pool should be aware of Positions.
  * This way it can calculate and manage Liquidity Commitments (C_A(r)) for each Position.
  * Furthermore, we need to know when Direct LP occurs, as this determines whether the underlying native tokens are settled to the Pool Manager.
  */
 contract CoreHook is BaseHook, ImmutableMarketState, ImmutableVTSState, ICoreHook {
     using TransientSlot for *;
     using CurrencySettler for Currency;
     using SafeCast for int256;
     using TransientStateLibrary for IPoolManager;
 
     // Owner will be set to MarketFactory
     constructor(address _poolManager, address _marketFactory, address _vtsOrchestrator)
         BaseHook(IPoolManager(_poolManager))
         ImmutableMarketState(_marketFactory)
         ImmutableVTSState(_vtsOrchestrator)
     {}
 
     function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
         return Hooks.Permissions({
             beforeInitialize: true, // Validate and set global parameters
             afterInitialize: false,
             beforeAddLiquidity: true,
             afterAddLiquidity: true, // Intercept liquidity modifications
             beforeRemoveLiquidity: true,
             afterRemoveLiquidity: true, // Intercept liquidity modifications
             beforeSwap: true,
             afterSwap: true,
             beforeDonate: false,
             afterDonate: false,
             beforeSwapReturnDelta: false,
             afterSwapReturnDelta: false,
             afterAddLiquidityReturnDelta: true,
             afterRemoveLiquidityReturnDelta: true
         });
     }
 
     function _beforeInitialize(address sender, PoolKey calldata, uint160)
         internal
         view
         virtual
         override
         onlyFactoryWithSender(sender)
         returns (bytes4)
     {
         return this.beforeInitialize.selector;
     }
 
     /**
      * For ALL active positions - settle position growths, and queue contribution-based bonuses at hook-time (liquidity modification event)
      * Rationale:
      * - In Uniswap-style accounting, a position's owed fees are (feeGrowthInside - feeGrowthInsideLast) * liquidity.
      * - If we change liquidity/commitment/coverage units first, any pre-add growth would be multiplied by the larger
      *   post-add units, which unfairly dilutes attribution and lets new units capture past accrual.
      * - By settling first, we checkpoint fee/deficit/inflow/proactive/fee-pot growth so all pre-add accrual is
      *   attributed to the pre-add units. Post-add accrual then starts against the updated units.
      * - This preserves fairness and prevents gaming (e.g. adding liquidity just before redeeming to amplify claims).
      */
     function _beforeAddLiquidity(
         address sender,
         PoolKey calldata,
         ModifyLiquidityParams calldata params,
         bytes calldata
     ) internal override returns (bytes4) {
         // Settle growths using pre-modification liquidity so prior accruals are not attributed to new units.
         vtsOrchestrator.settlePositionGrowths(PositionLibrary.generateId(sender, params));
         return this.beforeAddLiquidity.selector;
     }
 
     function _beforeRemoveLiquidity(
         address sender,
         PoolKey calldata,
         ModifyLiquidityParams calldata params,
         bytes calldata
     ) internal override returns (bytes4) {
         // Removal must settle growths against pre-modification liquidity first so already-earned accrual is not
         // reweighted onto the smaller post-removal position. This still applies during pause: remove-liquidity stays
         // available, but only through the canonical hook path that VTSOrchestrator accepts while paused.
         vtsOrchestrator.settlePositionGrowths(PositionLibrary.generateId(sender, params));
         return this.beforeRemoveLiquidity.selector;
     }
 
     function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
         internal
         override
         returns (bytes4, BeforeSwapDelta, uint24)
     {
         // store sqrtP_before, slot0 tick, and liquidity in transient storage for segment processing
         (uint160 sqrtPBefore, int24 tickBefore,,) = StateLibrary.getSlot0(poolManager, key.toId());
         uint128 liqBefore = StateLibrary.getLiquidity(poolManager, key.toId());
         TransientSlot.asUint256(TransientSlots.SQRTP_BEFORE_SLOT).tstore(uint256(sqrtPBefore));
         TransientSlot.asUint256(TransientSlots.TICK_BEFORE_SLOT).tstore(uint256(int256(tickBefore)));
         TransientSlot.asUint256(TransientSlots.LIQ_BEFORE_SLOT).tstore(uint256(liqBefore));
         return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
     }
 
     function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
         internal
         virtual
         override
         returns (bytes4, int128)
     {
         // Read swap snapshot from transient storage then clear immediately to avoid any same-tx "ghost state"
         // interactions if future refactors introduce nested/interleaved swaps.
         uint160 sqrtPBefore = uint160(TransientSlot.asUint256(TransientSlots.SQRTP_BEFORE_SLOT).tload());
-        int24 tickBefore = int24(int256(TransientSlot.asUint256(TransientSlots.TICK_BEFORE_SLOT).tload()));
+        // Safely decode signed int24 tick from transient storage without triggering uint256->int256 overflow.
+        uint256 __tickRaw = TransientSlot.asUint256(TransientSlots.TICK_BEFORE_SLOT).tload();
+        int256 __tickSigned;
+        assembly ("memory-safe") {
+            __tickSigned := signextend(2, __tickRaw)
+        }
+        int24 tickBefore = int24(__tickSigned);
         uint128 liqBefore = uint128(TransientSlot.asUint256(TransientSlots.LIQ_BEFORE_SLOT).tload());
         TransientSlot.asUint256(TransientSlots.SQRTP_BEFORE_SLOT).tstore(0);
         TransientSlot.asUint256(TransientSlots.TICK_BEFORE_SLOT).tstore(0);
         TransientSlot.asUint256(TransientSlots.LIQ_BEFORE_SLOT).tstore(0);
         vtsOrchestrator.afterCoreSwap(key, params, delta, sqrtPBefore, liqBefore, tickBefore);
 
         // Check if this is a direct core pool swap, and if it is, notify canonical vault handler.
         address proxyHook = _getProxyHook(key);
         if (CoreActionFlag.isDirectCoreAction(proxyHook)) {
             _notifyDirectSwap(proxyHook, key, delta);
         }
 
         return (this.afterSwap.selector, 0);
     }
 
     /// @notice The hook called after liquidity is added
     /// @param sender The initial msg.sender for the add liquidity call
     /// @param key The key for the pool
     /// @param params The parameters for adding liquidity
     /// @param delta The caller's balance delta after adding liquidity; the sum of principal delta, fees accrued, and hook delta
     /// @param feesAccrued The fees accrued since the last time fees were collected from this position
     /// @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be passed on to the hook
     /// @return bytes4 The function selector for the hook
     /// @return BalanceDelta The hook's delta in token0 and token1. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
     function _afterAddLiquidity(
         address sender,
         PoolKey calldata key,
         ModifyLiquidityParams calldata params,
         BalanceDelta delta,
         BalanceDelta feesAccrued,
         bytes calldata hookData
     ) internal virtual override returns (bytes4, BalanceDelta) {
         // Update VTS position state with registration/update based on actual pool id
         // Pass callerDelta and feesAccrued for consolidated delta management
         // Note: Pause check is enforced in VTSOrchestrator.processPosition
         (,, BalanceDelta feeAdj, bool isMMPosition) =
             vtsOrchestrator.processPosition(sender, key, params, delta, feesAccrued, hookData);
 
         // only add direct liquidity if this is not an MM position operation
         if (!isMMPosition) {
             IVaultCoreActionHandler(_getProxyHook(key)).handleAddLiquidity();
         }
 
         return (this.afterAddLiquidity.selector, feeAdj);
     }
 
     /// @notice The hook called after liquidity is removed
     /// @dev Allow removal of liquidity even when the market is paused.
     /// @param sender The initial msg.sender for the remove liquidity call
     /// @param key The key for the pool
     /// @param params The parameters for removing liquidity
     /// @param delta The caller's balance delta after removing liquidity; the sum of principal delta, fees accrued, and hook delta
     /// @param feesAccrued The fees accrued since the last time fees were collected from this position
     /// @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be be passed on to the hook
     /// @return bytes4 The function selector for the hook
     /// @return BalanceDelta The hook's delta in token0 and token1. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
     function _afterRemoveLiquidity(
         address sender,
         PoolKey calldata key,
         ModifyLiquidityParams calldata params,
         BalanceDelta delta,
         BalanceDelta feesAccrued,
         bytes calldata hookData
     ) internal virtual override returns (bytes4, BalanceDelta) {
         // All liquidity modifications now share the same VTS entrypoint; pause policy is enforced in touchPosition.
         (,, BalanceDelta feeAdj,) = vtsOrchestrator.processPosition(sender, key, params, delta, feesAccrued, hookData);
 
         // NOTE: We deliberately do NOT notify ProxyHook on direct-LP removals.
         // Underlying liquidity is sourced during unwrap via market liquidity, keeping a single settlement conduit.
 
         return (this.afterRemoveLiquidity.selector, feeAdj);
     }
 
     // Helper function to get the proxy hook address from the core pool key
     function _getProxyHook(PoolKey calldata corePoolKey) internal view returns (address) {
         return MarketHandlerLib.getProxyHook(marketFactory, corePoolKey);
     }
 
     /// @dev Emits direct swap lane fact to canonical vault handler for obligation follow-up.
     function _notifyDirectSwap(address proxyHook, PoolKey calldata key, BalanceDelta delta) internal {
         bool isZeroForOne = delta.amount0() < 0;
         address lccTokenIn = isZeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
         IVaultCoreActionHandler(proxyHook).handleSwap(lccTokenIn);
     }
 
     /// @notice Settle hook deltas to fee pot by minting/burning ERC6909 claims
     /// @dev Called after modifyLiquidity returns to clear PoolManager deltas.
     ///      PoolManager credits/debits hook deltas after the hook returns, so this must be
     ///      called from outside the hook callback (e.g. from PositionManagerImpl).
     ///      - If delta > 0 (credit): mint ERC6909 claims (consumes positive delta)
     ///      - If delta < 0 (debt): burn ERC6909 claims to clear negative delta
     /// @param key The pool key for the currencies to settle
     function settleHookDeltasToPot(PoolKey calldata key) external onlyFactory {
         // Settle CoreHook's deltas (from hook return value adjustments)
         address target = address(this);
         // Read target's deltas from PoolManager's transient storage
         int256 delta0 = poolManager.currencyDelta(target, key.currency0);
         int256 delta1 = poolManager.currencyDelta(target, key.currency1);
 
         // Settle currency0 delta
         if (delta0 > 0) {
             // Credit: mint ERC6909 claims to target (consumes positive delta)
             key.currency0.take(poolManager, target, uint256(delta0), true);
         } else if (delta0 < 0) {
             // Debt: burn ERC6909 claims from target to clear negative delta
             key.currency0.settle(poolManager, target, uint256(-delta0), true);
         }
 
         // Settle currency1 delta
         if (delta1 > 0) {
             // Credit: mint ERC6909 claims to target (consumes positive delta)
             key.currency1.take(poolManager, target, uint256(delta1), true);
         } else if (delta1 < 0) {
             // Debt: burn ERC6909 claims from target to clear negative delta
             key.currency1.settle(poolManager, target, uint256(-delta1), true);
         }
     }
 }
```

### 2. [High] Endpoint-only gating of unwrapTo in LiquidityHub causes frozen native-backed LCC for non-payable holders

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

The PR made all [LiquidityHub.unwrapTo(...)](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L640-L646) overloads [endpoint-only](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L140-L147), removing the only generic way for ordinary holders to direct native payouts to a payable recipient or choose a different queue owner. Non-payable contracts holding native-backed LCC can no longer redeem: [unwrap(...)](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L618-L620) may revert on ETH push, and queued settlements remain unserviceable since [processSettlementFor](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/LiquidityHubLib.sol#L572) always pushes native ETH to the same non-payable recipient.

This PR introduced a restriction that all [LiquidityHub.unwrapTo(...)](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L640-L646) overloads require the caller to be a protocol endpoint. Direct users are forced to use [unwrap(lcc, amount)](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L618-L620), which hardcodes both the immediate payout recipient and any queued settlement owner to msg.sender. For native-backed LCC, unwrap [tries to push native ETH to msg.sender](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L600-L606); a non-payable recipient causes the transaction to revert. If liquidity is unavailable and the unwrap queues instead, later settlement via [processSettlementFor(lcc, recipient, maxAmount)](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/LiquidityHubLib.sol#L572) again pushes native ETH to the same non-payable recipient and reverts, leaving the claim permanently unserviceable. LCC transfers are restricted ([non-protocol → non-protocol transfers are disallowed](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LCC.sol#L194)), so an ordinary holder cannot freely move LCC to a payable EOA first. No generic protocol-provided endpoint helper exists to bridge this gap. This is a functional regression created by the PR’s endpoint-only gating of unwrapTo and can result in frozen funds for non-payable holders of native-backed LCC.

#### Severity

**Impact Explanation:** [High] For affected holders (non-payable contracts), principal funds can be frozen with no in-protocol workaround once queued; the core redemption path for those users is unusable.

**Likelihood Explanation:** [Medium] Requires the holder to be a non-payable contract, use a native-backed LCC, and attempt redemption. These are uncommon but realistic and plausible conditions.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Immediate unwrap reverts: A non-payable contract holding native-backed LCC calls [LiquidityHub.unwrap(lcc, amount)](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L618-L620) while immediate liquidity is available. The function [attempts to send native ETH to msg.sender](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L600-L606) and reverts due to non-payable recipient, preventing redemption.
#### Preconditions / Assumptions
- (a). The LCC is native-backed (underlying == address(0))
- (b). The holder is a non-payable contract (cannot receive ETH)
- (c). The holder has a positive LCC balance
- (d). Sufficient immediate liquidity exists to pay part or all of the unwrap

### Scenario 2.
Queued settlement cannot be redeemed: A non-payable contract calls [LiquidityHub.unwrap(lcc, amount)](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L618-L620) during low liquidity, creating a queue keyed to the same non-payable address. Later, [processSettlementFor(lcc, recipient, maxAmount)](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/LiquidityHubLib.sol#L572) attempts to push native ETH to that address and reverts, leaving the queued claim permanently unserviceable.
#### Preconditions / Assumptions
- (a). The LCC is native-backed (underlying == address(0))
- (b). The holder is a non-payable contract (cannot receive ETH)
- (c). The holder has a positive LCC balance
- (d). At unwrap time, immediate liquidity is insufficient so the shortfall queues
- (e). Later, market-derived reserves become available for settlement

### Scenario 3.
Automated settlement repeatedly fails: The reactive/destination settlement processor repeatedly calls [processSettlementFor](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/LiquidityHubLib.sol#L572) for a non-payable recipient. Each attempt reverts on native ETH push, leaving funds stuck and causing repeated operational failures for that key.
#### Preconditions / Assumptions
- (a). The LCC is native-backed (underlying == address(0))
- (b). The holder is a non-payable contract (cannot receive ETH)
- (c). A queued settlement exists for this holder
- (d). Automated settlement infrastructure calls processSettlementFor for that (lcc, recipient) pair

#### Proposed fix

##### LiquidityHub.sol

File: `contracts/evm/src/LiquidityHub.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
 import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {LCCFactoryLib, LCCFactoryLinkedLib} from "./libraries/LCCFactoryLib.sol";
 import {LiquidityHubLib} from "./libraries/LiquidityHubLib.sol";
 import {LiquidityHubLinkedLib} from "./libraries/LiquidityHubLinkedLib.sol";
 import {LiquidityHubStorage, Market, UnderlyingReserve} from "./types/Liquidity.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {IMarketVault} from "./interfaces/IMarketVault.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {BoundRegistry} from "./modules/BoundRegistry.sol";
 import {Bounds} from "./libraries/Bounds.sol";
 
 /**
  * @title LiquidityHub
  * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
  * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
  */
 contract LiquidityHub is BoundRegistry, Ownable, ReentrancyGuardTransient {
     using CurrencyTransfer for Currency;
 
     // ============ UNIFIED STATE ============
     LiquidityHubStorage internal s;
 
     IOracleHelper public immutable oracleHelper;
 
     event FactorySet(address indexed factory, bool enabled);
     event LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId);
     event LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId);
     event SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementAnnulled(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementProcessed(
         address indexed lcc, address indexed recipient, uint256 settledAmount, uint256 requestedAmount
     );
     event LccWrappedWith(address indexed lcc, address indexed withLCC, address from, address to, uint256 amount);
     event LccWrapped(address indexed lcc, address from, address to, uint256 amount);
     event LccUnwrapped(address indexed lcc, address from, address to, uint256 amount);
 
     // IMPORTANT NOTE: The LiquidityHub is agnostic/unaware of the end account.
     // Similarly to how PoolManager leverages periphery contracts to manage end-account balances, the LiquidityHub aggregates balances, and uses LCCs to track account balances in a hub-and-spoke model.
 
     // Map of market factories
     mapping(address => bool) public isFactory;
 
     /**
      * @notice Constructs the LiquidityHub contract
      * @param _oracleHelper The oracle helper contract address
      * @param _nativeAssetName The name of the native asset (e.g., "Ether")
      * @param _nativeAssetSymbol The symbol of the native asset (e.g., "ETH")
      * @param _nativeAssetDecimals The decimals of the native asset (typically 18)
      * @param _initialOwner The initial owner of the contract
      */
     constructor(
         address _oracleHelper,
         string memory _nativeAssetName,
         string memory _nativeAssetSymbol,
         uint8 _nativeAssetDecimals,
         address _initialOwner
     ) Ownable(_initialOwner) {
         oracleHelper = IOracleHelper(_oracleHelper);
         LCCFactoryLib.initNativeAsset(s, _nativeAssetName, _nativeAssetSymbol, _nativeAssetDecimals);
     }
 
     /**
      * @notice Modifier to restrict access to registered factory contracts only
      */
     modifier onlyFactory() {
         _onlyFactory();
         _;
     }
 
     function _onlyFactory() internal view {
         if (!isFactory[_msgSender()]) {
             revert Errors.InvalidSender();
         }
     }
 
     /// Override from BoundRegistry
     function _lccMarket(address lcc) internal view override returns (bytes32 id, address factory) {
         Market memory market = s.lccToMarket[lcc];
         return (market.id, market.factory);
     }
 
     /// Override from BoundRegistry
     function setBoundLevel(address who, uint8 level) external override onlyFactory {
         // `BoundRegistry._setBoundLevel` enforces EXEMPT/DEX immutability and first-assignment-from-NONE.
         // The stronger policy that EXEMPT/DEX only arise from hardcoded setup / integration paths must be expressed by
         // the specific `MarketFactory` implementation using this hub; registered factories are trusted for that setup policy.
         // Queue-owner safety when moving an address into exempt remains an operational concern (not indexed on-chain).
         _setBoundLevel(msg.sender, who, level);
     }
 
     /// Override from BoundRegistry
     function setBoundLevels(address[] calldata who, uint8 level) external override onlyFactory {
         for (uint256 i = 0; i < who.length; i++) {
             _setBoundLevel(msg.sender, who[i], level);
         }
     }
 
     /**
      * @notice Modifier to ensure the provided LCC address is valid
      * @param lcc The LCC token address to validate
      */
     modifier onlyValidLcc(address lcc) {
         LiquidityHubLib.assertValidLcc(s, lcc);
         _;
     }
 
     /**
      * @notice Modifier to restrict access to issuers of a specific LCC token
      * @param lcc The LCC token address to check issuer status for
      */
     modifier onlyIssuer(address lcc) {
         _onlyIssuer(lcc);
         _;
     }
 
     function _onlyIssuer(address lcc) internal view {
         // Strict invariant: issuer-gated paths must never operate on invalid/uninitialised LCCs.
         LiquidityHubLib.assertValidLcc(s, lcc);
         if (!LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender)) {
             revert Errors.NotApproved(msg.sender);
         }
     }
 
     /**
      * @dev All `unwrapTo` overloads are endpoint-mediated on-behalf-of flows (e.g. `MMPositionManager`).
      *      Direct users unwrap via `unwrap(...)` which queues shortfalls to the caller.
      *      Caller must be `BOUND_ENDPOINT` in the LCC's market factory namespace (not EXEMPT/DEX).
      */
     function _onlyUnwrapToEndpoint(address lcc) internal view {
         if (boundLevelOfLcc(lcc, _msgSender()) != Bounds.BOUND_ENDPOINT) {
             revert Errors.InvalidSender();
         }
     }
 
     // ============ PUBLIC ACCESSORS ============
 
     /**
      * @notice Returns the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address, or address(0) if not found
      */
     function marketUnderlyingToLCC(bytes32 marketId, address underlying) external view returns (address) {
         return s.marketUnderlyingToLCC[marketId][underlying];
     }
 
     /**
      * @notice Returns the underlying asset address for a given LCC token
      * @param lcc The LCC token address
      * @return The underlying asset address (address(0) for native ETH)
      */
     function lccToUnderlying(address lcc) public view returns (address) {
         return s.lccToUnderlying[lcc];
     }
 
     /**
      * @notice Returns the Market struct for a given LCC token
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function lccToMarket(address lcc) external view returns (bytes32, address) {
         return _lccMarket(lcc);
     }
 
     /**
      * @notice
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function getFactory(address lcc0, address lcc1) external view returns (IMarketFactory) {
         address factory0 = s.lccToMarket[lcc0].factory;
         address factory1 = s.lccToMarket[lcc1].factory;
         if (factory0 != factory1) {
             revert Errors.InvariantViolated("LCCs are not from the same market");
         }
         return IMarketFactory(factory0);
     }
 
     /**
      * @notice Checks if an address is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @param issuer The address to check
      * @return True if the address is an issuer, false otherwise
      */
     function issuers(address lcc, address issuer) external view returns (bool) {
         return s.issuers[lcc][issuer];
     }
 
     /**
      * @notice Gets the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address
      */
     function getLCC(bytes32 marketId, address underlying) external view returns (address) {
         return LCCFactoryLib.getLCC(s, marketId, underlying);
     }
 
     /**
      * @notice Gets the underlying asset address for a given LCC token
      * @param lccToken The LCC token address
      * @return The underlying asset address
      */
     function getUnderlying(address lccToken) external view returns (address) {
         return LCCFactoryLib.getUnderlying(s, lccToken);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function isLCC(address lcc) external view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Returns the direct supply (wrapped underlying) for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of direct supply
      */
     function directSupply(address lcc) external view returns (uint256) {
         return s.directSupply[lcc];
     }
 
     /**
      * @notice Returns the shared reserve of underlying assets for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of underlying assets held in reserve for this LCC
      */
     function reserveOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return reserve.direct + reserve.marketDerived;
     }
 
     /**
      * @notice Returns the split underlying reserve tuple for a given LCC token
      * @param lcc The LCC token address
      * @return direct The reserve component backing direct/wrapped supply
      * @return marketDerived The reserve component mobilised from market-derived flows
      */
     function reserveOfUnderlyingTuple(address lcc)
         external
         view
         onlyValidLcc(lcc)
         returns (uint256 direct, uint256 marketDerived)
     {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return (reserve.direct, reserve.marketDerived);
     }
 
     /**
      * @notice Returns the queued settlement amount for a specific LCC and recipient
      * @param lcc The LCC token address
      * @param recipient The recipient address
      * @return The amount queued for settlement
      */
     function settleQueue(address lcc, address recipient) external view returns (uint256) {
         return s.settleQueue[lcc][recipient];
     }
 
     /**
      * @notice Returns the total queued settlement amount for a given LCC token
      * @param lcc The LCC token address
      * @return The total amount queued across all recipients
      */
     function totalQueued(address lcc) external view returns (uint256) {
         return s.totalQueued[lcc];
     }
 
     /**
      * @notice Returns the total queued settlement debt for the underlying of a given LCC
      * @param lcc The LCC token address
      * @return The total queued debt aggregated across all LCCs sharing the same underlying
      */
     function queueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         return s.queueOfUnderlying[s.lccToUnderlying[lcc]];
     }
 
     /**
      * @notice Returns the unfunded queued debt for the underlying of a given LCC
      * @dev Unfunded debt is `max(queueOfUnderlying - marketDerivedReserve, 0)` at the shared-underlying level.
      * @param lcc The LCC token address
      * @return The remaining underlying shortfall that still needs market-to-Hub mobilisation
      */
     function unfundedQueueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         address underlying = s.lccToUnderlying[lcc];
         uint256 queued = s.queueOfUnderlying[underlying];
         uint256 reserve = s.reserveOfUnderlying[underlying].marketDerived;
         return queued > reserve ? queued - reserve : 0;
     }
 
     // ============ ADMIN FUNCTIONS ============
 
     /**
      * @notice Sets or removes a factory address from the allowed factories list
      * @param factory The factory address to enable or disable
      * @param enabled Whether the factory should be enabled (true) or disabled (false)
      */
     function setFactory(address factory, bool enabled) external onlyOwner {
         isFactory[factory] = enabled;
         emit FactorySet(factory, enabled);
     }
 
     /**
      * @notice Creates LCC token pair for a market
      * @param marketRef The market reference (bytes from proxyHookAddress)
      * @param underlyingAsset0 The first underlying asset address
      * @param underlyingAsset1 The second underlying asset address
      * @param marketName The market name
      * @param initialIssuers Array of addresses to set as issuers for both LCC tokens
      * @return lccToken0 The first LCC token address
      * @return lccToken1 The second LCC token address
      */
     function createLCCPair(
         bytes memory marketRef,
         address underlyingAsset0,
         address underlyingAsset1,
         string memory marketName,
         address[] memory initialIssuers
     ) external onlyFactory returns (address lccToken0, address lccToken1) {
         address resilientOracleAddress = oracleHelper.oracle();
         address factory = _msgSender();
         address[2] memory underlyingPair = [underlyingAsset0, underlyingAsset1];
         lccToken0 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 0, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
         lccToken1 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 1, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
 
         // Emit events for LCC creation
         emit LCCCreated(underlyingAsset0, lccToken0, s.lccToMarket[lccToken0].id);
         emit LCCCreated(underlyingAsset1, lccToken1, s.lccToMarket[lccToken1].id);
     }
 
     /**
      * @notice Initializes the mapping from LCC tokens to Market (with ID and Ref)
      * @dev Order-insensitive: `lccToken0` and `lccToken1` are treated independently; no `(0,1)` lane semantics exist here.
      *      Canonical market ordering (for pair lanes) is defined by the core pool key in `MarketFactory`, not by argument order.
      * @param lccToken0 The first LCC token address
      * @param lccToken1 The second LCC token address
      * @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
      * @param marketRef The market reference (bytes from proxyHookAddress)
      */
     function initialize(address lccToken0, address lccToken1, bytes32 marketId, bytes memory marketRef)
         external
         onlyFactory
     {
         LCCFactoryLib.initialize(s, lccToken0, lccToken1, marketId, marketRef, _msgSender());
     }
 
     // ============ INTERNAL HELPERS (delegate to library) ============
 
     /**
      * @notice Checks if the current caller is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @return True if the caller is an issuer, false otherwise
      */
     function _isCallerIssuer(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function _isValidLcc(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Mints LCC tokens to an address
      * @param lccToken The LCC token address
      * @param to The address to mint tokens to
      * @param directAmount The amount to mint as direct supply
      * @param marketAmount The amount to mint as market-derived supply
      */
     function _mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.mint(lccToken, to, directAmount, marketAmount);
     }
 
     /**
      * @notice Burns LCC tokens from an address
      * @param lccToken The LCC token address
      * @param from The address to burn tokens from
      * @param directAmount The amount to burn from direct supply
      * @param marketAmount The amount to burn from market-derived supply
      */
     function _burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.burn(lccToken, from, directAmount, marketAmount);
     }
 
     /**
      * @notice Gets the total balance (wrapped + market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return The total balance
      */
     function _balanceOf(address lccToken, address account) internal view returns (uint256) {
         return LCCFactoryLib.balanceOf(lccToken, account);
     }
 
     /**
      * @notice Gets the bucketed balances (wrapped and market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return wrapped The wrapped (direct) balance
      * @return marketDerived The market-derived balance
      */
     function _balancesOf(address lccToken, address account)
         internal
         view
         returns (uint256 wrapped, uint256 marketDerived)
     {
         return LCCFactoryLib.balancesOf(lccToken, account);
     }
 
     function _assertWrapRecipientNotDexSink(address lcc, address to) internal view {
         if (Bounds.isDex(boundLevel(s.lccToMarket[lcc].factory, to))) {
             revert Errors.DirectWrapToDexNotAllowed(to);
         }
     }
 
     // ============ TRADER FUNCTIONS ============
 
     // DirectLPs and Traders engaging the CorePool directly will need LCC. LCC is 1:1 with the underlying asset.
     /**
      * @dev Internal function to wrap underlying assets into LCC tokens
      * @param lcc The LCC token address to wrap into
      * @param to The address receiving the LCC tokens
      * @param amount The amount of underlying assets to wrap
      */
     function _wrap(address lcc, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         address underlying = s.lccToUnderlying[lcc];
         bool isNativeAsset = underlying == address(0);
 
         // Mint-time ingress to the DEX sink bypasses LCC transfer hooks.
         // Reject it until there is a safe settlement path that can run under PoolManager lock constraints.
         _assertWrapRecipientNotDexSink(lcc, to);
 
         // throw error if the native ETH is insufficient and it is a native ETH backed LCC
         if (isNativeAsset) {
             if (msg.value != amount) {
                 revert Errors.InvalidAmount(0, 0);
             }
         } else {
             if (msg.value != 0) {
                 revert Errors.InvalidAmount(0, 0);
             }
             // Use CurrencyTransfer which has Permit2 fallback for ERC20 transfers
             Currency.wrap(underlying).transferFrom(from, address(this), amount);
         }
 
         s.directSupply[lcc] += amount;
         s.reserveOfUnderlying[underlying].direct += amount;
 
         // mint some tokens
         _mint(lcc, to, amount, 0);
 
         emit LccWrapped(lcc, from, to, amount);
     }
 
     function wrapTo(address lcc, address to, uint256 amount) external payable nonReentrant {
         _wrap(lcc, to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens and sends them to a specified recipient
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address
      * @param amount The amount of underlying assets to wrap
      */
     function wrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller
      * @param lcc The LCC token address
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address lcc, uint256 amount) external payable nonReentrant {
         _wrap(lcc, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address underlying, bytes32 marketId, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), amount);
     }
 
     /**
      * @notice Internal function to wrap LCC using another LCC as backing, with O(1) flattening and netting
      * @dev Delegates to LiquidityHubLib.wrapWithLogic - heavy logic moved to library
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The address receiving the target LCC
      * @param amount The amount to wrap
      */
     function _wrapWith(address lcc, address withLCC, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
 
         // wrapWithTo shares the same mint surface as direct wrap and must not bypass DEX ingress handling.
         _assertWrapRecipientNotDexSink(lcc, to);
 
         // Performs all necessary validation and preparation
         LiquidityHubLib.WrapWithContext memory ctx =
             LiquidityHubLinkedLib.wrapWithPrepare(s, lcc, withLCC, from, amount);
         // Pull backing LCC from caller into the Hub first.
         Currency.wrap(withLCC).transferFrom(from, address(this), ctx.originalAmount);
         // Executes the full wrap-with operation using the provided context
         ctx = LiquidityHubLinkedLib.wrapWithContext(s, lcc, withLCC, ctx);
         // Extract return values.
         // Note: wrapWithContext is designed to conserve amounts. Any mismatch is a logic bug in the library.
         uint256 directToMint = ctx.directToMint;
         uint256 marketToMint = ctx.marketToMint;
 
         // Final mint: mint target LCC with appropriate direct/market-derived split
         LCCFactoryLib.mint(lcc, to, directToMint, marketToMint);
 
         if (ctx.queuedShortfall > 0) {
             // Ensure the queued settlement event is emitted
             emit SettlementQueued(withLCC, address(this), ctx.queuedShortfall);
         }
 
         emit LccWrappedWith(lcc, withLCC, from, to, amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing for the caller
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param amount The amount to wrap
      */
     function wrapWith(address lcc, address withLCC, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing and sends to a specified recipient
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The recipient address
      * @param amount The amount to wrap
      */
     function wrapWithTo(address lcc, address withLCC, address to, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, to, amount);
     }
 
     /**
      * @dev Unwraps LCC from the account's wallet and transfers underlying assets to recipient
      * @dev Accounts should only be able to unwrap if they have LCC in their wallet
      * @dev Unwrap headroom (`availableToUnwrap`) nets any existing settlement queue for `queueTo` against the
      *      caller-held balance (`from`), so the same LCC cannot back repeated queued shortfalls.
      *      - Self-unwrap paths (`unwrap`, `unwrapTo` with `to == queueTo`): `queueTo == from`, so the queue is netted
      *        against the same user's live balance.
      *      - Endpoint `unwrapTo(lcc, to, queueTo, ...)`: supported only when the endpoint acts on behalf of the
      *        beneficiary named by `queueTo`; caller-held balance is treated as representing that beneficiary for this
      *        unwrap (see HUB-02A in INVARIANTS.md).
      * @param lcc The LCC token address to unwrap
      * @param to The recipient of the underlying asset
      * @param queueTo The address to queue shortfall to
      * @param amount The amount to unwrap
      */
     function _unwrap(address lcc, address to, address queueTo, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         (uint256 wrappedBalance, uint256 marketDerivedBalance) = _balancesOf(lcc, from);
         uint256 fromBalance = wrappedBalance + marketDerivedBalance;
 
         // Generic queue paths validate queue-owner shape only.
         // Current settleability remains a redemption-time concern for processSettlementFor().
         _assertValidQueueOwner(lcc, queueTo, true);
 
         _assertUnwrapWithinHeadroom(amount, fromBalance, s.settleQueue[lcc][queueTo]);
 
         (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) =
             LiquidityHubLinkedLib.unwrapInternalLogic(s, lcc, queueTo, amount, wrappedBalance, marketDerivedBalance);
 
         // `unwrapInternalLogic` updates queue state directly in library storage.
         // Queue owner shape is validated at write time; present settleability is enforced on settlement.
 
         // Burn the amount that was unwrapped
         // and transfer the underlying assets to the account
         if (directUnwrapped + marketUnwrapped > 0) {
             _pay(lcc, from, to, directUnwrapped, marketUnwrapped);
         }
         if (queuedShortfall > 0) {
             emit SettlementQueued(lcc, queueTo, queuedShortfall);
         }
 
         emit LccUnwrapped(lcc, from, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller
      * @param lcc The LCC token address to unwrap
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address lcc, uint256 amount) external nonReentrant {
         _unwrap(lcc, _msgSender(), _msgSender(), amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address underlying, bytes32 marketId, uint256 amount) external nonReentrant {
         _unwrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), _msgSender(), amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient
      * @dev Endpoint-only: caller must be `BOUND_ENDPOINT` for this LCC's market. Direct users use `unwrap(...)`.
      *      Shortfalls queue to `to`; admission is capped by `availableToUnwrap` (see `_unwrap` NatSpec, HUB-02).
      * @param lcc The LCC token address to unwrap
      * @param to The recipient address
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address lcc, address to, uint256 amount) external nonReentrant {
         _onlyUnwrapToEndpoint(lcc);
         // Backwards-compatible: queue shortfalls to the same address receiving the underlying.
         _unwrap(lcc, to, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient, while queueing any
      *         unfulfilled portion to a separate queue owner.
      * @dev Endpoint-only on-behalf-of flow (e.g. MMPM): "who receives underlying now" may differ from queue owner.
      *      Admission is capped by netting `settleQueue[lcc][queueTo]` against the caller-held balance (HUB-02 / HUB-02A).
      * @param lcc The LCC token address to unwrap
      * @param to The recipient address for underlying
      * @param queueTo The address to attribute any queued settlement to
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address lcc, address to, address queueTo, uint256 amount) external nonReentrant {
-        _onlyUnwrapToEndpoint(lcc);
+        if (queueTo != _msgSender()) _onlyUnwrapToEndpoint(lcc);
         _unwrap(lcc, to, queueTo, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient (overloaded)
      * @dev Endpoint-only: caller must be `BOUND_ENDPOINT` for the resolved LCC. Direct users use `unwrap(...)`.
      *      Admission uses `availableToUnwrap` with queue keyed to `to` (HUB-02).
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external nonReentrant {
         address lccAddr = s.marketUnderlyingToLCC[marketId][underlying];
         _onlyUnwrapToEndpoint(lccAddr);
         _unwrap(lccAddr, to, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens (resolved by underlying+marketId) to underlying assets, while queueing any unfulfilled
      *         portion to a separate queue owner.
      * @dev Endpoint-only on-behalf-of flow. Admission uses `availableToUnwrap` with queue keyed to `queueTo` (HUB-02A).
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address for underlying
      * @param queueTo The address to attribute any queued settlement to
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address underlying, bytes32 marketId, address to, address queueTo, uint256 amount)
         external
         nonReentrant
     {
         address lccAddr = s.marketUnderlyingToLCC[marketId][underlying];
-        _onlyUnwrapToEndpoint(lccAddr);
+        if (queueTo != _msgSender()) _onlyUnwrapToEndpoint(lccAddr);
         _unwrap(lccAddr, to, queueTo, amount);
     }
 
     // ============ LIQUIDITY FUNCTIONS ============
 
     /**
      * @notice Returns the available liquidity in the market for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of liquidity available in the market (0 if market doesn't exist)
      */
     function marketLiquidity(address lcc) public view returns (uint256) {
         Market memory market = s.lccToMarket[lcc];
         return
             market.id != bytes32(0)
                 ? IMarketFactory(market.factory).marketLiquidity(s.lccToUnderlying[lcc], market.id)
                 : 0;
     }
 
     // ============ ISSUER FUNCTIONS ============
 
     /**
      * @notice Issues LCC tokens (mints to issuer)
      * @param lcc The LCC token address to issue for
      * @param amount The amount to issue
      */
     function issue(address lcc, address to, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC mint path reverts on zero (direct+market) amount.
         // Minting market-derived LCC directly to the DEX sink bypasses transfer hooks and ingress settlement.
         _assertWrapRecipientNotDexSink(lcc, to);
         _mint(lcc, to, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens (burns from specified address)
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param amount The amount to cancel
      */
     function cancel(address lcc, address from, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC burn path reverts on zero (direct+market) amount.
         // `from` is intentionally issuer-selected because issuers are fixed protocol actors (for example ProxyHook and
         // VTSOrchestrator) that cancel along validated protocol flows, not arbitrary public confiscation surfaces.
         // Typical callers burn protocol-controlled holders such as queued settlement holders, MarketVault balances,
         // or staged transfer recipients after the surrounding flow has already proven the accounting path.
         _burn(lcc, from, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens and queues a settlement for the shortfall
      * @dev Simulates unwrap-with-queue without touching direct supply or market liquidity.
      *      Queue recipient shape is validated (non-zero, non-exempt unless Hub), while present settleability
      *      is intentionally enforced at processSettlementFor() when redemption is attempted.
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) public onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
         // Same trusted-issuer rationale as `cancel`: the issuer chooses `from` because this path is used to unwind
         // protocol-side LCC holdings while optionally preserving the recipient's queued settlement claim.
         _cancelWithQueue(lcc, from, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Queues settlement for a recipient after issuer-side deficit transfer.
      * @dev Security checks:
      *      - recipient must be non-zero
      *      - recipient must not be bucket-exempt (external settlement path requires market-derived balance accounting)
      *      - recipient must hold sufficient market-derived LCC to back the queued amount
      *      This path is stricter than generic queue accounting because it is only used when the issuer
      *      has already transferred deficit LCC to `recipient`, so queue owner and burn source must match now.
      */
     function queueForTransferRecipient(address lcc, address recipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         // Deficit queues must target a serviceable external recipient (Hub queueing is not allowed on this path).
         _assertQueueRecipientServiceable(lcc, recipient, amount, false);
         _queueSettlement(lcc, recipient, amount);
     }
 
     /**
      * @dev Internal implementation of cancelWithQueue without access control
      * @param lcc The LCC token address
      * @param from The address to cancel tokens from
      * @param principalAmount The total principal amount being cancelled (cancellable amount is burned from `from`)
      * @param queueAmount The amount to queue for settlement (portion of principalAmount queued for `recipient`)
      * @param recipient The recipient of the queued settlement
      */
     function _cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) internal {
         if (queueAmount > 0) {
             _assertValidQueueOwner(lcc, recipient, true);
         }
 
         uint256 cancelAmount = principalAmount - queueAmount;
 
         // Burn the cancellable portion of the principal amount from the sender.
         // Burn against the sender's actual bucket split (market-derived first, then wrapped).
         // Note: allow cancelAmount == 0 (principal fully queued) without reverting.
         if (cancelAmount > 0) {
             _safeBurn(lcc, from, cancelAmount);
         }
 
         // Queue accounting is intentionally decoupled from current holder backing.
         // Runtime settleability is enforced when processSettlementFor executes.
         _queueSettlement(lcc, recipient, queueAmount);
     }
 
     /**
      * @dev Burns against a holder's bucket split (market-derived first, then wrapped).
      * - Bucket-exempt recipients can burn without bucket accounting.
      * - If `balancesOf` is unavailable (e.g. reentrancy tests that stub LCC), fall back to a full burn.
      */
     function _safeBurn(address lcc, address from, uint256 amount) internal {
         if (amount == 0) return;
 
         if (Bounds.isExempt(boundLevelOfLcc(lcc, from))) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         // IMPORTANT: Some reentrancy-hardening tests replace the LCC code (vm.etch) with a minimal stub that
         // does not implement balancesOf; in that case we must still proceed to the burn to exercise the guard.
         uint256 wrappedBal;
         uint256 marketBal;
         bool hasBuckets = true;
         try ILCC(lcc).balancesOf(from) returns (uint256 wrapped, uint256 market) {
             wrappedBal = wrapped;
             marketBal = market;
         } catch (bytes memory reason) {
             // Keep fallback only for stubbed / non-implemented `balancesOf` paths (empty revert data).
             // Integrity and bucket errors (e.g. `Errors.InvalidBucketState`) must surface.
             if (reason.length == 0) {
                 hasBuckets = false;
             } else {
                 assembly ("memory-safe") {
                     revert(add(reason, 0x20), mload(reason))
                 }
             }
         }
 
         if (!hasBuckets) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         uint256 burnMarket = Math.min(marketBal, amount);
         uint256 remaining = amount - burnMarket;
         uint256 burnDirect = Math.min(wrappedBal, remaining);
         _burn(lcc, from, burnDirect, burnMarket);
     }
 
     /**
      * @notice Plans a cancel operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      This path-keyed store is safe only because current callers stage the plan and then
      *      immediately drive the matching transfer in the same logical path/transaction.
      *      It must not be treated as a general deferred queue across unrelated intermediate logic.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param amount The amount to cancel
      */
     function planCancel(address lcc, address sender, address cancelFromRecipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
 
         // Store the planned cancel in transient storage
         TransientSlots.setPlanCancel(lcc, sender, cancelFromRecipient, amount);
     }
 
     /**
      * @notice Plans a cancel with queue operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      Current MM decrease flows rely on the matching transfer happening immediately after
      *      `modifyLiquidity(...)` returns; if a future flow can stage the same key twice before
      *      consumption, this helper is no longer sufficient.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function planCancelWithQueue(
         address lcc,
         address sender,
         address cancelFromRecipient,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) external onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
 
         // Store the planned cancel with queue in transient storage
         TransientSlots.setPlanCancelWithQueue(lcc, sender, cancelFromRecipient, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Called by MarketVault after taking underlying liquidity from the market to LCC
      * @param lcc The LCC token address
      * @param amount The amount of underlying liquidity taken
      * @param shouldEmit Whether to emit LiquidityAvailable event
      */
     function confirmTake(address lcc, uint256 amount, bool shouldEmit) external onlyIssuer(lcc) {
         // INTENT:
         // `confirmTake()` must be callable from within higher-level flows that themselves may be `nonReentrant`
         // (e.g. `useMarketLiquidity()` eventually triggering a vault -> hub callback).
         // We therefore DO NOT apply `nonReentrant` here; instead, we enforce a strict balance-backed invariant
         // so callers cannot "fabricate" reserves via re-entrancy.
 
         LiquidityHubLib.ConfirmTakeContext memory ctx =
             LiquidityHubLinkedLib.confirmTakePrepare(s, lcc, amount, shouldEmit);
 
         // Best-effort: settle Hub queue up to the newly available amount
         if (ctx.hubQueueBeforeSettlement > 0) {
             _processSettlementFor(lcc, address(this), amount);
         }
 
         if (ctx.emitLiquidityAvailable) {
             // Only emit if there is new liquidity available and not consumed greedily by the Hub
             emit LiquidityAvailable(lcc, ctx.underlying, amount, ctx.marketId);
         }
 
         // Balance-backed invariant: reserve accounting must never exceed actual hub holdings.
         // This protects against re-entrancy and any accidental/malicious unbacked `confirmTake` calls.
         LiquidityHubLinkedLib.confirmTakeBalanceInvariant(s, ctx.underlying);
     }
 
     /**
      * @notice Prepare settlement of underlying from Hub to MarketVault
      * @dev For ERC20, approve the caller (expected MarketVault) to pull tokens; for native, transfer ETH to caller.
      *      Decrements direct reserve and per-LCC directSupply immediately; intended to be called just before settlement
      *      in the same tx.
      */
     function prepareSettle(address lcc, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         LiquidityHubLinkedLib.prepareSettle(s, lcc, amount, _msgSender());
     }
 
     /**
      * @notice Process settlement for a specific recipient using reserveOfUnderlying
      * @dev Permissionless function that allows anyone to process settlements when liquidity is available.
      *      Unified interface: branches behaviour based on whether recipient is address(this) (Hub) or external address.
      *      For Hub: burns Hub-held LCC without transferring underlying or decrementing reserves.
      *      For external: checks holder balance, burns user tokens, transfers underlying, and decrements reserves.
      *      External-path reverts are retriable and signal that reserves/custody are not yet reconciled.
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for (address(this) for Hub's own queue)
      * @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
      */
     function processSettlementFor(address lcc, address recipient, uint256 maxAmount)
         external
         onlyValidLcc(lcc)
         nonReentrant
     {
         _processSettlementFor(lcc, recipient, maxAmount);
     }
 
     /**
      * @notice Atomically releases queued MM custody and settles it against the recipient's Hub queue
      * @dev Best-effort path for MM collection flows. Returns 0 when the queue, reserve, or custody
      *      currently cannot support settlement, instead of reverting.
      * @param lcc The LCC token address
      * @param custodian The MM queue custodian holding beneficiary-scoped queued LCC
      * @param tokenId The commitment token id bucket to debit in the custodian
      * @param recipient The queue owner and settlement recipient
      * @param maxAmount The maximum amount to settle
      */
     function settleFromCustodian(address lcc, address custodian, uint256 tokenId, address recipient, uint256 maxAmount)
         external
         onlyValidLcc(lcc)
         nonReentrant
     {
         uint256 settled = LiquidityHubLinkedLib.settleFromCustodian(s, lcc, custodian, tokenId, recipient, maxAmount);
         if (settled > 0) {
             _processSettlementFor(lcc, recipient, settled);
         }
     }
 
     /**
      * @notice Internal function to process settlement for a specific recipient
      * @dev Delegates to LiquidityHubLib.processSettlementLogic
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for
      * @param maxAmount The maximum amount to settle
      */
     function _processSettlementFor(address lcc, address recipient, uint256 maxAmount) internal {
         uint256 queuedBefore = s.settleQueue[lcc][recipient];
         LiquidityHubLinkedLib.processSettlementLogic(s, lcc, recipient, maxAmount);
         uint256 queuedAfter = s.settleQueue[lcc][recipient];
         uint256 settled = queuedBefore > queuedAfter ? queuedBefore - queuedAfter : 0;
         if (settled > 0) {
             emit SettlementProcessed(lcc, recipient, settled, maxAmount);
         }
     }
 
     // -----------------------------------
     // LCC triggered functions
     // -----------------------------------
 
     /// @notice Called by LCC on transfer to execute any planned cancellations
     /// @dev Assumes at most one live plan per `(lcc, sender, recipient)` path at consumption time.
     ///      The current call graph preserves this by staging the plan immediately before the
     ///      matching transfer; this function does not independently disambiguate multiple same-key plans.
     ///      Planned cancels are intentionally consumed from the transfer path so the burn source is the exact
     ///      protocol-side recipient that just received the LCC, rather than an arbitrary user-selected address.
     function executePlannedCancel(address sender, address cancelFromRecipient) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Check for planned cancel with queue first (more specific)
         (uint256 principalAmount, uint256 queueAmount, address queueRecipient) =
             TransientSlots.consumePlanCancelWithQueue(lcc, sender, cancelFromRecipient);
 
         if (principalAmount > 0) {
             // _cancelWithQueue handles principal == queue (burn 0, queue all) and principal > queue.
             // Use internal function to bypass onlyIssuer check (LCC is the caller, not an issuer).
             _cancelWithQueue(lcc, cancelFromRecipient, principalAmount, queueAmount, queueRecipient);
             return;
         }
 
         // Check for simple planned cancel
         uint256 amount = TransientSlots.consumePlanCancel(lcc, sender, cancelFromRecipient);
         if (amount > 0) {
             _safeBurn(lcc, cancelFromRecipient, amount);
         }
     }
 
     /// @notice Annuls queued settlement before a protocol-bound transfer
     function annulSettlementBeforeTransfer(
         address from,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance,
         uint256 amountToTransfer
     ) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Even if queued == 0 or amountToTransfer == 0, the library path is a no-op.
         // We intentionally avoid an early return here to keep the control flow simpler and more auditable.
         uint256 toAnnul = LiquidityHubLinkedLib.annulSettlementBeforeTransfer(
             s, lcc, from, wrappedBalance, marketDerivedBalance, amountToTransfer
         );
         if (toAnnul > 0) {
             emit SettlementAnnulled(lcc, from, toAnnul);
         }
     }
 
     // ============ SETTLEMENT FUNCTIONS ============
 
     /**
      * @dev Pays an outstanding settlement to an account by burning LCC tokens and transferring underlying assets
      * @param lcc The LCC token address
      * @param owner The owner of the LCC tokens to burn
      * @param to The recipient of the underlying assets
      * @param fromDirect The amount of LCC to burn from direct supply
      * @param fromMarket The amount of LCC to burn from market-derived supply
      */
     function _pay(address lcc, address owner, address to, uint256 fromDirect, uint256 fromMarket) internal {
         LiquidityHubLinkedLib.pay(s, lcc, owner, to, fromDirect, fromMarket);
     }
 
     /**
      * @dev Adds a settlement request to the queue
      * @param lcc The LCC token address
      * @param recipient The address with pending settlements
      * @param amount The amount to eventually settle
      */
     function _assertQueueRecipientServiceable(address lcc, address recipient, uint256 amount, bool allowHub)
         internal
         view
     {
         _assertValidQueueOwner(lcc, recipient, allowHub);
 
         (, uint256 marketDerivedBalance) = ILCC(lcc).balancesOf(recipient);
         if (marketDerivedBalance < amount) {
             revert Errors.InsufficientBalance(marketDerivedBalance, amount);
         }
     }
 
     /**
      * @dev Minimal queue-owner validity check for generic queue creation.
      * Queue owners must not be zero and must not be bucket-exempt unless the queue is intentionally
      * attributed to the Hub itself. This keeps generic queue writes compatible with later settlement,
      * while still allowing queue ownership to be decoupled from current holder backing.
      */
     function _assertValidQueueOwner(address lcc, address recipient, bool allowHub) internal view {
         if (recipient == address(0)) {
             revert Errors.InvalidAddress(recipient);
         }
 
         if (recipient == address(this)) {
             if (!allowHub) revert Errors.NotApproved(recipient);
             return;
         }
 
         if (Bounds.isExempt(boundLevelOfLcc(lcc, recipient))) {
             revert Errors.NotApproved(recipient);
         }
     }
 
     /**
      * @dev Queue accounting helper only.
      * Deliberately does not assert recipient backing/custody because queue ownership may be
      * intentionally decoupled from current LCC holder state. Serviceability is enforced at
      * processSettlementFor(), while explicit transfer-recipient flows validate earlier.
      */
     function _queueSettlement(address lcc, address recipient, uint256 amount) internal {
         if (amount == 0) return;
         LiquidityHubLinkedLib.queueSettlement(s, lcc, recipient, amount);
         emit SettlementQueued(lcc, recipient, amount);
     }
 
     // ============ INTERNAL FUNCTIONS ============
 
     /// @dev Reverts unless `0 < amount <= availableToUnwrap` where `availableToUnwrap = max(0, fromBalance - existingQueue)`.
     function _assertUnwrapWithinHeadroom(uint256 amount, uint256 fromBalance, uint256 existingQueue) private pure {
         uint256 availableToUnwrap = fromBalance > existingQueue ? fromBalance - existingQueue : 0;
         if (amount == 0 || amount > availableToUnwrap) {
             revert Errors.InvalidAmount(amount, availableToUnwrap);
         }
     }
 
     /**
      * @dev Validates that the sender is the canonical vault for a native-backed market
      * @dev Reverts if sender identity is not canonical for the market derived from returned LCCs
      */
     function _assertValidEthSender() internal view {
         address sender = _msgSender();
         if (sender.code.length == 0) revert Errors.InvalidEthSender();
 
         address l0;
         address l1;
         // Prefer a typed call + try/catch over low-level staticcall probing.
         try IMarketVault(sender).lccs() returns (address _l0, address _l1) {
             l0 = _l0;
             l1 = _l1;
         } catch {
             revert Errors.InvalidEthSender();
         }
 
         bool valid0 = LCCFactoryLib.isValidLcc(s, l0);
         bool valid1 = LCCFactoryLib.isValidLcc(s, l1);
         if (!valid0 || !valid1) {
             revert Errors.InvalidEthSender();
         }
 
         Market memory m0 = s.lccToMarket[l0];
         Market memory m1 = s.lccToMarket[l1];
         if (m0.id == bytes32(0) || m1.id == bytes32(0) || m0.id != m1.id || m0.factory != m1.factory) {
             revert Errors.InvalidEthSender();
         }
         if (!isFactory[m0.factory]) {
             revert Errors.InvalidEthSender();
         }
         if (!IMarketFactory(m0.factory).isCanonicalVault(m0.id, sender)) {
             revert Errors.InvalidEthSender();
         }
 
         // Require a native-backed market.
         if (s.lccToUnderlying[l0] != address(0) && s.lccToUnderlying[l1] != address(0)) {
             revert Errors.InvalidEthSender();
         }
     }
 
     /**
      * @notice Receives native ETH transfers from MarketVault contracts
      * @dev Only accepts transfers from valid MarketVault contracts with at least one native ETH LCC.
      *      This enables the route: PoolManager -> MarketVault -> LiquidityHub for native asset settlements.
      *      Reverts if the sender is not a valid MarketVault or if neither LCC uses native ETH as underlying.
      */
     receive() external payable {
         // plain ETH transfer must come from a market vault.
         _assertValidEthSender();
     }
 }
```

### 3. [Medium] Skipping cancel(0) in MarketVault._cancelLCCWithDeficit enables fully-deficit proxy queueing to non-payable recipients in native markets, causing stuck Hub reserves

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

A PR change to MarketVault._cancelLCCWithDeficit [skips LiquidityHub.cancel when amountToCancel == 0](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/modules/MarketVault.sol#L333-L335), making fully-deficit proxy swaps proceed even with zero vault output liquidity. Attackers can direct the deficit queue to a non-payable contract in native-backed markets, making processSettlementFor permanently revert and causing ETH mobilized from the vault to remain stuck in the LiquidityHub with no reverse path back to the vault.

The PR modified MarketVault._cancelLCCWithDeficit to [skip LiquidityHub.cancel when amountToCancel == 0](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/modules/MarketVault.sol#L333-L335). Previously, a fully-deficit proxy swap at zero output vault liquidity would revert on cancel(0). Now, the flow proceeds: (1) ProxyHook [resolves an arbitrary deficitRecipient from hookData](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/ProxyHook.sol#L424-L436); (2) MarketVault [transfers deficit LCC to that recipient and calls LiquidityHub.queueForTransferRecipient](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/modules/MarketVault.sol#L336-L345); (3) LiquidityHub admits the queue based on [recipient shape and market-derived backing only (no payability check)](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L1094-L1102). For native-backed LCCs, settlement to a non-payable recipient always reverts in [LiquidityHubLib.transferUnderlying (native call)](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/LiquidityHubLib.sol#L613), so the queued claim becomes unserviceable. When the vault later regains liquidity, MarketVault._settleObligationsForLCC [moves ETH to the LiquidityHub](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/modules/MarketVault.sol#L294-L297) and confirmTake [increases market-derived reserve](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/LiquidityHubLib.sol#L636-L639). There is no mechanism to return that reserve to the vault, so if no other recipients exist, those funds are permanently stuck. If other recipients exist, the unserviceable queue forces a persistent backlog that repeatedly drains future vault inflows to the Hub and can culminate in stuck reserves once other recipients are cleared.

#### Severity

**Impact Explanation:** [High] Leads to permanently stuck funds (ETH) in the LiquidityHub with no workaround when no other recipients exist; otherwise causes persistent backlog that can culminate in stuck reserves once other recipients are cleared.

**Likelihood Explanation:** [Low] Primarily a griefing vector with no direct profit for the attacker and timing requirements (zero-liquidity moments).

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Permanent stuck ETH in Hub (no other queued recipients): The attacker deploys a non-payable contract and performs a proxy exact-input swap when the vault has zero output liquidity for a native-backed LCC, setting the contract as deficitRecipient. MarketVault transfers deficit LCC to the contract and queues settlement. Later, when the vault moves ETH to the Hub to cover the queue, processSettlementFor to that recipient always reverts on native transfer, leaving the mobilized ETH permanently stuck in the LiquidityHub.
#### Preconditions / Assumptions
- (a). The market’s output LCC is native-backed (underlying == address(0))
- (b). Vault output liquidity for the swap’s output side is zero at execution time
- (c). ProxyHook path is used and allows arbitrary deficitRecipient via hookData
- (d). The PR version with skip-on-zero cancel is deployed
- (e). No other queued settlement recipients exist (or are negligible) for this underlying
- (f). The chosen recipient is a non-payable contract

### Scenario 2.
Persistent vault-to-Hub drain with other recipients: The attacker creates an unserviceable queue as above while legitimate recipients also have queued claims. As liquidity returns, the vault repeatedly moves ETH to the Hub to cover aggregate unfunded queues. Legitimate settlements succeed, but the unserviceable queue ensures a persistent backlog that continuously absorbs new vault inflows and can eventually leave a residual stuck amount once other recipients are cleared.
#### Preconditions / Assumptions
- (a). The market’s output LCC is native-backed (underlying == address(0))
- (b). Zero or near-zero vault output liquidity occurs intermittently
- (c). ProxyHook path is used and allows arbitrary deficitRecipient via hookData
- (d). The PR version with skip-on-zero cancel is deployed
- (e). Other, legitimate recipients also have queued settlements
- (f). The attacker’s chosen recipient is a non-payable contract

### Scenario 3.
Two-sided amplification: The attacker repeats the above in both swap directions during zero-liquidity moments for each leg, creating unserviceable queues for both LCCs. This increases the persistent backlog on both sides, magnifying repeated vault-to-Hub drains and the potential for larger residual stuck reserves when other recipients clear.
#### Preconditions / Assumptions
- (a). Both LCCs in the pair can encounter zero/near-zero vault output liquidity at different times
- (b). ProxyHook path is used in both directions with arbitrary deficitRecipient via hookData
- (c). The PR version with skip-on-zero cancel is deployed
- (d). The attacker uses non-payable recipients for both legs’ output LCCs
- (e). Market is native-backed for the affected legs

#### Proposed fix

##### MarketVault.sol

File: `contracts/evm/src/modules/MarketVault.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/modules/MarketVault.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 /**
  * @title MarketVault
  * @notice Abstract contract providing vault functionality for managing liquidity in Uniswap V4 pools.
  *         The MarketVault is typically tied to a ProxyHook that manages liquidity through a PoolManager.
  *
  *         Core Responsibilities:
  *         - Managing underlying asset liquidity stored in the PoolManager via ERC-6909 claim tokens
  *         - Settling underlying assets to/from LCC (Liquidity Commitment Certificate) contracts
  *         - Fulfilling pending settlement obligations for users who attempted to unwrap LCC tokens
  *         - Handling balance deltas during PoolManager unlock operations
  *
  *         Key Concepts:
  *         - "Settle": Transfer ERC20 tokens to PoolManager and mint ERC-6909 claim tokens (deposit)
  *         - "Take": Burn ERC-6909 claim tokens and transfer ERC20 tokens from PoolManager (withdraw)
  *         - "Obligations": Pending settlement deficits that occur when users try to unwrap LCC tokens
  *                          but insufficient liquidity is available
  */
 pragma solidity ^0.8.26;
 
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
 import {ILCC} from "../interfaces/ILCC.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {IMarketVault} from "../interfaces/IMarketVault.sol";
 import {LiquidityUtils} from "../libraries/LiquidityUtils.sol";
 import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
 import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";
 import {Errors} from "../libraries/Errors.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
 import {ImmutableMarketState} from "./ImmutableMarketState.sol";
 
 abstract contract MarketVault is IMarketVault, ImmutableState, ImmutableMarketState, ReentrancyGuardTransient {
     using CurrencySettler for Currency;
 
     event SwapDeficit(PoolId indexed poolId, address indexed lccToken, address deficitRecipient, uint256 deficitAmount);
 
     ILiquidityHub public immutable liquidityHub;
 
     constructor(address _marketFactory) ImmutableMarketState(_marketFactory) {
         liquidityHub = marketFactory.liquidityHub();
     }
 
     // Market tracking state variables
     bytes32[] public knownMarkets; // List of known markets that have been registered
     mapping(bytes32 => bool) public isMarketKnown; // Quick lookup to check if a market has been registered
     mapping(bytes32 => uint256) public marketLiquidityReserves; // Market-specific underlying liquidity reserves
 
     // Events for market tracking
     event MarketRegistered(bytes32 indexed marketId);
     event MarketLiquidityAdded(bytes32 indexed marketId, uint256 amount);
     event MarketLiquidityUsed(bytes32 indexed marketId, uint256 amount);
     event LiquidityAddedToVault(address indexed sender, address indexed from, address indexed currency, uint256 amount);
     event LiquidityTakenFromVault(
         address indexed sender, address indexed recipient, address indexed currency, uint256 amount
     );
 
     /**
      * @dev Callback data structure for PoolManager unlock operations
      * @notice Contains the necessary information to process balance deltas during unlock callbacks
      * @param sender The address initiating the liquidity modification
      * @param currency0 The first currency in the pair
      * @param currency1 The second currency in the pair
      * @param balanceDelta The balance delta representing the change in liquidity for both currencies
      */
     struct CallbackData {
         address sender;
         Currency currency0;
         Currency currency1;
         BalanceDelta balanceDelta;
     }
 
     modifier onlyProtocolBounds() {
         _onlyProtocolBounds();
         _;
     }
 
     function _onlyProtocolBounds() internal view {
         // Trust is intentionally delegated to the MarketFactory bound namespace rather than to a narrower
         // hard-coded caller set. That makes this a governance / integration boundary: if governance binds the
         // wrong endpoint it can misuse vault liquidity, but unbound external callers still have no access.
         if (!marketFactory.bounds(msg.sender)) {
             revert Errors.InvalidSender();
         }
     }
 
     function _underlying() internal view virtual returns (Currency currency0, Currency currency1);
 
     function _lccs() internal view virtual returns (ILCC lccToken0, ILCC lccToken1);
 
     function _marketId() internal view virtual returns (bytes32);
 
     function lccs() external view returns (address lccToken0, address lccToken1) {
         (ILCC l0, ILCC l1) = _lccs();
         return (address(l0), address(l1));
     }
 
     /**
      * @dev Get the balance of a token in the MarketVault
      * @param currency The currency in market vault
      * @return The balance of the currency in the market vault
      */
     function inMarketBalanceOf(Currency currency) public view returns (uint256) {
         return poolManager.balanceOf(address(this), currency.toId());
     }
 
     /**
      * @dev Take underlying asset from the vault to the recipient address
      * @notice This function will revert if there is insufficient liquidity in the vault.
      *         It burns ERC-6909 claim tokens to release underlying ERC20 tokens and transfers them to the recipient.
      * @param underlyingCurrency The currency (underlying asset) to take from the vault
      * @param recipient The address that will receive the underlying asset
      * @param amount The amount of underlying asset to take from the vault
      * @custom:reverts InsufficientLiquidityToTake If the vault doesn't have enough liquidity to fulfill the request
      */
     function _takeUnderlyingFromVaultToRecipient(Currency underlyingCurrency, address recipient, uint256 amount)
         internal
     {
         // Verify that the vault has sufficient liquidity to fulfill the request
         uint256 availableLiquidity = inMarketBalanceOf(underlyingCurrency);
         if (availableLiquidity < amount) {
             revert Errors.InsufficientLiquidityToTake();
         }
 
         // Burn ERC-6909 claim tokens to release the underlying ERC20 tokens from the PoolManager
         // This reduces the vault's claim on the PoolManager's balance
         underlyingCurrency.settle(
             poolManager,
             address(this),
             amount,
             true // burn = true: burn ERC-6909 Claim Tokens
         );
 
         // Transfer the released ERC20 tokens (or native ETH) from PoolManager to the recipient
         // This claims the actual underlying tokens (not claim tokens)
         if (underlyingCurrency.isAddressZero() && recipient == address(liquidityHub)) {
             // For native ETH, we must route via this MarketVault.
             // Otherwise PoolManager sends ETH directly to LiquidityHub, whose receive() only accepts MarketVault senders.
             underlyingCurrency.take(
                 poolManager,
                 address(this),
                 amount,
                 false // mint = false: claim native ETH (not mint claim tokens)
             );
             (bool ok,) = payable(recipient).call{value: amount}("");
             if (!ok) revert Errors.InvariantViolated("Native transfer to LiquidityHub failed");
         } else {
             underlyingCurrency.take(
                 poolManager,
                 recipient,
                 amount,
                 false // mint = false: claim ERC20 tokens (not mint claim tokens)
             );
         }
 
         emit LiquidityTakenFromVault(msg.sender, recipient, Currency.unwrap(underlyingCurrency), amount);
     }
 
     /**
      * @dev Take underlying asset from the vault to an LCC and confirm the take
      * @notice This function will revert if there is insufficient liquidity in the vault.
      *         It takes the full requested amount from the vault, transfers it to the LCC contract,
      *         and notifies the LiquidityHub about the new balance. The LiquidityHub will emit
      *         a LiquidityAvailable event if shouldEmit is true.
      * @param lccToken The LCC token contract that will receive the underlying asset
      * @param amount The exact amount of underlying asset to take from the vault (must be > 0)
      * @param shouldEmit Whether to emit LiquidityAvailable event after confirming the take
      * @custom:reverts InvalidAmount If amount is zero
      * @custom:reverts InsufficientLiquidityToTake If the vault doesn't have enough liquidity to fulfill the request
      */
     function _takeUnderlyingFromVaultToHub(ILCC lccToken, uint256 amount, bool shouldEmit) internal {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
 
         Currency uaCurrency = Currency.wrap(lccToken.underlying());
 
         // Take the underlying asset from vault to the Hub contract address
         // This will revert if insufficient liquidity is available
         _takeUnderlyingFromVaultToRecipient(uaCurrency, address(liquidityHub), amount);
 
         // Notify the LiquidityHub about the new balance and optionally emit event
         liquidityHub.confirmTake(address(lccToken), amount, shouldEmit);
     }
 
     /**
      * @dev Settle underlying from Hub to vault (DEX ingress path).
      * @notice For ERC20: Hub approves MarketVault and we pull from Hub. For native: Hub transfers ETH to MarketVault and we settle from self.
      *         Must fully fund `amount` in this transaction; `LiquidityHub.prepareSettle` reverts if direct reserve cannot cover the full amount.
      */
     function _settleUnderlyingToVaultFromHub(ILCC lccToken, uint256 amount) internal {
         if (amount == 0) {
             return;
         }
 
         liquidityHub.prepareSettle(address(lccToken), amount);
 
         Currency uaCurrency = Currency.wrap(lccToken.underlying());
         // For native ETH, LiquidityHub transfers ETH to this vault first, so settle from self.
         // For ERC20, pull from LiquidityHub after prepareSettle approval.
         address payer = uaCurrency.isAddressZero() ? address(this) : address(liquidityHub);
         _settleUnderlyingToVaultFromSender(uaCurrency, payer, amount);
     }
 
     /**
      * @dev Settle underlying asset to the vault from a sender
      * @notice This function transfers ERC20 tokens from the sender to the PoolManager and mints
      *         ERC-6909 claim tokens to the vault. The claim tokens represent the vault's claim
      *         on the underlying tokens held by the PoolManager.
      * @param underlyingCurrency The currency (underlying asset) to settle to the vault
      * @param sender The address that owns the underlying asset and is settling it to the vault
      * @param amount The amount of underlying asset to settle to the vault
      * @custom:reverts InsufficientLiquidityToSettle If the sender doesn't have enough balance
      */
     function _settleUnderlyingToVaultFromSender(Currency underlyingCurrency, address sender, uint256 amount) internal {
         // Validate that the sender has sufficient balance to settle
         uint256 senderBalance = underlyingCurrency.balanceOf(sender);
 
         if (senderBalance < amount) {
             revert Errors.InsufficientLiquidityToSettle();
         }
 
         // Transfer ERC20 tokens from sender to the PoolManager
         // This moves the actual underlying tokens into the PoolManager's custody
         underlyingCurrency.settle(
             poolManager,
             sender,
             amount,
             false // burn = false: transfer ERC20 tokens (not burn ERC-6909 claim tokens)
         );
 
         // Mint ERC-6909 claim tokens to the vault representing its claim on the deposited tokens
         // These claim tokens can later be burned to "take" (retrieve) the underlying tokens
         underlyingCurrency.take(
             poolManager,
             address(this),
             amount,
             true // mint = true: mint ERC-6909 Claim Tokens to the vault
         );
 
         emit LiquidityAddedToVault(msg.sender, sender, Currency.unwrap(underlyingCurrency), amount);
     }
 
     /**
      * @dev Settle pending obligations for both tokens in a market
      * @notice This function attempts to fulfill pending settlement obligations for users who
      *         attempted to unwrap LCC tokens but encountered insufficient liquidity. It processes
      *         both LCC tokens (currency0 and currency1) in the market, transferring available
      *         liquidity from the vault to the LCCs to settle outstanding deficits.
      *         Called when new liquidity is deposited into the market (e.g., via Core Swap,
      *         MM settle, or DirectLP operations).
      * @param corePoolKey The core pool key identifying the market
      */
     function _settleObligations(PoolKey memory corePoolKey) internal {
         ILCC lccToken0 = ILCC(Currency.unwrap(corePoolKey.currency0));
         ILCC lccToken1 = ILCC(Currency.unwrap(corePoolKey.currency1));
 
         // Attempt to settle obligations for both tokens in the market
         _settleObligationsForLCC(lccToken0);
         _settleObligationsForLCC(lccToken1);
     }
 
     /**
      * @dev Try to settle pending settlement obligations for a specific LCC
      * @notice This function checks if there are pending settlement obligations (queued amounts) for
      *         users who tried to unwrap LCC tokens but encountered insufficient liquidity. If
      *         there are pending obligations and the vault has available liquidity, it transfers
      *         the liquidity from the vault to the Hub and triggers settlement processing.
      *         This is a best-effort operation that settles as much as possible with available liquidity.
      * @param lccToken The LCC token contract to settle obligations for
      */
     function _settleObligationsForLCC(ILCC lccToken) internal {
         // Compute only the remaining unfunded shortfall for this underlying.
         // This avoids repeatedly draining vault liquidity when the Hub reserve already covers queued debt.
         uint256 unfunded = liquidityHub.unfundedQueueOfUnderlying(address(lccToken));
         if (unfunded == 0) return;
 
         // Check how much underlying liquidity is available in the vault for this LCC's underlying asset
         Currency uaCurrency = Currency.wrap(lccToken.underlying());
         uint256 availableLiquidity = inMarketBalanceOf(uaCurrency);
 
         // Calculate how much we can actually settle (limited by available liquidity)
         uint256 amountToSettle = Math.min(unfunded, availableLiquidity);
         if (amountToSettle == 0) return; // No liquidity available to fulfill obligations
 
         // Transfer liquidity from vault to Hub and emit event
         // This will trigger LiquidityAvailable event if shouldEmit is true
         _takeUnderlyingFromVaultToHub(lccToken, amountToSettle, true);
     }
 
     /**
      * @dev Cancel an LCC token amount, handling deficit scenarios when insufficient liquidity is available
      * @notice This function cancels LCC tokens for a given amount, but may only partially fulfill
      *         the cancellation if the vault has insufficient underlying liquidity. When the requested
      *         amount exceeds available liquidity, it cancels what's available and handles the deficit
      *         by transferring the deficit amount to the deficit recipient (if provided).
      *
      *         The deficit scenario occurs when a swap operation requires more liquidity than is
      *         currently available in the vault. The ProxyHook will have already taken the full
      *         LCC amount from the PoolManager, so the deficit represents the shortfall that needs
      *         to be handled separately.
      * @param poolId The pool ID identifying the market
      * @param lccToken The LCC token contract to cancel
      * @param amount The amount of LCC tokens requested to be cancelled
      * @param deficitRecipient The address to receive any deficit amount (if insufficient liquidity)
      * @return amountToCancel The actual amount of LCC tokens that were cancelled (may be less than requested)
      * @custom:note If deficitRecipient is address(0) but deficitAmount > 0, the excess will accumulate.
      *              This indicates that prior swap amount restrictions were broken, which should never happen.
      */
     function _cancelLCCWithDeficit(PoolId poolId, ILCC lccToken, uint256 amount, address deficitRecipient)
         internal
         returns (uint256 amountToCancel)
     {
         uint256 deficitAmount = 0;
         uint256 available = inMarketBalanceOf(Currency.wrap(lccToken.underlying()));
         if (amount > available) {
             amountToCancel = available; // amount to cancel becomes what ever is in custody.
             deficitAmount = amount - available; // deficit amount becomes the difference between the amount to cancel and the amount in custody.
         } else {
             amountToCancel = amount;
         }
 
         if (deficitAmount > 0 && deficitRecipient == address(0)) {
             revert Errors.InvariantViolated("MarketVault: deficit requires recipient");
         }
 
         // `LiquidityHub.cancel` / `LCC.burn` revert on zero amount; skip when the vault has no underlying
         // claims to cancel (fully-deficit exact-input path still transfers LCC and queues settlement).
         if (amountToCancel > 0) {
             liquidityHub.cancel(address(lccToken), address(this), amountToCancel);
         }
 
         if (deficitAmount > 0 && deficitRecipient != address(0)) {
+            // Mitigation: issuer-driven native-backed deficit queues must target EOAs only.
+            // Contract recipients may be non-payable and cause permanent settlement failure on native transfer.
+            // For ERC20-backed LCCs, allow contracts as before.
+            if (Currency.wrap(lccToken.underlying()).isAddressZero() && deficitRecipient.code.length != 0) {
+                revert Errors.NotApproved(deficitRecipient);
+            }
+
             // The MarketVault already took the full LCC amount from the PoolManager.
             // Transfer deficit LCC first so queueing can assert recipient market-derived backing.
             Currency.wrap(address(lccToken)).transfer(deficitRecipient, deficitAmount);
             liquidityHub.queueForTransferRecipient(address(lccToken), deficitRecipient, deficitAmount);
             emit SwapDeficit(poolId, address(lccToken), deficitRecipient, deficitAmount);
         }
         // Note: If deficit recipient is not specified, but a deficit > 0, then excess will accumulate.
         // However, this means prior swap amount restriction in Proxy Hook must therefore be broken. This should never happen.
     }
 
     /**
      * @dev Modify vault liquidity. Called during a poolManager unlock operation.
      * @notice This function modifies the vault's liquidity by taking or settling underlying tokens from the vault to the sender or vice versa.
      * @param currency0 The first currency
      * @param currency1 The second currency
      * @param balanceDelta The balance delta representing the desired liquidity changes
      */
     function _modifyVaultLiquidity(Currency currency0, Currency currency1, BalanceDelta balanceDelta) internal {
         _modifyVaultLiquidityWithRecipient(currency0, currency1, balanceDelta, msg.sender);
     }
 
     /**
      * @dev Modify vault liquidity with an explicit recipient for withdrawals.
      * @notice Positive deltas (withdrawals) are sent to the recipient; negative deltas (deposits)
      *         are settled from this contract to the vault as usual.
      * @param currency0 The first currency
      * @param currency1 The second currency
      * @param balanceDelta The balance delta representing the desired liquidity changes
      * @param recipient The recipient for withdrawals
      */
     function _modifyVaultLiquidityWithRecipient(
         Currency currency0,
         Currency currency1,
         BalanceDelta balanceDelta,
         address recipient
     ) internal {
         // Extract the balance deltas for both currencies
         // Positive values indicate tokens need to be taken from the vault
         // Negative values indicate tokens need to be settled to the vault
         (int128 amount0, int128 amount1) = (balanceDelta.amount0(), balanceDelta.amount1());
 
         // Handle positive delta for currency0: take underlying tokens from vault to recipient
         if (amount0 > 0) {
             _takeUnderlyingFromVaultToRecipient(currency0, recipient, LiquidityUtils.safeInt128ToUint256(amount0));
         }
 
         // Handle positive delta for currency1: take underlying tokens from vault to recipient
         if (amount1 > 0) {
             _takeUnderlyingFromVaultToRecipient(currency1, recipient, LiquidityUtils.safeInt128ToUint256(amount1));
         }
 
         // Handle negative delta for currency0: settle underlying tokens from this contract to vault
         // ? Expects underlying native currency (eg. ETH, WETH, USDC, etc.) to be transferred to this contract in advance.
         if (amount0 < 0) {
             _settleUnderlyingToVaultFromSender(currency0, address(this), LiquidityUtils.safeInt128ToUint256(amount0));
         }
 
         // Handle negative delta for currency1: settle underlying tokens this contract to vault
         if (amount1 < 0) {
             _settleUnderlyingToVaultFromSender(currency1, address(this), LiquidityUtils.safeInt128ToUint256(amount1));
         }
     }
 
     /**
      * @dev Finalise modify vault liquidity, handling partial withdrawals gracefully
      * @notice This function finalises the modify vault liquidity by settling the obligations to the lcc tokens
      *         and confirming the take of the underlying tokens to the liquidity hub.
      * @param balanceDelta The balance delta representing the desired liquidity changes
      * @param usedDelta The actual balance delta that was applied (may be less than requested for withdrawals)
      * @param recipient The recipient for withdrawals (positive deltas)
      */
     function _finaliseModifyLiquidities(BalanceDelta balanceDelta, BalanceDelta usedDelta, address recipient) internal {
         (ILCC lccToken0, ILCC lccToken1) = _lccs();
         // If there was an addition (deposit), then settle the obligations to the lcc tokens
         // ? caller context means negative delta liquidity leaving the caller, and entering the vault.
 
         if (balanceDelta.amount0() < 0) {
             _settleObligationsForLCC(lccToken0);
         }
         if (balanceDelta.amount1() < 0) {
             _settleObligationsForLCC(lccToken1);
         }
 
         if (recipient == address(liquidityHub)) {
             int128 used0 = usedDelta.amount0();
             if (used0 > 0) {
                 // Market-to-Hub withdrawals should wake reactive settlement dispatch.
                 liquidityHub.confirmTake(address(lccToken0), LiquidityUtils.safeInt128ToUint256(used0), true);
             }
             int128 used1 = usedDelta.amount1();
             if (used1 > 0) {
                 liquidityHub.confirmTake(address(lccToken1), LiquidityUtils.safeInt128ToUint256(used1), true);
             }
         }
     }
 
     /// @dev Derives underlying currencies in core/LCC order.
     function _coreUnderlying() internal view returns (Currency currency0, Currency currency1) {
         (ILCC lcc0, ILCC lcc1) = _lccs();
         currency0 = Currency.wrap(lcc0.underlying());
         currency1 = Currency.wrap(lcc1.underlying());
     }
 
     /// @dev Shared clamp logic for dry modify using explicit currency ordering.
     function _dryModifyLiquiditiesWithCurrencies(Currency currency0, Currency currency1, BalanceDelta balanceDelta)
         internal
         view
         returns (BalanceDelta)
     {
         int128 delta0 = balanceDelta.amount0();
         int128 delta1 = balanceDelta.amount1();
 
         // Track actual amounts withdrawn/added
         int128 actualDelta0 = delta0;
         int128 actualDelta1 = delta1;
 
         // Handle withdrawals (negative deltas) - only withdraw what's available
         if (delta0 > 0) {
             uint256 requested0 = LiquidityUtils.safeInt128ToUint256(delta0);
             uint256 available0 = inMarketBalanceOf(currency0);
             uint256 amount0 = Math.min(requested0, available0);
             // If we can't fulfill the full withdrawal, adjust the delta to what we can actually withdraw
             if (amount0 < requested0) {
                 actualDelta0 = SafeCast.toInt128(amount0);
             }
         }
 
         if (delta1 > 0) {
             uint256 requested1 = LiquidityUtils.safeInt128ToUint256(delta1);
             uint256 available1 = inMarketBalanceOf(currency1);
             uint256 amount1 = Math.min(requested1, available1);
             // If we can't fulfill the full withdrawal, adjust the delta to what we can actually withdraw
             if (amount1 < requested1) {
                 actualDelta1 = SafeCast.toInt128(amount1);
             }
         }
 
         return toBalanceDelta(actualDelta0, actualDelta1);
     }
 
     /**
      * @dev Dry run to modify vault liquidity, handling partial withdrawals gracefully
      * @param balanceDelta The desired balance delta to apply
      * @return The actual balance delta that was applied (may be less than requested for withdrawals)
      */
     function dryModifyLiquidities(BalanceDelta balanceDelta) public view returns (BalanceDelta) {
         (Currency currency0, Currency currency1) = _coreUnderlying();
         return _dryModifyLiquiditiesWithCurrencies(currency0, currency1, balanceDelta);
     }
 
     /**
      * @dev This function is called by the MMPositionManager to add liquidity directly to the vault
      * @param balanceDelta The balance delta of the currency0 and currency1
      * @notice Derive the ProxyHook address from the Pool Id, assumes the (LCC underlying) currencies for the Proxy Pool.
      */
     function modifyLiquidities(BalanceDelta balanceDelta) external onlyProtocolBounds nonReentrant {
         (Currency currency0, Currency currency1) = _coreUnderlying();
         _modifyVaultLiquidity(currency0, currency1, balanceDelta);
         _finaliseModifyLiquidities(balanceDelta, balanceDelta, msg.sender);
     }
 
     /**
      * @dev Try to modify vault liquidity, handling partial withdrawals gracefully
      * @param balanceDelta The desired balance delta to apply
      * @return The actual balance delta that was applied (may be less than requested for withdrawals)
      */
     function tryModifyLiquidities(BalanceDelta balanceDelta)
         external
         onlyProtocolBounds
         nonReentrant
         returns (BalanceDelta)
     {
         (Currency currency0, Currency currency1) = _coreUnderlying();
 
         BalanceDelta usedDelta = dryModifyLiquidities(balanceDelta);
         _modifyVaultLiquidity(currency0, currency1, usedDelta);
         _finaliseModifyLiquidities(balanceDelta, usedDelta, msg.sender);
 
         return usedDelta;
     }
 
     /**
      * @notice Try to modify vault liquidity with a custom recipient for withdrawals
      * @param balanceDelta The desired balance delta to apply
      * @param recipient The recipient for withdrawals (positive deltas)
      * @return The actual balance delta that was applied (may be less than requested for withdrawals)
      */
     function tryModifyLiquiditiesWithRecipient(BalanceDelta balanceDelta, address recipient)
         external
         onlyProtocolBounds
         nonReentrant
         returns (BalanceDelta)
     {
         if (recipient == address(0)) {
             revert Errors.InvalidAddress(recipient);
         }
         (Currency currency0, Currency currency1) = _coreUnderlying();
 
         BalanceDelta usedDelta = dryModifyLiquidities(balanceDelta);
         _modifyVaultLiquidityWithRecipient(currency0, currency1, usedDelta, recipient);
         _finaliseModifyLiquidities(balanceDelta, usedDelta, recipient);
 
         return usedDelta;
     }
 
     /**
      * @notice Receives native ETH transfers from authorised protocol contracts
      * @dev This function is called when protocol contracts transfer native ETH to this MarketVault
      *      during settlement operations. Only accepts transfers from authorised sources:
      *      - Protocol bounds: including MMPositionManager during MM position settlement
      */
     receive() external payable {
         // Accept ETH from protocol-bound addresses only (e.g., MMPositionManager, LiquidityHub, PoolManager, etc.)
         if (!marketFactory.bounds(msg.sender)) {
             revert Errors.InvalidEthSender();
         }
     }
 }
```

#### Related findings

##### [Medium] All-deficit deficit transfer and unwrap headroom netting in MarketVault/LiquidityHub causes endpoint unwrapTo DoS

###### Description

A PR change allows all‑deficit proxy swaps to [transfer market‑derived LCC to an arbitrary recipient and immediately queue an equal settlement for that recipient](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/modules/MarketVault.sol#L338-L343). Another PR change [nets that recipient’s queued amount against the endpoint caller’s balance in LiquidityHub.unwrapTo](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L593-L593), letting an attacker front‑run to inflate a victim’s queue and cause endpoint on‑behalf‑of unwraps to revert.

The PR modified MarketVault._cancelLCCWithDeficit to [skip LiquidityHub.cancel when amountToCancel == 0](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/modules/MarketVault.sol#L333-L335), enabling [all‑deficit exact‑input proxy swaps](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/ProxyHook.sol#L360-L379) to succeed by first [transferring market‑derived LCC to a chosen recipient and then queuing the same amount to that recipient via LiquidityHub.queueForTransferRecipient](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/modules/MarketVault.sol#L338-L343). Separately, the PR added a [new headroom policy in LiquidityHub._unwrap for unwrapTo: amount <= max(0, fromBalance - settleQueue[lcc][queueTo])](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L1137-L1146), where fromBalance is the endpoint caller’s LCC and settleQueue is for queueTo (the beneficiary). An attacker can front‑run a pending endpoint unwrapTo by [routing a proxy swap with the deficit recipient set to the victim](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/ProxyHook.sol#L410-L443), thereby inflating settleQueue[lcc][victim]. When the endpoint later calls unwrapTo(lcc, to, queueTo=victim, amount=toUnwrap) holding only the local slice, availableToUnwrap becomes zero and the call reverts. This is a transaction‑order‑dependent denial‑of‑service against endpoint‑mediated unwrap flows and is introduced by the combination of these two PR changes.

###### Severity

**Impact Explanation:** [Medium] The attack creates a significant but temporary denial‑of‑service against endpoint‑mediated unwrapTo flows. It does not necessarily cause permanent stuck funds because operational/code workarounds and state changes (e.g., reserve replenishment) can restore progress.

**Likelihood Explanation:** [Medium] Requires front‑running and low/insufficient vault availability; these are plausible in public mempools and during market stress. The attack is largely griefing/gas‑cost based but realistically repeatable.

###### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Attacker front‑runs an MMPositionManager (MMPM) batch that will unwrap from deltas (payerIsUser=false) on behalf of the locker. The attacker executes a proxy exact‑input swap with the deficit recipient set to the locker address. MarketVault._cancelLCCWithDeficit transfers market‑derived LCC to the locker and queues the same amount. MMPM then calls LiquidityHub.unwrapTo(lcc, to, queueTo=locker, amount) using only its local LCC slice; the new headroom nets the locker’s inflated queue against MMPM’s small fromBalance, causing a revert and failing the batch.
#### Preconditions / Assumptions
- (a). ProxyHook allows caller‑supplied deficit recipient via hookData
- (b). MarketVault._cancelLCCWithDeficit PR change that skips cancel(0) is present
- (c). LiquidityHub._unwrap PR headroom rule nets settleQueue[queueTo] against caller’s fromBalance
- (d). Vault availability for the output underlying is zero or insufficient to fully settle
- (e). Attacker can front‑run the endpoint’s unwrapTo batch and can predict queueTo (e.g., the locker address)
- (f). MMPM uses unwrapTo(lcc, to, queueTo=locker, amount) after taking from deltas

### Scenario 2.
Attacker front‑runs a MMPM unwrap from user (payerIsUser=true). The attacker injects a queue to the user via a proxy swap (deficit recipient=user). MMPM pulls LCC from the user and calls LiquidityHub.unwrapTo(lcc, to, queueTo=user, amount). Headroom nets the user’s inflated queue against the endpoint’s small fromBalance, reverting the unwrapTo call and failing the batch.
#### Preconditions / Assumptions
- (a). ProxyHook allows caller‑supplied deficit recipient via hookData
- (b). MarketVault._cancelLCCWithDeficit PR change that skips cancel(0) is present
- (c). LiquidityHub._unwrap PR headroom rule nets settleQueue[queueTo] against caller’s fromBalance
- (d). Vault availability for the output underlying is zero or insufficient
- (e). Attacker can front‑run the endpoint’s unwrapTo and target queueTo=user
- (f). MMPM pulls LCC from user and calls unwrapTo(lcc, to, queueTo=user, amount)

### Scenario 3.
Attacker front‑runs any Bound Endpoint’s unwrapTo(lcc, to, queueTo, amount) by injecting a queue to queueTo via a proxy swap. LiquidityHub._unwrap then nets queueTo’s inflated queue against the endpoint’s fromBalance, making availableToUnwrap zero and reverting the unwrapTo operation.
#### Preconditions / Assumptions
- (a). ProxyHook allows caller‑supplied deficit recipient via hookData
- (b). MarketVault._cancelLCCWithDeficit PR change that skips cancel(0) is present
- (c). LiquidityHub._unwrap PR headroom rule nets settleQueue[queueTo] against caller’s fromBalance
- (d). Vault availability for the output underlying is zero or insufficient
- (e). Attacker can front‑run a Bound Endpoint unwrapTo and set deficit recipient to that queueTo

###### Proposed fix

####### LiquidityHub.sol

File: `contracts/evm/src/LiquidityHub.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
 import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {LCCFactoryLib, LCCFactoryLinkedLib} from "./libraries/LCCFactoryLib.sol";
 import {LiquidityHubLib} from "./libraries/LiquidityHubLib.sol";
 import {LiquidityHubLinkedLib} from "./libraries/LiquidityHubLinkedLib.sol";
 import {LiquidityHubStorage, Market, UnderlyingReserve} from "./types/Liquidity.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {IMarketVault} from "./interfaces/IMarketVault.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {BoundRegistry} from "./modules/BoundRegistry.sol";
 import {Bounds} from "./libraries/Bounds.sol";
 
 /**
  * @title LiquidityHub
  * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
  * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
  */
 contract LiquidityHub is BoundRegistry, Ownable, ReentrancyGuardTransient {
     using CurrencyTransfer for Currency;
 
     // ============ UNIFIED STATE ============
     LiquidityHubStorage internal s;
 
     IOracleHelper public immutable oracleHelper;
 
     event FactorySet(address indexed factory, bool enabled);
     event LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId);
     event LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId);
     event SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementAnnulled(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementProcessed(
         address indexed lcc, address indexed recipient, uint256 settledAmount, uint256 requestedAmount
     );
     event LccWrappedWith(address indexed lcc, address indexed withLCC, address from, address to, uint256 amount);
     event LccWrapped(address indexed lcc, address from, address to, uint256 amount);
     event LccUnwrapped(address indexed lcc, address from, address to, uint256 amount);
 
     // IMPORTANT NOTE: The LiquidityHub is agnostic/unaware of the end account.
     // Similarly to how PoolManager leverages periphery contracts to manage end-account balances, the LiquidityHub aggregates balances, and uses LCCs to track account balances in a hub-and-spoke model.
 
     // Map of market factories
     mapping(address => bool) public isFactory;
 
     /**
      * @notice Constructs the LiquidityHub contract
      * @param _oracleHelper The oracle helper contract address
      * @param _nativeAssetName The name of the native asset (e.g., "Ether")
      * @param _nativeAssetSymbol The symbol of the native asset (e.g., "ETH")
      * @param _nativeAssetDecimals The decimals of the native asset (typically 18)
      * @param _initialOwner The initial owner of the contract
      */
     constructor(
         address _oracleHelper,
         string memory _nativeAssetName,
         string memory _nativeAssetSymbol,
         uint8 _nativeAssetDecimals,
         address _initialOwner
     ) Ownable(_initialOwner) {
         oracleHelper = IOracleHelper(_oracleHelper);
         LCCFactoryLib.initNativeAsset(s, _nativeAssetName, _nativeAssetSymbol, _nativeAssetDecimals);
     }
 
     /**
      * @notice Modifier to restrict access to registered factory contracts only
      */
     modifier onlyFactory() {
         _onlyFactory();
         _;
     }
 
     function _onlyFactory() internal view {
         if (!isFactory[_msgSender()]) {
             revert Errors.InvalidSender();
         }
     }
 
     /// Override from BoundRegistry
     function _lccMarket(address lcc) internal view override returns (bytes32 id, address factory) {
         Market memory market = s.lccToMarket[lcc];
         return (market.id, market.factory);
     }
 
     /// Override from BoundRegistry
     function setBoundLevel(address who, uint8 level) external override onlyFactory {
         // `BoundRegistry._setBoundLevel` enforces EXEMPT/DEX immutability and first-assignment-from-NONE.
         // The stronger policy that EXEMPT/DEX only arise from hardcoded setup / integration paths must be expressed by
         // the specific `MarketFactory` implementation using this hub; registered factories are trusted for that setup policy.
         // Queue-owner safety when moving an address into exempt remains an operational concern (not indexed on-chain).
         _setBoundLevel(msg.sender, who, level);
     }
 
     /// Override from BoundRegistry
     function setBoundLevels(address[] calldata who, uint8 level) external override onlyFactory {
         for (uint256 i = 0; i < who.length; i++) {
             _setBoundLevel(msg.sender, who[i], level);
         }
     }
 
     /**
      * @notice Modifier to ensure the provided LCC address is valid
      * @param lcc The LCC token address to validate
      */
     modifier onlyValidLcc(address lcc) {
         LiquidityHubLib.assertValidLcc(s, lcc);
         _;
     }
 
     /**
      * @notice Modifier to restrict access to issuers of a specific LCC token
      * @param lcc The LCC token address to check issuer status for
      */
     modifier onlyIssuer(address lcc) {
         _onlyIssuer(lcc);
         _;
     }
 
     function _onlyIssuer(address lcc) internal view {
         // Strict invariant: issuer-gated paths must never operate on invalid/uninitialised LCCs.
         LiquidityHubLib.assertValidLcc(s, lcc);
         if (!LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender)) {
             revert Errors.NotApproved(msg.sender);
         }
     }
 
     /**
      * @dev All `unwrapTo` overloads are endpoint-mediated on-behalf-of flows (e.g. `MMPositionManager`).
      *      Direct users unwrap via `unwrap(...)` which queues shortfalls to the caller.
      *      Caller must be `BOUND_ENDPOINT` in the LCC's market factory namespace (not EXEMPT/DEX).
      */
     function _onlyUnwrapToEndpoint(address lcc) internal view {
         if (boundLevelOfLcc(lcc, _msgSender()) != Bounds.BOUND_ENDPOINT) {
             revert Errors.InvalidSender();
         }
     }
 
     // ============ PUBLIC ACCESSORS ============
 
     /**
      * @notice Returns the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address, or address(0) if not found
      */
     function marketUnderlyingToLCC(bytes32 marketId, address underlying) external view returns (address) {
         return s.marketUnderlyingToLCC[marketId][underlying];
     }
 
     /**
      * @notice Returns the underlying asset address for a given LCC token
      * @param lcc The LCC token address
      * @return The underlying asset address (address(0) for native ETH)
      */
     function lccToUnderlying(address lcc) public view returns (address) {
         return s.lccToUnderlying[lcc];
     }
 
     /**
      * @notice Returns the Market struct for a given LCC token
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function lccToMarket(address lcc) external view returns (bytes32, address) {
         return _lccMarket(lcc);
     }
 
     /**
      * @notice
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function getFactory(address lcc0, address lcc1) external view returns (IMarketFactory) {
         address factory0 = s.lccToMarket[lcc0].factory;
         address factory1 = s.lccToMarket[lcc1].factory;
         if (factory0 != factory1) {
             revert Errors.InvariantViolated("LCCs are not from the same market");
         }
         return IMarketFactory(factory0);
     }
 
     /**
      * @notice Checks if an address is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @param issuer The address to check
      * @return True if the address is an issuer, false otherwise
      */
     function issuers(address lcc, address issuer) external view returns (bool) {
         return s.issuers[lcc][issuer];
     }
 
     /**
      * @notice Gets the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address
      */
     function getLCC(bytes32 marketId, address underlying) external view returns (address) {
         return LCCFactoryLib.getLCC(s, marketId, underlying);
     }
 
     /**
      * @notice Gets the underlying asset address for a given LCC token
      * @param lccToken The LCC token address
      * @return The underlying asset address
      */
     function getUnderlying(address lccToken) external view returns (address) {
         return LCCFactoryLib.getUnderlying(s, lccToken);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function isLCC(address lcc) external view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Returns the direct supply (wrapped underlying) for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of direct supply
      */
     function directSupply(address lcc) external view returns (uint256) {
         return s.directSupply[lcc];
     }
 
     /**
      * @notice Returns the shared reserve of underlying assets for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of underlying assets held in reserve for this LCC
      */
     function reserveOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return reserve.direct + reserve.marketDerived;
     }
 
     /**
      * @notice Returns the split underlying reserve tuple for a given LCC token
      * @param lcc The LCC token address
      * @return direct The reserve component backing direct/wrapped supply
      * @return marketDerived The reserve component mobilised from market-derived flows
      */
     function reserveOfUnderlyingTuple(address lcc)
         external
         view
         onlyValidLcc(lcc)
         returns (uint256 direct, uint256 marketDerived)
     {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return (reserve.direct, reserve.marketDerived);
     }
 
     /**
      * @notice Returns the queued settlement amount for a specific LCC and recipient
      * @param lcc The LCC token address
      * @param recipient The recipient address
      * @return The amount queued for settlement
      */
     function settleQueue(address lcc, address recipient) external view returns (uint256) {
         return s.settleQueue[lcc][recipient];
     }
 
     /**
      * @notice Returns the total queued settlement amount for a given LCC token
      * @param lcc The LCC token address
      * @return The total amount queued across all recipients
      */
     function totalQueued(address lcc) external view returns (uint256) {
         return s.totalQueued[lcc];
     }
 
     /**
      * @notice Returns the total queued settlement debt for the underlying of a given LCC
      * @param lcc The LCC token address
      * @return The total queued debt aggregated across all LCCs sharing the same underlying
      */
     function queueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         return s.queueOfUnderlying[s.lccToUnderlying[lcc]];
     }
 
     /**
      * @notice Returns the unfunded queued debt for the underlying of a given LCC
      * @dev Unfunded debt is `max(queueOfUnderlying - marketDerivedReserve, 0)` at the shared-underlying level.
      * @param lcc The LCC token address
      * @return The remaining underlying shortfall that still needs market-to-Hub mobilisation
      */
     function unfundedQueueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         address underlying = s.lccToUnderlying[lcc];
         uint256 queued = s.queueOfUnderlying[underlying];
         uint256 reserve = s.reserveOfUnderlying[underlying].marketDerived;
         return queued > reserve ? queued - reserve : 0;
     }
 
     // ============ ADMIN FUNCTIONS ============
 
     /**
      * @notice Sets or removes a factory address from the allowed factories list
      * @param factory The factory address to enable or disable
      * @param enabled Whether the factory should be enabled (true) or disabled (false)
      */
     function setFactory(address factory, bool enabled) external onlyOwner {
         isFactory[factory] = enabled;
         emit FactorySet(factory, enabled);
     }
 
     /**
      * @notice Creates LCC token pair for a market
      * @param marketRef The market reference (bytes from proxyHookAddress)
      * @param underlyingAsset0 The first underlying asset address
      * @param underlyingAsset1 The second underlying asset address
      * @param marketName The market name
      * @param initialIssuers Array of addresses to set as issuers for both LCC tokens
      * @return lccToken0 The first LCC token address
      * @return lccToken1 The second LCC token address
      */
     function createLCCPair(
         bytes memory marketRef,
         address underlyingAsset0,
         address underlyingAsset1,
         string memory marketName,
         address[] memory initialIssuers
     ) external onlyFactory returns (address lccToken0, address lccToken1) {
         address resilientOracleAddress = oracleHelper.oracle();
         address factory = _msgSender();
         address[2] memory underlyingPair = [underlyingAsset0, underlyingAsset1];
         lccToken0 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 0, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
         lccToken1 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 1, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
 
         // Emit events for LCC creation
         emit LCCCreated(underlyingAsset0, lccToken0, s.lccToMarket[lccToken0].id);
         emit LCCCreated(underlyingAsset1, lccToken1, s.lccToMarket[lccToken1].id);
     }
 
     /**
      * @notice Initializes the mapping from LCC tokens to Market (with ID and Ref)
      * @dev Order-insensitive: `lccToken0` and `lccToken1` are treated independently; no `(0,1)` lane semantics exist here.
      *      Canonical market ordering (for pair lanes) is defined by the core pool key in `MarketFactory`, not by argument order.
      * @param lccToken0 The first LCC token address
      * @param lccToken1 The second LCC token address
      * @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
      * @param marketRef The market reference (bytes from proxyHookAddress)
      */
     function initialize(address lccToken0, address lccToken1, bytes32 marketId, bytes memory marketRef)
         external
         onlyFactory
     {
         LCCFactoryLib.initialize(s, lccToken0, lccToken1, marketId, marketRef, _msgSender());
     }
 
     // ============ INTERNAL HELPERS (delegate to library) ============
 
     /**
      * @notice Checks if the current caller is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @return True if the caller is an issuer, false otherwise
      */
     function _isCallerIssuer(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function _isValidLcc(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Mints LCC tokens to an address
      * @param lccToken The LCC token address
      * @param to The address to mint tokens to
      * @param directAmount The amount to mint as direct supply
      * @param marketAmount The amount to mint as market-derived supply
      */
     function _mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.mint(lccToken, to, directAmount, marketAmount);
     }
 
     /**
      * @notice Burns LCC tokens from an address
      * @param lccToken The LCC token address
      * @param from The address to burn tokens from
      * @param directAmount The amount to burn from direct supply
      * @param marketAmount The amount to burn from market-derived supply
      */
     function _burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.burn(lccToken, from, directAmount, marketAmount);
     }
 
     /**
      * @notice Gets the total balance (wrapped + market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return The total balance
      */
     function _balanceOf(address lccToken, address account) internal view returns (uint256) {
         return LCCFactoryLib.balanceOf(lccToken, account);
     }
 
     /**
      * @notice Gets the bucketed balances (wrapped and market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return wrapped The wrapped (direct) balance
      * @return marketDerived The market-derived balance
      */
     function _balancesOf(address lccToken, address account)
         internal
         view
         returns (uint256 wrapped, uint256 marketDerived)
     {
         return LCCFactoryLib.balancesOf(lccToken, account);
     }
 
     function _assertWrapRecipientNotDexSink(address lcc, address to) internal view {
         if (Bounds.isDex(boundLevel(s.lccToMarket[lcc].factory, to))) {
             revert Errors.DirectWrapToDexNotAllowed(to);
         }
     }
 
     // ============ TRADER FUNCTIONS ============
 
     // DirectLPs and Traders engaging the CorePool directly will need LCC. LCC is 1:1 with the underlying asset.
     /**
      * @dev Internal function to wrap underlying assets into LCC tokens
      * @param lcc The LCC token address to wrap into
      * @param to The address receiving the LCC tokens
      * @param amount The amount of underlying assets to wrap
      */
     function _wrap(address lcc, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         address underlying = s.lccToUnderlying[lcc];
         bool isNativeAsset = underlying == address(0);
 
         // Mint-time ingress to the DEX sink bypasses LCC transfer hooks.
         // Reject it until there is a safe settlement path that can run under PoolManager lock constraints.
         _assertWrapRecipientNotDexSink(lcc, to);
 
         // throw error if the native ETH is insufficient and it is a native ETH backed LCC
         if (isNativeAsset) {
             if (msg.value != amount) {
                 revert Errors.InvalidAmount(0, 0);
             }
         } else {
             if (msg.value != 0) {
                 revert Errors.InvalidAmount(0, 0);
             }
             // Use CurrencyTransfer which has Permit2 fallback for ERC20 transfers
             Currency.wrap(underlying).transferFrom(from, address(this), amount);
         }
 
         s.directSupply[lcc] += amount;
         s.reserveOfUnderlying[underlying].direct += amount;
 
         // mint some tokens
         _mint(lcc, to, amount, 0);
 
         emit LccWrapped(lcc, from, to, amount);
     }
 
     function wrapTo(address lcc, address to, uint256 amount) external payable nonReentrant {
         _wrap(lcc, to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens and sends them to a specified recipient
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address
      * @param amount The amount of underlying assets to wrap
      */
     function wrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller
      * @param lcc The LCC token address
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address lcc, uint256 amount) external payable nonReentrant {
         _wrap(lcc, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address underlying, bytes32 marketId, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), amount);
     }
 
     /**
      * @notice Internal function to wrap LCC using another LCC as backing, with O(1) flattening and netting
      * @dev Delegates to LiquidityHubLib.wrapWithLogic - heavy logic moved to library
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The address receiving the target LCC
      * @param amount The amount to wrap
      */
     function _wrapWith(address lcc, address withLCC, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
 
         // wrapWithTo shares the same mint surface as direct wrap and must not bypass DEX ingress handling.
         _assertWrapRecipientNotDexSink(lcc, to);
 
         // Performs all necessary validation and preparation
         LiquidityHubLib.WrapWithContext memory ctx =
             LiquidityHubLinkedLib.wrapWithPrepare(s, lcc, withLCC, from, amount);
         // Pull backing LCC from caller into the Hub first.
         Currency.wrap(withLCC).transferFrom(from, address(this), ctx.originalAmount);
         // Executes the full wrap-with operation using the provided context
         ctx = LiquidityHubLinkedLib.wrapWithContext(s, lcc, withLCC, ctx);
         // Extract return values.
         // Note: wrapWithContext is designed to conserve amounts. Any mismatch is a logic bug in the library.
         uint256 directToMint = ctx.directToMint;
         uint256 marketToMint = ctx.marketToMint;
 
         // Final mint: mint target LCC with appropriate direct/market-derived split
         LCCFactoryLib.mint(lcc, to, directToMint, marketToMint);
 
         if (ctx.queuedShortfall > 0) {
             // Ensure the queued settlement event is emitted
             emit SettlementQueued(withLCC, address(this), ctx.queuedShortfall);
         }
 
         emit LccWrappedWith(lcc, withLCC, from, to, amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing for the caller
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param amount The amount to wrap
      */
     function wrapWith(address lcc, address withLCC, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing and sends to a specified recipient
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The recipient address
      * @param amount The amount to wrap
      */
     function wrapWithTo(address lcc, address withLCC, address to, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, to, amount);
     }
 
     /**
      * @dev Unwraps LCC from the account's wallet and transfers underlying assets to recipient
      * @dev Accounts should only be able to unwrap if they have LCC in their wallet
      * @dev Unwrap headroom (`availableToUnwrap`) nets any existing settlement queue for `queueTo` against the
      *      caller-held balance (`from`), so the same LCC cannot back repeated queued shortfalls.
      *      - Self-unwrap paths (`unwrap`, `unwrapTo` with `to == queueTo`): `queueTo == from`, so the queue is netted
      *        against the same user's live balance.
      *      - Endpoint `unwrapTo(lcc, to, queueTo, ...)`: supported only when the endpoint acts on behalf of the
      *        beneficiary named by `queueTo`; caller-held balance is treated as representing that beneficiary for this
      *        unwrap (see HUB-02A in INVARIANTS.md).
      * @param lcc The LCC token address to unwrap
      * @param to The recipient of the underlying asset
      * @param queueTo The address to queue shortfall to
      * @param amount The amount to unwrap
      */
     function _unwrap(address lcc, address to, address queueTo, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         (uint256 wrappedBalance, uint256 marketDerivedBalance) = _balancesOf(lcc, from);
         uint256 fromBalance = wrappedBalance + marketDerivedBalance;
 
         // Generic queue paths validate queue-owner shape only.
         // Current settleability remains a redemption-time concern for processSettlementFor().
         _assertValidQueueOwner(lcc, queueTo, true);
+        // Residual queue nets only the unbacked portion of queueTo's queue against the endpoint-held balance.
+        uint256 existingQueue = s.settleQueue[lcc][queueTo];
+        uint256 queueToBalance = _balanceOf(lcc, queueTo);
+        uint256 residualQueue = existingQueue > queueToBalance ? existingQueue - queueToBalance : 0;
+        _assertUnwrapWithinHeadroom(amount, fromBalance, residualQueue);
 
-        _assertUnwrapWithinHeadroom(amount, fromBalance, s.settleQueue[lcc][queueTo]);
-
         (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) =
             LiquidityHubLinkedLib.unwrapInternalLogic(s, lcc, queueTo, amount, wrappedBalance, marketDerivedBalance);
 
         // `unwrapInternalLogic` updates queue state directly in library storage.
         // Queue owner shape is validated at write time; present settleability is enforced on settlement.
 
         // Burn the amount that was unwrapped
         // and transfer the underlying assets to the account
         if (directUnwrapped + marketUnwrapped > 0) {
             _pay(lcc, from, to, directUnwrapped, marketUnwrapped);
         }
         if (queuedShortfall > 0) {
             emit SettlementQueued(lcc, queueTo, queuedShortfall);
         }
 
         emit LccUnwrapped(lcc, from, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller
      * @param lcc The LCC token address to unwrap
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address lcc, uint256 amount) external nonReentrant {
         _unwrap(lcc, _msgSender(), _msgSender(), amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address underlying, bytes32 marketId, uint256 amount) external nonReentrant {
         _unwrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), _msgSender(), amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient
      * @dev Endpoint-only: caller must be `BOUND_ENDPOINT` for this LCC's market. Direct users use `unwrap(...)`.
      *      Shortfalls queue to `to`; admission is capped by `availableToUnwrap` (see `_unwrap` NatSpec, HUB-02).
      * @param lcc The LCC token address to unwrap
      * @param to The recipient address
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address lcc, address to, uint256 amount) external nonReentrant {
         _onlyUnwrapToEndpoint(lcc);
         // Backwards-compatible: queue shortfalls to the same address receiving the underlying.
         _unwrap(lcc, to, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient, while queueing any
      *         unfulfilled portion to a separate queue owner.
      * @dev Endpoint-only on-behalf-of flow (e.g. MMPM): "who receives underlying now" may differ from queue owner.
      *      Admission is capped by netting `settleQueue[lcc][queueTo]` against the caller-held balance (HUB-02 / HUB-02A).
      * @param lcc The LCC token address to unwrap
      * @param to The recipient address for underlying
      * @param queueTo The address to attribute any queued settlement to
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address lcc, address to, address queueTo, uint256 amount) external nonReentrant {
         _onlyUnwrapToEndpoint(lcc);
         _unwrap(lcc, to, queueTo, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient (overloaded)
      * @dev Endpoint-only: caller must be `BOUND_ENDPOINT` for the resolved LCC. Direct users use `unwrap(...)`.
      *      Admission uses `availableToUnwrap` with queue keyed to `to` (HUB-02).
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external nonReentrant {
         address lccAddr = s.marketUnderlyingToLCC[marketId][underlying];
         _onlyUnwrapToEndpoint(lccAddr);
         _unwrap(lccAddr, to, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens (resolved by underlying+marketId) to underlying assets, while queueing any unfulfilled
      *         portion to a separate queue owner.
      * @dev Endpoint-only on-behalf-of flow. Admission uses `availableToUnwrap` with queue keyed to `queueTo` (HUB-02A).
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address for underlying
      * @param queueTo The address to attribute any queued settlement to
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address underlying, bytes32 marketId, address to, address queueTo, uint256 amount)
         external
         nonReentrant
     {
         address lccAddr = s.marketUnderlyingToLCC[marketId][underlying];
         _onlyUnwrapToEndpoint(lccAddr);
         _unwrap(lccAddr, to, queueTo, amount);
     }
 
     // ============ LIQUIDITY FUNCTIONS ============
 
     /**
      * @notice Returns the available liquidity in the market for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of liquidity available in the market (0 if market doesn't exist)
      */
     function marketLiquidity(address lcc) public view returns (uint256) {
         Market memory market = s.lccToMarket[lcc];
         return
             market.id != bytes32(0)
                 ? IMarketFactory(market.factory).marketLiquidity(s.lccToUnderlying[lcc], market.id)
                 : 0;
     }
 
     // ============ ISSUER FUNCTIONS ============
 
     /**
      * @notice Issues LCC tokens (mints to issuer)
      * @param lcc The LCC token address to issue for
      * @param amount The amount to issue
      */
     function issue(address lcc, address to, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC mint path reverts on zero (direct+market) amount.
         // Minting market-derived LCC directly to the DEX sink bypasses transfer hooks and ingress settlement.
         _assertWrapRecipientNotDexSink(lcc, to);
         _mint(lcc, to, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens (burns from specified address)
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param amount The amount to cancel
      */
     function cancel(address lcc, address from, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC burn path reverts on zero (direct+market) amount.
         // `from` is intentionally issuer-selected because issuers are fixed protocol actors (for example ProxyHook and
         // VTSOrchestrator) that cancel along validated protocol flows, not arbitrary public confiscation surfaces.
         // Typical callers burn protocol-controlled holders such as queued settlement holders, MarketVault balances,
         // or staged transfer recipients after the surrounding flow has already proven the accounting path.
         _burn(lcc, from, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens and queues a settlement for the shortfall
      * @dev Simulates unwrap-with-queue without touching direct supply or market liquidity.
      *      Queue recipient shape is validated (non-zero, non-exempt unless Hub), while present settleability
      *      is intentionally enforced at processSettlementFor() when redemption is attempted.
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) public onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
         // Same trusted-issuer rationale as `cancel`: the issuer chooses `from` because this path is used to unwind
         // protocol-side LCC holdings while optionally preserving the recipient's queued settlement claim.
         _cancelWithQueue(lcc, from, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Queues settlement for a recipient after issuer-side deficit transfer.
      * @dev Security checks:
      *      - recipient must be non-zero
      *      - recipient must not be bucket-exempt (external settlement path requires market-derived balance accounting)
      *      - recipient must hold sufficient market-derived LCC to back the queued amount
      *      This path is stricter than generic queue accounting because it is only used when the issuer
      *      has already transferred deficit LCC to `recipient`, so queue owner and burn source must match now.
      */
     function queueForTransferRecipient(address lcc, address recipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         // Deficit queues must target a serviceable external recipient (Hub queueing is not allowed on this path).
         _assertQueueRecipientServiceable(lcc, recipient, amount, false);
         _queueSettlement(lcc, recipient, amount);
     }
 
     /**
      * @dev Internal implementation of cancelWithQueue without access control
      * @param lcc The LCC token address
      * @param from The address to cancel tokens from
      * @param principalAmount The total principal amount being cancelled (cancellable amount is burned from `from`)
      * @param queueAmount The amount to queue for settlement (portion of principalAmount queued for `recipient`)
      * @param recipient The recipient of the queued settlement
      */
     function _cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) internal {
         if (queueAmount > 0) {
             _assertValidQueueOwner(lcc, recipient, true);
         }
 
         uint256 cancelAmount = principalAmount - queueAmount;
 
         // Burn the cancellable portion of the principal amount from the sender.
         // Burn against the sender's actual bucket split (market-derived first, then wrapped).
         // Note: allow cancelAmount == 0 (principal fully queued) without reverting.
         if (cancelAmount > 0) {
             _safeBurn(lcc, from, cancelAmount);
         }
 
         // Queue accounting is intentionally decoupled from current holder backing.
         // Runtime settleability is enforced when processSettlementFor executes.
         _queueSettlement(lcc, recipient, queueAmount);
     }
 
     /**
      * @dev Burns against a holder's bucket split (market-derived first, then wrapped).
      * - Bucket-exempt recipients can burn without bucket accounting.
      * - If `balancesOf` is unavailable (e.g. reentrancy tests that stub LCC), fall back to a full burn.
      */
     function _safeBurn(address lcc, address from, uint256 amount) internal {
         if (amount == 0) return;
 
         if (Bounds.isExempt(boundLevelOfLcc(lcc, from))) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         // IMPORTANT: Some reentrancy-hardening tests replace the LCC code (vm.etch) with a minimal stub that
         // does not implement balancesOf; in that case we must still proceed to the burn to exercise the guard.
         uint256 wrappedBal;
         uint256 marketBal;
         bool hasBuckets = true;
         try ILCC(lcc).balancesOf(from) returns (uint256 wrapped, uint256 market) {
             wrappedBal = wrapped;
             marketBal = market;
         } catch (bytes memory reason) {
             // Keep fallback only for stubbed / non-implemented `balancesOf` paths (empty revert data).
             // Integrity and bucket errors (e.g. `Errors.InvalidBucketState`) must surface.
             if (reason.length == 0) {
                 hasBuckets = false;
             } else {
                 assembly ("memory-safe") {
                     revert(add(reason, 0x20), mload(reason))
                 }
             }
         }
 
         if (!hasBuckets) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         uint256 burnMarket = Math.min(marketBal, amount);
         uint256 remaining = amount - burnMarket;
         uint256 burnDirect = Math.min(wrappedBal, remaining);
         _burn(lcc, from, burnDirect, burnMarket);
     }
 
     /**
      * @notice Plans a cancel operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      This path-keyed store is safe only because current callers stage the plan and then
      *      immediately drive the matching transfer in the same logical path/transaction.
      *      It must not be treated as a general deferred queue across unrelated intermediate logic.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param amount The amount to cancel
      */
     function planCancel(address lcc, address sender, address cancelFromRecipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
 
         // Store the planned cancel in transient storage
         TransientSlots.setPlanCancel(lcc, sender, cancelFromRecipient, amount);
     }
 
     /**
      * @notice Plans a cancel with queue operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      Current MM decrease flows rely on the matching transfer happening immediately after
      *      `modifyLiquidity(...)` returns; if a future flow can stage the same key twice before
      *      consumption, this helper is no longer sufficient.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function planCancelWithQueue(
         address lcc,
         address sender,
         address cancelFromRecipient,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) external onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
 
         // Store the planned cancel with queue in transient storage
         TransientSlots.setPlanCancelWithQueue(lcc, sender, cancelFromRecipient, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Called by MarketVault after taking underlying liquidity from the market to LCC
      * @param lcc The LCC token address
      * @param amount The amount of underlying liquidity taken
      * @param shouldEmit Whether to emit LiquidityAvailable event
      */
     function confirmTake(address lcc, uint256 amount, bool shouldEmit) external onlyIssuer(lcc) {
         // INTENT:
         // `confirmTake()` must be callable from within higher-level flows that themselves may be `nonReentrant`
         // (e.g. `useMarketLiquidity()` eventually triggering a vault -> hub callback).
         // We therefore DO NOT apply `nonReentrant` here; instead, we enforce a strict balance-backed invariant
         // so callers cannot "fabricate" reserves via re-entrancy.
 
         LiquidityHubLib.ConfirmTakeContext memory ctx =
             LiquidityHubLinkedLib.confirmTakePrepare(s, lcc, amount, shouldEmit);
 
         // Best-effort: settle Hub queue up to the newly available amount
         if (ctx.hubQueueBeforeSettlement > 0) {
             _processSettlementFor(lcc, address(this), amount);
         }
 
         if (ctx.emitLiquidityAvailable) {
             // Only emit if there is new liquidity available and not consumed greedily by the Hub
             emit LiquidityAvailable(lcc, ctx.underlying, amount, ctx.marketId);
         }
 
         // Balance-backed invariant: reserve accounting must never exceed actual hub holdings.
         // This protects against re-entrancy and any accidental/malicious unbacked `confirmTake` calls.
         LiquidityHubLinkedLib.confirmTakeBalanceInvariant(s, ctx.underlying);
     }
 
     /**
      * @notice Prepare settlement of underlying from Hub to MarketVault
      * @dev For ERC20, approve the caller (expected MarketVault) to pull tokens; for native, transfer ETH to caller.
      *      Decrements direct reserve and per-LCC directSupply immediately; intended to be called just before settlement
      *      in the same tx.
      */
     function prepareSettle(address lcc, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         LiquidityHubLinkedLib.prepareSettle(s, lcc, amount, _msgSender());
     }
 
     /**
      * @notice Process settlement for a specific recipient using reserveOfUnderlying
      * @dev Permissionless function that allows anyone to process settlements when liquidity is available.
      *      Unified interface: branches behaviour based on whether recipient is address(this) (Hub) or external address.
      *      For Hub: burns Hub-held LCC without transferring underlying or decrementing reserves.
      *      For external: checks holder balance, burns user tokens, transfers underlying, and decrements reserves.
      *      External-path reverts are retriable and signal that reserves/custody are not yet reconciled.
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for (address(this) for Hub's own queue)
      * @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
      */
     function processSettlementFor(address lcc, address recipient, uint256 maxAmount)
         external
         onlyValidLcc(lcc)
         nonReentrant
     {
         _processSettlementFor(lcc, recipient, maxAmount);
     }
 
     /**
      * @notice Atomically releases queued MM custody and settles it against the recipient's Hub queue
      * @dev Best-effort path for MM collection flows. Returns 0 when the queue, reserve, or custody
      *      currently cannot support settlement, instead of reverting.
      * @param lcc The LCC token address
      * @param custodian The MM queue custodian holding beneficiary-scoped queued LCC
      * @param tokenId The commitment token id bucket to debit in the custodian
      * @param recipient The queue owner and settlement recipient
      * @param maxAmount The maximum amount to settle
      */
     function settleFromCustodian(address lcc, address custodian, uint256 tokenId, address recipient, uint256 maxAmount)
         external
         onlyValidLcc(lcc)
         nonReentrant
     {
         uint256 settled = LiquidityHubLinkedLib.settleFromCustodian(s, lcc, custodian, tokenId, recipient, maxAmount);
         if (settled > 0) {
             _processSettlementFor(lcc, recipient, settled);
         }
     }
 
     /**
      * @notice Internal function to process settlement for a specific recipient
      * @dev Delegates to LiquidityHubLib.processSettlementLogic
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for
      * @param maxAmount The maximum amount to settle
      */
     function _processSettlementFor(address lcc, address recipient, uint256 maxAmount) internal {
         uint256 queuedBefore = s.settleQueue[lcc][recipient];
         LiquidityHubLinkedLib.processSettlementLogic(s, lcc, recipient, maxAmount);
         uint256 queuedAfter = s.settleQueue[lcc][recipient];
         uint256 settled = queuedBefore > queuedAfter ? queuedBefore - queuedAfter : 0;
         if (settled > 0) {
             emit SettlementProcessed(lcc, recipient, settled, maxAmount);
         }
     }
 
     // -----------------------------------
     // LCC triggered functions
     // -----------------------------------
 
     /// @notice Called by LCC on transfer to execute any planned cancellations
     /// @dev Assumes at most one live plan per `(lcc, sender, recipient)` path at consumption time.
     ///      The current call graph preserves this by staging the plan immediately before the
     ///      matching transfer; this function does not independently disambiguate multiple same-key plans.
     ///      Planned cancels are intentionally consumed from the transfer path so the burn source is the exact
     ///      protocol-side recipient that just received the LCC, rather than an arbitrary user-selected address.
     function executePlannedCancel(address sender, address cancelFromRecipient) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Check for planned cancel with queue first (more specific)
         (uint256 principalAmount, uint256 queueAmount, address queueRecipient) =
             TransientSlots.consumePlanCancelWithQueue(lcc, sender, cancelFromRecipient);
 
         if (principalAmount > 0) {
             // _cancelWithQueue handles principal == queue (burn 0, queue all) and principal > queue.
             // Use internal function to bypass onlyIssuer check (LCC is the caller, not an issuer).
             _cancelWithQueue(lcc, cancelFromRecipient, principalAmount, queueAmount, queueRecipient);
             return;
         }
 
         // Check for simple planned cancel
         uint256 amount = TransientSlots.consumePlanCancel(lcc, sender, cancelFromRecipient);
         if (amount > 0) {
             _safeBurn(lcc, cancelFromRecipient, amount);
         }
     }
 
     /// @notice Annuls queued settlement before a protocol-bound transfer
     function annulSettlementBeforeTransfer(
         address from,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance,
         uint256 amountToTransfer
     ) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Even if queued == 0 or amountToTransfer == 0, the library path is a no-op.
         // We intentionally avoid an early return here to keep the control flow simpler and more auditable.
         uint256 toAnnul = LiquidityHubLinkedLib.annulSettlementBeforeTransfer(
             s, lcc, from, wrappedBalance, marketDerivedBalance, amountToTransfer
         );
         if (toAnnul > 0) {
             emit SettlementAnnulled(lcc, from, toAnnul);
         }
     }
 
     // ============ SETTLEMENT FUNCTIONS ============
 
     /**
      * @dev Pays an outstanding settlement to an account by burning LCC tokens and transferring underlying assets
      * @param lcc The LCC token address
      * @param owner The owner of the LCC tokens to burn
      * @param to The recipient of the underlying assets
      * @param fromDirect The amount of LCC to burn from direct supply
      * @param fromMarket The amount of LCC to burn from market-derived supply
      */
     function _pay(address lcc, address owner, address to, uint256 fromDirect, uint256 fromMarket) internal {
         LiquidityHubLinkedLib.pay(s, lcc, owner, to, fromDirect, fromMarket);
     }
 
     /**
      * @dev Adds a settlement request to the queue
      * @param lcc The LCC token address
      * @param recipient The address with pending settlements
      * @param amount The amount to eventually settle
      */
     function _assertQueueRecipientServiceable(address lcc, address recipient, uint256 amount, bool allowHub)
         internal
         view
     {
         _assertValidQueueOwner(lcc, recipient, allowHub);
 
         (, uint256 marketDerivedBalance) = ILCC(lcc).balancesOf(recipient);
         if (marketDerivedBalance < amount) {
             revert Errors.InsufficientBalance(marketDerivedBalance, amount);
         }
     }
 
     /**
      * @dev Minimal queue-owner validity check for generic queue creation.
      * Queue owners must not be zero and must not be bucket-exempt unless the queue is intentionally
      * attributed to the Hub itself. This keeps generic queue writes compatible with later settlement,
      * while still allowing queue ownership to be decoupled from current holder backing.
      */
     function _assertValidQueueOwner(address lcc, address recipient, bool allowHub) internal view {
         if (recipient == address(0)) {
             revert Errors.InvalidAddress(recipient);
         }
 
         if (recipient == address(this)) {
             if (!allowHub) revert Errors.NotApproved(recipient);
             return;
         }
 
         if (Bounds.isExempt(boundLevelOfLcc(lcc, recipient))) {
             revert Errors.NotApproved(recipient);
         }
     }
 
     /**
      * @dev Queue accounting helper only.
      * Deliberately does not assert recipient backing/custody because queue ownership may be
      * intentionally decoupled from current LCC holder state. Serviceability is enforced at
      * processSettlementFor(), while explicit transfer-recipient flows validate earlier.
      */
     function _queueSettlement(address lcc, address recipient, uint256 amount) internal {
         if (amount == 0) return;
         LiquidityHubLinkedLib.queueSettlement(s, lcc, recipient, amount);
         emit SettlementQueued(lcc, recipient, amount);
     }
 
     // ============ INTERNAL FUNCTIONS ============
 
     /// @dev Reverts unless `0 < amount <= availableToUnwrap` where `availableToUnwrap = max(0, fromBalance - existingQueue)`.
     function _assertUnwrapWithinHeadroom(uint256 amount, uint256 fromBalance, uint256 existingQueue) private pure {
         uint256 availableToUnwrap = fromBalance > existingQueue ? fromBalance - existingQueue : 0;
         if (amount == 0 || amount > availableToUnwrap) {
             revert Errors.InvalidAmount(amount, availableToUnwrap);
         }
     }
 
     /**
      * @dev Validates that the sender is the canonical vault for a native-backed market
      * @dev Reverts if sender identity is not canonical for the market derived from returned LCCs
      */
     function _assertValidEthSender() internal view {
         address sender = _msgSender();
         if (sender.code.length == 0) revert Errors.InvalidEthSender();
 
         address l0;
         address l1;
         // Prefer a typed call + try/catch over low-level staticcall probing.
         try IMarketVault(sender).lccs() returns (address _l0, address _l1) {
             l0 = _l0;
             l1 = _l1;
         } catch {
             revert Errors.InvalidEthSender();
         }
 
         bool valid0 = LCCFactoryLib.isValidLcc(s, l0);
         bool valid1 = LCCFactoryLib.isValidLcc(s, l1);
         if (!valid0 || !valid1) {
             revert Errors.InvalidEthSender();
         }
 
         Market memory m0 = s.lccToMarket[l0];
         Market memory m1 = s.lccToMarket[l1];
         if (m0.id == bytes32(0) || m1.id == bytes32(0) || m0.id != m1.id || m0.factory != m1.factory) {
             revert Errors.InvalidEthSender();
         }
         if (!isFactory[m0.factory]) {
             revert Errors.InvalidEthSender();
         }
         if (!IMarketFactory(m0.factory).isCanonicalVault(m0.id, sender)) {
             revert Errors.InvalidEthSender();
         }
 
         // Require a native-backed market.
         if (s.lccToUnderlying[l0] != address(0) && s.lccToUnderlying[l1] != address(0)) {
             revert Errors.InvalidEthSender();
         }
     }
 
     /**
      * @notice Receives native ETH transfers from MarketVault contracts
      * @dev Only accepts transfers from valid MarketVault contracts with at least one native ETH LCC.
      *      This enables the route: PoolManager -> MarketVault -> LiquidityHub for native asset settlements.
      *      Reverts if the sender is not a valid MarketVault or if neither LCC uses native ETH as underlying.
      */
     receive() external payable {
         // plain ETH transfer must come from a market vault.
         _assertValidEthSender();
     }
 }
```

## Warnings

### 1. [Medium] Unseeded inactiveRemnantCount in VTSPositionLib on upgrade causes settlement/reactivation DoS and potential fund stranding

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

This PR introduces [Commit.inactiveRemnantCount](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/types/Commit.sol#L36) and synchronization in VTSPositionLib that [decrements the counter and reverts on underflow](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSPositionLib.sol#L350-L355). If upgrading/reusing state without seeding this counter for existing inactive positions holding non-zero settled amounts, attempts to clear or reactivate such positions can revert, and decommit may proceed incorrectly, stranding withdrawable funds.

The PR adds [Commit.inactiveRemnantCount](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/types/Commit.sol#L36) and two synchronization helpers in VTSPositionLib ([_syncInactiveRemnantAfterActiveTransition](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSPositionLib.sol#L350-L355) and [_syncInactiveRemnantAfterSettledPairChange](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSPositionLib.sol#L382-L387)) to track inactive positions with non-zero live settled (pa.settled). These helpers decrement the counter and revert if it reaches zero. If the system is upgraded or state is reused without seeding inactiveRemnantCount to match existing position states, then: (a) clearing an inactive remnant or reactivating a position triggers a decrement from zero and reverts (DoS), and (b) [decommit checks in MMPositionManager](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/MMPositionManager.sol#L304) can pass with a zero counter despite real remnants, allowing NFT burn and stranding withdrawable funds due to subsequent authorization checks. These effects are introduced by the PR’s new counter and sync paths and occur even with otherwise correct protocol behavior.

#### Severity

**Impact Explanation:** [High] Actions that should clear or reactivate positions revert, potentially freezing funds indefinitely; alternatively, incorrect decommit can burn the NFT while remnants exist, stranding user-withdrawable funds—both are direct, material user harm.

**Likelihood Explanation:** [Low] Requires an upgrade or state reuse performed without seeding the new counter—a trusted-admin operational oversight. Fresh deployments are unaffected, and diligent migration can avoid the condition.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Clearing an inactive remnant: A position is inactive with non-zero settled from before the upgrade. The counter was not seeded and is zero. When the user settles to clear the remnant, [VTSPositionLib updates settled](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSPositionLib.sol#L312) and then [attempts to decrement inactiveRemnantCount](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSPositionLib.sol#L244) from zero, reverting and blocking the action.
#### Preconditions / Assumptions
- (a). Upgrade or state reuse to this PR’s code without seeding Commit.inactiveRemnantCount
- (b). At least one position under the commit is inactive (isActive == false) and has non-zero pa.settled
- (c). Commit.inactiveRemnantCount is zero despite real remnants

### Scenario 2.
Reactivating an inactive position with a remnant: A position is inactive with non-zero settled and the counter is zero due to lack of seeding. When adding liquidity to reactivate, VTSPositionLib [attempts to decrement the counter during the active-status transition](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSPositionLib.sol#L1377), underflows, and reverts, preventing reactivation.
#### Preconditions / Assumptions
- (a). Upgrade or state reuse to this PR’s code without seeding Commit.inactiveRemnantCount
- (b). Position is inactive with non-zero pa.settled
- (c). Commit.inactiveRemnantCount is zero despite real remnants

### Scenario 3.
Decommit despite real remnants (funds stranded): A commit has no active positions but does have inactive positions with non-zero settled. Because inactiveRemnantCount was never seeded, it remains zero. [decommit checks in MMPositionManager](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/MMPositionManager.sol#L304) can pass with a zero counter despite real remnants, allowing NFT burn and stranding withdrawable funds due to subsequent authorization checks.
#### Preconditions / Assumptions
- (a). Upgrade or state reuse to this PR’s code without seeding Commit.inactiveRemnantCount
- (b). Commit has no active positions but at least one inactive position has non-zero pa.settled
- (c). Commit.inactiveRemnantCount remains zero despite real remnants

#### Proposed fix

##### VTSPositionLib.sol

File: `contracts/evm/src/libraries/VTSPositionLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSPositionLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
 import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
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
     PositionModificationHookDataLib,
     MMIncreaseHookExtraData
 } from "../types/Position.sol";
 import {Pool} from "../types/Pool.sol";
 import {LiquidityUtils} from "./LiquidityUtils.sol";
 import {Errors} from "./Errors.sol";
 import {VTSFeeLinkedLib} from "./VTSFeeLib.sol";
 import {DynamicCurrencyDelta} from "./DynamicCurrencyDelta.sol";
 import {VTSCommitLib} from "./VTSCommitLib.sol";
 import {CheckpointLibrary} from "./Checkpoint.sol";
 
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
 
     // ============ INTERNAL STRUCTS ============
 
     /// @dev Internal struct to reduce stack depth in _handleLiquidityIncrease
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
 
     /// @dev Shared protocol-credit deposit inputs for MM add and explicit settle-from-deltas paths.
     struct ProtocolCreditSettlementParams {
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
 
         // DICE: Track pool-wide cumulative deficit principal decrease when cumulativeDeficit is netted.
         // commitmentDeficit is an insolvency gate and is intentionally excluded from totalDeficitPrincipal.
         if (cumulativeDeficitCoverage > 0) {
             uint256 currentPrincipal = paPool.totalDeficitPrincipal.get(tokenIndex);
             // Safely decrement (should not underflow if accounting is consistent)
             uint256 newPrincipal =
                 cumulativeDeficitCoverage > currentPrincipal ? 0 : currentPrincipal - cumulativeDeficitCoverage;
             paPool.totalDeficitPrincipal.set(tokenIndex, newPrincipal);
         }
 
         // CISE: Track pool-wide totalSettled aggregate
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
         // - cumulativeDeficitCoverage: decrements pool totalDeficitPrincipal (DICE denominator)
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
+                // FIXME: Migration-safe fallback: instead of reverting when the stored counter is 0 but a decrement
+                // is needed (legacy state after upgrade), compute the actual inactive-remnant count for this commit
+                // and set it here (self-heal) before applying the decrement. Do not revert on first mismatch.
+                // See also: VTSOrchestrator.getCommit computed gating note.
+                // FIXME: Migration-safe fallback: instead of reverting when the stored counter is 0 but a decrement
+                // is needed (legacy state after upgrade), compute the actual inactive-remnant count for this commit
+                // and set it here (self-heal) before applying the decrement. Do not revert on first mismatch.
+                // See also: VTSOrchestrator.getCommit computed gating note.
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
                 // DICE: Track pool-wide deficit principal increase
                 paPool.totalDeficitPrincipal.token0 += deficitIncrease;
                 // DICE: Flush any pending coverage residual now that principal exists
                 VTSFeeLinkedLib.flushCoverageResidualIfNeeded(s, poolId, 0);
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
                 // DICE: Track pool-wide deficit principal increase
                 paPool.totalDeficitPrincipal.token1 += deficitIncrease;
                 // DICE: Flush any pending coverage residual now that principal exists
                 VTSFeeLinkedLib.flushCoverageResidualIfNeeded(s, poolId, 1);
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
 
     /// @dev If Uniswap position liquidity changed without `touchPosition` (e.g. paused remove-liquidity in CoreHook),
     ///      `feeBurnGrowthRemainder` is invalid for the new denominator; clear it.
     ///      We do not overwrite `pos.liquidity` here: harness-only setups may diverge from PoolManager reads; the next
     ///      `touchPosition` still updates the mirror. DICE/coverage burn uses `StateLibrary.getPositionLiquidity` for L.
     function _reconcileLiquidityMirrorAndFeeBurnRemainder(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId
     ) private {
         Position storage pos = s.positions[positionId];
         if (pos.owner == address(0)) return;
 
         uint128 liqLive = StateLibrary.getPositionLiquidity(poolManager, pos.poolId, PositionId.unwrap(positionId));
         if (uint256(pos.liquidity) != uint256(liqLive)) {
             PositionAccounting storage pa = s.positionAccounting[positionId];
             pa.feeBurnGrowthRemainder.token0 = 0;
             pa.feeBurnGrowthRemainder.token1 = 0;
         }
     }
 
     /// @notice Settle both deficit, inflow, and coverage growth for a position
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     //#olympix-ignore-reentrancy
     function settlePositionGrowths(VTSStorage storage s, IPoolManager poolManager, PositionId positionId) public {
         _reconcileLiquidityMirrorAndFeeBurnRemainder(s, poolManager, positionId);
 
         VTSFeeLinkedLib.settleSettledIndexedCoverageUsage(s, positionId);
 
         _settlePositionDeficitGrowth(s, poolManager, positionId);
         // DICE ordering invariant:
         // Before decreasing cumulativeDeficit, we must reconcile the position up to the current
         // coverage-per-deficit index. If inflow netting runs first, the position shrinks principal
         // before we apply already-exercised coverage, understating burn and letting it evade charges
         // incurred while that principal was outstanding.
         VTSFeeLinkedLib.settleDeficitIndexedCoverageUsage(s, poolManager, positionId);
         // Only after DICE has been settled may inflow repay/net principal.
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
 
     /// @dev Initialise fee growth snapshot
     function _initFeeSnapshot(IPoolManager poolManager, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, sp.poolId, sp.tickLower, sp.tickUpper);
         pa.feeGrowthInsideLast.token0 = fg0;
         pa.feeGrowthInsideLast.token1 = fg1;
         pa.feeBurnGrowthRemainder.token0 = 0;
         pa.feeBurnGrowthRemainder.token1 = 0;
     }
 
     /// @dev Initialise DICE coverage index snapshot
     /// @notice Sets coverageIndexLastX128 to current pool coveragePerDeficitIndexX128
     ///         to prevent new positions from inheriting historical coverage charges
     function _initCoverageSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         // DICE: Initialize coverage index checkpoint to current pool index
         // This ensures new positions don't inherit historical coverage charges
         pa.coverageIndexLastX128.token0 = paPool.coveragePerDeficitIndexX128.token0;
         pa.coverageIndexLastX128.token1 = paPool.coveragePerDeficitIndexX128.token1;
         pa.residualCoverageIndexLastX128.token0 = paPool.coveragePerResidualDeficitIndexX128.token0;
         pa.residualCoverageIndexLastX128.token1 = paPool.coveragePerResidualDeficitIndexX128.token1;
     }
 
     /// @dev Initialise CISE coverage index snapshot
     /// @notice Sets ciseIndexLastX128 to current pool coveragePerSettledIndexX128
     ///         to prevent new positions from inheriting historical settled-indexed coverage
     function _initCISESnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp) private {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         pa.ciseIndexLastX128.token0 = paPool.coveragePerSettledIndexX128.token0;
         pa.ciseIndexLastX128.token1 = paPool.coveragePerSettledIndexX128.token1;
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
         _initFeeSnapshot(poolManager, pa, sp);
     }
 
     /// @notice Rebase zero-principal settlement snapshots during inactive-position reactivation.
     /// @dev Only lanes with no current settled / deficit principal are checkpointed to current pool indices.
     ///      Non-zero lanes keep their historical checkpoints so previously-earned DICE / CISE state is preserved.
     function _checkpointZeroPrincipalSettlementSnapshots(VTSStorage storage s, PositionId id) internal {
         Position memory pos = s.positions[id];
         PositionAccounting storage pa = s.positionAccounting[id];
         PoolAccounting storage paPool = s.poolAccounting[pos.poolId];
 
         if (pa.cumulativeDeficit.token0 == 0) {
             pa.coverageIndexLastX128.token0 = paPool.coveragePerDeficitIndexX128.token0;
             pa.residualCoverageIndexLastX128.token0 = paPool.coveragePerResidualDeficitIndexX128.token0;
         }
         if (pa.cumulativeDeficit.token1 == 0) {
             pa.coverageIndexLastX128.token1 = paPool.coveragePerDeficitIndexX128.token1;
             pa.residualCoverageIndexLastX128.token1 = paPool.coveragePerResidualDeficitIndexX128.token1;
         }
         if (pa.settled.token0 == 0) {
             pa.ciseIndexLastX128.token0 = paPool.coveragePerSettledIndexX128.token0;
         }
         if (pa.settled.token1 == 0) {
             pa.ciseIndexLastX128.token1 = paPool.coveragePerSettledIndexX128.token1;
         }
     }
 
     /**
      * @notice Initializes the snapshots for a position. Prevents new positions from inheriting historical tick-indexed growths.
      * @param s The central VTS storage
      * @param poolManager The pool manager contract
      * @param id The id of the position
      */
     function _initPositionSnapshots(VTSStorage storage s, IPoolManager poolManager, PositionId id) internal {
         PositionAccounting storage pa = s.positionAccounting[id];
 
         _checkpointTickIndexedSnapshots(s, poolManager, id);
 
         Position memory pos = s.positions[id];
         PoolId p = pos.poolId;
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, p);
         SnapshotParams memory sp =
             SnapshotParams({poolId: p, tickLower: pos.tickLower, tickUpper: pos.tickUpper, tickCurrent: tickCurrent});
 
         _initCoverageSnapshot(s, pa, sp);
         _initCISESnapshot(s, pa, sp);
     }
 
     /// @notice Touch a position to update its state, process fees, and handle MM-specific operations
     /// @dev Single entry point for position processing - handles registration, linking, fee processing,
     ///      delta accounting, LCC issuance/cancellation, and checkpoint marking
     /// @param s The VTS storage
     /// @param ctx The position context containing dependency references (poolManager, liquidityHub, etc.)
     /// @param p The touchPosition parameters (owner, poolKey, params, callerDelta, feesAccrued, hookData)
     /// @return result The touchPosition result (pos, id, feeAdj)
     /// @notice Decoded hook data for touch position operations
     struct TouchPositionHookData {
         bool isMMOperation;
         bool isSeizing;
         uint256 commitId;
     }
 
     /// @notice Decodes and validates hook data for touch position
     /// @param hookData The raw hook data bytes
     /// @return data The decoded hook data struct
     function _decodeHookData(bytes calldata hookData) private pure returns (TouchPositionHookData memory data) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
         data.isMMOperation = PositionModificationHookDataLib.isMMOperation(mmData);
         data.commitId = mmData.commitId;
         data.isSeizing = mmData.seizure.isSeizing;
     }
 
     /// @dev Applies one protocol-credit deposit lane by consuming live positive underlying delta.
     ///      `requiredSettlementDelta` uses negative sign for deposit requirements when `clampToRequiredSettlement`
     ///      is enabled; otherwise it is ignored.
     function _consumePositiveUnderlyingDeltaForSettlementLane(
         VTSStorage storage s,
         ProtocolCreditSettlementLaneParams memory p
     ) private returns (int128 settlementDelta, int128 remainingRequiredSettlementDelta) {
         remainingRequiredSettlementDelta = p.requiredSettlementDelta;
         if (p.currentUnderlyingDelta <= 0 || p.intendedSettle == 0) {
             return (0, remainingRequiredSettlementDelta);
         }
         if (p.clampToRequiredSettlement && p.requiredSettlementDelta >= 0) {
             return (0, remainingRequiredSettlementDelta);
         }
 
         uint256 availableCredit = LiquidityUtils.safeInt128ToUint256(p.currentUnderlyingDelta);
         uint256 requestedAmount = p.intendedSettle;
         if (requestedAmount > availableCredit) requestedAmount = availableCredit;
         if (p.clampToRequiredSettlement) {
             uint256 requiredAmount = LiquidityUtils.safeInt128ToUint256(p.requiredSettlementDelta);
             if (requestedAmount > requiredAmount) requestedAmount = requiredAmount;
         }
         if (p.isSeizing) {
             if (p.rfsDelta <= 0) return (0, remainingRequiredSettlementDelta);
             uint256 maxSeizingDeposit = LiquidityUtils.safeInt128ToUint256(p.rfsDelta);
             if (requestedAmount > maxSeizingDeposit) requestedAmount = maxSeizingDeposit;
         }
         if (requestedAmount == 0) return (0, remainingRequiredSettlementDelta);
 
         (int256 totalApplied, int256 settledDeltaOnly) =
             _vUpdateSettlement(s, p.positionId, p.tokenIndex, requestedAmount.toInt256());
         if (totalApplied <= 0) return (0, remainingRequiredSettlementDelta);
 
         uint256 creditConsumed = uint256(totalApplied);
         DynamicCurrencyDelta.accountDelta(p.underlyingCurrency, -creditConsumed.toInt128(), p.owner);
         settlementDelta = -creditConsumed.toInt128();
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
         internal
         returns (ProtocolCreditSettlementResult memory result)
     {
         BalanceDelta currentUnderlying =
             DynamicCurrencyDelta.getUnderlyingDeltaPair(p.owner, p.lccCurrency0, p.lccCurrency1);
         (int128 settle0, int128 remaining0) = _consumePositiveUnderlyingDeltaForSettlementLane(
             s,
             ProtocolCreditSettlementLaneParams({
                 positionId: p.positionId,
                 owner: p.owner,
                 underlyingCurrency: DynamicCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0),
                 tokenIndex: 0,
                 currentUnderlyingDelta: currentUnderlying.amount0(),
                 intendedSettle: p.intendedSettle0,
                 requiredSettlementDelta: p.requiredSettlementDelta.amount0(),
                 rfsDelta: p.rfsDelta.amount0(),
                 clampToRequiredSettlement: p.clampToRequiredSettlement,
                 isSeizing: p.isSeizing
             })
         );
         (int128 settle1, int128 remaining1) = _consumePositiveUnderlyingDeltaForSettlementLane(
             s,
             ProtocolCreditSettlementLaneParams({
                 positionId: p.positionId,
                 owner: p.owner,
                 underlyingCurrency: DynamicCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1),
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
     }
 
     /// @dev Settles protocol credit inside the MM add-liquidity hook path before LCC issuance/backing validation.
     function _applyInHookProtocolSettlementForMmIncrease(
         VTSStorage storage s,
         address owner,
         PositionId positionId,
         PoolKey calldata poolKey,
         bytes calldata hookData,
         BalanceDelta requiredSettlementDelta
     ) private returns (BalanceDelta remainingRequiredSettlementDelta) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
         MMIncreaseHookExtraData memory extra = PositionModificationHookDataLib.decodeMMIncreaseHookExtraData(mmData);
         if (!extra.settleInHook) return requiredSettlementDelta;
 
         ProtocolCreditSettlementResult memory result = _settleFromPositiveUnderlyingDelta(
             s,
             ProtocolCreditSettlementParams({
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
 
         remainingRequiredSettlementDelta = result.remainingRequiredSettlementDelta;
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
         if (!hookData.isSeizing) {
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
             // EXISTING POSITION (active or previously inactive)
 
             // Validate no mismatch if commit ID present.
             if (hookData.isMMOperation && hookData.commitId != posStorage.commitId) {
                 revert Errors.InvariantViolated("Invalid operation: Commit ID mismatch");
             }
 
             // Insolvency freeze: do not allow non-seizure MM liquidity changes while commitment deficit persists.
             // Settlement, checkpoint(withCommitment), and seizure paths remain the intended cure/formalise surfaces.
             if (hookData.isMMOperation && !hookData.isSeizing && p.params.liquidityDelta != 0) {
                 PositionAccounting storage paGuard = s.positionAccounting[result.id];
                 if (paGuard.commitmentDeficit.token0 > 0 || paGuard.commitmentDeficit.token1 > 0) {
                     revert Errors.CommitmentDeficitBlocksLiquidityChange(result.id);
                 }
             }
 
             if (p.params.liquidityDelta < 0) {
                 // Disallow decreases on previously-inactive positions. (If liq == 0, Uniswap will revert anyway.)
                 if (!posStorage.isActive) revert Errors.NotActive(result.id);
                 requiredSettlementDelta = _touchExistingDecrease(s, result.id, p.params, liq, hookData);
                 // Mirror using live PoolManager liquidity post-modify for both paused and unpaused removes.
                 PositionAccounting storage paDec = s.positionAccounting[result.id];
                 if (liq == 0) {
                     _captureResidualFeeBackingOnFullDeactivation(
                         s, ctx.poolManager, result.id, liq, p.params.liquidityDelta
                     );
                 } else {
                     uint128 removedLiquidity = uint256(-p.params.liquidityDelta).toUint128();
                     VTSFeeLinkedLib.captureResidualFeeBackingOnPartialDecrease(
                         s, ctx.poolManager, result.id, removedLiquidity
                     );
                 }
                 _applyLiquidityMirrorTransition(s, result.id, paDec, posStorage, initialLiquidity, liq);
             } else {
                 (uint128 liveLiquidityBeforeAdd, uint128 nextLiquidity) =
                     _deriveIncreaseTransitionLiquidity(liq, p.params.liquidityDelta);
                 if (p.params.liquidityDelta > 0) {
                     // Allow re-activating a previously inactive position by adding liquidity.
                     // Logically required to build on value routing while collecting fees on inactive positions.
                     // Rebase tick-indexed snapshots first so the zero-liquidity interval is not charged/credited to
                     // the newly reactivated liquidity.
                     if (liveLiquidityBeforeAdd == 0) {
                         _checkpointTickIndexedSnapshots(s, ctx.poolManager, result.id);
                         _checkpointZeroPrincipalSettlementSnapshots(s, result.id);
                     }
                     requiredSettlementDelta =
                         _touchExistingIncrease(s, poolId, result.id, p.params, nextLiquidity, hookData);
                     if (liveLiquidityBeforeAdd > 0) {
                         _rebaseResidualFeeGrowthOnActiveIncrease(
                             s, ctx.poolManager, poolId, result.id, liveLiquidityBeforeAdd
                         );
                     }
                 } else {
                     // Allow a no-op when active (Uniswap v4 disallows this when initial liq == 0).
                     // See https://github.com/Uniswap/v4-core/blob/36d790b1a3af38461453a13a6ff395290fbc11b2/src/libraries/Position.sol#L86
                     // Refresh commitment maxima from live liquidity (e.g. mirror desync or post-migration).
                     _trackCommitment(s, result.id, liq);
                     requiredSettlementDelta = BalanceDelta.wrap(0);
                 }
                 PositionAccounting storage paRem = s.positionAccounting[result.id];
                 _applyLiquidityMirrorTransition(
                     s, result.id, paRem, posStorage, uint256(liveLiquidityBeforeAdd), nextLiquidity
                 );
             }
         }
 
         if (isNewPosition) {
             _updateStatus(s, result.id, posStorage, initialLiquidity, liq);
         }
 
         result.feeAdj = VTSFeeLinkedLib.afterTouchPosition(s, result.id);
 
         if (hookData.isMMOperation) {
             _processMMOperations(s, ctx, p, result, hookData.commitId, hookData.isSeizing, requiredSettlementDelta);
         }
 
         result.pos = posStorage;
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
 
     /// @dev Rebase fee-growth checkpoints for fee lanes that still have unresolved residual burn base when adding
     ///      liquidity to an already-active position. This prevents newly added liquidity from inheriting the pre-add
     ///      fee window and double counting against already-banked historical residual backing.
     /// @param liquidityBeforeAdd Live position liquidity before this increase (pre-modify units); used to bank any
     ///        fee growth accrued on the surviving slice since `feeGrowthInsideLast` when settlement could not yet
     ///        materialise a burn (e.g. zero outflow window), so rebasing does not erase that window.
     function _rebaseResidualFeeGrowthOnActiveIncrease(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolId poolId,
         PositionId positionId,
         uint128 liquidityBeforeAdd
     ) internal {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         bool needFeeToken0 = pa.pendingResidualBurnBase.token1 > 0;
         bool needFeeToken1 = pa.pendingResidualBurnBase.token0 > 0;
         if (!needFeeToken0 && !needFeeToken1) return;
 
         Position storage pos = s.positions[positionId];
         (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, poolId, pos.tickLower, pos.tickUpper);
 
         if (needFeeToken0 && liquidityBeforeAdd > 0 && fg0 > pa.feeGrowthInsideLast.token0) {
             pa.pendingResidualFeeBacking
             .token0 += FullMath.mulDiv(
                 fg0 - pa.feeGrowthInsideLast.token0, uint256(liquidityBeforeAdd), FixedPoint128.Q128
             );
         }
         if (needFeeToken1 && liquidityBeforeAdd > 0 && fg1 > pa.feeGrowthInsideLast.token1) {
             pa.pendingResidualFeeBacking
             .token1 += FullMath.mulDiv(
                 fg1 - pa.feeGrowthInsideLast.token1, uint256(liquidityBeforeAdd), FixedPoint128.Q128
             );
         }
 
         if (needFeeToken0) pa.feeGrowthInsideLast.token0 = fg0;
         if (needFeeToken1) pa.feeGrowthInsideLast.token1 = fg1;
     }
 
     function _captureResidualFeeBackingOnFullDeactivation(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId,
         uint128 liq,
         int256 liquidityDelta
     ) internal {
         uint128 removedLiquidity = uint256(-liquidityDelta).toUint128();
         uint128 liveLiquidityBeforeRemove = (uint256(liq) + uint256(removedLiquidity)).toUint128();
         VTSFeeLinkedLib.captureResidualFeeBackingOnDeactivation(s, poolManager, positionId, liveLiquidityBeforeRemove);
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
     ///      For MM decreases, callers pass the amount actually routed out of live `settled` in this step: the vault
     ///      immediate slice plus Hub-queued principal (`settleableDelta + queuedDelta`). Any remainder that could not
     ///      be queued stays in `pa.settled` until serviceable; only the immediate slice is mirrored on
     ///      `DynamicCurrencyDelta` (see `_handleLiquidityDecrease`).
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
         if (initialLiquidity != uint256(nextLiquidity)) {
             // Remainder is defined for a fixed liquidity denominator; reset on liquidity changes.
             pa.feeBurnGrowthRemainder.token0 = 0;
             pa.feeBurnGrowthRemainder.token1 = 0;
         }
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
 
     /// @notice Process MM-specific operations (LCC management, deltas, checkpoints)
     /// @dev Extracted to reduce stack pressure in touchPosition
     function _processMMOperations(
         VTSStorage storage s,
         PositionContext memory ctx,
         TouchPositionParams calldata p,
         TouchPositionResult memory result,
         uint256 mmCommitId,
         bool isSeizing,
         BalanceDelta requiredSettlementDelta
     ) internal {
         // CoreHook applies a feeAdj to the callerDelta. ie.  callerDelta = principalDelta - feesAccrued - feeAdj.
         // Treat feeAdj as part of fees for cancel/transfer purposes.
         // ? feeAdj bonus is negative, slash is positive. The result is higher fees for bonus, lower for slash.
         BalanceDelta accruedFeesAfterAdj = p.feesAccrued - result.feeAdj;
 
         // positionDelta(a0/a1) are the gross amounts returned by the PoolManager for position modification.
         // principal0/principal1 = a{0,1} - fees{0,1} reflect the true principal liquidity change
         // that maps to LCC cancellation. fees are trader-derived, wrapped LCC value and must remain wrapped.
         BalanceDelta principalDelta = p.callerDelta - accruedFeesAfterAdj;
 
         // NOTE: LCC fee credits are handled at the MMPM level via balance sync pattern.
         // After MMPM takes from PoolManager, it syncs the LCC balance as credit to locker.
         // This allows direct _take calls for LCC without a separate collectFees function.
 
         // Handle LCC issuance/cancellation based on liquidity direction
         if (p.params.liquidityDelta > 0) {
             // Adding liquidity: settle any hook-carried protocol credit before backing validation/LCC issuance.
             requiredSettlementDelta = _applyInHookProtocolSettlementForMmIncrease(
                 s, p.owner, result.id, p.poolKey, p.hookData, requiredSettlementDelta
             );
             _handleLiquidityIncrease(
                 s,
                 ctx,
                 p.poolKey,
                 p.params,
                 LiquidityIncreaseParams({
                     owner: p.owner, commitId: mmCommitId, positionId: result.id, principalDelta: principalDelta
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
                 PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(p.hookData);
                 queueRecipient = PositionModificationHookDataLib.getLocker(mmData);
             }
 
             // Snapshot routing: `_handleLiquidityDecrease` splits vault-immediate vs Hub queue. Only the sum of
             // those two leaves live `settled` here; any shortfall that cannot be queued stays in `pa.settled`
             // until later liquidity. Booking that remainder on `DynamicCurrencyDelta` would create batch uncleared
             // positive underlying delta (DELTA-01) while the vault cannot pay it in the same unlock.
             BalanceDelta underlyingDeltaSettlement;
             BalanceDelta exportedForSettlementClamp;
             if (isSeizing) {
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
             _applySettlementClampFromExcess(
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
                 DynamicCurrencyDelta.getUnderlyingDeltaPair(p.owner, p.poolKey.currency0, p.poolKey.currency1);
             DynamicCurrencyDelta.accountUnderlyingSettlementDelta(
                 p.owner,
                 LiquidityUtils.safeToBalanceDelta(
                     int256(currentUnderlying.amount0()) + int256(requiredSettlementDelta.amount0()),
                     int256(currentUnderlying.amount1()) + int256(requiredSettlementDelta.amount1())
                 ),
                 p.poolKey.currency0,
                 p.poolKey.currency1
             );
         }
 
         // Mark RFS checkpoint
         (, BalanceDelta rfsDelta) = getRFS(s, result.id);
         CheckpointLibrary.markCheckpoint(s, result.id, _rfsOpenMask(rfsDelta));
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
         PoolKey calldata poolKey,
         ModifyLiquidityParams calldata params,
         LiquidityIncreaseParams memory p
     ) public {
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
 
         // Validate commitment backing in scoped block
         {
             (uint160 sqrtPriceX96, int24 currentTick,,) = ctx.poolManager.getSlot0(poolKey.toId());
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
                     liquidityDelta: params.liquidityDelta
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
 
     /// @dev Stack-isolated core for `_previewLiquidityDecreaseRouting` (MM decrease vault vs queue split).
     // if shortfall <= principal, then yes: settleable + queued == excess
     // if shortfall > principal, then no: settleable + queued < excess
     // Therefore export != excess, and we must accomodate.
     function _computeLiquidityDecreaseRoutingSplit(
         PositionContext memory ctx,
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta
     )
         private
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
 
     /// @dev View-only routing split for MM decreases; must stay aligned with `_handleLiquidityDecrease`.
     ///      Exposed for harness-based unit tests that assert settleable vs queued vs underlying legs.
     function _previewLiquidityDecreaseRouting(
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
             BalanceDelta underlyingDeltaSettlement
         )
     {
         // Check isZeroDelta on both principalDelta and requiredSettlementDelta:
         // if both are zero, we early return the default routing. This ensures that we don't incorrectly route or record shortfalls when requiredSettlementDelta is nonzero but principalDelta is zero (i.e. a pure burn-from-settled case), as vault clamping and state updates are handled elsewhere in the flow.
         if (LiquidityUtils.isZeroDelta(principalDelta) && LiquidityUtils.isZeroDelta(requiredSettlementDelta)) {
             return (0, 0, BalanceDelta.wrap(0), BalanceDelta.wrap(0), BalanceDelta.wrap(0));
         }
 
         BalanceDelta exportedForSettlementClampUnused;
         (
             retainedPrincipal0,
             retainedPrincipal1,
             settleableDelta,
             queuedDelta,
             underlyingDeltaSettlement,
             exportedForSettlementClampUnused
         ) = _computeLiquidityDecreaseRoutingSplit(ctx, principalDelta, requiredSettlementDelta);
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
         PoolKey calldata poolKey,
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

##### VTSOrchestrator.sol

File: `contracts/evm/src/VTSOrchestrator.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VTSOrchestrator.sol)

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
 import {VTSFeeLib} from "./libraries/VTSFeeLib.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {PoolAccounting} from "./types/VTS.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {TokenConfiguration} from "./types/VTS.sol";
 import {VTSAdmin} from "./modules/VTSAdmin.sol";
 
 /// @title VTSOrchestrator
 /// @notice Central state management layer and orchestrator for VTS logic
 /// @dev Adopts Bunni-style pattern: state managed in VTSStorage struct, complex logic delegated to linked libraries
 /// @author Fiet Protocol
 contract VTSOrchestrator is
     PausableVTS,
     VTSAdmin,
     VTSCurrencyDelta,
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
+        // FIXME: For migration safety, compute and return the actual inactive-remnant count (iterate commit positions
+        // and count inactive positions with non-zero pa.settled) instead of relying solely on the stored counter.
+        // Alternatively, expose a separate computed getter and use it for decommit gating in MMPositionManager.
+        // This ensures correct gating even before any post-upgrade self-healing transitions occur.
         Commit storage commit = s.commits[commitId];
         return (
             commit.mmState,
             commit.expiresAt,
             commit.positionCount,
             commit.activePositionCount,
             commit.inactiveRemnantCount
         );
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
     function getProtocolFeeAccrued(PoolId poolId) external view returns (uint256 fee0, uint256 fee1) {
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         return (paPool.protocolFeeAccrued.token0, paPool.protocolFeeAccrued.token1);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function getSlashedPot(PoolId poolId) external view returns (uint256 pot0, uint256 pot1) {
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         return (paPool.slashedPot.token0, paPool.slashedPot.token1);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function getPositionFeeAccounting(PositionId positionId)
         external
         view
         returns (uint256 feesShared0, uint256 feesShared1, int256 pendingFeeAdj0, int256 pendingFeeAdj1)
     {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         return (pa.feesShared.token0, pa.feesShared.token1, pa.pendingFeeAdj.token0, pa.pendingFeeAdj.token1);
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
         // Initialize the market details in the VTS state
         s.pools[corePoolKey.toId()] = Pool({
             currency0: corePoolKey.currency0,
             currency1: corePoolKey.currency1,
             vtsConfig: vtsConfiguration,
             isPaused: false
         });
     }
 
     /// @notice Increment coverage amounts for a pool
     /// @param poolId The pool identifier
     /// @param amount0 Amount to increment for token0
     /// @param amount1 Amount to increment for token1
     function incrementCoverage(PoolId poolId, uint256 amount0, uint256 amount1) external onlyFactory {
         if (amount0 > 0) {
             VTSCommitLib.incrementCoverage(s, poolId, 0, amount0);
         }
         if (amount1 > 0) {
             VTSCommitLib.incrementCoverage(s, poolId, 1, amount1);
         }
     }
 
     // --------------------------------------------------
     // CoreHook VTS Functionality
     // --------------------------------------------------
 
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
     /// @return feeAdj The fee adjustment delta
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
         returns (Position memory pos, PositionId id, BalanceDelta feeAdj, bool isMMPosition)
     {
         isMMPosition = _validateMMOperationLinked(owner, poolKey, hookData);
         (pos, id, feeAdj) = _processPositionLinked(owner, poolKey, params, callerDelta, feesAccrued, hookData);
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
     ) private returns (Position memory pos, PositionId id, BalanceDelta feeAdj) {
         VTSCoreHookContext memory ctx = _coreHookContext();
         (pos, id, feeAdj) =
             VTSLifecycleLinkedLib.processPosition(s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData);
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
     /// @dev Verifies the signal via SignalManager and stores it in the VTS state
     /// @param sender The effective caller (locker) for commit authorisation
     /// @param liquiditySignal The liquidity signal to commit
     /// @return commitId The commit identifier for the committed signal
     function commitSignal(IMarketFactory factory, address sender, bytes memory liquiditySignal)
         external
         onlyIfPoolManagerUnlocked
         onlyIfVRLHandlersRegistered
         nonReentrant
         returns (uint256 commitId)
     {
         commitId = VTSLifecycleLinkedLib.commitSignal(
             s, _commitRouterContext(), factory, _msgSender(), sender, liquiditySignal
         );
     }
 
     /// @notice Commit a liquidity signal using sender-signed EIP-712 relayer authorisation
     /// @dev Same factory-bound sender resolution as `commitSignal`: unbound callers may only relay for themselves.
     /// @param factory Market factory namespace for `_resolveSignalSender` / bound-caller checks only. Signature
     ///        verification and replay protection are enforced by `signalManager` (EIP-712 domain bound to
     ///        `verifyingContract`) and per-sender nonces — not by per-factory validation inside the signed payload.
     function commitSignalRelayed(
         IMarketFactory factory,
         address sender,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external onlyIfPoolManagerUnlocked onlyIfVRLHandlersRegistered nonReentrant returns (uint256 commitId) {
         commitId = VTSLifecycleLinkedLib.commitSignalRelayed(
             s, _commitRouterContext(), factory, _msgSender(), sender, liquiditySignal, deadline, authNonce, authSig
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
 
         RFSCheckpoint memory checkpointOut = VTSLifecycleLinkedLib.extendGracePeriod(
             s, _lifecycleContext(), poolKey, positionId, settlementTokenIndex, verifierIndex, settlementProof
         );
         emit GracePeriodExtended(commitId, positionIndex, settlementTokenIndex, checkpointOut);
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
         returns (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiquidityUnits)
     {
         _assertSignalValid(commitId, !isSeizing);
         _assertBoundFactoryCaller(factory);
 
         PositionId positionId = getPositionId(commitId, positionIndex);
         _assertPositionValid(positionId, false);
 
         Position memory pos = s.positions[positionId];
         if (_msgSender() != pos.owner) revert Errors.InvalidSender();
 
         if (isSeizing) {
             CheckpointLibrary.isSeizable(s, commitId, positionIndex, true);
         }
 
         SettleResult memory result = VTSLifecycleLinkedLib.onMMSettle(
             s, _lifecycleContext(), factory, positionId, pos.poolId, amountDelta, isSeizing, fromDeltas
         );
         settlementDelta = result.settlementDelta;
         rfsOpen = result.rfsOpen;
         seizedLiquidityUnits = result.seizedLiquidityUnits;
 
         // Emit event
         {
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
 
         VTSLifecycleLinkedLib.validateSeize(s, _lifecycleContext(), commitId, positionIndex, positionId);
     }
 
     /// @notice Renew a liquidity signal for an existing commit
     /// @dev Intended for router-style callers (e.g. MMPositionManager) where msg.sender is a forwarding contract.
     /// @param sender The effective caller (locker) used for advancer validation
     /// @param commitId The commit identifier to renew
     /// @param liquiditySignal The new liquidity signal
     function renewSignal(IMarketFactory factory, address sender, uint256 commitId, bytes memory liquiditySignal)
         external
         onlyIfPoolManagerUnlocked
         onlyIfVRLHandlersRegistered
         nonReentrant
     {
         // Validate commit exists (but don't require live signal - expired signals can be seized)
         _assertSignalValid(commitId, false);
         VTSLifecycleLinkedLib.renewSignal(
             s, _commitRouterContext(), factory, _msgSender(), sender, commitId, liquiditySignal
         );
     }
 
     /// @notice Renew a liquidity signal using sender-signed EIP-712 relayer authorisation
     /// @dev Same factory-bound sender resolution as `renewSignal`: unbound callers may only relay for themselves.
     /// @param factory Market factory namespace for `_resolveSignalSender` / bound-caller checks only. EIP-712
     ///        verification remains under `signalManager`; renewals are tied to `commitId` and validated liquidity
     ///        signal ownership within `VTSCommitLib.renewSignalRelayed`.
     function renewSignalRelayed(
         IMarketFactory factory,
         address sender,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external onlyIfPoolManagerUnlocked onlyIfVRLHandlersRegistered nonReentrant {
         _assertSignalValid(commitId, false);
         VTSLifecycleLinkedLib.renewSignalRelayed(
             s,
             _commitRouterContext(),
             factory,
             _msgSender(),
             sender,
             commitId,
             liquiditySignal,
             deadline,
             authNonce,
             authSig
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
 
         RFSCheckpoint memory checkpointOut =
             VTSLifecycleLinkedLib.checkpoint(s, _lifecycleContext(), commitId, withCommitment, positionId);
         emit Checkpointed(commitId, positionIndex, checkpointOut, withCommitment);
     }
 }
```

### 2. [Medium] Missing migration/refresh of commitmentMax in legacy positions causes RFS/withdrawal gating bypass

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

After changing [commitmentMax to be derived from live liquidity](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSPositionLib.sol#L127-L146), legacy positions keep stale (depressed) maxima unless explicitly ‘touched’. Safety-critical flows (RFS checks, withdrawal/seizure sizing) [still read the stored maxima](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSPositionLib.sol#L1872-L1873), allowing non-seizure decreases/withdrawals to pass when they should be blocked and delaying ordinary grace/seizure enforcement.

The PR updates [commitmentMax tracking to always be recomputed from live Uniswap liquidity on position touches](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSPositionLib.sol#L127-L146), but provides no migration/backfill or opportunistic refresh for legacy positions. As a result, pre-upgrade positions retain stale commitmentMax values that may be depressed due to prior incremental rounding/drift. Critical logic (RFS getRFS and seizure sizing) [reads the stored commitmentMax](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSPositionLib.sol#L1872-L1873) without recomputing it during read-only or settle-only flows. In particular, remove-liquidity gating [calls getRFS before any recomputation occurs](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSPositionLib.sol#L1169-L1174), so the gate can be bypassed based on stale maxima. Similarly, MM settlement withdrawals [use RFS from the stored maxima to decide whether to revert](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L479). This mixed-state behavior after upgrade undermines the intended settlement discipline and can delay ordinary grace/seizure enforcement until a position owner voluntarily performs a touch that refreshes commitmentMax.

#### Severity

**Impact Explanation:** [High] Breaking RFS/withdrawal gating on legacy positions undermines a core protocol invariant (required settlement before decreases/withdrawals) and can enable under-settled exits; delayed ordinary grace/seizure enforcement further weakens risk controls.

**Likelihood Explanation:** [Low] Exploitation requires operators not to run a migration/backfill/refresh during upgrade (contrary to the trusted admin/operator assumption) and the attacker to act before any incidental refresh occurs.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Non-seizure remove-liquidity bypass: A legacy MM position with depressed stored commitmentMax removes liquidity post-upgrade. The [RFS gate computes from stale maxima](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSPositionLib.sol#L1169-L1174) (closed) and allows the decrease. Only after passing the gate is commitmentMax recomputed from live liquidity, which is too late to enforce the pre-decrease settlement requirement.
#### Preconditions / Assumptions
- (a). A legacy MM position existed before the upgrade with stored commitmentMax depressed by prior rounding/drift.
- (b). No position-level commitmentDeficit is present (insolvency freeze not active).
- (c). Under corrected (live-liquidity-derived) maxima, RFS would be open prior to the decrease.
- (d). Operators did not perform a migration/backfill/refresh of commitmentMax prior to reopening flows.

### Scenario 2.
onMMSettle withdrawal bypass: A legacy MM position requests a withdrawal via onMMSettle. [RFS is computed from stale maxima](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L262) (closed), so the withdrawal proceeds while it would have been blocked under corrected maxima derived from live liquidity, given withdrawals [revert only when rfsOpen is true](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L479).
#### Preconditions / Assumptions
- (a). A legacy MM position existed before the upgrade with stored commitmentMax depressed by prior rounding/drift.
- (b). No position-level commitmentDeficit is present (insolvency freeze not active).
- (c). Under corrected maxima, RFS would be open and should block withdrawals.
- (d). Operators did not perform a migration/backfill/refresh of commitmentMax prior to reopening flows.

### Scenario 3.
Suppressed ordinary RFS checkpointing: A legacy position is checkpointed; getRFS uses stale maxima and reports RFS closed, so [openMask remains 0](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L687). This delays ordinary grace timing and seizure eligibility that would have started under corrected maxima.
#### Preconditions / Assumptions
- (a). A legacy MM position existed before the upgrade with stored commitmentMax depressed by prior rounding/drift.
- (b). Checkpointing relies on getRFS using stored commitmentMax without a preceding refresh.
- (c). Under corrected maxima, RFS would be open and should start/continue ordinary grace.
- (d). Operators did not perform a migration/backfill/refresh of commitmentMax prior to checkpointing.

#### Proposed fix

##### VTSPositionLib.sol

File: `contracts/evm/src/libraries/VTSPositionLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSPositionLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
 import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
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
     PositionModificationHookDataLib,
     MMIncreaseHookExtraData
 } from "../types/Position.sol";
 import {Pool} from "../types/Pool.sol";
 import {LiquidityUtils} from "./LiquidityUtils.sol";
 import {Errors} from "./Errors.sol";
 import {VTSFeeLinkedLib} from "./VTSFeeLib.sol";
 import {DynamicCurrencyDelta} from "./DynamicCurrencyDelta.sol";
 import {VTSCommitLib} from "./VTSCommitLib.sol";
 import {CheckpointLibrary} from "./Checkpoint.sol";
 
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
 
     // ============ INTERNAL STRUCTS ============
 
     /// @dev Internal struct to reduce stack depth in _handleLiquidityIncrease
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
 
     /// @dev Shared protocol-credit deposit inputs for MM add and explicit settle-from-deltas paths.
     struct ProtocolCreditSettlementParams {
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
 
         // DICE: Track pool-wide cumulative deficit principal decrease when cumulativeDeficit is netted.
         // commitmentDeficit is an insolvency gate and is intentionally excluded from totalDeficitPrincipal.
         if (cumulativeDeficitCoverage > 0) {
             uint256 currentPrincipal = paPool.totalDeficitPrincipal.get(tokenIndex);
             // Safely decrement (should not underflow if accounting is consistent)
             uint256 newPrincipal =
                 cumulativeDeficitCoverage > currentPrincipal ? 0 : currentPrincipal - cumulativeDeficitCoverage;
             paPool.totalDeficitPrincipal.set(tokenIndex, newPrincipal);
         }
 
         // CISE: Track pool-wide totalSettled aggregate
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
         // - cumulativeDeficitCoverage: decrements pool totalDeficitPrincipal (DICE denominator)
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
                 // DICE: Track pool-wide deficit principal increase
                 paPool.totalDeficitPrincipal.token0 += deficitIncrease;
                 // DICE: Flush any pending coverage residual now that principal exists
                 VTSFeeLinkedLib.flushCoverageResidualIfNeeded(s, poolId, 0);
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
                 // DICE: Track pool-wide deficit principal increase
                 paPool.totalDeficitPrincipal.token1 += deficitIncrease;
                 // DICE: Flush any pending coverage residual now that principal exists
                 VTSFeeLinkedLib.flushCoverageResidualIfNeeded(s, poolId, 1);
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
 
     /// @dev If Uniswap position liquidity changed without `touchPosition` (e.g. paused remove-liquidity in CoreHook),
     ///      `feeBurnGrowthRemainder` is invalid for the new denominator; clear it.
     ///      We do not overwrite `pos.liquidity` here: harness-only setups may diverge from PoolManager reads; the next
     ///      `touchPosition` still updates the mirror. DICE/coverage burn uses `StateLibrary.getPositionLiquidity` for L.
     function _reconcileLiquidityMirrorAndFeeBurnRemainder(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId
     ) private {
         Position storage pos = s.positions[positionId];
         if (pos.owner == address(0)) return;
 
         uint128 liqLive = StateLibrary.getPositionLiquidity(poolManager, pos.poolId, PositionId.unwrap(positionId));
         if (uint256(pos.liquidity) != uint256(liqLive)) {
             PositionAccounting storage pa = s.positionAccounting[positionId];
             pa.feeBurnGrowthRemainder.token0 = 0;
             pa.feeBurnGrowthRemainder.token1 = 0;
         }
     }
 
     /// @notice Settle both deficit, inflow, and coverage growth for a position
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     //#olympix-ignore-reentrancy
     function settlePositionGrowths(VTSStorage storage s, IPoolManager poolManager, PositionId positionId) public {
         _reconcileLiquidityMirrorAndFeeBurnRemainder(s, poolManager, positionId);
 
         VTSFeeLinkedLib.settleSettledIndexedCoverageUsage(s, positionId);
 
         _settlePositionDeficitGrowth(s, poolManager, positionId);
         // DICE ordering invariant:
         // Before decreasing cumulativeDeficit, we must reconcile the position up to the current
         // coverage-per-deficit index. If inflow netting runs first, the position shrinks principal
         // before we apply already-exercised coverage, understating burn and letting it evade charges
         // incurred while that principal was outstanding.
         VTSFeeLinkedLib.settleDeficitIndexedCoverageUsage(s, poolManager, positionId);
         // Only after DICE has been settled may inflow repay/net principal.
         _settlePositionInflowGrowth(s, poolManager, positionId);
+
+        // Opportunistic refresh: ensure commitment maxima reflect live PoolManager liquidity
+        // so downstream RFS/seizure reads do not rely on stale stored maxima (post-migration safety).
+        Position memory _pos = s.positions[positionId];
+        uint128 _liqLive = StateLibrary.getPositionLiquidity(poolManager, _pos.poolId, PositionId.unwrap(positionId));
+        _trackCommitment(s, positionId, _liqLive);
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
 
     /// @dev Initialise fee growth snapshot
     function _initFeeSnapshot(IPoolManager poolManager, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, sp.poolId, sp.tickLower, sp.tickUpper);
         pa.feeGrowthInsideLast.token0 = fg0;
         pa.feeGrowthInsideLast.token1 = fg1;
         pa.feeBurnGrowthRemainder.token0 = 0;
         pa.feeBurnGrowthRemainder.token1 = 0;
     }
 
     /// @dev Initialise DICE coverage index snapshot
     /// @notice Sets coverageIndexLastX128 to current pool coveragePerDeficitIndexX128
     ///         to prevent new positions from inheriting historical coverage charges
     function _initCoverageSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         // DICE: Initialize coverage index checkpoint to current pool index
         // This ensures new positions don't inherit historical coverage charges
         pa.coverageIndexLastX128.token0 = paPool.coveragePerDeficitIndexX128.token0;
         pa.coverageIndexLastX128.token1 = paPool.coveragePerDeficitIndexX128.token1;
         pa.residualCoverageIndexLastX128.token0 = paPool.coveragePerResidualDeficitIndexX128.token0;
         pa.residualCoverageIndexLastX128.token1 = paPool.coveragePerResidualDeficitIndexX128.token1;
     }
 
     /// @dev Initialise CISE coverage index snapshot
     /// @notice Sets ciseIndexLastX128 to current pool coveragePerSettledIndexX128
     ///         to prevent new positions from inheriting historical settled-indexed coverage
     function _initCISESnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp) private {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         pa.ciseIndexLastX128.token0 = paPool.coveragePerSettledIndexX128.token0;
         pa.ciseIndexLastX128.token1 = paPool.coveragePerSettledIndexX128.token1;
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
         _initFeeSnapshot(poolManager, pa, sp);
     }
 
     /// @notice Rebase zero-principal settlement snapshots during inactive-position reactivation.
     /// @dev Only lanes with no current settled / deficit principal are checkpointed to current pool indices.
     ///      Non-zero lanes keep their historical checkpoints so previously-earned DICE / CISE state is preserved.
     function _checkpointZeroPrincipalSettlementSnapshots(VTSStorage storage s, PositionId id) internal {
         Position memory pos = s.positions[id];
         PositionAccounting storage pa = s.positionAccounting[id];
         PoolAccounting storage paPool = s.poolAccounting[pos.poolId];
 
         if (pa.cumulativeDeficit.token0 == 0) {
             pa.coverageIndexLastX128.token0 = paPool.coveragePerDeficitIndexX128.token0;
             pa.residualCoverageIndexLastX128.token0 = paPool.coveragePerResidualDeficitIndexX128.token0;
         }
         if (pa.cumulativeDeficit.token1 == 0) {
             pa.coverageIndexLastX128.token1 = paPool.coveragePerDeficitIndexX128.token1;
             pa.residualCoverageIndexLastX128.token1 = paPool.coveragePerResidualDeficitIndexX128.token1;
         }
         if (pa.settled.token0 == 0) {
             pa.ciseIndexLastX128.token0 = paPool.coveragePerSettledIndexX128.token0;
         }
         if (pa.settled.token1 == 0) {
             pa.ciseIndexLastX128.token1 = paPool.coveragePerSettledIndexX128.token1;
         }
     }
 
     /**
      * @notice Initializes the snapshots for a position. Prevents new positions from inheriting historical tick-indexed growths.
      * @param s The central VTS storage
      * @param poolManager The pool manager contract
      * @param id The id of the position
      */
     function _initPositionSnapshots(VTSStorage storage s, IPoolManager poolManager, PositionId id) internal {
         PositionAccounting storage pa = s.positionAccounting[id];
 
         _checkpointTickIndexedSnapshots(s, poolManager, id);
 
         Position memory pos = s.positions[id];
         PoolId p = pos.poolId;
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, p);
         SnapshotParams memory sp =
             SnapshotParams({poolId: p, tickLower: pos.tickLower, tickUpper: pos.tickUpper, tickCurrent: tickCurrent});
 
         _initCoverageSnapshot(s, pa, sp);
         _initCISESnapshot(s, pa, sp);
     }
 
     /// @notice Touch a position to update its state, process fees, and handle MM-specific operations
     /// @dev Single entry point for position processing - handles registration, linking, fee processing,
     ///      delta accounting, LCC issuance/cancellation, and checkpoint marking
     /// @param s The VTS storage
     /// @param ctx The position context containing dependency references (poolManager, liquidityHub, etc.)
     /// @param p The touchPosition parameters (owner, poolKey, params, callerDelta, feesAccrued, hookData)
     /// @return result The touchPosition result (pos, id, feeAdj)
     /// @notice Decoded hook data for touch position operations
     struct TouchPositionHookData {
         bool isMMOperation;
         bool isSeizing;
         uint256 commitId;
     }
 
     /// @notice Decodes and validates hook data for touch position
     /// @param hookData The raw hook data bytes
     /// @return data The decoded hook data struct
     function _decodeHookData(bytes calldata hookData) private pure returns (TouchPositionHookData memory data) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
         data.isMMOperation = PositionModificationHookDataLib.isMMOperation(mmData);
         data.commitId = mmData.commitId;
         data.isSeizing = mmData.seizure.isSeizing;
     }
 
     /// @dev Applies one protocol-credit deposit lane by consuming live positive underlying delta.
     ///      `requiredSettlementDelta` uses negative sign for deposit requirements when `clampToRequiredSettlement`
     ///      is enabled; otherwise it is ignored.
     function _consumePositiveUnderlyingDeltaForSettlementLane(
         VTSStorage storage s,
         ProtocolCreditSettlementLaneParams memory p
     ) private returns (int128 settlementDelta, int128 remainingRequiredSettlementDelta) {
         remainingRequiredSettlementDelta = p.requiredSettlementDelta;
         if (p.currentUnderlyingDelta <= 0 || p.intendedSettle == 0) {
             return (0, remainingRequiredSettlementDelta);
         }
         if (p.clampToRequiredSettlement && p.requiredSettlementDelta >= 0) {
             return (0, remainingRequiredSettlementDelta);
         }
 
         uint256 availableCredit = LiquidityUtils.safeInt128ToUint256(p.currentUnderlyingDelta);
         uint256 requestedAmount = p.intendedSettle;
         if (requestedAmount > availableCredit) requestedAmount = availableCredit;
         if (p.clampToRequiredSettlement) {
             uint256 requiredAmount = LiquidityUtils.safeInt128ToUint256(p.requiredSettlementDelta);
             if (requestedAmount > requiredAmount) requestedAmount = requiredAmount;
         }
         if (p.isSeizing) {
             if (p.rfsDelta <= 0) return (0, remainingRequiredSettlementDelta);
             uint256 maxSeizingDeposit = LiquidityUtils.safeInt128ToUint256(p.rfsDelta);
             if (requestedAmount > maxSeizingDeposit) requestedAmount = maxSeizingDeposit;
         }
         if (requestedAmount == 0) return (0, remainingRequiredSettlementDelta);
 
         (int256 totalApplied, int256 settledDeltaOnly) =
             _vUpdateSettlement(s, p.positionId, p.tokenIndex, requestedAmount.toInt256());
         if (totalApplied <= 0) return (0, remainingRequiredSettlementDelta);
 
         uint256 creditConsumed = uint256(totalApplied);
         DynamicCurrencyDelta.accountDelta(p.underlyingCurrency, -creditConsumed.toInt128(), p.owner);
         settlementDelta = -creditConsumed.toInt128();
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
         internal
         returns (ProtocolCreditSettlementResult memory result)
     {
         BalanceDelta currentUnderlying =
             DynamicCurrencyDelta.getUnderlyingDeltaPair(p.owner, p.lccCurrency0, p.lccCurrency1);
         (int128 settle0, int128 remaining0) = _consumePositiveUnderlyingDeltaForSettlementLane(
             s,
             ProtocolCreditSettlementLaneParams({
                 positionId: p.positionId,
                 owner: p.owner,
                 underlyingCurrency: DynamicCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0),
                 tokenIndex: 0,
                 currentUnderlyingDelta: currentUnderlying.amount0(),
                 intendedSettle: p.intendedSettle0,
                 requiredSettlementDelta: p.requiredSettlementDelta.amount0(),
                 rfsDelta: p.rfsDelta.amount0(),
                 clampToRequiredSettlement: p.clampToRequiredSettlement,
                 isSeizing: p.isSeizing
             })
         );
         (int128 settle1, int128 remaining1) = _consumePositiveUnderlyingDeltaForSettlementLane(
             s,
             ProtocolCreditSettlementLaneParams({
                 positionId: p.positionId,
                 owner: p.owner,
                 underlyingCurrency: DynamicCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1),
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
     }
 
     /// @dev Settles protocol credit inside the MM add-liquidity hook path before LCC issuance/backing validation.
     function _applyInHookProtocolSettlementForMmIncrease(
         VTSStorage storage s,
         address owner,
         PositionId positionId,
         PoolKey calldata poolKey,
         bytes calldata hookData,
         BalanceDelta requiredSettlementDelta
     ) private returns (BalanceDelta remainingRequiredSettlementDelta) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
         MMIncreaseHookExtraData memory extra = PositionModificationHookDataLib.decodeMMIncreaseHookExtraData(mmData);
         if (!extra.settleInHook) return requiredSettlementDelta;
 
         ProtocolCreditSettlementResult memory result = _settleFromPositiveUnderlyingDelta(
             s,
             ProtocolCreditSettlementParams({
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
 
         remainingRequiredSettlementDelta = result.remainingRequiredSettlementDelta;
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
         if (!hookData.isSeizing) {
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
             // EXISTING POSITION (active or previously inactive)
 
             // Validate no mismatch if commit ID present.
             if (hookData.isMMOperation && hookData.commitId != posStorage.commitId) {
                 revert Errors.InvariantViolated("Invalid operation: Commit ID mismatch");
             }
 
             // Insolvency freeze: do not allow non-seizure MM liquidity changes while commitment deficit persists.
             // Settlement, checkpoint(withCommitment), and seizure paths remain the intended cure/formalise surfaces.
             if (hookData.isMMOperation && !hookData.isSeizing && p.params.liquidityDelta != 0) {
                 PositionAccounting storage paGuard = s.positionAccounting[result.id];
                 if (paGuard.commitmentDeficit.token0 > 0 || paGuard.commitmentDeficit.token1 > 0) {
                     revert Errors.CommitmentDeficitBlocksLiquidityChange(result.id);
                 }
             }
 
             if (p.params.liquidityDelta < 0) {
                 // Disallow decreases on previously-inactive positions. (If liq == 0, Uniswap will revert anyway.)
                 if (!posStorage.isActive) revert Errors.NotActive(result.id);
                 requiredSettlementDelta = _touchExistingDecrease(s, result.id, p.params, liq, hookData);
                 // Mirror using live PoolManager liquidity post-modify for both paused and unpaused removes.
                 PositionAccounting storage paDec = s.positionAccounting[result.id];
                 if (liq == 0) {
                     _captureResidualFeeBackingOnFullDeactivation(
                         s, ctx.poolManager, result.id, liq, p.params.liquidityDelta
                     );
                 } else {
                     uint128 removedLiquidity = uint256(-p.params.liquidityDelta).toUint128();
                     VTSFeeLinkedLib.captureResidualFeeBackingOnPartialDecrease(
                         s, ctx.poolManager, result.id, removedLiquidity
                     );
                 }
                 _applyLiquidityMirrorTransition(s, result.id, paDec, posStorage, initialLiquidity, liq);
             } else {
                 (uint128 liveLiquidityBeforeAdd, uint128 nextLiquidity) =
                     _deriveIncreaseTransitionLiquidity(liq, p.params.liquidityDelta);
                 if (p.params.liquidityDelta > 0) {
                     // Allow re-activating a previously inactive position by adding liquidity.
                     // Logically required to build on value routing while collecting fees on inactive positions.
                     // Rebase tick-indexed snapshots first so the zero-liquidity interval is not charged/credited to
                     // the newly reactivated liquidity.
                     if (liveLiquidityBeforeAdd == 0) {
                         _checkpointTickIndexedSnapshots(s, ctx.poolManager, result.id);
                         _checkpointZeroPrincipalSettlementSnapshots(s, result.id);
                     }
                     requiredSettlementDelta =
                         _touchExistingIncrease(s, poolId, result.id, p.params, nextLiquidity, hookData);
                     if (liveLiquidityBeforeAdd > 0) {
                         _rebaseResidualFeeGrowthOnActiveIncrease(
                             s, ctx.poolManager, poolId, result.id, liveLiquidityBeforeAdd
                         );
                     }
                 } else {
                     // Allow a no-op when active (Uniswap v4 disallows this when initial liq == 0).
                     // See https://github.com/Uniswap/v4-core/blob/36d790b1a3af38461453a13a6ff395290fbc11b2/src/libraries/Position.sol#L86
                     // Refresh commitment maxima from live liquidity (e.g. mirror desync or post-migration).
                     _trackCommitment(s, result.id, liq);
                     requiredSettlementDelta = BalanceDelta.wrap(0);
                 }
                 PositionAccounting storage paRem = s.positionAccounting[result.id];
                 _applyLiquidityMirrorTransition(
                     s, result.id, paRem, posStorage, uint256(liveLiquidityBeforeAdd), nextLiquidity
                 );
             }
         }
 
         if (isNewPosition) {
             _updateStatus(s, result.id, posStorage, initialLiquidity, liq);
         }
 
         result.feeAdj = VTSFeeLinkedLib.afterTouchPosition(s, result.id);
 
         if (hookData.isMMOperation) {
             _processMMOperations(s, ctx, p, result, hookData.commitId, hookData.isSeizing, requiredSettlementDelta);
         }
 
         result.pos = posStorage;
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
 
     /// @dev Rebase fee-growth checkpoints for fee lanes that still have unresolved residual burn base when adding
     ///      liquidity to an already-active position. This prevents newly added liquidity from inheriting the pre-add
     ///      fee window and double counting against already-banked historical residual backing.
     /// @param liquidityBeforeAdd Live position liquidity before this increase (pre-modify units); used to bank any
     ///        fee growth accrued on the surviving slice since `feeGrowthInsideLast` when settlement could not yet
     ///        materialise a burn (e.g. zero outflow window), so rebasing does not erase that window.
     function _rebaseResidualFeeGrowthOnActiveIncrease(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolId poolId,
         PositionId positionId,
         uint128 liquidityBeforeAdd
     ) internal {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         bool needFeeToken0 = pa.pendingResidualBurnBase.token1 > 0;
         bool needFeeToken1 = pa.pendingResidualBurnBase.token0 > 0;
         if (!needFeeToken0 && !needFeeToken1) return;
 
         Position storage pos = s.positions[positionId];
         (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, poolId, pos.tickLower, pos.tickUpper);
 
         if (needFeeToken0 && liquidityBeforeAdd > 0 && fg0 > pa.feeGrowthInsideLast.token0) {
             pa.pendingResidualFeeBacking
             .token0 += FullMath.mulDiv(
                 fg0 - pa.feeGrowthInsideLast.token0, uint256(liquidityBeforeAdd), FixedPoint128.Q128
             );
         }
         if (needFeeToken1 && liquidityBeforeAdd > 0 && fg1 > pa.feeGrowthInsideLast.token1) {
             pa.pendingResidualFeeBacking
             .token1 += FullMath.mulDiv(
                 fg1 - pa.feeGrowthInsideLast.token1, uint256(liquidityBeforeAdd), FixedPoint128.Q128
             );
         }
 
         if (needFeeToken0) pa.feeGrowthInsideLast.token0 = fg0;
         if (needFeeToken1) pa.feeGrowthInsideLast.token1 = fg1;
     }
 
     function _captureResidualFeeBackingOnFullDeactivation(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId,
         uint128 liq,
         int256 liquidityDelta
     ) internal {
         uint128 removedLiquidity = uint256(-liquidityDelta).toUint128();
         uint128 liveLiquidityBeforeRemove = (uint256(liq) + uint256(removedLiquidity)).toUint128();
         VTSFeeLinkedLib.captureResidualFeeBackingOnDeactivation(s, poolManager, positionId, liveLiquidityBeforeRemove);
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
     ///      For MM decreases, callers pass the amount actually routed out of live `settled` in this step: the vault
     ///      immediate slice plus Hub-queued principal (`settleableDelta + queuedDelta`). Any remainder that could not
     ///      be queued stays in `pa.settled` until serviceable; only the immediate slice is mirrored on
     ///      `DynamicCurrencyDelta` (see `_handleLiquidityDecrease`).
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
         if (initialLiquidity != uint256(nextLiquidity)) {
             // Remainder is defined for a fixed liquidity denominator; reset on liquidity changes.
             pa.feeBurnGrowthRemainder.token0 = 0;
             pa.feeBurnGrowthRemainder.token1 = 0;
         }
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
 
     /// @notice Process MM-specific operations (LCC management, deltas, checkpoints)
     /// @dev Extracted to reduce stack pressure in touchPosition
     function _processMMOperations(
         VTSStorage storage s,
         PositionContext memory ctx,
         TouchPositionParams calldata p,
         TouchPositionResult memory result,
         uint256 mmCommitId,
         bool isSeizing,
         BalanceDelta requiredSettlementDelta
     ) internal {
         // CoreHook applies a feeAdj to the callerDelta. ie.  callerDelta = principalDelta - feesAccrued - feeAdj.
         // Treat feeAdj as part of fees for cancel/transfer purposes.
         // ? feeAdj bonus is negative, slash is positive. The result is higher fees for bonus, lower for slash.
         BalanceDelta accruedFeesAfterAdj = p.feesAccrued - result.feeAdj;
 
         // positionDelta(a0/a1) are the gross amounts returned by the PoolManager for position modification.
         // principal0/principal1 = a{0,1} - fees{0,1} reflect the true principal liquidity change
         // that maps to LCC cancellation. fees are trader-derived, wrapped LCC value and must remain wrapped.
         BalanceDelta principalDelta = p.callerDelta - accruedFeesAfterAdj;
 
         // NOTE: LCC fee credits are handled at the MMPM level via balance sync pattern.
         // After MMPM takes from PoolManager, it syncs the LCC balance as credit to locker.
         // This allows direct _take calls for LCC without a separate collectFees function.
 
         // Handle LCC issuance/cancellation based on liquidity direction
         if (p.params.liquidityDelta > 0) {
             // Adding liquidity: settle any hook-carried protocol credit before backing validation/LCC issuance.
             requiredSettlementDelta = _applyInHookProtocolSettlementForMmIncrease(
                 s, p.owner, result.id, p.poolKey, p.hookData, requiredSettlementDelta
             );
             _handleLiquidityIncrease(
                 s,
                 ctx,
                 p.poolKey,
                 p.params,
                 LiquidityIncreaseParams({
                     owner: p.owner, commitId: mmCommitId, positionId: result.id, principalDelta: principalDelta
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
                 PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(p.hookData);
                 queueRecipient = PositionModificationHookDataLib.getLocker(mmData);
             }
 
             // Snapshot routing: `_handleLiquidityDecrease` splits vault-immediate vs Hub queue. Only the sum of
             // those two leaves live `settled` here; any shortfall that cannot be queued stays in `pa.settled`
             // until later liquidity. Booking that remainder on `DynamicCurrencyDelta` would create batch uncleared
             // positive underlying delta (DELTA-01) while the vault cannot pay it in the same unlock.
             BalanceDelta underlyingDeltaSettlement;
             BalanceDelta exportedForSettlementClamp;
             if (isSeizing) {
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
             _applySettlementClampFromExcess(
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
                 DynamicCurrencyDelta.getUnderlyingDeltaPair(p.owner, p.poolKey.currency0, p.poolKey.currency1);
             DynamicCurrencyDelta.accountUnderlyingSettlementDelta(
                 p.owner,
                 LiquidityUtils.safeToBalanceDelta(
                     int256(currentUnderlying.amount0()) + int256(requiredSettlementDelta.amount0()),
                     int256(currentUnderlying.amount1()) + int256(requiredSettlementDelta.amount1())
                 ),
                 p.poolKey.currency0,
                 p.poolKey.currency1
             );
         }
 
         // Mark RFS checkpoint
         (, BalanceDelta rfsDelta) = getRFS(s, result.id);
         CheckpointLibrary.markCheckpoint(s, result.id, _rfsOpenMask(rfsDelta));
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
         PoolKey calldata poolKey,
         ModifyLiquidityParams calldata params,
         LiquidityIncreaseParams memory p
     ) public {
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
 
         // Validate commitment backing in scoped block
         {
             (uint160 sqrtPriceX96, int24 currentTick,,) = ctx.poolManager.getSlot0(poolKey.toId());
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
                     liquidityDelta: params.liquidityDelta
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
 
     /// @dev Stack-isolated core for `_previewLiquidityDecreaseRouting` (MM decrease vault vs queue split).
     // if shortfall <= principal, then yes: settleable + queued == excess
     // if shortfall > principal, then no: settleable + queued < excess
     // Therefore export != excess, and we must accomodate.
     function _computeLiquidityDecreaseRoutingSplit(
         PositionContext memory ctx,
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta
     )
         private
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
 
     /// @dev View-only routing split for MM decreases; must stay aligned with `_handleLiquidityDecrease`.
     ///      Exposed for harness-based unit tests that assert settleable vs queued vs underlying legs.
     function _previewLiquidityDecreaseRouting(
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
             BalanceDelta underlyingDeltaSettlement
         )
     {
         // Check isZeroDelta on both principalDelta and requiredSettlementDelta:
         // if both are zero, we early return the default routing. This ensures that we don't incorrectly route or record shortfalls when requiredSettlementDelta is nonzero but principalDelta is zero (i.e. a pure burn-from-settled case), as vault clamping and state updates are handled elsewhere in the flow.
         if (LiquidityUtils.isZeroDelta(principalDelta) && LiquidityUtils.isZeroDelta(requiredSettlementDelta)) {
             return (0, 0, BalanceDelta.wrap(0), BalanceDelta.wrap(0), BalanceDelta.wrap(0));
         }
 
         BalanceDelta exportedForSettlementClampUnused;
         (
             retainedPrincipal0,
             retainedPrincipal1,
             settleableDelta,
             queuedDelta,
             underlyingDeltaSettlement,
             exportedForSettlementClampUnused
         ) = _computeLiquidityDecreaseRoutingSplit(ctx, principalDelta, requiredSettlementDelta);
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
         PoolKey calldata poolKey,
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

### 3. [Low] Unprotected re-initialization in VTSOrchestrator.initPool causes unauthorized unpause and config override

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

[VTSOrchestrator.initPool](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VTSOrchestrator.sol#L454) overwrites an existing pool entry and resets isPaused to false without an initialization guard. Any LiquidityHub-registered factory can re-call it to unpause a pool and change vtsConfig, bypassing owner-only controls.

The function [VTSOrchestrator.initPool](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VTSOrchestrator.sol#L454) [writes s.pools[corePoolKey.toId()] = Pool({currency0, currency1, vtsConfig, isPaused:false})](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VTSOrchestrator.sol#L457-L462) guarded only by [LiquidityHub.isFactory(msg.sender)](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VTSOrchestrator.sol#L136-L139). It lacks a one-time initialization guard and unconditionally [sets isPaused=false](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VTSOrchestrator.sol#L461). While the same PoolKey must be used to target the same PoolId (so currencies cannot be changed for an existing entry), any registered factory can re-call initPool to forcibly unpause the pool and overwrite vtsConfig, effectively bypassing owner-only pause and configuration flows. Seizure/grace mechanics ([CheckpointLibrary.isSeizable](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/Checkpoint.sol#L106-L111)) and fee-sharing ([VTSFeeLib](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSFeeLib.sol#L516-L523)) read vtsConfig live, so this re-init immediately changes protocol behavior for that pool.

#### Severity

**Impact Explanation:** [Medium] Unpausing and policy overrides can significantly alter protocol behavior and user outcomes (e.g., seizure timing and fee-sharing), causing material loss of yield/fees and governance/ACL violations, but do not by themselves cause direct principal theft or unavoidable permanent freezes.

**Likelihood Explanation:** [Low] Exploitation requires misuse, malice, mistake, or compromise of a trusted LiquidityHub-registered factory and, for seizure effects, further authorized actions by the position owner/manager.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Force-unpause a paused pool: A registered factory re-calls [initPool](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VTSOrchestrator.sol#L454) with the original PoolKey and any vtsConfiguration, which overwrites s.pools[poolId] and [sets isPaused=false](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VTSOrchestrator.sol#L461), re-enabling all [notPoolPaused-gated operations](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/modules/PausableVTS.sol#L37-L44) despite a prior owner-imposed pause.
#### Preconditions / Assumptions
- (a). The pool was previously initialized and is currently paused via pausePool(poolId)
- (b). An address is registered as a factory in LiquidityHub (trusted role) and misuses or is compromised
- (c). The attacker knows the exact original PoolKey (publicly derivable)

### Scenario 2.
Manipulate seizure/grace policy: A registered factory re-calls [initPool](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VTSOrchestrator.sol#L454) with extreme vtsConfiguration (e.g., very low bypass bps and zero bypass time or excessively large grace periods). Since [CheckpointLibrary.isSeizable](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/Checkpoint.sol#L106-L111) reads vtsConfig live, ordinary RFS grace or commitment-deficit bypass timing changes immediately, potentially enabling premature or excessively delayed seizures (actual seizure execution still requires position owner authority).
#### Preconditions / Assumptions
- (a). The pool was previously initialized with active positions
- (b). An address is registered as a factory in LiquidityHub (trusted role) and misuses or is compromised
- (c). The attacker knows the exact original PoolKey (publicly derivable)
- (d). Any actual seizure still requires an authorized position owner/manager to execute onMMSettle with seizing=true

### Scenario 3.
Sabotage fee-sharing/yield distribution: A registered factory re-calls [initPool](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VTSOrchestrator.sol#L454) with coverageFeeShare set to 0 or an extreme value, changing [VTSFeeLib](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSFeeLib.sol#L516-L523) behavior so that fee-sharing is disabled or skewed, reducing or redistributing users’ expected yield/fees.
#### Preconditions / Assumptions
- (a). The pool was previously initialized and fee-sharing is in use
- (b). An address is registered as a factory in LiquidityHub (trusted role) and misuses or is compromised
- (c). The attacker knows the exact original PoolKey (publicly derivable)

#### Proposed fix

##### VTSOrchestrator.sol

File: `contracts/evm/src/VTSOrchestrator.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VTSOrchestrator.sol)

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
 import {VTSFeeLib} from "./libraries/VTSFeeLib.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {PoolAccounting} from "./types/VTS.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {TokenConfiguration} from "./types/VTS.sol";
 import {VTSAdmin} from "./modules/VTSAdmin.sol";
 
 /// @title VTSOrchestrator
 /// @notice Central state management layer and orchestrator for VTS logic
 /// @dev Adopts Bunni-style pattern: state managed in VTSStorage struct, complex logic delegated to linked libraries
 /// @author Fiet Protocol
 contract VTSOrchestrator is
     PausableVTS,
     VTSAdmin,
     VTSCurrencyDelta,
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
     function getProtocolFeeAccrued(PoolId poolId) external view returns (uint256 fee0, uint256 fee1) {
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         return (paPool.protocolFeeAccrued.token0, paPool.protocolFeeAccrued.token1);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function getSlashedPot(PoolId poolId) external view returns (uint256 pot0, uint256 pot1) {
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         return (paPool.slashedPot.token0, paPool.slashedPot.token1);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function getPositionFeeAccounting(PositionId positionId)
         external
         view
         returns (uint256 feesShared0, uint256 feesShared1, int256 pendingFeeAdj0, int256 pendingFeeAdj1)
     {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         return (pa.feesShared.token0, pa.feesShared.token1, pa.pendingFeeAdj.token0, pa.pendingFeeAdj.token1);
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
-        // Initialize the market details in the VTS state
-        s.pools[corePoolKey.toId()] = Pool({
+        PoolId poolId = corePoolKey.toId();
+        // Canonical factory only: prevent cross-factory interference
+        IMarketFactory canonicalFactory =
+            liquidityHub.getFactory(Currency.unwrap(corePoolKey.currency0), Currency.unwrap(corePoolKey.currency1));
+        if (address(canonicalFactory) != msg.sender) revert Errors.InvalidSender();
+        // One-time initialization: prevent re-init overwriting config/pause
+        if (Currency.unwrap(s.pools[poolId].currency0) != address(0)) revert Errors.InvalidSender();
+        // Initialize the market details in the VTS state (first init only)
+        s.pools[poolId] = Pool({
             currency0: corePoolKey.currency0,
             currency1: corePoolKey.currency1,
             vtsConfig: vtsConfiguration,
             isPaused: false
         });
     }
 
     /// @notice Increment coverage amounts for a pool
     /// @param poolId The pool identifier
     /// @param amount0 Amount to increment for token0
     /// @param amount1 Amount to increment for token1
     function incrementCoverage(PoolId poolId, uint256 amount0, uint256 amount1) external onlyFactory {
         if (amount0 > 0) {
             VTSCommitLib.incrementCoverage(s, poolId, 0, amount0);
         }
         if (amount1 > 0) {
             VTSCommitLib.incrementCoverage(s, poolId, 1, amount1);
         }
     }
 
     // --------------------------------------------------
     // CoreHook VTS Functionality
     // --------------------------------------------------
 
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
     /// @return feeAdj The fee adjustment delta
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
         returns (Position memory pos, PositionId id, BalanceDelta feeAdj, bool isMMPosition)
     {
         isMMPosition = _validateMMOperationLinked(owner, poolKey, hookData);
         (pos, id, feeAdj) = _processPositionLinked(owner, poolKey, params, callerDelta, feesAccrued, hookData);
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
     ) private returns (Position memory pos, PositionId id, BalanceDelta feeAdj) {
         VTSCoreHookContext memory ctx = _coreHookContext();
         (pos, id, feeAdj) =
             VTSLifecycleLinkedLib.processPosition(s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData);
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
     /// @dev Verifies the signal via SignalManager and stores it in the VTS state
     /// @param sender The effective caller (locker) for commit authorisation
     /// @param liquiditySignal The liquidity signal to commit
     /// @return commitId The commit identifier for the committed signal
     function commitSignal(IMarketFactory factory, address sender, bytes memory liquiditySignal)
         external
         onlyIfPoolManagerUnlocked
         onlyIfVRLHandlersRegistered
         nonReentrant
         returns (uint256 commitId)
     {
         commitId = VTSLifecycleLinkedLib.commitSignal(
             s, _commitRouterContext(), factory, _msgSender(), sender, liquiditySignal
         );
     }
 
     /// @notice Commit a liquidity signal using sender-signed EIP-712 relayer authorisation
     /// @dev Same factory-bound sender resolution as `commitSignal`: unbound callers may only relay for themselves.
     /// @param factory Market factory namespace for `_resolveSignalSender` / bound-caller checks only. Signature
     ///        verification and replay protection are enforced by `signalManager` (EIP-712 domain bound to
     ///        `verifyingContract`) and per-sender nonces — not by per-factory validation inside the signed payload.
     function commitSignalRelayed(
         IMarketFactory factory,
         address sender,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external onlyIfPoolManagerUnlocked onlyIfVRLHandlersRegistered nonReentrant returns (uint256 commitId) {
         commitId = VTSLifecycleLinkedLib.commitSignalRelayed(
             s, _commitRouterContext(), factory, _msgSender(), sender, liquiditySignal, deadline, authNonce, authSig
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
 
         RFSCheckpoint memory checkpointOut = VTSLifecycleLinkedLib.extendGracePeriod(
             s, _lifecycleContext(), poolKey, positionId, settlementTokenIndex, verifierIndex, settlementProof
         );
         emit GracePeriodExtended(commitId, positionIndex, settlementTokenIndex, checkpointOut);
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
         returns (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiquidityUnits)
     {
         _assertSignalValid(commitId, !isSeizing);
         _assertBoundFactoryCaller(factory);
 
         PositionId positionId = getPositionId(commitId, positionIndex);
         _assertPositionValid(positionId, false);
 
         Position memory pos = s.positions[positionId];
         if (_msgSender() != pos.owner) revert Errors.InvalidSender();
 
         if (isSeizing) {
             CheckpointLibrary.isSeizable(s, commitId, positionIndex, true);
         }
 
         SettleResult memory result = VTSLifecycleLinkedLib.onMMSettle(
             s, _lifecycleContext(), factory, positionId, pos.poolId, amountDelta, isSeizing, fromDeltas
         );
         settlementDelta = result.settlementDelta;
         rfsOpen = result.rfsOpen;
         seizedLiquidityUnits = result.seizedLiquidityUnits;
 
         // Emit event
         {
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
 
         VTSLifecycleLinkedLib.validateSeize(s, _lifecycleContext(), commitId, positionIndex, positionId);
     }
 
     /// @notice Renew a liquidity signal for an existing commit
     /// @dev Intended for router-style callers (e.g. MMPositionManager) where msg.sender is a forwarding contract.
     /// @param sender The effective caller (locker) used for advancer validation
     /// @param commitId The commit identifier to renew
     /// @param liquiditySignal The new liquidity signal
     function renewSignal(IMarketFactory factory, address sender, uint256 commitId, bytes memory liquiditySignal)
         external
         onlyIfPoolManagerUnlocked
         onlyIfVRLHandlersRegistered
         nonReentrant
     {
         // Validate commit exists (but don't require live signal - expired signals can be seized)
         _assertSignalValid(commitId, false);
         VTSLifecycleLinkedLib.renewSignal(
             s, _commitRouterContext(), factory, _msgSender(), sender, commitId, liquiditySignal
         );
     }
 
     /// @notice Renew a liquidity signal using sender-signed EIP-712 relayer authorisation
     /// @dev Same factory-bound sender resolution as `renewSignal`: unbound callers may only relay for themselves.
     /// @param factory Market factory namespace for `_resolveSignalSender` / bound-caller checks only. EIP-712
     ///        verification remains under `signalManager`; renewals are tied to `commitId` and validated liquidity
     ///        signal ownership within `VTSCommitLib.renewSignalRelayed`.
     function renewSignalRelayed(
         IMarketFactory factory,
         address sender,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external onlyIfPoolManagerUnlocked onlyIfVRLHandlersRegistered nonReentrant {
         _assertSignalValid(commitId, false);
         VTSLifecycleLinkedLib.renewSignalRelayed(
             s,
             _commitRouterContext(),
             factory,
             _msgSender(),
             sender,
             commitId,
             liquiditySignal,
             deadline,
             authNonce,
             authSig
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
 
         RFSCheckpoint memory checkpointOut =
             VTSLifecycleLinkedLib.checkpoint(s, _lifecycleContext(), commitId, withCommitment, positionId);
         emit Checkpointed(commitId, positionIndex, checkpointOut, withCommitment);
     }
 }
```

### 4. [Low] Zero-amount cancel skip in MarketVault._cancelLCCWithDeficit under ProxyHook exact-input deficit causes stuck user output at non-LCC-aware recipients

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

A PR change to [MarketVault._cancelLCCWithDeficit](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/modules/MarketVault.sol#L312-L332) skips [LiquidityHub.cancel](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L724-L739) when amountToCancel==0. In ProxyHook exact-input swaps with zero vault underlying, this turns a fully-deficit case from revert into success, transferring the entire output as market-derived LCC to a user-controlled recipient and queuing settlement. If the recipient is a non-LCC-aware contract (e.g., router), the user’s output can become practically stuck there.

The PR modifies [MarketVault._cancelLCCWithDeficit](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/modules/MarketVault.sol#L312-L332) so that when the vault’s deliverable underlying is zero (amountToCancel==0), it no longer calls [LiquidityHub.cancel (which reverts on zero)](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L724-L739), but instead proceeds to transfer deficit LCC to the resolved recipient and queue the settlement claim. ProxyHook’s exact-input flow allows a user-controlled deficit recipient (locker, RECIPIENT_ROUTER, or explicit address) and [only forbids deficit when no recipient can be resolved](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/ProxyHook.sol#L372-L386). [LiquidityHub.queueForTransferRecipient](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L742-L761) validates recipient shape and backing, [which are satisfied because LCC is transferred first](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L1084-L1103). Before this change, a fully-deficit exact-input swap would revert at cancel(0), preventing stuck states [via LCC.burn’s zero-amount revert](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LCC.sol#L126-L137). After the change, swaps succeed even when no underlying can be settled immediately, and if the recipient is a non-LCC-aware contract (e.g., a router without settlement forwarding), the user’s output (LCC + queued claim) can be practically stuck at that address. Typical routers with nonzero minOut and locker-to-user resolution mitigate this, but misconfigured integrations remain exposed.

#### Severity

**Impact Explanation:** [Medium] User output value can be stuck at a non-LCC-aware contract (router or arbitrary contract) as market-derived LCC and queued settlement. While not theft and with a manual rescue path available via trusted issuer operations, this represents a meaningful loss of access to principal until intervention.

**Likelihood Explanation:** [Low] Exploitation depends on integration choices (recipient set to a non-LCC-aware contract, weak/zero minOut) and deficit state alignment (fully or partially drained vault at execution). Typical deployments use nonzero minOut and resolve recipients to the end-user (EOA), reducing likelihood.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Fully-deficit exact-input swap where the integrator passes RECIPIENT_ROUTER and minOut=0: ProxyHook resolves the router as the recipient; MarketVault skips cancel(0) and transfers the full output as LCC to the router and queues settlement; swap succeeds with zero immediate underlying; the router cannot unwrap or process settlement, so value is stuck there.
#### Preconditions / Assumptions
- (a). Deployed version includes the PR change that skips LiquidityHub.cancel on amountToCancel==0
- (b). ProxyHook is used with MarketVault and LiquidityHub wired
- (c). Integration sets hookData to RECIPIENT_ROUTER so recipient resolves to the router contract
- (d). Router is not bucket-exempt and lacks LCC/settlement handling or rescue logic
- (e). Router sets amountOutMinimum=0 (or equivalently non-protective)
- (f). Vault has zero available underlying for the output token at execution time (fully-deficit)

### Scenario 2.
Fully-deficit exact-input swap where hookData specifies an explicit non-LCC-aware contract as recipient and minOut=0: MarketVault skips cancel(0), transfers full deficit LCC to that contract and queues settlement; swap succeeds but the contract cannot redeem, leaving the user’s output stuck.
#### Preconditions / Assumptions
- (a). Deployed version includes the PR change that skips LiquidityHub.cancel on amountToCancel==0
- (b). ProxyHook is used with MarketVault and LiquidityHub wired
- (c). Integration passes an explicit non-LCC-aware recipient address in hookData
- (d). Recipient is not bucket-exempt and lacks LCC/settlement handling or rescue logic
- (e). Router or dApp sets amountOutMinimum=0 (or equivalently non-protective)
- (f). Vault has zero available underlying for the output token at execution time (fully-deficit)

### Scenario 3.
Partial-deficit exact-input swap where minOut is satisfied: MarketVault cancels the available portion and transfers the residual deficit as LCC to the router/contract recipient and queues settlement; the user receives some underlying now, but the residual value remains stuck at the non-LCC-aware contract.
#### Preconditions / Assumptions
- (a). Deployed version includes the PR change
- (b). ProxyHook is used with MarketVault and LiquidityHub wired
- (c). Integration sets recipient to RECIPIENT_ROUTER or another non-LCC-aware contract
- (d). Vault has some but insufficient available underlying for the output token (partial deficit)
- (e). amountOutMinimum is set below the available underlying so the swap passes

#### Proposed fix

##### LiquidityHub.sol

File: `contracts/evm/src/LiquidityHub.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
 import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {LCCFactoryLib, LCCFactoryLinkedLib} from "./libraries/LCCFactoryLib.sol";
 import {LiquidityHubLib} from "./libraries/LiquidityHubLib.sol";
 import {LiquidityHubLinkedLib} from "./libraries/LiquidityHubLinkedLib.sol";
 import {LiquidityHubStorage, Market, UnderlyingReserve} from "./types/Liquidity.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {IMarketVault} from "./interfaces/IMarketVault.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {BoundRegistry} from "./modules/BoundRegistry.sol";
 import {Bounds} from "./libraries/Bounds.sol";
 
 /**
  * @title LiquidityHub
  * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
  * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
  */
 contract LiquidityHub is BoundRegistry, Ownable, ReentrancyGuardTransient {
     using CurrencyTransfer for Currency;
 
     // ============ UNIFIED STATE ============
     LiquidityHubStorage internal s;
 
     IOracleHelper public immutable oracleHelper;
 
     event FactorySet(address indexed factory, bool enabled);
     event LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId);
     event LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId);
     event SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementAnnulled(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementProcessed(
         address indexed lcc, address indexed recipient, uint256 settledAmount, uint256 requestedAmount
     );
     event LccWrappedWith(address indexed lcc, address indexed withLCC, address from, address to, uint256 amount);
     event LccWrapped(address indexed lcc, address from, address to, uint256 amount);
     event LccUnwrapped(address indexed lcc, address from, address to, uint256 amount);
 
     // IMPORTANT NOTE: The LiquidityHub is agnostic/unaware of the end account.
     // Similarly to how PoolManager leverages periphery contracts to manage end-account balances, the LiquidityHub aggregates balances, and uses LCCs to track account balances in a hub-and-spoke model.
 
     // Map of market factories
     mapping(address => bool) public isFactory;
 
     /**
      * @notice Constructs the LiquidityHub contract
      * @param _oracleHelper The oracle helper contract address
      * @param _nativeAssetName The name of the native asset (e.g., "Ether")
      * @param _nativeAssetSymbol The symbol of the native asset (e.g., "ETH")
      * @param _nativeAssetDecimals The decimals of the native asset (typically 18)
      * @param _initialOwner The initial owner of the contract
      */
     constructor(
         address _oracleHelper,
         string memory _nativeAssetName,
         string memory _nativeAssetSymbol,
         uint8 _nativeAssetDecimals,
         address _initialOwner
     ) Ownable(_initialOwner) {
         oracleHelper = IOracleHelper(_oracleHelper);
         LCCFactoryLib.initNativeAsset(s, _nativeAssetName, _nativeAssetSymbol, _nativeAssetDecimals);
     }
 
     /**
      * @notice Modifier to restrict access to registered factory contracts only
      */
     modifier onlyFactory() {
         _onlyFactory();
         _;
     }
 
     function _onlyFactory() internal view {
         if (!isFactory[_msgSender()]) {
             revert Errors.InvalidSender();
         }
     }
 
     /// Override from BoundRegistry
     function _lccMarket(address lcc) internal view override returns (bytes32 id, address factory) {
         Market memory market = s.lccToMarket[lcc];
         return (market.id, market.factory);
     }
 
     /// Override from BoundRegistry
     function setBoundLevel(address who, uint8 level) external override onlyFactory {
         // `BoundRegistry._setBoundLevel` enforces EXEMPT/DEX immutability and first-assignment-from-NONE.
         // The stronger policy that EXEMPT/DEX only arise from hardcoded setup / integration paths must be expressed by
         // the specific `MarketFactory` implementation using this hub; registered factories are trusted for that setup policy.
         // Queue-owner safety when moving an address into exempt remains an operational concern (not indexed on-chain).
         _setBoundLevel(msg.sender, who, level);
     }
 
     /// Override from BoundRegistry
     function setBoundLevels(address[] calldata who, uint8 level) external override onlyFactory {
         for (uint256 i = 0; i < who.length; i++) {
             _setBoundLevel(msg.sender, who[i], level);
         }
     }
 
     /**
      * @notice Modifier to ensure the provided LCC address is valid
      * @param lcc The LCC token address to validate
      */
     modifier onlyValidLcc(address lcc) {
         LiquidityHubLib.assertValidLcc(s, lcc);
         _;
     }
 
     /**
      * @notice Modifier to restrict access to issuers of a specific LCC token
      * @param lcc The LCC token address to check issuer status for
      */
     modifier onlyIssuer(address lcc) {
         _onlyIssuer(lcc);
         _;
     }
 
     function _onlyIssuer(address lcc) internal view {
         // Strict invariant: issuer-gated paths must never operate on invalid/uninitialised LCCs.
         LiquidityHubLib.assertValidLcc(s, lcc);
         if (!LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender)) {
             revert Errors.NotApproved(msg.sender);
         }
     }
 
     /**
      * @dev All `unwrapTo` overloads are endpoint-mediated on-behalf-of flows (e.g. `MMPositionManager`).
      *      Direct users unwrap via `unwrap(...)` which queues shortfalls to the caller.
      *      Caller must be `BOUND_ENDPOINT` in the LCC's market factory namespace (not EXEMPT/DEX).
      */
     function _onlyUnwrapToEndpoint(address lcc) internal view {
         if (boundLevelOfLcc(lcc, _msgSender()) != Bounds.BOUND_ENDPOINT) {
             revert Errors.InvalidSender();
         }
     }
 
     // ============ PUBLIC ACCESSORS ============
 
     /**
      * @notice Returns the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address, or address(0) if not found
      */
     function marketUnderlyingToLCC(bytes32 marketId, address underlying) external view returns (address) {
         return s.marketUnderlyingToLCC[marketId][underlying];
     }
 
     /**
      * @notice Returns the underlying asset address for a given LCC token
      * @param lcc The LCC token address
      * @return The underlying asset address (address(0) for native ETH)
      */
     function lccToUnderlying(address lcc) public view returns (address) {
         return s.lccToUnderlying[lcc];
     }
 
     /**
      * @notice Returns the Market struct for a given LCC token
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function lccToMarket(address lcc) external view returns (bytes32, address) {
         return _lccMarket(lcc);
     }
 
     /**
      * @notice
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function getFactory(address lcc0, address lcc1) external view returns (IMarketFactory) {
         address factory0 = s.lccToMarket[lcc0].factory;
         address factory1 = s.lccToMarket[lcc1].factory;
         if (factory0 != factory1) {
             revert Errors.InvariantViolated("LCCs are not from the same market");
         }
         return IMarketFactory(factory0);
     }
 
     /**
      * @notice Checks if an address is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @param issuer The address to check
      * @return True if the address is an issuer, false otherwise
      */
     function issuers(address lcc, address issuer) external view returns (bool) {
         return s.issuers[lcc][issuer];
     }
 
     /**
      * @notice Gets the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address
      */
     function getLCC(bytes32 marketId, address underlying) external view returns (address) {
         return LCCFactoryLib.getLCC(s, marketId, underlying);
     }
 
     /**
      * @notice Gets the underlying asset address for a given LCC token
      * @param lccToken The LCC token address
      * @return The underlying asset address
      */
     function getUnderlying(address lccToken) external view returns (address) {
         return LCCFactoryLib.getUnderlying(s, lccToken);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function isLCC(address lcc) external view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Returns the direct supply (wrapped underlying) for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of direct supply
      */
     function directSupply(address lcc) external view returns (uint256) {
         return s.directSupply[lcc];
     }
 
     /**
      * @notice Returns the shared reserve of underlying assets for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of underlying assets held in reserve for this LCC
      */
     function reserveOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return reserve.direct + reserve.marketDerived;
     }
 
     /**
      * @notice Returns the split underlying reserve tuple for a given LCC token
      * @param lcc The LCC token address
      * @return direct The reserve component backing direct/wrapped supply
      * @return marketDerived The reserve component mobilised from market-derived flows
      */
     function reserveOfUnderlyingTuple(address lcc)
         external
         view
         onlyValidLcc(lcc)
         returns (uint256 direct, uint256 marketDerived)
     {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return (reserve.direct, reserve.marketDerived);
     }
 
     /**
      * @notice Returns the queued settlement amount for a specific LCC and recipient
      * @param lcc The LCC token address
      * @param recipient The recipient address
      * @return The amount queued for settlement
      */
     function settleQueue(address lcc, address recipient) external view returns (uint256) {
         return s.settleQueue[lcc][recipient];
     }
 
     /**
      * @notice Returns the total queued settlement amount for a given LCC token
      * @param lcc The LCC token address
      * @return The total amount queued across all recipients
      */
     function totalQueued(address lcc) external view returns (uint256) {
         return s.totalQueued[lcc];
     }
 
     /**
      * @notice Returns the total queued settlement debt for the underlying of a given LCC
      * @param lcc The LCC token address
      * @return The total queued debt aggregated across all LCCs sharing the same underlying
      */
     function queueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         return s.queueOfUnderlying[s.lccToUnderlying[lcc]];
     }
 
     /**
      * @notice Returns the unfunded queued debt for the underlying of a given LCC
      * @dev Unfunded debt is `max(queueOfUnderlying - marketDerivedReserve, 0)` at the shared-underlying level.
      * @param lcc The LCC token address
      * @return The remaining underlying shortfall that still needs market-to-Hub mobilisation
      */
     function unfundedQueueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         address underlying = s.lccToUnderlying[lcc];
         uint256 queued = s.queueOfUnderlying[underlying];
         uint256 reserve = s.reserveOfUnderlying[underlying].marketDerived;
         return queued > reserve ? queued - reserve : 0;
     }
 
     // ============ ADMIN FUNCTIONS ============
 
     /**
      * @notice Sets or removes a factory address from the allowed factories list
      * @param factory The factory address to enable or disable
      * @param enabled Whether the factory should be enabled (true) or disabled (false)
      */
     function setFactory(address factory, bool enabled) external onlyOwner {
         isFactory[factory] = enabled;
         emit FactorySet(factory, enabled);
     }
 
     /**
      * @notice Creates LCC token pair for a market
      * @param marketRef The market reference (bytes from proxyHookAddress)
      * @param underlyingAsset0 The first underlying asset address
      * @param underlyingAsset1 The second underlying asset address
      * @param marketName The market name
      * @param initialIssuers Array of addresses to set as issuers for both LCC tokens
      * @return lccToken0 The first LCC token address
      * @return lccToken1 The second LCC token address
      */
     function createLCCPair(
         bytes memory marketRef,
         address underlyingAsset0,
         address underlyingAsset1,
         string memory marketName,
         address[] memory initialIssuers
     ) external onlyFactory returns (address lccToken0, address lccToken1) {
         address resilientOracleAddress = oracleHelper.oracle();
         address factory = _msgSender();
         address[2] memory underlyingPair = [underlyingAsset0, underlyingAsset1];
         lccToken0 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 0, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
         lccToken1 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 1, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
 
         // Emit events for LCC creation
         emit LCCCreated(underlyingAsset0, lccToken0, s.lccToMarket[lccToken0].id);
         emit LCCCreated(underlyingAsset1, lccToken1, s.lccToMarket[lccToken1].id);
     }
 
     /**
      * @notice Initializes the mapping from LCC tokens to Market (with ID and Ref)
      * @dev Order-insensitive: `lccToken0` and `lccToken1` are treated independently; no `(0,1)` lane semantics exist here.
      *      Canonical market ordering (for pair lanes) is defined by the core pool key in `MarketFactory`, not by argument order.
      * @param lccToken0 The first LCC token address
      * @param lccToken1 The second LCC token address
      * @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
      * @param marketRef The market reference (bytes from proxyHookAddress)
      */
     function initialize(address lccToken0, address lccToken1, bytes32 marketId, bytes memory marketRef)
         external
         onlyFactory
     {
         LCCFactoryLib.initialize(s, lccToken0, lccToken1, marketId, marketRef, _msgSender());
     }
 
     // ============ INTERNAL HELPERS (delegate to library) ============
 
     /**
      * @notice Checks if the current caller is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @return True if the caller is an issuer, false otherwise
      */
     function _isCallerIssuer(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function _isValidLcc(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Mints LCC tokens to an address
      * @param lccToken The LCC token address
      * @param to The address to mint tokens to
      * @param directAmount The amount to mint as direct supply
      * @param marketAmount The amount to mint as market-derived supply
      */
     function _mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.mint(lccToken, to, directAmount, marketAmount);
     }
 
     /**
      * @notice Burns LCC tokens from an address
      * @param lccToken The LCC token address
      * @param from The address to burn tokens from
      * @param directAmount The amount to burn from direct supply
      * @param marketAmount The amount to burn from market-derived supply
      */
     function _burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.burn(lccToken, from, directAmount, marketAmount);
     }
 
     /**
      * @notice Gets the total balance (wrapped + market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return The total balance
      */
     function _balanceOf(address lccToken, address account) internal view returns (uint256) {
         return LCCFactoryLib.balanceOf(lccToken, account);
     }
 
     /**
      * @notice Gets the bucketed balances (wrapped and market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return wrapped The wrapped (direct) balance
      * @return marketDerived The market-derived balance
      */
     function _balancesOf(address lccToken, address account)
         internal
         view
         returns (uint256 wrapped, uint256 marketDerived)
     {
         return LCCFactoryLib.balancesOf(lccToken, account);
     }
 
     function _assertWrapRecipientNotDexSink(address lcc, address to) internal view {
         if (Bounds.isDex(boundLevel(s.lccToMarket[lcc].factory, to))) {
             revert Errors.DirectWrapToDexNotAllowed(to);
         }
     }
 
     // ============ TRADER FUNCTIONS ============
 
     // DirectLPs and Traders engaging the CorePool directly will need LCC. LCC is 1:1 with the underlying asset.
     /**
      * @dev Internal function to wrap underlying assets into LCC tokens
      * @param lcc The LCC token address to wrap into
      * @param to The address receiving the LCC tokens
      * @param amount The amount of underlying assets to wrap
      */
     function _wrap(address lcc, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         address underlying = s.lccToUnderlying[lcc];
         bool isNativeAsset = underlying == address(0);
 
         // Mint-time ingress to the DEX sink bypasses LCC transfer hooks.
         // Reject it until there is a safe settlement path that can run under PoolManager lock constraints.
         _assertWrapRecipientNotDexSink(lcc, to);
 
         // throw error if the native ETH is insufficient and it is a native ETH backed LCC
         if (isNativeAsset) {
             if (msg.value != amount) {
                 revert Errors.InvalidAmount(0, 0);
             }
         } else {
             if (msg.value != 0) {
                 revert Errors.InvalidAmount(0, 0);
             }
             // Use CurrencyTransfer which has Permit2 fallback for ERC20 transfers
             Currency.wrap(underlying).transferFrom(from, address(this), amount);
         }
 
         s.directSupply[lcc] += amount;
         s.reserveOfUnderlying[underlying].direct += amount;
 
         // mint some tokens
         _mint(lcc, to, amount, 0);
 
         emit LccWrapped(lcc, from, to, amount);
     }
 
     function wrapTo(address lcc, address to, uint256 amount) external payable nonReentrant {
         _wrap(lcc, to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens and sends them to a specified recipient
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address
      * @param amount The amount of underlying assets to wrap
      */
     function wrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller
      * @param lcc The LCC token address
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address lcc, uint256 amount) external payable nonReentrant {
         _wrap(lcc, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address underlying, bytes32 marketId, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), amount);
     }
 
     /**
      * @notice Internal function to wrap LCC using another LCC as backing, with O(1) flattening and netting
      * @dev Delegates to LiquidityHubLib.wrapWithLogic - heavy logic moved to library
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The address receiving the target LCC
      * @param amount The amount to wrap
      */
     function _wrapWith(address lcc, address withLCC, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
 
         // wrapWithTo shares the same mint surface as direct wrap and must not bypass DEX ingress handling.
         _assertWrapRecipientNotDexSink(lcc, to);
 
         // Performs all necessary validation and preparation
         LiquidityHubLib.WrapWithContext memory ctx =
             LiquidityHubLinkedLib.wrapWithPrepare(s, lcc, withLCC, from, amount);
         // Pull backing LCC from caller into the Hub first.
         Currency.wrap(withLCC).transferFrom(from, address(this), ctx.originalAmount);
         // Executes the full wrap-with operation using the provided context
         ctx = LiquidityHubLinkedLib.wrapWithContext(s, lcc, withLCC, ctx);
         // Extract return values.
         // Note: wrapWithContext is designed to conserve amounts. Any mismatch is a logic bug in the library.
         uint256 directToMint = ctx.directToMint;
         uint256 marketToMint = ctx.marketToMint;
 
         // Final mint: mint target LCC with appropriate direct/market-derived split
         LCCFactoryLib.mint(lcc, to, directToMint, marketToMint);
 
         if (ctx.queuedShortfall > 0) {
             // Ensure the queued settlement event is emitted
             emit SettlementQueued(withLCC, address(this), ctx.queuedShortfall);
         }
 
         emit LccWrappedWith(lcc, withLCC, from, to, amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing for the caller
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param amount The amount to wrap
      */
     function wrapWith(address lcc, address withLCC, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing and sends to a specified recipient
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The recipient address
      * @param amount The amount to wrap
      */
     function wrapWithTo(address lcc, address withLCC, address to, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, to, amount);
     }
 
     /**
      * @dev Unwraps LCC from the account's wallet and transfers underlying assets to recipient
      * @dev Accounts should only be able to unwrap if they have LCC in their wallet
      * @dev Unwrap headroom (`availableToUnwrap`) nets any existing settlement queue for `queueTo` against the
      *      caller-held balance (`from`), so the same LCC cannot back repeated queued shortfalls.
      *      - Self-unwrap paths (`unwrap`, `unwrapTo` with `to == queueTo`): `queueTo == from`, so the queue is netted
      *        against the same user's live balance.
      *      - Endpoint `unwrapTo(lcc, to, queueTo, ...)`: supported only when the endpoint acts on behalf of the
      *        beneficiary named by `queueTo`; caller-held balance is treated as representing that beneficiary for this
      *        unwrap (see HUB-02A in INVARIANTS.md).
      * @param lcc The LCC token address to unwrap
      * @param to The recipient of the underlying asset
      * @param queueTo The address to queue shortfall to
      * @param amount The amount to unwrap
      */
     function _unwrap(address lcc, address to, address queueTo, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         (uint256 wrappedBalance, uint256 marketDerivedBalance) = _balancesOf(lcc, from);
         uint256 fromBalance = wrappedBalance + marketDerivedBalance;
 
         // Generic queue paths validate queue-owner shape only.
         // Current settleability remains a redemption-time concern for processSettlementFor().
         _assertValidQueueOwner(lcc, queueTo, true);
 
         _assertUnwrapWithinHeadroom(amount, fromBalance, s.settleQueue[lcc][queueTo]);
 
         (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) =
             LiquidityHubLinkedLib.unwrapInternalLogic(s, lcc, queueTo, amount, wrappedBalance, marketDerivedBalance);
 
         // `unwrapInternalLogic` updates queue state directly in library storage.
         // Queue owner shape is validated at write time; present settleability is enforced on settlement.
 
         // Burn the amount that was unwrapped
         // and transfer the underlying assets to the account
         if (directUnwrapped + marketUnwrapped > 0) {
             _pay(lcc, from, to, directUnwrapped, marketUnwrapped);
         }
         if (queuedShortfall > 0) {
             emit SettlementQueued(lcc, queueTo, queuedShortfall);
         }
 
         emit LccUnwrapped(lcc, from, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller
      * @param lcc The LCC token address to unwrap
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address lcc, uint256 amount) external nonReentrant {
         _unwrap(lcc, _msgSender(), _msgSender(), amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address underlying, bytes32 marketId, uint256 amount) external nonReentrant {
         _unwrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), _msgSender(), amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient
      * @dev Endpoint-only: caller must be `BOUND_ENDPOINT` for this LCC's market. Direct users use `unwrap(...)`.
      *      Shortfalls queue to `to`; admission is capped by `availableToUnwrap` (see `_unwrap` NatSpec, HUB-02).
      * @param lcc The LCC token address to unwrap
      * @param to The recipient address
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address lcc, address to, uint256 amount) external nonReentrant {
         _onlyUnwrapToEndpoint(lcc);
         // Backwards-compatible: queue shortfalls to the same address receiving the underlying.
         _unwrap(lcc, to, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient, while queueing any
      *         unfulfilled portion to a separate queue owner.
      * @dev Endpoint-only on-behalf-of flow (e.g. MMPM): "who receives underlying now" may differ from queue owner.
      *      Admission is capped by netting `settleQueue[lcc][queueTo]` against the caller-held balance (HUB-02 / HUB-02A).
      * @param lcc The LCC token address to unwrap
      * @param to The recipient address for underlying
      * @param queueTo The address to attribute any queued settlement to
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address lcc, address to, address queueTo, uint256 amount) external nonReentrant {
         _onlyUnwrapToEndpoint(lcc);
         _unwrap(lcc, to, queueTo, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient (overloaded)
      * @dev Endpoint-only: caller must be `BOUND_ENDPOINT` for the resolved LCC. Direct users use `unwrap(...)`.
      *      Admission uses `availableToUnwrap` with queue keyed to `to` (HUB-02).
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external nonReentrant {
         address lccAddr = s.marketUnderlyingToLCC[marketId][underlying];
         _onlyUnwrapToEndpoint(lccAddr);
         _unwrap(lccAddr, to, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens (resolved by underlying+marketId) to underlying assets, while queueing any unfulfilled
      *         portion to a separate queue owner.
      * @dev Endpoint-only on-behalf-of flow. Admission uses `availableToUnwrap` with queue keyed to `queueTo` (HUB-02A).
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address for underlying
      * @param queueTo The address to attribute any queued settlement to
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address underlying, bytes32 marketId, address to, address queueTo, uint256 amount)
         external
         nonReentrant
     {
         address lccAddr = s.marketUnderlyingToLCC[marketId][underlying];
         _onlyUnwrapToEndpoint(lccAddr);
         _unwrap(lccAddr, to, queueTo, amount);
     }
 
     // ============ LIQUIDITY FUNCTIONS ============
 
     /**
      * @notice Returns the available liquidity in the market for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of liquidity available in the market (0 if market doesn't exist)
      */
     function marketLiquidity(address lcc) public view returns (uint256) {
         Market memory market = s.lccToMarket[lcc];
         return
             market.id != bytes32(0)
                 ? IMarketFactory(market.factory).marketLiquidity(s.lccToUnderlying[lcc], market.id)
                 : 0;
     }
 
     // ============ ISSUER FUNCTIONS ============
 
     /**
      * @notice Issues LCC tokens (mints to issuer)
      * @param lcc The LCC token address to issue for
      * @param amount The amount to issue
      */
     function issue(address lcc, address to, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC mint path reverts on zero (direct+market) amount.
         // Minting market-derived LCC directly to the DEX sink bypasses transfer hooks and ingress settlement.
         _assertWrapRecipientNotDexSink(lcc, to);
         _mint(lcc, to, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens (burns from specified address)
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param amount The amount to cancel
      */
     function cancel(address lcc, address from, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC burn path reverts on zero (direct+market) amount.
         // `from` is intentionally issuer-selected because issuers are fixed protocol actors (for example ProxyHook and
         // VTSOrchestrator) that cancel along validated protocol flows, not arbitrary public confiscation surfaces.
         // Typical callers burn protocol-controlled holders such as queued settlement holders, MarketVault balances,
         // or staged transfer recipients after the surrounding flow has already proven the accounting path.
         _burn(lcc, from, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens and queues a settlement for the shortfall
      * @dev Simulates unwrap-with-queue without touching direct supply or market liquidity.
      *      Queue recipient shape is validated (non-zero, non-exempt unless Hub), while present settleability
      *      is intentionally enforced at processSettlementFor() when redemption is attempted.
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) public onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
         // Same trusted-issuer rationale as `cancel`: the issuer chooses `from` because this path is used to unwind
         // protocol-side LCC holdings while optionally preserving the recipient's queued settlement claim.
         _cancelWithQueue(lcc, from, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Queues settlement for a recipient after issuer-side deficit transfer.
      * @dev Security checks:
      *      - recipient must be non-zero
      *      - recipient must not be bucket-exempt (external settlement path requires market-derived balance accounting)
      *      - recipient must hold sufficient market-derived LCC to back the queued amount
      *      This path is stricter than generic queue accounting because it is only used when the issuer
      *      has already transferred deficit LCC to `recipient`, so queue owner and burn source must match now.
      */
     function queueForTransferRecipient(address lcc, address recipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
+        // Contract recipients must be explicitly endpoint-bound in this market's namespace.
+        // This prevents routing issuer-driven deficits to arbitrary/non-serviceable contracts.
+        if (recipient.code.length > 0) {
+            if (boundLevelOfLcc(lcc, recipient) < Bounds.BOUND_ENDPOINT) {
+                revert Errors.NotApproved(recipient);
+            }
+        }
         // Deficit queues must target a serviceable external recipient (Hub queueing is not allowed on this path).
         _assertQueueRecipientServiceable(lcc, recipient, amount, false);
         _queueSettlement(lcc, recipient, amount);
     }
 
     /**
      * @dev Internal implementation of cancelWithQueue without access control
      * @param lcc The LCC token address
      * @param from The address to cancel tokens from
      * @param principalAmount The total principal amount being cancelled (cancellable amount is burned from `from`)
      * @param queueAmount The amount to queue for settlement (portion of principalAmount queued for `recipient`)
      * @param recipient The recipient of the queued settlement
      */
     function _cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) internal {
         if (queueAmount > 0) {
             _assertValidQueueOwner(lcc, recipient, true);
         }
 
         uint256 cancelAmount = principalAmount - queueAmount;
 
         // Burn the cancellable portion of the principal amount from the sender.
         // Burn against the sender's actual bucket split (market-derived first, then wrapped).
         // Note: allow cancelAmount == 0 (principal fully queued) without reverting.
         if (cancelAmount > 0) {
             _safeBurn(lcc, from, cancelAmount);
         }
 
         // Queue accounting is intentionally decoupled from current holder backing.
         // Runtime settleability is enforced when processSettlementFor executes.
         _queueSettlement(lcc, recipient, queueAmount);
     }
 
     /**
      * @dev Burns against a holder's bucket split (market-derived first, then wrapped).
      * - Bucket-exempt recipients can burn without bucket accounting.
      * - If `balancesOf` is unavailable (e.g. reentrancy tests that stub LCC), fall back to a full burn.
      */
     function _safeBurn(address lcc, address from, uint256 amount) internal {
         if (amount == 0) return;
 
         if (Bounds.isExempt(boundLevelOfLcc(lcc, from))) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         // IMPORTANT: Some reentrancy-hardening tests replace the LCC code (vm.etch) with a minimal stub that
         // does not implement balancesOf; in that case we must still proceed to the burn to exercise the guard.
         uint256 wrappedBal;
         uint256 marketBal;
         bool hasBuckets = true;
         try ILCC(lcc).balancesOf(from) returns (uint256 wrapped, uint256 market) {
             wrappedBal = wrapped;
             marketBal = market;
         } catch (bytes memory reason) {
             // Keep fallback only for stubbed / non-implemented `balancesOf` paths (empty revert data).
             // Integrity and bucket errors (e.g. `Errors.InvalidBucketState`) must surface.
             if (reason.length == 0) {
                 hasBuckets = false;
             } else {
                 assembly ("memory-safe") {
                     revert(add(reason, 0x20), mload(reason))
                 }
             }
         }
 
         if (!hasBuckets) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         uint256 burnMarket = Math.min(marketBal, amount);
         uint256 remaining = amount - burnMarket;
         uint256 burnDirect = Math.min(wrappedBal, remaining);
         _burn(lcc, from, burnDirect, burnMarket);
     }
 
     /**
      * @notice Plans a cancel operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      This path-keyed store is safe only because current callers stage the plan and then
      *      immediately drive the matching transfer in the same logical path/transaction.
      *      It must not be treated as a general deferred queue across unrelated intermediate logic.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param amount The amount to cancel
      */
     function planCancel(address lcc, address sender, address cancelFromRecipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
 
         // Store the planned cancel in transient storage
         TransientSlots.setPlanCancel(lcc, sender, cancelFromRecipient, amount);
     }
 
     /**
      * @notice Plans a cancel with queue operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      Current MM decrease flows rely on the matching transfer happening immediately after
      *      `modifyLiquidity(...)` returns; if a future flow can stage the same key twice before
      *      consumption, this helper is no longer sufficient.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function planCancelWithQueue(
         address lcc,
         address sender,
         address cancelFromRecipient,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) external onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
 
         // Store the planned cancel with queue in transient storage
         TransientSlots.setPlanCancelWithQueue(lcc, sender, cancelFromRecipient, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Called by MarketVault after taking underlying liquidity from the market to LCC
      * @param lcc The LCC token address
      * @param amount The amount of underlying liquidity taken
      * @param shouldEmit Whether to emit LiquidityAvailable event
      */
     function confirmTake(address lcc, uint256 amount, bool shouldEmit) external onlyIssuer(lcc) {
         // INTENT:
         // `confirmTake()` must be callable from within higher-level flows that themselves may be `nonReentrant`
         // (e.g. `useMarketLiquidity()` eventually triggering a vault -> hub callback).
         // We therefore DO NOT apply `nonReentrant` here; instead, we enforce a strict balance-backed invariant
         // so callers cannot "fabricate" reserves via re-entrancy.
 
         LiquidityHubLib.ConfirmTakeContext memory ctx =
             LiquidityHubLinkedLib.confirmTakePrepare(s, lcc, amount, shouldEmit);
 
         // Best-effort: settle Hub queue up to the newly available amount
         if (ctx.hubQueueBeforeSettlement > 0) {
             _processSettlementFor(lcc, address(this), amount);
         }
 
         if (ctx.emitLiquidityAvailable) {
             // Only emit if there is new liquidity available and not consumed greedily by the Hub
             emit LiquidityAvailable(lcc, ctx.underlying, amount, ctx.marketId);
         }
 
         // Balance-backed invariant: reserve accounting must never exceed actual hub holdings.
         // This protects against re-entrancy and any accidental/malicious unbacked `confirmTake` calls.
         LiquidityHubLinkedLib.confirmTakeBalanceInvariant(s, ctx.underlying);
     }
 
     /**
      * @notice Prepare settlement of underlying from Hub to MarketVault
      * @dev For ERC20, approve the caller (expected MarketVault) to pull tokens; for native, transfer ETH to caller.
      *      Decrements direct reserve and per-LCC directSupply immediately; intended to be called just before settlement
      *      in the same tx.
      */
     function prepareSettle(address lcc, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         LiquidityHubLinkedLib.prepareSettle(s, lcc, amount, _msgSender());
     }
 
     /**
      * @notice Process settlement for a specific recipient using reserveOfUnderlying
      * @dev Permissionless function that allows anyone to process settlements when liquidity is available.
      *      Unified interface: branches behaviour based on whether recipient is address(this) (Hub) or external address.
      *      For Hub: burns Hub-held LCC without transferring underlying or decrementing reserves.
      *      For external: checks holder balance, burns user tokens, transfers underlying, and decrements reserves.
      *      External-path reverts are retriable and signal that reserves/custody are not yet reconciled.
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for (address(this) for Hub's own queue)
      * @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
      */
     function processSettlementFor(address lcc, address recipient, uint256 maxAmount)
         external
         onlyValidLcc(lcc)
         nonReentrant
     {
         _processSettlementFor(lcc, recipient, maxAmount);
     }
 
     /**
      * @notice Atomically releases queued MM custody and settles it against the recipient's Hub queue
      * @dev Best-effort path for MM collection flows. Returns 0 when the queue, reserve, or custody
      *      currently cannot support settlement, instead of reverting.
      * @param lcc The LCC token address
      * @param custodian The MM queue custodian holding beneficiary-scoped queued LCC
      * @param tokenId The commitment token id bucket to debit in the custodian
      * @param recipient The queue owner and settlement recipient
      * @param maxAmount The maximum amount to settle
      */
     function settleFromCustodian(address lcc, address custodian, uint256 tokenId, address recipient, uint256 maxAmount)
         external
         onlyValidLcc(lcc)
         nonReentrant
     {
         uint256 settled = LiquidityHubLinkedLib.settleFromCustodian(s, lcc, custodian, tokenId, recipient, maxAmount);
         if (settled > 0) {
             _processSettlementFor(lcc, recipient, settled);
         }
     }
 
     /**
      * @notice Internal function to process settlement for a specific recipient
      * @dev Delegates to LiquidityHubLib.processSettlementLogic
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for
      * @param maxAmount The maximum amount to settle
      */
     function _processSettlementFor(address lcc, address recipient, uint256 maxAmount) internal {
         uint256 queuedBefore = s.settleQueue[lcc][recipient];
         LiquidityHubLinkedLib.processSettlementLogic(s, lcc, recipient, maxAmount);
         uint256 queuedAfter = s.settleQueue[lcc][recipient];
         uint256 settled = queuedBefore > queuedAfter ? queuedBefore - queuedAfter : 0;
         if (settled > 0) {
             emit SettlementProcessed(lcc, recipient, settled, maxAmount);
         }
     }
 
     // -----------------------------------
     // LCC triggered functions
     // -----------------------------------
 
     /// @notice Called by LCC on transfer to execute any planned cancellations
     /// @dev Assumes at most one live plan per `(lcc, sender, recipient)` path at consumption time.
     ///      The current call graph preserves this by staging the plan immediately before the
     ///      matching transfer; this function does not independently disambiguate multiple same-key plans.
     ///      Planned cancels are intentionally consumed from the transfer path so the burn source is the exact
     ///      protocol-side recipient that just received the LCC, rather than an arbitrary user-selected address.
     function executePlannedCancel(address sender, address cancelFromRecipient) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Check for planned cancel with queue first (more specific)
         (uint256 principalAmount, uint256 queueAmount, address queueRecipient) =
             TransientSlots.consumePlanCancelWithQueue(lcc, sender, cancelFromRecipient);
 
         if (principalAmount > 0) {
             // _cancelWithQueue handles principal == queue (burn 0, queue all) and principal > queue.
             // Use internal function to bypass onlyIssuer check (LCC is the caller, not an issuer).
             _cancelWithQueue(lcc, cancelFromRecipient, principalAmount, queueAmount, queueRecipient);
             return;
         }
 
         // Check for simple planned cancel
         uint256 amount = TransientSlots.consumePlanCancel(lcc, sender, cancelFromRecipient);
         if (amount > 0) {
             _safeBurn(lcc, cancelFromRecipient, amount);
         }
     }
 
     /// @notice Annuls queued settlement before a protocol-bound transfer
     function annulSettlementBeforeTransfer(
         address from,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance,
         uint256 amountToTransfer
     ) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Even if queued == 0 or amountToTransfer == 0, the library path is a no-op.
         // We intentionally avoid an early return here to keep the control flow simpler and more auditable.
         uint256 toAnnul = LiquidityHubLinkedLib.annulSettlementBeforeTransfer(
             s, lcc, from, wrappedBalance, marketDerivedBalance, amountToTransfer
         );
         if (toAnnul > 0) {
             emit SettlementAnnulled(lcc, from, toAnnul);
         }
     }
 
     // ============ SETTLEMENT FUNCTIONS ============
 
     /**
      * @dev Pays an outstanding settlement to an account by burning LCC tokens and transferring underlying assets
      * @param lcc The LCC token address
      * @param owner The owner of the LCC tokens to burn
      * @param to The recipient of the underlying assets
      * @param fromDirect The amount of LCC to burn from direct supply
      * @param fromMarket The amount of LCC to burn from market-derived supply
      */
     function _pay(address lcc, address owner, address to, uint256 fromDirect, uint256 fromMarket) internal {
         LiquidityHubLinkedLib.pay(s, lcc, owner, to, fromDirect, fromMarket);
     }
 
     /**
      * @dev Adds a settlement request to the queue
      * @param lcc The LCC token address
      * @param recipient The address with pending settlements
      * @param amount The amount to eventually settle
      */
     function _assertQueueRecipientServiceable(address lcc, address recipient, uint256 amount, bool allowHub)
         internal
         view
     {
         _assertValidQueueOwner(lcc, recipient, allowHub);
 
         (, uint256 marketDerivedBalance) = ILCC(lcc).balancesOf(recipient);
         if (marketDerivedBalance < amount) {
             revert Errors.InsufficientBalance(marketDerivedBalance, amount);
         }
     }
 
     /**
      * @dev Minimal queue-owner validity check for generic queue creation.
      * Queue owners must not be zero and must not be bucket-exempt unless the queue is intentionally
      * attributed to the Hub itself. This keeps generic queue writes compatible with later settlement,
      * while still allowing queue ownership to be decoupled from current holder backing.
      */
     function _assertValidQueueOwner(address lcc, address recipient, bool allowHub) internal view {
         if (recipient == address(0)) {
             revert Errors.InvalidAddress(recipient);
         }
 
         if (recipient == address(this)) {
             if (!allowHub) revert Errors.NotApproved(recipient);
             return;
         }
 
         if (Bounds.isExempt(boundLevelOfLcc(lcc, recipient))) {
             revert Errors.NotApproved(recipient);
         }
     }
 
     /**
      * @dev Queue accounting helper only.
      * Deliberately does not assert recipient backing/custody because queue ownership may be
      * intentionally decoupled from current LCC holder state. Serviceability is enforced at
      * processSettlementFor(), while explicit transfer-recipient flows validate earlier.
      */
     function _queueSettlement(address lcc, address recipient, uint256 amount) internal {
         if (amount == 0) return;
         LiquidityHubLinkedLib.queueSettlement(s, lcc, recipient, amount);
         emit SettlementQueued(lcc, recipient, amount);
     }
 
     // ============ INTERNAL FUNCTIONS ============
 
     /// @dev Reverts unless `0 < amount <= availableToUnwrap` where `availableToUnwrap = max(0, fromBalance - existingQueue)`.
     function _assertUnwrapWithinHeadroom(uint256 amount, uint256 fromBalance, uint256 existingQueue) private pure {
         uint256 availableToUnwrap = fromBalance > existingQueue ? fromBalance - existingQueue : 0;
         if (amount == 0 || amount > availableToUnwrap) {
             revert Errors.InvalidAmount(amount, availableToUnwrap);
         }
     }
 
     /**
      * @dev Validates that the sender is the canonical vault for a native-backed market
      * @dev Reverts if sender identity is not canonical for the market derived from returned LCCs
      */
     function _assertValidEthSender() internal view {
         address sender = _msgSender();
         if (sender.code.length == 0) revert Errors.InvalidEthSender();
 
         address l0;
         address l1;
         // Prefer a typed call + try/catch over low-level staticcall probing.
         try IMarketVault(sender).lccs() returns (address _l0, address _l1) {
             l0 = _l0;
             l1 = _l1;
         } catch {
             revert Errors.InvalidEthSender();
         }
 
         bool valid0 = LCCFactoryLib.isValidLcc(s, l0);
         bool valid1 = LCCFactoryLib.isValidLcc(s, l1);
         if (!valid0 || !valid1) {
             revert Errors.InvalidEthSender();
         }
 
         Market memory m0 = s.lccToMarket[l0];
         Market memory m1 = s.lccToMarket[l1];
         if (m0.id == bytes32(0) || m1.id == bytes32(0) || m0.id != m1.id || m0.factory != m1.factory) {
             revert Errors.InvalidEthSender();
         }
         if (!isFactory[m0.factory]) {
             revert Errors.InvalidEthSender();
         }
         if (!IMarketFactory(m0.factory).isCanonicalVault(m0.id, sender)) {
             revert Errors.InvalidEthSender();
         }
 
         // Require a native-backed market.
         if (s.lccToUnderlying[l0] != address(0) && s.lccToUnderlying[l1] != address(0)) {
             revert Errors.InvalidEthSender();
         }
     }
 
     /**
      * @notice Receives native ETH transfers from MarketVault contracts
      * @dev Only accepts transfers from valid MarketVault contracts with at least one native ETH LCC.
      *      This enables the route: PoolManager -> MarketVault -> LiquidityHub for native asset settlements.
      *      Reverts if the sender is not a valid MarketVault or if neither LCC uses native ETH as underlying.
      */
     receive() external payable {
         // plain ETH transfer must come from a market vault.
         _assertValidEthSender();
     }
 }
```

#### Related findings

##### [Low] Unwrap headroom netting against settleQueue in LiquidityHub causes denial-of-unwrap for users when issuers queue to them

###### Description

A PR-introduced [unwrap admission rule nets a user’s balance against their settleQueue](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L590-L596), and combined with [endpoint-only unwrapTo](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L136-L145), allows issuer-created queues to block user unwraps.

This PR added a new admission check in LiquidityHub._unwrap that requires [0 < amount <= (fromBalance - settleQueue[lcc][queueTo])](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L1137-L1144) and made [unwrapTo endpoint-only](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L136-L145). Meanwhile, cancelWithQueue still permits issuers to [queue settlement to any non-exempt address without requiring the recipient to hold market-derived LCC](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol#L1109-L1121). As a result, a privileged issuer can (intentionally or by mistake) create a queue entry for a regular user, which reduces the user’s availableToUnwrap to zero and causes unwrap to revert, even though the user holds LCC. Settlement-time invariants remain safe ([processSettlementLogic requires recipient holder balance and reserves](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/LiquidityHubLib.sol#L527-L531)), but the PR introduces a regression that can deny user unwraps until the queue is reduced or cleared. Under the trust assumptions, issuers are protocol-controlled and expected to act correctly, so exploitation likelihood is low. Impact is a significant availability loss for affected users, not a funds-loss or invariant break.

###### Severity

**Impact Explanation:** [Medium] The PR change can significantly impair or deny user unwrapping (withdrawal-like functionality) by netting third-party queued debt against the user’s live balance. This is a significant availability loss but does not cause funds loss or invariant violations.

**Likelihood Explanation:** [Low] All scenarios require misuse or mistakes by a privileged issuer (trusted protocol role) to queue to arbitrary users, which is unlikely under the stated trust assumptions and normal protocol flows.

###### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Issuer queues to a user via cancelWithQueue for an amount >= the user’s LCC balance; the user’s unwrap(lcc, amount) reverts because availableToUnwrap = balance − queued = 0, and the user cannot use unwrapTo to avoid netting.
#### Preconditions / Assumptions
- (a). An LCC token exists and has at least one registered issuer (privileged protocol role).
- (b). The victim user holds a positive LCC balance.
- (c). The issuer calls cancelWithQueue with recipient set to the user, increasing settleQueue[lcc][user].
- (d). The user attempts unwrap(lcc, amount) as a non-endpoint (cannot use unwrapTo to change queueTo).

### Scenario 2.
A misconfigured issuer/integrator repeatedly calls cancelWithQueue to many user addresses; when these users later try to unwrap, headroom is reduced by the queued amounts, causing widespread unwrap reverts until queues are corrected.
#### Preconditions / Assumptions
- (a). An issuer/integrator (privileged protocol role) is misconfigured or buggy.
- (b). It calls cancelWithQueue for many non-exempt external users, adding large queues.
- (c). Affected users later attempt unwrap(lcc, amount) as non-endpoints.

### Scenario 3.
An issuer posts small periodic queues to a target user; each unwrap attempt must be small or reverts due to reduced headroom, effectively throttling the user’s ability to unwrap.
#### Preconditions / Assumptions
- (a). An issuer (privileged role) is willing to repeatedly post small queues to a target user.
- (b). The user regularly attempts unwrap(lcc, amount) as a non-endpoint.

###### Proposed fix

####### LiquidityHub.sol

File: `contracts/evm/src/LiquidityHub.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/LiquidityHub.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
 import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {LCCFactoryLib, LCCFactoryLinkedLib} from "./libraries/LCCFactoryLib.sol";
 import {LiquidityHubLib} from "./libraries/LiquidityHubLib.sol";
 import {LiquidityHubLinkedLib} from "./libraries/LiquidityHubLinkedLib.sol";
 import {LiquidityHubStorage, Market, UnderlyingReserve} from "./types/Liquidity.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {IMarketVault} from "./interfaces/IMarketVault.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {BoundRegistry} from "./modules/BoundRegistry.sol";
 import {Bounds} from "./libraries/Bounds.sol";
 
 /**
  * @title LiquidityHub
  * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
  * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
  */
 contract LiquidityHub is BoundRegistry, Ownable, ReentrancyGuardTransient {
     using CurrencyTransfer for Currency;
 
     // ============ UNIFIED STATE ============
     LiquidityHubStorage internal s;
 
     IOracleHelper public immutable oracleHelper;
 
     event FactorySet(address indexed factory, bool enabled);
     event LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId);
     event LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId);
     event SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementAnnulled(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementProcessed(
         address indexed lcc, address indexed recipient, uint256 settledAmount, uint256 requestedAmount
     );
     event LccWrappedWith(address indexed lcc, address indexed withLCC, address from, address to, uint256 amount);
     event LccWrapped(address indexed lcc, address from, address to, uint256 amount);
     event LccUnwrapped(address indexed lcc, address from, address to, uint256 amount);
 
     // IMPORTANT NOTE: The LiquidityHub is agnostic/unaware of the end account.
     // Similarly to how PoolManager leverages periphery contracts to manage end-account balances, the LiquidityHub aggregates balances, and uses LCCs to track account balances in a hub-and-spoke model.
 
     // Map of market factories
     mapping(address => bool) public isFactory;
 
     /**
      * @notice Constructs the LiquidityHub contract
      * @param _oracleHelper The oracle helper contract address
      * @param _nativeAssetName The name of the native asset (e.g., "Ether")
      * @param _nativeAssetSymbol The symbol of the native asset (e.g., "ETH")
      * @param _nativeAssetDecimals The decimals of the native asset (typically 18)
      * @param _initialOwner The initial owner of the contract
      */
     constructor(
         address _oracleHelper,
         string memory _nativeAssetName,
         string memory _nativeAssetSymbol,
         uint8 _nativeAssetDecimals,
         address _initialOwner
     ) Ownable(_initialOwner) {
         oracleHelper = IOracleHelper(_oracleHelper);
         LCCFactoryLib.initNativeAsset(s, _nativeAssetName, _nativeAssetSymbol, _nativeAssetDecimals);
     }
 
     /**
      * @notice Modifier to restrict access to registered factory contracts only
      */
     modifier onlyFactory() {
         _onlyFactory();
         _;
     }
 
     function _onlyFactory() internal view {
         if (!isFactory[_msgSender()]) {
             revert Errors.InvalidSender();
         }
     }
 
     /// Override from BoundRegistry
     function _lccMarket(address lcc) internal view override returns (bytes32 id, address factory) {
         Market memory market = s.lccToMarket[lcc];
         return (market.id, market.factory);
     }
 
     /// Override from BoundRegistry
     function setBoundLevel(address who, uint8 level) external override onlyFactory {
         // `BoundRegistry._setBoundLevel` enforces EXEMPT/DEX immutability and first-assignment-from-NONE.
         // The stronger policy that EXEMPT/DEX only arise from hardcoded setup / integration paths must be expressed by
         // the specific `MarketFactory` implementation using this hub; registered factories are trusted for that setup policy.
         // Queue-owner safety when moving an address into exempt remains an operational concern (not indexed on-chain).
         _setBoundLevel(msg.sender, who, level);
     }
 
     /// Override from BoundRegistry
     function setBoundLevels(address[] calldata who, uint8 level) external override onlyFactory {
         for (uint256 i = 0; i < who.length; i++) {
             _setBoundLevel(msg.sender, who[i], level);
         }
     }
 
     /**
      * @notice Modifier to ensure the provided LCC address is valid
      * @param lcc The LCC token address to validate
      */
     modifier onlyValidLcc(address lcc) {
         LiquidityHubLib.assertValidLcc(s, lcc);
         _;
     }
 
     /**
      * @notice Modifier to restrict access to issuers of a specific LCC token
      * @param lcc The LCC token address to check issuer status for
      */
     modifier onlyIssuer(address lcc) {
         _onlyIssuer(lcc);
         _;
     }
 
     function _onlyIssuer(address lcc) internal view {
         // Strict invariant: issuer-gated paths must never operate on invalid/uninitialised LCCs.
         LiquidityHubLib.assertValidLcc(s, lcc);
         if (!LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender)) {
             revert Errors.NotApproved(msg.sender);
         }
     }
 
     /**
      * @dev All `unwrapTo` overloads are endpoint-mediated on-behalf-of flows (e.g. `MMPositionManager`).
      *      Direct users unwrap via `unwrap(...)` which queues shortfalls to the caller.
      *      Caller must be `BOUND_ENDPOINT` in the LCC's market factory namespace (not EXEMPT/DEX).
      */
     function _onlyUnwrapToEndpoint(address lcc) internal view {
         if (boundLevelOfLcc(lcc, _msgSender()) != Bounds.BOUND_ENDPOINT) {
             revert Errors.InvalidSender();
         }
     }
 
     // ============ PUBLIC ACCESSORS ============
 
     /**
      * @notice Returns the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address, or address(0) if not found
      */
     function marketUnderlyingToLCC(bytes32 marketId, address underlying) external view returns (address) {
         return s.marketUnderlyingToLCC[marketId][underlying];
     }
 
     /**
      * @notice Returns the underlying asset address for a given LCC token
      * @param lcc The LCC token address
      * @return The underlying asset address (address(0) for native ETH)
      */
     function lccToUnderlying(address lcc) public view returns (address) {
         return s.lccToUnderlying[lcc];
     }
 
     /**
      * @notice Returns the Market struct for a given LCC token
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function lccToMarket(address lcc) external view returns (bytes32, address) {
         return _lccMarket(lcc);
     }
 
     /**
      * @notice
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function getFactory(address lcc0, address lcc1) external view returns (IMarketFactory) {
         address factory0 = s.lccToMarket[lcc0].factory;
         address factory1 = s.lccToMarket[lcc1].factory;
         if (factory0 != factory1) {
             revert Errors.InvariantViolated("LCCs are not from the same market");
         }
         return IMarketFactory(factory0);
     }
 
     /**
      * @notice Checks if an address is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @param issuer The address to check
      * @return True if the address is an issuer, false otherwise
      */
     function issuers(address lcc, address issuer) external view returns (bool) {
         return s.issuers[lcc][issuer];
     }
 
     /**
      * @notice Gets the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address
      */
     function getLCC(bytes32 marketId, address underlying) external view returns (address) {
         return LCCFactoryLib.getLCC(s, marketId, underlying);
     }
 
     /**
      * @notice Gets the underlying asset address for a given LCC token
      * @param lccToken The LCC token address
      * @return The underlying asset address
      */
     function getUnderlying(address lccToken) external view returns (address) {
         return LCCFactoryLib.getUnderlying(s, lccToken);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function isLCC(address lcc) external view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Returns the direct supply (wrapped underlying) for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of direct supply
      */
     function directSupply(address lcc) external view returns (uint256) {
         return s.directSupply[lcc];
     }
 
     /**
      * @notice Returns the shared reserve of underlying assets for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of underlying assets held in reserve for this LCC
      */
     function reserveOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return reserve.direct + reserve.marketDerived;
     }
 
     /**
      * @notice Returns the split underlying reserve tuple for a given LCC token
      * @param lcc The LCC token address
      * @return direct The reserve component backing direct/wrapped supply
      * @return marketDerived The reserve component mobilised from market-derived flows
      */
     function reserveOfUnderlyingTuple(address lcc)
         external
         view
         onlyValidLcc(lcc)
         returns (uint256 direct, uint256 marketDerived)
     {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return (reserve.direct, reserve.marketDerived);
     }
 
     /**
      * @notice Returns the queued settlement amount for a specific LCC and recipient
      * @param lcc The LCC token address
      * @param recipient The recipient address
      * @return The amount queued for settlement
      */
     function settleQueue(address lcc, address recipient) external view returns (uint256) {
         return s.settleQueue[lcc][recipient];
     }
 
     /**
      * @notice Returns the total queued settlement amount for a given LCC token
      * @param lcc The LCC token address
      * @return The total amount queued across all recipients
      */
     function totalQueued(address lcc) external view returns (uint256) {
         return s.totalQueued[lcc];
     }
 
     /**
      * @notice Returns the total queued settlement debt for the underlying of a given LCC
      * @param lcc The LCC token address
      * @return The total queued debt aggregated across all LCCs sharing the same underlying
      */
     function queueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         return s.queueOfUnderlying[s.lccToUnderlying[lcc]];
     }
 
     /**
      * @notice Returns the unfunded queued debt for the underlying of a given LCC
      * @dev Unfunded debt is `max(queueOfUnderlying - marketDerivedReserve, 0)` at the shared-underlying level.
      * @param lcc The LCC token address
      * @return The remaining underlying shortfall that still needs market-to-Hub mobilisation
      */
     function unfundedQueueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         address underlying = s.lccToUnderlying[lcc];
         uint256 queued = s.queueOfUnderlying[underlying];
         uint256 reserve = s.reserveOfUnderlying[underlying].marketDerived;
         return queued > reserve ? queued - reserve : 0;
     }
 
     // ============ ADMIN FUNCTIONS ============
 
     /**
      * @notice Sets or removes a factory address from the allowed factories list
      * @param factory The factory address to enable or disable
      * @param enabled Whether the factory should be enabled (true) or disabled (false)
      */
     function setFactory(address factory, bool enabled) external onlyOwner {
         isFactory[factory] = enabled;
         emit FactorySet(factory, enabled);
     }
 
     /**
      * @notice Creates LCC token pair for a market
      * @param marketRef The market reference (bytes from proxyHookAddress)
      * @param underlyingAsset0 The first underlying asset address
      * @param underlyingAsset1 The second underlying asset address
      * @param marketName The market name
      * @param initialIssuers Array of addresses to set as issuers for both LCC tokens
      * @return lccToken0 The first LCC token address
      * @return lccToken1 The second LCC token address
      */
     function createLCCPair(
         bytes memory marketRef,
         address underlyingAsset0,
         address underlyingAsset1,
         string memory marketName,
         address[] memory initialIssuers
     ) external onlyFactory returns (address lccToken0, address lccToken1) {
         address resilientOracleAddress = oracleHelper.oracle();
         address factory = _msgSender();
         address[2] memory underlyingPair = [underlyingAsset0, underlyingAsset1];
         lccToken0 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 0, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
         lccToken1 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 1, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
 
         // Emit events for LCC creation
         emit LCCCreated(underlyingAsset0, lccToken0, s.lccToMarket[lccToken0].id);
         emit LCCCreated(underlyingAsset1, lccToken1, s.lccToMarket[lccToken1].id);
     }
 
     /**
      * @notice Initializes the mapping from LCC tokens to Market (with ID and Ref)
      * @dev Order-insensitive: `lccToken0` and `lccToken1` are treated independently; no `(0,1)` lane semantics exist here.
      *      Canonical market ordering (for pair lanes) is defined by the core pool key in `MarketFactory`, not by argument order.
      * @param lccToken0 The first LCC token address
      * @param lccToken1 The second LCC token address
      * @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
      * @param marketRef The market reference (bytes from proxyHookAddress)
      */
     function initialize(address lccToken0, address lccToken1, bytes32 marketId, bytes memory marketRef)
         external
         onlyFactory
     {
         LCCFactoryLib.initialize(s, lccToken0, lccToken1, marketId, marketRef, _msgSender());
     }
 
     // ============ INTERNAL HELPERS (delegate to library) ============
 
     /**
      * @notice Checks if the current caller is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @return True if the caller is an issuer, false otherwise
      */
     function _isCallerIssuer(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function _isValidLcc(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Mints LCC tokens to an address
      * @param lccToken The LCC token address
      * @param to The address to mint tokens to
      * @param directAmount The amount to mint as direct supply
      * @param marketAmount The amount to mint as market-derived supply
      */
     function _mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.mint(lccToken, to, directAmount, marketAmount);
     }
 
     /**
      * @notice Burns LCC tokens from an address
      * @param lccToken The LCC token address
      * @param from The address to burn tokens from
      * @param directAmount The amount to burn from direct supply
      * @param marketAmount The amount to burn from market-derived supply
      */
     function _burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.burn(lccToken, from, directAmount, marketAmount);
     }
 
     /**
      * @notice Gets the total balance (wrapped + market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return The total balance
      */
     function _balanceOf(address lccToken, address account) internal view returns (uint256) {
         return LCCFactoryLib.balanceOf(lccToken, account);
     }
 
     /**
      * @notice Gets the bucketed balances (wrapped and market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return wrapped The wrapped (direct) balance
      * @return marketDerived The market-derived balance
      */
     function _balancesOf(address lccToken, address account)
         internal
         view
         returns (uint256 wrapped, uint256 marketDerived)
     {
         return LCCFactoryLib.balancesOf(lccToken, account);
     }
 
     function _assertWrapRecipientNotDexSink(address lcc, address to) internal view {
         if (Bounds.isDex(boundLevel(s.lccToMarket[lcc].factory, to))) {
             revert Errors.DirectWrapToDexNotAllowed(to);
         }
     }
 
     // ============ TRADER FUNCTIONS ============
 
     // DirectLPs and Traders engaging the CorePool directly will need LCC. LCC is 1:1 with the underlying asset.
     /**
      * @dev Internal function to wrap underlying assets into LCC tokens
      * @param lcc The LCC token address to wrap into
      * @param to The address receiving the LCC tokens
      * @param amount The amount of underlying assets to wrap
      */
     function _wrap(address lcc, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         address underlying = s.lccToUnderlying[lcc];
         bool isNativeAsset = underlying == address(0);
 
         // Mint-time ingress to the DEX sink bypasses LCC transfer hooks.
         // Reject it until there is a safe settlement path that can run under PoolManager lock constraints.
         _assertWrapRecipientNotDexSink(lcc, to);
 
         // throw error if the native ETH is insufficient and it is a native ETH backed LCC
         if (isNativeAsset) {
             if (msg.value != amount) {
                 revert Errors.InvalidAmount(0, 0);
             }
         } else {
             if (msg.value != 0) {
                 revert Errors.InvalidAmount(0, 0);
             }
             // Use CurrencyTransfer which has Permit2 fallback for ERC20 transfers
             Currency.wrap(underlying).transferFrom(from, address(this), amount);
         }
 
         s.directSupply[lcc] += amount;
         s.reserveOfUnderlying[underlying].direct += amount;
 
         // mint some tokens
         _mint(lcc, to, amount, 0);
 
         emit LccWrapped(lcc, from, to, amount);
     }
 
     function wrapTo(address lcc, address to, uint256 amount) external payable nonReentrant {
         _wrap(lcc, to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens and sends them to a specified recipient
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address
      * @param amount The amount of underlying assets to wrap
      */
     function wrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller
      * @param lcc The LCC token address
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address lcc, uint256 amount) external payable nonReentrant {
         _wrap(lcc, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address underlying, bytes32 marketId, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), amount);
     }
 
     /**
      * @notice Internal function to wrap LCC using another LCC as backing, with O(1) flattening and netting
      * @dev Delegates to LiquidityHubLib.wrapWithLogic - heavy logic moved to library
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The address receiving the target LCC
      * @param amount The amount to wrap
      */
     function _wrapWith(address lcc, address withLCC, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
 
         // wrapWithTo shares the same mint surface as direct wrap and must not bypass DEX ingress handling.
         _assertWrapRecipientNotDexSink(lcc, to);
 
         // Performs all necessary validation and preparation
         LiquidityHubLib.WrapWithContext memory ctx =
             LiquidityHubLinkedLib.wrapWithPrepare(s, lcc, withLCC, from, amount);
         // Pull backing LCC from caller into the Hub first.
         Currency.wrap(withLCC).transferFrom(from, address(this), ctx.originalAmount);
         // Executes the full wrap-with operation using the provided context
         ctx = LiquidityHubLinkedLib.wrapWithContext(s, lcc, withLCC, ctx);
         // Extract return values.
         // Note: wrapWithContext is designed to conserve amounts. Any mismatch is a logic bug in the library.
         uint256 directToMint = ctx.directToMint;
         uint256 marketToMint = ctx.marketToMint;
 
         // Final mint: mint target LCC with appropriate direct/market-derived split
         LCCFactoryLib.mint(lcc, to, directToMint, marketToMint);
 
         if (ctx.queuedShortfall > 0) {
             // Ensure the queued settlement event is emitted
             emit SettlementQueued(withLCC, address(this), ctx.queuedShortfall);
         }
 
         emit LccWrappedWith(lcc, withLCC, from, to, amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing for the caller
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param amount The amount to wrap
      */
     function wrapWith(address lcc, address withLCC, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing and sends to a specified recipient
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The recipient address
      * @param amount The amount to wrap
      */
     function wrapWithTo(address lcc, address withLCC, address to, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, to, amount);
     }
 
     /**
      * @dev Unwraps LCC from the account's wallet and transfers underlying assets to recipient
      * @dev Accounts should only be able to unwrap if they have LCC in their wallet
      * @dev Unwrap headroom (`availableToUnwrap`) nets any existing settlement queue for `queueTo` against the
      *      caller-held balance (`from`), so the same LCC cannot back repeated queued shortfalls.
      *      - Self-unwrap paths (`unwrap`, `unwrapTo` with `to == queueTo`): `queueTo == from`, so the queue is netted
      *        against the same user's live balance.
      *      - Endpoint `unwrapTo(lcc, to, queueTo, ...)`: supported only when the endpoint acts on behalf of the
      *        beneficiary named by `queueTo`; caller-held balance is treated as representing that beneficiary for this
      *        unwrap (see HUB-02A in INVARIANTS.md).
      * @param lcc The LCC token address to unwrap
      * @param to The recipient of the underlying asset
      * @param queueTo The address to queue shortfall to
      * @param amount The amount to unwrap
      */
     function _unwrap(address lcc, address to, address queueTo, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         (uint256 wrappedBalance, uint256 marketDerivedBalance) = _balancesOf(lcc, from);
         uint256 fromBalance = wrappedBalance + marketDerivedBalance;
 
         // Generic queue paths validate queue-owner shape only.
         // Current settleability remains a redemption-time concern for processSettlementFor().
         _assertValidQueueOwner(lcc, queueTo, true);
 
+        // FIX-ME: Unwrap admission should net only self-originated (unwrap-created) shortfalls.
+        // Introduce `headroomQueue[lcc][queueTo]` to track unwrap-created queue, and replace the next line
+        // to use that mapping instead of `s.settleQueue`. Increment it on unwrap shortfall; decrement on settlement/annul.
+        // Until implemented, issuer-created queues can reduce user headroom (DoS risk).
         _assertUnwrapWithinHeadroom(amount, fromBalance, s.settleQueue[lcc][queueTo]);
 
         (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) =
             LiquidityHubLinkedLib.unwrapInternalLogic(s, lcc, queueTo, amount, wrappedBalance, marketDerivedBalance);
 
         // `unwrapInternalLogic` updates queue state directly in library storage.
         // Queue owner shape is validated at write time; present settleability is enforced on settlement.
 
         // Burn the amount that was unwrapped
         // and transfer the underlying assets to the account
         if (directUnwrapped + marketUnwrapped > 0) {
             _pay(lcc, from, to, directUnwrapped, marketUnwrapped);
         }
         if (queuedShortfall > 0) {
             emit SettlementQueued(lcc, queueTo, queuedShortfall);
         }
 
         emit LccUnwrapped(lcc, from, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller
      * @param lcc The LCC token address to unwrap
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address lcc, uint256 amount) external nonReentrant {
         _unwrap(lcc, _msgSender(), _msgSender(), amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address underlying, bytes32 marketId, uint256 amount) external nonReentrant {
         _unwrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), _msgSender(), amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient
      * @dev Endpoint-only: caller must be `BOUND_ENDPOINT` for this LCC's market. Direct users use `unwrap(...)`.
      *      Shortfalls queue to `to`; admission is capped by `availableToUnwrap` (see `_unwrap` NatSpec, HUB-02).
      * @param lcc The LCC token address to unwrap
      * @param to The recipient address
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address lcc, address to, uint256 amount) external nonReentrant {
         _onlyUnwrapToEndpoint(lcc);
         // Backwards-compatible: queue shortfalls to the same address receiving the underlying.
         _unwrap(lcc, to, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient, while queueing any
      *         unfulfilled portion to a separate queue owner.
      * @dev Endpoint-only on-behalf-of flow (e.g. MMPM): "who receives underlying now" may differ from queue owner.
      *      Admission is capped by netting `settleQueue[lcc][queueTo]` against the caller-held balance (HUB-02 / HUB-02A).
      * @param lcc The LCC token address to unwrap
      * @param to The recipient address for underlying
      * @param queueTo The address to attribute any queued settlement to
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address lcc, address to, address queueTo, uint256 amount) external nonReentrant {
         _onlyUnwrapToEndpoint(lcc);
         _unwrap(lcc, to, queueTo, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient (overloaded)
      * @dev Endpoint-only: caller must be `BOUND_ENDPOINT` for the resolved LCC. Direct users use `unwrap(...)`.
      *      Admission uses `availableToUnwrap` with queue keyed to `to` (HUB-02).
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external nonReentrant {
         address lccAddr = s.marketUnderlyingToLCC[marketId][underlying];
         _onlyUnwrapToEndpoint(lccAddr);
         _unwrap(lccAddr, to, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens (resolved by underlying+marketId) to underlying assets, while queueing any unfulfilled
      *         portion to a separate queue owner.
      * @dev Endpoint-only on-behalf-of flow. Admission uses `availableToUnwrap` with queue keyed to `queueTo` (HUB-02A).
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address for underlying
      * @param queueTo The address to attribute any queued settlement to
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address underlying, bytes32 marketId, address to, address queueTo, uint256 amount)
         external
         nonReentrant
     {
         address lccAddr = s.marketUnderlyingToLCC[marketId][underlying];
         _onlyUnwrapToEndpoint(lccAddr);
         _unwrap(lccAddr, to, queueTo, amount);
     }
 
     // ============ LIQUIDITY FUNCTIONS ============
 
     /**
      * @notice Returns the available liquidity in the market for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of liquidity available in the market (0 if market doesn't exist)
      */
     function marketLiquidity(address lcc) public view returns (uint256) {
         Market memory market = s.lccToMarket[lcc];
         return
             market.id != bytes32(0)
                 ? IMarketFactory(market.factory).marketLiquidity(s.lccToUnderlying[lcc], market.id)
                 : 0;
     }
 
     // ============ ISSUER FUNCTIONS ============
 
     /**
      * @notice Issues LCC tokens (mints to issuer)
      * @param lcc The LCC token address to issue for
      * @param amount The amount to issue
      */
     function issue(address lcc, address to, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC mint path reverts on zero (direct+market) amount.
         // Minting market-derived LCC directly to the DEX sink bypasses transfer hooks and ingress settlement.
         _assertWrapRecipientNotDexSink(lcc, to);
         _mint(lcc, to, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens (burns from specified address)
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param amount The amount to cancel
      */
     function cancel(address lcc, address from, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC burn path reverts on zero (direct+market) amount.
         // `from` is intentionally issuer-selected because issuers are fixed protocol actors (for example ProxyHook and
         // VTSOrchestrator) that cancel along validated protocol flows, not arbitrary public confiscation surfaces.
         // Typical callers burn protocol-controlled holders such as queued settlement holders, MarketVault balances,
         // or staged transfer recipients after the surrounding flow has already proven the accounting path.
         _burn(lcc, from, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens and queues a settlement for the shortfall
      * @dev Simulates unwrap-with-queue without touching direct supply or market liquidity.
      *      Queue recipient shape is validated (non-zero, non-exempt unless Hub), while present settleability
      *      is intentionally enforced at processSettlementFor() when redemption is attempted.
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) public onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
         // Same trusted-issuer rationale as `cancel`: the issuer chooses `from` because this path is used to unwind
         // protocol-side LCC holdings while optionally preserving the recipient's queued settlement claim.
         _cancelWithQueue(lcc, from, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Queues settlement for a recipient after issuer-side deficit transfer.
      * @dev Security checks:
      *      - recipient must be non-zero
      *      - recipient must not be bucket-exempt (external settlement path requires market-derived balance accounting)
      *      - recipient must hold sufficient market-derived LCC to back the queued amount
      *      This path is stricter than generic queue accounting because it is only used when the issuer
      *      has already transferred deficit LCC to `recipient`, so queue owner and burn source must match now.
      */
     function queueForTransferRecipient(address lcc, address recipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         // Deficit queues must target a serviceable external recipient (Hub queueing is not allowed on this path).
         _assertQueueRecipientServiceable(lcc, recipient, amount, false);
         _queueSettlement(lcc, recipient, amount);
     }
 
     /**
      * @dev Internal implementation of cancelWithQueue without access control
      * @param lcc The LCC token address
      * @param from The address to cancel tokens from
      * @param principalAmount The total principal amount being cancelled (cancellable amount is burned from `from`)
      * @param queueAmount The amount to queue for settlement (portion of principalAmount queued for `recipient`)
      * @param recipient The recipient of the queued settlement
      */
     function _cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) internal {
         if (queueAmount > 0) {
             _assertValidQueueOwner(lcc, recipient, true);
         }
 
         uint256 cancelAmount = principalAmount - queueAmount;
 
         // Burn the cancellable portion of the principal amount from the sender.
         // Burn against the sender's actual bucket split (market-derived first, then wrapped).
         // Note: allow cancelAmount == 0 (principal fully queued) without reverting.
         if (cancelAmount > 0) {
             _safeBurn(lcc, from, cancelAmount);
         }
 
         // Queue accounting is intentionally decoupled from current holder backing.
         // Runtime settleability is enforced when processSettlementFor executes.
         _queueSettlement(lcc, recipient, queueAmount);
     }
 
     /**
      * @dev Burns against a holder's bucket split (market-derived first, then wrapped).
      * - Bucket-exempt recipients can burn without bucket accounting.
      * - If `balancesOf` is unavailable (e.g. reentrancy tests that stub LCC), fall back to a full burn.
      */
     function _safeBurn(address lcc, address from, uint256 amount) internal {
         if (amount == 0) return;
 
         if (Bounds.isExempt(boundLevelOfLcc(lcc, from))) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         // IMPORTANT: Some reentrancy-hardening tests replace the LCC code (vm.etch) with a minimal stub that
         // does not implement balancesOf; in that case we must still proceed to the burn to exercise the guard.
         uint256 wrappedBal;
         uint256 marketBal;
         bool hasBuckets = true;
         try ILCC(lcc).balancesOf(from) returns (uint256 wrapped, uint256 market) {
             wrappedBal = wrapped;
             marketBal = market;
         } catch (bytes memory reason) {
             // Keep fallback only for stubbed / non-implemented `balancesOf` paths (empty revert data).
             // Integrity and bucket errors (e.g. `Errors.InvalidBucketState`) must surface.
             if (reason.length == 0) {
                 hasBuckets = false;
             } else {
                 assembly ("memory-safe") {
                     revert(add(reason, 0x20), mload(reason))
                 }
             }
         }
 
         if (!hasBuckets) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         uint256 burnMarket = Math.min(marketBal, amount);
         uint256 remaining = amount - burnMarket;
         uint256 burnDirect = Math.min(wrappedBal, remaining);
         _burn(lcc, from, burnDirect, burnMarket);
     }
 
     /**
      * @notice Plans a cancel operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      This path-keyed store is safe only because current callers stage the plan and then
      *      immediately drive the matching transfer in the same logical path/transaction.
      *      It must not be treated as a general deferred queue across unrelated intermediate logic.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param amount The amount to cancel
      */
     function planCancel(address lcc, address sender, address cancelFromRecipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
 
         // Store the planned cancel in transient storage
         TransientSlots.setPlanCancel(lcc, sender, cancelFromRecipient, amount);
     }
 
     /**
      * @notice Plans a cancel with queue operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      Current MM decrease flows rely on the matching transfer happening immediately after
      *      `modifyLiquidity(...)` returns; if a future flow can stage the same key twice before
      *      consumption, this helper is no longer sufficient.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function planCancelWithQueue(
         address lcc,
         address sender,
         address cancelFromRecipient,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) external onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
 
         // Store the planned cancel with queue in transient storage
         TransientSlots.setPlanCancelWithQueue(lcc, sender, cancelFromRecipient, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Called by MarketVault after taking underlying liquidity from the market to LCC
      * @param lcc The LCC token address
      * @param amount The amount of underlying liquidity taken
      * @param shouldEmit Whether to emit LiquidityAvailable event
      */
     function confirmTake(address lcc, uint256 amount, bool shouldEmit) external onlyIssuer(lcc) {
         // INTENT:
         // `confirmTake()` must be callable from within higher-level flows that themselves may be `nonReentrant`
         // (e.g. `useMarketLiquidity()` eventually triggering a vault -> hub callback).
         // We therefore DO NOT apply `nonReentrant` here; instead, we enforce a strict balance-backed invariant
         // so callers cannot "fabricate" reserves via re-entrancy.
 
         LiquidityHubLib.ConfirmTakeContext memory ctx =
             LiquidityHubLinkedLib.confirmTakePrepare(s, lcc, amount, shouldEmit);
 
         // Best-effort: settle Hub queue up to the newly available amount
         if (ctx.hubQueueBeforeSettlement > 0) {
             _processSettlementFor(lcc, address(this), amount);
         }
 
         if (ctx.emitLiquidityAvailable) {
             // Only emit if there is new liquidity available and not consumed greedily by the Hub
             emit LiquidityAvailable(lcc, ctx.underlying, amount, ctx.marketId);
         }
 
         // Balance-backed invariant: reserve accounting must never exceed actual hub holdings.
         // This protects against re-entrancy and any accidental/malicious unbacked `confirmTake` calls.
         LiquidityHubLinkedLib.confirmTakeBalanceInvariant(s, ctx.underlying);
     }
 
     /**
      * @notice Prepare settlement of underlying from Hub to MarketVault
      * @dev For ERC20, approve the caller (expected MarketVault) to pull tokens; for native, transfer ETH to caller.
      *      Decrements direct reserve and per-LCC directSupply immediately; intended to be called just before settlement
      *      in the same tx.
      */
     function prepareSettle(address lcc, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         LiquidityHubLinkedLib.prepareSettle(s, lcc, amount, _msgSender());
     }
 
     /**
      * @notice Process settlement for a specific recipient using reserveOfUnderlying
      * @dev Permissionless function that allows anyone to process settlements when liquidity is available.
      *      Unified interface: branches behaviour based on whether recipient is address(this) (Hub) or external address.
      *      For Hub: burns Hub-held LCC without transferring underlying or decrementing reserves.
      *      For external: checks holder balance, burns user tokens, transfers underlying, and decrements reserves.
      *      External-path reverts are retriable and signal that reserves/custody are not yet reconciled.
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for (address(this) for Hub's own queue)
      * @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
      */
     function processSettlementFor(address lcc, address recipient, uint256 maxAmount)
         external
         onlyValidLcc(lcc)
         nonReentrant
     {
         _processSettlementFor(lcc, recipient, maxAmount);
     }
 
     /**
      * @notice Atomically releases queued MM custody and settles it against the recipient's Hub queue
      * @dev Best-effort path for MM collection flows. Returns 0 when the queue, reserve, or custody
      *      currently cannot support settlement, instead of reverting.
      * @param lcc The LCC token address
      * @param custodian The MM queue custodian holding beneficiary-scoped queued LCC
      * @param tokenId The commitment token id bucket to debit in the custodian
      * @param recipient The queue owner and settlement recipient
      * @param maxAmount The maximum amount to settle
      */
     function settleFromCustodian(address lcc, address custodian, uint256 tokenId, address recipient, uint256 maxAmount)
         external
         onlyValidLcc(lcc)
         nonReentrant
     {
         uint256 settled = LiquidityHubLinkedLib.settleFromCustodian(s, lcc, custodian, tokenId, recipient, maxAmount);
         if (settled > 0) {
             _processSettlementFor(lcc, recipient, settled);
         }
     }
 
     /**
      * @notice Internal function to process settlement for a specific recipient
      * @dev Delegates to LiquidityHubLib.processSettlementLogic
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for
      * @param maxAmount The maximum amount to settle
      */
     function _processSettlementFor(address lcc, address recipient, uint256 maxAmount) internal {
         uint256 queuedBefore = s.settleQueue[lcc][recipient];
         LiquidityHubLinkedLib.processSettlementLogic(s, lcc, recipient, maxAmount);
         uint256 queuedAfter = s.settleQueue[lcc][recipient];
         uint256 settled = queuedBefore > queuedAfter ? queuedBefore - queuedAfter : 0;
+        // FIX-ME: If using a dedicated `headroomQueue`, also decrement it here:
+        // e.g., `uint256 hq = headroomQueue[lcc][recipient]; if (hq > 0) { headroomQueue[lcc][recipient] = hq > settled ? hq - settled : 0; }`
+        // This keeps headroom-only accounting consistent with total queue reductions on settlement.
+
         if (settled > 0) {
             emit SettlementProcessed(lcc, recipient, settled, maxAmount);
         }
     }
 
     // -----------------------------------
     // LCC triggered functions
     // -----------------------------------
 
     /// @notice Called by LCC on transfer to execute any planned cancellations
     /// @dev Assumes at most one live plan per `(lcc, sender, recipient)` path at consumption time.
     ///      The current call graph preserves this by staging the plan immediately before the
     ///      matching transfer; this function does not independently disambiguate multiple same-key plans.
     ///      Planned cancels are intentionally consumed from the transfer path so the burn source is the exact
     ///      protocol-side recipient that just received the LCC, rather than an arbitrary user-selected address.
     function executePlannedCancel(address sender, address cancelFromRecipient) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Check for planned cancel with queue first (more specific)
         (uint256 principalAmount, uint256 queueAmount, address queueRecipient) =
             TransientSlots.consumePlanCancelWithQueue(lcc, sender, cancelFromRecipient);
 
         if (principalAmount > 0) {
             // _cancelWithQueue handles principal == queue (burn 0, queue all) and principal > queue.
             // Use internal function to bypass onlyIssuer check (LCC is the caller, not an issuer).
             _cancelWithQueue(lcc, cancelFromRecipient, principalAmount, queueAmount, queueRecipient);
             return;
         }
 
         // Check for simple planned cancel
         uint256 amount = TransientSlots.consumePlanCancel(lcc, sender, cancelFromRecipient);
         if (amount > 0) {
             _safeBurn(lcc, cancelFromRecipient, amount);
         }
     }
 
     /// @notice Annuls queued settlement before a protocol-bound transfer
     function annulSettlementBeforeTransfer(
         address from,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance,
         uint256 amountToTransfer
     ) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Even if queued == 0 or amountToTransfer == 0, the library path is a no-op.
         // We intentionally avoid an early return here to keep the control flow simpler and more auditable.
         uint256 toAnnul = LiquidityHubLinkedLib.annulSettlementBeforeTransfer(
             s, lcc, from, wrappedBalance, marketDerivedBalance, amountToTransfer
         );
+        // FIX-ME: If using `headroomQueue`, also reduce it here by `min(headroomQueue[lcc][from], toAnnul)`
+        // so that bleed-into-queue on protocol-bound transfers updates both total queue and headroom queue.
+
         if (toAnnul > 0) {
             emit SettlementAnnulled(lcc, from, toAnnul);
         }
     }
 
     // ============ SETTLEMENT FUNCTIONS ============
 
     /**
      * @dev Pays an outstanding settlement to an account by burning LCC tokens and transferring underlying assets
      * @param lcc The LCC token address
      * @param owner The owner of the LCC tokens to burn
      * @param to The recipient of the underlying assets
      * @param fromDirect The amount of LCC to burn from direct supply
      * @param fromMarket The amount of LCC to burn from market-derived supply
      */
     function _pay(address lcc, address owner, address to, uint256 fromDirect, uint256 fromMarket) internal {
         LiquidityHubLinkedLib.pay(s, lcc, owner, to, fromDirect, fromMarket);
     }
 
     /**
      * @dev Adds a settlement request to the queue
      * @param lcc The LCC token address
      * @param recipient The address with pending settlements
      * @param amount The amount to eventually settle
      */
     function _assertQueueRecipientServiceable(address lcc, address recipient, uint256 amount, bool allowHub)
         internal
         view
     {
         _assertValidQueueOwner(lcc, recipient, allowHub);
 
         (, uint256 marketDerivedBalance) = ILCC(lcc).balancesOf(recipient);
         if (marketDerivedBalance < amount) {
             revert Errors.InsufficientBalance(marketDerivedBalance, amount);
         }
     }
 
     /**
      * @dev Minimal queue-owner validity check for generic queue creation.
      * Queue owners must not be zero and must not be bucket-exempt unless the queue is intentionally
      * attributed to the Hub itself. This keeps generic queue writes compatible with later settlement,
      * while still allowing queue ownership to be decoupled from current holder backing.
      */
     function _assertValidQueueOwner(address lcc, address recipient, bool allowHub) internal view {
         if (recipient == address(0)) {
             revert Errors.InvalidAddress(recipient);
         }
 
         if (recipient == address(this)) {
             if (!allowHub) revert Errors.NotApproved(recipient);
             return;
         }
 
         if (Bounds.isExempt(boundLevelOfLcc(lcc, recipient))) {
             revert Errors.NotApproved(recipient);
         }
     }
 
     /**
      * @dev Queue accounting helper only.
      * Deliberately does not assert recipient backing/custody because queue ownership may be
      * intentionally decoupled from current LCC holder state. Serviceability is enforced at
      * processSettlementFor(), while explicit transfer-recipient flows validate earlier.
      */
     function _queueSettlement(address lcc, address recipient, uint256 amount) internal {
         if (amount == 0) return;
         LiquidityHubLinkedLib.queueSettlement(s, lcc, recipient, amount);
         emit SettlementQueued(lcc, recipient, amount);
     }
 
     // ============ INTERNAL FUNCTIONS ============
 
     /// @dev Reverts unless `0 < amount <= availableToUnwrap` where `availableToUnwrap = max(0, fromBalance - existingQueue)`.
     function _assertUnwrapWithinHeadroom(uint256 amount, uint256 fromBalance, uint256 existingQueue) private pure {
         uint256 availableToUnwrap = fromBalance > existingQueue ? fromBalance - existingQueue : 0;
         if (amount == 0 || amount > availableToUnwrap) {
             revert Errors.InvalidAmount(amount, availableToUnwrap);
         }
     }
 
     /**
      * @dev Validates that the sender is the canonical vault for a native-backed market
      * @dev Reverts if sender identity is not canonical for the market derived from returned LCCs
      */
     function _assertValidEthSender() internal view {
         address sender = _msgSender();
         if (sender.code.length == 0) revert Errors.InvalidEthSender();
 
         address l0;
         address l1;
         // Prefer a typed call + try/catch over low-level staticcall probing.
         try IMarketVault(sender).lccs() returns (address _l0, address _l1) {
             l0 = _l0;
             l1 = _l1;
         } catch {
             revert Errors.InvalidEthSender();
         }
 
         bool valid0 = LCCFactoryLib.isValidLcc(s, l0);
         bool valid1 = LCCFactoryLib.isValidLcc(s, l1);
         if (!valid0 || !valid1) {
             revert Errors.InvalidEthSender();
         }
 
         Market memory m0 = s.lccToMarket[l0];
         Market memory m1 = s.lccToMarket[l1];
         if (m0.id == bytes32(0) || m1.id == bytes32(0) || m0.id != m1.id || m0.factory != m1.factory) {
             revert Errors.InvalidEthSender();
         }
         if (!isFactory[m0.factory]) {
             revert Errors.InvalidEthSender();
         }
         if (!IMarketFactory(m0.factory).isCanonicalVault(m0.id, sender)) {
             revert Errors.InvalidEthSender();
         }
 
         // Require a native-backed market.
         if (s.lccToUnderlying[l0] != address(0) && s.lccToUnderlying[l1] != address(0)) {
             revert Errors.InvalidEthSender();
         }
     }
 
     /**
      * @notice Receives native ETH transfers from MarketVault contracts
      * @dev Only accepts transfers from valid MarketVault contracts with at least one native ETH LCC.
      *      This enables the route: PoolManager -> MarketVault -> LiquidityHub for native asset settlements.
      *      Reverts if the sender is not a valid MarketVault or if neither LCC uses native ETH as underlying.
      */
     receive() external payable {
         // plain ETH transfer must come from a market vault.
         _assertValidEthSender();
     }
 }
```

### 5. [Low] Removal of on-chain TTL cap for VRL proofs in VRLSignalManager/VTSCommitLib causes extended stale-proof acceptance window

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

The system now relies solely on the [Merkle-leaf expiryAt](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/MarketMaker.sol#L56-L58) for VRL proof freshness, removing the prior on-chain TTL cap. If the VRL signer issues leaves with generous expiryAt, stale reserve snapshots remain accepted longer, allowing liquidity increases and deficit reductions to proceed on outdated backing.

VRLSignalManager now [enforces freshness only via the leaf’s mmState.expiryAt](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VRLSignalManager.sol#L136-L137) and [returns expirySeconds = expiryAt - now](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VRLSignalManager.sol#L152-L153). VTSCommitLib [sets commit.expiresAt = now + expirySeconds](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSCommitLib.sol#L298), so commit lifetime matches the leaf expiry exactly, with no on-chain cap. While unexpired, operations such as validateLiquidityDelta [use the stored mmState reserves to determine backing (via oracle pricing)](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSCommitLib.sol#L158). [Checkpointing treats expired signals as zero backing](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSCommitLib.sol#L360-L365), but until expiry, stale mmState is accepted. Removing the prior global on-chain TTL (signalExpiryInSeconds) is a defense-in-depth regression: if the integrated VRL signer/aggregator issues leaves with long expiryAt (by policy or misconfiguration), stale proofs are accepted much longer, extending the period in which MMs can add liquidity or reduce deficits based on outdated reserve attestations.

#### Severity

**Impact Explanation:** [Low] This is a defense-in-depth regression that extends stale-proof acceptance duration but does not itself directly mint, steal, or freeze funds, nor break core invariants. It increases risk exposure duration without guaranteeing immediate principal loss.

**Likelihood Explanation:** [Low] It depends on the integrated VRL signer/aggregator issuing leaves with generous expiryAt (policy or misconfiguration), which is outside the attacker’s direct on-chain control and thus falls under integration behavior.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
An MM hoards a valid, still-unexpired leaf with a generous expiryAt while their true off-chain reserves decline; before expiry, they commit the leaf and perform add-liquidity operations. Because the commit remains live until expiryAt and [validateLiquidityDelta](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSPositionLib.sol#L1665-L1679) uses the stored mmState, liquidity increases pass for longer than they would under a short on-chain TTL, increasing exposure based on stale backing.
#### Preconditions / Assumptions
- (a). The integrated VRL signer/aggregator issues a leaf with a generous future expiryAt (long acceptance window).
- (b). The MM holds a valid leaf with nonce > on-chain mmNonce[owner].
- (c). The MM’s actual off-chain reserves have declined relative to the snapshot, making the mmState stale but still unexpired.
- (d). The commit is submitted and verified before expiryAt, setting commit.expiresAt to the leaf’s expiryAt.
- (e). The MM performs add-liquidity operations that rely on validateLiquidityDelta using the stored mmState while unexpired.

### Scenario 2.
An MM with a position-level commitment deficit waits until a stale but unexpired commit remains live due to long expiryAt, then runs a checkpoint with commitment. Since the signal is not expired, checkpointing uses the stored mmState to compute signalUsd and reduces or clears deficits longer than would have been permitted under a short on-chain TTL.
#### Preconditions / Assumptions
- (a). The integrated VRL signer/aggregator issues a leaf with a generous future expiryAt.
- (b). A position has a stored commitment deficit.
- (c). The commit remains unexpired due to long expiryAt.
- (d). The MM triggers checkpointing with commitment before expiry, which uses the stored mmState (signalUsd) rather than zeroing it.

#### Proposed fix

##### VRLSignalManager.sol

File: `contracts/evm/src/VRLSignalManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VRLSignalManager.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 // The VRLSpokeReceiver is a module that is responsible for verifying the liquidity signal and returning the tickers and amounts of the assets
 // It is used by the `MMPositionManager` to verify the liquidity signal and return the tickers and amounts of the assets
 // and to ensure that the MM has enough reserves in their signal to cover their liquidity commitment to the Market
 pragma solidity ^0.8.26;
 
 import {MarketMaker} from "./libraries/MarketMaker.sol";
 import {ISignalVerifier} from "./interfaces/ISignalVerifier.sol";
 import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
 import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
 import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
 import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
 import {LiquiditySignal} from "./types/Commit.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {IVRLSignalManager} from "./interfaces/IVRLSignalManager.sol";
 
 contract VRLSignalManager is Ownable, EIP712, IVRLSignalManager {
     using MarketMaker for MarketMaker.State;
     using ECDSA for bytes32;
 
     event MMNonceSeeded(address indexed marketMaker, uint256 previousNonce, uint256 newNonce);
     event SubmitAuthNonceSeeded(address indexed sender, uint256 previousNonce, uint256 newNonce);
 
     ISignalVerifier internal verifier;
 
     /**
      * @dev Tracks the latest nonce per Market Maker (MM) address.
      *
      * IMPORTANT: A single nonce is generated (off Market Chain) once for an array of MMState covering the entire VRL
      * (Verification Root Ledger) for all Market Makers. This means:
      *
      * - The nonce represents a shared state advancement across all MMs in a VRL batch
      * - When submitting a proof, it must represent a state advancement over the last proof
      *   submitted for that specific MM (enforced by requiring signal.nonce > mmNonce[mmState.owner])
      * - Verification of a single MMState does NOT invalidate the nonce for another MMState
      * - Each MMState progresses independently until it reaches the latest nonce
      * - Multiple MMs can be verified at the same nonce level, but each MM's nonce must be
      *   monotonically increasing
      *
      * Example: If VRL nonce is 5, MM A can submit nonce 5 even if MM B has already submitted
      * nonce 5, but MM A cannot submit nonce 4 if they've already submitted nonce 5.
      */
     // Replacement deployments reset storage, so owner can seed continuity before re-registering a new handler.
     // Seeders may only move these replay guards forwards; they can never lower an already-recorded nonce.
     mapping(address => uint256) public mmNonce;
     mapping(address => uint256) public submitAuthNonce;
     address public immutable submitter;
+    uint256 public maxSignalTTLSeconds;
     bytes32 internal constant RELAY_AUTH_TYPEHASH = keccak256(
         "RelayAuth(address sender,uint256 commitId,bytes32 liquiditySignalHash,uint256 deadline,uint256 nonce)"
     );
 
     constructor(address _verifier, address _submitter, address _initialOwner)
         Ownable(_initialOwner)
         EIP712("VRLSignalManager", "1")
     {
         if (_submitter == address(0)) revert Errors.InvalidAddress(_submitter);
 
         verifier = ISignalVerifier(_verifier);
         submitter = _submitter;
     }
 
     modifier onlySubmitter() {
         _onlySubmitter();
         _;
     }
 
     function _onlySubmitter() internal view {
         if (msg.sender != submitter) revert Errors.InvalidSender();
     }
 
     /**
      * @dev This function is used to set the verifier for the VRLSpokeReceiver
      *      the verifier responsible for verifing the signatures and inclusion proofs
      * @param _newVerifier The new verifier to set
      */
     function setVerifier(address _newVerifier) external onlyOwner {
         address oldVerifier = address(verifier);
         verifier = ISignalVerifier(_newVerifier);
         emit VerifierChanged(oldVerifier, _newVerifier);
     }
+    function setMaxSignalTTLSeconds(uint256 v) external onlyOwner { maxSignalTTLSeconds = v; }
 
     /**
      * @dev This function is used to get the verifier for the VRLSpokeReceiver
      * @return The verifier address
      */
     function getVerifier() external view returns (address) {
         return address(verifier);
     }
 
     /// @notice Seed the minimum accepted MM nonce on a replacement deployment before re-registering the handler.
     /// @dev Owner may only move the stored nonce forwards, preserving monotonic replay protection across redeploys.
     function seedMMNonce(address marketMaker, uint256 minimumNonce) external onlyOwner {
         uint256 previousNonce = mmNonce[marketMaker];
         if (minimumNonce < previousNonce) {
             revert Errors.InvalidNonce(minimumNonce, previousNonce);
         }
         if (minimumNonce == previousNonce) return;
         mmNonce[marketMaker] = minimumNonce;
         emit MMNonceSeeded(marketMaker, previousNonce, minimumNonce);
     }
 
     /// @notice Seed the next relayed authorisation nonce on a replacement deployment before re-registering.
     /// @dev Owner may only move the stored nonce forwards, preserving monotonic replay protection across redeploys.
     function seedSubmitAuthNonce(address sender, uint256 minimumNonce) external onlyOwner {
         uint256 previousNonce = submitAuthNonce[sender];
         if (minimumNonce < previousNonce) {
             revert Errors.InvalidNonce(minimumNonce, previousNonce);
         }
         if (minimumNonce == previousNonce) return;
         submitAuthNonce[sender] = minimumNonce;
         emit SubmitAuthNonceSeeded(sender, previousNonce, minimumNonce);
     }
 
     function _assertSenderAuthorised(LiquiditySignal memory signal, address sender) internal pure {
         if (sender != signal.mmState.owner && sender != signal.mmState.advancer) {
             revert Errors.InvalidSender();
         }
     }
 
     /**
      * @dev This function is used to verify the liquidity signal and return the tickers and amounts of the assets
      * @param signal The liquidity signal to verify
      * @return isProofValid Whether the proof is valid
      */
     function _verifyLiquiditySignalInternal(LiquiditySignal memory signal)
         internal
         returns (bool isProofValid, uint256 _signalExpiryInSeconds)
     {
         // derive the liquidity signal
         // validate the new nonce is greater than than the previous nonce
         if (signal.nonce <= mmNonce[signal.mmState.owner]) {
             revert Errors.InvalidNonce(signal.nonce, mmNonce[signal.mmState.owner]);
         }
 
         // Leaf-bound proof freshness: `expiryAt` is part of the signed Merkle leaf (`mmState`).
         if (block.timestamp > signal.mmState.expiryAt) {
             revert Errors.DeadlinePassed(signal.mmState.expiryAt);
         }
 
         // verify the proofs associated with the state
         isProofValid = verifier.verifyProof(
             signal.nonce, signal.rootHash, signal.rootHashSignature, signal.mmState, signal.merkleProof
         );
 
         if (isProofValid) {
             // update the nonce for the mm if the proof is valid
             mmNonce[signal.mmState.owner] = signal.nonce;
             // emit the verified liquidity signal
             emit LiquiditySignalVerified(signal);
         }
 
         // On-chain commit window is the remaining time until the leaf `expiryAt` (signed in the Merkle state).
-        _signalExpiryInSeconds = signal.mmState.expiryAt - block.timestamp;
+        uint256 remaining = signal.mmState.expiryAt - block.timestamp;
+        if (maxSignalTTLSeconds != 0 && remaining > maxSignalTTLSeconds) {
+            remaining = maxSignalTTLSeconds;
+        }
+        _signalExpiryInSeconds = remaining;
     }
 
     function verifyLiquiditySignal(address sender, bytes memory liquiditySignal, bool revertOnInvalid)
         external
         onlySubmitter
         returns (bool ok, uint256 _signalExpiryInSeconds)
     {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         _assertSenderAuthorised(signal, sender);
         (ok, _signalExpiryInSeconds) = _verifyLiquiditySignalInternal(signal);
         if (revertOnInvalid && !ok) revert Errors.InvalidProof();
     }
 
     function verifyLiquiditySignalRelayed(
         address sender,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig,
         bool revertOnInvalid
     ) external onlySubmitter returns (bool ok, uint256 _signalExpiryInSeconds) {
         if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);
         if (authNonce != submitAuthNonce[sender]) {
             revert Errors.InvalidNonce(authNonce, submitAuthNonce[sender]);
         }
 
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         _assertSenderAuthorised(signal, sender);
 
         bytes32 structHash = EfficientHashLib.hash(
             abi.encode(RELAY_AUTH_TYPEHASH, sender, commitId, keccak256(liquiditySignal), deadline, authNonce)
         );
 
         if (_hashTypedDataV4(structHash).recover(authSig) != sender) {
             revert Errors.InvalidSender();
         }
 
         (ok, _signalExpiryInSeconds) = _verifyLiquiditySignalInternal(signal);
         if (revertOnInvalid && !ok) revert Errors.InvalidProof();
         if (ok) {
             submitAuthNonce[sender] = authNonce + 1;
         }
     }
 }
```

#### Related findings

##### [Informational] Leaf-expiry equality acceptance in VRLSignalManager causes dead-on-arrival commits and nonce consumption

###### Description

The PR introduced a leaf-bound absolute expiry (mmState.expiryAt). [VRLSignalManager accepts proofs when block.timestamp == expiryAt](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VRLSignalManager.sol#L136-L138) and returns expirySeconds = 0. VTSCommitLib then writes commit.expiresAt = block.timestamp, while [VTS live-signal checks treat equality as expired](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L136-L141). As a result, a commit/renewal can succeed and advance replay guards (mmNonce and, for relayed flows, submitAuthNonce) but be immediately unusable for live-signal operations. This behavior stems from the PR’s new leaf-expiry design.

With the PR’s change to leaf-bound expiry, [VRLSignalManager._verifyLiquiditySignalInternal rejects only when block.timestamp > mmState.expiryAt](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VRLSignalManager.sol#L136-L138). At equality, verification succeeds and [returns _signalExpiryInSeconds = 0](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VRLSignalManager.sol#L152-L154). VTSCommitLib then [sets commit.expiresAt = block.timestamp + expirySeconds](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSCommitLib.sol#L296-L299), which equals block.timestamp. VTS enforces live-signal validity using equality-based expiry (e.g., [VTSLifecycleLinkedLib.isSignalValid uses block.timestamp >= commit.expiresAt](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L136-L141); [VTSPositionLib._linkPositionToCommit rejects when expiresAt <= block.timestamp](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSPositionLib.sol#L742-L743)). Thus, a commit or renewal can be accepted and [advance mmNonce](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VRLSignalManager.sol#L145-L149) (and [submitAuthNonce for relayed calls](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VRLSignalManager.sol#L194-L196)) but is immediately expired for any live-signal action. This inconsistency was introduced by the PR’s switch to a leaf-bound absolute expiry and the equality-accepting check in VRLSignalManager.

###### Severity

**Impact Explanation:** [Informational] The issue results in UX/liveness friction (gas wasted, commit/renewal stored but immediately non-live, replay guards advanced). It does not cause funds loss, break invariants, or permanently freeze funds.

**Likelihood Explanation:** [Low] Exploitation requires equality at the expiry boundary; for relayed flows it also typically requires a misconfigured deadline equal to expiry. Operators and the trusted submitter can avoid equality-bound timings and set safer deadlines.

###### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Non-relayed commit at the expiry boundary: An MM submits a non-relayed commit near mmState.expiryAt; the tx is included at block.timestamp == expiryAt. VRLSignalManager accepts the proof (strict '>' check), [returns expirySeconds = 0](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VRLSignalManager.sol#L152-L154), and advances mmNonce. [VTSCommitLib sets commit.expiresAt = now](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSCommitLib.sol#L296-L299). The commit is stored and the NFT is minted, but all live-signal checks immediately treat it as expired, preventing linking or other live operations.
#### Preconditions / Assumptions
- (a). A valid LiquiditySignal with mmState.expiryAt = T
- (b). Non-relayed commit submitted close to T
- (c). Inclusion occurs at block.timestamp == T

### Scenario 2.
Relayed commit with deadline equal to expiry: The MM uses the relayed path with deadline == mmState.expiryAt, and the tx lands at block.timestamp == expiryAt. The deadline check (strict '>') passes; VRLSignalManager accepts the proof, returns expirySeconds = 0, advances mmNonce, and [verifyLiquiditySignalRelayed increments submitAuthNonce](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VRLSignalManager.sol#L194-L196). VTSCommitLib writes commit.expiresAt = now. The commit is immediately non-live for VTS, wasting gas and consuming both nonces.
#### Preconditions / Assumptions
- (a). Relayed commit path used
- (b). deadline is set equal to mmState.expiryAt
- (c). Inclusion occurs at block.timestamp == deadline == expiryAt

### Scenario 3.
Just-in-time renewal at the expiry boundary: An MM renews a commit with a new LiquiditySignal whose mmState.expiryAt equals the block timestamp at inclusion. VRLSignalManager accepts the proof at equality and [returns expirySeconds = 0](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VRLSignalManager.sol#L152-L154); VTSCommitLib updates mmState and [sets commit.expiresAt = now](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/libraries/VTSCommitLib.sol#L296-L299). The renewed commit is immediately expired for live-signal actions, and replay guards have advanced.
#### Preconditions / Assumptions
- (a). Existing commit is renewed using a LiquiditySignal with mmState.expiryAt = T2
- (b). Inclusion occurs at block.timestamp == T2

###### Proposed fix

####### VRLSignalManager.sol

File: `contracts/evm/src/VRLSignalManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6d9f1cc515a70827eb5ddb9cc554a7ddeec49110/contracts/evm/src/VRLSignalManager.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 // The VRLSpokeReceiver is a module that is responsible for verifying the liquidity signal and returning the tickers and amounts of the assets
 // It is used by the `MMPositionManager` to verify the liquidity signal and return the tickers and amounts of the assets
 // and to ensure that the MM has enough reserves in their signal to cover their liquidity commitment to the Market
 pragma solidity ^0.8.26;
 
 import {MarketMaker} from "./libraries/MarketMaker.sol";
 import {ISignalVerifier} from "./interfaces/ISignalVerifier.sol";
 import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
 import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
 import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
 import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
 import {LiquiditySignal} from "./types/Commit.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {IVRLSignalManager} from "./interfaces/IVRLSignalManager.sol";
 
 contract VRLSignalManager is Ownable, EIP712, IVRLSignalManager {
     using MarketMaker for MarketMaker.State;
     using ECDSA for bytes32;
 
     event MMNonceSeeded(address indexed marketMaker, uint256 previousNonce, uint256 newNonce);
     event SubmitAuthNonceSeeded(address indexed sender, uint256 previousNonce, uint256 newNonce);
 
     ISignalVerifier internal verifier;
 
     /**
      * @dev Tracks the latest nonce per Market Maker (MM) address.
      *
      * IMPORTANT: A single nonce is generated (off Market Chain) once for an array of MMState covering the entire VRL
      * (Verification Root Ledger) for all Market Makers. This means:
      *
      * - The nonce represents a shared state advancement across all MMs in a VRL batch
      * - When submitting a proof, it must represent a state advancement over the last proof
      *   submitted for that specific MM (enforced by requiring signal.nonce > mmNonce[mmState.owner])
      * - Verification of a single MMState does NOT invalidate the nonce for another MMState
      * - Each MMState progresses independently until it reaches the latest nonce
      * - Multiple MMs can be verified at the same nonce level, but each MM's nonce must be
      *   monotonically increasing
      *
      * Example: If VRL nonce is 5, MM A can submit nonce 5 even if MM B has already submitted
      * nonce 5, but MM A cannot submit nonce 4 if they've already submitted nonce 5.
      */
     // Replacement deployments reset storage, so owner can seed continuity before re-registering a new handler.
     // Seeders may only move these replay guards forwards; they can never lower an already-recorded nonce.
     mapping(address => uint256) public mmNonce;
     mapping(address => uint256) public submitAuthNonce;
     address public immutable submitter;
     bytes32 internal constant RELAY_AUTH_TYPEHASH = keccak256(
         "RelayAuth(address sender,uint256 commitId,bytes32 liquiditySignalHash,uint256 deadline,uint256 nonce)"
     );
 
     constructor(address _verifier, address _submitter, address _initialOwner)
         Ownable(_initialOwner)
         EIP712("VRLSignalManager", "1")
     {
         if (_submitter == address(0)) revert Errors.InvalidAddress(_submitter);
 
         verifier = ISignalVerifier(_verifier);
         submitter = _submitter;
     }
 
     modifier onlySubmitter() {
         _onlySubmitter();
         _;
     }
 
     function _onlySubmitter() internal view {
         if (msg.sender != submitter) revert Errors.InvalidSender();
     }
 
     /**
      * @dev This function is used to set the verifier for the VRLSpokeReceiver
      *      the verifier responsible for verifing the signatures and inclusion proofs
      * @param _newVerifier The new verifier to set
      */
     function setVerifier(address _newVerifier) external onlyOwner {
         address oldVerifier = address(verifier);
         verifier = ISignalVerifier(_newVerifier);
         emit VerifierChanged(oldVerifier, _newVerifier);
     }
 
     /**
      * @dev This function is used to get the verifier for the VRLSpokeReceiver
      * @return The verifier address
      */
     function getVerifier() external view returns (address) {
         return address(verifier);
     }
 
     /// @notice Seed the minimum accepted MM nonce on a replacement deployment before re-registering the handler.
     /// @dev Owner may only move the stored nonce forwards, preserving monotonic replay protection across redeploys.
     function seedMMNonce(address marketMaker, uint256 minimumNonce) external onlyOwner {
         uint256 previousNonce = mmNonce[marketMaker];
         if (minimumNonce < previousNonce) {
             revert Errors.InvalidNonce(minimumNonce, previousNonce);
         }
         if (minimumNonce == previousNonce) return;
         mmNonce[marketMaker] = minimumNonce;
         emit MMNonceSeeded(marketMaker, previousNonce, minimumNonce);
     }
 
     /// @notice Seed the next relayed authorisation nonce on a replacement deployment before re-registering.
     /// @dev Owner may only move the stored nonce forwards, preserving monotonic replay protection across redeploys.
     function seedSubmitAuthNonce(address sender, uint256 minimumNonce) external onlyOwner {
         uint256 previousNonce = submitAuthNonce[sender];
         if (minimumNonce < previousNonce) {
             revert Errors.InvalidNonce(minimumNonce, previousNonce);
         }
         if (minimumNonce == previousNonce) return;
         submitAuthNonce[sender] = minimumNonce;
         emit SubmitAuthNonceSeeded(sender, previousNonce, minimumNonce);
     }
 
     function _assertSenderAuthorised(LiquiditySignal memory signal, address sender) internal pure {
         if (sender != signal.mmState.owner && sender != signal.mmState.advancer) {
             revert Errors.InvalidSender();
         }
     }
 
     /**
      * @dev This function is used to verify the liquidity signal and return the tickers and amounts of the assets
      * @param signal The liquidity signal to verify
      * @return isProofValid Whether the proof is valid
      */
     function _verifyLiquiditySignalInternal(LiquiditySignal memory signal)
         internal
         returns (bool isProofValid, uint256 _signalExpiryInSeconds)
     {
         // derive the liquidity signal
         // validate the new nonce is greater than than the previous nonce
         if (signal.nonce <= mmNonce[signal.mmState.owner]) {
             revert Errors.InvalidNonce(signal.nonce, mmNonce[signal.mmState.owner]);
         }
 
         // Leaf-bound proof freshness: `expiryAt` is part of the signed Merkle leaf (`mmState`).
-        if (block.timestamp > signal.mmState.expiryAt) {
+        if (block.timestamp >= signal.mmState.expiryAt) {
             revert Errors.DeadlinePassed(signal.mmState.expiryAt);
         }
 
         // verify the proofs associated with the state
         isProofValid = verifier.verifyProof(
             signal.nonce, signal.rootHash, signal.rootHashSignature, signal.mmState, signal.merkleProof
         );
 
         if (isProofValid) {
             // update the nonce for the mm if the proof is valid
             mmNonce[signal.mmState.owner] = signal.nonce;
             // emit the verified liquidity signal
             emit LiquiditySignalVerified(signal);
         }
 
         // On-chain commit window is the remaining time until the leaf `expiryAt` (signed in the Merkle state).
         _signalExpiryInSeconds = signal.mmState.expiryAt - block.timestamp;
     }
 
     function verifyLiquiditySignal(address sender, bytes memory liquiditySignal, bool revertOnInvalid)
         external
         onlySubmitter
         returns (bool ok, uint256 _signalExpiryInSeconds)
     {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         _assertSenderAuthorised(signal, sender);
         (ok, _signalExpiryInSeconds) = _verifyLiquiditySignalInternal(signal);
         if (revertOnInvalid && !ok) revert Errors.InvalidProof();
     }
 
     function verifyLiquiditySignalRelayed(
         address sender,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig,
         bool revertOnInvalid
     ) external onlySubmitter returns (bool ok, uint256 _signalExpiryInSeconds) {
-        if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);
+        if (block.timestamp >= deadline) revert Errors.DeadlinePassed(deadline);
         if (authNonce != submitAuthNonce[sender]) {
             revert Errors.InvalidNonce(authNonce, submitAuthNonce[sender]);
         }
 
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         _assertSenderAuthorised(signal, sender);
 
         bytes32 structHash = EfficientHashLib.hash(
             abi.encode(RELAY_AUTH_TYPEHASH, sender, commitId, keccak256(liquiditySignal), deadline, authNonce)
         );
 
         if (_hashTypedDataV4(structHash).recover(authSig) != sender) {
             revert Errors.InvalidSender();
         }
 
         (ok, _signalExpiryInSeconds) = _verifyLiquiditySignalInternal(signal);
         if (revertOnInvalid && !ok) revert Errors.InvalidProof();
         if (ok) {
             submitAuthNonce[sender] = authNonce + 1;
         }
     }
 }
```

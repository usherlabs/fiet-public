# Vuln #9 Scan #2: Direct-core front-running can only grief proxy swaps in a lane-matched, queue-dependent ordering edge case (resolution)

Last updated: 2026-03-25

## Summary

The original finding appears to overstate the scope of the issue.

The currently supported code path does **not** show a broad invariant break where any dust direct-core swap can generally pre-drain liquidity and disrupt any later proxy swap. The narrower issue is:

- a prior **direct core swap** can trigger `handleSwap(lccTokenIn)`;
- that path only settles obligations for the **input LCC lane** of the direct core swap;
- it only has an effect when there is a non-zero **unfunded queue** for that same underlying; and
- a later **proxy swap** is only affected if its required **output underlying** is the same lane that was just settled and the transaction ordering is adversarial.

So the adjusted vulnerability scope is best described as a **conditional grief / ordering edge case**, not a pervasive proxy/core desynchronisation issue.

## Affected scope

### Production code

- `contracts/evm/src/CoreHook.sol`
- `contracts/evm/src/ProxyHook.sol`
- `contracts/evm/src/modules/VaultCoreActionHandler.sol`
- `contracts/evm/src/modules/MarketVault.sol`

## Adjusted vulnerability scope

### What the finding gets right

There is a real mechanism by which a prior direct core swap can change what a later proxy swap sees in `inMarketBalanceOf(...)`.

The relevant follow-up path is:

1. `CoreHook._afterSwap(...)` detects a direct core action and notifies the canonical proxy-side handler.
2. `VaultCoreActionHandler.handleSwap(lccTokenIn)` is called for the **input** lane of that direct core swap.
3. `MarketVault._settleObligationsForLCC(lccTokenIn)` may move underlying from the vault to the Hub.
4. A later proxy swap reads the reduced `inMarketBalanceOf(outputUnderlying)` and may:
   - revert, for **exact-output** proxy swaps when immediate output underlying is insufficient (strict exact-output, including when a deficit recipient is resolved via `hookData`); or
   - revert when the recipient cannot be resolved, for exact-input; or
   - produce output-side queued excess / deficit LCC for a resolved exact-input recipient.

### What the finding overstates

The effect is not general to all later proxy swaps.

For the issue to manifest, all of the following must be true:

1. The prior direct core swap must use as its **input** the same LCC lane whose underlying the later proxy swap needs as **output**.
2. `LiquidityHub.unfundedQueueOfUnderlying(lccTokenIn)` must be non-zero at that time.
3. The vault must hold enough liquidity on that same underlying for the settlement side effect to matter.
4. The attacker must obtain favourable ordering ahead of the victim proxy swap, which in practice means a mempool / builder / sequencing environment that allows front-running.

That is materially narrower than:

- "any direct core swap now triggers a vault pre-drain"; or
- "proxy swaps are generally no longer a façade over the core curve".

## Behavioural clarification

### Lane specificity matters

`handleSwap(...)` only settles obligations for `lccTokenIn`, not both lanes and not the output lane of the direct core swap.

That means the later proxy swap is only exposed when its output underlying matches the earlier direct core swap's input lane.

### Queue state matters

The settlement side effect is gated by `unfundedQueueOfUnderlying(...)`.

If there is no unfunded queue for that underlying, the direct core swap does not reduce vault availability through this path.

### Exact-output vs exact-input matters

The later proxy swap outcome depends on swap shape:

- **Exact-output**: reverts when immediate output underlying in the vault cannot cover the full requested output (`Errors.InsufficientLiquidity(...)`), regardless of whether `hookData` resolves a deficit recipient. Queued-deficit exact-output on the proxy pool is not supported: **MKT-05** requires the hook’s specified delta to cancel the full `amountSpecified`, which is incompatible with under-settling immediate underlying while still completing the Uniswap swap leg.
- **Exact-input with unresolved recipient**: still reverts when the immediate output cannot be fully settled into underlying.
- **Exact-input with resolved recipient**: can succeed with queued output-side excess / deficit LCC rather than reverting immediately.

## Framing for the rest of this note

This write-up should therefore assess finding 9 under the following adjusted statement:

> A prior direct core swap can grief a later proxy swap only in the narrower case where transaction ordering is adversarial, the direct swap's input lane matches the proxy swap's output lane, and that underlying currently has unfunded queued settlement debt that `handleSwap(...)` can materialise out of the vault.

That is the right starting point for resolution analysis, severity assessment, and any decision about whether this behaviour is acceptable protocol policy or should be further constrained.

## Resolution (mitigation)

**Exact-output:** Proxy **exact-output** swaps use **strict** semantics: if `inMarketBalanceOf(outputUnderlying)` is below the requested output, the swap **reverts**, including when `hookData` resolves a deficit recipient. A prior attempt to relax this for resolved recipients was **reverted** because it left a non-zero proxy-pool `amountToSwap` (breaking **MKT-05**).

**Exact-input (resolved recipient):** Unchanged — deficit can still be represented as output-side LCC + queue where the settlement path supports it.

**Documentation:** See `contracts/evm/INVARIANTS.md` (**MKT-05**) for proxy-pool neutralisation requirements.

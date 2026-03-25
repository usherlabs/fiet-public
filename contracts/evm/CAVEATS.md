# Liveness

This document records known liveness caveats in the EVM contracts where the protocol deliberately prefers
invariant preservation and solvency-safe behaviour over always-on execution.

## Proxy Swaps Depend on Shared Vault Liquidity

Proxy-pool swaps do **not** execute against the proxy pool's own AMM curve. Per `contracts/evm/INVARIANTS.md`
(`MKT-05`), proxy swaps must be fully neutralised at the Uniswap layer so the proxy pool does not advance its own
price state.

That requirement has an important liveness consequence: proxy swaps are not only a function of the core pool price.
They also depend on whether the protocol can immediately source the required underlying asset from the market vault.

Today, proxy swaps read vault availability via `inMarketBalanceOf(...)` and then settle output from the same shared
inventory. That inventory is also used by other legitimate protocol paths, including:

- direct `unwrap()` / `unwrapTo()` flows that consume market liquidity;
- queue settlement and obligation processing;
- market-liquidity withdrawals used by protocol paths such as MM flows; and
- any other path that lawfully draws on the same in-market underlying balance.

As a result, a proxy swap can revert if an earlier transaction has already consumed the relevant output-side
underlying liquidity, even if the core pool itself would still price the trade.

## Why the Protocol Fails Closed

For proxy exact-output, insufficient immediate underlying must revert.

The protocol previously explored allowing resolved-recipient exact-output swaps to continue under shortfall by
delivering what could be settled immediately and queueing the remainder. That approach was reverted.

The reason is mechanical, not cosmetic:

- proxy exact-output must cancel the full specified leg of the proxy swap;
- if the hook settles less underlying than the requested exact output, the hook delta no longer neutralises the full
  `amountSpecified`; and
- any residual `amountToSwap` would cause the proxy pool's own swap logic to execute, breaking `MKT-05`.

So when immediate output liquidity is unavailable, reverting is the correct safety-preserving behaviour. The revert is
not a loss-of-funds event; it is a guardrail that prevents the protocol from violating its single-curve execution
model.

## Scope of the Liveness Caveat

This caveat is broader than direct-core follow-up settlement alone.

It is true that a prior direct core swap can, in some circumstances, reduce the output-side liquidity later observed
by a proxy swap. But the same general effect can arise from any protocol action that validly consumes the same shared
vault liquidity first. In particular, proxy liveness can be affected by:

- `unwrap()` and `unwrapTo()` when they source market liquidity rather than only Hub direct reserve;
- queue settlement / obligation fulfilment paths;
- MM or other protocol withdrawals that consume the same vault-backed underlying; and
- adversarial transaction ordering in environments where front-running or preferred ordering is possible.

Accordingly, the correct mental model is:

> proxy-pool swaps preserve price-path invariants first, and only execute when immediate vault-backed settlement can
> be completed without causing the proxy pool's own AMM state machine to run.

This means the proxy path should be treated as an invariant-constrained settlement facade over the core pool, not as a
hard guarantee that every core-priceable trade will also be live through the proxy entrypoint.

## Operational Position

The protocol currently accepts this liveness trade-off.

The alternative designs considered here all require an explicit policy choice about which users or flows receive
priority over shared market liquidity. Examples include reserving inventory for proxy swaps, splitting settlement
buffers, or introducing activity-based locking. Those designs may improve proxy UX, but they also add accounting
complexity, prioritisation semantics, and new griefing surfaces.

At present, the protocol chooses the simpler and safer rule:

- preserve `MKT-05` and related accounting invariants;
- keep proxy exact-output strict;
- allow proxy exact-input deficit handling only where the existing settlement path already safely supports it; and
- fail closed when immediate underlying settlement cannot be completed safely.

## User / Integrator Guidance

Integrators and active traders should treat the two swap surfaces differently:

- the **core pool** is the preferred route when execution certainty against the protocol's price curve is the primary
  goal;
- the **proxy pool** is an invariant-constrained convenience surface that additionally depends on immediate vault
  settlement capacity; and
- a proxy-swap revert due to insufficient immediate liquidity should be interpreted as a liveness limitation, not as
  evidence of lost funds or broken solvency.

Where a flow cannot tolerate this liveness caveat, route through the core pool directly instead of relying on the
proxy settlement facade.

## Summary

This is a known caveat, not an accidental relaxation of safety checks.

Proxy swaps intentionally prioritise invariant safety over universal liveness. If shared vault liquidity is not
available at execution time, the protocol reverts rather than under-settling exact-output or allowing the proxy pool
AMM to execute.

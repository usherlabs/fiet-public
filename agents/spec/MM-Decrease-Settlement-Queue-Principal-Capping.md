# MM decrease: settlement routing and queue principal

Authoritative enforcement points and economic sub-slices for MM liquidity decreases (vault-immediate slice vs Hub queue vs
deferred live `pa.settled`) are documented under **SETTLE-03** in [`contracts/evm/INVARIANTS.md`](../../contracts/evm/INVARIANTS.md).

**Integrator reminder**

- **Cancel-with-queue / VTS routing caps** use hook-time pool principal `callerDelta - feesAccrued`.
- **Decrease/burn `amount0Min` / `amount1Min`** floors use per-leg non-fee LCC after informational fee netting
  (`LiquidityUtils.forwardedNonFeeLccAmount`), which is **not** the same scalar as `callerDelta - feesAccrued`.

Historical research notes that referenced legacy fee-materialisation mechanics were retired with fee disablement; see git
history if you need the older narrative.

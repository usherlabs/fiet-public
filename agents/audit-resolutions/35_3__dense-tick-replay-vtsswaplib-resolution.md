# Finding 35_3: Dense-tick replay / gas pressure in `VTSSwapLib.processSwap` (resolution)

Last updated: 2026-04-23

## Summary

The finding correctly identifies that `VTSSwapLib.processSwap` must replay each **initialised tick** crossed on the Uniswap v4-style path after a core swap, which can become expensive when many ticks are initialised close to `slot0`. The resolution **does not** weaken that replay to a hard cap inside `VTSSwapLib`, because doing so would risk diverging from the v4 swap path semantics that underlie `VTS-02` / `VTS-03` accounting (see `INVARIANTS.md` **VTS-REF**).

Instead, the protocol mitigates the **attack surface** for pathological tick density at the **core liquidity policy** layer: **`CoreHook` now rejects ultra-narrow, dust non–market-maker adds** on the core pool, while MM operations (non-zero `commitId` in decoded hook data) bypass the gate. This is documented as **CORE-DIRECT-LP-01** in `contracts/evm/INVARIANTS.md`.

## Implemented changes

### 1. Core topology / LP policy (preferred mitigation layer)

- **File**: `contracts/evm/src/CoreHook.sol`
- **Behaviour**: `_enforceDirectLiquidityAntiGrief` runs on positive `liquidityDelta` for non-MM adds:
  - minimum width: `(tickUpper - tickLower) >= MIN_DIRECT_LP_TICK_SPACING_STEPS * tickSpacing` with `MIN_DIRECT_LP_TICK_SPACING_STEPS = 2`;
  - minimum liquidity delta: `MIN_DIRECT_LP_LIQUIDITY_DELTA`.
- **Errors**: `Errors.DirectLiquidityRangeTooNarrow`, `Errors.DirectLiquidityTooSmall` in `contracts/evm/src/libraries/Errors.sol`.

PoolManager surfaces hook reverts as **`CustomRevert.WrappedError`** (ERC-7751-style); callers see the hook address, `IHooks.beforeAddLiquidity`, the inner error payload, and `Hooks.HookCallFailed`.

### 2. Correctness reference and differential coverage

- **Invariant**: **VTS-REF** formalises parity expectations with Uniswap v4 `Pool.swap` / `crossTick`.
- **Tests**:
  - `contracts/evm/test/libraries/VTSSwapLibUniswapParity.t.sol` — real `PoolManager` swaps vs `SwapSimulator` / slot0 parity.
  - `contracts/evm/test/libraries/VTSSwapLib.t.sol` — retained regression coverage (gap swaps, boundary flips, wrong `tickBefore` divergence).
- **Note**: Tests that add liquidity on the **core pool** were widened to satisfy **CORE-DIRECT-LP-01** (e.g. two tick-spacing steps when `tickSpacing = 60`).

### 3. Gas baseline and policy regression

- **File**: `contracts/evm/test/libraries/VTSSwapLibDenseTickGas.t.sol`
  - `test_gas_processSwap_multi_tick_baseline_non_trivial` — baseline `processSwap` gas after compliant wide adds.
  - `test_direct_lp_single_spacing_width_reverts_on_core` — expects `WrappedError` around `DirectLiquidityRangeTooNarrow(60,120)` for a single-spacing `0–60` range with `tickSpacing = 60`.

## Why this preserves correctness

- **VTS replay remains a faithful replay** of the crossed-initialised-tick sequence implied by v4 swap stepping, so `VTS-02` / `VTS-03` attributions stay tied to the same path the pool executed.
- **Policy** reduces economically meaningless single-step dust bands that only exist to inflate crossing count, without changing swap math or capping crosses after the fact.

## Residual trade-offs

- Very small retail-style ranges on the **core pool** must go through MM-position paths (or meet the minimum width / liquidity floor) rather than permissionless single-step mints.
- **Extremely** small `tickSpacing` deployments may still admit many initialised ticks per price move; governance and market parameters should remain aligned with expected trade size and volatility (see also the operating notes in `vulnerability 46-per-tick-outside-growth-gas-griefing-resolution.md`).

## Validation commands

```bash
cd contracts/evm
forge test --match-contract VTSSwapLibTest
forge test --match-contract VTSSwapLibUniswapParityTest
forge test --match-contract VTSSwapLibDenseTickGasTest
```

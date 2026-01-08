# PROPOSAL: Stylus-based “Atomic Revalidation” Validator for Maker Intents

## Context and goal

Fiet’s Market Maker (MM) operation is predominantly **off-chain planned** (planner/risk/quoting) and **on-chain executed** (Uniswap v4 + Fiet protocol actions). The primary failure mode we want to mitigate is:

- **State drift between planning and execution** (even a single block) causing:
  - unexpected slippage / tick movement,
  - RfS (Request-for-Settlement) gating issues,
  - unexpected settlement queues / liquidity shortfalls,
  - breaches of SafetyLimits (amounts / liquidity delta),
  - execution that is correct “per calldata”, but incorrect “per intent”.

This document proposes an **intent validator** that:

- is reused **off-chain** as a deterministic crate (for preflight checks), and
- is deployed **on-chain** (Stylus program) to re-check the same invariants against **atomic chain state** immediately before the wallet executes.

The validator is designed to be expressive enough for MM operations, while remaining bounded, auditable, and gas-predictable.

---

## High-level design overview

We introduce three layers:

- **(1) Intent encoding (what is authorised)**
  - A signed “intent envelope” containing:
    - call bundle hash (targets + selectors + calldata hashes + value),
    - a “check program” (conditions to verify atomically),
    - expiry (`deadline`) and a wallet-scoped nonce,
    - domain separation (chain ID, wallet address, validator address/version).

- **(2) Facts acquisition (how state is observed)**
  - Off-chain: fetch facts from RPC/indexer; normalise units; then run the same check program.
  - On-chain: re-fetch the facts atomically using `staticcall` to the canonical contracts (PoolManager, `VTSOrchestrator`, `MMPositionManager`, `LiquidityHub`, oracle helpers, etc.).

- **(3) Deterministic validation core (how facts are checked)**
  - A pure, deterministic “validator-core” module:
    - decodes the check program,
    - executes checks against a structured facts view,
    - enforces SafetyLimits semantics,
    - returns pass/fail (+ optional structured error codes).

This closely matches the patterns already present in:

- `maker/core/src/planner/validation.rs` (pure request invariants),
- `maker/core/src/risk.rs` (`SafetyLimits` as the canonical limits model),
- `maker/services/execution/.../safety_guard.rs` (execution-time enforcement, but currently mixed with off-chain price services).

---

## Why this belongs under `protocol/contracts/stylus/`

This directory is the right home for:

- the **on-chain Stylus validator contract** (WASM),
- its ABI export artefacts,
- and a documentation hub for the validator’s integration into the protocol execution stack.

We do **not** propose rewriting core protocol contracts in Stylus as a primary gas optimisation. Instead, we apply Stylus where it is most viable:

- **decode/iterate/compute-heavy validation loops**,
- **read-heavy fact aggregation**,
- and a modular “verifier/validator by address” deployment pattern.

---

## Scope: what we will and will not do

### In scope

- A generic “check program” that can express:
  - deadline/nonce checks,
  - pool price/tick drift bounds (e.g. `slot0` constraints),
  - RfS gating constraints (withdrawal only when RfS closed, headroom checks),
  - settlement queue and reserve constraints,
  - token allowlists and max per-token amounts,
  - max liquidity delta constraints,
  - optional “getter-based” checks for arbitrary protocol facts, with strict guardrails.

### Out of scope (for the first implementation)

- Running the full planner on-chain.
- Arbitrary dynamic loops over protocol state (e.g. iterating all positions/commits on-chain).
- Off-chain-only dependencies on-chain (Restate context, external price services, CEX state).
- Unbounded arbitrary getter calls (unsafe, gas grief risk).

---

## Architectural options (choose one as the primary rollout)

### Option A — Solidity validator first, Stylus later (lowest integration risk)

- Implement validator as a Solidity contract (easy to integrate with wallet frameworks, mature tooling).
- Keep the check program encoding stable.
- Later port the interpreter to Stylus if profiling shows the validator itself is a material gas bottleneck.

**Pros**

- Faster to ship, easier audits, easier wallet integration.

**Cons**

- Leaves potential compute/iteration savings on the table.

### Option B — Stylus validator first (highest potential compute efficiency)

- Implement interpreter + fact reads in Stylus.
- Export ABI and call it from wallet/entrypoint.

**Pros**

- Best fit for decode/iterate-heavy workloads.

**Cons**

- Higher integration and audit complexity; more care needed for ABI parity and testing.

### Option C — Hybrid

- Keep “core guardrails” in Solidity (nonce/deadline/call-bundle binding).
- Delegate expensive check-program evaluation to Stylus via `staticcall`.

**Pros**

- Limits blast radius: if Stylus program fails, Solidity wrapper can fail closed.

**Cons**

- Adds an extra call boundary; must keep gas and ABI overhead bounded.

---

## Validator “check program” concept

We model validation as a small bytecode-like DSL (“check program”), signed by the MM bot.

### Requirements

- **Deterministic**: bit-for-bit identical semantics off-chain and on-chain.
- **Bounded**:
  - max program length,
  - max number of checks,
  - max gas per external read,
  - no unbounded loops.
- **Compositional**: checks are independent and can be ordered; fail fast.
- **Auditable**: small opcode set, explicit semantics, and stable versioning.

### Suggested structure (envelope)

- `version` (u16/u32)
- `nonce` (u64/u256) + replay scope (wallet-scoped)
- `deadline` (u64)
- `call_bundle_hash` (bytes32)
- `program_bytes` (bytes)
- `signature` (bytes)

---

## Facts model: “atomic acquisition” on-chain

The validator should support a facts schema that maps to what your execution paths actually care about.

### Canonical fact sources (suggested allowlist)

- **Uniswap v4 PoolManager**
  - `getSlot0(poolId)` → `sqrtPriceX96`, `tick`, fees, etc.
  - liquidity / tick bitmap reads when needed (keep optional; can be expensive).
- **Fiet `VTSOrchestrator`**
  - `calcRFS(commitId, positionIndex, requireClosed)` (note: non-view, but deterministic; consider a view-friendly equivalent or a lighter “RfS lens”)
  - `getPositionSettledAmounts(PositionId)`
  - `getCommitmentMaxima(PositionId)`
  - `positionToCheckpoint(PositionId)` (grace period / RFS checkpoint info)
- **Fiet `MMPositionManager`**
  - commitment ownership and indices (where needed).
- **Fiet `LiquidityHub`**
  - `settleQueue(lcc, owner)`
  - `reserveOfUnderlying(lcc)`
  - `totalQueued(lcc)` (if used for global throttles)
- **Oracle helper / resilient oracle** (optional)
  - recommended only for coarse sanity bounds; avoid deep oracle dependency for the first rollout.

---

## “Arbitrary getter” checks: viability and guardrails

It is viable to allow “any fact exposed via a getter signature”, but only with strong restrictions:

- **Allowlist by (address, selector)**, optionally additionally by **codehash**.
  - Do not allow arbitrary addresses; otherwise this becomes a universal on-chain query engine.
- **Only `staticcall`** with a strict gas cap per call.
- **Return-data constraints**:
  - Prefer fixed-size returns (`uint256`, `int256`, `bool`, `bytes32`, small tuples).
  - For dynamic returns (`bytes`, `string`), compare **`keccak256(returnData)`** instead of decoding.
- **No ambiguous semantics**:
  - The program must specify comparisons as raw numeric comparisons (e.g. `<=`, `>=`) against explicit constants.
  - Any unit normalisation should be performed off-chain and included as constants (or use only canonical on-chain units).

This gives “optionality” without creating an unbounded or un-auditable validator.

---

## Suggested opcode/check set (initial)

Keep the initial set small and aligned to MM velocity + safety:

- **Envelope checks**
  - `CHECK_DEADLINE(now <= deadline)`
  - `CHECK_NONCE(expectedNonce)`
  - `CHECK_CALL_BUNDLE_HASH(bytes32)`

- **Pool state checks**
  - `CHECK_SLOT0_TICK_BOUNDS(poolId, minTick, maxTick)`
  - `CHECK_SLOT0_SQRT_PRICE_BOUNDS(poolId, minSqrtP, maxSqrtP)`
  - `CHECK_POOL_UNLOCKED/LOCKED` (if execution requires a lock state)

- **RfS / VTS checks**
  - `CHECK_RFS_CLOSED(commitId, positionIndex)` (or `PositionId`)
  - `CHECK_SETTLED_GTE(positionId, min0, min1)` (or per-token checks)
  - `CHECK_COMMITMENT_DEFICIT_LTE(positionId, max0, max1)` (if exposed by a view)
  - `CHECK_GRACE_PERIOD_REMAINING_GTE(positionId, minSeconds)` (if relevant)

- **LiquidityHub settlement checks**
  - `CHECK_QUEUE_LTE(lcc, owner, maxQueued)`
  - `CHECK_RESERVE_GTE(lcc, minReserve)`

- **Risk limits (SafetyLimits) checks**
  - `CHECK_TOKEN_ALLOWLIST(token)`
  - `CHECK_TOKEN_AMOUNT_LTE(token, amount)`
  - `CHECK_NATIVE_VALUE_LTE(value)`
  - `CHECK_LIQUIDITY_DELTA_LTE(delta)`

- **Generic getter checks (guarded)**
  - `CHECK_STATICCALL_U256(addr, selector+args, op, rhsU256)`
  - `CHECK_STATICCALL_HASH(addr, selector+args, expectedKeccak256)`

Version the opcode set and treat it as an API.

---

## Reuse plan from `fiet/maker` (what to modularise)

We agree with the direction described in the prompt:

- **Reuse (pure)**
  - Planner request invariants: `core/src/planner/validation.rs` (`validate_request`)
  - Limits model semantics: `core/src/risk.rs` (`SafetyLimits`)

- **Refactor and reuse (pure subset)**
  - Split `services/execution/src/wallet_manager/safety_guard.rs` into:
    - `validate_step_pure(step, limits, now, ...facts...)`
    - `validate_step_with_price_service(...)` (off-chain only)

The on-chain validator should consume:

- a flattened representation of an `ExecutionPlan`/`ExecutionStep` (or a call-bundle hash),
- plus the check-program and limits,
- and then validate using atomic facts.

---

## On-chain integration target: smart wallet validator (EIP-7702 / Kernel-style)

We intend to use the validator as a wallet authorisation layer, not as a protocol contract rewrite.

At a high level:

- the wallet receives a signed intent,
- the validator verifies signature and conditions against atomic state,
- only then the wallet executes the call bundle.

This is compatible with modular validator architectures (e.g. Kernel validators).

Important integration notes:

- **Call bundle binding is mandatory**: the signature must bind the validator conditions to the exact execution payload.
- **Replay protection**: nonce must be wallet-scoped and stored/validated on-chain.
- **Expiry**: strict deadline, fail closed.
- **Fail-closed**: any read failure (`staticcall` failure, short return data, decoding mismatch) must revert/deny.

---

## Security and operational considerations

### Security rails (must-haves)

- **Allowlists**: target addresses + selectors for both execution and fact queries.
- **Gas caps** per `staticcall`, and a max number of checks.
- **No dynamic unbounded decoding** in the validator (hash dynamic return data if needed).
- **Version pinning**: `version` in the signed message; validator rejects unknown versions.
- **Unit discipline**: everything compared in canonical units (ticks, sqrtPriceX96, raw token amounts).

### Testing strategy

- **Property tests**: off-chain crate runs the same check program; compare against on-chain program in a test harness.
- **Golden vectors**: fixed inputs for pool states, VTS states, queue states → expected pass/fail.
- **Adversarial tests**: malformed programs, gas grief attempts, dynamic return data, overflow boundaries.

### Performance strategy

- Keep on-chain reads minimal (prefer single reads like `slot0` over multi-tick iteration).
- Avoid heavy simulations on-chain inside the validator (do those off-chain; validate only critical bounds on-chain).

---

## Rollout phases (suggested)

### Phase 0 — Design freeze

- Finalise:
  - check-program encoding,
  - opcode list v1,
  - fact sources allowlist,
  - signature domain separation rules.

### Phase 1 — Off-chain crate extraction

- Create `validator-core` (pure):
  - parse program,
  - evaluate checks against supplied facts,
  - reuse `SafetyLimits` semantics.
- Add RPC-backed facts provider used by MM bot preflight.

### Phase 2 — On-chain validator (Stylus or Solidity)

- Implement:
  - signature verification + nonce + deadline,
  - atomic fact reads (allowlisted),
  - program evaluation,
  - call-bundle hash binding.
- Export ABI for integration into wallet tooling.

### Phase 3 — Wallet integration

- Wire validator into the chosen wallet architecture (EIP-7702/Kernal-like module).
- Restrict execution targets/selectors to:
  - known routers,
  - `MMPositionManager` entrypoints,
  - settlement/queue collection flows,
  - and any other explicitly approved call surfaces.

### Phase 4 — Iterate

- Add opcodes only when demanded by strategy, keeping the surface area tight.
- Consider a hybrid wrapper if a Solidity “fail-closed” guard is desired around a Stylus interpreter.

---

## Open questions (to answer before implementation)

- Which on-chain runtime is the source of truth for the validator module?
  - Solidity validator contract vs Stylus validator contract vs wallet-native validator module.
- Do we need a view-friendly `RfS lens` method for validation, to avoid non-view `calcRFS` calls from validation contexts?
- What is the minimal allowlist of:
  - fact getter calls, and
  - execution targets/selectors,
  required for the MM’s initial production strategies?
- Should “arbitrary getter” support be included in v1, or delayed until v2 after safety audits?

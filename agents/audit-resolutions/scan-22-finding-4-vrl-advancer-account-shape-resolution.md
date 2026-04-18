# Scan #22, Finding #4: VRL advancer EOA/7702 shape check vs later contract code (resolution)

Last updated: 2026-04-17

## Summary

The original finding ([`../audit-findings/4__medium-code-length-0-treated-as-eoa-in-vrlsignalmanager-assertsupportedadvancer-during-verification-causes-generic-contr.md`](../audit-findings/4__medium-code-length-0-treated-as-eoa-in-vrlsignalmanager-assertsupportedadvancer-during-verification-causes-generic-contr.md)) correctly described a **policy tension**: `VRLSignalManager._assertSupportedAdvancer` treated `code.length == 0` as an acceptable advancer at verification time, while later ordinary MM operations only compared **addresses** (`locker == mmState.advancer`) without re-checking bytecode.

The protocol team’s position is that **enforcing advancer bytecode shape was not a material security property**:

- advancer power is already bounded by **`authorisedRelayer`**, NFT-gated actions, and proof verification
- there is no standalone funds-loss or invariant break from allowing a contract-shaped advancer when the VRL proof and orchestration gates still hold
- the stricter EOA/7702-only rule added complexity and duplicated a concern that is better expressed as **relay auth mode** (ECDSA on `verifyLiquiditySignalRelayed`) vs **direct** verification

**Resolution:** remove `_assertSupportedAdvancer` from `VRLSignalManager`, drop `Errors.InvalidAdvancer`, and rewrite `INVARIANTS.md` / [`../spec/MM-Owner-Advancer-Locker-Role-Matrix.md`](../spec/MM-Owner-Advancer-Locker-Role-Matrix.md) so policy is **account-shape agnostic** for `mmState.advancer`, with an explicit **relay caveat** (ECDSA-only relay).

## Vulnerability recap (original report)

1. At signal verification, `advancer.code.length == 0` could mean undeployed CREATE2 or in-constructor address, not only a long-lived EOA.
2. After commit storage, the advancer could gain arbitrary code.
3. Non-seizing MM ops did not re-validate code shape; only `locker == advancer`.

## Resolution (what changed)

### 1) Code: no advancer bytecode classification in `VRLSignalManager`

- Removed `_assertSupportedAdvancer` and the `EIP7702Utils` import from [`contracts/evm/src/VRLSignalManager.sol`](../../contracts/evm/src/VRLSignalManager.sol).
- Removed `Errors.InvalidAdvancer` from [`contracts/evm/src/libraries/Errors.sol`](../../contracts/evm/src/libraries/Errors.sol).
- Extended NatSpec on [`contracts/evm/src/interfaces/IVRLSignalManager.sol`](../../contracts/evm/src/interfaces/IVRLSignalManager.sol) to document shape-agnostic verification and the relay ECDSA limitation.

### 2) Documentation

- Updated **COMMIT-ROLE-01** in [`contracts/evm/INVARIANTS.md`](../../contracts/evm/INVARIANTS.md).
- Added an **Account shape** subsection to [`agents/spec/MM-Owner-Advancer-Locker-Role-Matrix.md`](../spec/MM-Owner-Advancer-Locker-Role-Matrix.md).

### 3) Tests

- Adjusted [`contracts/evm/test/VRLSignalManager.t.sol`](../../contracts/evm/test/VRLSignalManager.t.sol) so contract-shaped and arbitrary-bytecode advancers are accepted when the verifier accepts the proof (stub verifier), and relay paths no longer expect `InvalidAdvancer`.

## Residual / intentional behaviour

- **`verifyLiquiditySignalRelayed`** remains **`ECDSA.recover(...) == sender`**. Integrators who need relay with non-ECDSA-capable `sender` accounts must address that separately; this is unchanged and is a **relay compatibility** concern, not a protocol-wide advancer bytecode rule.
- **Seizure** and **`authorisedRelayer`** semantics are unchanged.

## Verification

From `contracts/evm`:

```bash
forge test --match-path test/VRLSignalManager.t.sol
```

Optional broader sanity:

```bash
forge test --match-path test/VTSOrchestrator.t.sol
```

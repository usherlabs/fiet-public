# Vulnerability #8: MM sender-fabrication nonce bump / renewal DoS (resolution)

Last updated: 2026-03-10

## Summary

The original report was **directionally real but technically stale**.

The current codebase did **not** expose the exact root cause described in the report:

- `VRLSignalManager.verifyLiquiditySignal(...)` was already `onlySubmitter`
- the default verifier did **not** rely on `mmSignature`

However, the underlying exploit class was still valid on the **non-relayed** path:

- `VTSOrchestrator` accepted a caller-supplied `sender`
- forwarded that `sender` into `VRLSignalManager`
- and `VRLSignalManager` only checked whether the supplied `sender` matched `mmState.owner` or `mmState.advancer`

This meant an attacker inside a `PoolManager.unlock(...)` window could replay a victim's observed `liquiditySignal` and fabricate `sender = owner` or `sender = advancer`, causing `mmNonce` to advance before the legitimate commit / renew transaction landed.

That issue is now resolved by:

- binding the MM integration layer to a concrete `MarketFactory`
- requiring non-relayed commit / renew calls to pass that factory into `VTSOrchestrator`
- trusting forwarded `sender` only when the **actual caller** is protocol-bound in that factory namespace
- otherwise requiring the caller to act only as themselves

Relayed flows remain unchanged and continue to rely on explicit EIP-712 sender authorisation in `VRLSignalManager`.

## Vulnerability recap

### What the original report got right

The report correctly identified the meaningful consequence chain:

1. a third party observes a valid `liquiditySignal`
2. they submit it first
3. the MM's later equal-nonce commit / renew reverts with `InvalidNonce`
4. if that blocks renewal close to expiry, the signal can expire and downstream checkpoint / seizure logic can become hostile to the MM

### What the original report got wrong

Two details of the report no longer matched the live code:

1. `VRLSignalManager` was not callable by arbitrary users; it was already restricted to its configured `submitter`
2. the default verifier did not consume `mmSignature`, and therefore the claimed “`mmSignature` not bound to VRL nonce/root/contract” root cause was stale

So the live exploit path was **not** “public proof verification with a weak verifier”.

It was instead:

- **trusted submitter misuse** on the non-relayed path
- because `VTSOrchestrator` did not authenticate the forwarded `sender` against the real caller

## Actual root cause before the fix

Before remediation, non-relayed commit / renew entrypoints in `VTSOrchestrator` accepted an arbitrary `sender` and passed it directly into `VRLSignalManager`.

`VRLSignalManager` then enforced only:

- `sender == mmState.owner || sender == mmState.advancer`

That check validated the **value** of `sender` against the signal, but did not validate whether the caller was actually allowed to claim that identity.

Because `PoolManager.unlock(...)` is callback-based and permissionless to the unlocking contract, an attacker could:

1. open their own unlock window
2. call `VTSOrchestrator.commitSignal(...)` or `renewSignal(...)`
3. supply the victim's valid `liquiditySignal`
4. fabricate `sender = victimOwner` or `sender = victimAdvancer`

That was sufficient to advance `mmNonce` for the victim MM on the non-relayed path.

## Resolution

### 1) MM integrations are now factory-bound

The MM path no longer resolves its factory dynamically from `LiquidityHub.getFactory(...)` during core MM flows.

Instead, the MM integration layer is bound to a concrete `MarketFactory`, and that bound factory is used throughout the MMPM-side inheritance chain.

Effect:

- the trust namespace for MM commit / renew flows is explicit
- caller-bound checks can now be applied against the correct factory bounds registry
- MM-side helper flows no longer depend on per-call currency-pair factory discovery for the affected surfaces

### 2) Non-relayed VTSO commit / renew now require factory context

The non-relayed VTSO signal entrypoints now take a factory argument:

- `commitSignal(IMarketFactory factory, address sender, bytes liquiditySignal)`
- `renewSignal(IMarketFactory factory, address sender, uint256 commitId, bytes liquiditySignal)`

This allows `VTSOrchestrator` to validate both:

- that the supplied factory is real via `liquidityHub.isFactory(...)`
- that the **actual caller** is protocol-bound for that factory

### 3) Forwarded sender is only trusted from protocol-bound endpoints

The central behavioural fix is now in `VTSOrchestrator._resolveSignalSender(...)`.

For non-relayed flows:

- if the caller is protocol-bound in the provided factory namespace, forwarded `sender` is honoured
- if the caller is not protocol-bound, they may only act as themselves
- if an unbound caller forwards a different `sender`, the call reverts with `InvalidSender`

This closes the original impersonation gap.

An attacker can no longer observe a victim signal and simply claim:

- `sender = mmState.owner`, or
- `sender = mmState.advancer`

unless they are already a protocol-bound endpoint for the relevant factory.

### 4) Relayed flows: factory-bound sender resolution (follow-up)

Relayed entrypoints now mirror non-relayed `commitSignal` / `renewSignal` by taking an explicit `IMarketFactory factory` and resolving the effective sender via `VTSOrchestrator._resolveSignalSender(factory, sender)`. This closes mempool relay front-running where an arbitrary unlock callback could submit a copied EIP-712 payload before the intended protocol-bound caller.

- `commitSignalRelayed(IMarketFactory factory, address sender, ...)`
- `renewSignalRelayed(IMarketFactory factory, address sender, ...)`

EIP-712 `RelayAuth` in `VRLSignalManager` continues to bind `sender`, signal bytes, deadline, and nonce.

## Why the original exploit no longer works

After the fix, an attacker observing a victim's `liquiditySignal` still cannot use the old path unless they satisfy one of two conditions:

1. they are the same address as the claimed `sender`, or
2. they are a protocol-bound endpoint for the validated factory namespace

An arbitrary unlock-callback contract no longer qualifies.

So the attacker can no longer:

- replay the victim signal
- fabricate `sender = owner` / `advancer`
- and pre-emptively bump `mmNonce`

on the non-relayed route.

That removes the prerequisite needed to force the victim's later same-nonce commit / renew to fail.

## Test coverage

The remediation is covered by regression tests in:

- `contracts/evm/test/VTSOrchestrator.t.sol`
- `contracts/evm/test/VTSOrchestrator.reentrancy.t.sol`
- `contracts/evm/test/MMPositionManager.t.sol`
- `contracts/evm/test/marketmaker/MMPositionActionsImpl.t.sol`
- `contracts/evm/test/modules/PositionManagerBase.t.sol`
- `contracts/evm/test/modules/PositionManagerEntrypoint.t.sol`
- `contracts/evm/test/modules/PositionManagerImpl.t.sol`

Specific regression coverage was added for the original exploit class:

- `test_revert_commitSignal_whenUnboundCallerForwardsSender_insideUnlock`
- `test_revert_renewSignal_whenUnboundCallerForwardsSender_insideUnlock`

These prove that an unbound caller inside `PoolManager.unlock(...)` can no longer impersonate the MM `owner` / `advancer` on non-relayed commit / renew.

## Residual assumptions

- This resolution intentionally does **not** introduce VTSO batch scoping or move delta finalisation ownership into `VTSOrchestrator`
- The trust boundary now depends on `factory.bounds(caller)` for non-relayed forwarded sender flows
- Any future protocol-bound endpoint added to a factory must preserve the same sender-auth assumptions; a dangerously generic bound endpoint could reintroduce a similar class of issue through that endpoint
- Relayed sender trust still depends on the existing EIP-712 `SubmitAuth` model in `VRLSignalManager`

## Final assessment

The original report should be interpreted as:

- **stale in stated cryptographic root cause**
- but **valid in exploit class and impact direction**

The implemented remediation closes the real live issue by authenticating forwarded non-relayed sender identity at the `VTSOrchestrator` boundary against the factory-bound protocol surface.

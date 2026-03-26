---
name: Submitter-locked VRL handlers
overview: Refactor VRL proof handler access control to a single constructor-set `submitter` (VTSOrchestrator), remove trusted-caller registries, switch relayed EIP-712 SubmitAuth to Design B (no submitter field), and add safe post-deploy registration in VTSOrchestrator via a new `VTSAdmin` module plus a registration-required modifier.
todos:
  - id: proof-handlers-submitters
    content: Refactor VRLSignalManager + VRLSettlementObserver to submitter-only access; add submitter getters; add baseline seeding arrays; remove trusted-caller registries; update interfaces.
    status: completed
  - id: eip712-design-b
    content: Update VRLSignalManager relayed EIP-712 to Design B (no submitter field) and adjust tests + spec doc accordingly.
    status: completed
  - id: vtso-admin-refactor
    content: Create modules/VTSAdmin.sol; move onlyOwner methods; add registerVRLProofHandlers + registration-required modifier; update VTSOrchestrator to store/register handlers post-deploy.
    status: completed
  - id: deploy-and-tests
    content: Update DeployContracts.s.sol to new deployment order + proxyCall registration; update affected Foundry tests and mocks to new constructors and access control.
    status: completed
isProject: false
---

## Scope and goals

- Replace `trustedCallers`/`setTrustedCaller` gating in VRL proof handler contracts with a **single constructor-set `submitter`** + `onlySubmitter` modifier.
- Adopt **Design B** for relayed EIP-712: remove `submitter` from the signed typed data and rely on `onlySubmitter` to enforce who can call `verifyLiquiditySignalRelayed`.
- Seed baseline replay/nonce state at deployment time:
  - `VRLSignalManager`: baseline `mmNonce` and baseline `submitAuthNonce`.
  - `VRLSettlementObserver`: baseline `usedProofHashes` (selected).
- Change `VTSOrchestrator` to **register proof handlers post-deploy** (owner-only) instead of constructor arguments, with a shared modifier that enforces registration.
- Extract admin-only methods to `VTSAdmin` (new module) and update deploy script wiring.

## Key existing on-chain anchor points

- Current relayed typed data includes submitter:

```44:46:/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VRLSignalManager.sol
bytes32 internal constant SUBMIT_AUTH_TYPEHASH = keccak256(
    "SubmitAuth(address sender,address submitter,bytes32 liquiditySignalHash,uint256 deadline,uint256 nonce)"
);
```

- `VTSOrchestrator` currently receives proof handlers in its constructor and stores them as `immutable`:
  - `/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol`

## Design decisions (locked)

- **Relayed auth (Design B)**: new typed message omits `submitter`.
  - New type string: `SubmitAuth(address sender,bytes32 liquiditySignalHash,uint256 deadline,uint256 nonce)`.
  - Verification relies on:
    - `onlySubmitter` (enforces the caller contract)
    - EIP-712 signature recovers `sender`
    - `submitAuthNonce[sender]` replay protection
- **Settlement observer baseline initialisation**: seed `usedProofHashes` via constructor `bytes32[] baselineUsedProofHashes`.
- **Registration safety**: proof handlers expose `submitter()` so `VTSAdmin` can assert `handler.submitter() == address(this)` at registration time.

## Implementation steps

### A) VRLSignalManager: submitter-only access + baseline nonces + Design B EIP-712

Update `/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VRLSignalManager.sol` and `/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/interfaces/IVRLSignalManager.sol`.

- **Remove trusted-caller registry**:
  - Delete `trustedCallers` mapping, `TrustedCallerSet` event, `setTrustedCaller`, and `onlyTrustedCaller` modifier.
- **Add submitter enforcement**:
  - `address public immutable submitter;`
  - `modifier onlySubmitter() { _onlySubmitter(); _; }`
  - `function _onlySubmitter() internal view { if (msg.sender != submitter) revert Errors.InvalidSender(); }`
  - Ensure `verifyLiquiditySignal` and `verifyLiquiditySignalRelayed` use `onlySubmitter`.
- **Add baseline nonce seeding** (constructor arrays):
  - `address[] baselineMmOwners, uint256[] baselineMmNonces` → set `mmNonce[owner]=nonce`.
  - `address[] baselineAuthSenders, uint256[] baselineAuthNonces` → set `submitAuthNonce[sender]=nonce`.
  - Validate array lengths match.
- **Design B EIP-712 update**:
  - Update `SUBMIT_AUTH_TYPEHASH` to the new type string without `submitter`.
  - Update `structHash` encoding to remove `msg.sender`.
  - Keep `deadline` + `authNonce` checks as-is.

### B) VRLSettlementObserver: submitter-only access + baseline used-proof seeding

Update `/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VRLSettlementObserver.sol` and `/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/interfaces/IVRLSettlementObserver.sol`.

- Remove `trustedCallers` mapping, `TrustedCallerSet` event, `setTrustedCaller`, and `onlyTrustedCaller`.
- Add `address public immutable submitter;` + `onlySubmitter` + `_onlySubmitter()`.
- Update `verifySettlementProof(...)` to be `onlySubmitter`.
- Add constructor arg `bytes32[] baselineUsedProofHashes` to pre-mark `usedProofHashes[hash]=true`.

### C) VTSAdmin module: collate admin and add registration-required modifier

Create new module file `/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/modules/VTSAdmin.sol` and update `/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol`.

- Move existing `onlyOwner` admin methods (currently `setMarketVTSConfiguration(...)`) into `VTSAdmin`.
- Add proof handler registration in `VTSAdmin`, e.g.:
  - `registerVRLProofHandlers(address signalManager, address settlementObserver)` (owner-only)
  - Emits events like `VRLProofHandlersRegistered(...)`.
  - Validations:
    - non-zero addresses
    - `IVRLSignalManager(signalManager).submitter() == address(this)`
    - `IVRLSettlementObserver(settlementObserver).submitter() == address(this)`
- Add modifier for runtime safety:
  - `modifier onlyIfVRLHandlersRegistered() { _onlyIfVRLHandlersRegistered(); _; }`
  - `_onlyIfVRLHandlersRegistered()` checks that both handler addresses are set.
- In `VTSOrchestrator`, apply `onlyIfVRLHandlersRegistered` to all functions that depend on handlers (at minimum: `commitSignal`_, `renewSignal`_, and any settlement-proof pathway that ultimately calls `CheckpointLibrary.extendGracePeriod(...)`).

### D) VTSOrchestrator: remove constructor args for handlers, store handlers in state

Update `/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol`.

- Remove `_signalManager` and `_settlementObserver` from constructor args.
- Convert `signalManager` and `settlementObserver` from `immutable` to settable storage vars initialised to `address(0)`.
- Remove direct assignment in constructor and rely on `registerVRLProofHandlers`.

### E) Update deploy script wiring

Update `/Users/ryansoury/dev/fiet/protocol/contracts/evm-scripts/script/deploy/DeployContracts.s.sol`.

- Deploy `VTSOrchestrator` without handler args.
- Deploy `VRLSignalManager` with `submitter = vtsOrchestrator` and baseline arrays (likely empty in script).
- Deploy `VRLSettlementObserver` with `submitter = vtsOrchestrator` and baseline usedProofHashes array (likely empty).
- After deployments, call `VTSOrchestrator.registerVRLProofHandlers(...)` via `GlobalConfig.proxyCall` (since owner is `globalConfig`).

### F) Tests + spec doc updates

- Update tests that currently call `setTrustedCaller`:
  - `/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/VRLSignalManager.t.sol`
  - `/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/VRLSettlementObserver.t.sol`
  - `/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/base/MarketTestBase.sol`
  - any mocks implementing `IVRLSignalManager` / `IVRLSettlementObserver`.
- Update relayed EIP-712 test vectors in `VRLSignalManager.t.sol` to the new typehash and signing payload (remove submitter field).
- Update the repo doc you added earlier:
  - `/Users/ryansoury/dev/fiet/protocol/agents/spec/VRL-Signal-Relaying-(EIP-712)-SubmitAuth.md` to reflect Design B typed data.

## Rollout / verification

- Compile + run Foundry tests, focusing on:
  - `VRLSignalManager.t.sol`
  - `VRLSettlementObserver.t.sol`
  - `MMPositionManager`/commitment flows (`MarketTestBase`-derived suites)
  - `Checkpoint`/settlement proof flows

## Expected deltas (high level)

- External callers will no longer need a trusted-caller allowlist; only the orchestrator can call the proof handlers.
- Relayed EIP-712 authorisation no longer includes `submitter` in the signature, reducing signed payload complexity and removing submitter drift.
- Deployments and tests will switch from constructor-wiring to post-deploy registration (owner-only) with enforced submitter matching.

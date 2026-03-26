# VRL Signal Relaying (EIP-712) — `SubmitAuth`

This spec documents how to produce the **off-chain** EIP-712 signature required by `VRLSignalManager.verifyLiquiditySignalRelayed(...)`, and how to pass it through the protocol using the existing `MMPositionManager` actions (`COMMIT_SIGNAL` / `RENEW_SIGNAL`) via `relayParams`.

## On-chain contract references

- **Verifier of relayed authorisation**: `contracts/evm/src/VRLSignalManager.sol`
- **Relayed verification entrypoint**: `IVRLSignalManager.verifyLiquiditySignalRelayed(...)`
- **Relayed commit/renew entrypoints**:
  - `VTSOrchestrator.commitSignalRelayed(...)`
  - `VTSOrchestrator.renewSignalRelayed(...)`
- **MMPositionManager action payloads** (relay passthrough):
  - `COMMIT_SIGNAL`: `(bytes liquiditySignal, address owner, bytes relayParams)`
  - `RENEW_SIGNAL`: `(uint256 tokenId, bytes liquiditySignal, bytes relayParams)`

## Security intent

Relaying allows a third-party submitter (e.g. a router) to submit a `liquiditySignal` **on behalf of** a declared `sender` (either `mmState.owner` or `mmState.advancer`) while still binding:

- **who is authorised**: `sender` must sign the EIP-712 message
- **who may submit**: the caller is enforced on-chain by `onlySubmitter` (constructor-set submitter)
- **what may be submitted**: the message is bound to the exact `liquiditySignal` bytes
- **replay protection**: `submitAuthNonce[sender]` is consumed on success
- **expiry**: `deadline`

## EIP-712 domain

`VRLSignalManager` inherits OpenZeppelin `EIP712("VRLSignalManager", "1")`.

Domain fields:

- **name**: `"VRLSignalManager"`
- **version**: `"1"`
- **chainId**: current chain id
- **verifyingContract**: deployed `VRLSignalManager` address

## Typed data

Type string (must match on-chain `SUBMIT_AUTH_TYPEHASH`):

```text
SubmitAuth(address sender,bytes32 liquiditySignalHash,uint256 deadline,uint256 nonce)
```

Fields:

- **sender**: the effective actor (must equal either `mmState.owner` or `mmState.advancer` in the decoded signal)
- **liquiditySignalHash**: `keccak256(liquiditySignal)` where `liquiditySignal` is the ABI-encoded `LiquiditySignal` bytes blob
- **deadline**: unix timestamp; verification reverts if `block.timestamp > deadline`
- **nonce**: must equal `VRLSignalManager.submitAuthNonce(sender)` at submission time

Important:

- The submitter is no longer signed in typed data.
- `VRLSignalManager` enforces `msg.sender == submitter` via `onlySubmitter`.
- When deployed for protocol flows, `submitter` should be the `VTSOrchestrator` contract address.

## How to sign (ethers.js example)

This example signs the typed data as an EOA using ethers v6.

```ts
import { ethers } from "ethers";

type SubmitAuth = {
  sender: string;
  liquiditySignalHash: string; // bytes32
  deadline: bigint;
  nonce: bigint;
};

const domain = {
  name: "VRLSignalManager",
  version: "1",
  chainId: 1n, // replace
  verifyingContract: "0xVRLSignalManagerAddress", // replace
};

const types = {
  SubmitAuth: [
    { name: "sender", type: "address" },
    { name: "liquiditySignalHash", type: "bytes32" },
    { name: "deadline", type: "uint256" },
    { name: "nonce", type: "uint256" },
  ],
};

// liquiditySignal is the ABI-encoded LiquiditySignal bytes
const liquiditySignal: Uint8Array = /* ... */;
const liquiditySignalHash = ethers.keccak256(liquiditySignal);

const value: SubmitAuth = {
  sender: "0xSender",       // must be owner or advancer from mmState
  liquiditySignalHash,
  deadline: 1710000000n,    // replace
  nonce: 0n,                // VRLSignalManager.submitAuthNonce(sender)
};

const wallet = new ethers.Wallet("0xPRIVATE_KEY"); // sender's key
const authSig = await wallet.signTypedData(domain, types, value);
```

Notes:

- `authSig` must be a standard 65-byte ECDSA signature (ethers returns `0x`-prefixed hex).
- Make sure the call path reaches `VRLSignalManager` from the configured submitter contract (typically `VTSOrchestrator`).

## How to call on-chain (direct relayed entrypoint)

Call `VRLSignalManager.verifyLiquiditySignalRelayed(...)` from a **trusted caller**:

- `sender`: same as in the signature
- `liquiditySignal`: the exact bytes blob that was hashed
- `deadline`, `nonce`, `authSig`: must match the signature

The function will:

- validate `nonce == submitAuthNonce[sender]`
- validate `keccak256(liquiditySignal)` matches
- recover `authSig` and require recovered signer equals `sender`
- verify the signal’s merkle inclusion + root signature
- bump `mmNonce[mmState.owner]` and `submitAuthNonce[sender]` on success

## Passing relayed auth through `MMPositionManager` actions (`relayParams`)

`MMPositionManager` supports relayed commit/renew by setting `relayParams` to a non-empty ABI blob:

```solidity
relayParams := abi.encode(uint256 deadline, uint256 authNonce, bytes authSig)
```

### COMMIT_SIGNAL params

Action payload:

```solidity
abi.encode(bytes liquiditySignal, address owner, bytes relayParams)
```

Behaviour:

- if `relayParams.length == 0`: calls `VTSOrchestrator.commitSignal(sender, liquiditySignal)`
- else: decodes `(deadline, authNonce, authSig)` and calls `VTSOrchestrator.commitSignalRelayed(marketFactory, sender, liquiditySignal, deadline, authNonce, authSig)`

### RENEW_SIGNAL params

Action payload:

```solidity
abi.encode(uint256 tokenId, bytes liquiditySignal, bytes relayParams)
```

Behaviour:

- if `relayParams.length == 0`: calls `VTSOrchestrator.renewSignal(sender, tokenId, liquiditySignal)`
- else: decodes `(deadline, authNonce, authSig)` and calls `VTSOrchestrator.renewSignalRelayed(marketFactory, sender, tokenId, liquiditySignal, deadline, authNonce, authSig)`

## Operational checklist

- **Before signing**:
  - Read `authNonce = VRLSignalManager.submitAuthNonce(sender)`.
  - Choose a short-lived `deadline`.
- **Before submitting**:
  - Ensure the call reaches `VRLSignalManager` from the configured `submitter`.
- **On failure**:
  - A wrong submitter caller, mismatched signal bytes, expired deadline, or nonce mismatch will revert.

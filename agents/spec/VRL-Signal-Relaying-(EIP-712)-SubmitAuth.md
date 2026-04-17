# VRL Signal Relaying (EIP-712) — `RelayAuth`

This spec documents how to produce the **off-chain** EIP-712 signature required by `VRLSignalManager.verifyLiquiditySignalRelayed(...)`, and how to pass it through the protocol using the existing `MMPositionManager` actions (`COMMIT_SIGNAL` / `RENEW_SIGNAL`) via `relayParams`.

**Canonical on-chain type**: `RelayAuth` in `contracts/evm/src/VRLSignalManager.sol` (not the historical `SubmitAuth` sketch below). Fields are **`signer`** (proof principal) and **`sender`** (MM batch locker; `address(0)` aliases `signer` on fresh commit). The EIP-712 domain uses version **`"1"`**.

## On-chain contract references

- **Verifier of relayed authorisation**: `contracts/evm/src/VRLSignalManager.sol`
- **Relayed verification entrypoint**: `IVRLSignalManager.verifyLiquiditySignalRelayed(...)`
- **Relayed commit/renew entrypoints**:
  - `VTSOrchestrator.commitSignalRelayed(...)`
  - `VTSOrchestrator.renewSignalRelayed(...)`
- **MMPositionManager action payloads** (relay passthrough):
  - `COMMIT_SIGNAL`: `(bytes liquiditySignal, bytes relayParams)`
  - `RENEW_SIGNAL`: `(uint256 tokenId, bytes liquiditySignal, bytes relayParams)`

## Security intent

Relaying allows a third-party submitter (e.g. a router) to submit a `liquiditySignal` **on behalf of** a declared proof principal (`signer`: either `mmState.owner` or `mmState.advancer`) while still binding:

- **who is authorised**: `signer` must sign the EIP-712 message
- **who may submit**: the caller is enforced on-chain by `onlySubmitter` (constructor-set submitter)
- **what may be submitted**: the message is bound to the exact `liquiditySignal` bytes
- **replay protection**: `submitAuthNonce[signer]` is consumed on success
- **expiry**: `deadline`

## EIP-712 domain

`VRLSignalManager` inherits OpenZeppelin `EIP712("VRLSignalManager", "1")`.

Domain fields:

- **name**: `"VRLSignalManager"`
- **version**: `"1"`
- **chainId**: current chain id
- **verifyingContract**: deployed `VRLSignalManager` address

## Typed data

Type string (must match on-chain `RELAY_AUTH_TYPEHASH`):

```text
RelayAuth(address signer,uint256 commitId,bytes32 liquiditySignalHash,address sender,uint256 deadline,uint256 nonce)
```

Fields:

- **signer**: the proof principal (must equal either `mmState.owner` or `mmState.advancer` in the decoded signal)
- **commitId**: `0` for fresh commit relay; existing commit id for renew relay
- **liquiditySignalHash**: `keccak256(liquiditySignal)` where `liquiditySignal` is the ABI-encoded `LiquiditySignal` bytes blob
- **sender**: for **fresh commit** (`commitId == 0`), the MM batch locker / NFT recipient — either the explicit address, or **`address(0)`** meaning custody to **`signer`** (i.e. `mmState.owner` when `signer` is owner). For **renew** (`commitId != 0`), must be **`address(0)`** in the signed payload.
- **deadline**: unix timestamp; verification reverts if `block.timestamp > deadline`
- **nonce**: must equal `VRLSignalManager.submitAuthNonce(signer)` at submission time (same address as the typed-data `sender` field)

Important:

- The submitter is no longer signed in typed data.
- `VRLSignalManager` enforces `msg.sender == submitter` via `onlySubmitter`.
- When deployed for protocol flows, `submitter` should be the `VTSOrchestrator` contract address.

## How to sign (ethers.js example)

This example signs the typed data as an EOA using ethers v6.

```ts
import { ethers } from "ethers";

type RelayAuth = {
  signer: string;
  commitId: bigint;
  liquiditySignalHash: string; // bytes32
  sender: string; // MM batch locker; zero = alias signer on fresh; zero for renew
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
  RelayAuth: [
    { name: "signer", type: "address" },
    { name: "commitId", type: "uint256" },
    { name: "liquiditySignalHash", type: "bytes32" },
    { name: "sender", type: "address" },
    { name: "deadline", type: "uint256" },
    { name: "nonce", type: "uint256" },
  ],
};

// liquiditySignal is the ABI-encoded LiquiditySignal bytes
const liquiditySignal: Uint8Array = /* ... */;
const liquiditySignalHash = ethers.keccak256(liquiditySignal);

const value: RelayAuth = {
  signer: "0xSigner",       // must be owner or advancer from mmState
  commitId: 0n,             // 0 for fresh commit; existing id for renew
  liquiditySignalHash,
  sender: "0xLocker", // fresh: batch locker, or ethers.ZeroAddress to alias signer; renew: ethers.ZeroAddress
  deadline: 1710000000n,    // replace
  nonce: 0n,                // VRLSignalManager.submitAuthNonce(signer address)
};

const wallet = new ethers.Wallet("0xPRIVATE_KEY"); // signer's key
const authSig = await wallet.signTypedData(domain, types, value);
```

Notes:

- `authSig` must be a standard 65-byte ECDSA signature (ethers returns `0x`-prefixed hex).
- Make sure the call path reaches `VRLSignalManager` from the configured submitter contract (typically `VTSOrchestrator`).

## How to call on-chain (direct relayed entrypoint)

Call `VRLSignalManager.verifyLiquiditySignalRelayed(signer, commitId, liquiditySignal, deadline, authNonce, authSig, sender, ...)` from a **trusted caller** (the `submitter`):

- `signer`: same as the typed-data `signer` field in `RelayAuth` (proof principal; must match recovered signature)
- `liquiditySignal`: the exact bytes blob that was hashed
- `sender`: must match the signed typed-data `sender` (MM batch locker / NFT recipient; `address(0)` aliases `signer` on fresh commit)
- `deadline`, `nonce`, `authSig`: must match the signature

The function will:

- validate `nonce == submitAuthNonce[signer]`
- validate `keccak256(liquiditySignal)` matches
- recover `authSig` and require recovered signer equals `signer`
- verify the signal’s merkle inclusion + root signature
- bump `mmNonce[mmState.owner]` and `submitAuthNonce[signer]` on success

## Passing relayed auth through `MMPositionManager` actions (`relayParams`)

`MMPositionManager` supports relayed commit/renew by setting `relayParams` to a non-empty ABI blob:

```solidity
relayParams := abi.encode(uint256 deadline, uint256 authNonce, bytes authSig, address sender)
```

The fourth word is the EIP-712 `RelayAuth.sender` value. For renew relay, pass `address(0)` (must match the signed typed data).

### COMMIT_SIGNAL params

Action payload:

```solidity
abi.encode(bytes liquiditySignal, bytes relayParams)
```

Behaviour:

- if `relayParams.length == 0`: direct fresh commit — requires `msgSender() == mmState.owner`; mints the NFT to `mmState.owner`
- else: decodes `(deadline, authNonce, authSig, sender)` and requires `msgSender()` to equal the NFT recipient (`sender`, or `mmState.owner` when that field is zero), then calls `VTSOrchestrator.commitSignalRelayed(..., sender)`

### RENEW_SIGNAL params

Action payload:

```solidity
abi.encode(uint256 tokenId, bytes liquiditySignal, bytes relayParams)
```

Behaviour:

- if `relayParams.length == 0`: calls `VTSOrchestrator.renewSignal(sender, tokenId, liquiditySignal)`
- else: decodes `(deadline, authNonce, authSig, sender)` and calls `VTSOrchestrator.renewSignalRelayed(..., sender)` (renew signatures use typed-data `sender == 0`)

## Operational checklist

- **Before signing**:
  - Read `authNonce = VRLSignalManager.submitAuthNonce(signer)` (the proof principal address).
  - Choose a short-lived `deadline`.
- **Before submitting**:
  - Ensure the call reaches `VRLSignalManager` from the configured `submitter`.
- **On failure**:
  - A wrong submitter caller, mismatched signal bytes, expired deadline, or nonce mismatch will revert.

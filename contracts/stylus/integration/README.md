# Stylus integration runner (what it actually checks)

This directory contains a **minimal on-chain sanity-check harness** for the Stylus policy program described in `protocol/contracts/stylus/README.md` (see the “Integration runner (devnet / testnet)” section).

It is not a full ERC-4337 / Kernel end-to-end test. Instead, it performs a small set of direct contract calls/transactions against an **already deployed** Stylus program address, to confirm:

- the contract reports the expected **module types**, and
- the contract’s **initialisation state** flips as expected across `onInstall` and `onUninstall`.

The harness lives in `src/main.rs` and is run as a normal Rust binary via Cargo.

## What this runner does (step-by-step)

All behaviour below is implemented in `integration/src/main.rs`.

### 1) Parse CLI args and environment variables

The runner accepts:

- **`--rpc-url`** (or `RPC_URL`): HTTP RPC endpoint.
- **`--deployments-path`** (or `DEPLOYMENTS`, default `deployments.devnet.json`): JSON file written by `tools/deployer`.
- **`--contract-key`** (default `intent-policy`): key under `deployments.<contract-key>.address`.
- **`--private-key`** (or `PKEY`) **or** **`--private-key-path`** (or `PRIV_KEY_PATH`): signer used to send transactions.
- **`--smart-account`** (optional): address passed to `isInitialized(address)` view calls.
- **`--permission-id`** (or `PERMISSION_ID`): bytes32 permission id used to scope policy install state.
- **`--authorised-signer`** (optional): address stored as the policy envelope signer in `onInstall(bytes)`.

Defaults that matter:

- If `--smart-account` is omitted, it uses the **signer’s address**.
- If `--authorised-signer` is omitted, it uses the **signer’s address**.

### 2) Read the deployed contract address from `deployments.<env>.json`

The runner reads `--deployments-path` and expects (at minimum) a shape like:

```json
{
  "deployments": {
    "intent-validator": {
      "address": "0x..."
    }
  }
}
```

It then looks up:

- `deployments[contract_key].address`

and instantiates an `ethers` contract binding at that address with this minimal ABI:

- `onInstall(bytes)`
- `onUninstall(bytes)`
- `isModuleType(uint256)`
- `isInitialized(address)`

### 3) Connect to the RPC and configure the signer

The runner:

- creates an `ethers` HTTP provider from `--rpc-url`,
- fetches `chainId` from the network, and
- loads a local wallet from the provided private key, setting the fetched chain ID.

It wraps the provider with `SignerMiddleware` so it can send transactions.

### 4) Sanity-check: module type detection

The first behavioural check is:

- call `isModuleType(5)` and require **true** (policy)
- call `isModuleType(1)` and require **false** (validator)

If any of these expectations fail, the runner exits with an error:

- “unexpected module-type detection …”

This is aligned with the parent README’s claim that the program is exposed as a **Kernel-compatible `IPolicy`** module.

### 5) Check initialisation state before install

Next it calls:

- `isInitialized(smart_account)`

and prints:

- `isInitialised(before): <bool>`

This is just a read-only query of the contract’s per-account state.

### 6) If needed, call `onInstall(...)` and re-check initialisation

If `isInitialized(smart_account)` was **false**, the runner sends an install transaction:

- **Calldata**: `onInstall(install_data)`
- **Value**: 0
- **`install_data`**: `bytes32(permissionId) || initData`
- **`initData`**: `uint8 version || bytes20 authorisedSigner || bytes20 stateView || bytes20 vtsOrchestrator || bytes20 liquidityHub`

It waits for the transaction receipt and prints:

- `onInstall tx: <hash>`

Then it calls:

- `isInitialized(smart_account)`

and requires it to be **true**, otherwise it errors:

- “expected contract to be initialised after onInstall”

#### Important nuance vs the Kernel flow

In the parent README, “install” typically happens because a **Kernel account** calls into the module during module installation (so `msg.sender` is the Kernel account).

This runner does **not** call `Kernel.installModule(...)`. It calls `onInstall(...)` **directly** from the EOA/private key you provide.

That means:

- the module’s internal “initialised for X” state will be recorded for **`msg.sender`**, i.e. the signer address,
- but the runner *checks* `isInitialized(smart_account)`.

So, for the integration checks to behave as intended, `--smart-account` should typically be the **same address as the signer** (which is why the default is the signer). If you set `--smart-account` to a different address, the runner will likely report “not initialised” even after sending `onInstall`, because it did not install “as” that other address.

### 7) Call `onUninstall(...)` and check initialisation is cleared

Finally, the runner sends an uninstall transaction:

- **Calldata**: `onUninstall(bytes)`
- **Value**: 0
- **Data**: `bytes32(permissionId)` (prefix required by the policy)

It waits for the receipt and prints:

- `onUninstall tx: <hash>`

Then it calls:

- `isInitialized(smart_account)`

and requires it to be **false**, otherwise it errors:

- “expected contract to be uninitialised after onUninstall”

If all checks pass, it prints:

- `Integration checks passed.`

## How this relates to `protocol/contracts/stylus/README.md`

The parent README describes:

- the contract’s role as a Kernel-compatible validator (and optional hook),
- the intended initialisation payload for `onInstall` (packed authorised signer address), and
- the real-world Kernel installation path via `Kernel.installModule(...)` (usually through a UserOperation).

This integration runner specifically validates the **narrowest, lowest-level pieces** of that story:

- **`onInstall` payload shape**: it uses the same packed 20-byte authorised signer format.
- **Module type declarations**: it asserts `isModuleType(1)` and `isModuleType(2)` are true.
- **State transitions**: it verifies `isInitialized(account)` toggles from false → true → false across install/uninstall.

What it does **not** test:

- Kernel’s `installModule(...)` encoding and restrictions
- ERC-4337 UserOperation validation paths (`validateUserOp`, signature validation, EntryPoint interactions)
- correct behaviour of the validator logic beyond these basic lifecycle hooks

## Running it

From `protocol/contracts/stylus/` (repo-relative):

```bash
cargo run --manifest-path integration/Cargo.toml -- \
  --rpc-url "$RPC_URL" \
  --private-key-path "$PRIV_KEY_PATH" \
  --deployments-path deployments.devnet.json \
  --contract-key intent-policy
```

If you want to override the defaults:

- `--smart-account <addr>`: which address you query `isInitialized(...)` for (see the nuance above).
- `--authorised-signer <addr>`: which address is packed into the first 20 bytes of `onInstall(data)`.

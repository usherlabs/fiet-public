# WIP: (Experimental) Fiet Maker Kernel Policy

> **Warning**  
> This folder contains **experimental code** for demonstration and research purposes only.  
> Not ready for **use in production or mainnet** yet.  
> Use at your own risk.

Arbitrum Stylus program written in Rust using the [stylus-sdk](https://github.com/OffchainLabs/stylus-sdk-rs).

This workspace hosts the on-chain **“Atomic Revalidation” intent policy** described in `PROPOSAL.md`, exposed as a **Kernel-compatible** ERC-7579 `IPolicy` module (**module type 5**) intended to be used in the **Kernel permissions** pipeline (eg alongside CallPolicy and a signer module).

The core contract crate is `src/fiet-maker-policy/`. The policy is designed to **fail closed**: if envelope parsing, signature checks, replay protection, program decoding, or on-chain fact acquisition fails, the policy returns a failure code and the UserOperation should not proceed.

- **On-chain policy entrypoint**: `src/fiet-maker-policy/src/intent_policy.rs`
- **Envelope hashing/signing**: `src/fiet-maker-policy/src/utils/policy_envelope.rs`
- **Off-chain encoder / shared types**: `tools/fiet-maker-policy-encoder/`
- **E2E harness (Bun)**: `e2e/`

## Unit Testing

> **Note:**  
> Unit tests in this policy suite may **fail** due to known pending issues with `arbos-forge` and ArbOS Stylus functionality (see details below).  
> Some test failures may not reflect actual bugs in the policy code, but rather limitations or bugs in the harness or toolchain.  
> Please refer to the “Important: `arbos-forge` FAILS - ‘pending/partial’ behaviour (known issue)” section below for guidance on distinguishing harness-level failures from code-level issues.

### Prerequisite: ArbOS Foundry

Requires a build from source:

1. `git clone https://github.com/iosiro/arbos-foundry`
2. `cd arbos-foundry`
3. `cargo install --path ./crates/forge --profile release --force --locked --bin arbos-forge`

### Stylus workflow (`arbos-forge`)

The Stylus tests load the policy WASM from
`src/fiet-maker-policy/target/wasm32-unknown-unknown/release/fiet_maker_policy.wasm`.

### Important: `arbos-forge` FAILS - “pending/partial” behaviour (known issue)

`arbos-forge` (via ArbOS Foundry’s `deployStylusCode` cheatcode) is very useful for quick sanity checks, but it can fail in a way that looks like a _policy bug_ when it is actually a _harness limitation_.

In particular, we have observed a “pending/partial” state where:

- the WASM file on disk is valid (passes `WasmFixtureSanity.t.sol`)
- deployment appears to succeed
- but the **first attempted execution** triggers ArbOS validation and fails

Common failure modes look like:

- **Truncated / partial module**: `Validation error: unexpected end-of-file (at offset 0x...)`
  - This typically indicates the runtime ended up validating a _shorter_ byte stream than the WASM file on disk (eg an embedded/truncated artefact).
- **Invalid code shape if you manually etch code**: `failed to parse wasm ... reference-types not enabled ...`
  - ArbOS expects the canonical Stylus program encoding. Naively doing `vm.etch(addr, 0xeff00000 || wasm_bytes)` can produce a byte layout that ArbOS treats as malformed.

Because these failures happen at validation time, they can mask the real semantic errors the unit tests are trying to exercise (install/uninstall, envelope parsing, signature checks, nonce consumption).

**Rule of thumb**: treat `arbos-forge` unit test failures with the above signatures as _harness-level_ until proven otherwise. The Nitro-based E2E suite (`just e2e_test`) is the source of truth for end-to-end Stylus behaviour.

### Refresh the WASM artefact

From `contracts/stylus/src/fiet-maker-policy/` run `cargo stylus check`.
If you see `can't find crate for core` / target-not-installed errors, install the target once: `rustup target add wasm32-unknown-unknown`

You can sanity-check the fixture contains no DataCount section (bulk-memory) with:

```bash
arbos-forge test --match-path test/WasmFixtureSanity.t.sol -vv
```

## Stylus (Nitro) E2E bootstrap

This directory contains the tooling to:

- deploy a minimal EVM “infra” on a fresh Nitro devnet for the Stylus policy to `staticcall` during validation
- deploy the Stylus intent policy
- write `e2e/.env` and run the Bun E2E harness against your local Nitro node

All orchestration is in `justfile`.

## Prerequisites

- **Nitro** devnet running with Stylus enabled (run this in a separate process/terminal)
- **Foundry** (`forge`, `cast`)
- **just**
- **jq**
- **Rust** + `cargo-stylus` (for policy deployment via `tools/deployer`)
- **Bun** (for `e2e/`)

## Bootstrap a new Nitro node (high level)

1. Start your Nitro node in a separate terminal (your local Nitro setup dictates the exact command and ports).
2. Export the required environment variables (see below).
3. From `protocol/contracts/stylus/`, run `just bootstrap`.
4. Run E2E tests with `just e2e_test`.

## Required environment variables

- **`RPC_URL`**: Nitro RPC (eg `http://127.0.0.1:8547`)
- **`CHAIN_ID`**: Nitro chain id (string). Defaults to `421614` if unset.
- **`PRIVATE_KEY`**: deployer key for Foundry scripts (expected as bytes32 hex)
- **`OWNER_PRIVATE_KEY`**: key used by the Bun E2E harness
- **`PERMISSION_ID`**: bytes32 encoding of Kernel `PermissionId` (bytes4), left-aligned and zero-padded
- **`PRIV_KEY_PATH` or `PKEY`**: deployer key for Stylus policy deploy (`cargo stylus deploy`), provide exactly one

## Permission IDs & “permission instances” (important)

This project uses a **`PERMISSION_ID`** (a `bytes32`) to identify a specific **permission instance** for a given wallet.

### What is a permission instance?

A **permission instance** is the tuple:

- **wallet**: the account address being validated/executed. Under EIP-7702 this is the **EOA address** (delegated to Kernel implementation).
- **permission id**: a `bytes32` identifier for _one specific permission configuration_

In other words: the same wallet can install/configure the same policy multiple times under different ids, and those installs are treated as separate “instances”.

### What is isolated on-chain between instances?

Inside the Stylus policy, configuration and replay-protection are **scoped by `(wallet, permissionId)`**.

Concretely, the policy derives a composite storage key:

- `key = keccak256(wallet || permissionId)`

and stores per-instance state under that key, including:

- **replay nonce**: each permission instance has its own nonce stream, so a replay in one instance does not affect another
- **authorised envelope signer**: each permission instance can require a different envelope signer
- **fact sources**: each permission instance can point at different fact source contracts (StateView / VTSOrchestrator / LiquidityHub)

The only wallet-level state is `used_ids[wallet]`, which is used to answer `isInitialized(wallet)` when _any_ permission id is installed.

### Why is `PERMISSION_ID` required by the E2E harness?

`PERMISSION_ID` is not a secret. It’s a **namespace / handle** that must be consistent across:

- **Kernel permission config**: which permission instance is installed for the account (policies + signer)
- **policy envelope signing**: the envelope includes `permissionId` in the signed EIP-712 payload to prevent cross-instance replay
- **policy storage**: the policy reads/writes config + nonces under the composite `(wallet, permissionId)` key

If the E2E harness doesn’t know the `PERMISSION_ID`, it can’t build the correct permission config nor sign envelopes that match that config.

### What should I set `PERMISSION_ID` to?

For devnets/tests, Kernel’s `PermissionId` is a **bytes4**. We encode it as a bytes32 for the Stylus policy and envelope signing by left-aligning the bytes4 and zero-padding the remaining 28 bytes (eg `0xdeadbeef` becomes `0xdeadbeef0000...00`).

Common options:

- `just` use default per wallet.

```bash
# Optional: write a default PERMISSION_ID into `contracts/stylus/.env` if you don’t want to choose one manually
# (only writes it if PERMISSION_ID is not already present in `.env`)
just env_init_permission_id
```

- **hash a label** (recommended so it’s deterministic and readable):

```bash
PID32="$(cast keccak "fiet-permission-devnet")"
export PERMISSION_ID="${PID32:0:10}$(printf '0%.0s' {1..56})"
```

- **use a fixed test constant**:

```bash
export PERMISSION_ID="0x0000000100000000000000000000000000000000000000000000000000000000"
```

## Command reference (`justfile`)

From `protocol/contracts/stylus/`:

```bash
# List all commands
just

# Help/summary
just help

# Wait for Nitro RPC to become available
just nitro_wait

# Deploy Nitro E2E infra mocks (StateView/VTSOrchestrator/LiquidityHub + CREATE3Factory + placeholders)
just infra_deploy

# Deploy Kernel contracts (devnet)
just kernel_deploy

# Deploy & activate the Stylus intent policy (writes deployments.stylus.nitro.json)
just stylus_deploy_policy

# Write e2e/.env from the deployed addresses
just e2e_write_env

# Run Bun E2E tests
just e2e_test
```

OR use `just bootstrap`

```bash
# Full bootstrap: infra + kernel + policy + e2e env
just bootstrap

# Run Bun E2E tests
just e2e_test
```

## Quick start

```bash
export RPC_URL="http://127.0.0.1:8547"
export CHAIN_ID="..."
export PRIVATE_KEY="0x..."
export OWNER_PRIVATE_KEY="0x..."
export PERMISSION_ID="0x..."

# Provide ONE of these for Stylus deploy:
export PRIV_KEY_PATH="/path/to/keyfile"
# export PKEY="0x..."

just bootstrap
just e2e_test
```

## Notes

- The infra deployed by `just infra_deploy` is intentionally minimal and purpose-built for Stylus policy validation.
- If you want to deploy the full Fiet protocol stack on Nitro (instead of mocks), that’s a separate workflow.

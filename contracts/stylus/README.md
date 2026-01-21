# WIP: (Experimental) Fiet Maker Kernel Policy

> **Warning**  
> This folder contains **experimental code** for demonstration and research purposes only.  
> Not ready for **use in production or mainnet** yet.  
> Use at your own risk.  

Arbitrum Stylus program written in Rust using the [stylus-sdk](https://github.com/OffchainLabs/stylus-sdk-rs).

This workspace hosts the on-chain **“Atomic Revalidation” intent policy** described in `PROPOSAL.md`, exposed as a **Kernel-compatible** ERC-7579 `IPolicy` module (**module type 5**) intended to be used in the **Kernel permissions** pipeline (for example, alongside a PermissionValidator signer).

The core contract crate is `fiet-maker-policy/`. The policy is designed to **fail closed**: if envelope parsing, signature checks, replay protection, program decoding, or on-chain fact acquisition fails, the policy returns a failure code and the UserOperation should not proceed.

- **On-chain policy entrypoint**: `fiet-maker-policy/src/intent_policy.rs`
- **Envelope hashing/signing**: `fiet-maker-policy/src/utils/policy_envelope.rs`
- **Off-chain encoder / shared types**: `off-chain/fiet-maker-policy-encoder/`
- **E2E harness (Bun)**: `e2e/`

## Unit Testing

### Prerequisite: ArbOS Foundry

Requires a build from source:

1. `git clone https://github.com/iosiro/arbos-foundry`
2. `cd arbos-foundry`
3. `cargo install --path ./crates/forge --profile release --force --locked --bin arbos-forge`

### Stylus fixture workflow (arbos-forge)

The Stylus tests load the policy WASM from `fixtures/fiet_maker_policy.wasm`.

To refresh the fixture:

1. From `contracts/fiet-maker-policy/` run `cargo stylus check`.
2. Copy `target/wasm32-unknown-unknown/release/fiet_maker_policy.wasm` to
   `contracts/stylus/fixtures/fiet_maker_policy.wasm`.

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
- **`PERMISSION_ID`**: bytes32 permission id used by the PermissionValidator config
- **`PRIV_KEY_PATH` or `PKEY`**: deployer key for Stylus policy deploy (`cargo stylus deploy`), provide exactly one

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

# Oracle admin (`contracts/evm-scripts/script/admin`)

This folder contains scripts for administering the Venus oracle stack under `contracts/evm/lib/oracle/`.

## Goals

- Configure **per-asset Chainlink feeds** (e.g. USDC uses a different feed to COMP).
- Configure **ResilientOracle** per asset (MAIN/PIVOT/FALLBACK + enable flags + caching).
- Configure **BoundValidator** per asset (upper/lower deviation ratios) when pivot/fallback validation is enabled.
- Route all admin calls via **`GlobalConfig.proxyCall`** so `msg.sender == GlobalConfig`.

## Deployment artefacts written by `just deploy-oracle`

When you run `just deploy-oracle`, it will:

- Write `.env` entries:
  - `RESILIENT_ORACLE_ADDRESS`
  - `ACCESS_CONTROL_MANAGER` (also resolvable from `RESILIENT_ORACLE_ADDRESS`)
- Copy the Hardhat deployment JSON files into:
  - `deployments/oracle_deployments/<oracle-network>/`
- Write a single address book:
  - `deployments/oracle_deployments/<oracle-network>/addresses.json`
- Write the oracle ProxyAdmin address as a simple text file:
  - `deployments/oracle_deployments/<oracle-network>/DefaultProxyAdmin.address`

## Fresh deployment checklist

Use this order when configuring a newly deployed oracle stack for the first time.

### 1) Deploy the oracle stack

Run `just deploy-oracle` first.

This writes the addresses you need for the later admin steps, including:

- `RESILIENT_ORACLE_ADDRESS`
- `ACCESS_CONTROL_MANAGER`
- `deployments/oracle_deployments/<oracle-network>/addresses.json`

### 2) Confirm who owns `GlobalConfig`

Most admin scripts in this folder call targets through `GlobalConfig.proxyCall(...)`.

That means the transaction broadcaster must be the current `GlobalConfig` owner.

If your signer is not the `GlobalConfig` owner, the proxied admin scripts in this file will not work.

### 3) Transfer the oracle ownership surfaces to `GlobalConfig`

For a fresh deployment, make `GlobalConfig` the intended admin surface before attempting per-asset configuration.

Run one of:

- `just admin-oracle-transfer-to-globalconfig`
- `just admin-oracle-transfer-stack-to-globalconfig`

Typical inputs are:

- `RESILIENT_ORACLE_ADDRESS`
- `BOUND_VALIDATOR_ADDRESS`
- `MAIN_ORACLE_ADDRESS`
- `DEFAULT_PROXY_ADMIN_ADDRESS`

What this step is meant to achieve:

- `ResilientOracle.owner() == GlobalConfig`
- `BoundValidator.owner() == GlobalConfig` (if provided)
- `MainOracle.owner() == GlobalConfig` (if provided)
- `DefaultProxyAdmin.owner() == GlobalConfig` (if provided)

### 4) Ensure `GlobalConfig` has ACM `DEFAULT_ADMIN_ROLE`

This is the step that allows `GlobalConfig` to grant the finer-grained oracle permissions required later.

You can do this in either of two ways:

1. let `just admin-oracle-transfer-to-globalconfig` grant ACM admin during the handoff; or
2. run `just admin-acm-transfer-admin-to-globalconfig` separately.

Important:

- the signer for this step must already be an ACM admin; and
- `GlobalConfig` must end this step with `DEFAULT_ADMIN_ROLE`.

Without this, `just admin-oracle-acm-give-call-permission` will revert because ACM sees `msg.sender == GlobalConfig` and `GlobalConfig` is not allowed to grant roles.

### 5) Grant the required ACM call permissions to `GlobalConfig`

Once `GlobalConfig` is an ACM admin, grant the actual permissions used by the per-asset configuration flow.

At minimum, grant these permissions with `ACCOUNT_TO_PERMIT="$GLOBALCONFIG_ADDRESS"`:

- on `MainOracle`: `setTokenConfig(TokenConfig)`
- on `ResilientOracle`: `setTokenConfig(TokenConfig)`
- on `BoundValidator`: `setValidateConfig(ValidateConfig)` when pivot or fallback validation is enabled

For compatibility with some deployments, you may also need the tuple-style signature on `MainOracle`:

- `setTokenConfig((address,address,uint256))`

Recommended command sequence:

```bash
# 1) MainOracle feed config
ACCOUNT_TO_PERMIT="$GLOBALCONFIG_ADDRESS" \
RESILIENT_ORACLE_ADDRESS="$RESILIENT_ORACLE_ADDRESS" \
TARGET_ADDRESS="$MAIN_ORACLE_ADDRESS" \
FUNCTION_SIG="setTokenConfig(TokenConfig)" \
just admin-oracle-acm-give-call-permission

ACCOUNT_TO_PERMIT="$GLOBALCONFIG_ADDRESS" \
RESILIENT_ORACLE_ADDRESS="$RESILIENT_ORACLE_ADDRESS" \
TARGET_ADDRESS="$MAIN_ORACLE_ADDRESS" \
FUNCTION_SIG="setTokenConfig((address,address,uint256))" \
just admin-oracle-acm-give-call-permission

# 2) BoundValidator bounds config
ACCOUNT_TO_PERMIT="$GLOBALCONFIG_ADDRESS" \
RESILIENT_ORACLE_ADDRESS="$RESILIENT_ORACLE_ADDRESS" \
TARGET_ADDRESS="$BOUND_VALIDATOR_ADDRESS" \
FUNCTION_SIG="setValidateConfig(ValidateConfig)" \
just admin-oracle-acm-give-call-permission

# 3) ResilientOracle token config
ACCOUNT_TO_PERMIT="$GLOBALCONFIG_ADDRESS" \
RESILIENT_ORACLE_ADDRESS="$RESILIENT_ORACLE_ADDRESS" \
TARGET_ADDRESS="$RESILIENT_ORACLE_ADDRESS" \
FUNCTION_SIG="setTokenConfig(TokenConfig)" \
just admin-oracle-acm-give-call-permission
```

### 6) Prepare the per-asset config file

Create or update your network config under `contracts/evm-scripts/config/oracle/`.

For example:

- `config/oracle/arbitrumone.json`

Make sure it contains:

- the deployed contract addresses (`resilientOracle`, `mainOracle`, `boundValidator`)
- each asset's feed and stale period
- optional pivot and fallback oracle settings
- bounds whenever pivot or fallback validation is enabled

### 7) Run the asset configuration script

Once ownership and ACM permissions are in place, run:

- `just admin-oracle-configure-assets`

This applies, per asset:

1. `MainOracle.setTokenConfig(...)`
2. `BoundValidator.setValidateConfig(...)` when needed
3. `ResilientOracle.setTokenConfig(...)`

All of these calls are routed through `GlobalConfig.proxyCall(...)`.

### 8) Verify the final state

After configuration:

- confirm the relevant oracle contracts are owned by `GlobalConfig`
- confirm `GlobalConfig` still has the required ACM permissions
- confirm price reads succeed for the configured assets
- confirm assets using pivot or fallback have valid bounds configured

### Common failure mode

If `just admin-oracle-acm-give-call-permission` reverts with:

- `AccessControl: account ... is missing role 0x00`

then `GlobalConfig` does not yet hold ACM `DEFAULT_ADMIN_ROLE`, or the signer you used was not able to grant it.

Fix that first, then rerun the granular permission grants above.

## Preconditions (one-time)

### 1) Ensure GlobalConfig is the intended admin surface

Most scripts in `script/admin/` route through `GlobalConfig.proxyCall`, so your broadcaster key must be the **GlobalConfig owner**.

### 2) Ensure ACM permissions exist for GlobalConfig

Venus oracles enforce access via ACM (`_checkAccessAllowed("<sig>")`). When routing admin calls through `GlobalConfig.proxyCall`,
the oracle contracts will see `msg.sender == GlobalConfig`, so **GlobalConfig must be permitted**.

At minimum, GlobalConfig needs call permission for:

- On `MainOracle` (Venus `ChainlinkOracle`): `setTokenConfig(TokenConfig)`
- On `ResilientOracle`: `setTokenConfig(TokenConfig)`
- On `BoundValidator`: `setValidateConfig(ValidateConfig)` (required whenever pivot/fallback is enabled, because ResilientOracle validates)

This repo provides `ResilientOracleACMPermissions.s.sol` (`just admin-oracle-acm-give-call-permission`) to grant a single permission per run.

Recommended approach:

1. Set `ACCOUNT_TO_PERMIT` to your `GlobalConfig` address.
2. Run the permission script for each target contract + signature you need.
   - `RESILIENT_ORACLE_ADDRESS` is used only to resolve the ACM.
   - `TARGET_ADDRESS` is the contract you are granting permissions to.

Example (copy/paste):

```bash
# 1) Allow GlobalConfig to configure MAIN oracle feeds (ChainlinkOracle)
ACCOUNT_TO_PERMIT="$GLOBALCONFIG_ADDRESS" \
RESILIENT_ORACLE_ADDRESS="$RESILIENT_ORACLE_ADDRESS" \
TARGET_ADDRESS="$MAIN_ORACLE_ADDRESS" \
FUNCTION_SIG="setTokenConfig(TokenConfig)" \
just admin-oracle-acm-give-call-permission

ACCOUNT_TO_PERMIT="$GLOBALCONFIG_ADDRESS" \
RESILIENT_ORACLE_ADDRESS="$RESILIENT_ORACLE_ADDRESS" \
TARGET_ADDRESS="$MAIN_ORACLE_ADDRESS" \
FUNCTION_SIG="setTokenConfig((address,address,uint256))" \
just admin-oracle-acm-give-call-permission

# 2) Allow GlobalConfig to configure bounds
ACCOUNT_TO_PERMIT="$GLOBALCONFIG_ADDRESS" \
RESILIENT_ORACLE_ADDRESS="$RESILIENT_ORACLE_ADDRESS" \
TARGET_ADDRESS="$BOUND_VALIDATOR_ADDRESS" \
FUNCTION_SIG="setValidateConfig(ValidateConfig)" \
just admin-oracle-acm-give-call-permission

# 3) Allow GlobalConfig to configure ResilientOracle token configs
ACCOUNT_TO_PERMIT="$GLOBALCONFIG_ADDRESS" \
RESILIENT_ORACLE_ADDRESS="$RESILIENT_ORACLE_ADDRESS" \
TARGET_ADDRESS="$RESILIENT_ORACLE_ADDRESS" \
FUNCTION_SIG="setTokenConfig(TokenConfig)" \
just admin-oracle-acm-give-call-permission
```

## Per-asset configuration (feeds + bounds + ResilientOracle)

### 1) Create a config file under `config/oracle/`

Create a JSON config file under:

- `contracts/evm-scripts/config/oracle/`

An example is provided at:

- `config/oracle/example.json`

### 2) Run the config script

Run:

- `just admin-oracle-configure-assets`

Env:

- `ORACLE_CONFIG_FILE` (optional): filename under `config/oracle/` (default: `example.json`)

What it does per asset:

1. `ChainlinkOracle.setTokenConfig({asset, feed, maxStalePeriod})`
2. If pivot/fallback is enabled: `BoundValidator.setValidateConfig({asset, upperBoundRatio, lowerBoundRatio})`
3. `ResilientOracle.setTokenConfig({asset, oracles[main,pivot,fallback], enableFlags, cachingEnabled})`

All calls are routed via `GlobalConfig.proxyCall`.

## `BoundValidator`

If either PIVOT or FALLBACK is enabled for an asset, `ResilientOracle` may call `BoundValidator.validatePriceWithAnchorPrice(...)`.
If `BoundValidator` has no config for that asset, price reads can revert with `"validation config not exist"`.

So, when enabling pivot/fallback, always provide a `bounds` object in the config.

### How `BoundValidator` affects MAIN/PIVOT/FALLBACK selection

`BoundValidator` does **not** “trigger” the pivot or fallback oracle to be called. It only answers:
**“is price A close enough to price B for this asset?”**

Conceptually, it validates a ratio band per asset:

- It computes \(anchorRatio = \frac{anchorPrice \cdot 1e18}{reportedPrice}\)
- It returns `true` if `lowerBoundRatio <= anchorRatio <= upperBoundRatio`

`ResilientOracle` uses that boolean result to decide which price to return, in this order:

1. **Pivot price is fetched first** (if enabled), then:
2. **MAIN vs PIVOT**:
   a. If MAIN validates against PIVOT, ResilientOracle returns **MAIN**.
3. **FALLBACK vs PIVOT**:
   a. If MAIN failed validation, and FALLBACK validates against PIVOT, ResilientOracle returns **FALLBACK**.
4. **MAIN vs FALLBACK** (last resort):
   a. If neither validated against PIVOT, but both MAIN and FALLBACK exist, ResilientOracle validates MAIN vs FALLBACK.
   b. If valid, it returns **MAIN**.
5. Otherwise, it reverts with `"invalid resilient oracle price"`.

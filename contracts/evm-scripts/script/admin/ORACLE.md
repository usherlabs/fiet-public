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

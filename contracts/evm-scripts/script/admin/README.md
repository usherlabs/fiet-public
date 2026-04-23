# Admin scripts (`contracts/evm-scripts/script/admin`)

This folder contains **Foundry scripts** for exercising **admin / owner-only** protocol operations.

Most protocol contracts are owned by `GlobalConfig`, so these scripts commonly route calls through:

- `GlobalConfig.proxyCall(target, calldata)`

That means **the transaction signer must be the `GlobalConfig` owner** for most commands.

## Common environment

- **Required (almost all scripts)**:
  - `PRIVATE_KEY`: the EOA private key (as `bytes32`) used to broadcast
  - `NETWORK`: selects the deployments file used by `AdminBase` (loads `globalConfig`, `marketFactory`, etc.)

- **Loaded automatically by `AdminBase`**:
  - `globalConfig` (used for `proxyCall`)
  - `marketFactory`
  - and derived from getters: `vtsOrchestrator`, `oracleHelper`, `liquidityHub`, `signalManager`, `settlementObserver`

## CSI micro-share rounding rollout note

For the CSI micro-share self-exclusion fix (conservative rounding during `feesShared` sync):

- this is a runtime maths patch in `VTSFeeLib` only;
- no storage layout change is required;
- no dedicated migration script is required for already-migrated CSI lanes.

Recommended verification after deployment:

1. run the CSI library and index test suites covering micro-share partial-spend cases;
2. sanity-check that a self-only or micro-split contributor cannot queue bonus from still-self-attributable residual pot;
3. verify ordinary CSI epoch rollover semantics are unchanged.

## Commands

### `just admin-proxy-call`

- **What it does**: generic wrapper to call anything via `GlobalConfig.proxyCall`.
- **On-chain call**: `GlobalConfig.proxyCall(TARGET, CALLDATA)`
- **Script**: `AdminProxyCall.s.sol:AdminProxyCallScript`
- **Env**:
  - `TARGET`: address
  - `CALLDATA`: ABI-encoded calldata bytes (`0x...`)

### `just admin-marketfactory-add-bounds`

- **What it does**: allow-list bounds in `MarketFactory`.
- **On-chain call**: `MarketFactory.addBounds(bounds[])` (via `GlobalConfig.proxyCall`)
- **Script**: `MarketFactoryBounds.s.sol:MarketFactoryAddBoundsScript`
- **Env (choose one)**:
  - `BOUNDS_FILE`: path to JSON file containing `{ "bounds": ["0x..", ...] }`
  - `BOUNDS_JSON`: the JSON string itself (same shape)

### `just admin-marketfactory-remove-bounds`

- **What it does**: remove bounds from `MarketFactory`.
- **On-chain call**: `MarketFactory.removeBounds(bounds[])` (via `GlobalConfig.proxyCall`)
- **Script**: `MarketFactoryBounds.s.sol:MarketFactoryRemoveBoundsScript`
- **Env (choose one)**:
  - `BOUNDS_FILE`: path to JSON file containing `{ "bounds": ["0x..", ...] }`
  - `BOUNDS_JSON`: the JSON string itself (same shape)

### `just admin-liquidityhub-set-factory`

- **What it does**: enables/disables a factory inside `LiquidityHub`.
- **On-chain call**: `LiquidityHub.setFactory(factory, enabled)` (via `GlobalConfig.proxyCall`)
- **Script**: `LiquidityHubSetFactory.s.sol:LiquidityHubSetFactoryScript`
- **Env**:
  - `FACTORY`: address
  - `ENABLED`: `0|1`

### `just admin-oraclehelper-register-ticker`

- **What it does**: registers or updates a ticker mapping in `OracleHelper`.
- **On-chain call**: `OracleHelper.registerTicker(ticker, asset)` (via `GlobalConfig.proxyCall`)
- **Script**: `OracleHelperRegisterTicker.s.sol:OracleHelperRegisterTickerScript`
- **Env**:
  - `TICKER`: string (e.g. `BTC`)
  - `ASSET`: address

### `just admin-vts-set-global-pause`

- **What it does**: sets the global pause flag for VTS.
- **On-chain call**: `VTSOrchestrator.setGlobalPause(paused)`
  - if `VTSOrchestrator.owner() == GlobalConfig`, this is routed via `GlobalConfig.proxyCall`
- **Script**: `VTSOrchestratorAdmin.s.sol:VTSSetGlobalPauseScript`
- **Env**:
  - `PAUSED`: `0|1`

### `just admin-vts-set-market-config`

- **What it does**: sets the VTS config for a given core pool id (defaults, or optional file override).
- **On-chain call**: `VTSOrchestrator.setMarketVTSConfiguration(corePoolId, defaultCfg)`
  - if `VTSOrchestrator.owner() == GlobalConfig`, this is routed via `GlobalConfig.proxyCall`
- **Script**: `VTSOrchestratorAdmin.s.sol:VTSSetMarketConfigScript`
- **Env**:
  - `CORE_POOL_ID`: `bytes32`
  - `VTS_CONFIG_FILE_PATH` (optional): path to a JSON or TOML file to override the default config
    - JSON keys: `.token0.gracePeriodTime` etc.
    - TOML keys: `token0.gracePeriodTime` etc.
    - You can set this in your `.env` file for repeatable runs.

### `just admin-vrl-signal-set-verifier`

- **What it does**: updates the verifier used by `VRLSignalManager`.
- **On-chain call**: `VRLSignalManager.setVerifier(newVerifier)`
  - if `VRLSignalManager.owner() == GlobalConfig`, this is routed via `GlobalConfig.proxyCall`
- **Script**: `VRLSignalManagerAdmin.s.sol:VRLSignalManagerSetVerifierScript`
- **Env**:
  - `NEW_VERIFIER`: address

### `just admin-vrl-settlement-add-verifier`

- **What it does**: adds a verifier in `VRLSettlementObserver` and logs its index.
- **On-chain call**: `VRLSettlementObserver.addVerifier(verifier)` (via `GlobalConfig.proxyCall`)
- **Script**: `VRLSettlementObserverAdmin.s.sol:VRLSettlementAddVerifierScript`
- **Env**:
  - `VERIFIER`: address

### `just admin-vrl-settlement-nullify-verifier`

- **What it does**: nullifies a verifier by index.
- **On-chain call**: `VRLSettlementObserver.nullifyVerifier(index)` (via `GlobalConfig.proxyCall`)
- **Script**: `VRLSettlementObserverAdmin.s.sol:VRLSettlementNullifyVerifierScript`
- **Env**:
  - `VERIFIER_INDEX`: `uint256`

### `just admin-vrl-settlement-allow-verifier-for-tokens`

- **What it does**: allow-lists a verifier for a set of token addresses.
- **On-chain call**: `VRLSettlementObserver.allowVerifierForTokens(index, tokens[])` (via `GlobalConfig.proxyCall`)
- **Script**: `VRLSettlementObserverAdmin.s.sol:VRLSettlementAllowVerifierForTokensScript`
- **Env**:
  - `VERIFIER_INDEX`: `uint256`
  - tokens input (choose one):
    - `TOKENS_FILE`: path to JSON file `{ "tokens": ["0x..", ...] }`
    - `TOKENS_JSON`: the JSON string itself (same shape)

### `just admin-vrl-settlement-disallow-verifier-for-tokens`

- **What it does**: removes verifier allow-list entries for a set of token addresses.
- **On-chain call**: `VRLSettlementObserver.disallowVerifierForTokens(index, tokens[])` (via `GlobalConfig.proxyCall`)
- **Script**: `VRLSettlementObserverAdmin.s.sol:VRLSettlementDisallowVerifierForTokensScript`
- **Env**:
  - `VERIFIER_INDEX`: `uint256`
  - tokens input (choose one):
    - `TOKENS_FILE`: path to JSON file `{ "tokens": ["0x..", ...] }`
    - `TOKENS_JSON`: the JSON string itself (same shape)

### `just admin-oracle-transfer-to-globalconfig`

- **What it does**: hands over Venus oracle ownership/admin surfaces to `GlobalConfig`:
  - `ResilientOracle` ownership (with `acceptOwnership()` via `GlobalConfig.proxyCall`)
  - optional ACM `DEFAULT_ADMIN_ROLE` migration to `GlobalConfig`
  - optional ownership handoff for `BoundValidator`, main oracle proxy, and the oracle `DefaultProxyAdmin` contract
- **On-chain calls**:
  - `AccessControlManager.grantRole(DEFAULT_ADMIN_ROLE, GlobalConfig)` (direct)
  - `AccessControlManager.revokeRole(DEFAULT_ADMIN_ROLE, OLD_ADMIN)` (direct)
  - `ResilientOracle.transferOwnership(GlobalConfig)` (direct)
  - `GlobalConfig.proxyCall(ResilientOracle, acceptOwnership())`
  - `require(ResilientOracle.owner() == GlobalConfig)`
- **Script**: `OracleStackOwnership.s.sol:OracleStackTransferToGlobalConfigScript`
- **Address resolution** (same script for both `admin-oracle-transfer-*` recipes):
  - `NETWORK` selects `deployments/<NETWORK>_deployments.json` (for `GlobalConfig`, `MarketFactory`, etc.).
  - Oracle proxy addresses default from `deployments/oracle_deployments/<oracle-namespace>/addresses.json`, where `<oracle-namespace>` is `ORACLE_DEPLOYMENT_NETWORK` if set, otherwise mapped from `NETWORK` + `MODE` (for example `NETWORK=arbitrum` + `MODE!=LOCAL` → `arbitrumone`, matching `just deploy-oracle`).
  - Any of the following env vars **override** the address book for that field only: `RESILIENT_ORACLE_ADDRESS`, `BOUND_VALIDATOR_ADDRESS`, `MAIN_ORACLE_ADDRESS`, `ORACLE_PROXY_ADMIN_ADDRESS`.
  - To **skip** a handoff for a given contract, set that env var to the zero address (`0x0000…0000`); omitting the var means “read from the address book”.
- **Env**:
  - `ORACLE_DEPLOYMENT_NETWORK` (optional): folder name under `deployments/oracle_deployments/` when it differs from the automatic mapping.
  - `RESILIENT_ORACLE_ADDRESS` (optional): overrides `ResilientOracle_Proxy` from the address book.
  - `BOUND_VALIDATOR_ADDRESS` (optional): overrides `BoundValidator_Proxy` from the address book.
  - `MAIN_ORACLE_ADDRESS` (optional): overrides `ChainlinkOracle_Proxy` / `SequencerChainlinkOracle_Proxy` from the address book.
  - `ORACLE_PROXY_ADMIN_ADDRESS` (optional): **the oracle `DefaultProxyAdmin` contract address** (from the address book key `DefaultProxyAdmin`). This is a **transfer target**, not the new owner. The intended owner after handoff is always `GlobalConfig`. Do not set this to the `GlobalConfig` address (the script rejects that).
  - `DEFAULT_PROXY_ADMIN_ADDRESS` (optional, legacy): accepted only if `ORACLE_PROXY_ADMIN_ADDRESS` is unset; same semantics as `ORACLE_PROXY_ADMIN_ADDRESS`.

### `just admin-oracle-transfer-stack-to-globalconfig`

- **What it does**: transfers the rest of the Venus oracle ownership surface to `GlobalConfig`:
  - `BoundValidator`
  - main oracle proxy (`ChainlinkOracle` / `SequencerChainlinkOracle`)
  - oracle `DefaultProxyAdmin` (upgrade admin for oracle proxies; `GlobalConfig` becomes its owner)
- **On-chain calls**:
  - `target.transferOwnership(GlobalConfig)` (direct, when signer is current owner)
  - `GlobalConfig.proxyCall(target, acceptOwnership())` (for `Ownable2Step` targets)
  - `require(target.owner() == GlobalConfig)`
- **Script**: `OracleStackOwnership.s.sol:OracleStackTransferToGlobalConfigScript`
- **Env**: same address-resolution rules as `just admin-oracle-transfer-to-globalconfig`; for stack-only runs you will typically rely on the address book or set overrides as needed.

### `just admin-oracle-acm-give-call-permission`

- **What it does**: grants a ResilientOracle call permission through the Venus ACM, and asserts it stuck.
- **On-chain call**:
  - `GlobalConfig.proxyCall(AccessControlManager, giveCallPermission(oracle, FUNCTION_SIG, ACCOUNT_TO_PERMIT))`
  - then checks `AccessControlManager.hasPermission(ACCOUNT_TO_PERMIT, oracle, FUNCTION_SIG) == true`
- **Script**: `ResilientOracleACMPermissions.s.sol:ResilientOracleACMGiveCallPermissionScript`
- **Env**:
  - `RESILIENT_ORACLE_ADDRESS` (optional): used to resolve the ACM; if unset, reads `ResilientOracle_Proxy` from the oracle address book (`ORACLE_DEPLOYMENT_NETWORK` or the same `NETWORK`+`MODE` mapping as `just deploy-oracle`).
  - `TARGET_ADDRESS`: address to permit (e.g. MainOracle, BoundValidator, ResilientOracle)
  - `FUNCTION_SIG`: string (e.g. `pause()`, `setOracle(address,address,uint8)`)
  - `ACCOUNT_TO_PERMIT`: address

### `just admin-acm-transfer-admin-to-globalconfig`

- **What it does**: grants `DEFAULT_ADMIN_ROLE` on ACM to `GlobalConfig`, optionally revoking it from `OLD_ADMIN`.
- **On-chain calls**:
  - `AccessControlManager.grantRole(DEFAULT_ADMIN_ROLE, GlobalConfig)`
  - (optional) `AccessControlManager.revokeRole(DEFAULT_ADMIN_ROLE, OLD_ADMIN)`
- **Script**: `AccessControlManagerAdmin.s.sol:AccessControlManagerTransferAdminToGlobalConfigScript`
- **Env**:
  - `ACCESS_CONTROL_MANAGER`: (optional) address
    - If you ran `just deploy-oracle`, this is auto-populated into `.env` for you.
    - If omitted, you may provide `RESILIENT_ORACLE_ADDRESS` and the ACM will be resolved from it.
  - `RESILIENT_ORACLE_ADDRESS` (optional): used only to resolve the ACM. If neither this nor `ACCESS_CONTROL_MANAGER` is set, the script reads `ResilientOracle_Proxy` from the oracle address book (same namespace rules as above).
  - `OLD_ADMIN` (optional): address

### `just admin-oracle-configure-assets`

- **What it does**: configures per-asset oracle feeds (ChainlinkOracle), per-asset bounds (BoundValidator), and per-asset ResilientOracle token configs, all routed via `GlobalConfig.proxyCall`.
- **Script**: `OracleConfigureAssets.s.sol:OracleConfigureAssetsScript`
- **Env**:
  - `ORACLE_CONFIG_FILE` (optional): filename under `config/oracle/` (default: `example.json`)
- **Docs**: see `script/admin/ORACLE.md` for the end-to-end flow (including required ACM permissions).

### `just admin-oracle-validate-config`

- **What it does**: validates an oracle config file against the oracle deployment artefacts and the live chain state.
- **Checks**:
  - config contract addresses vs `deployments/oracle_deployments/<oracle-network>/addresses.json`
  - `ResilientOracle`, `MainOracle`, `BoundValidator`, and `DefaultProxyAdmin` ownership against `GlobalConfig`
  - shared ACM wiring and required `GlobalConfig` permissions
  - per-asset `MainOracle`, `BoundValidator`, and `ResilientOracle` config values
- **Script**: `OracleValidateConfig.s.sol:OracleValidateConfigScript`
- **Env**:
  - `ORACLE_CONFIG_FILE` (optional): filename under `config/oracle/` (default: `example.json`)
  - `ORACLE_DEPLOYMENT_NETWORK` (optional): oracle deployment directory name under `deployments/oracle_deployments/`

## Oracle admin model (Venus `lib/oracle`)

The Venus oracle stack under `contracts/evm/lib/oracle/` has **two separate admin surfaces**:

- **Ownership** (typically `Ownable2Step`): who can transfer/accept ownership, etc.
- **AccessControlManager (ACM) permissions**: many `ResilientOracle` admin functions are gated by ACM checks (ownership alone does not automatically grant ACM permissions).

If your goal is **GlobalConfig as the single admin** for _all_ administrative operations in `lib/oracle`, you generally need **both**:

- **`OracleStackOwnership.s.sol`** (`just admin-oracle-transfer-to-globalconfig` / `just admin-oracle-transfer-stack-to-globalconfig`): makes `GlobalConfig` the `ResilientOracle` owner (and, optionally, transfers ACM admin and other oracle-stack ownership surfaces). Oracle contract addresses default from `deployments/oracle_deployments/<namespace>/addresses.json`; `GlobalConfig` itself must never be passed as a handoff target (including as `ORACLE_PROXY_ADMIN_ADDRESS`).
- **`ResilientOracleACMPermissions.s.sol`** (`just admin-oracle-acm-give-call-permission`): grants ACM call permissions for whichever `ResilientOracle` function signatures you intend to run via `GlobalConfig` (and you should ensure no other accounts retain those permissions).

`AccessControlManagerAdmin.s.sol` (`just admin-acm-transfer-admin-to-globalconfig`) is **not sufficient on its own**: it only transfers the ACM `DEFAULT_ADMIN_ROLE` to `GlobalConfig`. You still need the ownership handover (and, depending on which oracle admin functions you want to exercise, the ACM call permissions as well).

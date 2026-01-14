# Admin scripts (`contracts/evm-scripts/script/admin`)

This folder contains **Foundry scripts** for exercising **admin / owner-only** protocol operations.

Most protocol contracts are owned by `GlobalConfig`, so these scripts commonly route calls through:

- `GlobalConfig.proxyCall(target, calldata)`

That means **the transaction signer must be the `GlobalConfig` owner** for most commands.

## Common environment

- **Required (almost all scripts)**:
  - `PRIVATE_KEY`: the EOA private key (as `bytes32`) used to broadcast
  - `NETWORK`: selects the deployments file used by `AdminBase` (loads `globalConfig`, `marketFactory`, etc)

- **Loaded automatically by `AdminBase`**:
  - `globalConfig` (used for `proxyCall`)
  - `marketFactory`
  - and derived from getters: `vtsOrchestrator`, `oracleHelper`, `liquidityHub`, `signalManager`, `settlementObserver`

## Commands

### `just admin-proxy-call`

- **What it does**: generic wrapper to call anything via `GlobalConfig.proxyCall`.
- **On-chain call**: `GlobalConfig.proxyCall(TARGET, CALLDATA)`
- **Script**: `AdminProxyCall.s.sol:AdminProxyCallScript`
- **Env**:
  - `TARGET`: address
  - `CALLDATA`: ABI-encoded calldata bytes (`0x...`)

### `just admin-marketfactory-set-hooks`

- **What it does**: sets the core hook used by `MarketFactory`.
- **On-chain call**: `MarketFactory.setHooks(coreHook)`
  - routed via `GlobalConfig.proxyCall(MarketFactory, abi.encodeCall(setHooks,...))`
- **Script**: `MarketFactorySetHooks.s.sol:MarketFactorySetHooksScript`
- **Env**:
  - `CORE_HOOK` (optional): core hook address (defaults to deployments key `coreHook`)

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

### `just admin-vts-set-market-config-default`

- **What it does**: sets the default VTS config for a given core pool id.
- **On-chain call**: `VTSOrchestrator.setMarketVTSConfiguration(corePoolId, defaultCfg)`
  - if `VTSOrchestrator.owner() == GlobalConfig`, this is routed via `GlobalConfig.proxyCall`
- **Script**: `VTSOrchestratorAdmin.s.sol:VTSSetMarketConfigDefaultScript`
- **Env**:
  - `CORE_POOL_ID`: `bytes32`

### `just admin-vrl-signal-set-verifier`

- **What it does**: updates the verifier used by `VRLSignalManager`.
- **On-chain call**: `VRLSignalManager.setVerifier(newVerifier)`
  - if `VRLSignalManager.owner() == GlobalConfig`, this is routed via `GlobalConfig.proxyCall`
- **Script**: `VRLSignalManagerAdmin.s.sol:VRLSignalManagerSetVerifierScript`
- **Env**:
  - `NEW_VERIFIER`: address

### `just admin-vrl-signal-set-expiry`

- **What it does**: sets the `LiquiditySignal` expiry window.
- **On-chain call**: `VRLSignalManager.setSignalExpiryInSeconds(seconds)`
  - if `VRLSignalManager.owner() == GlobalConfig`, this is routed via `GlobalConfig.proxyCall`
- **Script**: `VRLSignalManagerAdmin.s.sol:VRLSignalManagerSetExpiryScript`
- **Env**:
  - `SIGNAL_EXPIRY_SECONDS`: `uint256`

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

- **What it does**: hands over Venus `ResilientOracle` ownership to `GlobalConfig` and asserts it succeeded.
- **On-chain calls**:
  - `AccessControlManager.grantRole(DEFAULT_ADMIN_ROLE, GlobalConfig)` (direct)
  - `AccessControlManager.revokeRole(DEFAULT_ADMIN_ROLE, OLD_ADMIN)` (direct)
  - `ResilientOracle.transferOwnership(GlobalConfig)` (direct)
  - `GlobalConfig.proxyCall(ResilientOracle, acceptOwnership())`
  - `require(ResilientOracle.owner() == GlobalConfig)`
- **Script**: `ResilientOracleOwnership.s.sol:ResilientOracleTransferToGlobalConfigScript`
- **Env**:
  - `RESILIENT_ORACLE_ADDRESS`: address

### `just admin-oracle-acm-give-call-permission`

- **What it does**: grants a ResilientOracle call permission through the Venus ACM, and asserts it stuck.
- **On-chain call**:
  - `GlobalConfig.proxyCall(AccessControlManager, giveCallPermission(oracle, FUNCTION_SIG, ACCOUNT_TO_PERMIT))`
  - then checks `AccessControlManager.hasPermission(ACCOUNT_TO_PERMIT, oracle, FUNCTION_SIG) == true`
- **Script**: `ResilientOracleACMPermissions.s.sol:ResilientOracleACMGiveCallPermissionScript`
- **Env**:
  - `RESILIENT_ORACLE_ADDRESS`: address
  - `FUNCTION_SIG`: string (e.g. `pause()`, `setOracle(address,address,uint8)`)
  - `ACCOUNT_TO_PERMIT`: address

### `just admin-acm-transfer-admin-to-globalconfig`

- **What it does**: grants `DEFAULT_ADMIN_ROLE` on ACM to `GlobalConfig`, optionally revoking it from `OLD_ADMIN`.
- **On-chain calls**:
  - `AccessControlManager.grantRole(DEFAULT_ADMIN_ROLE, GlobalConfig)`
  - (optional) `AccessControlManager.revokeRole(DEFAULT_ADMIN_ROLE, OLD_ADMIN)`
- **Script**: `AccessControlManagerAdmin.s.sol:AccessControlManagerTransferAdminToGlobalConfigScript`
- **Env**:
  - `ACCESS_CONTROL_MANAGER`: address
  - `OLD_ADMIN` (optional): address


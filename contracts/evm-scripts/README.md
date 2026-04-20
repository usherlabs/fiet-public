# Deployment Scripts

This directory contains deployment scripts for the Fiet Protocol contracts.

## Prerequisites

1. Set your private key as an environment variable:

```bash
export PRIVATE_KEY=your_private_key_here
```

1. Ensure you have sufficient funds in your wallet for deployment

2. To run a local fork, start an Anvil fork:
   - From `contracts/evm-scripts/`: `NETWORK=sepolia just fork` (requires the `just` CLI), or
   - run `anvil --fork-url <RPC_URL> --port 8545` directly

3. Ensure the main EVM project dependencies (including the oracle submodule) are installed
   - From `contracts/evm/`, run `forge install` to initialise/update submodules
   - Then run `yarn install` from `contracts/evm/` (this installs Node deps including `lib/oracle`)

4. For a fresh deployment, make sure `RESILIENT_ORACLE_ADDRESS` is not present so that a fresh copy can be deployed

## E2E Scripts/Tests Overview

End-to-end (E2E) tests are comprehensive integration tests that validate the full protocol flow. All E2E test scripts are located in the `script/e2e/` folder.

The following E2E test scripts are available:

1. **`e2e/Deploy.s.sol`** - Deploys the full protocol stack and logs all deployed contract addresses
   - Run with: `just e2e-deploy`
   - **Required:** `PRIVATE_KEY`

2. **`e2e/LiquidityProvision.s.sol`** - Tests the regular LP flow: adding liquidity, removing liquidity, and unwrapping LCCs
   - Run with: `just e2e-normal-lp`
   - **Required:** `PRIVATE_KEY`, `LP_PRIVATE_KEY`

3. **`e2e/Swap.s.sol`** - Tests exact-output swap flows with precise assertions
   - Run with: `just e2e-swap`
   - **Required:** `PRIVATE_KEY`, `LP_PRIVATE_KEY`

4. **`e2e/MarketMaker.s.sol`** - Tests the complete Market Maker journey: commit, mint, swaps, fee collection, and position closure
   - Run with: `just e2e-market-maker`
   - **Required:** `PRIVATE_KEY`, `LP_PRIVATE_KEY`

5. **`e2e/MMCoverage.s.sol`** - Tests the multi-MM settlement, checkpoint, poke, and exit flow without fee-pot-specific assertions
   - Run with: `just e2e-mm-coverage`
   - **Required:** `PRIVATE_KEY`, `LP_PRIVATE_KEY`, `LP2_PRIVATE_KEY`, `LP3_PRIVATE_KEY`

**Run all E2E tests:** `just e2e` (requires fork to be running)

## Deployment and configuration scripts overview

### `deploy/DeployContracts.s.sol` - Main Deployment Script

The comprehensive deployment script that deploys all contracts in the correct order:

1. **MarketFactory** - Deployed first (without hooks)
2. **CoreHook** - Deployed with proper HookMiner logic and MarketFactory address
3. **ProxyHook** - Deployed with proper HookMiner logic and MarketFactory address
4. **Initialise MarketFactory** - Calls `initialise()` to configure hooks in MarketFactory
5. **Hook Activation** - Verifies cross-references between hooks and factory

### Step-by-step deployment flow

1. **Deploy contracts** - `just deploy`
   - Deploys oracle, libraries, and core contracts
   - **Required:** `PRIVATE_KEY`
   - **Optional:** `NETWORK` (default: `sepolia`), `MODE` (default: `LOCAL`), `BROADCAST` (default: `false`)
   - **Output:** Sets `RESILIENT_ORACLE_ADDRESS` in `.env` file

2. **Configure underlying tokens** - Set `UNDERLYING_ASSET_0` and `UNDERLYING_ASSET_1` env variables
   - (dev mode only) - `just deploy-tokenA && just deploy-tokenB` then acquire the contract addresses from the deployment and update the env variables
   - (production mode) - Provide the addresses of the tokens that would make up the underlying assets of the market to be created
   - **Required:** `PRIVATE_KEY`, `UNDERLYING_ASSET_0`, `UNDERLYING_ASSET_1`

3. **Obtain tokens** - `just mint-mock-tokens`
   - (dev mode only) - Mints tokens to LP address for local development
   - (production mode) - Acquire enough amounts of each token configured as an `UNDERLYING_ASSET`
   - **Required:** `PRIVATE_KEY`, `UNDERLYING_ASSET_0`, `UNDERLYING_ASSET_1`
   - **Optional:** `LP_PRIVATE_KEY` (defaults to `PRIVATE_KEY`), `RECIPIENT_ADDRESS` (defaults to LP address), `AMOUNT` (default: max/2)

4. **Configure oracle** - `just configure-oracle`
   - Configures ResilientOracle for the underlying assets specified
   - (dev mode only) - Dev mode deploys a mock oracle contract and uses that as the main oracle for the underlying pair and sets the price to 1e18 since a feed will not be used in dev mode.
   - (production mode) - Since a feed is required in production we would have to configure the feed on the main oracle and this is specific to the choice of oracle e.g Binance, Chainlink etc
   - **Required:** `PRIVATE_KEY`, `RESILIENT_ORACLE_ADDRESS`, `UNDERLYING_ASSET_0`, `UNDERLYING_ASSET_1`
   - **Optional:** `MAIN_ORACLE_ADDRESS` (defaults to deployment file), `ORACLE_CACHING_ENABLED` (default: `0`)

5. **Create market** - `just create-market`
   - Creates a new market with configured assets
   - **Required:** `PRIVATE_KEY`, `UNDERLYING_ASSET_0`, `UNDERLYING_ASSET_1`, `VTS_CONFIG_FILE_PATH`
   - **Optional:** `CORE_POOL_FEE` (default: `0`), `TICK_SPACING` (default: `60`), `INITIAL_SQRT_PRICE_X96` (auto-calculated if not set), `REFERENCE_POOL_ID`, `ASSET0_PRICE`, `ASSET1_PRICE`, `PRICE_DECIMALS` (default: `6`)
   - **Required (VTS config):**
     - `VTS_CONFIG_FILE_PATH` must point to a JSON or TOML file matching the full VTS config struct shape
     - All VTS fields must be present in the file; market-creation scripts do not apply fallback defaults
     - JSON keys: `.token0.gracePeriodTime`, `.token0.baseVTSRate`, `.token0.maxGracePeriodTime`, `.token0.unbackedCommitmentGraceBypassTime`, `.token0.unbackedCommitmentGraceBypassThreshold`, `.token1...`, `.minResidualUnits`, `.unbackedCommitmentGraceBypassBps`
     - TOML keys: `token0.gracePeriodTime`, `token0.baseVTSRate`, `token0.maxGracePeriodTime`, `token0.unbackedCommitmentGraceBypassTime`, `token0.unbackedCommitmentGraceBypassThreshold`, `token1...`, `minResidualUnits`, `unbackedCommitmentGraceBypassBps`
   - **Output:** Writes `CORE_POOL_ID` and `PROXY_POOL_ID` to `deployments/{NETWORK}_markets.json`. Use `just read-deployment` to retrieve these values.

6. **Add liquidity** - `just add-liquidity`
   - Adds initial liquidity to the market
   - **Required:** `PRIVATE_KEY`, `LP_PRIVATE_KEY`, `CORE_POOL_ID`
   - **Optional:** `UNDERLYING_ASSET_0`, `UNDERLYING_ASSET_1`, `UNDERLYING_ASSET_0_AMOUNT`, `UNDERLYING_ASSET_1_AMOUNT`, `UA_0_AMOUNT`, `UA_1_AMOUNT`, `CORE_0_AMOUNT`, `CORE_1_AMOUNT`, `LCC_0_AMOUNT`, `LCC_1_AMOUNT`, `RANGE_WIDTH`
   - **Notes:**
     - `UNDERLYING_ASSET_0_AMOUNT` / `UNDERLYING_ASSET_1_AMOUNT` (preferred) are interpreted as amounts for the addresses
       in `UNDERLYING_ASSET_0` / `UNDERLYING_ASSET_1` respectively, regardless of core/LCC sorting.
     - `UA_0_AMOUNT` / `UA_1_AMOUNT` remain supported for backwards compatibility and are treated as aliases of the above.
       If both alias + preferred vars are set for the same lane and differ, the script will revert.
     - If you want to specify amounts directly in **core pool currency0/1 lanes** (LCC tokens), use `CORE_0_AMOUNT` / `CORE_1_AMOUNT`
       (or `LCC_0_AMOUNT` / `LCC_1_AMOUNT`). Do not mix CORE/LCC amount envs with UNDERLYING/UA amount envs.

7. **Remove liquidity** (optional) - `just remove-liquidity`
   - **Required:** `PRIVATE_KEY`, `LP_PRIVATE_KEY`, `TOKEN_ID`, `CORE_POOL_ID`

## Additional Utility Scripts

### Market Operations

- **`SwapV4.s.sol`** - Execute swaps on the proxy pool
  - **Required:** `PRIVATE_KEY`, `LP_PRIVATE_KEY`, `CORE_POOL_ID`
  - **Optional:** `SWAP_TYPE`, `AMOUNT`, `EAMOUNT`

- **`UnwrapLCC.s.sol`** - Unwrap LCC tokens to underlying assets
  - **Required:** `PRIVATE_KEY`, `LP_PRIVATE_KEY`, `LCC_ADDRESS`
  - **Optional:** `NETWORK`

- **`PauseMarket.s.sol`** - Pause or unpause market operations
  - **Required:** `PRIVATE_KEY`, `CORE_POOL_ID`, `PAUSE` (0=unpause, 1=pause)
  - **Optional:** `NETWORK`

- **`TransferOwnership.s.sol`** - Transfer ownership of protocol contracts
  - **Required:** `PRIVATE_KEY`, `NEW_OWNER`, `NETWORK`

### View Scripts

- **`view/GetCurrentSqrtPrice.s.sol`** - Get current sqrt price from a pool
  - **Required:** `CORE_POOL_ID` or `TOKEN_A`/`TOKEN_B`

- **`view/CalculateSqrtPrice.s.sol`** - Calculate sqrt price from asset prices
  - **Required:** `BID`, `ASK`
  - **Optional:** `TOKEN_A`, `TOKEN_B`, `QUOTE_DECIMALS`

### Reading Deployment Data

- **`ReadDeployment.s.sol`** - Read deployment addresses and market data from JSON files
  - Run with: `just read-deployment`
  - Reads from `deployments/{NETWORK}_deployments.json` and `deployments/{NETWORK}_markets.json`

### CREATE3 Factory Requirement

These scripts depend on the **CREATE3 factory** being deployed at the canonical address used by `CREATE3Script`:

- `contracts/evm-scripts/script/base/CREATE3Script.sol` (lines 51–52) hardcodes:
  - `CREATE3Factory(0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf)`

If you run against an RPC/network where there is **no contract code at that address**, scripts will fail with an error like **“call to non-contract address 0x9fBB…”**.

- **Remote networks**: use an RPC for a network where that CREATE3 factory is already deployed at `0x9fBB...`.
- **Local Anvil fork**: from `contracts/evm-scripts/`, run `MODE=LOCAL just setup-create3` (or the equivalent `anvil_setCode` flow) to install the factory bytecode at `0x9fBB...` before running deploy scripts.

## Verification

After deployment, you can verify the deployment using the built-in verification function:

```bash
forge script script/deploy/DeployContracts.s.sol:DeployContracts --sig "verifyDeployment()" --rpc-url <your_rpc_url>
```

## Hook Flags

The deployment uses specific hook flags to ensure proper functionality:

### CoreHook Flags

- `BEFORE_INITIALIZE_FLAG` - Validates pool initialization
- `AFTER_ADD_LIQUIDITY_FLAG` - Intercepts liquidity additions
- `AFTER_REMOVE_LIQUIDITY_FLAG` - Intercepts liquidity removals

### ProxyHook Flags

- `BEFORE_INITIALIZE_FLAG` - Validates pool initialization
- `BEFORE_ADD_LIQUIDITY_FLAG` - Blocks normal liquidity additions
- `BEFORE_SWAP_FLAG` - Overrides swap functionality
- `BEFORE_SWAP_RETURNS_DELTA_FLAG` - Allows custom swap deltas

## Deployment Order

The deployment follows a specific order to ensure proper contract relationships:

1. **MarketFactory Deployment**
   - Deployed first without hooks to avoid circular dependency
   - Only takes poolManager and bounds as constructor parameters

2. **CoreHook Deployment**
   - Uses HookMiner to find address with correct flags
   - Deployed with actual MarketFactory address in constructor

3. **ProxyHook Deployment**
   - Uses HookMiner to find address with correct flags
   - Deployed with actual MarketFactory address in constructor

4. **Initialise MarketFactory**
   - Calls `initialise()` function to configure hooks
   - Automatically calls `activate()` on both hooks during initialisation

5. **Hook Activation Verification**
   - Verifies cross-references are set correctly
   - Ensures hooks can communicate with factory

## Contract Relationships

```text
MarketFactory
├── CoreHook (manages core pool operations)
└── ProxyHook (manages proxy pool operations)
    └── References CoreHook for cross-pool operations
```

## Address Management

The deployment script automatically:

- Mines correct addresses for hooks using HookMiner
- Writes deployed addresses to JSON file for future reference
- Verifies all contract relationships are correct

### JSON-based Address Management

The deployment uses `ScriptHelper.s.sol` to manage addresses in JSON format:

- **Write addresses**: `writeAddress(name, address)` - Writes address to JSON file
- **Read addresses**: `readAddress(name)` - Reads address from JSON file
- **Write strings**: `writeString(name, value)` - Writes string metadata to JSON file
- **Read strings**: `readString(name)` - Reads string metadata from JSON file

### Using Deployment Addresses in Other Scripts

Other scripts can easily reference deployed contracts:

```solidity
import {ScriptHelper} from "./libraries/ScriptHelper.s.sol";

contract MyScript is ScriptHelper {
    function run() external {
        address coreHook = readAddress("coreHook");
        address proxyHook = readAddress("proxyHook");
        address marketFactory = readAddress("marketFactory");

        // Use the addresses...
    }
}
```

## Files Generated

After deployment, the following files are created:

- `deployments/{NETWORK}_deployments.json` - All deployment addresses and metadata in JSON format
- `deployments/{NETWORK}_markets.json` - Market creation data including `CORE_POOL_ID` and `PROXY_POOL_ID`

The deployments JSON file contains:

```json
{
  "coreHook": "0x...",
  "proxyHook": "0x...",
  "marketFactory": "0x...",
  "deploymentDate": "1234567890",
  "deploymentNetwork": "sepolia",
  "poolManager": "0x..."
}
```

The markets JSON file contains market-specific data keyed by `CORE_POOL_ID`:

```json
{
  "{CORE_POOL_ID}_corePoolId": "0x...",
  "{CORE_POOL_ID}_proxyPoolId": "0x...",
  "{CORE_POOL_ID}_underlyingAsset0": "0x...",
  "{CORE_POOL_ID}_underlyingAsset1": "0x...",
  "{CORE_POOL_ID}_lcc0": "0x...",
  "{CORE_POOL_ID}_lcc1": "0x..."
}
```

## Error Handling

The deployment script includes comprehensive error handling:

- Validates hook flags match expected permissions
- Verifies contract constructor parameters
- Checks cross-references between contracts
- Ensures proper activation of hooks

## Security Considerations

- All hooks are deployed using CREATE2 for deterministic addresses
- Hook flags are verified to match expected permissions
- MarketFactory validates all constructor parameters
- Cross-references are verified after deployment

## Troubleshooting

### Common Issues

1. **Hook Address Mismatch**
   - Ensure HookMiner is finding correct addresses
   - Verify flags match expected permissions

2. **Constructor Parameter Errors**
   - Check MarketFactory constructor parameters (now only poolManager and bounds)
   - Verify LCC constructor parameters

3. **initialise() Failures**
   - Ensure hooks are properly deployed before calling initialise()
   - Check that MarketFactory owner is calling initialise()

4. **Activation Failures**
   - Ensure hooks are properly deployed
   - Check that initialise() was called successfully

### Debug Commands

Test individual components:

```bash
# Read deployment addresses
forge script script/ReadDeployment.s.sol:ReadDeploymentScript --rpc-url <your_rpc_url>

# Verify deployment
forge script script/deploy/DeployContracts.s.sol:DeployContracts --sig "verifyDeployment()" --rpc-url <your_rpc_url>
```

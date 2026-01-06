# Deployment Scripts

This directory contains deployment scripts for the Fiet Protocol contracts.

## Scripts Overview

### 1. `deploy/DeployContracts.s.sol` - Main Deployment Script
The comprehensive deployment script that deploys all contracts in the correct order:

1. **MarketFactory** - Deployed first (without hooks)
2. **CoreHook** - Deployed with proper HookMiner logic and MarketFactory address
3. **ProxyHook** - Deployed with proper HookMiner logic and MarketFactory address
4. **Set Hooks** - Calls `setHooks()` to configure hooks in MarketFactory
5. **Hook Activation** - Verifies cross-references between hooks and factory

### 2. `TestDeploy.s.sol` - Test Script
A test script to verify deployment logic without actual deployment. Tests:
- HookMiner logic for both hooks
- Hook permissions verification
- MarketFactory deployment logic

## Usage

### Prerequisites
1. Set your private key as an environment variable:
```bash
export PRIVATE_KEY=your_private_key_here
```

2. Ensure you have sufficient funds in your wallet for deployment

3. To run a local fork, start an Anvil fork:
   - `just fork` (requires the `just` CLI), or
   - run `anvil --fork-url <RPC_URL> --port 8545` directly

4. Ensure the oracle dependencies are installed
   - `cd fiet-protocol/contracts/evm/lib/oracle` to navigate to the oracle directory
   - `yarn install` to install the hardhat dependencies required to make a deployment

### CREATE3 Factory Requirement
These scripts depend on the **CREATE3 factory** being deployed at the canonical address used by `CREATE3Script`:

- `contracts/evm-scripts/script/base/CREATE3Script.sol` (lines 51–52) hardcodes:
  - `CREATE3Factory(0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf)`

If you run against an RPC/network where there is **no contract code at that address**, scripts will fail with an error like **“call to non-contract address 0x9fBB…”**.

- **Remote networks**: use an RPC for a network where that CREATE3 factory is already deployed at `0x9fBB...`.
- **Local Anvil fork**: run `just setup-create3` (or the equivalent `anvil_setCode` flow) to install the factory bytecode at `0x9fBB...` before running deploy scripts.

### Running the Deployment

#### Deploy the oracle:
```bash
BROADCAST=true just deploy-oracle 
```

#### Deploy the linked libraries:
```bash
BROADCAST=true just deploy-libraries
```

#### Deploy the contracts:
```bash
BROADCAST=true just deploy-contracts
```

#### Full deployment of core contract
```bash
BROADCAST=true just deploy
```

### Deploying a market
#### Configuring the oracle

Before creating a market, the oracle must be configured for the **two underlying assets** (otherwise `create-market` will revert with `MarketOraclesNotConfigured()`).

Run:

```bash
BROADCAST=true just configure-oracle
```

Required env vars (recommended to put these in `contracts/evm-scripts/.env`):
- **`RESILIENT_ORACLE_ADDRESS`**: Deployed ResilientOracle proxy address (written by `just deploy-oracle`).
- **`UNDERLYING_ASSET_0`**: First underlying token address. if none existent, it can be generated using `just deploy-tokenA` 
- **`UNDERLYING_ASSET_1`**: Second underlying token address. if none existent, it can be generated using `just deploy-tokenA`

Optional env vars (`*`):
- **`MAIN_ORACLE_ADDRESS`***: MAIN oracle address used by ResilientOracle (LOCAL/dev: typically `ChainlinkOracle_Proxy`). Defaults to latest deployment.


#### Deploying the market

```bash
BROADCAST=true just create-market
```

### Verification

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

4. **Set Hooks in MarketFactory**
   - Calls `setHooks()` function to configure hooks
   - Automatically calls `activate()` on both hooks during setHooks()

5. **Hook Activation Verification**
   - Verifies cross-references are set correctly
   - Ensures hooks can communicate with factory

## Contract Relationships

```
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
- `deployments/deployments.json` - All deployment addresses and metadata in JSON format

The JSON file contains:
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

3. **setHooks() Failures**
   - Ensure hooks are properly deployed before calling setHooks()
   - Check that MarketFactory owner is calling setHooks()

4. **Activation Failures**
   - Ensure hooks are properly deployed
   - Check that setHooks() was called successfully

### Debug Commands

Test individual components:
```bash
# Test hook permissions
forge script script/TestDeploy.s.sol:TestDeployScript --sig "testHookPermissions()"

# Test specific hook mining
forge script script/TestDeploy.s.sol:TestDeployScript --sig "_testCoreHookMining()"

# Read deployment addresses
forge script script/ReadDeployment.s.sol:ReadDeploymentScript --rpc-url <your_rpc_url>

# Verify deployment
forge script script/deploy/DeployContracts.s.sol:DeployContracts --sig "verifyDeployment()" --rpc-url <your_rpc_url>
``` 
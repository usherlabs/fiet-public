# Deployment Scripts

This directory contains deployment scripts for the Fiet Protocol contracts.

## Scripts Overview

### 1. `DeployComplete.s.sol` - Main Deployment Script
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

### Running the Deployment

#### Test the deployment logic first:
```bash
forge script script/TestDeploy.s.sol:TestDeployScript --rpc-url <your_rpc_url>
```

#### Run the complete deployment:
```bash
forge script script/DeployComplete.s.sol:CompleteDeployScript --rpc-url <your_rpc_url> --broadcast
```

### Verification

After deployment, you can verify the deployment using the built-in verification function:

```bash
forge script script/DeployComplete.s.sol:CompleteDeployScript --sig "verifyDeployment()" --rpc-url <your_rpc_url>
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
forge script script/DeployComplete.s.sol:CompleteDeployScript --sig "verifyDeployment()" --rpc-url <your_rpc_url>
``` 
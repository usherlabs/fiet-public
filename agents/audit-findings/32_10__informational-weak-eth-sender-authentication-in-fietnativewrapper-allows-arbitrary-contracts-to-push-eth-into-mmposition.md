[Informational] Weak ETH sender authentication in FietNativeWrapper allows arbitrary contracts to push ETH into MMPositionManager

# Description

The PR introduced a new ETH-receive exception in [FietNativeWrapper._assertValidEthSender](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/NativeWrapper.sol#L36-L39) that accepts any contract reporting positionManager() == address(this). This under-authenticated path lets arbitrary contracts bypass the ETH receive allowlist and push ETH into MMPositionManager. Current native-credit accounting prevents counterfeit credit or fund theft, so impact is limited to griefing and erosion of the intended trust boundary.

This PR added a new sender-acceptance branch in contracts/evm/src/modules/NativeWrapper.sol ([FietNativeWrapper._assertValidEthSender](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/NativeWrapper.sol#L36-L39)) that treats any contract as a valid "custodian" if a staticcall to positionManager() on msg.sender returns address(this). There is no verification that the sender is a genuine MMQueueCustodian, is factory-deployed, or matches custodianFor[beneficiary]. As a result, any attacker contract can bypass the ETH receive allowlist and send ETH to MMPositionManager. However, the current native-credit accounting design does not attribute such ambient ETH to users: [batch-entry credits](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L52-L54) are [bounded by msg.value](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/TransientSlots.sol#L66-L68) and measured against a per-transaction baseline; native LCC unwrapping credits are [measured as in-call balance deltas](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L469-L481) around synchronous custodian flows; and WETH unwrap credits [use exact amounts](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L674-L675). Therefore, no counterfeit credit or theft is enabled. The issue’s practical impact is a weakened trust boundary and potential griefing by pushing ETH into the manager, not a direct financial loss.

# Severity

**Impact Explanation:** [Low] No counterfeit user credit or fund theft is possible under current accounting; the effect is limited to pushing ambient ETH into the manager and weakening the ETH-source trust boundary.

**Likelihood Explanation:** [Low] Exploitation is purely griefing and requires the attacker to spend ETH with no financial return, matching the rule for irrational, unprofitable behavior.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
An attacker deploys a spoof contract that implements positionManager() to return the MMPositionManager address and then calls it to forward ETH to the manager. The [receive check accepts the ETH](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/NativeWrapper.sol#L66-L68) and it accumulates as ambient balance, but no user receives native credit and funds cannot be withdrawn without matching credits.
#### Preconditions / Assumptions
- (a). MMPositionManager is deployed with this PR’s FietNativeWrapper._assertValidEthSender logic
- (b). Attacker can deploy arbitrary contracts and send ETH
- (c). Network and protocol operate normally; no special states required

### Scenario 2.
An attacker repeatedly pushes small amounts of ETH to MMPositionManager via the spoofed sender, bypassing the receive allowlist without using selfdestruct. This makes nuisance ETH pushes cheaper and easier, though still unprofitable and without creating user credits.
#### Preconditions / Assumptions
- (a). Same as Scenario 1
- (b). Attacker is willing to spend ETH purely for nuisance/griefing without profit

# Proposed fix

## NativeWrapper.sol

File: `contracts/evm/src/modules/NativeWrapper.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/NativeWrapper.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {NativeWrapper as UniNativeWrapper} from "../forks/NativeWrapper.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 import {Errors} from "../libraries/Errors.sol";
 import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
 import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";
+import {IMMPositionManager} from "../interfaces/IMMPositionManager.sol";
 import {IMMQueueCustodian} from "../interfaces/IMMQueueCustodian.sol";
 
 /// @title FietNativeWrapper
 /// @notice Used for wrapping and unwrapping native assets in PositionManagers.
 /// @dev Named to avoid colliding with the forked `NativeWrapper` contract name in this codebase.
 abstract contract FietNativeWrapper is UniNativeWrapper {
     constructor(IWETH9 _weth9) UniNativeWrapper(_weth9) {}
 
     /// @dev Implemented by inheritors that already bind a canonical MarketFactory namespace.
     function _canonicalMarketFactory() internal view virtual returns (IMarketFactory);
     /// @dev Implemented by inheritors with canonical LiquidityHub binding.
     function _liquidityHub() internal view virtual returns (ILiquidityHub);
 
     /// @notice Validates that the ETH sender is either WETH9, poolManager, canonical LiquidityHub, or a canonical native vault
     /// @dev Uses MarketFactory registry data to avoid interface-probing based sender spoofing.
     function _assertValidEthSender() internal view {
         // If sender is WETH9 or poolManager, allow it (these are trusted sources)
         if (msg.sender == address(WETH9) || msg.sender == address(poolManager)) {
             return;
         }
 
         // Allow canonical Hub-native payouts (e.g. native LCC unwrap-to-self in MMPM).
         if (msg.sender == address(_liquidityHub())) {
             return;
         }
 
-        // Native-backed LCC unwrap: `MMQueueCustodian` forwards immediate ETH from Hub to this manager for delta credit.
+        // Native-backed LCC unwrap: only accept ETH from this manager's canonical custodian for its beneficiary.
         if (msg.sender.code.length > 0) {
-            (bool ok, bytes memory data) = msg.sender.staticcall(abi.encodeCall(IMMQueueCustodian.positionManager, ()));
-            if (ok && data.length >= 32 && abi.decode(data, (address)) == address(this)) {
-                return;
+            (bool okPm, bytes memory dPm) = msg.sender.staticcall(abi.encodeCall(IMMQueueCustodian.positionManager, ()));
+            (bool okBen, bytes memory dBen) = msg.sender.staticcall(abi.encodeCall(IMMQueueCustodian.beneficiary, ()));
+            if (okPm && dPm.length >= 32 && okBen && dBen.length >= 32 && abi.decode(dPm, (address)) == address(this)) {
+                address ben = abi.decode(dBen, (address));
+                if (IMMPositionManager(address(this)).custodianFor(ben) == msg.sender) {
+                    return;
+                }
             }
         }
 
         IMarketFactory factory = _canonicalMarketFactory();
         address sender = msg.sender;
         if (sender.code.length == 0) {
             revert Errors.InvalidEthSender();
         }
 
         // Canonical vault lookup by sender address; unknown senders map to [0,0].
         address[2] memory underlyingPair = factory.proxyHookToCurrencyPair(sender);
         bool native0 = underlyingPair[0] == address(0);
         bool native1 = underlyingPair[1] == address(0);
 
         // Require exactly one native leg. This rejects unknown senders ([0,0]) and non-native markets.
         if (native0 == native1) {
             revert Errors.InvalidEthSender();
         }
     }
 
     // Best practice: be explicit about intent
     // Only executes on plain transaction (no selector) (ie. poolManager or WETH9 transfer of assets) to MarketVault.
     // Plain transactions are performed by the pool manager or external contracts in native asset routes.
     // ie. Only be executed if the msg.sender is the market vault in route: PM -> MV -> LH
     // This function replaces the forked NativeWrapper receive() to include MarketVault.
     receive() external payable override {
         _assertValidEthSender();
     }
 }
```

# Fiet - fiet-protocol

## Status

Done

## Tags

BugPoCer Only  
Private

## Commit

3a6d8fb3c9d33a196e662fa64ff4f2cb8255be26

## BugPoCer Scan Report

- [Low] pause_bypass
- [Low] missing_state_validation
- [Low] missing_input_validation
- [Low] insufficient_length_validation
- [Medium] incorrect_abi_decoding
- [Medium] insufficient_length_validation
- [Low] division_by_zero
- [Low] missing_input_validation

## All PoCs

## BugPoCer Scan Report

### [Low] pause_bypass

**Type:** Design Flaw  
**Location:** contracts/VTSOrchestrator.sol: settlePositionGrowths  
**Unit Name:** VTSOrchestrator  
**Location:** contracts/VTSOrchestrator.sol: settlePositionGrowths  
**Description:** settlePositionGrowths mutates position state via VTSPositionLib.settlePositionGrowths but lacks any pause guard (notPoolPaused) or linkage to a specific pool, allowing state changes while the pool is paused. This enables griefing/out-of-sequence settlements even during incident response.  
**PoC Summary:** test/poc/VTSOrchestrator_pause_bypass.t.sol — The PoC pauses a pool and then calls `settlePositionGrowths` (at `contracts/VTSOrchestrator.sol: settlePositionGrowths`) on an active position, demonstrating that without a `notPoolPaused` guard it still mutates state, while a guarded control path reverts as expected. This confirms the pause-bypass vulnerability as a true positive.

### [Low] missing_state_validation

**Type:** Design Flaw  
**Location:** `contracts/MarketFactory.sol::createMarket`  
**Unit Name:** MarketFactory  
**Location:** `contracts/MarketFactory.sol::createMarket`  
**Description:** `createMarket` does not validate that `coreHook` has been set (non-zero) before using it to initialize the core pool. If the owner never calls `setHooks()` or passes an invalid zero hook, the factory can create a core pool with `hooks = address(0)`, diverging from the intended architecture (core pool must be governed by the core hook). This cross-function dependency (`setHooks` → `createMarket`) lacks an enforcement check and can leave markets misconfigured, potentially breaking downstream invariants that expect hook callbacks (e.g., `AFTER_ADD/REMOVE_LIQUIDITY`) to run.  
**PoC Summary:** `test/poc/MarketFactory_missing_state_validation.t.sol` — Invokes `contracts/MarketFactory.sol::createMarket` without calling `setHooks`, expecting a revert if `coreHook` is unset, but the function proceeds to initialize the core pool with `hooks = address(0)`, demonstrating the missing state validation between `setHooks` and `createMarket`. The PoC reproduces the misconfiguration (true positive).

### [Low] missing_input_validation

**Type:** Config Risk  
**Location:** `contracts/VTSOrchestrator.sol: constructor`  
**Unit Name:** VTSOrchestrator  
**Location:** `contracts/VTSOrchestrator.sol: constructor`  
**Description:** Constructor validates only `_poolManager != address(0)` but does not validate `_signalManager`, `_oracleHelper`, `_liquidityHub`, or `_settlementObserver`. Supplying zero addresses will permanently brick dependent flows (oracle, signal, settlement, factory routing), creating an instant DoS at deployment.  
**PoC Summary:** test/poc/VTSOrchestrator_missing_input_validation.t.sol — Deploys a minimal orchestrator mirroring the constructor with_signalManager, _oracleHelper,_liquidityHub, and _settlementObserver set to zero to show deployment does not revert, then calls onlyFactoryGuard to demonstrate a DoS via an external call through a zero liquidityHub. The PoC successfully reproduces the missing input validation and its effect, so this is a true positive.

### [Low] insufficient_length_validation

**Type:** Design Flaw  
**Location:** CalldataDecoder.sol  
**Unit Name:** CalldataDecoder  
**Location:** CalldataDecoder.sol - functions decodeModifyLiquidityParams, decodeIncreaseLiquidityFromDeltasParams, decodeMintParams, decodeMintFromDeltasParams, decodeBurnParams  
**Description:** These decoders read multiple static words from params (e.g., tokenId/liquidity/amounts/ticks/owner) without first verifying that params.length covers the required static area. They rely solely on a later toBytes(...) check for the trailing bytes field. With truncated calldata, calldataload on missing words yields zeroes, causing silent defaulting (e.g., owner =address(0), amounts=0), enabling malformed calldata to pass with unintended semantics and potential authorization/state-bypass.  
**PoC Summary:** test/poc/CalldataDecoder_insufficient_length_validation.t.sol — The PoC supplies a 32-byte truncated params to a harness calling decodeMintParams and decodeModifyLiquidityParams, demonstrating that the decoders read missing static words as zero and fail to revert because only toBytes(...) enforces length, resulting in silent defaulting of fields. The issue is reproduced as described, so this is a true positive.

### [Medium] incorrect_abi_decoding

**Type:** Design Flaw  
**Location:** contracts/libraries/MMCalldataDecoder.sol: decodeCheckpointParams()  
**Unit Name:** MMCalldataDecoder  
**Location:** contracts/libraries/MMCalldataDecoder.sol: decodeCheckpointParams()  
**Description:** decodeCheckpointParams() decodes (uint256 tokenId, uint256 positionIndex, bytes data, bool withCommitment) but reads withCommitment from params.offset + 0x40, which is the third head word (the bytes offset), not the fourth head word where the bool resides (+0x60). As a result, withCommitment will almost always be non-zero (true) since it is set to the dynamic bytes offset, bypassing intended logic that depends on the flag. Fix by loading withCommitment from add(params.offset, 0x60) after validating length and before calling toBytes(2).  
**PoC Summary:** test/poc/MMCalldataDecoder_incorrect_abidecoding.t.sol — Crafts calldata for (uint256, uint256, bytes, bool) with withCommitment=false and compares a harness mirroring contracts/libraries/MMCalldataDecoder.sol: decodeCheckpointParams() that reads the bool at +0x40 against a correct version reading at +0x60, demonstrating the vulnerable decoder misinterprets the bytes offset as a nonzero bool. The PoC successfully reproduces the bug, confirming a true positive.

### [Medium] insufficient_length_validation

**Type:** User Exploit  
**Location:** contracts/libraries/MMCalldataDecoder.sol: decodeCommitSignalParams()  
**Unit Name:** MMCalldataDecoder  
**Location:** contracts/libraries/MMCalldataDecoder.sol: decodeCommitSignalParams()  
**Description:** decodeCommitSignalParams() reads owner with calldataload(add(params.offset, 0x20)) without any prior params.length check. If params.length < 0x40, EVM returns zero for out-of-bounds loads, silently setting owner to address(0) before toBytes(0) runs. This enables crafted calldata to zero out the recipient field and can misdirect or brick downstream flows that mint or assign ownership. Add a minimum length check (>= 0x40) before reading the second head word.  
**PoC Summary:** test/poc/MMCalldataDecoder_insufficient_length_validation.t.sol — Calls decodeCommitSignalParams() with a 32-byte head to exploit the missing params.length >= 0x40 check, making the out-of-bounds calldataload(add(params.offset, 0x20)) set owner to address(0) while toBytes(0) still succeeds in contracts/libraries/MMCalldataDecoder.sol. The call did not revert as expected, confirming the insufficient length validation vulnerability (true positive).

### [Low] division_by_zero

**Type:** Design Flaw  
**Location:** contracts/MarketFactory.sol::createMarket (proxyInitialPrice inversion)  
**Unit Name:** MarketFactory  
**Location:** contracts/MarketFactory.sol::createMarket (proxyInitialPrice inversion)  
**Description:** When ordersMatch == false, the code computes proxyInitialPrice = uint160((uint256(1) << 192) / initialSqrtPriceX96);. If initialSqrtPriceX96 == 0, this division reverts with a panic (division by zero). There is no input validation to prevent zero initial price, creating a brittle owner-only path that can brick market creation or be accidentally triggered. Add an explicit require(initialSqrtPriceX96 > 0) before inversion.  
**PoC Summary:** test/poc/MarketFactory_division_by_zero.t.sol — The PoC builds a harness of contracts/MarketFactory.sol::createMarket with a stub LiquidityHub that reverses token order to force ordersMatch == false, then sets initialSqrtPriceX96 = 0 so the inversion proxyInitialPrice = uint160((uint256(1) << 192) / initialSqrtPriceX96) hits a division-by-zero revert. By omitting an expectRevert (and including a control test where orders match), it demonstrates the panic revert, confirming a true positive.

### [Low] missing_input_validation

**Type:** Design Flaw  
**Location:** contracts/MarketFactory.sol::constructor  
**Unit Name:** MarketFactory  
**Location:** contracts/MarketFactory.sol::constructor  
**Description:** Constructor does not validate critical dependencies: _poolManager,_liquidityHub, _oracleHelper, and_vtsOrchestrator can be zero addresses. If liquidityHub == address(0), onlyLiquidityHub will permanently revert; if _poolManager == address(0), poolManager.initialize() in_createCorePool/_createProxyPool bricks market creation; zero oracleHelper or vtsOrchestrator can break oracle validation or pool initialization paths. Add explicit non-zero checks for all constructor parameters.  
**PoC Summary:** test/poc/MarketFactory_missing_input_validation.t.sol — Deploys a minimal MarketFactory with zero addresses to show the contracts/MarketFactory.sol::constructor lacks non-zero validation, then proves a permanent DoS by setting liquidityHub to address(0) so onlyLiquidityHub causes useMarketLiquidity() to always revert; this successfully reproduces the issue (true positive).

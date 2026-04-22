[High] Balance-wide sync attribution in OwnerCurrencyDelta.syncBalanceAsCredit for omnibus MMPM balance causes cross-user ERC20 theft/debt-erasure

# Description

[OwnerCurrencyDelta.syncBalanceAsCredit](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/OwnerCurrencyDelta.sol#L170-L205) credits/reduces a target’s delta from the entire ERC20 balance held by a shared owner (MMPositionManager), without last-synced tracking or per-locker reservation. Because MMPM is an omnibus holder for many lockers, a later locker can SYNC and TAKE tokens previously parked on MMPM by another user, or erase their own debt using those tokens.

The syncBalanceAsCredit routine uses currency.balanceOf(owner) to credit or reduce a target’s delta with no notion of already-attributed amounts. MMPositionManager (address(this)) intentionally holds ERC20 balances for many lockers across flows (e.g., settlement withdrawals to MMPM, ERC20 self-take to MMPM, unwrap-to-MMPM). Public [SYNC](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionManager.sol#L650-L661) maps the omnibus MMPM balance to the caller’s delta and [TAKE then transfers out tokens](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L84-L96). End-of-batch transient-delta invariants only ensure deltas net to zero; they do not prevent ERC20 from remaining parked on MMPM or being re-attributed to another locker later. LCC receipts in modify-liquidity have a partial mitigation ([take-back before custody forward](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/modules/PositionManagerImpl.sol#L191-L197)), but general ERC20 sync sites (e.g., [auto-sync credits the attacker from the entire MMPM ERC20 balance](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionActionsImpl.sol#L458-L479)) and [unwrap-to-MMPM](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionManager.sol#L486-L494) and public SYNC remain vulnerable. This allows (a) theft of ERC20 parked by other lockers via SYNC+TAKE and (b) debt erasure by syncing against someone else’s parked ERC20.

# Severity

**Impact Explanation:** [High] Enables direct, material loss of users’ principal ERC20 (theft via SYNC+TAKE) and undermines solvency by allowing debt erasure using others’ parked funds.

**Likelihood Explanation:** [Medium] Exploitation requires ERC20 to be parked on MMPM (a plausible, intended state due to ERC20 self-take and other flows) but not guaranteed at all times; attackers can monitor and act when present.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Public SYNC + TAKE drains parked ERC20: A victim previously used ERC20 self-take to address(this), zeroing their delta while leaving tokens on MMPM. The attacker calls SYNC(token) to credit themselves from the full MMPM balance, then calls TAKE(token) to withdraw those tokens to their wallet.
#### Preconditions / Assumptions
- (a). There is a non-zero ERC20 balance parked on the MMPositionManager (e.g., from a prior user’s ERC20 self-take to address(this) or other flows that left ERC20 on MMPM).
- (b). Attacker can call MMPM SYNC and TAKE as a locker (intended public utilities).

### Scenario 2.
Piggyback theft via auto-sync in positive ERC20 settlement: Attacker triggers a settlement that withdraws ERC20 to MMPM with usePositionManagerBalance=true. The auto-sync credits the attacker from the entire MMPM ERC20 balance (including tokens parked by others). The attacker then TAKEs the credited tokens.
#### Preconditions / Assumptions
- (a). There is a non-zero ERC20 balance parked on the MMPositionManager from prior users.
- (b). Attacker can trigger a position settlement that yields a positive ERC20 outflow to MMPM with usePositionManagerBalance=true.
- (c). Attacker can subsequently call TAKE to withdraw credited tokens.

### Scenario 3.
Debt erasure using someone else’s parked ERC20: Attacker holds a negative delta in an ERC20 while MMPM has that ERC20 parked by others. Attacker calls SYNC(token), which reduces their debt by min(MMPM balance, attacker debt), effectively erasing obligations without using their own funds.
#### Preconditions / Assumptions
- (a). Attacker currently has a negative delta for the ERC20.
- (b). There is a non-zero ERC20 balance parked on the MMPositionManager from prior users.
- (c). Attacker can call SYNC to reduce their debt using the MMPM balance.

# Proposed fix

## MMPositionActionsImpl.sol

File: `contracts/evm/src/MMPositionActionsImpl.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionActionsImpl.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
 import {PositionId, PositionLibrary, PositionModificationHookDataLib} from "./types/Position.sol";
 import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {IMarketVault} from "./interfaces/IMarketVault.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
 import {Position} from "./types/Position.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
 import {PositionManagerImpl} from "./modules/PositionManagerImpl.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {MarketHandlerLib} from "./libraries/MarketHandlerLib.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
 import {MMActions} from "./libraries/MMActions.sol";
 import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
 import {MMHelpers} from "./libraries/MMHelpers.sol";
 import {Locker} from "v4-periphery/src/libraries/Locker.sol";
 import {DelegateCallGuard} from "./modules/DelegateCallGuard.sol";
 import {VaultSettlementIntent} from "./types/VTS.sol";
 import {SlippageCheck} from "v4-periphery/src/libraries/SlippageCheck.sol";
 
 /// @title MMPositionActionsImpl
 /// @notice Implementation contract for MMPositionManager position operations
 /// @dev Called via delegatecall from MMPositionManager, shares storage context
 /// @dev Only handles position operations (actions <= SETTLE_POSITION_FROM_DELTAS)
 /// @dev ERC721 functions accessed via delegatecall context from MMPositionManager
 contract MMPositionActionsImpl is IMMActionsImpl, PositionManagerImpl, DelegateCallGuard {
     using SafeCast for uint256;
     using PositionLibrary for PositionId;
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
     using CurrencySettler for Currency;
     using CurrencyTransfer for Currency;
     using MMCalldataDecoder for bytes;
     using SlippageCheck for BalanceDelta;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Internal Structs
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @dev Internal struct to reduce stack depth in _settle
     /// @notice Groups transfer-related parameters to avoid stack-too-deep errors
     struct SettleTransferParams {
         Currency underlying0;
         Currency underlying1;
         IMarketVault vault;
         bool usePositionManagerBalance;
     }
 
     /// @dev Internal struct to reduce stack depth in _settle
     /// @notice Groups onMMSettle call parameters
     struct SettleCallParams {
         IMarketVault vault;
         IMarketFactory factory;
         uint256 tokenId;
         uint256 positionIndex;
         BalanceDelta requestedDelta;
         bool isSeizing;
         /// @dev Passed through to `onMMSettle`: affects deposit lanes only; no-op for withdrawals.
         bool fromDeltas;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Immutables (must match MMPositionManager's values)
     // ═══════════════════════════════════════════════════════════════════════════
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Constructor
     // ═══════════════════════════════════════════════════════════════════════════
 
     constructor(address _manager, address _marketFactory, address _vtsOrchestrator, address _canonicalCustody)
         PositionManagerImpl(IPoolManager(_manager), _marketFactory, _vtsOrchestrator, _canonicalCustody)
     {}
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Overrides for abstract functions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc PositionManagerBase
     function msgSender() public view override returns (address) {
         // References locker from delegatecall context - MMPositionManager
         return Locker.get();
     }
 
     /// @inheritdoc PositionManagerImpl
     function _queueSettleRecipient(uint256) internal view override returns (address) {
         IMMPositionManager m = IMMPositionManager(address(this));
         address recipientKey = msgSender();
         MMHelpers.assertQueueCustodianForRecipient(recipientKey);
         return m.custodianFor(recipientKey);
     }
 
     /// @dev Queued LCC is custodied on `custodianFor[beneficiary]` (the acting locker’s domain), beneficiary-global per `lcc`.
     function _forwardQueuedLccToCustodian(Currency currency, uint256, address beneficiary, uint256 amount)
         internal
         override(PositionManagerImpl)
     {
         IMMPositionManager m = IMMPositionManager(address(this));
         address recipientKey = beneficiary;
         MMHelpers.assertQueueCustodianForRecipient(recipientKey);
         address custAddr = m.custodianFor(recipientKey);
         if (custAddr != address(0) && custAddr != address(this)) {
             currency.transfer(custAddr, amount);
         }
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Position Action Handler
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc IMMActionsImpl
     /// @dev Only handles position operations (actions <= SETTLE_POSITION_FROM_DELTAS)
     function handleAction(uint256 action, bytes calldata params) external override onlyDelegateCall {
         if (action == MMActions.SETTLE_POSITION) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 int128 amount0,
                 int128 amount1,
                 bool usePositionManagerBalance
             ) = params.decodeSettlePositionParams();
             _settle(poolKey, tokenId, positionIndex, amount0, amount1, usePositionManagerBalance);
             return;
         }
         if (action == MMActions.MINT_POSITION) {
             (PoolKey calldata poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity) =
                 params.decodeMintPositionParams();
             _mintPosition(poolKey, tokenId, tickLower, tickUpper, liquidity);
             return;
         }
         if (action == MMActions.INCREASE_LIQUIDITY) {
             (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint256 liquidity) =
                 params.decodeIncreaseLiquidityParams();
             _increase(poolKey, tokenId, positionIndex, liquidity);
             return;
         }
         if (action == MMActions.DECREASE_LIQUIDITY) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint256 amountToDecrease,
                 uint128 amount0Min,
                 uint128 amount1Min
             ) = params.decodeDecreaseLiquidityParams();
             _decrease(poolKey, tokenId, positionIndex, amountToDecrease, amount0Min, amount1Min);
             return;
         }
         if (action == MMActions.BURN_POSITION) {
             (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint128 amount0Min, uint128 amount1Min) =
                 params.decodeBurnPositionParams();
             _burnPosition(poolKey, tokenId, positionIndex, amount0Min, amount1Min);
             return;
         }
         if (action == MMActions.SEIZE_POSITION) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint256 amount0,
                 uint256 amount1,
                 bool usePositionManagerBalance
             ) = params.decodeSeizePositionParams();
             _seizePosition(poolKey, tokenId, positionIndex, amount0, amount1, usePositionManagerBalance);
             return;
         }
         if (action == MMActions.INCREASE_LIQUIDITY_FROM_DELTAS) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint128 amount0Max,
                 uint128 amount1Max,
                 bool payerIsUser
             ) = params.decodeIncreaseFromDeltasParams();
             _increaseFromDeltas(poolKey, tokenId, positionIndex, amount0Max, amount1Max, payerIsUser);
             return;
         }
         if (action == MMActions.MINT_POSITION_FROM_DELTAS) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 int24 tickLower,
                 int24 tickUpper,
                 uint128 amount0Max,
                 uint128 amount1Max,
                 bool payerIsUser
             ) = params.decodeMintFromDeltasParams();
             _mintFromDeltas(poolKey, tokenId, tickLower, tickUpper, amount0Max, amount1Max, payerIsUser);
             return;
         }
         if (action == MMActions.SETTLE_POSITION_FROM_DELTAS) {
             (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, bool payerIsUser, bool shouldTake) =
                 params.decodeSettleFromDeltasParams();
             _settleFromDeltas(poolKey, tokenId, positionIndex, payerIsUser, shouldTake);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Internal Helpers
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Returns the position information for a given token ID and position index
     /// @param tokenId The ERC721 tokenId (commitment NFT ID)
     /// @param positionIndex The index of the position within the commitment
     /// @return Position The position information
     /// @return PositionId The position ID
     function getPosition(uint256 tokenId, uint256 positionIndex) public view returns (Position memory, PositionId) {
         return vtsOrchestrator.getPosition(tokenId, positionIndex);
     }
 
     /// @notice Returns the position ID for a given token ID and position index
     /// @param tokenId The ERC721 tokenId (commitment NFT ID)
     /// @param positionIndex The index of the position within the commitment
     /// @return The position ID
     function getPositionId(uint256 tokenId, uint256 positionIndex) public view returns (PositionId) {
         return vtsOrchestrator.getPositionId(tokenId, positionIndex);
     }
 
     /// @notice Checks if a position is currently being seized
     /// @param positionId The position ID to check
     /// @return True if the position is being seized
     function _isSeizing(PositionId positionId) internal view returns (bool) {
         PositionId seizedPositionId = TransientSlots.getSeizedPositionId();
         return PositionId.unwrap(seizedPositionId) == PositionId.unwrap(positionId);
     }
 
     /// @notice Gets the vault for a pool key
     /// @param poolKey The pool key
     /// @return The vault
     function _getVault(PoolKey calldata poolKey) internal view returns (IMarketVault) {
         return MarketHandlerLib.getVault(marketFactory, poolKey.toId());
     }
 
     /// @dev Splits hook encoding out of `_increaseFromDeltas` / `_mintFromDeltas` to avoid stack-too-deep in unoptimised builds.
     function _encodePositionHookForRecipientKeyedCustodian(
         uint256 tokenId,
         uint256 positionIndex,
         address locker,
         bool withInHookProtocolSettlement,
         uint256 credit0,
         uint256 credit1
     ) private returns (bytes memory) {
         address qRec = _queueSettleRecipient(tokenId);
         if (withInHookProtocolSettlement) {
             return PositionModificationHookDataLib.encodeWithInHookProtocolSettlement(
                 tokenId, positionIndex, locker, qRec, credit0, credit1
             );
         }
         return PositionModificationHookDataLib.encode(tokenId, positionIndex, locker, qRec);
     }
 
     /// @notice Reverts when principal token spend exceeds user-provided maxima
     function _validateMaxIn(BalanceDelta principalDelta, uint128 amount0Max, uint128 amount1Max) internal pure {
         int256 amount0 = principalDelta.amount0();
         int256 amount1 = principalDelta.amount1();
         if (amount0 < 0 && amount0Max < uint128(uint256(-amount0))) {
             revert Errors.MaximumAmountExceeded(amount0Max, uint128(uint256(-amount0)));
         }
         if (amount1 < 0 && amount1Max < uint128(uint256(-amount1))) {
             revert Errors.MaximumAmountExceeded(amount1Max, uint128(uint256(-amount1)));
         }
     }
 
     /// @notice Settles locker's available delta credits into the position via MMPM balance.
     function _settleFromDeltasCredits(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 credit0,
         uint256 credit1
     ) internal {
         _settle(poolKey, tokenId, positionIndex, -credit0.toInt128(), -credit1.toInt128(), true);
     }
 
     /// @notice Settles protocol-owned underlying delta credits into the position without token movement.
     function _settleProtocolCreditsFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 credit0,
         uint256 credit1,
         bool isSeizing
     ) internal {
         if (credit0 == 0 && credit1 == 0) return;
         if (isSeizing) {
             revert Errors.SeizureSettleOnlyDepositDisallowed();
         }
 
         _callOnMMSettle(
             SettleCallParams({
                 vault: _getVault(poolKey),
                 factory: marketFactory,
                 tokenId: tokenId,
                 positionIndex: positionIndex,
                 requestedDelta: LiquidityUtils.safeToBalanceDelta(credit0, credit1, true, true),
                 isSeizing: isSeizing,
                 fromDeltas: true
             })
         );
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Position Actions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Seizes a position (third-party guarantor action)
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amount0 The amount of token0 for seizure settlement
     /// @param amount1 The amount of token1 for seizure settlement
     /// @param usePositionManagerBalance If true, tokens flow via MMPM balance and locker's deltas are adjusted
     function _seizePosition(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 amount0,
         uint256 amount1,
         bool usePositionManagerBalance
     ) internal {
         (Position memory position, PositionId positionId) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         if (MMHelpers.isApprovedOrOwner(msgSender(), tokenId) || position.isActive == false) {
             revert Errors.InvalidPosition(tokenId, positionIndex, positionId);
         }
 
         vtsOrchestrator.onSeize(tokenId, positionIndex);
         TransientSlots.setSeizedPositionId(positionId);
 
         // negative amounts since we are settling into a position
         TransientSlots.setSeizurePrimarySettleAllowed(true);
         (BalanceDelta settlementDelta, uint256 seizedLiquidityUnits) = _settle(
             poolKey, tokenId, positionIndex, -amount0.toInt128(), -amount1.toInt128(), usePositionManagerBalance
         );
         TransientSlots.setSeizurePrimarySettleAllowed(false);
 
         // Fail closed: a zero-liquidity decrease still runs `modifyLiquidity` and can realise accrued LCC fees to the
         // locker (seizer) without removing any position liquidity. Seizure must not proceed unless the settlement
         // phase produced a non-zero seized-liquidity amount from VTS sizing.
         if (seizedLiquidityUnits == 0) {
             revert Errors.SeizureWithoutLiquidityRemoval();
         }
 
         // Use returned maxima clamped settlementDelta
         bytes memory hookData = PositionModificationHookDataLib.encodeSeizure(
             tokenId,
             positionIndex,
             msgSender(),
             _queueSettleRecipient(tokenId),
             settlementDelta.amount0(),
             settlementDelta.amount1()
         );
 
         _decreaseInternal(
             poolKey,
             position,
             PositionLibrary.generateSalt(tokenId, positionIndex),
             tokenId,
             seizedLiquidityUnits,
             hookData,
             0,
             0
         );
     }
 
     /// @notice Calls VTS orchestrator onMMSettle with bundled parameters
     /// @dev Extracted to reduce stack depth in _settle (avoids stack-too-deep with coverage instrumentation)
     /// @param params The call parameters bundled in a struct
     /// @return settlementDelta The settlement delta
     /// @return seizedLiquidityUnits The amount of liquidity units seized
     function _callOnMMSettle(SettleCallParams memory params)
         internal
         returns (
             BalanceDelta settlementDelta,
             uint256 seizedLiquidityUnits,
             VaultSettlementIntent memory vaultSettlementIntent
         )
     {
         (settlementDelta,, seizedLiquidityUnits, vaultSettlementIntent) =
             vtsOrchestrator.onMMSettle(
                 params.factory,
                 params.tokenId,
                 params.positionIndex,
                 params.requestedDelta,
                 params.isSeizing,
                 params.fromDeltas
             );
     }
 
     /// @notice Processes settlement transfers for a position
     /// @dev Extracted to reduce stack depth in _settle (avoids stack-too-deep with coverage instrumentation)
     /// @param params The transfer parameters bundled in a struct
     /// @param settlementIntent The explicit vault settlement intent from VTS
     function _processSettlementTransfers(
         SettleTransferParams memory params,
         VaultSettlementIntent memory settlementIntent
     ) internal {
         BalanceDelta settlementDelta = settlementIntent.requestedDelta;
         // Adheres to core/LCC pool token ordering.
         int128 delta0 = settlementDelta.amount0();
         int128 delta1 = settlementDelta.amount1();
 
         address sender = msgSender();
         address custody = canonicalCustody;
 
         // Process negative deltas (inflows to vault)
         if (delta0 < 0) {
             uint256 amt0 = LiquidityUtils.safeInt128ToUint256(delta0);
             if (params.usePositionManagerBalance) {
                 // Ensure locker credit is fully consumed before moving pooled MMPM funds.
                 uint256 taken0 = vtsOrchestrator.take(params.underlying0, sender, amt0);
                 if (taken0 != amt0) {
                     revert Errors.InsufficientBalance(taken0, amt0);
                 }
                 params.underlying0.transfer(custody, amt0);
             } else {
                 // Settle IN (deposit) of native ETH MUST come from MMPM balance.
                 if (params.underlying0 == CurrencyLibrary.ADDRESS_ZERO) {
                     revert Errors.NativeTransferFromUnsupported(sender);
                 }
                 // Otherwise, pull only from the locker (msgSender()).
                 params.underlying0.transferFrom(sender, custody, amt0);
             }
         }
         if (delta1 < 0) {
             uint256 amt1 = LiquidityUtils.safeInt128ToUint256(delta1);
             if (params.usePositionManagerBalance) {
                 uint256 taken1 = vtsOrchestrator.take(params.underlying1, sender, amt1);
                 if (taken1 != amt1) {
                     revert Errors.InsufficientBalance(taken1, amt1);
                 }
                 params.underlying1.transfer(custody, amt1);
             } else {
                 if (params.underlying1 == CurrencyLibrary.ADDRESS_ZERO) {
                     revert Errors.NativeTransferFromUnsupported(sender);
                 }
                 params.underlying1.transferFrom(sender, custody, amt1);
             }
         }
 
         params.vault.modifyLiquidities(settlementIntent);
 
+        // NOTE: For ERC20 positive deltas, prefer exact-credit of actual delivered amounts (e.g., via
+        // tryModifyLiquiditiesWithRecipient and its return delta) instead of balance-wide sync to avoid mis-attribution
+        // if any legacy omnibus balances remain.
         // Process positive deltas (outflows from vault)
         if (params.usePositionManagerBalance) {
             // Either sync received amounts (non-native) or credit exact known native deltas.
             if (delta0 > 0) {
                 uint256 amt0Out = LiquidityUtils.safeInt128ToUint256(delta0);
                 if (params.underlying0 == CurrencyLibrary.ADDRESS_ZERO) {
                     _creditExact(params.underlying0, amt0Out);
                 } else {
                     _syncBalanceAsCredit(params.underlying0);
                 }
             }
             if (delta1 > 0) {
                 uint256 amt1Out = LiquidityUtils.safeInt128ToUint256(delta1);
                 if (params.underlying1 == CurrencyLibrary.ADDRESS_ZERO) {
                     _creditExact(params.underlying1, amt1Out);
                 } else {
                     _syncBalanceAsCredit(params.underlying1);
                 }
             }
         } else {
             // or forward to the locker.
             if (delta0 > 0) {
                 params.underlying0.transfer(sender, LiquidityUtils.safeInt128ToUint256(delta0));
             }
             if (delta1 > 0) {
                 params.underlying1.transfer(sender, LiquidityUtils.safeInt128ToUint256(delta1));
             }
         }
     }
 
     /// @notice Settles underlying assets to/from a position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amount0 The amount of token0 to settle (signed)
     /// @param amount1 The amount of token1 to settle (signed)
     /// @param usePositionManagerBalance If true, tokens flow via MMPM balance and locker's deltas are adjusted.
     ///        If false, tokens flow directly from/to locker (external transfer).
     /// @return seizedLiquidityUnits The amount of liquidity units seized (if applicable)
     function _settle(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         int128 amount0,
         int128 amount1,
         bool usePositionManagerBalance
     ) internal returns (BalanceDelta, uint256) {
         if (amount0 == 0 && amount1 == 0) {
             revert Errors.InvalidDelta(0, 0);
         }
 
         // Build call params in scoped block to release intermediate variables
         SettleCallParams memory callParams;
         {
             // Position validation in nested scope
             bool isSeizing;
             {
                 Position memory position;
                 PositionId positionId;
                 (position, positionId) = getPosition(tokenId, positionIndex);
                 MMHelpers.assertPositionForPool(poolKey, position);
                 isSeizing = _isSeizing(positionId);
             }
 
             if (!isSeizing) {
                 MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
             }
 
             if (isSeizing && (amount0 < 0 || amount1 < 0) && !TransientSlots.getSeizurePrimarySettleAllowed()) {
                 revert Errors.SeizureSettleOnlyDepositDisallowed();
             }
 
             callParams = SettleCallParams({
                 vault: _getVault(poolKey),
                 factory: marketFactory,
                 tokenId: tokenId,
                 positionIndex: positionIndex,
                 requestedDelta: toBalanceDelta(amount0, amount1),
                 isSeizing: isSeizing,
                 fromDeltas: false
             });
         }
 
         // Call onMMSettle via helper
         (
             BalanceDelta settlementDelta,
             uint256 seizedLiquidityUnits,
             VaultSettlementIntent memory vaultSettlementIntent
         ) = _callOnMMSettle(callParams);
 
         // Process settlement transfers via helper (reduces stack depth)
         _processSettlementTransfers(
             SettleTransferParams({
                 underlying0: _lccToUnderlyingCurrency(poolKey.currency0),
                 underlying1: _lccToUnderlyingCurrency(poolKey.currency1),
                 vault: callParams.vault,
                 usePositionManagerBalance: usePositionManagerBalance
             }),
             vaultSettlementIntent
         );
 
         return (settlementDelta, seizedLiquidityUnits);
     }
 
     /// @notice Burns (fully decreases) a position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     function _burnPosition(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint128 amount0Min,
         uint128 amount1Min
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         uint256 completeLiquidity = uint256(position.liquidity);
         address qRec = _queueSettleRecipient(tokenId);
         _decreaseInternal(
             poolKey,
             position,
             PositionLibrary.generateSalt(tokenId, positionIndex),
             tokenId,
             completeLiquidity,
             PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender(), qRec),
             amount0Min,
             amount1Min
         );
     }
 
     /// @notice Increases liquidity in an existing position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param liquidity The amount of liquidity to add
     function _increase(PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint256 liquidity) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
         _increaseInternal(poolKey, tokenId, positionIndex, position.tickLower, position.tickUpper, liquidity);
     }
 
     /// @notice Internal helper to increase liquidity
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param liquidity The amount of liquidity to add
     /// @return positionId The position ID
     /// @return principalDelta Principal token deltas excluding informational fee accrual
     function _increaseInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity
     ) internal returns (PositionId positionId, BalanceDelta principalDelta) {
         address qRec = _queueSettleRecipient(tokenId);
         return _increaseInternal(
             poolKey,
             tokenId,
             positionIndex,
             tickLower,
             tickUpper,
             liquidity,
             PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender(), qRec)
         );
     }
 
     function _increaseInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity,
         bytes memory hookData
     ) internal returns (PositionId positionId, BalanceDelta principalDelta) {
         if (liquidity > type(uint128).max) {
             revert Errors.InvalidAmount(liquidity, type(uint128).max);
         }
 
         ModifyLiquidityParams memory params = ModifyLiquidityParams({
             tickLower: tickLower,
             tickUpper: tickUpper,
             liquidityDelta: liquidity.toInt256(),
             salt: PositionLibrary.generateSalt(tokenId, positionIndex)
         });
 
         positionId = PositionLibrary.generateId(address(this), params);
         (BalanceDelta liquidityDelta, BalanceDelta feesAccrued,) =
             _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
         principalDelta = liquidityDelta - feesAccrued;
     }
 
     /// @notice Increases liquidity using available delta credits
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amount0Max The maximum amount of token0 to spend
     /// @param amount1Max The maximum amount of token1 to spend
     /// @param payerIsUser If true, user consumes credit the protocol owes them (delta target = MMPM).
     ///        If false, uses locker's direct credit (delta target = locker).
     /// @dev Delta target semantics:
     ///      - MMPM (address(this)): Protocol owes/is owed by external sources
     ///      - Locker (msgSender()): External entity owes/is owed by protocol
     /// @dev tickLower and tickUpper are read from the position via getPosition()
     function _increaseFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint128 amount0Max,
         uint128 amount1Max,
         bool payerIsUser
     ) internal {
         address sender = msgSender();
         MMHelpers.assertApprovedOrOwner(sender, tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         // payerIsUser = true: User consumes credit protocol owes them (tracked on MMPM)
         // payerIsUser = false: Locker uses their own direct credit
         address deltaTarget = payerIsUser ? address(this) : sender;
         (uint256 liquidityFromDeltas, uint256 credit0, uint256 credit1) =
             _getLiquidityFromDeltas(poolKey, deltaTarget, position.tickLower, position.tickUpper);
         bytes memory hookData = _encodePositionHookForRecipientKeyedCustodian(
             tokenId, positionIndex, sender, payerIsUser, credit0, credit1
         );
         (, BalanceDelta principalDelta) = _increaseInternal(
             poolKey, tokenId, positionIndex, position.tickLower, position.tickUpper, liquidityFromDeltas, hookData
         );
         _validateMaxIn(principalDelta, amount0Max, amount1Max);
         if (!payerIsUser) {
             _settleFromDeltasCredits(poolKey, tokenId, positionIndex, credit0, credit1);
         }
     }
 
     /// @notice Mints a new position within a commitment
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param liquidity The amount of liquidity to mint
     function _mintPosition(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         _mintPositionInternal(poolKey, tokenId, tickLower, tickUpper, liquidity);
     }
 
     /// @notice Mints a new position using available delta credits
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param amount0Max The maximum amount of token0 to spend
     /// @param amount1Max The maximum amount of token1 to spend
     /// @param payerIsUser If true, user consumes credit the protocol owes them (delta target = MMPM).
     ///        If false, uses locker's direct credit (delta target = locker).
     /// @dev Delta target semantics:
     ///      - MMPM (address(this)): Protocol owes/is owed by external sources
     ///      - Locker (msgSender()): External entity owes/is owed by protocol
     function _mintFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint128 amount0Max,
         uint128 amount1Max,
         bool payerIsUser
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         // payerIsUser = true: User consumes credit protocol owes them (tracked on MMPM)
         // payerIsUser = false: Locker uses their own direct credit
         address deltaTarget = payerIsUser ? address(this) : msgSender();
         (uint256 liquidityFromDeltas, uint256 credit0, uint256 credit1) =
             _getLiquidityFromDeltas(poolKey, deltaTarget, tickLower, tickUpper);
         uint256 nextPositionIndex;
         (,, nextPositionIndex,,) = vtsOrchestrator.getCommit(tokenId);
         bytes memory hookData = _encodePositionHookForRecipientKeyedCustodian(
             tokenId, nextPositionIndex, msgSender(), payerIsUser, credit0, credit1
         );
         // This works as LCCs are issued, capitalised by underlying tokens owed to the MM.
         (, uint256 positionIndex, BalanceDelta principalDelta) =
             _mintPositionInternal(poolKey, tokenId, tickLower, tickUpper, liquidityFromDeltas, hookData);
         _validateMaxIn(principalDelta, amount0Max, amount1Max);
         if (!payerIsUser) {
             _settleFromDeltasCredits(poolKey, tokenId, positionIndex, credit0, credit1);
         }
     }
 
     /// @notice Settles into/from the position using available delta credits
     /// @dev Note: We can only do additional actions (such as settle in or out) on credits (deltas that are positive).
     ///      Credits represent amounts the system owes to the user, which can be settled into positions or withdrawn.
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param payerIsUser If true, use protocol delta (address(this)). If false, use locker delta (msgSender()).
     /// @param shouldTake If true, withdraw (consume credit). If false, deposit (settle credit into position).
     /// @dev Delta semantics:
     ///      - Protocol delta (address(this)): Protocol owes/is owed by external sources
     ///      - Locker delta (msgSender()): External entity owes/is owed by protocol
     function _settleFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         bool payerIsUser,
         bool shouldTake
     ) internal {
         address sender = msgSender();
 
         Currency underlying0 = _lccToUnderlyingCurrency(poolKey.currency0);
         Currency underlying1 = _lccToUnderlyingCurrency(poolKey.currency1);
 
         // Ambient seizure (AUTH-01A / audit 30_3): `SETTLE_POSITION_FROM_DELTAS` with `payerIsUser=true` and
         // `shouldTake=false` is the protocol-credit *deposit* matrix cell. It calls `onMMSettle(isSeizing=true)` without
         // any guaranteed `_decreaseInternal` coupling, so carry and sizing can advance while liquidity stays unchanged.
         // Forbid this cell whenever the batch already marked this `(tokenId, positionIndex)` as seized — even when
         // there are no protocol credits yet (otherwise the call would be a misleading no-op while still being the
         // wrong operation to schedule under seizure).
         if (payerIsUser && !shouldTake) {
             (Position memory position, PositionId positionId) = getPosition(tokenId, positionIndex);
             MMHelpers.assertPositionForPool(poolKey, position);
             if (_isSeizing(positionId)) {
                 revert Errors.SeizureSettleOnlyDepositDisallowed();
             }
         }
 
         // Behaviour matrix:
         // - shouldTake=true && payerIsUser=true:  Withdraw to locker from protocol delta via _settle
         // - shouldTake=false && payerIsUser=true: Settle protocol-owned delta credits via VTS lifecycle accounting
         // - shouldTake=true && payerIsUser=false: Withdraw to MMPM and sync credits
         // - shouldTake=false && payerIsUser=false: Settle from MMPM balance via _settle
 
         // Get protocol delta credits (address(this))
         (uint256 credit0, uint256 credit1) = _getFullCreditPair(underlying0, underlying1, address(this));
 
         if (credit0 > 0 || credit1 > 0) {
             if (shouldTake) {
                 // WITHDRAW: Move credits out as tokens
                 // Protocol owes user → withdraw to locker via _settle
                 _settle(poolKey, tokenId, positionIndex, credit0.toInt128(), credit1.toInt128(), !payerIsUser);
                 // if !payerIsUser, balance sync handled in _settle
             } else {
                 // DEPOSIT: Settle protocol-owned underlying delta credits into the position with no token movement.
                 bool isSeizing;
                 {
                     Position memory position;
                     PositionId positionId;
                     (position, positionId) = getPosition(tokenId, positionIndex);
                     MMHelpers.assertPositionForPool(poolKey, position);
                     isSeizing = _isSeizing(positionId);
                 }
 
                 if (!isSeizing) {
                     MMHelpers.assertApprovedOrOwner(sender, tokenId);
                 }
 
                 _settleProtocolCreditsFromDeltas(poolKey, tokenId, positionIndex, credit0, credit1, isSeizing);
             }
         }
         if (!payerIsUser && !shouldTake) {
             // Settle from MMPM balance (actual token movement)
             (uint256 lockerCredit0, uint256 lockerCredit1) = _getFullCreditPair(underlying0, underlying1, sender);
             _settle(poolKey, tokenId, positionIndex, -lockerCredit0.toInt128(), -lockerCredit1.toInt128(), true);
         }
     }
 
     /// @notice Internal helper to decrease liquidity
     /// @param poolKey The pool key
     /// @param position The position to decrease
     /// @param salt The position salt
     /// @param amountToDecrease The amount of liquidity to remove
     /// @param hookData The hook data for the modification
     function _decreaseInternal(
         PoolKey calldata poolKey,
         Position memory position,
         bytes32 salt,
         uint256 tokenId,
         uint256 amountToDecrease,
         bytes memory hookData,
         uint128 amount0Min,
         uint128 amount1Min
     ) internal {
         uint256 posLiq = uint256(position.liquidity);
         if (amountToDecrease > posLiq) {
             revert Errors.InvalidAmount(amountToDecrease, posLiq);
         }
 
         if (amountToDecrease > uint256(type(int256).max)) {
             amountToDecrease = uint256(type(int256).max);
         }
 
         ModifyLiquidityParams memory params = ModifyLiquidityParams({
             tickLower: position.tickLower,
             tickUpper: position.tickUpper,
             liquidityDelta: -amountToDecrease.toInt256(),
             salt: salt
         });
 
         (,, BalanceDelta mmForwardedNonFeeForMinOut) = _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
         // Min-out on immediate non-fee LCC after fee netting, not raw `callerDelta - feesAccrued` (VTS queue principal).
         mmForwardedNonFeeForMinOut.validateMinOut(amount0Min, amount1Min);
     }
 
     /// @notice Decreases liquidity from an existing position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amountToDecrease The amount of liquidity to remove
     /// @param amount0Min Minimum per-leg immediate non-fee LCC token0 after fee netting (`LiquidityUtils.forwardedNonFeeLccAmount`).
     ///        For commit positions, only the Hub-queued slice is custodied; surplus remains locker transient LCC credit.
     /// @param amount1Min Minimum per-leg immediate non-fee LCC token1 after fee netting (VTS queue principal remains `callerDelta - feesAccrued`).
     function _decrease(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 amountToDecrease,
         uint128 amount0Min,
         uint128 amount1Min
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         address qRec = _queueSettleRecipient(tokenId);
         _decreaseInternal(
             poolKey,
             position,
             PositionLibrary.generateSalt(tokenId, positionIndex),
             tokenId,
             amountToDecrease,
             PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender(), qRec),
             amount0Min,
             amount1Min
         );
     }
 
     /// @notice Internal helper to mint a new position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param liquidity The amount of liquidity to mint
     /// @return positionId The position ID
     /// @return positionIndex The position index within the commitment
     /// @return principalDelta Principal token deltas excluding informational fee accrual
     function _mintPositionInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity
     ) internal returns (PositionId positionId, uint256 positionIndex, BalanceDelta principalDelta) {
         uint256 nextPositionIndex;
         (,, nextPositionIndex,,) = vtsOrchestrator.getCommit(tokenId);
         address qRec = _queueSettleRecipient(tokenId);
         return _mintPositionInternal(
             poolKey,
             tokenId,
             tickLower,
             tickUpper,
             liquidity,
             PositionModificationHookDataLib.encode(tokenId, nextPositionIndex, msgSender(), qRec)
         );
     }
 
     function _mintPositionInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity,
         bytes memory hookData
     ) internal returns (PositionId positionId, uint256 positionIndex, BalanceDelta principalDelta) {
         if (liquidity > type(uint128).max) {
             revert Errors.InvalidAmount(liquidity, type(uint128).max);
         }
 
         (,, positionIndex,,) = vtsOrchestrator.getCommit(tokenId);
 
         ModifyLiquidityParams memory params = ModifyLiquidityParams({
             tickLower: tickLower,
             tickUpper: tickUpper,
             liquidityDelta: liquidity.toInt256(),
             salt: PositionLibrary.generateSalt(tokenId, positionIndex)
         });
 
         positionId = PositionLibrary.generateId(address(this), params);
         (BalanceDelta liquidityDelta, BalanceDelta feesAccrued,) =
             _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
         principalDelta = liquidityDelta - feesAccrued;
     }
 }
```

## PositionManagerEntrypoint.sol

File: `contracts/evm/src/modules/PositionManagerEntrypoint.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/modules/PositionManagerEntrypoint.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
 import {TransientSlots} from "../libraries/TransientSlots.sol";
 import {PositionManagerBase} from "./PositionManagerBase.sol";
 import {Errors} from "../libraries/Errors.sol";
 
 /**
  * @title PositionManagerEntrypoint
  * @notice Base contract providing entrypoint-specific functionality
  * @dev Contains functions used only by MMPositionManager (entrypoint)
  */
 abstract contract PositionManagerEntrypoint is PositionManagerBase {
     address public immutable actionsImpl;
 
     constructor(address _marketFactory, address _vtsOrchestrator, address _canonicalCustody, address _actionsImpl)
         PositionManagerBase(_marketFactory, _vtsOrchestrator, _canonicalCustody)
     {
         if (_actionsImpl == address(0) || _actionsImpl.code.length == 0) {
             revert Errors.InvalidAddress(_actionsImpl);
         }
         actionsImpl = _actionsImpl;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Delegation Helpers
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @dev Delegates a call to the implementation contract
     function _delegateToImpl(bytes memory data) internal {
         // OZ Address helper verifies target is a contract and bubbles revert reasons.
         Address.functionDelegateCall(actionsImpl, data);
     }
 
     // ------------------------------------------------------------------------------------------------
     // Batch Hooks
     // ------------------------------------------------------------------------------------------------
 
     /// @notice Hook called before batch execution
     /// @dev Credits native ETH to the locker delta using **balance-delta** accounting for the batch:
     ///      - First batch in the tx: baseline `lastSeen = balance - msg.value` so only this call's `msg.value` is
     ///        treated as new inflow (ambient ETH already on the router is not credited).
     ///      - Later batches: `fresh = balance - lastSeen`; credit `min(msg.value, fresh)` so:
     ///        - `Multicall_v4` inner `delegatecall`s share one outer `msg.value` and do not increase balance between
     ///          batches → second inner batch gets `fresh == 0` (fixes duplicate credit if we cleared a boolean per batch).
     ///        - Distinct payable top-level calls each add ETH → `fresh` matches the new wei and each call is credited once.
     ///      `_afterBatch` snapshots `address(this).balance` into transient storage for the rest of the transaction.
     function _beforeBatch() internal {
         uint256 amount = TransientSlots.nativeEthCreditAmountForBatch(address(this).balance, msg.value);
         if (amount > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
         }
     }
 
     /// @notice Hook called after batch execution
     /// @dev Clears batch-scoped seizure context, asserts deltas net to zero, then records native balance for the next
     ///      `_beforeBatch` in the same transaction (multicall-safe, multi-entrypoint-safe).
     function _afterBatch() internal {
         TransientSlots.clearSeizedPositionId();
         TransientSlots.clearSeizurePrimarySettleAllowed();
         // Owner-scoped and market-scoped transient namespaces both resolve through the orchestrator boundary.
         vtsOrchestrator.assertNonZeroDeltas(marketFactory);
         TransientSlots.setNativeLastSeenBalance(address(this).balance);
     }
 
     // ------------------------------------------------------------------------------------------------
     // MM Utility Helpers
     // ------------------------------------------------------------------------------------------------
 
     /// @notice Takes currency from delta and transfers to recipient
     /// @dev Unified flow for both LCC and underlying currencies:
     ///      - Balance held as ERC20 by MMPM
     ///      - Delta on locker (LCC fees synced via _syncBalanceAsCredit after position modification)
     ///      - Flow: debit locker delta -> direct ERC20 transfer
     /// @param currency The currency to take
     /// @param to The recipient address
     /// @param maxAmount The maximum amount to take (0 = take full available credit)
     /// @dev Native `TAKE` to `address(this)` is disallowed: it would debit the locker's delta without moving ETH,
     ///      stranding balance on MMPM with no native `SYNC` path (see `INVARIANTS.md` DELTA-02 / audit finding on
-    ///      native self-take). ERC20 self-take remains valid and recoverable via `SYNC`.
+    ///      native self-take). ERC20 self-take is also disallowed to prevent omnibus balance parking and re-attribution.
     function _take(Currency currency, address to, uint256 maxAmount) internal {
-        if (currency == CurrencyLibrary.ADDRESS_ZERO && to == address(this)) {
+        if (to == address(this)) {
             revert Errors.InvalidAddress(to);
         }
         address locker = msgSender();
         uint256 bal = currency.balanceOfSelf();
         // maxAmount == 0 means "take full available credit", but still cap to the actual ERC20 balance held by MMPM.
         uint256 trueMaxAmount = (maxAmount == 0) ? bal : Math.min(maxAmount, bal);
         uint256 takeAmount = vtsOrchestrator.take(currency, locker, trueMaxAmount);
 
         if (to != address(this)) {
             currency.transfer(to, takeAmount);
         }
     }
 }
```

## MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionManager.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {ERC721Permit_v4} from "v4-periphery/src/base/ERC721Permit_v4.sol";
 import {ReentrancyLock} from "v4-periphery/src/base/ReentrancyLock.sol";
 import {Multicall_v4} from "v4-periphery/src/base/Multicall_v4.sol";
 import {BaseActionsRouter} from "v4-periphery/src/base/BaseActionsRouter.sol";
 import {FietNativeWrapper} from "./modules/NativeWrapper.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 import {PositionId, Position} from "./types/Position.sol";
 import {LiquiditySignal} from "./types/Commit.sol";
 import {MarketMaker} from "./libraries/MarketMaker.sol";
 import {ICommitmentDescriptor} from "./interfaces/ICommitmentDescriptor.sol";
 import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
 import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
 import {PositionManagerEntrypoint} from "./modules/PositionManagerEntrypoint.sol";
 import {Permit2Forwarder} from "v4-periphery/src/base/Permit2Forwarder.sol";
 import {MMActions} from "./libraries/MMActions.sol";
 import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
 import {MMHelpers} from "./libraries/MMHelpers.sol";
 import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {IMMQueueCustodianFactory} from "./interfaces/IMMQueueCustodianFactory.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
 
 /// @title MMPositionManager
 /// @notice Entry point for VRL commitment position management
 /// @dev Handles commitment lifecycle (ERC721) and utility operations locally
 /// @dev Delegates position operations to `MMPositionActionsImpl` via delegatecall (`_delegateToImpl`).
 /// @dev Seizure economics coupling (AUTH-01A): settle-only *deposits* that can reach `onMMSettle(isSeizing=true)`
 ///      without a paired liquidity decrease are rejected in the impl — including the protocol-credit branch of
 ///      `SETTLE_POSITION_FROM_DELTAS` and raw `SETTLE_POSITION` deposits — so seizure carry cannot be advanced in
 ///      isolation from `_decreaseInternal`. Only the primary settle nested inside `SEIZE_POSITION` is allow-listed
 ///      for that phase via `TransientSlots` (cleared in `_afterBatch`).
 contract MMPositionManager is
     ERC721Permit_v4,
     IMMPositionManager,
     ReentrancyLock,
     Multicall_v4,
     Permit2Forwarder,
     BaseActionsRouter,
     FietNativeWrapper,
     PositionManagerEntrypoint
 {
     /// @dev Aggregates constructor dependencies so unoptimised builds avoid stack-too-deep in the inheritance init list.
     struct MMPositionManagerInit {
         IPoolManager poolManager;
         address marketFactory;
         address vtsOrchestrator;
         address canonicalCustody;
         address descriptor;
         IWETH9 weth9;
         IAllowanceTransfer permit2;
         address actionsImpl;
         /// @notice Stateless deployer for `MMQueueCustodian` (authorises callers via `marketFactory.bounds`).
         address queueCustodianFactory;
     }
 
     using MMCalldataDecoder for bytes;
     using CurrencyTransfer for Currency;
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Events
     // ═══════════════════════════════════════════════════════════════════════════
 
     event SignalCommitted(uint256 tokenId);
     event SignalDecommitted(uint256 tokenId, uint256 positionCount);
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Immutables
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice The implementation contract for position operations
     address public immutable commitmentDescriptor;
     /// @notice Deploys queue custodians; only factory-bound MMPMs may call `deploy` on it.
     address public immutable queueCustodianFactory;
     /// @notice One queue custodian per beneficiary domain (locker / seizer); immutable beneficiary inside the custodian.
     mapping(address recipient => address) public custodianFor;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Constructor
     // ═══════════════════════════════════════════════════════════════════════════
 
     constructor(MMPositionManagerInit memory p)
         ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
         BaseActionsRouter(p.poolManager)
         Permit2Forwarder(p.permit2)
         FietNativeWrapper(p.weth9)
         PositionManagerEntrypoint(p.marketFactory, p.vtsOrchestrator, p.canonicalCustody, p.actionsImpl)
     {
         if (p.queueCustodianFactory == address(0) || p.queueCustodianFactory.code.length == 0) {
             revert Errors.InvalidAddress(p.queueCustodianFactory);
         }
         commitmentDescriptor = p.descriptor;
         queueCustodianFactory = p.queueCustodianFactory;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Modifiers
     // ═══════════════════════════════════════════════════════════════════════════
 
     modifier checkDeadline(uint256 deadline) {
         _checkDeadline(deadline);
         _;
     }
 
     function _checkDeadline(uint256 deadline) internal view {
         if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);
     }
 
     /// @notice Requires PoolManager to be locked (not within an active batch)
     modifier onlyIfPoolManagerLocked() {
         _onlyIfPoolManagerLocked();
         _;
     }
 
     function _onlyIfPoolManagerLocked() internal view {
         if (poolManager.isUnlocked()) revert Errors.PoolManagerMustBeLocked();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // BaseActionsRouter Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc BaseActionsRouter
     function msgSender() public view override(BaseActionsRouter, PositionManagerBase) returns (address) {
         return _getLocker();
     }
 
     /// @dev Deploys `MMQueueCustodian` for `recipient` when absent (`INITIALISE`, tests).
     ///      There is no lazy deployment on unwrap/collect: queue-forward paths require `custodianFor[recipient] != 0`
     ///      (see `INVARIANTS.md`); integrators must call `INITIALISE` (or rely on tests) before those flows.
     function _deployQueueCustodian(address recipient) internal {
         if (recipient == address(0)) revert Errors.InvalidAddress(recipient);
         if (custodianFor[recipient] != address(0)) return;
         address ca = IMMQueueCustodianFactory(queueCustodianFactory).deploy(recipient, marketFactory);
         if (ca == address(0) || ca.code.length == 0) revert Errors.InvalidAddress(ca);
         custodianFor[recipient] = ca;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _canonicalMarketFactory() internal view override returns (IMarketFactory) {
         return marketFactory;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _liquidityHub() internal view override returns (ILiquidityHub) {
         return liquidityHub;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _isCustodian(address candidate) internal view override returns (bool) {
         if (candidate.code.length == 0) return false;
         (bool ok, bytes memory data) = candidate.staticcall(abi.encodeCall(IMMQueueCustodian.beneficiary, ()));
         if (!ok || data.length < 32) return false;
         address beneficiary = abi.decode(data, (address));
         if (beneficiary == address(0)) return false;
         return custodianFor[beneficiary] == candidate;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Entry Points with Hooks
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Executes a batch of liquidity modifications
     /// @dev Mirrors v4 PositionManager.modifyLiquidities
     function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
         external
         payable
         isNotLocked
         checkDeadline(deadline)
     {
         _beforeBatch();
         _executeActions(unlockData);
         _afterBatch();
     }
 
     /// @notice Executes actions without acquiring a new unlock
     /// @dev Mirrors v4 PositionManager.modifyLiquiditiesWithoutUnlock
     function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params)
         external
         payable
         isNotLocked
     {
         _beforeBatch();
         _executeActionsWithoutUnlock(actions, params);
         _afterBatch();
     }
 
     /// @notice Get the next token ID that will be assigned
     /// @dev Returns the next commit ID from VTSOrchestrator, matching Uniswap PositionManager interface
     /// @return The next token ID (will be assigned on next commitSignal call)
     function nextTokenId() public view returns (uint256) {
         return vtsOrchestrator.nextCommitId();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Action Routing (Comparison-Based)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles action execution with comparison-based routing
     /// @dev Actions <= SETTLE_POSITION_FROM_DELTAS delegate to impl (position operations)
     /// @dev Actions >= COMMIT_SIGNAL and < TAKE handled locally (commitments)
     /// @dev Actions >= TAKE handled locally (utilities)
     /// @dev Seizure deposit gating for SETTLE_POSITION and SETTLE_POSITION_FROM_DELTAS lives in the impl, not here;
     ///      this router delegates those checks to the same delegatecall module that performs onMMSettle and carry or
     ///      liquidity coupling (see MMPositionManager contract-level dev notes above).
     function _handleAction(uint256 action, bytes calldata params) internal virtual override {
         // Position actions (<= SETTLE_POSITION_FROM_DELTAS) → delegate to impl
         if (action <= MMActions.SETTLE_POSITION_FROM_DELTAS) {
             _delegateToImpl(abi.encodeWithSelector(IMMActionsImpl.handleAction.selector, action, params));
             return;
         }
 
         // Commitment actions (>= COMMIT_SIGNAL and < TAKE) → handle locally
         if (action >= MMActions.COMMIT_SIGNAL && action < MMActions.TAKE) {
             _handleCommitmentAction(action, params);
             return;
         }
 
         // Currency/utility actions (>= TAKE) → handle locally
         _handleUtilityAction(action, params);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Commitment Actions (ERC721 + Signal Management)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles commitment-level actions
     /// @param action The action code
     /// @param params The encoded parameters for the action
     function _handleCommitmentAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.COMMIT_SIGNAL) {
             (bytes calldata liquiditySignal, bytes calldata relayParams) = params.decodeCommitSignalParams();
             _commitSignal(liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.RENEW_SIGNAL) {
             (uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) =
                 params.decodeTokenIdAndBytes();
             _renewSignal(tokenId, liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.DECOMMIT_SIGNAL) {
             uint256 tokenId = params.decodeDecommitSignalParams();
             _decommitSignal(tokenId);
             return;
         }
         if (action == MMActions.CHECKPOINT) {
             (uint256 tokenId, uint256 positionIndex, bool withCommitment) = params.decodeCheckpointParams();
             _checkpoint(tokenId, positionIndex, withCommitment);
             return;
         }
         if (action == MMActions.EXTEND_GRACE_PERIOD) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint8 settlementTokenIndex,
                 uint32 verifierIndex,
                 bytes calldata settlementProof
             ) = params.decodeExtendGracePeriodParams();
             _extendGracePeriod(poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @notice Commits a liquidity signal and mints a commitment NFT
     /// @dev Fresh commit is owner-authenticated: VRL sees `signal.mmState.owner` as the proof principal.
     ///      Direct commit requires `msgSender() == mmState.owner` and mints the NFT to `mmState.owner`.
     ///      Relayed commit passes EIP-712 `RelayAuth.sender` as this `sender` (`address(0)` means `mmState.owner`; otherwise
     ///      must equal `msgSender()` here).
     /// @param liquiditySignal The ABI-encoded LiquiditySignal to verify and record
     /// @param relayParams Empty for direct commit; otherwise `(deadline, authNonce, authSig, sender)`.
     /// @return tokenId The commitment NFT id created
     function _commitSignal(bytes calldata liquiditySignal, bytes calldata relayParams)
         internal
         returns (uint256 tokenId)
     {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         address mmOwner = signal.mmState.owner;
         address nftRecipient;
 
         if (relayParams.length == 0) {
             if (msgSender() != mmOwner) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignal(marketFactory, liquiditySignal);
             _mint(mmOwner, tokenId);
             nftRecipient = mmOwner;
         } else {
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address sender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address mintRecipient = sender == address(0) ? mmOwner : sender;
             if (msgSender() != mintRecipient) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignalRelayed(
                 marketFactory, liquiditySignal, deadline, authNonce, authSig, sender
             );
             _mint(mintRecipient, tokenId);
             nftRecipient = mintRecipient;
         }
         emit SignalCommitted(tokenId);
     }
 
     /// @notice Renews an existing signal with new parameters
     /// @dev Direct renew (no relay) requires the batch locker to equal `signal.mmState.advancer`, matching ordinary
     ///      non-seizing MM ops (`locker == advancer`). Relayed renew: EIP-712 `RelayAuth.sender` must be `address(0)`
     ///      (locker must still be advancer) or `signal.mmState.advancer`; the batch locker (`msgSender()`) must match
     ///      the signed sender when non-zero, or be the advancer when the signed sender is zero.
     /// @param tokenId The commitment NFT token ID
     /// @param liquiditySignal The new liquidity signal
     function _renewSignal(uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) internal {
         if (relayParams.length == 0) {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             if (msgSender() != signal.mmState.advancer) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignal(marketFactory, tokenId, liquiditySignal);
         } else {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address relaySender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address adv = signal.mmState.advancer;
             if (msgSender() != adv && msgSender() != relaySender) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignalRelayed(
                 marketFactory, tokenId, liquiditySignal, deadline, authNonce, authSig, relaySender
             );
         }
     }
 
     /// @notice Decommits a signal and burns the commitment NFT
     /// @param tokenId The commitment NFT token ID
     function _decommitSignal(uint256 tokenId) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         // Check if commit has any active positions (burned positions are inactive)
         (,, uint256 positionCount, uint256 activePositionCount, uint256 inactiveRemnantCount) =
             vtsOrchestrator.getCommit(tokenId);
         if (activePositionCount > 0) {
             revert Errors.CommitNotEmpty(tokenId);
         }
         // Inactive positions may still hold withdrawable `pa.settled` (SETTLE-03); burning the NFT would strand it
         // because MM settlement paths require `assertApprovedOrOwner` against this tokenId. Tracked in O(1) via
         // `Commit.inactiveRemnantCount` (see VTSPositionLib._syncInactiveRemnantAfterActiveTransition /
         // `_syncInactiveRemnantAfterSettledPairChange`).
         if (inactiveRemnantCount > 0) {
             revert Errors.CommitNotDrained(tokenId);
         }
 
         _burn(tokenId);
         emit SignalDecommitted(tokenId, uint256(positionCount));
     }
 
     /// @notice Marks a checkpoint for a position, optionally running commitment backing checks
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function _checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) internal {
         vtsOrchestrator.checkpoint(tokenId, positionIndex, withCommitment);
     }
 
     /// @notice Extends grace period for a commitment via proof
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param settlementTokenIndex The settlement token index
     /// @param verifierIndex The verifier index
     /// @param settlementProof The settlement proof
     function _extendGracePeriod(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint8 settlementTokenIndex,
         uint32 verifierIndex,
         bytes calldata settlementProof
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         vtsOrchestrator.extendGracePeriod(
             marketFactory, poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof
         );
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Utility Actions (Currency Operations)
     // ═══════════════════════════════════════════════════════════════════════════
 
     function _handleUtilityAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.TAKE) {
             (Currency currency, address to, uint256 maxAmount) = params.decodeTakeParams();
             _take(currency, to, maxAmount);
             return;
         }
         if (action == MMActions.UNWRAP_LCC) {
             (address lccAddr, uint256 amount, address recipient, bool payerIsUser) = params.decodeUnwrapLccParams();
             address to = _resolveStrictRecipient(recipient);
             if (payerIsUser) {
                 _unwrapLccFromUser(lccAddr, to, amount);
             } else {
                 _unwrapLccFromDeltas(lccAddr, to, amount);
             }
             return;
         }
         if (action == MMActions.WRAP_NATIVE) {
             uint256 amount = params.decodeUint256();
             _wrapNative(amount);
             return;
         }
         if (action == MMActions.UNWRAP_NATIVE) {
             (uint256 amount, bool payerIsUser) = params.decodeUint256AndBool();
             _unwrapNative(amount, payerIsUser);
             return;
         }
         if (action == MMActions.INITIALISE) {
             params.decodeInitialiseParams();
             _deployQueueCustodian(msgSender());
             return;
         }
         if (action == MMActions.COLLECT_AVAILABLE_LIQUIDITY) {
             (address lcc, uint256 maxAmount) = params.decodeCollectLiquidityParams();
             _collectAvailableLiquidity(lcc, maxAmount);
             return;
         }
         if (action == MMActions.SYNC) {
             Currency currency = params.decodeSyncParams();
             _sync(currency);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @dev UNWRAP_LCC payout may only go to the locker or MMPM; arbitrary third-party recipients are disallowed.
     function _resolveStrictRecipient(address recipient) internal view returns (address) {
         address to = _mapRecipient(recipient);
         if (to != msgSender() && to != address(this)) {
             revert Errors.NotApproved(to);
         }
         return to;
     }
 
     /// @dev Routes unwrap through the recipient's `MMQueueCustodian`: custodian self-unwraps on Hub, then forwards immediate underlying to `forwardUnderlyingTo`.
     function _unwrapToQueueForward(
         address lccAddr,
         Currency lccCurrency,
         address forwardUnderlyingTo,
         address beneficiary,
         uint256 toUnwrap
     ) private {
         if (toUnwrap == 0) return;
         MMHelpers.assertQueueCustodianForRecipient(beneficiary);
         address custAddr = custodianFor[beneficiary];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
         lccCurrency.transfer(custAddr, toUnwrap);
         custodian.unwrapLcc(lccAddr, forwardUnderlyingTo, toUnwrap);
     }
 
     /// @notice Unwraps LCC tokens to underlying asset using deltas (locker credit)
     /// @dev Native-backed LCC: custodian receives ETH from Hub during `unwrap`, then forwards to MMPM in the same call
     ///      (locker `receive()` does not run during Hub execution). The locker receives native credit and must
     ///      `TAKE(ADDRESS_ZERO, ...)` to withdraw ETH.
     function _unwrapLccFromDeltas(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         // Native: forward immediate underlying to MMPM; ERC20: forward per `to`.
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         uint256 toUnwrap = vtsOrchestrator.take(lccCurrency, msgSender(), requested);
 
         if (toUnwrap > 0) {
             address beneficiary = msgSender();
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, beneficiary, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
 
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
     }
 
     /// @notice Unwraps LCC tokens to underlying asset by pulling from the locker/user
     /// @dev Native-backed LCC: custodian forwards ETH to MMPM after Hub `unwrap`; see `_unwrapLccFromDeltas` NatSpec.
     ///      Split into a private helper to avoid stack-too-deep in unoptimised builds.
     function _unwrapLccFromUser(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         address payer = msgSender();
         uint256 toUnwrap = lcc.balanceOf(payer);
         if (requested > 0) {
             toUnwrap = Math.min(toUnwrap, requested);
         }
 
         return _unwrapLccFromUserWithAmount(lccAddr, lccCurrency, to, payer, toUnwrap, isNativeUnderlying, underlying);
     }
 
     /// @dev Pull, unwrap-to-queue, and credit; isolated to keep `_unwrapLccFromUser` stack shallow.
     function _unwrapLccFromUserWithAmount(
         address lccAddr,
         Currency lccCurrency,
         address to,
         address payer,
         uint256 toUnwrap,
         bool isNativeUnderlying,
         address underlying
     ) private returns (uint256 unwrapped) {
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         if (toUnwrap > 0) {
             // Pull only from the locker/user (never arbitrary third parties).
             // Snapshot queue *after* transfer: non-protocol -> protocol triggers annulment of queued
             // settlement (LCC-02), so the baseline for this unwrap's incremental queue must be post-annul.
             lccCurrency.transferFrom(payer, address(this), toUnwrap);
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, payer, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
     }
 
     /// @notice Collects available queue liquidity for `msgSender()`’s custodian: settles the Hub queue when needed,
     ///         then releases underlying to this contract and credits the locker (withdraw via `TAKE`).
     /// @dev When the Hub queue was already cleared via permissionless `processSettlementFor`, releases from underlying
     ///      already held on the custodian (bounded per **HUB-02A** accounting).
     function _collectAvailableLiquidity(address lcc, uint256 maxAmount) internal {
         if (maxAmount == 0) return;
 
         address locker = msgSender();
         MMHelpers.assertQueueCustodianForRecipient(locker);
         address custAddr = custodianFor[locker];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         if (IMMQueueCustodian(custAddr).beneficiary() != locker) {
             revert Errors.InvalidSender();
         }
 
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
 
         // One `ILCC.underlying()` read per collect; thread through balance + credit helpers (avoids repeated staticcalls).
         address underlyingAddr = ILCC(lcc).underlying();
         bool isNativeUnderlying = underlyingAddr == address(0);
 
         uint256 remaining =
             _collectSettleHubQueueForCustodian(custodian, custAddr, lcc, underlyingAddr, isNativeUnderlying, maxAmount);
         _releasePreSettledCustodianUnderlying(custodian, custAddr, lcc, underlyingAddr, isNativeUnderlying, remaining);
     }
 
     /// @dev Credits the batch locker by an exact underlying amount after custodian→manager transfer (no balance-wide sync).
     function _creditLockerExactUnderlyingRelease(address underlyingAddr, uint256 amount, bool isNativeUnderlying)
         private
     {
         if (amount == 0) return;
         if (isNativeUnderlying) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
         } else {
             _creditExact(Currency.wrap(underlyingAddr), amount);
         }
     }
 
     /// @dev Native or ERC20 underlying balance held by `custAddr` for the settlement asset (`underlyingAddr` / `isNative`).
     function _custodianUnderlyingBalance(address custAddr, address underlyingAddr, bool isNativeUnderlying)
         private
         view
         returns (uint256)
     {
         if (isNativeUnderlying) {
             return custAddr.balance;
         }
         return IERC20(underlyingAddr).balanceOf(custAddr);
     }
 
     /// @dev Phase 1: settle live Hub queue where possible; returns remaining collect budget (underlying units).
     function _collectSettleHubQueueForCustodian(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         address underlyingAddr,
         bool isNativeUnderlying,
         uint256 maxAmount
     ) private returns (uint256 remaining) {
         uint256 hubQ = liquidityHub.settleQueue(lcc, custAddr);
         (, uint256 holderBal) = ILCC(lcc).balancesOf(custAddr);
         (, uint256 reserveMarket) = liquidityHub.reserveOfUnderlyingTuple(lcc);
 
         uint256 settleAmount = maxAmount;
         settleAmount = Math.min(settleAmount, hubQ);
         settleAmount = Math.min(settleAmount, holderBal);
         settleAmount = Math.min(settleAmount, reserveMarket);
 
         if (settleAmount == 0) return maxAmount;
 
         uint256 uBefore = _custodianUnderlyingBalance(custAddr, underlyingAddr, isNativeUnderlying);
         liquidityHub.processSettlementFor(lcc, custAddr, settleAmount);
         uint256 uAfter = _custodianUnderlyingBalance(custAddr, underlyingAddr, isNativeUnderlying);
         uint256 delivered = uAfter > uBefore ? uAfter - uBefore : 0;
 
         if (delivered > 0) {
             custodian.release(lcc, delivered);
             _creditLockerExactUnderlyingRelease(underlyingAddr, delivered, isNativeUnderlying);
         }
 
         uint256 consumed = delivered;
         unchecked {
             return maxAmount > consumed ? maxAmount - consumed : 0;
         }
     }
 
     /// @dev Phase 2: flush underlying already on the custodian (e.g. permissionless pre-settlement), up to budget.
     function _releasePreSettledCustodianUnderlying(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         address underlyingAddr,
         bool isNativeUnderlying,
         uint256 remaining
     ) private {
         if (remaining == 0) return;
 
         uint256 uBal = _custodianUnderlyingBalance(custAddr, underlyingAddr, isNativeUnderlying);
         uint256 releaseAmount = Math.min(remaining, uBal);
 
         if (releaseAmount > 0) {
             custodian.release(lcc, releaseAmount);
             _creditLockerExactUnderlyingRelease(underlyingAddr, releaseAmount, isNativeUnderlying);
         }
     }
 
     /// @notice Syncs currency balance as credit to delta
     /// @param currency The currency to sync
     /// @dev owner is always address(this) (MMPM) and target is always msgSender() (locker)
     function _sync(Currency currency) internal {
-        // Native ETH sync must be source-aware (exact amount) and is handled by dedicated flows.
-        if (currency == CurrencyLibrary.ADDRESS_ZERO) {
-            revert Errors.InvalidAddress(address(0));
-        }
-        vtsOrchestrator.sync(marketFactory, currency, address(this), msgSender());
+        // Public balance-wide SYNC is disabled to prevent omnibus-balance re-attribution across lockers.
+        // Use exact-credit flows that measure delivered amounts instead.
+        revert Errors.UnsupportedAction(MMActions.SYNC);
     }
 
     /// @notice Wraps native ETH to WETH
     /// @param amount The amount of ETH to wrap (0 for max available from deltas)
     function _wrapNative(uint256 amount) internal {
         uint256 takeAmount = vtsOrchestrator.take(CurrencyLibrary.ADDRESS_ZERO, msgSender(), amount);
         if (amount > 0 && amount > takeAmount) {
             revert Errors.InsufficientBalance(takeAmount, amount);
         } else if (amount == 0) {
             amount = takeAmount;
         }
         if (amount == 0) {
             return;
         }
 
         _wrap(amount);
         Currency weth = Currency.wrap(address(WETH9));
         _syncBalanceAsCredit(weth);
     }
 
     /// @notice Unwraps WETH to native ETH
     /// @param amount The amount of WETH to unwrap (0 for max)
     /// @param payerIsUser Whether the payer is the user (true) or deltas (false)
     function _unwrapNative(uint256 amount, bool payerIsUser) internal {
         Currency weth = Currency.wrap(address(WETH9));
         if (payerIsUser) {
             address payer = msgSender();
             if (amount == 0) {
                 amount = weth.balanceOf(payer);
             }
             // Use CurrencyTransfer with Permit2 fallback for user transfers
             weth.transferFrom(payer, address(this), amount);
         } else {
             uint256 takeAmount = vtsOrchestrator.take(weth, msgSender(), amount);
             if (amount > 0 && amount > takeAmount) {
                 revert Errors.InsufficientBalance(takeAmount, amount);
             } else if (amount == 0) {
                 amount = takeAmount;
             }
             if (amount == 0) {
                 return;
             }
         }
         _unwrap(amount);
         _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Returns the token URI for a given token id using the commitment descriptor contract
     function tokenURI(uint256 tokenId) public view override returns (string memory) {
         if (commitmentDescriptor == address(0)) {
             revert Errors.CommitmentDescriptorNotSet();
         }
         return ICommitmentDescriptor(commitmentDescriptor).tokenURI(tokenId);
     }
 
     /// @dev Overrides transferFrom to revert if pool manager is locked
     /// @dev Prevents transfers while an unlock session is active (mid-batch)
     function transferFrom(address from, address to, uint256 id) public virtual override onlyIfPoolManagerLocked {
         super.transferFrom(from, to, id);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // View Functions (delegate to impl via staticcall)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPosition(uint256 tokenId, uint256 positionIndex)
         external
         view
         returns (
             Position memory, /* position */
             PositionId /* positionId */
         )
     {
         return vtsOrchestrator.getPosition(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPositionId(uint256 tokenId, uint256 positionIndex) external view returns (PositionId) {
         return vtsOrchestrator.getPositionId(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     function commitOf(uint256 tokenId)
         external
         view
         returns (
             MarketMaker.State memory state,
             uint256 expiresAt,
             uint256 positionCount,
             uint256 activePositionCount,
             uint256 inactiveRemnantCount
         )
     {
         return vtsOrchestrator.getCommit(tokenId);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // No-Locking Checkpoint Functions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Marks a checkpoint for a single position, optionally running backing checks
     /// @param tokenId The ERC721 token id (commitment NFT id)
     /// @param positionIndex The index of the position within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) external onlyIfPoolManagerLocked {
         _checkpoint(tokenId, positionIndex, withCommitment);
     }
 }
```

# Related findings

## [Medium] Missing canonical LCC/hub validation and ERC20 balance-wide sync in UNWRAP_LCC in MMPositionManager causes arbitrary external call surface and potential misattribution/drain of ambient ERC20

### Description

MMPositionManager’s [UNWRAP_LCC path](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionManager.sol#L404-L414) accepts any LCC address and relies on ILCC(lcc).hub() for unwraps, enabling calls into arbitrary external hubs. In the ERC20 branch, when unwrapped funds are sent to the manager, the code credits the locker via a balance-wide sync, aligning the locker’s credit to the manager’s entire ERC20 balance instead of the increment. This creates a brittle accounting surface and, if ambient ERC20 exists on the manager, allows a locker to withdraw it.

The [UNWRAP_LCC utility in MMPositionManager](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionManager.sol#L404-L414) does not verify that the user-supplied lccAddr is a canonical LCC for the factory, nor that ILCC(lcc).hub() matches the canonical LiquidityHub. It forwards the unwrap to [MMQueueCustodian.unwrapLcc](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionManager.sol#L464-L465), which also trusts ILCC(lcc).hub() and calls [hub.unwrap(lcc, amount)](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMQueueCustodian.sol#L65-L73) on whatever hub the token returns, exposing a trusted flow to arbitrary external contracts. After an unwrap that delivers ERC20 underlying to the manager (recipient = address(this)), MMPositionManager credits the locker using [_syncBalanceAsCredit(Currency.wrap(underlying))](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionManager.sol#L494). That function [aligns the locker’s delta to the manager’s entire current ERC20 balance](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/OwnerCurrencyDelta.sol#L177-L195), not the increment just unwrapped. If ambient ERC20 is present on the manager, this can result in misattribution and withdrawal of those funds by the locker via TAKE. While the ambient-balance drain is also achievable via the public SYNC + TAKE utilities without using UNWRAP_LCC, the missing canonicalization and the balance-wide sync in the UNWRAP_LCC path are correctness/safety issues that should be fixed by enforcing canonical LCC/hub and crediting the exact unwrapped amount.

### Severity

**Impact Explanation:** [High] If ambient ERC20 exists on the manager, a locker can withdraw principal assets from the manager by inducing a balance-wide sync and then taking the funds; additionally, arbitrary external call exposure can disrupt expected unwrap behavior.

**Likelihood Explanation:** [Low] The principal-loss scenario depends on an uncommon state (ambient ERC20 remaining on the manager across transactions), typically avoidable with good operational hygiene; the arbitrary external call/DoS scenarios require the attacker to supply a malicious token address and primarily affect their own call path.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Drain ambient ERC20 on the manager via [UNWRAP_LCC ERC20 branch](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionManager.sol#L475-L485): attacker unwraps a minimal amount of canonical LCC backed by token U to the manager; because unwrapped > 0, the code performs a [balance-wide sync for U](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionManager.sol#L494), aligning the attacker’s credit to the manager’s entire U balance, then attacker [TAKEs U](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L95) to withdraw ambient funds.
#### Preconditions / Assumptions
- (a). Ambient ERC20 balance U > 0 exists on MMPositionManager (address(this)).
- (b). Attacker has INITIALISEd to create their custodian.
- (c). Attacker holds minimal canonical LCC backed by ERC20 U and approves MMPM.
- (d). UNWRAP_LCC is called with recipient = address(this), payerIsUser = true.

### Scenario 2.
Arbitrary external call surface: attacker supplies a fake ILCC whose hub() returns an attacker-controlled contract; UNWRAP_LCC forwards unwrap to the custodian, which calls the attacker hub’s unwrap(), allowing arbitrary external code execution in a permissioned path and potential DoS of the unwrap flow.
#### Preconditions / Assumptions
- (a). Attacker deploys a fake ILCC with hub() returning an attacker-controlled hub contract.
- (b). Attacker holds/approves the fake ILCC to MMPM and calls UNWRAP_LCC with that address.

### Scenario 3.
Queue/accounting confusion DoS: with a fake LCC/hub, the attacker manipulates settleQueue reads around unwrap to induce inconsistent queued deltas, triggering InsufficientBalance checks and reverting the unwrap, disrupting the UNWRAP_LCC utility.
#### Preconditions / Assumptions
- (a). Attacker deploys a fake ILCC and fake hub that can control settleQueue responses and revert behavior.
- (b). Attacker calls UNWRAP_LCC using the fake LCC.

### Proposed fix

#### MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionManager.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {ERC721Permit_v4} from "v4-periphery/src/base/ERC721Permit_v4.sol";
 import {ReentrancyLock} from "v4-periphery/src/base/ReentrancyLock.sol";
 import {Multicall_v4} from "v4-periphery/src/base/Multicall_v4.sol";
 import {BaseActionsRouter} from "v4-periphery/src/base/BaseActionsRouter.sol";
 import {FietNativeWrapper} from "./modules/NativeWrapper.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 import {PositionId, Position} from "./types/Position.sol";
 import {LiquiditySignal} from "./types/Commit.sol";
 import {MarketMaker} from "./libraries/MarketMaker.sol";
 import {ICommitmentDescriptor} from "./interfaces/ICommitmentDescriptor.sol";
 import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
 import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
 import {PositionManagerEntrypoint} from "./modules/PositionManagerEntrypoint.sol";
 import {Permit2Forwarder} from "v4-periphery/src/base/Permit2Forwarder.sol";
 import {MMActions} from "./libraries/MMActions.sol";
 import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
 import {MMHelpers} from "./libraries/MMHelpers.sol";
 import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {IMMQueueCustodianFactory} from "./interfaces/IMMQueueCustodianFactory.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
 
 /// @title MMPositionManager
 /// @notice Entry point for VRL commitment position management
 /// @dev Handles commitment lifecycle (ERC721) and utility operations locally
 /// @dev Delegates position operations to `MMPositionActionsImpl` via delegatecall (`_delegateToImpl`).
 /// @dev Seizure economics coupling (AUTH-01A): settle-only *deposits* that can reach `onMMSettle(isSeizing=true)`
 ///      without a paired liquidity decrease are rejected in the impl — including the protocol-credit branch of
 ///      `SETTLE_POSITION_FROM_DELTAS` and raw `SETTLE_POSITION` deposits — so seizure carry cannot be advanced in
 ///      isolation from `_decreaseInternal`. Only the primary settle nested inside `SEIZE_POSITION` is allow-listed
 ///      for that phase via `TransientSlots` (cleared in `_afterBatch`).
 contract MMPositionManager is
     ERC721Permit_v4,
     IMMPositionManager,
     ReentrancyLock,
     Multicall_v4,
     Permit2Forwarder,
     BaseActionsRouter,
     FietNativeWrapper,
     PositionManagerEntrypoint
 {
     /// @dev Aggregates constructor dependencies so unoptimised builds avoid stack-too-deep in the inheritance init list.
     struct MMPositionManagerInit {
         IPoolManager poolManager;
         address marketFactory;
         address vtsOrchestrator;
         address canonicalCustody;
         address descriptor;
         IWETH9 weth9;
         IAllowanceTransfer permit2;
         address actionsImpl;
         /// @notice Stateless deployer for `MMQueueCustodian` (authorises callers via `marketFactory.bounds`).
         address queueCustodianFactory;
     }
 
     using MMCalldataDecoder for bytes;
     using CurrencyTransfer for Currency;
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Events
     // ═══════════════════════════════════════════════════════════════════════════
 
     event SignalCommitted(uint256 tokenId);
     event SignalDecommitted(uint256 tokenId, uint256 positionCount);
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Immutables
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice The implementation contract for position operations
     address public immutable commitmentDescriptor;
     /// @notice Deploys queue custodians; only factory-bound MMPMs may call `deploy` on it.
     address public immutable queueCustodianFactory;
     /// @notice One queue custodian per beneficiary domain (locker / seizer); immutable beneficiary inside the custodian.
     mapping(address recipient => address) public custodianFor;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Constructor
     // ═══════════════════════════════════════════════════════════════════════════
 
     constructor(MMPositionManagerInit memory p)
         ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
         BaseActionsRouter(p.poolManager)
         Permit2Forwarder(p.permit2)
         FietNativeWrapper(p.weth9)
         PositionManagerEntrypoint(p.marketFactory, p.vtsOrchestrator, p.canonicalCustody, p.actionsImpl)
     {
         if (p.queueCustodianFactory == address(0) || p.queueCustodianFactory.code.length == 0) {
             revert Errors.InvalidAddress(p.queueCustodianFactory);
         }
         commitmentDescriptor = p.descriptor;
         queueCustodianFactory = p.queueCustodianFactory;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Modifiers
     // ═══════════════════════════════════════════════════════════════════════════
 
     modifier checkDeadline(uint256 deadline) {
         _checkDeadline(deadline);
         _;
     }
 
     function _checkDeadline(uint256 deadline) internal view {
         if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);
     }
 
     /// @notice Requires PoolManager to be locked (not within an active batch)
     modifier onlyIfPoolManagerLocked() {
         _onlyIfPoolManagerLocked();
         _;
     }
 
     function _onlyIfPoolManagerLocked() internal view {
         if (poolManager.isUnlocked()) revert Errors.PoolManagerMustBeLocked();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // BaseActionsRouter Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc BaseActionsRouter
     function msgSender() public view override(BaseActionsRouter, PositionManagerBase) returns (address) {
         return _getLocker();
     }
 
     /// @dev Deploys `MMQueueCustodian` for `recipient` when absent (`INITIALISE`, tests).
     ///      There is no lazy deployment on unwrap/collect: queue-forward paths require `custodianFor[recipient] != 0`
     ///      (see `INVARIANTS.md`); integrators must call `INITIALISE` (or rely on tests) before those flows.
     function _deployQueueCustodian(address recipient) internal {
         if (recipient == address(0)) revert Errors.InvalidAddress(recipient);
         if (custodianFor[recipient] != address(0)) return;
         address ca = IMMQueueCustodianFactory(queueCustodianFactory).deploy(recipient, marketFactory);
         if (ca == address(0) || ca.code.length == 0) revert Errors.InvalidAddress(ca);
         custodianFor[recipient] = ca;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _canonicalMarketFactory() internal view override returns (IMarketFactory) {
         return marketFactory;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _liquidityHub() internal view override returns (ILiquidityHub) {
         return liquidityHub;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _isCustodian(address candidate) internal view override returns (bool) {
         if (candidate.code.length == 0) return false;
         (bool ok, bytes memory data) = candidate.staticcall(abi.encodeCall(IMMQueueCustodian.beneficiary, ()));
         if (!ok || data.length < 32) return false;
         address beneficiary = abi.decode(data, (address));
         if (beneficiary == address(0)) return false;
         return custodianFor[beneficiary] == candidate;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Entry Points with Hooks
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Executes a batch of liquidity modifications
     /// @dev Mirrors v4 PositionManager.modifyLiquidities
     function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
         external
         payable
         isNotLocked
         checkDeadline(deadline)
     {
         _beforeBatch();
         _executeActions(unlockData);
         _afterBatch();
     }
 
     /// @notice Executes actions without acquiring a new unlock
     /// @dev Mirrors v4 PositionManager.modifyLiquiditiesWithoutUnlock
     function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params)
         external
         payable
         isNotLocked
     {
         _beforeBatch();
         _executeActionsWithoutUnlock(actions, params);
         _afterBatch();
     }
 
     /// @notice Get the next token ID that will be assigned
     /// @dev Returns the next commit ID from VTSOrchestrator, matching Uniswap PositionManager interface
     /// @return The next token ID (will be assigned on next commitSignal call)
     function nextTokenId() public view returns (uint256) {
         return vtsOrchestrator.nextCommitId();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Action Routing (Comparison-Based)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles action execution with comparison-based routing
     /// @dev Actions <= SETTLE_POSITION_FROM_DELTAS delegate to impl (position operations)
     /// @dev Actions >= COMMIT_SIGNAL and < TAKE handled locally (commitments)
     /// @dev Actions >= TAKE handled locally (utilities)
     /// @dev Seizure deposit gating for SETTLE_POSITION and SETTLE_POSITION_FROM_DELTAS lives in the impl, not here;
     ///      this router delegates those checks to the same delegatecall module that performs onMMSettle and carry or
     ///      liquidity coupling (see MMPositionManager contract-level dev notes above).
     function _handleAction(uint256 action, bytes calldata params) internal virtual override {
         // Position actions (<= SETTLE_POSITION_FROM_DELTAS) → delegate to impl
         if (action <= MMActions.SETTLE_POSITION_FROM_DELTAS) {
             _delegateToImpl(abi.encodeWithSelector(IMMActionsImpl.handleAction.selector, action, params));
             return;
         }
 
         // Commitment actions (>= COMMIT_SIGNAL and < TAKE) → handle locally
         if (action >= MMActions.COMMIT_SIGNAL && action < MMActions.TAKE) {
             _handleCommitmentAction(action, params);
             return;
         }
 
         // Currency/utility actions (>= TAKE) → handle locally
         _handleUtilityAction(action, params);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Commitment Actions (ERC721 + Signal Management)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles commitment-level actions
     /// @param action The action code
     /// @param params The encoded parameters for the action
     function _handleCommitmentAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.COMMIT_SIGNAL) {
             (bytes calldata liquiditySignal, bytes calldata relayParams) = params.decodeCommitSignalParams();
             _commitSignal(liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.RENEW_SIGNAL) {
             (uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) =
                 params.decodeTokenIdAndBytes();
             _renewSignal(tokenId, liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.DECOMMIT_SIGNAL) {
             uint256 tokenId = params.decodeDecommitSignalParams();
             _decommitSignal(tokenId);
             return;
         }
         if (action == MMActions.CHECKPOINT) {
             (uint256 tokenId, uint256 positionIndex, bool withCommitment) = params.decodeCheckpointParams();
             _checkpoint(tokenId, positionIndex, withCommitment);
             return;
         }
         if (action == MMActions.EXTEND_GRACE_PERIOD) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint8 settlementTokenIndex,
                 uint32 verifierIndex,
                 bytes calldata settlementProof
             ) = params.decodeExtendGracePeriodParams();
             _extendGracePeriod(poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @notice Commits a liquidity signal and mints a commitment NFT
     /// @dev Fresh commit is owner-authenticated: VRL sees `signal.mmState.owner` as the proof principal.
     ///      Direct commit requires `msgSender() == mmState.owner` and mints the NFT to `mmState.owner`.
     ///      Relayed commit passes EIP-712 `RelayAuth.sender` as this `sender` (`address(0)` means `mmState.owner`; otherwise
     ///      must equal `msgSender()` here).
     /// @param liquiditySignal The ABI-encoded LiquiditySignal to verify and record
     /// @param relayParams Empty for direct commit; otherwise `(deadline, authNonce, authSig, sender)`.
     /// @return tokenId The commitment NFT id created
     function _commitSignal(bytes calldata liquiditySignal, bytes calldata relayParams)
         internal
         returns (uint256 tokenId)
     {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         address mmOwner = signal.mmState.owner;
         address nftRecipient;
 
         if (relayParams.length == 0) {
             if (msgSender() != mmOwner) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignal(marketFactory, liquiditySignal);
             _mint(mmOwner, tokenId);
             nftRecipient = mmOwner;
         } else {
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address sender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address mintRecipient = sender == address(0) ? mmOwner : sender;
             if (msgSender() != mintRecipient) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignalRelayed(
                 marketFactory, liquiditySignal, deadline, authNonce, authSig, sender
             );
             _mint(mintRecipient, tokenId);
             nftRecipient = mintRecipient;
         }
         emit SignalCommitted(tokenId);
     }
 
     /// @notice Renews an existing signal with new parameters
     /// @dev Direct renew (no relay) requires the batch locker to equal `signal.mmState.advancer`, matching ordinary
     ///      non-seizing MM ops (`locker == advancer`). Relayed renew: EIP-712 `RelayAuth.sender` must be `address(0)`
     ///      (locker must still be advancer) or `signal.mmState.advancer`; the batch locker (`msgSender()`) must match
     ///      the signed sender when non-zero, or be the advancer when the signed sender is zero.
     /// @param tokenId The commitment NFT token ID
     /// @param liquiditySignal The new liquidity signal
     function _renewSignal(uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) internal {
         if (relayParams.length == 0) {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             if (msgSender() != signal.mmState.advancer) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignal(marketFactory, tokenId, liquiditySignal);
         } else {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address relaySender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address adv = signal.mmState.advancer;
             if (msgSender() != adv && msgSender() != relaySender) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignalRelayed(
                 marketFactory, tokenId, liquiditySignal, deadline, authNonce, authSig, relaySender
             );
         }
     }
 
     /// @notice Decommits a signal and burns the commitment NFT
     /// @param tokenId The commitment NFT token ID
     function _decommitSignal(uint256 tokenId) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         // Check if commit has any active positions (burned positions are inactive)
         (,, uint256 positionCount, uint256 activePositionCount, uint256 inactiveRemnantCount) =
             vtsOrchestrator.getCommit(tokenId);
         if (activePositionCount > 0) {
             revert Errors.CommitNotEmpty(tokenId);
         }
         // Inactive positions may still hold withdrawable `pa.settled` (SETTLE-03); burning the NFT would strand it
         // because MM settlement paths require `assertApprovedOrOwner` against this tokenId. Tracked in O(1) via
         // `Commit.inactiveRemnantCount` (see VTSPositionLib._syncInactiveRemnantAfterActiveTransition /
         // `_syncInactiveRemnantAfterSettledPairChange`).
         if (inactiveRemnantCount > 0) {
             revert Errors.CommitNotDrained(tokenId);
         }
 
         _burn(tokenId);
         emit SignalDecommitted(tokenId, uint256(positionCount));
     }
 
     /// @notice Marks a checkpoint for a position, optionally running commitment backing checks
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function _checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) internal {
         vtsOrchestrator.checkpoint(tokenId, positionIndex, withCommitment);
     }
 
     /// @notice Extends grace period for a commitment via proof
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param settlementTokenIndex The settlement token index
     /// @param verifierIndex The verifier index
     /// @param settlementProof The settlement proof
     function _extendGracePeriod(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint8 settlementTokenIndex,
         uint32 verifierIndex,
         bytes calldata settlementProof
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         vtsOrchestrator.extendGracePeriod(
             marketFactory, poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof
         );
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Utility Actions (Currency Operations)
     // ═══════════════════════════════════════════════════════════════════════════
 
     function _handleUtilityAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.TAKE) {
             (Currency currency, address to, uint256 maxAmount) = params.decodeTakeParams();
             _take(currency, to, maxAmount);
             return;
         }
         if (action == MMActions.UNWRAP_LCC) {
             (address lccAddr, uint256 amount, address recipient, bool payerIsUser) = params.decodeUnwrapLccParams();
             address to = _resolveStrictRecipient(recipient);
             if (payerIsUser) {
                 _unwrapLccFromUser(lccAddr, to, amount);
             } else {
                 _unwrapLccFromDeltas(lccAddr, to, amount);
             }
             return;
         }
         if (action == MMActions.WRAP_NATIVE) {
             uint256 amount = params.decodeUint256();
             _wrapNative(amount);
             return;
         }
         if (action == MMActions.UNWRAP_NATIVE) {
             (uint256 amount, bool payerIsUser) = params.decodeUint256AndBool();
             _unwrapNative(amount, payerIsUser);
             return;
         }
         if (action == MMActions.INITIALISE) {
             params.decodeInitialiseParams();
             _deployQueueCustodian(msgSender());
             return;
         }
         if (action == MMActions.COLLECT_AVAILABLE_LIQUIDITY) {
             (address lcc, uint256 maxAmount) = params.decodeCollectLiquidityParams();
             _collectAvailableLiquidity(lcc, maxAmount);
             return;
         }
         if (action == MMActions.SYNC) {
             Currency currency = params.decodeSyncParams();
             _sync(currency);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @dev UNWRAP_LCC payout may only go to the locker or MMPM; arbitrary third-party recipients are disallowed.
     function _resolveStrictRecipient(address recipient) internal view returns (address) {
         address to = _mapRecipient(recipient);
         if (to != msgSender() && to != address(this)) {
             revert Errors.NotApproved(to);
         }
         return to;
     }
 
     /// @dev Routes unwrap through the recipient's `MMQueueCustodian`: custodian self-unwraps on Hub, then forwards immediate underlying to `forwardUnderlyingTo`.
     function _unwrapToQueueForward(
         address lccAddr,
         Currency lccCurrency,
         address forwardUnderlyingTo,
         address beneficiary,
         uint256 toUnwrap
     ) private {
         if (toUnwrap == 0) return;
         MMHelpers.assertQueueCustodianForRecipient(beneficiary);
         address custAddr = custodianFor[beneficiary];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
         lccCurrency.transfer(custAddr, toUnwrap);
         custodian.unwrapLcc(lccAddr, forwardUnderlyingTo, toUnwrap);
     }
 
     /// @notice Unwraps LCC tokens to underlying asset using deltas (locker credit)
     /// @dev Native-backed LCC: custodian receives ETH from Hub during `unwrap`, then forwards to MMPM in the same call
     ///      (locker `receive()` does not run during Hub execution). The locker receives native credit and must
     ///      `TAKE(ADDRESS_ZERO, ...)` to withdraw ETH.
     function _unwrapLccFromDeltas(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
+        if (!liquidityHub.isLCC(lccAddr) || ILCC(lccAddr).hub() != address(liquidityHub)) revert Errors.InvalidAddress(lccAddr);
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         // Native: forward immediate underlying to MMPM; ERC20: forward per `to`.
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         uint256 toUnwrap = vtsOrchestrator.take(lccCurrency, msgSender(), requested);
 
         if (toUnwrap > 0) {
             address beneficiary = msgSender();
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, beneficiary, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
 
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
-            _syncBalanceAsCredit(Currency.wrap(underlying));
+            _creditExact(Currency.wrap(underlying), unwrapped);
         }
     }
 
     /// @notice Unwraps LCC tokens to underlying asset by pulling from the locker/user
     /// @dev Native-backed LCC: custodian forwards ETH to MMPM after Hub `unwrap`; see `_unwrapLccFromDeltas` NatSpec.
     ///      Split into a private helper to avoid stack-too-deep in unoptimised builds.
     function _unwrapLccFromUser(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
+        if (!liquidityHub.isLCC(lccAddr) || ILCC(lccAddr).hub() != address(liquidityHub)) revert Errors.InvalidAddress(lccAddr);
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         address payer = msgSender();
         uint256 toUnwrap = lcc.balanceOf(payer);
         if (requested > 0) {
             toUnwrap = Math.min(toUnwrap, requested);
         }
 
         return _unwrapLccFromUserWithAmount(lccAddr, lccCurrency, to, payer, toUnwrap, isNativeUnderlying, underlying);
     }
 
     /// @dev Pull, unwrap-to-queue, and credit; isolated to keep `_unwrapLccFromUser` stack shallow.
     function _unwrapLccFromUserWithAmount(
         address lccAddr,
         Currency lccCurrency,
         address to,
         address payer,
         uint256 toUnwrap,
         bool isNativeUnderlying,
         address underlying
     ) private returns (uint256 unwrapped) {
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         if (toUnwrap > 0) {
             // Pull only from the locker/user (never arbitrary third parties).
             // Snapshot queue *after* transfer: non-protocol -> protocol triggers annulment of queued
             // settlement (LCC-02), so the baseline for this unwrap's incremental queue must be post-annul.
             lccCurrency.transferFrom(payer, address(this), toUnwrap);
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, payer, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
-            _syncBalanceAsCredit(Currency.wrap(underlying));
+            _creditExact(Currency.wrap(underlying), unwrapped);
         }
     }
 
     /// @notice Collects available queue liquidity for `msgSender()`’s custodian: settles the Hub queue when needed,
     ///         then releases underlying to this contract and credits the locker (withdraw via `TAKE`).
     /// @dev When the Hub queue was already cleared via permissionless `processSettlementFor`, releases from underlying
     ///      already held on the custodian (bounded per **HUB-02A** accounting).
     function _collectAvailableLiquidity(address lcc, uint256 maxAmount) internal {
         if (maxAmount == 0) return;
 
         address locker = msgSender();
         MMHelpers.assertQueueCustodianForRecipient(locker);
         address custAddr = custodianFor[locker];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         if (IMMQueueCustodian(custAddr).beneficiary() != locker) {
             revert Errors.InvalidSender();
         }
 
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
 
         // One `ILCC.underlying()` read per collect; thread through balance + credit helpers (avoids repeated staticcalls).
+        if (!liquidityHub.isLCC(lcc) || ILCC(lcc).hub() != address(liquidityHub)) revert Errors.InvalidAddress(lcc);
         address underlyingAddr = ILCC(lcc).underlying();
         bool isNativeUnderlying = underlyingAddr == address(0);
 
         uint256 remaining =
             _collectSettleHubQueueForCustodian(custodian, custAddr, lcc, underlyingAddr, isNativeUnderlying, maxAmount);
         _releasePreSettledCustodianUnderlying(custodian, custAddr, lcc, underlyingAddr, isNativeUnderlying, remaining);
     }
 
     /// @dev Credits the batch locker by an exact underlying amount after custodian→manager transfer (no balance-wide sync).
     function _creditLockerExactUnderlyingRelease(address underlyingAddr, uint256 amount, bool isNativeUnderlying)
         private
     {
         if (amount == 0) return;
         if (isNativeUnderlying) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
         } else {
             _creditExact(Currency.wrap(underlyingAddr), amount);
         }
     }
 
     /// @dev Native or ERC20 underlying balance held by `custAddr` for the settlement asset (`underlyingAddr` / `isNative`).
     function _custodianUnderlyingBalance(address custAddr, address underlyingAddr, bool isNativeUnderlying)
         private
         view
         returns (uint256)
     {
         if (isNativeUnderlying) {
             return custAddr.balance;
         }
         return IERC20(underlyingAddr).balanceOf(custAddr);
     }
 
     /// @dev Phase 1: settle live Hub queue where possible; returns remaining collect budget (underlying units).
     function _collectSettleHubQueueForCustodian(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         address underlyingAddr,
         bool isNativeUnderlying,
         uint256 maxAmount
     ) private returns (uint256 remaining) {
         uint256 hubQ = liquidityHub.settleQueue(lcc, custAddr);
         (, uint256 holderBal) = ILCC(lcc).balancesOf(custAddr);
         (, uint256 reserveMarket) = liquidityHub.reserveOfUnderlyingTuple(lcc);
 
         uint256 settleAmount = maxAmount;
         settleAmount = Math.min(settleAmount, hubQ);
         settleAmount = Math.min(settleAmount, holderBal);
         settleAmount = Math.min(settleAmount, reserveMarket);
 
         if (settleAmount == 0) return maxAmount;
 
         uint256 uBefore = _custodianUnderlyingBalance(custAddr, underlyingAddr, isNativeUnderlying);
         liquidityHub.processSettlementFor(lcc, custAddr, settleAmount);
         uint256 uAfter = _custodianUnderlyingBalance(custAddr, underlyingAddr, isNativeUnderlying);
         uint256 delivered = uAfter > uBefore ? uAfter - uBefore : 0;
 
         if (delivered > 0) {
             custodian.release(lcc, delivered);
             _creditLockerExactUnderlyingRelease(underlyingAddr, delivered, isNativeUnderlying);
         }
 
         uint256 consumed = delivered;
         unchecked {
             return maxAmount > consumed ? maxAmount - consumed : 0;
         }
     }
 
     /// @dev Phase 2: flush underlying already on the custodian (e.g. permissionless pre-settlement), up to budget.
     function _releasePreSettledCustodianUnderlying(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         address underlyingAddr,
         bool isNativeUnderlying,
         uint256 remaining
     ) private {
         if (remaining == 0) return;
 
         uint256 uBal = _custodianUnderlyingBalance(custAddr, underlyingAddr, isNativeUnderlying);
         uint256 releaseAmount = Math.min(remaining, uBal);
 
         if (releaseAmount > 0) {
             custodian.release(lcc, releaseAmount);
             _creditLockerExactUnderlyingRelease(underlyingAddr, releaseAmount, isNativeUnderlying);
         }
     }
 
     /// @notice Syncs currency balance as credit to delta
     /// @param currency The currency to sync
     /// @dev owner is always address(this) (MMPM) and target is always msgSender() (locker)
     function _sync(Currency currency) internal {
         // Native ETH sync must be source-aware (exact amount) and is handled by dedicated flows.
         if (currency == CurrencyLibrary.ADDRESS_ZERO) {
             revert Errors.InvalidAddress(address(0));
         }
         vtsOrchestrator.sync(marketFactory, currency, address(this), msgSender());
     }
 
     /// @notice Wraps native ETH to WETH
     /// @param amount The amount of ETH to wrap (0 for max available from deltas)
     function _wrapNative(uint256 amount) internal {
         uint256 takeAmount = vtsOrchestrator.take(CurrencyLibrary.ADDRESS_ZERO, msgSender(), amount);
         if (amount > 0 && amount > takeAmount) {
             revert Errors.InsufficientBalance(takeAmount, amount);
         } else if (amount == 0) {
             amount = takeAmount;
         }
         if (amount == 0) {
             return;
         }
 
         _wrap(amount);
         Currency weth = Currency.wrap(address(WETH9));
         _syncBalanceAsCredit(weth);
     }
 
     /// @notice Unwraps WETH to native ETH
     /// @param amount The amount of WETH to unwrap (0 for max)
     /// @param payerIsUser Whether the payer is the user (true) or deltas (false)
     function _unwrapNative(uint256 amount, bool payerIsUser) internal {
         Currency weth = Currency.wrap(address(WETH9));
         if (payerIsUser) {
             address payer = msgSender();
             if (amount == 0) {
                 amount = weth.balanceOf(payer);
             }
             // Use CurrencyTransfer with Permit2 fallback for user transfers
             weth.transferFrom(payer, address(this), amount);
         } else {
             uint256 takeAmount = vtsOrchestrator.take(weth, msgSender(), amount);
             if (amount > 0 && amount > takeAmount) {
                 revert Errors.InsufficientBalance(takeAmount, amount);
             } else if (amount == 0) {
                 amount = takeAmount;
             }
             if (amount == 0) {
                 return;
             }
         }
         _unwrap(amount);
         _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Returns the token URI for a given token id using the commitment descriptor contract
     function tokenURI(uint256 tokenId) public view override returns (string memory) {
         if (commitmentDescriptor == address(0)) {
             revert Errors.CommitmentDescriptorNotSet();
         }
         return ICommitmentDescriptor(commitmentDescriptor).tokenURI(tokenId);
     }
 
     /// @dev Overrides transferFrom to revert if pool manager is locked
     /// @dev Prevents transfers while an unlock session is active (mid-batch)
     function transferFrom(address from, address to, uint256 id) public virtual override onlyIfPoolManagerLocked {
         super.transferFrom(from, to, id);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // View Functions (delegate to impl via staticcall)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPosition(uint256 tokenId, uint256 positionIndex)
         external
         view
         returns (
             Position memory, /* position */
             PositionId /* positionId */
         )
     {
         return vtsOrchestrator.getPosition(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPositionId(uint256 tokenId, uint256 positionIndex) external view returns (PositionId) {
         return vtsOrchestrator.getPositionId(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     function commitOf(uint256 tokenId)
         external
         view
         returns (
             MarketMaker.State memory state,
             uint256 expiresAt,
             uint256 positionCount,
             uint256 activePositionCount,
             uint256 inactiveRemnantCount
         )
     {
         return vtsOrchestrator.getCommit(tokenId);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // No-Locking Checkpoint Functions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Marks a checkpoint for a single position, optionally running backing checks
     /// @param tokenId The ERC721 token id (commitment NFT id)
     /// @param positionIndex The index of the position within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) external onlyIfPoolManagerLocked {
         _checkpoint(tokenId, positionIndex, withCommitment);
     }
 }
```

## [Medium] Arbitrary deficit recipient plus WETH fallback and public SYNC in MMPositionManager cause FCFS capture of misrouted settlements

### Description

[ProxyHook lets swappers set any deficit recipient](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/ProxyHook.sol#L464-L479); if set to MMPositionManager, LiquidityHub settles the claim to MMPM ([wrapping native to WETH for contracts](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/LiquidityHubLib.sol#L572-L601)). MMPM exposes a [public SYNC](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionManager.sol#L656-L663) that credits the caller with any ERC20 balance MMPM holds and [TAKE to withdraw it](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L80-L99). This enables first-come-first-served capture of misrouted settlement value; if MMPM is not bounds-enabled, funds can be stranded.

A swapper can [specify an arbitrary deficit recipient via ProxyHook hookData](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/ProxyHook.sol#L464-L479). When a deficit occurs, ProxyHook [first transfers the market-derived LCC to that recipient and then calls LiquidityHub.queueForTransferRecipient](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/ProxyHook.sol#L280-L287), which [accepts endpoint recipients that hold sufficient market-derived LCC](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/LiquidityHub.sol#L1026-L1047) (satisfied by the prior transfer). Later, LiquidityHub.processSettlementFor(lcc, recipient, maxAmount) settles the queued claim: for native-backed LCC it [wraps ETH to WETH for non-INativeSettlementReceiver contracts](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/LiquidityHubLib.sol#L572-L601) and transfers WETH to the recipient; for ERC20-backed LCC it [transfers the ERC20 directly](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/LiquidityHubLib.sol#L572-L601). If the recipient is the shared MMPositionManager (MMPM), these ERC20 balances now sit on MMPM. MMPM’s [public SYNC(currency) calls vtsOrchestrator.sync(marketFactory, currency, owner=address(this), target=msgSender())](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionManager.sol#L656-L663), crediting the caller with any MMPM-held ERC20 balance; [TAKE then withdraws it](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L80-L99). There is no provenance tie between the settlement’s rightful owner and the locker calling SYNC. Thus, misrouted settlements to MMPM can be FCFS captured by third parties. If MMPM is not bounds-enabled, SYNC reverts and funds become stuck on MMPM instead.

### Severity

**Impact Explanation:** [High] Victims can suffer direct, material loss of principal when misrouted settlements to MMPM are captured by third parties; alternatively, funds can be frozen on MMPM without a recovery path if SYNC is disallowed.

**Likelihood Explanation:** [Low] Exploitation requires the victim or integrator to misroute the deficit recipient to MMPositionManager; attackers cannot force this. Such misrouting is a user/integration error and reduces frequency.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Native-backed LCC deficit is routed to MMPositionManager; LiquidityHub settles to MMPM, [auto-wrapping ETH to WETH](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/LiquidityHubLib.sol#L572-L601); an attacker calls [SYNC(WETH)](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionManager.sol#L656-L663) and [TAKE](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L80-L99) to withdraw the WETH from MMPM, capturing the victim’s settlement.
#### Preconditions / Assumptions
- (a). MMPositionManager is bounds-enabled in the MarketFactory (endpoint or exempt)
- (b). Market has a native-backed LCC
- (c). Swapper or integrator sets deficitRecipient = MMPositionManager via ProxyHook hookData during a deficit swap
- (d). LiquidityHub has sufficient reserves at or after settlement
- (e). MMPositionManager does not implement INativeSettlementReceiver

### Scenario 2.
ERC20-backed LCC deficit is routed to MMPositionManager; LiquidityHub [settles directly in the ERC20 to MMPM](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/LiquidityHubLib.sol#L572-L601); an attacker calls [SYNC(underlyingERC20)](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionManager.sol#L656-L663) and [TAKE](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L80-L99) to withdraw the ERC20 from MMPM, capturing the victim’s settlement.
#### Preconditions / Assumptions
- (a). MMPositionManager is bounds-enabled in the MarketFactory (endpoint or exempt)
- (b). Market has an ERC20-backed LCC
- (c). Swapper or integrator sets deficitRecipient = MMPositionManager via ProxyHook hookData during a deficit swap
- (d). LiquidityHub has sufficient reserves at or after settlement

### Scenario 3.
MMPositionManager is not bounds-enabled; a deficit is routed and [settled to MMPM](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/LiquidityHub.sol#L732-L751) (WETH or ERC20); SYNC is disallowed, leaving the funds stranded on MMPM with no public recovery path.
#### Preconditions / Assumptions
- (a). MMPositionManager is not bounds-enabled in the MarketFactory
- (b). Swapper or integrator sets deficitRecipient = MMPositionManager via ProxyHook hookData during a deficit swap
- (c). LiquidityHub settles the queue to MMPositionManager

### Proposed fix

#### LiquidityHub.sol

File: `contracts/evm/src/LiquidityHub.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/LiquidityHub.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
 import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {LCCFactoryLib, LCCFactoryLinkedLib} from "./libraries/LCCFactoryLib.sol";
 import {LiquidityHubLib} from "./libraries/LiquidityHubLib.sol";
 import {LiquidityHubLinkedLib} from "./libraries/LiquidityHubLinkedLib.sol";
 import {LiquidityHubStorage, Market, UnderlyingReserve} from "./types/Liquidity.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {ICanonicalVault} from "./interfaces/ICanonicalVault.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {BoundRegistry} from "./modules/BoundRegistry.sol";
 import {Bounds} from "./libraries/Bounds.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 
 /**
  * @title LiquidityHub
  * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
  * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
  */
 contract LiquidityHub is BoundRegistry, Ownable, ReentrancyGuardTransient {
     using CurrencyTransfer for Currency;
 
     // ============ UNIFIED STATE ============
     LiquidityHubStorage internal s;
 
     IOracleHelper public immutable oracleHelper;
     IWETH9 public immutable weth9;
 
     event FactorySet(address indexed factory, bool enabled);
     event LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId);
     /// @notice New market-derived reserve recorded for this LCC's underlying; may now service queued external settlements.
     /// @dev Wake-up signal for off-chain / reactive settlement dispatch. Not net of Hub self-queue: Hub settling to
     ///      itself burns LCC and does not spend reserve, so emission must not be gated on pre-Hub queue size.
     event LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId);
     event SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementAnnulled(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementProcessed(
         address indexed lcc, address indexed recipient, uint256 settledAmount, uint256 requestedAmount
     );
     event LccWrappedWith(address indexed lcc, address indexed withLCC, address from, address to, uint256 amount);
     event LccWrapped(address indexed lcc, address from, address to, uint256 amount);
     event LccUnwrapped(address indexed lcc, address from, address to, uint256 amount);
 
     // IMPORTANT NOTE: The LiquidityHub is agnostic/unaware of the end account.
     // Similarly to how PoolManager leverages periphery contracts to manage end-account balances, the LiquidityHub aggregates balances, and uses LCCs to track account balances in a hub-and-spoke model.
 
     // Map of market factories
     mapping(address => bool) public isFactory;
 
     /**
      * @notice Constructs the LiquidityHub contract
      * @param _oracleHelper The oracle helper contract address
      * @param _nativeAssetName The name of the native asset (e.g., "Ether")
      * @param _nativeAssetSymbol The symbol of the native asset (e.g., "ETH")
      * @param _nativeAssetDecimals The decimals of the native asset (typically 18)
      * @param _weth9 Wrapped native token used for native settlement fallback
      * @param _initialOwner The initial owner of the contract
      */
     constructor(
         address _oracleHelper,
         string memory _nativeAssetName,
         string memory _nativeAssetSymbol,
         uint8 _nativeAssetDecimals,
         address _weth9,
         address _initialOwner
     ) Ownable(_initialOwner) {
         oracleHelper = IOracleHelper(_oracleHelper);
         weth9 = IWETH9(_weth9);
         LCCFactoryLib.initNativeAsset(s, _nativeAssetName, _nativeAssetSymbol, _nativeAssetDecimals);
     }
 
     /**
      * @notice Modifier to restrict access to registered factory contracts only
      */
     modifier onlyFactory() {
         _onlyFactory();
         _;
     }
 
     function _onlyFactory() internal view {
         if (!isFactory[_msgSender()]) {
             revert Errors.InvalidSender();
         }
     }
 
     /// Override from BoundRegistry
     function _lccMarket(address lcc) internal view override returns (bytes32 id, address factory) {
         Market memory market = s.lccToMarket[lcc];
         return (market.id, market.factory);
     }
 
     /// Override from BoundRegistry
     function setBoundLevel(address who, uint8 level) external override onlyFactory {
         // `BoundRegistry._setBoundLevel` enforces EXEMPT/DEX immutability and first-assignment-from-NONE.
         // The stronger policy that EXEMPT/DEX only arise from hardcoded setup / integration paths must be expressed by
         // the specific `MarketFactory` implementation using this hub; registered factories are trusted for that setup policy.
         // Queue-owner safety when moving an address into exempt remains an operational concern (not indexed on-chain).
         _setBoundLevel(msg.sender, who, level);
     }
 
     /// Override from BoundRegistry
     function setBoundLevels(address[] calldata who, uint8 level) external override onlyFactory {
         for (uint256 i = 0; i < who.length; i++) {
             _setBoundLevel(msg.sender, who[i], level);
         }
     }
 
     /**
      * @notice Modifier to ensure the provided LCC address is valid
      * @param lcc The LCC token address to validate
      */
     modifier onlyValidLcc(address lcc) {
         LiquidityHubLib.assertValidLcc(s, lcc);
         _;
     }
 
     /**
      * @notice Modifier to restrict access to issuers of a specific LCC token
      * @param lcc The LCC token address to check issuer status for
      */
     modifier onlyIssuer(address lcc) {
         _onlyIssuer(lcc);
         _;
     }
 
     function _onlyIssuer(address lcc) internal view {
         // Strict invariant: issuer-gated paths must never operate on invalid/uninitialised LCCs.
         LiquidityHubLib.assertValidLcc(s, lcc);
         if (!LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender)) {
             revert Errors.NotApproved(msg.sender);
         }
     }
 
     // ============ PUBLIC ACCESSORS ============
 
     /**
      * @notice Returns the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address, or address(0) if not found
      */
     function marketUnderlyingToLCC(bytes32 marketId, address underlying) external view returns (address) {
         return s.marketUnderlyingToLCC[marketId][underlying];
     }
 
     /**
      * @notice Returns the underlying asset address for a given LCC token
      * @param lcc The LCC token address
      * @return The underlying asset address (address(0) for native ETH)
      */
     function lccToUnderlying(address lcc) public view returns (address) {
         return s.lccToUnderlying[lcc];
     }
 
     /**
      * @notice Returns the Market struct for a given LCC token
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function lccToMarket(address lcc) external view returns (bytes32, address) {
         return _lccMarket(lcc);
     }
 
     /**
      * @notice
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function getFactory(address lcc0, address lcc1) external view returns (IMarketFactory) {
         address factory0 = s.lccToMarket[lcc0].factory;
         address factory1 = s.lccToMarket[lcc1].factory;
         if (factory0 != factory1) {
             revert Errors.InvariantViolated("LCCs are not from the same market");
         }
         return IMarketFactory(factory0);
     }
 
     /**
      * @notice Checks if an address is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @param issuer The address to check
      * @return True if the address is an issuer, false otherwise
      */
     function issuers(address lcc, address issuer) external view returns (bool) {
         return s.issuers[lcc][issuer];
     }
 
     /**
      * @notice Gets the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address
      */
     function getLCC(bytes32 marketId, address underlying) external view returns (address) {
         return LCCFactoryLib.getLCC(s, marketId, underlying);
     }
 
     /**
      * @notice Gets the underlying asset address for a given LCC token
      * @param lccToken The LCC token address
      * @return The underlying asset address
      */
     function getUnderlying(address lccToken) external view returns (address) {
         return LCCFactoryLib.getUnderlying(s, lccToken);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function isLCC(address lcc) external view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Returns the direct supply (wrapped underlying) for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of direct supply
      */
     function directSupply(address lcc) external view returns (uint256) {
         return s.directSupply[lcc];
     }
 
     /**
      * @notice Returns the shared reserve of underlying assets for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of underlying assets held in reserve for this LCC
      */
     function reserveOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return reserve.direct + reserve.marketDerived;
     }
 
     /**
      * @notice Returns the split underlying reserve tuple for a given LCC token
      * @param lcc The LCC token address
      * @return direct The reserve component backing direct/wrapped supply
      * @return marketDerived The reserve component mobilised from market-derived flows
      */
     function reserveOfUnderlyingTuple(address lcc)
         external
         view
         onlyValidLcc(lcc)
         returns (uint256 direct, uint256 marketDerived)
     {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return (reserve.direct, reserve.marketDerived);
     }
 
     /**
      * @notice Returns the queued settlement amount for a specific LCC and recipient
      * @param lcc The LCC token address
      * @param recipient The recipient address
      * @return The amount queued for settlement
      */
     function settleQueue(address lcc, address recipient) external view returns (uint256) {
         return s.settleQueue[lcc][recipient];
     }
 
     /**
      * @notice Returns the total queued settlement amount for a given LCC token
      * @param lcc The LCC token address
      * @return The total amount queued across all recipients
      */
     function totalQueued(address lcc) external view returns (uint256) {
         return s.totalQueued[lcc];
     }
 
     /**
      * @notice Returns the total queued settlement debt for the underlying of a given LCC
      * @param lcc The LCC token address
      * @return The total queued debt aggregated across all LCCs sharing the same underlying
      */
     function queueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         return s.queueOfUnderlying[s.lccToUnderlying[lcc]];
     }
 
     /**
      * @notice Returns the unfunded queued debt for the underlying of a given LCC
      * @dev Unfunded debt is `max(queueOfUnderlying - marketDerivedReserve, 0)` at the shared-underlying level.
      * @param lcc The LCC token address
      * @return The remaining underlying shortfall that still needs market-to-Hub mobilisation
      */
     function unfundedQueueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         address underlying = s.lccToUnderlying[lcc];
         uint256 queued = s.queueOfUnderlying[underlying];
         uint256 reserve = s.reserveOfUnderlying[underlying].marketDerived;
         return queued > reserve ? queued - reserve : 0;
     }
 
     // ============ ADMIN FUNCTIONS ============
 
     /**
      * @notice Sets or removes a factory address from the allowed factories list
      * @param factory The factory address to enable or disable
      * @param enabled Whether the factory should be enabled (true) or disabled (false)
      */
     function setFactory(address factory, bool enabled) external onlyOwner {
         isFactory[factory] = enabled;
         emit FactorySet(factory, enabled);
     }
 
     /**
      * @notice Creates LCC token pair for a market
      * @param marketRef The market reference (bytes from proxyHookAddress)
      * @param underlyingAsset0 The first underlying asset address
      * @param underlyingAsset1 The second underlying asset address
      * @param marketName The market name
      * @param initialIssuers Array of addresses to set as issuers for both LCC tokens
      * @return lccToken0 The first LCC token address
      * @return lccToken1 The second LCC token address
      */
     function createLCCPair(
         bytes memory marketRef,
         address underlyingAsset0,
         address underlyingAsset1,
         string memory marketName,
         address[] memory initialIssuers
     ) external onlyFactory returns (address lccToken0, address lccToken1) {
         address resilientOracleAddress = oracleHelper.oracle();
         address factory = _msgSender();
         address[2] memory underlyingPair = [underlyingAsset0, underlyingAsset1];
         lccToken0 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 0, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
         lccToken1 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 1, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
 
         // Emit events for LCC creation
         emit LCCCreated(underlyingAsset0, lccToken0, s.lccToMarket[lccToken0].id);
         emit LCCCreated(underlyingAsset1, lccToken1, s.lccToMarket[lccToken1].id);
     }
 
     /**
      * @notice Initializes the mapping from LCC tokens to Market (with ID and Ref)
      * @dev Order-insensitive: `lccToken0` and `lccToken1` are treated independently; no `(0,1)` lane semantics exist here.
      *      Canonical market ordering (for pair lanes) is defined by the core pool key in `MarketFactory`, not by argument order.
      * @param lccToken0 The first LCC token address
      * @param lccToken1 The second LCC token address
      * @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
      * @param marketRef The market reference (bytes from proxyHookAddress)
      */
     function initialize(address lccToken0, address lccToken1, bytes32 marketId, bytes memory marketRef)
         external
         onlyFactory
     {
         LCCFactoryLib.initialize(s, lccToken0, lccToken1, marketId, marketRef, _msgSender());
     }
 
     // ============ INTERNAL HELPERS (delegate to library) ============
 
     /**
      * @notice Checks if the current caller is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @return True if the caller is an issuer, false otherwise
      */
     function _isCallerIssuer(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function _isValidLcc(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Mints LCC tokens to an address
      * @param lccToken The LCC token address
      * @param to The address to mint tokens to
      * @param directAmount The amount to mint as direct supply
      * @param marketAmount The amount to mint as market-derived supply
      */
     function _mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.mint(lccToken, to, directAmount, marketAmount);
     }
 
     /**
      * @notice Burns LCC tokens from an address
      * @param lccToken The LCC token address
      * @param from The address to burn tokens from
      * @param directAmount The amount to burn from direct supply
      * @param marketAmount The amount to burn from market-derived supply
      */
     function _burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.burn(lccToken, from, directAmount, marketAmount);
     }
 
     /**
      * @notice Gets the total balance (wrapped + market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return The total balance
      */
     function _balanceOf(address lccToken, address account) internal view returns (uint256) {
         return LCCFactoryLib.balanceOf(lccToken, account);
     }
 
     /**
      * @notice Gets the bucketed balances (wrapped and market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return wrapped The wrapped (direct) balance
      * @return marketDerived The market-derived balance
      */
     function _balancesOf(address lccToken, address account)
         internal
         view
         returns (uint256 wrapped, uint256 marketDerived)
     {
         return LCCFactoryLib.balancesOf(lccToken, account);
     }
 
     /// @dev Rejects DEX sinks — issuer mints and wrap paths bypass LCC transfer hooks, so DEX ingress must not be bypassed.
     function _assertRecipientNotDexSink(address lcc, address to) internal view {
         uint8 level = boundLevel(s.lccToMarket[lcc].factory, to);
         if (Bounds.isDex(level)) {
             revert Errors.MintToNotAllowedRecipient(to);
         }
     }
 
     /// @dev User-facing wrap / wrapWith mint surfaces (`_wrap`, `_wrapWith`): minting into any protocol-bound address
     ///      (endpoint, exempt, or DEX) bypasses normal custody expectations and can strand value or become FCFS-capturable
     ///      on routers (see **DELTA-02**). Issuer-only `issue` remains the supported path to protocol endpoints.
     function _assertUserFacingMintRecipient(address lcc, address to) internal view {
         uint8 level = boundLevel(s.lccToMarket[lcc].factory, to);
         if (Bounds.isEndpoint(level)) {
             revert Errors.MintToNotAllowedRecipient(to);
         }
     }
 
     // ============ TRADER FUNCTIONS ============
 
     // DirectLPs and Traders engaging the CorePool directly will need LCC. LCC is 1:1 with the underlying asset.
     /**
      * @dev Internal function to wrap underlying assets into LCC tokens
      * @param lcc The LCC token address to wrap into
      * @param to The address receiving the LCC tokens
      * @param amount The amount of underlying assets to wrap
      */
     function _wrap(address lcc, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         address underlying = s.lccToUnderlying[lcc];
         bool isNativeAsset = underlying == address(0);
 
         _assertUserFacingMintRecipient(lcc, to);
 
         // throw error if the native ETH is insufficient and it is a native ETH backed LCC
         if (isNativeAsset) {
             if (msg.value != amount) {
                 revert Errors.InvalidAmount(0, 0);
             }
         } else {
             if (msg.value != 0) {
                 revert Errors.InvalidAmount(0, 0);
             }
             // Use CurrencyTransfer which has Permit2 fallback for ERC20 transfers
             Currency.wrap(underlying).transferFrom(from, address(this), amount);
         }
 
         s.directSupply[lcc] += amount;
         s.reserveOfUnderlying[underlying].direct += amount;
 
         // mint some tokens
         _mint(lcc, to, amount, 0);
 
         emit LccWrapped(lcc, from, to, amount);
     }
 
     function wrapTo(address lcc, address to, uint256 amount) external payable nonReentrant {
         _wrap(lcc, to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens and sends them to a specified recipient
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address
      * @param amount The amount of underlying assets to wrap
      */
     function wrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller
      * @param lcc The LCC token address
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address lcc, uint256 amount) external payable nonReentrant {
         _wrap(lcc, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address underlying, bytes32 marketId, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), amount);
     }
 
     /**
      * @notice Internal function to wrap LCC using another LCC as backing, with O(1) flattening and netting
      * @dev Delegates to LiquidityHubLib.wrapWithLogic - heavy logic moved to library
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The address receiving the target LCC
      * @param amount The amount to wrap
      */
     function _wrapWith(address lcc, address withLCC, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
 
         _assertUserFacingMintRecipient(lcc, to);
 
         // Performs all necessary validation and preparation
         LiquidityHubLib.WrapWithContext memory ctx =
             LiquidityHubLinkedLib.wrapWithPrepare(s, lcc, withLCC, from, amount);
         // Pull backing LCC from caller into the Hub first.
         Currency.wrap(withLCC).transferFrom(from, address(this), ctx.originalAmount);
         // Executes the full wrap-with operation using the provided context
         ctx = LiquidityHubLinkedLib.wrapWithContext(s, lcc, withLCC, ctx);
         // Extract return values.
         // Note: wrapWithContext is designed to conserve amounts. Any mismatch is a logic bug in the library.
         uint256 directToMint = ctx.directToMint;
         uint256 marketToMint = ctx.marketToMint;
 
         // Final mint: mint target LCC with appropriate direct/market-derived split
         LCCFactoryLib.mint(lcc, to, directToMint, marketToMint);
 
         if (ctx.queuedShortfall > 0) {
             // Ensure the queued settlement event is emitted
             emit SettlementQueued(withLCC, address(this), ctx.queuedShortfall);
         }
 
         emit LccWrappedWith(lcc, withLCC, from, to, amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing for the caller
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param amount The amount to wrap
      */
     function wrapWith(address lcc, address withLCC, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing and sends to a specified recipient
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The recipient address
      * @param amount The amount to wrap
      */
     function wrapWithTo(address lcc, address withLCC, address to, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, to, amount);
     }
 
     /**
      * @dev Unwraps LCC from the account's wallet and transfers underlying assets to recipient
      * @dev Accounts should only be able to unwrap if they have LCC in their wallet
      * @dev Unwrap headroom (`availableToUnwrap`) nets any existing settlement queue for `queueTo` against the
      *      caller-held balance (`from`), so the same LCC cannot back repeated queued shortfalls.
      *      - Self-unwrap paths (`unwrap(...)`): `queueTo == from`, so the queue is netted against the same user's live balance.
      *      - Immediate payout `to` must be serviceable: not Hub, not exempt/DEX sinks (HUB-02B).
      * @param lcc The LCC token address to unwrap
      * @param to The recipient of the underlying asset
      * @param queueTo The address to queue shortfall to
      * @param amount The amount to unwrap
      */
     function _unwrap(address lcc, address to, address queueTo, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         (uint256 wrappedBalance, uint256 marketDerivedBalance) = _balancesOf(lcc, from);
         uint256 fromBalance = wrappedBalance + marketDerivedBalance;
 
         // Generic queue paths validate queue-owner shape only.
         // Current settleability remains a redemption-time concern for processSettlementFor().
         _assertValidQueueOwner(lcc, queueTo, true);
         // Immediate payout recipient must be serviceable: not Hub, not exempt/DEX sinks (see HUB-02B in INVARIANTS.md).
         _assertValidUnwrapPayoutRecipient(lcc, to);
 
         (uint256 effectiveFromBalance, uint256 existingQueue) =
             _unwrapEffectiveFromBalance(lcc, from, queueTo, fromBalance);
         _assertUnwrapWithinHeadroom(amount, effectiveFromBalance, existingQueue);
 
         _unwrapAndPay(lcc, from, to, queueTo, amount, wrappedBalance, marketDerivedBalance);
     }
 
     /// @dev Executes `unwrapInternalLogic`, underlying payout, and events after admission checks pass.
     function _unwrapAndPay(
         address lcc,
         address from,
         address to,
         address queueTo,
         uint256 amount,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance
     ) private {
         (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) = LiquidityHubLinkedLib.unwrapInternalLogic(
             s, lcc, queueTo, amount, wrappedBalance, marketDerivedBalance
         );
 
         if (directUnwrapped + marketUnwrapped > 0) {
             _pay(lcc, from, to, directUnwrapped, marketUnwrapped);
         }
         if (queuedShortfall > 0) {
             emit SettlementQueued(lcc, queueTo, queuedShortfall);
         }
 
         emit LccUnwrapped(lcc, from, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller
      * @param lcc The LCC token address to unwrap
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address lcc, uint256 amount) external nonReentrant {
         _unwrap(lcc, _msgSender(), _msgSender(), amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address underlying, bytes32 marketId, uint256 amount) external nonReentrant {
         _unwrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), _msgSender(), amount);
     }
 
     // ============ LIQUIDITY FUNCTIONS ============
 
     /**
      * @notice Returns the available liquidity in the market for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of liquidity available in the market (0 if market doesn't exist)
      */
     function marketLiquidity(address lcc) public view returns (uint256) {
         Market memory market = s.lccToMarket[lcc];
         return
             market.id != bytes32(0)
                 ? IMarketFactory(market.factory).marketLiquidity(s.lccToUnderlying[lcc], market.id)
                 : 0;
     }
 
     // ============ ISSUER FUNCTIONS ============
 
     /**
      * @notice Issues LCC tokens (mints to issuer)
      * @param lcc The LCC token address to issue for
      * @param amount The amount to issue
      */
     function issue(address lcc, address to, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC mint path reverts on zero (direct+market) amount.
         // Minting market-derived LCC directly to the DEX sink bypasses transfer hooks and ingress settlement.
         // Issuer mints to bucket-exempt protocol endpoints (eg ProxyHook) remain valid — only DEX sinks are rejected here.
         _assertRecipientNotDexSink(lcc, to);
         _mint(lcc, to, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens (burns from specified address)
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param amount The amount to cancel
      */
     function cancel(address lcc, address from, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC burn path reverts on zero (direct+market) amount.
         // `from` is intentionally issuer-selected because issuers are fixed protocol actors (for example ProxyHook and
         // VTSOrchestrator) that cancel along validated protocol flows, not arbitrary public confiscation surfaces.
         // Typical callers burn protocol-controlled holders such as queued settlement holders, MarketVault balances,
         // or staged transfer recipients after the surrounding flow has already proven the accounting path.
         _burn(lcc, from, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens and queues a settlement for the shortfall
      * @dev Simulates unwrap-with-queue without touching direct supply or market liquidity.
      *      Queue recipient shape is validated (non-zero, non-exempt unless Hub), while present settleability
      *      is intentionally enforced at processSettlementFor() when redemption is attempted.
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) public onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
         // Same trusted-issuer rationale as `cancel`: the issuer chooses `from` because this path is used to unwind
         // protocol-side LCC holdings while optionally preserving the recipient's queued settlement claim.
         _cancelWithQueue(lcc, from, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Queues settlement for a recipient after issuer-side deficit transfer.
      * @dev Security checks:
      *      - recipient must be non-zero
      *      - recipient must not be bucket-exempt (external settlement path requires market-derived balance accounting)
      *      - recipient must hold sufficient market-derived LCC to back the queued amount
      *      This path is stricter than generic queue accounting because it is only used when the issuer
      *      has already transferred deficit LCC to `recipient`, so queue owner and burn source must match now.
      */
     function queueForTransferRecipient(address lcc, address recipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         // Deficit queues must target a serviceable external recipient (Hub queueing is not allowed on this path).
         _assertQueueRecipientServiceable(lcc, recipient, amount, false);
         _queueSettlement(lcc, recipient, amount);
     }
 
     /**
      * @dev Internal implementation of cancelWithQueue without access control
      * @param lcc The LCC token address
      * @param from The address to cancel tokens from
      * @param principalAmount The total principal amount being cancelled (cancellable amount is burned from `from`)
      * @param queueAmount The amount to queue for settlement (portion of principalAmount queued for `recipient`)
      * @param recipient The recipient of the queued settlement
      */
     function _cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) internal {
         if (queueAmount > 0) {
             _assertValidQueueOwner(lcc, recipient, true);
         }
 
         uint256 cancelAmount = principalAmount - queueAmount;
 
         // Burn the cancellable portion of the principal amount from the sender.
         // Burn against the sender's actual bucket split (market-derived first, then wrapped).
         // Note: allow cancelAmount == 0 (principal fully queued) without reverting.
         if (cancelAmount > 0) {
             _safeBurn(lcc, from, cancelAmount);
         }
 
         // Queue accounting is intentionally decoupled from current holder backing.
         // Runtime settleability is enforced when processSettlementFor executes.
         _queueSettlement(lcc, recipient, queueAmount);
     }
 
     /**
      * @dev Burns against a holder's bucket split (market-derived first, then wrapped).
      * - Bucket-exempt recipients can burn without bucket accounting.
      * - If `balancesOf` is unavailable (e.g. reentrancy tests that stub LCC), fall back to a full burn.
      */
     function _safeBurn(address lcc, address from, uint256 amount) internal {
         if (amount == 0) return;
 
         if (Bounds.isExempt(boundLevelOfLcc(lcc, from))) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         // IMPORTANT: Some reentrancy-hardening tests replace the LCC code (vm.etch) with a minimal stub that
         // does not implement balancesOf; in that case we must still proceed to the burn to exercise the guard.
         uint256 wrappedBal;
         uint256 marketBal;
         bool hasBuckets = true;
         try ILCC(lcc).balancesOf(from) returns (uint256 wrapped, uint256 market) {
             wrappedBal = wrapped;
             marketBal = market;
         } catch (bytes memory reason) {
             // Keep fallback only for stubbed / non-implemented `balancesOf` paths (empty revert data).
             // Integrity and bucket errors (e.g. `Errors.InvalidBucketState`) must surface.
             if (reason.length == 0) {
                 hasBuckets = false;
             } else {
                 assembly ("memory-safe") {
                     revert(add(reason, 0x20), mload(reason))
                 }
             }
         }
 
         if (!hasBuckets) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         uint256 burnMarket = Math.min(marketBal, amount);
         uint256 remaining = amount - burnMarket;
         uint256 burnDirect = Math.min(wrappedBal, remaining);
         _burn(lcc, from, burnDirect, burnMarket);
     }
 
     /**
      * @notice Plans a cancel operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      This path-keyed store is safe only because current callers stage the plan and then
      *      immediately drive the matching transfer in the same logical path/transaction.
      *      It must not be treated as a general deferred queue across unrelated intermediate logic.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param amount The amount to cancel
      */
     function planCancel(address lcc, address sender, address cancelFromRecipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
 
         // Store the planned cancel in transient storage
         TransientSlots.setPlanCancel(lcc, sender, cancelFromRecipient, amount);
     }
 
     /**
      * @notice Plans a cancel with queue operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      Current MM decrease flows rely on the matching transfer happening immediately after
      *      `modifyLiquidity(...)` returns; if a future flow can stage the same key twice before
      *      consumption, this helper is no longer sufficient.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function planCancelWithQueue(
         address lcc,
         address sender,
         address cancelFromRecipient,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) external onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
 
         // Store the planned cancel with queue in transient storage
         TransientSlots.setPlanCancelWithQueue(lcc, sender, cancelFromRecipient, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Called by MarketVault after taking underlying liquidity from the market to LCC
      * @param lcc The LCC token address
      * @param amount The amount of underlying liquidity taken
      * @param shouldEmit If true, emit `LiquidityAvailable` when `amount > 0` (wake-up for dispatch; not suppressed when
      *        Hub self-queue is large—new reserve may still service external queues)
      */
     function confirmTake(address lcc, uint256 amount, bool shouldEmit) external onlyIssuer(lcc) {
         // INTENT:
         // `confirmTake()` must be callable from within higher-level flows that themselves may be `nonReentrant`
         // (e.g. `useMarketLiquidity()` eventually triggering a vault -> hub callback).
         // We therefore DO NOT apply `nonReentrant` here; instead, we enforce a strict balance-backed invariant
         // so callers cannot "fabricate" reserves via re-entrancy.
 
         LiquidityHubLib.ConfirmTakeContext memory ctx =
             LiquidityHubLinkedLib.confirmTakePrepare(s, lcc, amount, shouldEmit);
 
         // Best-effort: settle Hub queue up to the newly available amount
         if (ctx.hubQueueBeforeSettlement > 0) {
             _processSettlementFor(lcc, address(this), amount);
         }
 
         if (ctx.emitLiquidityAvailable) {
             // New reserve arrived at the Hub; downstream dispatch may clear external `settleQueue` entries. Hub
             // self-settlement above does not consume this reserve (LCC burn / queue collapse only).
             emit LiquidityAvailable(lcc, ctx.underlying, amount, ctx.marketId);
         }
 
         // Balance-backed invariant: reserve accounting must never exceed actual hub holdings.
         // This protects against re-entrancy and any accidental/malicious unbacked `confirmTake` calls.
         LiquidityHubLinkedLib.confirmTakeBalanceInvariant(s, ctx.underlying);
     }
 
     /**
      * @notice Prepare settlement of underlying from Hub to MarketVault
      * @dev For ERC20, approve the caller (expected MarketVault) to pull tokens; for native, transfer ETH to caller.
      *      Decrements direct reserve and per-LCC directSupply immediately; intended to be called just before settlement
      *      in the same tx.
      */
     function prepareSettle(address lcc, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         LiquidityHubLinkedLib.prepareSettle(s, lcc, amount, _msgSender());
     }
 
     /**
      * @notice Process settlement for a specific recipient using reserveOfUnderlying
      * @dev Permissionless function that allows anyone to process settlements when liquidity is available.
      *      Unified interface: branches behaviour based on whether recipient is address(this) (Hub) or external address.
      *      For Hub: burns Hub-held LCC without transferring underlying or decrementing reserves.
      *      For external: checks holder balance, burns user tokens, transfers underlying, and decrements reserves.
      *      External-path reverts are retriable and signal that reserves/custody are not yet reconciled.
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for (address(this) for Hub's own queue)
      * @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
      */
     function processSettlementFor(address lcc, address recipient, uint256 maxAmount)
         external
         onlyValidLcc(lcc)
         nonReentrant
     {
         _processSettlementFor(lcc, recipient, maxAmount);
     }
 
     /**
      * @notice Internal function to process settlement for a specific recipient
      * @dev Delegates to LiquidityHubLib.processSettlementLogic
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for
      * @param maxAmount The maximum amount to settle
      */
     function _processSettlementFor(address lcc, address recipient, uint256 maxAmount) internal {
         uint256 queuedBefore = s.settleQueue[lcc][recipient];
         LiquidityHubLinkedLib.processSettlementLogic(s, lcc, recipient, maxAmount);
         uint256 queuedAfter = s.settleQueue[lcc][recipient];
         uint256 settled = queuedBefore > queuedAfter ? queuedBefore - queuedAfter : 0;
         if (settled > 0) {
             emit SettlementProcessed(lcc, recipient, settled, maxAmount);
         }
     }
 
     // -----------------------------------
     // LCC triggered functions
     // -----------------------------------
 
     /// @notice Called by LCC on transfer to execute any planned cancellations
     /// @dev Assumes at most one live plan per `(lcc, sender, recipient)` path at consumption time.
     ///      The current call graph preserves this by staging the plan immediately before the
     ///      matching transfer; this function does not independently disambiguate multiple same-key plans.
     ///      Planned cancels are intentionally consumed from the transfer path so the burn source is the exact
     ///      protocol-side recipient that just received the LCC, rather than an arbitrary user-selected address.
     function executePlannedCancel(address sender, address cancelFromRecipient) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Check for planned cancel with queue first (more specific)
         (uint256 principalAmount, uint256 queueAmount, address queueRecipient) =
             TransientSlots.consumePlanCancelWithQueue(lcc, sender, cancelFromRecipient);
 
         if (principalAmount > 0) {
             // _cancelWithQueue handles principal == queue (burn 0, queue all) and principal > queue.
             // Use internal function to bypass onlyIssuer check (LCC is the caller, not an issuer).
             _cancelWithQueue(lcc, cancelFromRecipient, principalAmount, queueAmount, queueRecipient);
             return;
         }
 
         // Check for simple planned cancel
         uint256 amount = TransientSlots.consumePlanCancel(lcc, sender, cancelFromRecipient);
         if (amount > 0) {
             _safeBurn(lcc, cancelFromRecipient, amount);
         }
     }
 
     /// @notice Annuls queued settlement before a protocol-bound transfer
     function annulSettlementBeforeTransfer(
         address from,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance,
         uint256 amountToTransfer
     ) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Even if queued == 0 or amountToTransfer == 0, the library path is a no-op.
         // We intentionally avoid an early return here to keep the control flow simpler and more auditable.
         uint256 toAnnul = LiquidityHubLinkedLib.annulSettlementBeforeTransfer(
             s, lcc, from, wrappedBalance, marketDerivedBalance, amountToTransfer
         );
         if (toAnnul > 0) {
             emit SettlementAnnulled(lcc, from, toAnnul);
         }
     }
 
     // ============ SETTLEMENT FUNCTIONS ============
 
     /**
      * @dev Pays an outstanding settlement to an account by burning LCC tokens and transferring underlying assets
      * @param lcc The LCC token address
      * @param owner The owner of the LCC tokens to burn
      * @param to The recipient of the underlying assets
      * @param fromDirect The amount of LCC to burn from direct supply
      * @param fromMarket The amount of LCC to burn from market-derived supply
      */
     function _pay(address lcc, address owner, address to, uint256 fromDirect, uint256 fromMarket) internal {
         LiquidityHubLinkedLib.pay(s, lcc, owner, to, fromDirect, fromMarket);
     }
 
     /**
      * @dev Adds a settlement request to the queue
      * @param lcc The LCC token address
      * @param recipient The address with pending settlements
      * @param amount The amount to eventually settle
      */
     function _assertQueueRecipientServiceable(address lcc, address recipient, uint256 amount, bool allowHub)
         internal
         view
     {
         _assertValidQueueOwner(lcc, recipient, allowHub);
 
         // Native settlements pay `recipient` during `processSettlementFor` via `LiquidityHubLib.transferUnderlying`:
         // EOAs receive raw ETH first (then WETH on failure); contracts receive raw ETH only if they EIP-165 support
         // `INativeSettlementReceiver` (for example `MMQueueCustodian`); all other contracts receive WETH directly.
         // Queue admission still requires `balancesOf` market-derived backing and valid bound level (above).
 
+        // Deficit queues must target non-protocol recipients only (BOUND_NONE). Disallow protocol-bound endpoints
+        // (including shared routers) to prevent settlement value landing on shared contracts.
+        if (boundLevelOfLcc(lcc, recipient) != Bounds.BOUND_NONE) {
+            revert Errors.NotApproved(recipient);
+        }
+
         (, uint256 marketDerivedBalance) = ILCC(lcc).balancesOf(recipient);
         if (marketDerivedBalance < amount) {
             revert Errors.InsufficientBalance(marketDerivedBalance, amount);
         }
     }
 
     /**
      * @dev Minimal queue-owner validity check for generic queue creation.
      * Queue owners must not be zero and must not be bucket-exempt unless the queue is intentionally
      * attributed to the Hub itself. This keeps generic queue writes compatible with later settlement,
      * while still allowing queue ownership to be decoupled from current holder backing.
      */
     function _assertValidQueueOwner(address lcc, address recipient, bool allowHub) internal view {
         if (recipient == address(0)) {
             revert Errors.InvalidAddress(recipient);
         }
 
         if (recipient == address(this)) {
             if (!allowHub) revert Errors.NotApproved(recipient);
             return;
         }
 
         uint8 level = boundLevelOfLcc(lcc, recipient);
         if (Bounds.isExempt(level) || Bounds.isDex(level)) {
             revert Errors.NotApproved(recipient);
         }
     }
 
     /**
      * @dev Unwrap immediate payout recipient: must not be zero, the Hub, bucket-exempt, or DEX sink.
      *      Distinct from queue ownership: `queueTo` may be `address(this)` for Hub-internal queue semantics;
      *      underlying must never be paid to unserviceable sinks (e.g. proxy-hook/facade).
      */
     function _assertValidUnwrapPayoutRecipient(address lcc, address recipient) internal view {
         if (recipient == address(0)) {
             revert Errors.InvalidAddress(recipient);
         }
         if (recipient == address(this)) {
             revert Errors.NotApproved(recipient);
         }
         uint8 level = boundLevelOfLcc(lcc, recipient);
         if (Bounds.isExempt(level) || Bounds.isDex(level)) {
             revert Errors.NotApproved(recipient);
         }
     }
 
     /**
      * @dev Queue accounting helper only.
      * Deliberately does not assert recipient backing/custody because queue ownership may be
      * intentionally decoupled from current LCC holder state. Serviceability is enforced at
      * processSettlementFor(), while explicit transfer-recipient flows validate earlier.
      */
     function _queueSettlement(address lcc, address recipient, uint256 amount) internal {
         if (amount == 0) return;
         LiquidityHubLinkedLib.queueSettlement(s, lcc, recipient, amount);
         emit SettlementQueued(lcc, recipient, amount);
     }
 
     // ============ INTERNAL FUNCTIONS ============
 
     /// @dev Computes unwrap headroom for `_unwrap`: existing queue against `queueTo` nets against `fromBalance`.
     function _unwrapEffectiveFromBalance(address lcc, address, address queueTo, uint256 fromBalance)
         private
         view
         returns (uint256 effectiveFromBalance, uint256 existingQueue)
     {
         existingQueue = s.settleQueue[lcc][queueTo];
         effectiveFromBalance = fromBalance;
     }
 
     /// @dev Reverts unless `0 < amount <= availableToUnwrap` where `availableToUnwrap = max(0, fromBalance - existingQueue)`.
     ///      For endpoint flows, `fromBalance` may already include capped custody credit (see `_unwrap`).
     function _assertUnwrapWithinHeadroom(uint256 amount, uint256 fromBalance, uint256 existingQueue) private pure {
         uint256 availableToUnwrap = fromBalance > existingQueue ? fromBalance - existingQueue : 0;
         if (amount == 0 || amount > availableToUnwrap) {
             revert Errors.InvalidAmount(amount, availableToUnwrap);
         }
     }
 
     /**
      * @dev Validates inbound ETH from the factory-scoped canonical vault only.
      *      `CanonicalVault` sends native ETH to the Hub; identity is `ICanonicalVault.marketFactory()` plus
      *      `IMarketFactory.canonicalVault() == sender` for a hub-registered factory.
      */
     function _assertValidEthSender() internal view {
         address sender = _msgSender();
         if (sender.code.length == 0) revert Errors.InvalidEthSender();
 
         try ICanonicalVault(sender).marketFactory() returns (address mf) {
             if (isFactory[mf] && IMarketFactory(mf).canonicalVault() == sender) {
                 return;
             }
         } catch {}
 
         revert Errors.InvalidEthSender();
     }
 
     /**
      * @notice Receives native ETH from the factory's `canonicalVault` only
      */
     receive() external payable {
         _assertValidEthSender();
     }
 }
```

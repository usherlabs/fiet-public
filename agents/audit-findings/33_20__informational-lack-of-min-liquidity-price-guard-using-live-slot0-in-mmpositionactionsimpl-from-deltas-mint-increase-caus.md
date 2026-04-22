[Informational] Lack of min-liquidity/price guard using live slot0 in MMPositionActionsImpl ‘from deltas’ mint/increase causes front-runnable slippage reducing minted LP units

# Description

The add-liquidity-from-deltas helpers [compute liquidity to mint from the live pool price](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/modules/PositionManagerImpl.sol#L103-L116) and [only enforce max token-in amounts](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionActionsImpl.sol#L270-L281), enabling front-running to reduce minted LP units while unused value remains as credits/backing.

MMPositionActionsImpl.[_increaseFromDeltas](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionActionsImpl.sol#L693) and [_mintFromDeltas](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionActionsImpl.sol#L750) derive the exact liquidity to add via PositionManagerImpl._getLiquidityFromDeltas, which [reads the current Uniswap v4 slot0 and converts the caller’s available credits (getFullCreditPair) into LP units using LiquidityAmounts.getLiquidityForAmounts](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/modules/PositionManagerImpl.sol#L103-L116). These helpers then execute the mint/increase and [only enforce user-provided amount0Max/amount1Max via _validateMaxIn](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionActionsImpl.sol#L270-L281), without any min-liquidity or price/tick bound. A searcher can front-run the transaction to push price toward the range edge so that the same credits mint fewer LP units, still passing the max-input checks. Unused value does not leave the user; it remains as positive credits/backing (for payerIsUser=true, [in-hook settlement is clamped to required settlement](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L372-L382); for payerIsUser=false, [subsequent settle-from-deltas books excess as settlement/overflow](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L285)). This creates a front-runnable slippage surface that reduces the active LP minted in that transaction but does not cause principal loss.

# Severity

**Impact Explanation:** [Low] Users mint fewer LP units for the same credits; remaining value is preserved as credits/backing. No principal loss, no invariant break, and no DoS.

**Likelihood Explanation:** [Low] Requires attacker to move price (paying fees and taking inventory risk) with unclear or negative expected value; primarily a griefing/opportunity-cost pattern.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Victim uses MINT_POSITION_FROM_DELTAS (payerIsUser=true). Attacker front-runs to move price near a tick boundary; the function computes liquidityFromDeltas at the shifted price and mints fewer LP units. Max-input checks pass; unused credits remain with the user.
#### Preconditions / Assumptions
- (a). Victim has positive deltas (credits) on both pool tokens.
- (b). Victim submits MINT_POSITION_FROM_DELTAS with sufficient amount0Max/amount1Max and payerIsUser=true.
- (c). Public mempool; attacker can pre-trade the same core pool to shift slot0.

### Scenario 2.
Victim uses INCREASE_LIQUIDITY_FROM_DELTAS (payerIsUser=false). Attacker front-runs to skew price; fewer LP units are added and a subsequent settle-from-deltas consumes intended credits, recording any excess as position backing/overflow rather than active LP units.
#### Preconditions / Assumptions
- (a). Victim has an existing position and positive own credits (locker deltas).
- (b). Victim submits INCREASE_LIQUIDITY_FROM_DELTAS with sufficient amount0Max/amount1Max and payerIsUser=false.
- (c). Public mempool; attacker can pre-trade the same core pool to shift slot0.

### Scenario 3.
Victim with skewed credits calls MINT_POSITION_FROM_DELTAS (payerIsUser=true) on a narrow range. Attacker front-runs to push price just outside the range, yielding negligible minted LP; remaining credits are preserved for the user.
#### Preconditions / Assumptions
- (a). Victim’s credits are skewed (e.g., mostly token0) and chooses a narrow tick range.
- (b). Victim submits MINT_POSITION_FROM_DELTAS with payerIsUser=true and sufficient maxima.
- (c). Public mempool; attacker can pre-trade the same core pool to shift slot0 slightly outside the range.

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
+        // NOTE[SLIPPAGE-GUARD]: liquidityFromDeltas depends on live slot0. To harden against sandwiching,
+        // accept a user-specified minLiquidity (and/or price/tick guard) and require it here before proceeding.
+        // See recommended guarded action variants and decoders in MMCalldataDecoder.
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
+        // NOTE[SLIPPAGE-GUARD]: liquidityFromDeltas depends on live slot0. To harden against sandwiching,
+        // accept a user-specified minLiquidity (and/or price/tick guard) and require it here before proceeding.
+        // See recommended guarded action variants and decoders in MMCalldataDecoder.
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

## MMCalldataDecoder.sol

File: `contracts/evm/src/libraries/MMCalldataDecoder.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/MMCalldataDecoder.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {CalldataDecoder} from "v4-periphery/src/libraries/CalldataDecoder.sol";
 
 /// @title Library for efficient calldata decoding in MMPositionManager
 /// @notice Reduces bytecode by replacing abi.decode with assembly-based decoding
 /// @dev Follows Uniswap v4 CalldataDecoder patterns for consistency
 library MMCalldataDecoder {
     using CalldataDecoder for bytes;
 
     error SliceOutOfBounds();
 
     /// @notice Mask used for offsets and lengths to ensure no overflow
     /// @dev No sane ABI encoding will pass in an offset or length greater than type(uint32).max
     uint256 constant OFFSET_OR_LENGTH_MASK = 0xffffffff;
 
     /// @notice Equivalent to SliceOutOfBounds.selector, stored in least-significant bits
     uint256 constant SLICE_ERROR_SELECTOR = 0x3b99b53d;
 
     // ═══════════════════════════════════════════════════════════════════════════════════════════
     // High Priority Decoders (Position Operations)
     // ═══════════════════════════════════════════════════════════════════════════════════════════
 
     /// @dev SETTLE_POSITION: (PoolKey, uint256, uint256, int128, int128, bool)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return amount0 The amount of token0 to settle
     /// @return amount1 The amount of token1 to settle
     /// @return usePositionManagerBalance If true, tokens flow via MMPM balance and locker's deltas are adjusted
     function decodeSettlePositionParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             uint256 positionIndex,
             int128 amount0,
             int128 amount1,
             bool usePositionManagerBalance
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amount0, amount1, usePositionManagerBalance
             // Minimum length: 0xa0 + 0x20*5 = 0x140
             if lt(params.length, 0x140) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             amount0 := calldataload(add(params.offset, 0xe0))
             amount1 := calldataload(add(params.offset, 0x100))
             usePositionManagerBalance := calldataload(add(params.offset, 0x120))
         }
     }
 
     /// @dev INCREASE_LIQUIDITY: (PoolKey, uint256, uint256, uint256)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return liquidity The amount of liquidity to add
     function decodeIncreaseLiquidityParams(bytes calldata params)
         internal
         pure
         returns (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint256 liquidity)
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, liquidity
             // Minimum length: 0xa0 + 0x20*3 = 0x100
             if lt(params.length, 0x100) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             liquidity := calldataload(add(params.offset, 0xe0))
         }
     }
 
     /// @dev MINT_POSITION: (PoolKey, uint256, int24, int24, uint256)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return tickLower The lower tick of the position
     /// @return tickUpper The upper tick of the position
     /// @return liquidity The amount of liquidity to mint
     function decodeMintPositionParams(bytes calldata params)
         internal
         pure
         returns (PoolKey calldata poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity)
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, tickLower, tickUpper, liquidity
             // Minimum length: 0xa0 + 0x20*4 = 0x120
             if lt(params.length, 0x120) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             tickLower := calldataload(add(params.offset, 0xc0))
             tickUpper := calldataload(add(params.offset, 0xe0))
             liquidity := calldataload(add(params.offset, 0x100))
         }
     }
 
     /// @dev DECREASE_LIQUIDITY: (PoolKey, uint256, uint256, uint256, uint128, uint128)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return amountToDecrease The amount of liquidity to remove
     /// @return amount0Min Minimum per-leg immediate non-fee LCC token0 out after fee netting (see `LiquidityUtils.forwardedNonFeeLccAmount`; commit surplus is locker credit)
     /// @return amount1Min Minimum immediate non-fee LCC token1 out
     function decodeDecreaseLiquidityParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             uint256 positionIndex,
             uint256 amountToDecrease,
             uint128 amount0Min,
             uint128 amount1Min
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amountToDecrease, amount0Min, amount1Min
             // Minimum length: 0xa0 + 0x20*5 = 0x140
             if lt(params.length, 0x140) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             amountToDecrease := calldataload(add(params.offset, 0xe0))
             amount0Min := calldataload(add(params.offset, 0x100))
             amount1Min := calldataload(add(params.offset, 0x120))
         }
     }
 
     /// @dev BURN_POSITION: (PoolKey, uint256, uint256, uint128, uint128)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return amount0Min Minimum per-leg immediate non-fee LCC token0 when burning (same semantics as decrease min-out)
     /// @return amount1Min Minimum immediate non-fee LCC token1 out
     function decodeBurnPositionParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             uint256 positionIndex,
             uint128 amount0Min,
             uint128 amount1Min
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amount0Min, amount1Min
             // Minimum length: 0xa0 + 0x20*4 = 0x120
             if lt(params.length, 0x120) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             amount0Min := calldataload(add(params.offset, 0xe0))
             amount1Min := calldataload(add(params.offset, 0x100))
         }
     }
 
     /// @dev SEIZE_POSITION: (PoolKey, uint256, uint256, uint256, uint256, bool)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return amount0 The amount of token0 for seizure
     /// @return amount1 The amount of token1 for seizure
     /// @return usePositionManagerBalance If true, tokens flow via MMPM balance and locker's deltas are adjusted
     function decodeSeizePositionParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             uint256 positionIndex,
             uint256 amount0,
             uint256 amount1,
             bool usePositionManagerBalance
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amount0, amount1, usePositionManagerBalance
             // Minimum length: 0xa0 + 0x20*5 = 0x140
             if lt(params.length, 0x140) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             amount0 := calldataload(add(params.offset, 0xe0))
             amount1 := calldataload(add(params.offset, 0x100))
             usePositionManagerBalance := calldataload(add(params.offset, 0x120))
         }
     }
 
     // ═══════════════════════════════════════════════════════════════════════════════════════════
     // Medium Priority Decoders (Delta Operations & Signal Management)
     // ═══════════════════════════════════════════════════════════════════════════════════════════
 
     /// @dev INCREASE_LIQUIDITY_FROM_DELTAS: (PoolKey, uint256, uint256, uint128, uint128, bool)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return amount0Max The maximum amount of token0 to spend
     /// @return amount1Max The maximum amount of token1 to spend
     /// @return payerIsUser If true, user consumes credit protocol owes them (MMPM delta).
     ///         If false, uses locker's direct credit.
+    // TODO[SLIPPAGE-GUARD]: Add guarded variants that include minLiquidity and optional price/tick bounds.
+    // Introduce new action codes to keep backward compatibility; enforce guards in MMPositionActionsImpl.
     function decodeIncreaseFromDeltasParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             uint256 positionIndex,
             uint128 amount0Max,
             uint128 amount1Max,
             bool payerIsUser
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amount0Max, amount1Max, payerIsUser
             // Minimum length: 0xa0 + 0x20*5 = 0x140
             if lt(params.length, 0x140) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             amount0Max := calldataload(add(params.offset, 0xe0))
             amount1Max := calldataload(add(params.offset, 0x100))
             payerIsUser := calldataload(add(params.offset, 0x120))
         }
     }
 
     /// @dev MINT_POSITION_FROM_DELTAS: (PoolKey, uint256, int24, int24, uint128, uint128, bool)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return tickLower The lower tick of the position
     /// @return tickUpper The upper tick of the position
     /// @return amount0Max The maximum amount of token0 to spend
     /// @return amount1Max The maximum amount of token1 to spend
     /// @return payerIsUser If true, user consumes credit protocol owes them (MMPM delta).
     ///         If false, uses locker's direct credit.
+    // TODO[SLIPPAGE-GUARD]: Add guarded variants that include minLiquidity and optional price/tick bounds.
+    // Introduce new action codes to keep backward compatibility; enforce guards in MMPositionActionsImpl.
     function decodeMintFromDeltasParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             int24 tickLower,
             int24 tickUpper,
             uint128 amount0Max,
             uint128 amount1Max,
             bool payerIsUser
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, tickLower, tickUpper, amount0Max, amount1Max, payerIsUser
             // Minimum length: 0xa0 + 0x20*6 = 0x160
             if lt(params.length, 0x160) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             tickLower := calldataload(add(params.offset, 0xc0))
             tickUpper := calldataload(add(params.offset, 0xe0))
             amount0Max := calldataload(add(params.offset, 0x100))
             amount1Max := calldataload(add(params.offset, 0x120))
             payerIsUser := calldataload(add(params.offset, 0x140))
         }
     }
 
     /// @dev SETTLE_POSITION_FROM_DELTAS: (PoolKey, uint256, uint256, bool, bool, bool)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return payerIsUser If true, use protocol delta (address(this)). If false, use locker delta (msgSender()).
     /// @return shouldTake If true, withdraw (consume credit). If false, deposit (settle credit into position).
     function decodeSettleFromDeltasParams(bytes calldata params)
         internal
         pure
         returns (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, bool payerIsUser, bool shouldTake)
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, payerIsUser, shouldTake
             // Minimum length: 0xa0 + 0x20*4 = 0x120
             if lt(params.length, 0x120) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             payerIsUser := calldataload(add(params.offset, 0xe0))
             shouldTake := calldataload(add(params.offset, 0x100))
         }
     }
 
     /// @dev DECOMMIT_SIGNAL: (uint256)
     /// @param params The calldata bytes to decode
     /// @return tokenId The commitment NFT token ID
     function decodeDecommitSignalParams(bytes calldata params) internal pure returns (uint256 tokenId) {
         assembly ("memory-safe") {
             // tokenId: 1 slot (0x20)
             // Minimum length: 0x20
             if lt(params.length, 0x20) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             tokenId := calldataload(params.offset)
         }
     }
 
     /// @dev EXTEND_GRACE_PERIOD: (PoolKey, uint256, uint256, uint8, uint32, bytes)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return settlementTokenIndex The index of the settlement token
     /// @return verifierIndex The verifier index
     /// @return settlementProof The settlement proof bytes
     function decodeExtendGracePeriodParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             uint256 positionIndex,
             uint8 settlementTokenIndex,
             uint32 verifierIndex,
             bytes calldata settlementProof
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId (0x20), positionIndex (0x20), settlementTokenIndex (0x20), verifierIndex (0x20)
             // settlementProof offset pointer is at 0x120 (after all fixed-size params)
             // Minimum length: 0x120 + 0x20 (offset pointer) + 0x20 (length) = 0x160
             if lt(params.length, 0x160) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             settlementTokenIndex := calldataload(add(params.offset, 0xe0))
             verifierIndex := calldataload(add(params.offset, 0x100))
 
             // Read the offset pointer for settlementProof (dynamic bytes, index 5)
             // The offset pointer is stored at params.offset + 0x120 (after all fixed-size params)
             let proofOffsetPtr := add(params.offset, 0x120)
             let proofDataOffset := add(params.offset, and(calldataload(proofOffsetPtr), OFFSET_OR_LENGTH_MASK))
 
             // Read the length of the bytes
             let proofLength := and(calldataload(proofDataOffset), OFFSET_OR_LENGTH_MASK)
 
             // Set settlementProof calldata slice
             settlementProof.offset := add(proofDataOffset, 0x20)
             settlementProof.length := proofLength
 
             // Verify the bytes string fits within params
             if lt(add(params.length, params.offset), add(settlementProof.length, settlementProof.offset)) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
         }
     }
 
     /// @dev COMMIT_SIGNAL: (bytes liquiditySignal, bytes relayParams)
     /// @param params The calldata bytes to decode
     /// @return liquiditySignal The liquidity signal bytes
     /// @return relayParams Optional relayer auth params encoded as
     ///         `(uint256 deadline, uint256 authNonce, bytes authSig, address sender)`.
     ///         When non-empty, EIP-712 `RelayAuth.sender` is supplied as `sender` (`address(0)` means mint to
     ///         `mmState.owner`; otherwise must equal the batch locker / NFT recipient) while VRL `signer` remains
     ///         `mmState.owner`.
     function decodeCommitSignalParams(bytes calldata params)
         internal
         pure
         returns (bytes calldata liquiditySignal, bytes calldata relayParams)
     {
         assembly ("memory-safe") {
             // ABI encoding: (bytes liquiditySignal, bytes relayParams)
             // Minimum length for empty bytes fields:
             // - head (2 words): offset, offset => 0x40
             // - tails (2 length words)                => 0x40
             // total                               => 0x80
             if lt(params.length, 0x80) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
         }
         // Use CalldataDecoder.toBytes for dynamic bytes (index 0 = 1st argument)
         liquiditySignal = params.toBytes(0);
         relayParams = params.toBytes(1);
     }
 
     /// @dev RENEW_SIGNAL: (uint256, bytes, bytes relayParams)
     /// @param params The calldata bytes to decode
     /// @return tokenId The commitment NFT token ID
     /// @return data The liquidity signal bytes
     /// @return relayParams Optional relayer auth params encoded as
     ///         `(uint256 deadline, uint256 authNonce, bytes authSig, address sender)` (renew: typed-data
     ///         `RelayAuth.sender` must be `address(0)`).
     function decodeTokenIdAndBytes(bytes calldata params)
         internal
         pure
         returns (uint256 tokenId, bytes calldata data, bytes calldata relayParams)
     {
         assembly ("memory-safe") {
             // ABI encoding: (uint256 tokenId, bytes data, bytes relayParams)
             // Minimum length for empty bytes fields:
             // - head (3 words): tokenId, offset, offset => 0x60
             // - tails (2 length words)                  => 0x40
             // total                                      => 0xa0
             if lt(params.length, 0xa0) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             tokenId := calldataload(params.offset)
         }
         // Use CalldataDecoder.toBytes for dynamic bytes (index 1 = 2nd argument)
         data = params.toBytes(1);
         relayParams = params.toBytes(2);
     }
 
     /// @dev CHECKPOINT: (uint256, uint256, bool)
     /// @param params The calldata bytes to decode
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The index of the position within the commitment
     /// @return withCommitment Whether to run commitment backing checks
     function decodeCheckpointParams(bytes calldata params)
         internal
         pure
         returns (uint256 tokenId, uint256 positionIndex, bool withCommitment)
     {
         assembly ("memory-safe") {
             // ABI encoding: (uint256 tokenId, uint256 positionIndex, bool withCommitment)
             // Minimum length: 3 words = 0x60
             if lt(params.length, 0x60) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             tokenId := calldataload(params.offset)
             positionIndex := calldataload(add(params.offset, 0x20))
             // Head layout: tokenId @ 0x00, positionIndex @ 0x20, withCommitment @ 0x40
             withCommitment := calldataload(add(params.offset, 0x40))
         }
     }
 
     // ═══════════════════════════════════════════════════════════════════════════════════════════
     // Low Priority Decoders (Simple Types)
     // ═══════════════════════════════════════════════════════════════════════════════════════════
 
     /// @dev UNWRAP_LCC: (address, uint256, address, bool)
     /// @param params The calldata bytes to decode
     /// @return lccAddr The LCC token address
     /// @return amount The amount to unwrap
     /// @return recipient The recipient address
     /// @return payerIsUser Whether the payer is the user
     function decodeUnwrapLccParams(bytes calldata params)
         internal
         pure
         returns (address lccAddr, uint256 amount, address recipient, bool payerIsUser)
     {
         assembly ("memory-safe") {
             if lt(params.length, 0x80) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             lccAddr := calldataload(params.offset)
             amount := calldataload(add(params.offset, 0x20))
             recipient := calldataload(add(params.offset, 0x40))
             payerIsUser := calldataload(add(params.offset, 0x60))
         }
     }
 
     /// @dev COLLECT_AVAILABLE_LIQUIDITY: `(address lcc, uint256 maxAmount)` — **0x40** bytes; locker’s custodian scope.
     /// @param params The calldata bytes to decode
     /// @return lcc The LCC token address
     /// @return maxAmount The maximum amount to collect
     function decodeCollectLiquidityParams(bytes calldata params)
         internal
         pure
         returns (address lcc, uint256 maxAmount)
     {
         if (params.length != 0x40) {
             revert SliceOutOfBounds();
         }
         assembly ("memory-safe") {
             lcc := calldataload(params.offset)
             maxAmount := calldataload(add(params.offset, 0x20))
         }
     }
 
     /// @dev INITIALISE: no calldata words (must be exactly empty).
     function decodeInitialiseParams(bytes calldata params) internal pure {
         if (params.length != 0) {
             revert SliceOutOfBounds();
         }
     }
 
     /// @dev UNWRAP_NATIVE: (uint256, bool)
     /// @param params The calldata bytes to decode
     /// @return amount The amount to unwrap
     /// @return payerIsUser Whether the payer is the user
     function decodeUint256AndBool(bytes calldata params) internal pure returns (uint256 amount, bool payerIsUser) {
         assembly ("memory-safe") {
             if lt(params.length, 0x40) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             amount := calldataload(params.offset)
             payerIsUser := calldataload(add(params.offset, 0x20))
         }
     }
 
     /// @dev TAKE: (Currency, address, uint256)
     /// @notice Reuses Uniswap's decodeCurrencyAddressAndUint256 pattern
     /// @param params The calldata bytes to decode
     /// @return currency The currency to take
     /// @return recipient The recipient address
     /// @return maxAmount The maximum amount to take
     function decodeTakeParams(bytes calldata params)
         internal
         pure
         returns (Currency currency, address recipient, uint256 maxAmount)
     {
         assembly ("memory-safe") {
             if lt(params.length, 0x60) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             currency := calldataload(params.offset)
             recipient := calldataload(add(params.offset, 0x20))
             maxAmount := calldataload(add(params.offset, 0x40))
         }
     }
 
     /// @dev WRAP_NATIVE: (uint256)
     /// @notice Reuses Uniswap's decodeUint256 pattern
     /// @param params The calldata bytes to decode
     /// @return amount The amount to wrap
     function decodeUint256(bytes calldata params) internal pure returns (uint256 amount) {
         assembly ("memory-safe") {
             if lt(params.length, 0x20) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             amount := calldataload(params.offset)
         }
     }
 
     /// @dev SYNC: (Currency)
     /// @param params The calldata bytes to decode
     /// @return currency The currency to sync
     /// @dev owner is always address(this) (MMPM) and target is always msgSender() (locker)
     function decodeSyncParams(bytes calldata params) internal pure returns (Currency currency) {
         assembly ("memory-safe") {
             if lt(params.length, 0x20) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             currency := calldataload(params.offset)
         }
     }
 }
```

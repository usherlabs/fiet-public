[High] Router-global owner credits not provenance-bound in MMPositionActionsImpl allow cross-tenant vault reserve theft

# Description

Underlying credits created during one maker’s position flow are keyed to the router (MMPositionManager) and can be withdrawn or used by any other maker owning any tokenId on the same router via *_FROM_DELTAS/SETTLE_POSITION_FROM_DELTAS, because [authorization only checks destination NFT ownership](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMPositionActionsImpl.sol#L506-L524) and not the origin of credits.

In MMPositionManager-based markets, VTS owner-scoped deltas (OwnerCurrencyDelta) are keyed by (owner, currency), where owner for MM positions is the router contract address. During MM decreases and especially seizure decreases on a victim’s active position, [VTSPositionMMOpsLib._applyPositiveRequiredSettlementToOwnerAndVault](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L170-L206) books immediate settleable underlying to OwnerCurrencyDelta(owner=router) and reduces vault reserves. Later in the same batch, [MMPositionActionsImpl._settleFromDeltas](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMPositionActionsImpl.sol#L778) and *_FROM_DELTAS [using _getFullCreditPair(..., address(this))](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/modules/PositionManagerImpl.sol#L108-L118) read these router-global credits and allow spending them after only verifying that msgSender() is approved/owner of the destination tokenId ([MMHelpers.assertApprovedOrOwner](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMPositionActionsImpl.sol#L506-L524)). There is no provenance binding between credits and the commit/position that generated them. Consequently, a malicious maker who also holds any commitment NFT on the same router can first execute a permissionless SEIZE_POSITION on a victim to surface router-global credits, then immediately withdraw those credits via SETTLE_POSITION_FROM_DELTAS with payerIsUser=true and shouldTake=true (or convert them into their own position’s liquidity via MINT/INCREASE_FROM_DELTAS). [VTSOrchestrator.onMMSettle further permits inactive withdraw-only settlements without a live signal](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/VTSOrchestrator.sol#L748-L758), making immediate extraction to the attacker feasible. [End-of-batch delta zeroing still holds](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L76-L80) because the attacker’s consumption nets owner deltas to zero; however, the market vault suffers a direct principal loss.

# Severity

**Impact Explanation:** [High] The attacker can directly withdraw underlying from the market vault or appropriate reserve-backed value into their own liquidity, causing a direct, material loss of principal from protocol reserves.

**Likelihood Explanation:** [Medium] Exploitation requires multi-tenant router deployment, attacker legitimately owning a tokenId under the same router, the presence of a seizable victim position, and some vault settleable capacity; these are realistic but not guaranteed at all times.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Seize-and-withdraw to attacker’s inactive position: In one batch, the attacker calls SEIZE_POSITION on a victim’s active, seizable position, creating router-global underlying credits and reducing vault reserves; then calls SETTLE_POSITION_FROM_DELTAS on their own inactive tokenId (payerIsUser=true, shouldTake=true). Authorization passes on the attacker’s tokenId; VTS allows inactive withdraw-only without live signal; underlying is transferred from the vault to the attacker.
#### Preconditions / Assumptions
- (a). A shared (multi-tenant) MMPositionManager is used by multiple makers
- (b). Attacker owns at least one commitment NFT under the same router and pool with an inactive position
- (c). Victim has an active, seizable position in the same pool (grace elapsed)
- (d). Market vault has immediate settleable capacity for the victim’s decrease (per dryModifyLiquidities)

### Scenario 2.
Seize-and-mint/increase from deltas: The attacker first seizes the victim’s position to create router-global credits, then calls MINT_POSITION_FROM_DELTAS or INCREASE_LIQUIDITY_FROM_DELTAS on their own tokenId with payerIsUser=true. In-hook settlement consumes router-global credits to fund the attacker’s added liquidity before LCC issuance; vault reserves are already reduced, and the attacker appropriates backing into their position.
#### Preconditions / Assumptions
- (a). A shared (multi-tenant) MMPositionManager is used by multiple makers
- (b). Attacker owns a position they can mint/increase on in the same pool
- (c). Victim has an active, seizable position in the same pool
- (d). Market vault has immediate settleable capacity for the victim’s decrease (per dryModifyLiquidities)

### Scenario 3.
Seize-and-withdraw to attacker’s active position with live signal: The attacker maintains a live VRL signal for their own commit. After seizing the victim to create router-global credits, the attacker calls SETTLE_POSITION_FROM_DELTAS (payerIsUser=true, shouldTake=true) on their active tokenId. Live-signal checks pass, and underlying is withdrawn from the vault to the attacker.
#### Preconditions / Assumptions
- (a). A shared (multi-tenant) MMPositionManager is used by multiple makers
- (b). Attacker owns an active tokenId in the same pool with a live VRL signal
- (c). Victim has an active, seizable position in the same pool
- (d). Market vault has immediate settleable capacity for the victim’s decrease (per dryModifyLiquidities)

# Proposed fix

## MMPositionActionsImpl.sol

File: `contracts/evm/src/MMPositionActionsImpl.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMPositionActionsImpl.sol)

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
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Position Action Handler
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc IMMActionsImpl
     /// @dev Only handles position operations (actions <= SETTLE_POSITION_FROM_DELTAS)
     function handleAction(uint256 action, bytes calldata params) external payable override onlyDelegateCall {
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
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 int24 tickLower,
                 int24 tickUpper,
                 uint256 liquidity,
                 uint128 amount0Max,
                 uint128 amount1Max
             ) = params.decodeMintPositionParams();
             _mintPosition(poolKey, tokenId, tickLower, tickUpper, liquidity, amount0Max, amount1Max);
             return;
         }
         if (action == MMActions.INCREASE_LIQUIDITY) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint256 liquidity,
                 uint128 amount0Max,
                 uint128 amount1Max
             ) = params.decodeIncreaseLiquidityParams();
             _increase(poolKey, tokenId, positionIndex, liquidity, amount0Max, amount1Max);
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
             // Native: exact; ERC20: exact from settlement delta (not omnibus MMPM balance sync)
             if (delta0 > 0) {
                 uint256 amt0Out = LiquidityUtils.safeInt128ToUint256(delta0);
                 _creditExact(params.underlying0, amt0Out);
             }
             if (delta1 > 0) {
                 uint256 amt1Out = LiquidityUtils.safeInt128ToUint256(delta1);
                 _creditExact(params.underlying1, amt1Out);
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
 
             // AUTH-01A: only the primary `SEIZE_POSITION` deposit settle may bypass NFT owner checks. All follow-on
             // settles (including seizing withdrawals) require `approvedOrOwner` so a seizer cannot drain router-scoped
             // underlying credit without commitment NFT authorisation.
             bool isDepositLane = (amount0 < 0) || (amount1 < 0);
             if (isSeizing && isDepositLane && !TransientSlots.getSeizurePrimarySettleAllowed()) {
                 revert Errors.SeizureSettleOnlyDepositDisallowed();
             }
             bool inPrimarySeizeSettle = isSeizing && TransientSlots.getSeizurePrimarySettleAllowed() && isDepositLane;
             if (!inPrimarySeizeSettle) {
                 MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
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
     /// @param amount0Max Maximum token0 principal spend (LCC leg)
     /// @param amount1Max Maximum token1 principal spend
     function _increase(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 liquidity,
         uint128 amount0Max,
         uint128 amount1Max
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
         (, BalanceDelta principalDelta) =
             _increaseInternal(poolKey, tokenId, positionIndex, position.tickLower, position.tickUpper, liquidity);
         _validateMaxIn(principalDelta, amount0Max, amount1Max);
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
+        // Temporary hardening: disallow protocol-credit (router-global) usage to prevent cross-tenant spend.
+        if (payerIsUser) revert Errors.TransferNotAllowed();
+
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
     /// @param amount0Max Maximum token0 principal spend (LCC leg)
     /// @param amount1Max Maximum token1 principal spend
     function _mintPosition(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity,
         uint128 amount0Max,
         uint128 amount1Max
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         (,, BalanceDelta principalDelta) = _mintPositionInternal(poolKey, tokenId, tickLower, tickUpper, liquidity);
         _validateMaxIn(principalDelta, amount0Max, amount1Max);
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
+        // Temporary hardening: disallow protocol-credit (router-global) usage to prevent cross-tenant spend.
+        if (payerIsUser) revert Errors.TransferNotAllowed();
+
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
+        // Temporary hardening: disallow protocol-credit (router-global) usage to prevent cross-tenant spend.
+        if (payerIsUser) revert Errors.TransferNotAllowed();
+
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

# Related findings

## [High] FCFS balance-to-credit sync without provenance in OwnerCurrencyDelta/VTSOrchestrator causes theft of manager-held ERC20/LCC via SYNC+TAKE

### Description

SYNC maps the MMPositionManager’s live ERC20/LCC balance to the caller’s positive credit without provenance or last-seen tracking, and [TAKE then withdraws those tokens to arbitrary recipients](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/modules/PositionManagerBase.sol#L73-L74), enabling theft of any residue left on the manager across transactions.

[OwnerCurrencyDelta.syncBalanceAsCredit](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/libraries/OwnerCurrencyDelta.sol#L176-L195) raises a target’s positive delta up to balanceOf(owner) when target is not in debt, with no provenance or last-synced baseline. MMUtilityActionsImpl exposes this as [SYNC](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/modules/PositionManagerBase.sol#L50-L53), passing owner=MMPositionManager and target=locker. VTSOrchestrator.sync only checks the manager is factory-bound and then calls [syncBalanceAsCredit](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/libraries/OwnerCurrencyDelta.sol#L176-L195). PositionManagerBase._take then [transfers tokens from the manager to the specified recipient](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/modules/PositionManagerBase.sol#L73-L74) after reducing the locker’s delta. [End-of-batch assertions only ensure transient deltas are zero](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/libraries/OwnerCurrencyDelta.sol#L156-L161); token balances on the manager persist across transactions. As a result, any ERC20/LCC left on the manager (e.g., via ERC20 self-take to address(this) or surplus LCC after decreases) can be claimed by whoever calls SYNC first and then withdrawn with TAKE.

### Severity

**Impact Explanation:** [High] Direct, material loss of principal funds: attacker withdraws ERC20/LCC tokens left on the MMPositionManager.

**Likelihood Explanation:** [Medium] Requires the manager to hold residue at transaction start; this arises from supported, documented flows (e.g., ERC20 self-take to address(this), surplus LCC after decreases) and is plausible though not guaranteed in every integration.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
A user previously clears their positive ERC20 delta using [TAKE(ERC20, to=address(this))](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/modules/PositionManagerBase.sol#L61-L66), which is allowed for ERC20 and leaves the tokens on the MMPositionManager across transactions. In a later transaction, an attacker calls [SYNC(ERC20)](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/modules/PositionManagerBase.sol#L50-L53) to map the manager’s ERC20 balance to their own positive credit, then calls [TAKE(ERC20, to=attacker)](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/modules/PositionManagerBase.sol#L73-L74) to withdraw the tokens.
#### Preconditions / Assumptions
- (a). MMPositionManager holds a non-zero ERC20 balance at the start of the attacker’s transaction.
- (b). The balance resulted from a prior allowed action: [TAKE(ERC20, to=address(this))](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/modules/PositionManagerBase.sol#L61-L66) reduced a locker’s delta without moving tokens off the manager.
- (c). No provenance or per-locker attribution binds the manager’s balance to a specific user.
- (d). Attacker can call SYNC and TAKE via the MMPositionManager (manager is factory-bound; SYNC has no per-user auth).

### Scenario 2.
After a liquidity decrease, LCC is minted to the MMPositionManager; only the queued (qCommitted) slice is forwarded to the custodian, leaving surplus LCC on the manager. The user clears remaining LCC delta via [TAKE(LCC, to=address(this))](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/modules/PositionManagerBase.sol#L61-L66), leaving those LCC on the manager at the end of the batch. In a later transaction, an attacker calls [SYNC(LCC)](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/modules/PositionManagerBase.sol#L50-L53) to map the manager’s LCC balance to their credit and [TAKE(LCC, to=attacker)](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/modules/PositionManagerBase.sol#L73-L74) to withdraw. The attacker may then INITIALISE a custodian and UNWRAP_LCC(payerIsUser=true) to realize underlying.
#### Preconditions / Assumptions
- (a). A prior decrease minted LCC to the manager; only the qCommitted portion was forwarded to the custodian, leaving surplus on the manager.
- (b). The user cleared remaining LCC delta via [TAKE(LCC, to=address(this))](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/modules/PositionManagerBase.sol#L61-L66), leaving LCC on the manager across transactions.
- (c). Attacker can invoke SYNC and TAKE without additional authorization; LCC transfers from protocol-bound manager to EOA are permitted.
- (d). Optional for full monetization: attacker can INITIALISE a custodian and UNWRAP_LCC(payerIsUser=true) to convert stolen LCC to underlying.

### Proposed fix

#### MMUtilityActionsImpl.sol

File: `contracts/evm/src/MMUtilityActionsImpl.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMUtilityActionsImpl.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 import {Locker} from "v4-periphery/src/libraries/Locker.sol";
 import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
 import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 
 import {FietNativeWrapper} from "./modules/NativeWrapper.sol";
 import {PositionManagerImpl} from "./modules/PositionManagerImpl.sol";
 import {DelegateCallGuard} from "./modules/DelegateCallGuard.sol";
 import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
 import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {MMActions} from "./libraries/MMActions.sol";
 import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
 import {MMHelpers} from "./libraries/MMHelpers.sol";
 import {MMQueueCustodianLib} from "./libraries/MMQueueCustodianLib.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 
 /// @title MMUtilityActionsImpl
 /// @notice Delegatecall module for MMPositionManager utility actions (>= `MMActions.TAKE`).
 /// @dev `INITIALISE` stays on `MMPositionManager` because it writes `custodianFor` (manager storage layout).
 contract MMUtilityActionsImpl is IMMActionsImpl, PositionManagerImpl, FietNativeWrapper, DelegateCallGuard {
     using MMCalldataDecoder for bytes;
     using CurrencyTransfer for Currency;
     using MMQueueCustodianLib for IMMPositionManager;
 
     constructor(
         IPoolManager poolManager,
         address marketFactory,
         address vtsOrchestrator,
         address canonicalCustody,
         IWETH9 weth9
     ) PositionManagerImpl(poolManager, marketFactory, vtsOrchestrator, canonicalCustody) FietNativeWrapper(weth9) {}
 
     function _mmpm() private view returns (IMMPositionManager) {
         return IMMPositionManager(address(this));
     }
 
     /// @notice Locker for batched MM actions (same semantics as `MMPositionActionsImpl`).
     function msgSender() public view override returns (address) {
         return Locker.get();
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
         return _mmpm().isRegisteredCustodian(candidate);
     }
 
     /// @inheritdoc IMMActionsImpl
     /// @dev Only utility actions (>= `TAKE`). `INITIALISE` is handled on the manager entry contract.
     function handleAction(uint256 action, bytes calldata params) external payable override onlyDelegateCall {
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
         if (action == MMActions.COLLECT_AVAILABLE_LIQUIDITY) {
             (address lcc, uint256 maxAmount) = params.decodeCollectLiquidityParams();
             _collectAvailableLiquidity(lcc, maxAmount);
             return;
         }
         if (action == MMActions.SYNC) {
-            Currency currency = params.decodeSyncParams();
-            _sync(currency);
-            return;
+            revert Errors.UnsupportedAction(action);
         }
         revert Errors.UnsupportedAction(action);
     }
 
     function _mapRecipient(address recipient) internal view returns (address) {
         if (recipient == ActionConstants.MSG_SENDER) {
             return msgSender();
         } else if (recipient == ActionConstants.ADDRESS_THIS) {
             return address(this);
         } else {
             return recipient;
         }
     }
 
     /// @dev UNWRAP_LCC payout may only go to the locker or MMPM; arbitrary third-party recipients are disallowed.
     function _resolveStrictRecipient(address recipient) internal view returns (address) {
         address to = _mapRecipient(recipient);
         if (to != msgSender() && to != address(this)) {
             revert Errors.NotApproved(to);
         }
         return to;
     }
 
     function _unwrapToQueueForward(
         address lccAddr,
         Currency lccCurrency,
         address forwardUnderlyingTo,
         address beneficiary,
         uint256 toUnwrap
     ) private {
         if (toUnwrap == 0) return;
         MMHelpers.assertQueueCustodianForRecipient(beneficiary);
         address custAddr = _mmpm().custodianFor(beneficiary);
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
         lccCurrency.transfer(custAddr, toUnwrap);
         custodian.unwrapLcc(lccAddr, forwardUnderlyingTo, toUnwrap);
     }
 
     function _unwrapLccFromDeltas(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
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
             _creditExact(Currency.wrap(underlying), unwrapped);
         }
     }
 
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
             lccCurrency.transferFrom(payer, address(this), toUnwrap);
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, payer, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _creditExact(Currency.wrap(underlying), unwrapped);
         }
     }
 
     function _collectAvailableLiquidity(address lcc, uint256 maxAmount) internal {
         if (maxAmount == 0) return;
 
         address locker = msgSender();
         MMHelpers.assertQueueCustodianForRecipient(locker);
         address custAddr = _mmpm().custodianFor(locker);
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         if (IMMQueueCustodian(custAddr).beneficiary() != locker) {
             revert Errors.InvalidSender();
         }
 
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
 
         address underlyingAddr = ILCC(lcc).underlying();
         bool isNativeUnderlying = underlyingAddr == address(0);
 
         uint256 remaining =
             _collectSettleHubQueueForCustodian(custodian, custAddr, lcc, underlyingAddr, isNativeUnderlying, maxAmount);
         _releasePreSettledCustodianUnderlying(custodian, custAddr, lcc, underlyingAddr, isNativeUnderlying, remaining);
     }
 
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
 
     function _sync(Currency currency) internal {
         if (currency == CurrencyLibrary.ADDRESS_ZERO) {
             revert Errors.InvalidAddress(address(0));
         }
         vtsOrchestrator.sync(marketFactory, currency, address(this), msgSender());
     }
 
     /// @dev Resolves `requested` against the locker’s delta via `take` (`requested == 0` takes full credit).
     /// @return amount Amount to apply downstream (0 means no-op).
     function _resolveDeltaTakeAmount(Currency currency, uint256 requested) private returns (uint256 amount) {
         uint256 takeAmount = vtsOrchestrator.take(currency, msgSender(), requested);
         if (requested > 0 && requested > takeAmount) {
             revert Errors.InsufficientBalance(takeAmount, requested);
         }
         amount = requested == 0 ? takeAmount : requested;
     }
 
     function _wrapNative(uint256 amount) internal {
         amount = _resolveDeltaTakeAmount(CurrencyLibrary.ADDRESS_ZERO, amount);
         if (amount == 0) {
             return;
         }
 
         _wrap(amount);
         // Exact WETH minted: do not attribute full MMPM WETH balance
         _creditExact(Currency.wrap(address(WETH9)), amount);
     }
 
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
             amount = _resolveDeltaTakeAmount(weth, amount);
             if (amount == 0) {
                 return;
             }
         }
         _unwrap(amount);
         _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
     }
 }
```

#### PositionManagerBase.sol

File: `contracts/evm/src/modules/PositionManagerBase.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/modules/PositionManagerBase.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {ImmutableVTSState} from "./ImmutableVTSState.sol";
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {ILCC} from "../interfaces/ILCC.sol";
 import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";
 import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
 import {Errors} from "../libraries/Errors.sol";
 
 /**
  * @title PositionManagerBase
  * @notice Base contract providing shared functionality for position management
  * @dev Contains abstract functions and shared currency detection utilities
  * @dev Note: ImmutableState is provided by inheriting contracts (BaseActionsRouter for entrypoint, direct for impl)
  */
 abstract contract PositionManagerBase is ImmutableVTSState {
     using CurrencyLibrary for Currency;
 
     ILiquidityHub internal immutable liquidityHub;
     IMarketFactory internal immutable marketFactory;
     /// @notice Factory-scoped canonical custody used at batch finality and for settlement transfers.
     address internal immutable canonicalCustody;
 
     constructor(address _marketFactory, address _vtsOrchestrator, address _canonicalCustody)
         ImmutableVTSState(_vtsOrchestrator)
     {
         if (_canonicalCustody == address(0)) revert Errors.InvalidAddress(_canonicalCustody);
         marketFactory = IMarketFactory(_marketFactory);
         liquidityHub = marketFactory.liquidityHub();
         canonicalCustody = _canonicalCustody;
     }
 
     // ------------------------------------------------------------------------------------------------
     // ABSTRACT FUNCTIONS (must be implemented by inheriting contracts)
     // ------------------------------------------------------------------------------------------------
 
     /// @notice Returns the locker address (original caller of the batch)
     /// @dev Must be implemented by inheriting contracts (e.g., via BaseActionsRouter._getLocker())
     function msgSender() public view virtual returns (address);
 
     // ------------------------------------------------------------------------------------------------
     // SHARED UTILITIES
     // ------------------------------------------------------------------------------------------------
 
     /// @notice Converts LCC currency to underlying currency
     /// @param lcc The LCC currency
     /// @return The underlying currency
     function _lccToUnderlyingCurrency(Currency lcc) internal view returns (Currency) {
         return Currency.wrap(ILCC(Currency.unwrap(lcc)).underlying());
     }
 
     /// @notice Checks if a currency is an LCC token
     /// @param currency The currency to check
     /// @return True if the currency is a valid LCC token
     function _isLCC(Currency currency) internal view returns (bool) {
         address token = Currency.unwrap(currency);
         if (token == address(0)) return false;
         return liquidityHub.isLCC(token);
     }
 
     /// @notice Syncs balance accumulation as credit for a single currency
     /// @dev Only handles balance increases (accumulation), not decreases (consumption).
     ///      Checks MMPM's balance (address(this)) and credits locker's delta (msgSender).
     ///      This ensures balance increases from wrap/unwrap operations create takeable credits on the locker.
     /// @param currency The currency to sync balance for
     function _syncBalanceAsCredit(Currency currency) internal {
         // owner = address(this) = MMPM (balance holder)
         // target = msgSender() = locker (delta recipient)
         vtsOrchestrator.sync(marketFactory, currency, address(this), msgSender());
     }
 
     /// @notice Credits an exact known amount to the locker's delta
     /// @param currency The currency to credit
     /// @param amount The exact amount to credit
     function _creditExact(Currency currency, uint256 amount) internal {
         vtsOrchestrator.creditExact(marketFactory, currency, msgSender(), amount);
     }
 
     /// @notice Takes currency from delta and transfers to recipient (locker = `msgSender()`).
-    /// @dev Native `TAKE` to `address(this)` is disallowed: it would debit the locker's delta without moving ETH,
-    ///      stranding balance on MMPM with no native `SYNC` path (see `INVARIANTS.md` DELTA-02). ERC20 self-take
-    ///      remains valid and recoverable via `SYNC`.
+    /// @dev TAKE to `address(this)` is disallowed to prevent creating manager-held residues that can be incorrectly
+    ///      claimed by other lockers in later transactions.
     function _take(Currency currency, address to, uint256 maxAmount) internal {
-        if (currency == CurrencyLibrary.ADDRESS_ZERO && to == address(this)) {
+        if (to == address(this)) {
             revert Errors.InvalidAddress(to);
         }
         address locker = msgSender();
         uint256 bal = currency.balanceOfSelf();
         uint256 trueMaxAmount = (maxAmount == 0) ? bal : Math.min(maxAmount, bal);
         uint256 takeAmount = vtsOrchestrator.take(currency, locker, trueMaxAmount);
 
         if (to != address(this)) {
             currency.transfer(to, takeAmount);
         }
     }
 }
```

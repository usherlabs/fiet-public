// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
import {PositionId, PositionLibrary, PositionModificationHookDataLib} from "./types/Position.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {IMarketVault} from "./interfaces/IMarketVault.sol";
import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
import {Errors} from "./libraries/Errors.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
import {Position} from "./types/Position.sol";
import {TransientSlots} from "./libraries/TransientSlots.sol";
import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
import {PositionManagerQueueCustodian} from "./modules/PositionManagerQueueCustodian.sol";
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

/// @title MMPositionActionsImpl
/// @notice Implementation contract for MMPositionManager position operations
/// @dev Called via delegatecall from MMPositionManager, shares storage context
/// @dev Only handles position operations (actions <= SETTLE_POSITION_FROM_DELTAS)
/// @dev ERC721 functions accessed via delegatecall context from MMPositionManager
contract MMPositionActionsImpl is
    IMMActionsImpl,
    PositionManagerQueueCustodian,
    PositionManagerImpl,
    DelegateCallGuard
{
    using SafeCast for uint256;
    using PositionLibrary for PositionId;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using CurrencyTransfer for Currency;
    using MMCalldataDecoder for bytes;

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
        uint256 tokenId;
        uint256 positionIndex;
        Currency currency0;
        Currency currency1;
        BalanceDelta requestedDelta;
        bool isSeizing;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Immutables (must match MMPositionManager's values)
    // ═══════════════════════════════════════════════════════════════════════════

    // ═══════════════════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address _manager, address _marketFactory, address _vtsOrchestrator)
        PositionManagerImpl(IPoolManager(_manager), _marketFactory, _vtsOrchestrator)
    {}

    // ═══════════════════════════════════════════════════════════════════════════
    // Overrides for abstract functions
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc PositionManagerBase
    function msgSender() public view override returns (address) {
        // References locker from delegatecall context - MMPositionManager
        return Locker.get();
    }

    /// @inheritdoc PositionManagerQueueCustodian
    function _queueCustodian() internal view override(PositionManagerQueueCustodian) returns (IMMQueueCustodian) {
        return IMMPositionManager(address(this)).queueCustodian();
    }

    function _forwardQueuedLccToCustodian(Currency currency, uint256 tokenId, uint256 amount)
        internal
        override(PositionManagerImpl)
    {
        IMMQueueCustodian custodian = _queueCustodian();
        if (address(custodian) != address(0) && address(custodian) != address(this)) {
            currency.transfer(address(custodian), amount);
            if (tokenId > 0) {
                custodian.record(tokenId, Currency.unwrap(currency), amount);
            }
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
            (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint256 amountToDecrease) =
                params.decodeDecreaseLiquidityParams();
            _decrease(poolKey, tokenId, positionIndex, amountToDecrease);
            return;
        }
        if (action == MMActions.BURN_POSITION) {
            (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex) = params.decodeBurnPositionParams();
            _burnPosition(poolKey, tokenId, positionIndex);
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
            (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, bool payerIsUser) =
                params.decodeIncreaseFromDeltasParams();
            _increaseFromDeltas(poolKey, tokenId, positionIndex, payerIsUser);
            return;
        }
        if (action == MMActions.MINT_POSITION_FROM_DELTAS) {
            (PoolKey calldata poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, bool payerIsUser) =
                params.decodeMintFromDeltasParams();
            _mintFromDeltas(poolKey, tokenId, tickLower, tickUpper, payerIsUser);
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
        (BalanceDelta settlementDelta, uint256 seizedLiquidityUnits) = _settle(
            poolKey, tokenId, positionIndex, -amount0.toInt128(), -amount1.toInt128(), usePositionManagerBalance
        );

        // Use returned maxima clamped settlementDelta
        bytes memory hookData = PositionModificationHookDataLib.encodeSeizure(
            tokenId, positionIndex, msgSender(), settlementDelta.amount0(), settlementDelta.amount1()
        );

        _decreaseInternal(
            poolKey,
            position,
            PositionLibrary.generateSalt(tokenId, positionIndex),
            tokenId,
            seizedLiquidityUnits,
            hookData
        );
    }

    /// @notice Calls VTS orchestrator onMMSettle with bundled parameters
    /// @dev Extracted to reduce stack depth in _settle (avoids stack-too-deep with coverage instrumentation)
    /// @param params The call parameters bundled in a struct
    /// @return settlementDelta The settlement delta
    /// @return seizedLiquidityUnits The amount of liquidity units seized
    function _callOnMMSettle(SettleCallParams memory params)
        internal
        returns (BalanceDelta settlementDelta, uint256 seizedLiquidityUnits)
    {
        (settlementDelta,, seizedLiquidityUnits) = vtsOrchestrator.onMMSettle(
            params.vault,
            params.tokenId,
            params.positionIndex,
            params.currency0,
            params.currency1,
            params.requestedDelta,
            params.isSeizing
        );
    }

    /// @notice Processes settlement transfers for a position
    /// @dev Extracted to reduce stack depth in _settle (avoids stack-too-deep with coverage instrumentation)
    /// @param params The transfer parameters bundled in a struct
    /// @param settlementDelta The settlement delta from VTS
    function _processSettlementTransfers(SettleTransferParams memory params, BalanceDelta settlementDelta) internal {
        // Adheres to core/LCC pool token ordering.
        int128 delta0 = settlementDelta.amount0();
        int128 delta1 = settlementDelta.amount1();

        address sender = msgSender();

        // Process negative deltas (inflows to vault)
        if (delta0 < 0) {
            uint256 amt0 = LiquidityUtils.safeInt128ToUint256(delta0);
            if (params.usePositionManagerBalance) {
                // Ensure locker credit is fully consumed before moving pooled MMPM funds.
                uint256 taken0 = vtsOrchestrator.take(params.underlying0, sender, amt0);
                if (taken0 != amt0) {
                    revert Errors.InsufficientBalance(taken0, amt0);
                }
                params.underlying0.transfer(address(params.vault), amt0);
            } else {
                // Otherwise, pull only from the locker (msgSender()).
                params.underlying0.transferFrom(sender, address(params.vault), amt0);
            }
        }
        if (delta1 < 0) {
            uint256 amt1 = LiquidityUtils.safeInt128ToUint256(delta1);
            if (params.usePositionManagerBalance) {
                uint256 taken1 = vtsOrchestrator.take(params.underlying1, sender, amt1);
                if (taken1 != amt1) {
                    revert Errors.InsufficientBalance(taken1, amt1);
                }
                params.underlying1.transfer(address(params.vault), amt1);
            } else {
                params.underlying1.transferFrom(sender, address(params.vault), amt1);
            }
        }

        params.vault.modifyLiquidities(settlementDelta);

        // Process positive deltas (outflows from vault)
        if (params.usePositionManagerBalance) {
            // Either sync received amounts
            if (delta0 > 0 || delta1 > 0) {
                _syncPairBalanceAsCredit(params.underlying0, params.underlying1);
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

            callParams = SettleCallParams({
                vault: _getVault(poolKey),
                tokenId: tokenId,
                positionIndex: positionIndex,
                currency0: poolKey.currency0,
                currency1: poolKey.currency1,
                requestedDelta: toBalanceDelta(amount0, amount1),
                isSeizing: isSeizing
            });
        }

        // Call onMMSettle via helper
        (BalanceDelta settlementDelta, uint256 seizedLiquidityUnits) = _callOnMMSettle(callParams);

        // Process settlement transfers via helper (reduces stack depth)
        _processSettlementTransfers(
            SettleTransferParams({
                underlying0: _lccToUnderlyingCurrency(poolKey.currency0),
                underlying1: _lccToUnderlyingCurrency(poolKey.currency1),
                vault: callParams.vault,
                usePositionManagerBalance: usePositionManagerBalance
            }),
            settlementDelta
        );

        return (settlementDelta, seizedLiquidityUnits);
    }

    /// @notice Burns (fully decreases) a position
    /// @param poolKey The pool key
    /// @param tokenId The commitment NFT token ID
    /// @param positionIndex The position index within the commitment
    function _burnPosition(PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex) internal {
        MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);

        (Position memory position,) = getPosition(tokenId, positionIndex);
        MMHelpers.assertPositionForPool(poolKey, position);

        uint256 completeLiquidity = uint256(position.liquidity);
        _decreaseInternal(
            poolKey,
            position,
            PositionLibrary.generateSalt(tokenId, positionIndex),
            tokenId,
            completeLiquidity,
            PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender())
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
    function _increaseInternal(
        PoolKey calldata poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    ) internal returns (PositionId positionId) {
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
        bytes memory hookData = PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender());
        _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
    }

    /// @notice Increases liquidity using available delta credits
    /// @param poolKey The pool key
    /// @param tokenId The commitment NFT token ID
    /// @param positionIndex The position index within the commitment
    /// @param payerIsUser If true, user consumes credit the protocol owes them (delta target = MMPM).
    ///        If false, uses locker's direct credit (delta target = locker).
    /// @dev Delta target semantics:
    ///      - MMPM (address(this)): Protocol owes/is owed by external sources
    ///      - Locker (msgSender()): External entity owes/is owed by protocol
    /// @dev tickLower and tickUpper are read from the position via getPosition()
    function _increaseFromDeltas(PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, bool payerIsUser)
        internal
    {
        address sender = msgSender();
        MMHelpers.assertApprovedOrOwner(sender, tokenId);

        (Position memory position,) = getPosition(tokenId, positionIndex);
        MMHelpers.assertPositionForPool(poolKey, position);

        // payerIsUser = true: User consumes credit protocol owes them (tracked on MMPM)
        // payerIsUser = false: Locker uses their own direct credit
        address deltaTarget = payerIsUser ? address(this) : sender;
        (uint256 liquidityFromDeltas, uint256 credit0, uint256 credit1) =
            _getLiquidityFromDeltas(poolKey, deltaTarget, position.tickLower, position.tickUpper);
        _increaseInternal(poolKey, tokenId, positionIndex, position.tickLower, position.tickUpper, liquidityFromDeltas);
        if (payerIsUser) {
            // since credits exist (and already in market), net settlement for position
            _callOnMMSettle(
                SettleCallParams({
                    vault: _getVault(poolKey),
                    tokenId: tokenId,
                    positionIndex: positionIndex,
                    currency0: poolKey.currency0,
                    currency1: poolKey.currency1,
                    requestedDelta: LiquidityUtils.safeToBalanceDelta(credit0, credit1, true, true),
                    isSeizing: false
                })
            );
        } else {
            // Settle into the position the underlying tokens that are owed.
            _settle(poolKey, tokenId, positionIndex, -credit0.toInt128(), -credit1.toInt128(), true);
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
        bool payerIsUser
    ) internal {
        MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);

        // payerIsUser = true: User consumes credit protocol owes them (tracked on MMPM)
        // payerIsUser = false: Locker uses their own direct credit
        address deltaTarget = payerIsUser ? address(this) : msgSender();
        (uint256 liquidityFromDeltas, uint256 credit0, uint256 credit1) =
            _getLiquidityFromDeltas(poolKey, deltaTarget, tickLower, tickUpper);
        // This works as LCCs are issued, capitalised by underlying tokens owed to the MM.
        (, uint256 positionIndex) = _mintPositionInternal(poolKey, tokenId, tickLower, tickUpper, liquidityFromDeltas);
        if (payerIsUser) {
            // since credits exist (and already in market), net settlement for position
            _callOnMMSettle(
                SettleCallParams({
                    vault: _getVault(poolKey),
                    tokenId: tokenId,
                    positionIndex: positionIndex,
                    currency0: poolKey.currency0,
                    currency1: poolKey.currency1,
                    requestedDelta: LiquidityUtils.safeToBalanceDelta(credit0, credit1, true, true),
                    isSeizing: false
                })
            );
        } else {
            // Settle into the position the underlying tokens that are owed.
            _settle(poolKey, tokenId, positionIndex, -credit0.toInt128(), -credit1.toInt128(), true);
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

        // Behaviour matrix:
        // - shouldTake=true && payerIsUser=true:  Withdraw to locker from protocol delta via _settle
        // - shouldTake=false && payerIsUser=true: Net protocol delta with onMMSettle (no token movement)
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
                // DEPOSIT: Settle credits into position
                // Net protocol delta via onMMSettle (no token movement) regardless of payerIsUser
                // Build call params in scoped block to reduce stack depth
                SettleCallParams memory callParams;
                {
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

                    callParams = SettleCallParams({
                        vault: _getVault(poolKey),
                        tokenId: tokenId,
                        positionIndex: positionIndex,
                        currency0: poolKey.currency0,
                        currency1: poolKey.currency1,
                        requestedDelta: LiquidityUtils.safeToBalanceDelta(credit0, credit1, true, true),
                        isSeizing: isSeizing
                    });
                }
                _callOnMMSettle(callParams);
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
        bytes memory hookData
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

        _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
    }

    /// @notice Decreases liquidity from an existing position
    /// @param poolKey The pool key
    /// @param tokenId The commitment NFT token ID
    /// @param positionIndex The position index within the commitment
    /// @param amountToDecrease The amount of liquidity to remove
    function _decrease(PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint256 amountToDecrease)
        internal
    {
        MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);

        (Position memory position,) = getPosition(tokenId, positionIndex);
        MMHelpers.assertPositionForPool(poolKey, position);

        _decreaseInternal(
            poolKey,
            position,
            PositionLibrary.generateSalt(tokenId, positionIndex),
            tokenId,
            amountToDecrease,
            PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender())
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
    function _mintPositionInternal(
        PoolKey calldata poolKey,
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    ) internal returns (PositionId positionId, uint256 positionIndex) {
        if (liquidity > type(uint128).max) {
            revert Errors.InvalidAmount(liquidity, type(uint128).max);
        }

        (,, positionIndex,) = vtsOrchestrator.getCommit(tokenId);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidity.toInt256(),
            salt: PositionLibrary.generateSalt(tokenId, positionIndex)
        });

        positionId = PositionLibrary.generateId(address(this), params);
        bytes memory hookData = PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender());
        _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
    }
}


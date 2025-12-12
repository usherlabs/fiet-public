// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
import {PositionId, PositionLibrary, PositionModificationHookDataLib} from "./types/Position.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
import {IMarketVault} from "./interfaces/IMarketVault.sol";
import {Errors} from "./libraries/Errors.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
import {Position} from "./types/Position.sol";
import {TransientSlots} from "./libraries/TransientSlots.sol";
import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
import {PositionManagerImpl} from "./modules/PositionManagerImpl.sol";
import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
import {MarketHandlerLib} from "./libraries/MarketHandlerLib.sol";
import {ImmutableMarketState} from "./modules/ImmutableMarketState.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
import {MMActions} from "./libraries/MMActions.sol";
import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
import {MMHelpers} from "./libraries/MMHelpers.sol";
import {Locker} from "v4-periphery/src/libraries/Locker.sol";
import {MarketMaker} from "./libraries/MarketMaker.sol";
import {DelegateCallGuard} from "./modules/DelegateCallGuard.sol";

/// @title MMPositionActionsImpl
/// @notice Implementation contract for MMPositionManager position operations
/// @dev Called via delegatecall from MMPositionManager, shares storage context
/// @dev Only handles position operations (actions <= SETTLE_POSITION_FROM_DELTAS)
/// @dev ERC721 functions accessed via delegatecall context from MMPositionManager
contract MMPositionActionsImpl is IMMActionsImpl, PositionManagerImpl, ImmutableMarketState, DelegateCallGuard {
    using SafeCast for uint256;
    using PositionLibrary for PositionId;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using CurrencyTransfer for Currency;
    using MMCalldataDecoder for bytes;

    // ═══════════════════════════════════════════════════════════════════════════
    // Immutables (must match MMPositionManager's values)
    // ═══════════════════════════════════════════════════════════════════════════

    ILiquidityHub internal immutable liquidityHub;

    // ═══════════════════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address _manager, address _marketFactory, address _vtsOrchestrator)
        PositionManagerImpl(IPoolManager(_manager), _vtsOrchestrator)
        ImmutableMarketState(_marketFactory)
    {
        liquidityHub = marketFactory.liquidityHub();
    }

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
            (
                PoolKey calldata poolKey,
                uint256 tokenId,
                uint256 positionIndex,
                int24 tickLower,
                int24 tickUpper,
                uint256 liquidity
            ) = params.decodeIncreaseLiquidityParams();
            _increase(poolKey, tokenId, positionIndex, tickLower, tickUpper, liquidity);
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
            (
                PoolKey calldata poolKey,
                uint256 tokenId,
                uint256 positionIndex,
                int24 tickLower,
                int24 tickUpper,
                bool payerIsUser
            ) = params.decodeIncreaseFromDeltasParams();
            _increaseFromDeltas(poolKey, tokenId, positionIndex, tickLower, tickUpper, payerIsUser);
            return;
        }
        if (action == MMActions.MINT_POSITION_FROM_DELTAS) {
            (PoolKey calldata poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, bool payerIsUser) =
                params.decodeMintFromDeltasParams();
            _mintFromDeltas(poolKey, tokenId, tickLower, tickUpper, payerIsUser);
            return;
        }
        if (action == MMActions.SETTLE_POSITION_FROM_DELTAS) {
            (
                PoolKey calldata poolKey,
                uint256 tokenId,
                uint256 positionIndex,
                bool settleIn0,
                bool settleIn1,
                bool payerIsUser
            ) = params.decodeSettleFromDeltasParams();
            _settleFromDeltas(poolKey, tokenId, positionIndex, settleIn0, settleIn1, payerIsUser);
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

    /// @notice Checks if a position is currently being seized
    /// @param positionId The position ID to check
    /// @return True if the position is being seized
    function _isSeizing(PositionId positionId) internal view returns (bool) {
        PositionId seizedPositionId = TransientSlots.getSeizedPositionId();
        return PositionId.unwrap(seizedPositionId) == PositionId.unwrap(positionId);
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

        // Caller must be approved/owner AND position must be active
        // Note: Actual seizure eligibility (grace period) is checked in VTSOrchestrator.onSeize
        MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
        if (position.isActive == false) {
            revert Errors.InvalidPosition(tokenId, positionIndex, positionId);
        }

        vtsOrchestrator.onSeize(tokenId, positionIndex);
        TransientSlots.setSeizedPositionId(positionId);

        uint256 seizedLiquidityUnits =
            _settle(poolKey, tokenId, positionIndex, amount0.toInt128(), amount1.toInt128(), usePositionManagerBalance);

        BalanceDelta seizureSettlementDelta = LiquidityUtils.safeToBalanceDelta(amount0, amount1, true, true);
        bytes memory hookData = PositionModificationHookDataLib.encodeSeizure(
            tokenId, positionIndex, msgSender(), seizureSettlementDelta.amount0(), seizureSettlementDelta.amount1()
        );

        _decreaseInternal(
            poolKey, position, PositionLibrary.generateSalt(tokenId, positionIndex), seizedLiquidityUnits, hookData
        );
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
    ) internal returns (uint256) {
        if (amount0 == 0 && amount1 == 0) {
            revert Errors.InvalidDelta(0, 0);
        }

        (Position memory position, PositionId positionId) = getPosition(tokenId, positionIndex);
        MMHelpers.assertPositionForPool(poolKey, position);

        bool isSeizing = _isSeizing(positionId);

        if (!isSeizing) {
            MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
        }

        Currency underlying0 = _lccToUnderlyingCurrency(poolKey.currency0);
        Currency underlying1 = _lccToUnderlyingCurrency(poolKey.currency1);

        IMarketVault vault = MarketHandlerLib.getVault(marketFactory, poolKey.toId());

        (BalanceDelta settlementDelta,, uint256 seizedLiquidityUnits) = vtsOrchestrator.onMMSettle(
            vault,
            tokenId,
            positionIndex,
            poolKey.currency0,
            poolKey.currency1,
            toBalanceDelta(amount0, amount1),
            isSeizing
        );

        int128 delta0 = settlementDelta.amount0();
        int128 delta1 = settlementDelta.amount1();

        address sender = msgSender();
        address valueSender = usePositionManagerBalance ? address(this) : sender;
        if (delta0 < 0) {
            underlying0.transferFrom(valueSender, address(vault), LiquidityUtils.safeInt128ToUint256(delta0));
            if (usePositionManagerBalance) {
                vtsOrchestrator.take(underlying0, sender, LiquidityUtils.safeInt128ToUint256(delta0));
            }
        }
        if (delta1 < 0) {
            underlying1.transferFrom(valueSender, address(vault), LiquidityUtils.safeInt128ToUint256(delta1));
            if (usePositionManagerBalance) {
                vtsOrchestrator.take(underlying1, sender, LiquidityUtils.safeInt128ToUint256(delta1));
            }
        }

        vault.modifyLiquidities(settlementDelta);

        if (delta0 > 0) {
            underlying0.transfer(valueSender, LiquidityUtils.safeInt128ToUint256(delta0));
        }
        if (delta1 > 0) {
            underlying1.transfer(valueSender, LiquidityUtils.safeInt128ToUint256(delta1));
        }
        if ((delta0 > 0 || delta1 > 0) && usePositionManagerBalance) {
            _syncPairBalanceToDeltas(underlying0, underlying1);
        }

        return seizedLiquidityUnits;
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
            completeLiquidity,
            PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender())
        );
    }

    /// @notice Increases liquidity in an existing position
    /// @param poolKey The pool key
    /// @param tokenId The commitment NFT token ID
    /// @param positionIndex The position index within the commitment
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param liquidity The amount of liquidity to add
    function _increase(
        PoolKey calldata poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    ) internal {
        MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);

        (Position memory position,) = getPosition(tokenId, positionIndex);
        MMHelpers.assertPositionForPool(poolKey, position);
        _increaseInternal(poolKey, tokenId, positionIndex, tickLower, tickUpper, liquidity);
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
        _modifySyntheticLiquidity(poolKey, params, hookData);
    }

    /// @notice Increases liquidity using available delta credits
    /// @param poolKey The pool key
    /// @param tokenId The commitment NFT token ID
    /// @param positionIndex The position index within the commitment
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param payerIsUser If true, user consumes credit the protocol owes them (delta target = MMPM).
    ///        If false, uses locker's direct credit (delta target = locker).
    /// @dev Delta target semantics:
    ///      - MMPM (address(this)): Protocol owes/is owed by external sources
    ///      - Locker (msgSender()): External entity owes/is owed by protocol
    function _increaseFromDeltas(
        PoolKey calldata poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        int24 tickLower,
        int24 tickUpper,
        bool payerIsUser
    ) internal {
        MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);

        (Position memory position,) = getPosition(tokenId, positionIndex);
        MMHelpers.assertPositionForPool(poolKey, position);

        // payerIsUser = true: User consumes credit protocol owes them (tracked on MMPM)
        // payerIsUser = false: Locker uses their own direct credit
        address deltaTarget = payerIsUser ? address(this) : msgSender();
        uint256 liquidityFromDeltas = _getLiquidityFromDeltas(poolKey, deltaTarget, tickLower, tickUpper);
        _increaseInternal(poolKey, tokenId, positionIndex, tickLower, tickUpper, liquidityFromDeltas);
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
        uint256 liquidityFromDeltas = _getLiquidityFromDeltas(poolKey, deltaTarget, tickLower, tickUpper);
        _mintPositionInternal(poolKey, tokenId, tickLower, tickUpper, liquidityFromDeltas);
    }

    /// @notice Settles a position using available delta credits
    /// @param poolKey The pool key
    /// @param tokenId The commitment NFT token ID
    /// @param positionIndex The position index within the commitment
    /// @param settleIn0 Whether to settle in token0
    /// @param settleIn1 Whether to settle in token1
    /// @param payerIsUser If true, user consumes credit the protocol owes them (delta target = MMPM).
    ///        If false, uses locker's direct credit (delta target = locker).
    /// @dev Delta target semantics:
    ///      - MMPM (address(this)): Protocol owes/is owed by external sources
    ///      - Locker (msgSender()): External entity owes/is owed by protocol
    function _settleFromDeltas(
        PoolKey calldata poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        bool settleIn0,
        bool settleIn1,
        bool payerIsUser
    ) internal {
        // payerIsUser = true: User consumes credit protocol owes them (tracked on MMPM)
        // payerIsUser = false: Locker uses their own direct credit
        address deltaTarget = payerIsUser ? address(this) : msgSender();
        (uint256 credit0, uint256 credit1) = _getFullCreditPair(
            _lccToUnderlyingCurrency(poolKey.currency0), _lccToUnderlyingCurrency(poolKey.currency1), deltaTarget
        );
        BalanceDelta sDelta = LiquidityUtils.safeToBalanceDelta(credit0, credit1, settleIn0, settleIn1);
        _settle(poolKey, tokenId, positionIndex, sDelta.amount0(), sDelta.amount1(), true);
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

        _modifySyntheticLiquidity(poolKey, params, hookData);
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

        (,, positionIndex) = vtsOrchestrator.getCommit(tokenId);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidity.toInt256(),
            salt: PositionLibrary.generateSalt(tokenId, positionIndex)
        });

        positionId = PositionLibrary.generateId(address(this), params);
        bytes memory hookData = PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender());
        _modifySyntheticLiquidity(poolKey, params, hookData);
    }
}


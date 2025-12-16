// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

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
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {console} from "forge-std/console.sol";
import {ILCC} from "./interfaces/ILCC.sol";

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

    // ═══════════════════════════════════════════════════════════════════════════
    // Immutables (must match MMPositionManager's values)
    // ═══════════════════════════════════════════════════════════════════════════

    // ═══════════════════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address _manager, address _liquidityHub, address _vtsOrchestrator)
        PositionManagerImpl(IPoolManager(_manager), _liquidityHub, _vtsOrchestrator)
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
        IMarketFactory marketFactory =
            liquidityHub.getFactory(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
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

        IMarketVault vault = _getVault(poolKey);

        (BalanceDelta settlementDelta,, uint256 seizedLiquidityUnits) = vtsOrchestrator.onMMSettle(
            vault,
            tokenId,
            positionIndex,
            poolKey.currency0,
            poolKey.currency1,
            toBalanceDelta(amount0, amount1),
            isSeizing
        );

        Currency underlying0 = _lccToUnderlyingCurrency(poolKey.currency0);
        Currency underlying1 = _lccToUnderlyingCurrency(poolKey.currency1);

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
        address sender = msgSender();
        MMHelpers.assertApprovedOrOwner(sender, tokenId);

        (Position memory position,) = getPosition(tokenId, positionIndex);
        MMHelpers.assertPositionForPool(poolKey, position);

        // payerIsUser = true: User consumes credit protocol owes them (tracked on MMPM)
        // payerIsUser = false: Locker uses their own direct credit
        address deltaTarget = payerIsUser ? address(this) : sender;
        (uint256 liquidityFromDeltas, uint256 credit0, uint256 credit1) =
            _getLiquidityFromDeltas(poolKey, deltaTarget, tickLower, tickUpper);
        _increaseInternal(poolKey, tokenId, positionIndex, tickLower, tickUpper, liquidityFromDeltas);
        if (!payerIsUser) {
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
        if (!payerIsUser) {
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

        if (credit0 == 0 && credit1 == 0) {
            revert Errors.InvalidDelta(0, 0);
        }

        if (shouldTake) {
            // WITHDRAW: Move credits out as tokens
            // Protocol owes user → withdraw to locker via _settle
            _settle(poolKey, tokenId, positionIndex, credit0.toInt128(), credit1.toInt128(), !payerIsUser);
            // if !payerIsUser, balance sync handled in _settle
        } else {
            // DEPOSIT: Settle credits into position
            // Net protocol delta via onMMSettle (no token movement)
            (Position memory position, PositionId positionId) = getPosition(tokenId, positionIndex);
            MMHelpers.assertPositionForPool(poolKey, position);

            bool isSeizing = _isSeizing(positionId);
            if (!isSeizing) {
                MMHelpers.assertApprovedOrOwner(sender, tokenId);
            }

            BalanceDelta sDelta = LiquidityUtils.safeToBalanceDelta(credit0, credit1, true, true);
            vtsOrchestrator.onMMSettle(
                _getVault(poolKey), tokenId, positionIndex, poolKey.currency0, poolKey.currency1, sDelta, isSeizing
            );
            if (!payerIsUser) {
                // Settle from MMPM balance (actual token movement)
                (uint256 lockerCredit0, uint256 lockerCredit1) = _getFullCreditPair(underlying0, underlying1, sender);
                _settle(poolKey, tokenId, positionIndex, -lockerCredit0.toInt128(), -lockerCredit1.toInt128(), true);
            }
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


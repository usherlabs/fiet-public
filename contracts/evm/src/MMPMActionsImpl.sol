// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionId, PositionLibrary, PositionModificationHookDataLib} from "./types/Position.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
import {IMarketVault} from "./interfaces/IMarketVault.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Errors} from "./libraries/Errors.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {IVTSOrchestrator} from "./interfaces/IVTSOrchestrator.sol";
import {Position} from "./types/Position.sol";
import {TransientSlots} from "./libraries/TransientSlots.sol";
import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
import {MarketHandlerLib} from "./libraries/MarketHandlerLib.sol";
import {ImmutableMarketState} from "./modules/ImmutableMarketState.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {NativeWrapper} from "./forks/NativeWrapper.sol";
import {IMMPMActionsImpl} from "./interfaces/IMMPMActionsImpl.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {MMActions} from "./libraries/MMActions.sol";
import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
import {ERC721Permit_v4} from "v4-periphery/src/base/ERC721Permit_v4.sol";
import {Locker} from "v4-periphery/src/libraries/Locker.sol";
import {ICommitmentDescriptor} from "./interfaces/ICommitmentDescriptor.sol";
import {MarketMaker} from "./libraries/MarketMaker.sol";
import {CheckpointEntrypoints} from "./modules/CheckpointEntrypoints.sol";

/// @title MMPMActionsImpl
/// @notice Implementation contract for MMPositionManager action handling
/// @dev Called via delegatecall from MMPositionManager, shares storage context
/// @dev Immutables must match MMPositionManager's values since they're embedded in bytecode
contract MMPMActionsImpl is
    ERC721Permit_v4,
    IMMPMActionsImpl,
    ImmutableState,
    PositionManagerBase,
    NativeWrapper,
    ImmutableMarketState,
    CheckpointEntrypoints
{
    using SafeCast for uint256;
    using PositionLibrary for PositionId;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using CurrencyTransfer for Currency;
    using SafeERC20 for IERC20;
    using MMCalldataDecoder for bytes;

    // ═══════════════════════════════════════════════════════════════════════════
    // Events (must match MMPositionManager for proper event emission)
    // ═══════════════════════════════════════════════════════════════════════════

    event SignalCommitted(uint256 tokenId);
    event SignalDecommitted(uint256 tokenId, uint256 positionCount);

    // ═══════════════════════════════════════════════════════════════════════════
    // DelegateCall Guard
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Address of this contract at deployment - used to detect delegatecall
    address private immutable __self = address(this);

    error OnlyDelegateCall();

    modifier onlyDelegateCall() {
        if (address(this) == __self) revert OnlyDelegateCall();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Immutables (must match MMPositionManager's values)
    // ═══════════════════════════════════════════════════════════════════════════

    ILiquidityHub internal immutable liquidityHub;
    address public immutable commitmentDescriptor;

    // ═══════════════════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address _manager, address _marketFactory, address _vtsOrchestrator, address _descriptor, IWETH9 _weth9)
        ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
        ImmutableState(IPoolManager(_manager))
        PositionManagerBase(_vtsOrchestrator)
        NativeWrapper(_weth9)
        ImmutableMarketState(_marketFactory)
    {
        commitmentDescriptor = _descriptor;
        liquidityHub = marketFactory.liquidityHub();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Overrides for abstract functions
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc PositionManagerBase
    function msgSender() public view override returns (address) {
        return Locker.get();
    }

    /// @inheritdoc PositionManagerBase
    function _liquidityHub() internal view override returns (ILiquidityHub) {
        return liquidityHub;
    }

    /// @notice Returns the token URI for a given token id using the commitment descriptor contract
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (commitmentDescriptor == address(0)) {
            revert Errors.CommitmentDescriptorNotSet();
        }
        return ICommitmentDescriptor(commitmentDescriptor).tokenURI(tokenId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Entry Point Hooks (called by MMPM via delegatecall)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IMMPMActionsImpl
    function beforeEntrypoint(uint256 deadline) external onlyDelegateCall {
        if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);

        // Handle native value
        uint256 amount = TransientSlots.readMsgValueOnce();
        if (amount > 0) {
            _syncBalanceAsCredit(CurrencyLibrary.ADDRESS_ZERO);
        }
    }

    /// @inheritdoc IMMPMActionsImpl
    function afterEntrypoint() external onlyDelegateCall {
        vtsOrchestrator.assertNonZeroDeltas();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Main Action Handler
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IMMPMActionsImpl
    function handleAction(uint256 action, bytes calldata params) external override onlyDelegateCall {
        if (action == MMActions.COMMIT_SIGNAL) {
            (bytes calldata liquiditySignal, address owner) = params.decodeCommitSignalParams();
            _commitSignal(liquiditySignal, _mapRecipient(owner));
            return;
        }
        if (action == MMActions.SETTLE_POSITION) {
            (
                PoolKey calldata poolKey,
                uint256 tokenId,
                uint256 positionIndex,
                int128 amount0,
                int128 amount1,
                bool withDeltas
            ) = params.decodeSettlePositionParams();
            _settle(poolKey, tokenId, positionIndex, amount0, amount1, withDeltas);
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
        if (action == MMActions.RENEW_SIGNAL) {
            (uint256 tokenId, bytes calldata liquiditySignal) = params.decodeTokenIdAndBytes();
            _renewSignal(tokenId, liquiditySignal);
            return;
        }
        if (action == MMActions.SEIZE_POSITION) {
            (
                PoolKey calldata poolKey,
                uint256 tokenId,
                uint256 positionIndex,
                uint256 amount0,
                uint256 amount1,
                bool withDeltas
            ) = params.decodeSeizePositionParams();
            _seizePosition(poolKey, tokenId, positionIndex, amount0, amount1, withDeltas);
            return;
        }
        if (action == MMActions.DECLARE_UNBACKED_COMMITMENT) {
            (uint256 tokenId, bytes calldata liquiditySignal) = params.decodeTokenIdAndBytes();
            _declareUnbackedCommitment(tokenId, liquiditySignal);
            return;
        }
        if (action == MMActions.COLLECT_AVAILABLE_LIQUIDITY) {
            (address lcc, address recipient, uint256 maxAmount) = params.decodeCollectLiquidityParams();
            _collectAvailableLiquidity(lcc, recipient, maxAmount);
            return;
        }
        if (action == MMActions.DECOMMIT_SIGNAL) {
            (PoolKey calldata poolKey, uint256 tokenId) = params.decodeDecommitSignalParams();
            _decommitSignal(poolKey, tokenId);
            return;
        }
        if (action == MMActions.UNWRAP_LCC) {
            (address lccAddr, uint256 amount, address recipient, bool payerIsUser) = params.decodeUnwrapLCCParams();
            _unwrapLCC(lccAddr, _mapPayer(payerIsUser), _mapRecipient(recipient), amount);
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
        if (action == MMActions.TAKE) {
            (Currency currency, address to, uint256 maxAmount) = params.decodeTakeParams();
            _take(currency, to, maxAmount);
            return;
        }
        if (action == MMActions.INCREASE_LIQUIDITY_FROM_DELTAS) {
            (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, int24 tickLower, int24 tickUpper) =
                params.decodeIncreaseFromDeltasParams();
            _increaseFromDeltas(poolKey, tokenId, positionIndex, tickLower, tickUpper);
            return;
        }
        if (action == MMActions.MINT_POSITION_FROM_DELTAS) {
            (PoolKey calldata poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper) =
                params.decodeMintFromDeltasParams();
            _mintFromDeltas(poolKey, tokenId, tickLower, tickUpper);
            return;
        }
        if (action == MMActions.SETTLE_POSITION_FROM_DELTAS) {
            (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, bool settleIn0, bool settleIn1) =
                params.decodeSettleFromDeltasParams();
            _settleFromDeltas(poolKey, tokenId, positionIndex, settleIn0, settleIn1);
            return;
        }
        revert Errors.UnsupportedAction(action);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Internal Helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Asserts that the caller is approved or the owner of the token
    function _assertApprovedOrOwner(address caller, uint256 tokenId) internal view {
        if (!_isApprovedOrOwner(caller, tokenId)) {
            revert Errors.NotApproved(caller);
        }
    }

    /// @notice Enforces that the commit is valid (not expired)
    function _assertSignalValid(uint256 tokenId) internal view {
        (, uint256 expiresAt,,) = vtsOrchestrator.getCommit(tokenId);
        if (expiresAt < block.timestamp) {
            revert Errors.SignalExpired(tokenId);
        }
    }

    function _assertPositionForPool(PoolKey calldata poolKey, Position memory position) internal pure {
        if (PoolId.unwrap(position.poolId) != PoolId.unwrap(poolKey.toId())) {
            revert Errors.InvalidMarket(poolKey);
        }
    }

    /// @dev Map recipient address, handling special constants
    function _mapRecipient(address recipient) internal view returns (address) {
        if (recipient == address(0)) return msgSender();
        if (recipient == address(1)) return address(this);
        return recipient;
    }

    /// @dev Map payer based on flag
    function _mapPayer(bool payerIsUser) internal view returns (address) {
        return payerIsUser ? msgSender() : address(this);
    }

    /// @notice Returns the position information for a given token ID and position index
    /// @param tokenId the ERC721 tokenId (commitment NFT ID)
    /// @param positionIndex the index of the position within the commitment
    /// @return Position the position information
    /// @return PositionId the position ID
    function getPosition(uint256 tokenId, uint256 positionIndex) public view returns (Position memory, PositionId) {
        return vtsOrchestrator.getPosition(tokenId, positionIndex);
    }

    /// @notice Returns the position ID for a given token ID and position index
    /// @param tokenId The ERC721 tokenId (commitment NFT ID)
    /// @param positionIndex The index of the position within the commitment
    /// @return PositionId The position ID
    function getPositionId(uint256 tokenId, uint256 positionIndex) public view returns (PositionId) {
        return vtsOrchestrator.getPositionId(tokenId, positionIndex);
    }

    /// @notice Returns the commit information for a given commitment NFT
    /// @param tokenId the ERC721 tokenId (commitment NFT ID)
    /// @return mmState The MarketMaker state
    /// @return expiresAt The expiration timestamp
    /// @return positionCount The count of positions
    /// @return deficitBps The deficit basis points
    function commitOf(uint256 tokenId) public view returns (MarketMaker.State memory, uint256, uint256, uint256) {
        return vtsOrchestrator.getCommit(tokenId);
    }

    /// @dev Check if position is being seized
    function _isSeizing(PositionId positionId) internal view returns (bool) {
        PositionId seizedPositionId = TransientSlots.getSeizedPositionId();
        return PositionId.unwrap(seizedPositionId) == PositionId.unwrap(positionId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Native Asset Wrap/Unwrap Operations
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Wraps native ETH to WETH, updating deltas accordingly
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
    function _unwrapNative(uint256 amount, bool payerIsUser) internal {
        Currency weth = Currency.wrap(address(WETH9));
        if (payerIsUser) {
            address payer = msgSender();
            if (amount == 0) {
                amount = weth.balanceOf(payer);
            }
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
        _syncBalanceAsCredit(CurrencyLibrary.ADDRESS_ZERO);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Signal Management Actions
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Commits a liquidity signal and mints a commitment NFT
    /// @param liquiditySignal The ABI-encoded LiquiditySignal to verify and record
    /// @param owner The address to receive the commitment NFT (can be mapped constants)
    /// @return tokenId The commitment NFT id created
    function _commitSignal(bytes calldata liquiditySignal, address owner) internal returns (uint256 tokenId) {
        // Commit the signal to the vts orchestrator
        tokenId = vtsOrchestrator.commitSignal(liquiditySignal);
        // Mint the NFT using the returned token id
        _mint(owner, tokenId);
        emit SignalCommitted(tokenId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Position Actions
    // ═══════════════════════════════════════════════════════════════════════════

    function _extendGracePeriod(
        PoolKey calldata poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes calldata settlementProof
    ) internal {
        _assertApprovedOrOwner(msgSender(), tokenId);
        _assertSignalValid(tokenId);
        vtsOrchestrator.extendGracePeriod(
            poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof
        );
    }

    function _seizePosition(
        PoolKey calldata poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        uint256 amount0,
        uint256 amount1,
        bool withDeltas
    ) internal {
        (Position memory position, PositionId positionId) = getPosition(tokenId, positionIndex);
        _assertPositionForPool(poolKey, position);

        if (!_isApprovedOrOwner(msgSender(), tokenId) || position.isActive == false) {
            revert Errors.InvalidPosition(tokenId, positionIndex, positionId);
        }

        vtsOrchestrator.onSeize(tokenId, positionIndex);
        TransientSlots.setSeizedPositionId(positionId);

        uint256 seizedLiquidityUnits =
            _settle(poolKey, tokenId, positionIndex, amount0.toInt128(), amount1.toInt128(), withDeltas);

        BalanceDelta seizureSettlementDelta = LiquidityUtils.safeToBalanceDelta(amount0, amount1, true, true);
        bytes memory hookData = PositionModificationHookDataLib.encodeSeizure(
            tokenId, positionIndex, msgSender(), seizureSettlementDelta.amount0(), seizureSettlementDelta.amount1()
        );

        _decreaseInternal(
            poolKey, position, PositionLibrary.generateSalt(tokenId, positionIndex), seizedLiquidityUnits, hookData
        );
    }

    function _declareUnbackedCommitment(uint256 tokenId, bytes calldata liquiditySignal) internal {
        vtsOrchestrator.declareUnbackedCommitment(msgSender(), tokenId, liquiditySignal);
    }

    function _unwrapLCC(address lccAddr, address from, address to, uint256 requested)
        internal
        returns (uint256 unwrapped)
    {
        ILCC lcc = ILCC(lccAddr);
        Currency lccCurrency = Currency.wrap(lccAddr);
        address underlying = lcc.underlying();

        uint256 beforeBal = IERC20(underlying).balanceOf(to);
        uint256 toUnwrap;

        if (from == address(this)) {
            toUnwrap = vtsOrchestrator.take(lccCurrency, msgSender(), requested);
        } else {
            toUnwrap = lcc.balanceOf(from);
            if (requested > 0 && toUnwrap > requested) {
                toUnwrap = requested;
            }
        }

        if (toUnwrap > 0) {
            if (from != address(this)) {
                lcc.safeTransferFrom(from, address(this), toUnwrap);
            }
            liquidityHub.unwrapTo(lccAddr, to, toUnwrap);
        }

        unwrapped = IERC20(underlying).balanceOf(to) - beforeBal;

        if (to == address(this) && unwrapped > 0) {
            _syncBalanceAsCredit(Currency.wrap(underlying));
        }
    }

    function _collectAvailableLiquidity(address lcc, address recipient, uint256 maxAmount) internal {
        address sender = msgSender();
        uint256 queued = liquidityHub.settleQueue(lcc, sender);

        if (queued > 0) {
            liquidityHub.processSettlementFor(lcc, recipient, maxAmount);

            if (recipient == address(this)) {
                _syncBalanceAsCredit(_lccToUnderlyingCurrency(Currency.wrap(lcc)));
            }
        }
    }

    function _settle(
        PoolKey calldata poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        int128 amount0,
        int128 amount1,
        bool withDeltas
    ) internal returns (uint256) {
        if (amount0 == 0 && amount1 == 0) {
            revert Errors.InvalidDelta(0, 0);
        }

        (Position memory position, PositionId positionId) = getPosition(tokenId, positionIndex);
        _assertPositionForPool(poolKey, position);

        bool isSeizing = _isSeizing(positionId);

        if (!isSeizing) {
            _assertSignalValid(tokenId);
            _assertApprovedOrOwner(msgSender(), tokenId);
        }

        Currency underlying0 = _lccToUnderlyingCurrency(poolKey.currency0);
        Currency underlying1 = _lccToUnderlyingCurrency(poolKey.currency1);

        IMarketVault vault = MarketHandlerLib.getVault(marketFactory, poolKey.toId());

        (BalanceDelta settlementDelta,, uint256 seizedLiquidityUnits) = vtsOrchestrator.onMMSettle(
            vault, positionId, poolKey.currency0, poolKey.currency1, toBalanceDelta(amount0, amount1), isSeizing
        );

        int128 delta0 = settlementDelta.amount0();
        int128 delta1 = settlementDelta.amount1();

        address sender = msgSender();
        address valueSender = withDeltas ? address(this) : sender;
        if (delta0 < 0) {
            underlying0.transferFrom(valueSender, address(vault), LiquidityUtils.safeInt128ToUint256(delta0));
            if (withDeltas) {
                vtsOrchestrator.take(underlying0, sender, LiquidityUtils.safeInt128ToUint256(delta0));
            }
        }
        if (delta1 < 0) {
            underlying1.transferFrom(valueSender, address(vault), LiquidityUtils.safeInt128ToUint256(delta1));
            if (withDeltas) {
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
        if ((delta0 > 0 || delta1 > 0) && withDeltas) {
            _syncPairBalanceToDeltas(underlying0, underlying1);
        }

        return seizedLiquidityUnits;
    }

    function _renewSignal(uint256 tokenId, bytes calldata liquiditySignal) internal {
        _assertApprovedOrOwner(msgSender(), tokenId);
        vtsOrchestrator.renewSignal(tokenId, liquiditySignal);
    }

    function _decommitSignal(PoolKey calldata poolKey, uint256 tokenId) internal {
        _assertApprovedOrOwner(msgSender(), tokenId);
        _assertSignalValid(tokenId);

        (,, uint256 positionCount,) = vtsOrchestrator.getCommit(tokenId);
        if (positionCount > 0) {
            revert Errors.CommitNotEmpty(tokenId);
        }

        _burn(tokenId);
        emit SignalDecommitted(tokenId, positionCount);
    }

    function _burnPosition(PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex) internal {
        _assertApprovedOrOwner(msgSender(), tokenId);
        _assertSignalValid(tokenId);

        (Position memory position,) = getPosition(tokenId, positionIndex);
        _assertPositionForPool(poolKey, position);
        uint256 completeLiquidity = uint256(position.liquidity);
        _decreaseInternal(
            poolKey,
            position,
            PositionLibrary.generateSalt(tokenId, positionIndex),
            completeLiquidity,
            PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender())
        );
    }

    function _increase(
        PoolKey calldata poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    ) internal {
        _assertApprovedOrOwner(msgSender(), tokenId);
        _assertSignalValid(tokenId);

        (Position memory position,) = getPosition(tokenId, positionIndex);
        _assertPositionForPool(poolKey, position);
        _increaseInternal(poolKey, tokenId, positionIndex, tickLower, tickUpper, liquidity);
    }

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

    function _increaseFromDeltas(
        PoolKey calldata poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        int24 tickLower,
        int24 tickUpper
    ) internal {
        _assertApprovedOrOwner(msgSender(), tokenId);
        _assertSignalValid(tokenId);

        (Position memory position,) = getPosition(tokenId, positionIndex);
        _assertPositionForPool(poolKey, position);

        uint256 liquidityFromDeltas = _getLiquidityFromDeltas(poolKey, address(this), tickLower, tickUpper);
        _increaseInternal(poolKey, tokenId, positionIndex, tickLower, tickUpper, liquidityFromDeltas);
    }

    function _mintFromDeltas(PoolKey calldata poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper) internal {
        _assertApprovedOrOwner(msgSender(), tokenId);
        _assertSignalValid(tokenId);

        uint256 liquidityFromDeltas = _getLiquidityFromDeltas(poolKey, address(this), tickLower, tickUpper);
        _mintPositionInternal(poolKey, tokenId, tickLower, tickUpper, liquidityFromDeltas);
    }

    function _settleFromDeltas(
        PoolKey calldata poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        bool settleIn0,
        bool settleIn1
    ) internal {
        (uint256 credit0, uint256 credit1) = _getFullCreditPair(
            _lccToUnderlyingCurrency(poolKey.currency0), _lccToUnderlyingCurrency(poolKey.currency1), address(this)
        );
        BalanceDelta sDelta = LiquidityUtils.safeToBalanceDelta(credit0, credit1, settleIn0, settleIn1);
        _settle(poolKey, tokenId, positionIndex, sDelta.amount0(), sDelta.amount1(), true);
    }

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

    function _decrease(PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint256 amountToDecrease)
        internal
    {
        _assertApprovedOrOwner(msgSender(), tokenId);
        _assertSignalValid(tokenId);

        (Position memory position,) = getPosition(tokenId, positionIndex);
        _assertPositionForPool(poolKey, position);

        _decreaseInternal(
            poolKey,
            position,
            PositionLibrary.generateSalt(tokenId, positionIndex),
            amountToDecrease,
            PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender())
        );
    }

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
        _modifySyntheticLiquidity(poolKey, params, hookData);
    }
}


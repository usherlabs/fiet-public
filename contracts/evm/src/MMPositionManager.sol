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
import {MarketMaker} from "./libraries/MarketMaker.sol";
import {ICommitmentDescriptor} from "./interfaces/ICommitmentDescriptor.sol";
import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
import {Errors} from "./libraries/Errors.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
import {PositionManagerEntrypoint} from "./modules/PositionManagerEntrypoint.sol";
import {Permit2Forwarder} from "v4-periphery/src/base/Permit2Forwarder.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MMActions} from "./libraries/MMActions.sol";
import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
import {MMHelpers} from "./libraries/MMHelpers.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";

/// @title MMPositionManager
/// @notice Entry point for VRL commitment position management
/// @dev Handles commitment lifecycle (ERC721) and utility operations locally
/// @dev Delegates position operations to MMPMActionsImpl via delegatecall
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

    // ═══════════════════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(
        address _manager,
        address _liquidityHub,
        address _vtsOrchestrator,
        address _descriptor,
        IWETH9 _weth9,
        IAllowanceTransfer _permit2,
        address _actionsImpl
    )
        ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
        BaseActionsRouter(IPoolManager(_manager))
        Permit2Forwarder(_permit2)
        FietNativeWrapper(_weth9)
        PositionManagerEntrypoint(_liquidityHub, _vtsOrchestrator, _actionsImpl)
    {
        commitmentDescriptor = _descriptor;
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
            (bytes calldata liquiditySignal, address owner) = params.decodeCommitSignalParams();
            _commitSignal(liquiditySignal, _mapRecipient(owner));
            return;
        }
        if (action == MMActions.RENEW_SIGNAL) {
            (uint256 tokenId, bytes calldata liquiditySignal) = params.decodeTokenIdAndBytes();
            _renewSignal(tokenId, liquiditySignal);
            return;
        }
        if (action == MMActions.DECOMMIT_SIGNAL) {
            uint256 tokenId = params.decodeDecommitSignalParams();
            _decommitSignal(tokenId);
            return;
        }
        if (action == MMActions.CHECKPOINT) {
            (uint256 tokenId, uint256 positionIndex, bool withCommitment) = params.decodeCheckpointParams();
            _checkpoint(msgSender(), tokenId, positionIndex, withCommitment);
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
    /// @param liquiditySignal The ABI-encoded LiquiditySignal to verify and record
    /// @param owner The address to receive the commitment NFT
    /// @return tokenId The commitment NFT id created
    function _commitSignal(bytes calldata liquiditySignal, address owner) internal returns (uint256 tokenId) {
        tokenId = vtsOrchestrator.commitSignal(liquiditySignal);
        _mint(owner, tokenId);
        emit SignalCommitted(tokenId);
    }

    /// @notice Renews an existing signal with new parameters
    /// @param tokenId The commitment NFT token ID
    /// @param liquiditySignal The new liquidity signal
    function _renewSignal(uint256 tokenId, bytes calldata liquiditySignal) internal {
        vtsOrchestrator.renewSignal(msgSender(), tokenId, liquiditySignal);
    }

    /// @notice Decommits a signal and burns the commitment NFT
    /// @param tokenId The commitment NFT token ID
    function _decommitSignal(uint256 tokenId) internal {
        MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);

        // Check if commit has any active positions (burned positions are inactive)
        (,, uint256 positionCount, uint256 activePositionCount) = vtsOrchestrator.getCommit(tokenId);
        if (activePositionCount > 0) {
            revert Errors.CommitNotEmpty(tokenId);
        }

        _burn(tokenId);
        emit SignalDecommitted(tokenId, uint256(positionCount));
    }

    /// @notice Marks a checkpoint for a position, optionally running commitment backing checks
    /// @param tokenId The commitment NFT token ID
    /// @param positionIndex The position index within the commitment
    /// @param withCommitment Whether to run commitment backing checks and update deficits
    function _checkpoint(
        address sender,
        uint256 tokenId,
        uint256 positionIndex,
        bool withCommitment
    ) internal {
        vtsOrchestrator.checkpoint(sender, tokenId, positionIndex, withCommitment);
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
            poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof
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
            if (payerIsUser) {
                _unwrapLccFromUser(lccAddr, _mapRecipient(recipient), amount);
            } else {
                _unwrapLccFromDeltas(lccAddr, _mapRecipient(recipient), amount);
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
            Currency currency = params.decodeSyncParams();
            _sync(currency);
            return;
        }
        revert Errors.UnsupportedAction(action);
    }

    /// @notice Unwraps LCC tokens to underlying asset using deltas (locker credit)
    function _unwrapLccFromDeltas(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
        ILCC lcc = ILCC(lccAddr);
        Currency lccCurrency = Currency.wrap(lccAddr);
        address underlying = lcc.underlying();

        uint256 beforeBal = IERC20(underlying).balanceOf(to);
        uint256 toUnwrap = vtsOrchestrator.take(lccCurrency, msgSender(), requested);

        if (toUnwrap > 0) {
            address queueTo = msgSender();
            liquidityHub.unwrapTo(lccAddr, to, queueTo, toUnwrap);
        }

        unwrapped = IERC20(underlying).balanceOf(to) - beforeBal;

        if (to == address(this) && unwrapped > 0) {
            _syncBalanceAsCredit(Currency.wrap(underlying));
        }
    }

    /// @notice Unwraps LCC tokens to underlying asset by pulling from the locker/user
    function _unwrapLccFromUser(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
        ILCC lcc = ILCC(lccAddr);
        Currency lccCurrency = Currency.wrap(lccAddr);
        address underlying = lcc.underlying();

        address payer = msgSender();
        uint256 toUnwrap = lcc.balanceOf(payer);
        if (requested > 0) {
            toUnwrap = Math.min(toUnwrap, requested);
        }

        uint256 beforeBal = IERC20(underlying).balanceOf(to);
        if (toUnwrap > 0) {
            // Pull only from the locker/user (never arbitrary third parties).
            lccCurrency.transferFrom(payer, address(this), toUnwrap);
            liquidityHub.unwrapTo(lccAddr, to, payer, toUnwrap);
        }

        unwrapped = IERC20(underlying).balanceOf(to) - beforeBal;
        if (to == address(this) && unwrapped > 0) {
            _syncBalanceAsCredit(Currency.wrap(underlying));
        }
    }

    /// @notice Collects available liquidity from settlement queue
    /// @param lcc The LCC token address
    /// @param maxAmount The maximum amount to collect
    function _collectAvailableLiquidity(address lcc, uint256 maxAmount) internal {
        address sender = msgSender();
        uint256 queued = liquidityHub.settleQueue(lcc, sender);

        if (queued > 0) {
            Currency lccCurrency = Currency.wrap(lcc);
            uint256 available = liquidityHub.reserveOfUnderlying(lcc);
            uint256 toSettle = Math.min(queued, Math.min(maxAmount, available));
            if (toSettle > 0) {
                lccCurrency.transfer(sender, toSettle); // transfer LCC to sender for burn/pay
                liquidityHub.processSettlementFor(lcc, sender, toSettle);
            }
        }
    }

    /// @notice Syncs currency balance as credit to delta
    /// @param currency The currency to sync
    /// @dev owner is always address(this) (MMPM) and target is always msgSender() (locker)
    function _sync(Currency currency) internal {
        vtsOrchestrator.sync(currency, address(this), msgSender());
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
        _syncBalanceAsCredit(CurrencyLibrary.ADDRESS_ZERO);
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
        returns (MarketMaker.State memory state, uint256 expiresAt, uint256 positionCount, uint256 activePositionCount)
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
    function checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment)
        external
        onlyIfPoolManagerLocked
    {
        _checkpoint(msg.sender, tokenId, positionIndex, withCommitment);
    }
}

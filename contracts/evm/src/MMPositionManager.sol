// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
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
import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
import {PositionManagerEntrypoint} from "./modules/PositionManagerEntrypoint.sol";
import {Permit2Forwarder} from "v4-periphery/src/base/Permit2Forwarder.sol";
import {MMActions} from "./libraries/MMActions.sol";
import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
import {MMHelpers} from "./libraries/MMHelpers.sol";
import {MMQueueCustodianLib} from "./libraries/MMQueueCustodianLib.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {IMMQueueCustodianFactory} from "./interfaces/IMMQueueCustodianFactory.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @title MMPositionManager
/// @notice Entry point for VRL commitment position management
/// @dev Handles commitment lifecycle (ERC721) and `INITIALISE` locally; delegates utility actions (>= `TAKE`) to
///      `MMUtilityActionsImpl` via `_delegateToUtilityImpl`, and position operations to `MMPositionActionsImpl`.
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
    using MMQueueCustodianLib for IMMPositionManager;

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
        /// @notice Delegatecall module for utility actions (>= `MMActions.TAKE`); excludes `INITIALISE`.
        address utilityActionsImpl;
        /// @notice Stateless deployer for `MMQueueCustodian` (authorises callers via `marketFactory.bounds`).
        address queueCustodianFactory;
    }

    using MMCalldataDecoder for bytes;
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
        PositionManagerEntrypoint(
            p.marketFactory, p.vtsOrchestrator, p.canonicalCustody, p.actionsImpl, p.utilityActionsImpl
        )
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
        return IMMPositionManager(address(this)).isRegisteredCustodian(candidate);
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
    /// @dev Actions >= TAKE delegate to `utilityActionsImpl` except `INITIALISE` (writes `custodianFor` here)
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

        // Currency/utility actions (>= TAKE) → utility impl (INITIALISE handled locally in `_handleUtilityAction`)
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
        if (action == MMActions.INITIALISE) {
            params.decodeInitialiseParams();
            _deployQueueCustodian(msgSender());
            return;
        }
        _delegateToUtilityImpl(abi.encodeWithSelector(IMMActionsImpl.handleAction.selector, action, params));
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

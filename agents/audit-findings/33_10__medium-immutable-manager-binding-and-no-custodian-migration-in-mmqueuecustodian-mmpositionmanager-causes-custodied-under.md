[Medium] Immutable manager binding and no custodian migration in MMQueueCustodian/MMPositionManager causes custodied underlying and queued settlements to be stranded on manager replacement

# Description

MMQueueCustodian hard-binds an [immutable positionManager](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMQueueCustodian.sol#L23) and gates release/unwrap to it, while MMPositionManager can [only deploy new custodians](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionManager.sol#L147-L153) and cannot adopt or rebind existing ones. On manager replacement, beneficiaries get new custodians; any underlying or queued LCC held at old custodians remains operable only by the old manager, risking frozen funds if the old manager cannot be used.

Each MMQueueCustodian is constructed with an [immutable positionManager](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMQueueCustodian.sol#L23) and exposes only two state-changing functions (unwrapLcc and release) restricted by onlyPositionManager. [Release always transfers underlying to the bound manager](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMQueueCustodian.sol#L98-L100), never to arbitrary recipients. MMPositionManager maintains a [custodianFor mapping](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionManager.sol#L92) and [only deploys fresh custodians via the factory](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMPositionManager.sol#L147-L153); it provides no function to adopt or rebind preexisting custodians. Consequently, when a new manager is deployed, it creates [different custodian addresses per beneficiary](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMQueueCustodianFactory.sol#L20). Any queued LCC or already-delivered underlying sitting in the old custodians can only be operated by the old manager. Although LiquidityHub has an [issuer-only cancelWithQueue path](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/LiquidityHub.sol#L704-L722) that could theoretically re-attribute queues, the issuer contracts exposed in this repository do not provide an admin/operator-callable method to perform such migration. The practical outcome is an upgrade/migration availability gap: users must continue using the old manager to drain legacy custodians, and if the old manager is unusable, these assets are effectively frozen.

# Severity

**Impact Explanation:** [Medium] Typical outcome is significant availability loss requiring continued use of the old manager to drain funds; a workable operational workaround exists. Only in the worst case (old manager unusable) does the impact escalate to frozen funds, but that branch is not the dominant, expected outcome under planned admin operations.

**Likelihood Explanation:** [Medium] Manager replacement with live balances/queues is a realistic operational state. However, under the trust assumption of diligent admin planning, fully unusable old-manager conditions are less common, moderating overall likelihood.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
After a manager replacement, a beneficiary’s old custodian holds underlying previously delivered by the Hub. Because release is onlyPositionManager and targets the old manager, and the new manager neither adopts old custodians nor [accepts ETH from them](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/modules/NativeWrapper.sol#L28-L45), the beneficiary cannot withdraw through the new manager. If the old manager is unusable, the underlying remains stuck.
#### Preconditions / Assumptions
- (a). A beneficiary has a deployed old custodian bound to the old manager with non-zero underlying already delivered to the custodian.
- (b). A new manager is deployed (address changes) and creates a new custodian for the beneficiary.
- (c). The old manager is deprecated or unusable (e.g., cannot execute release).

### Scenario 2.
Queued LCC shortfalls remain keyed to the old custodian address. Permissionless settlement can deliver underlying to that custodian, but only the old manager can subsequently release it. [Issuer-level re-attribution (cancelWithQueue)](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/LiquidityHub.sol#L704-L722) is not practically accessible via exposed APIs, so if the old manager is unusable, these claims cannot be migrated and the eventual underlying becomes stuck on the old custodian.
#### Preconditions / Assumptions
- (a). A beneficiary has non-zero LiquidityHub.settleQueue(lcc, old_custodian).
- (b). A new manager is deployed and creates a new custodian for the beneficiary.
- (c). Issuer contracts do not expose a callable migration method for cancelWithQueue in this deployment.
- (d). The old manager becomes unusable, preventing release from the old custodian after settlement.

### Scenario 3.
Attempts to forward funds directly from an old custodian to the new manager fail: the custodian can [only release to its bound manager](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMQueueCustodian.sol#L98-L100), and the new manager’s receive gate (valid ETH sender/custodian recognition) [rejects inbound value from old custodians](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/modules/NativeWrapper.sol#L28-L45). There is no on-chain adoption/rebind path, so migration through the new manager is blocked.
#### Preconditions / Assumptions
- (a). A new manager is deployed and recognizes only newly created custodians via its custodianFor mapping.
- (b). The old custodian remains bound to the old manager and cannot change its positionManager.
- (c). The new manager’s ETH receive gate only accepts ETH from recognized sources/custodians.

# Proposed fix

## MMQueueCustodian.sol

File: `contracts/evm/src/MMQueueCustodian.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MMQueueCustodian.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {ERC165} from "openzeppelin-contracts/contracts/utils/introspection/ERC165.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {INativeSettlementReceiver} from "./interfaces/INativeSettlementReceiver.sol";
 import {Errors} from "./libraries/Errors.sol";
 
 /// @title MMQueueCustodian
 /// @notice One queue custodian per beneficiary: Hub queue owner for that MM domain; actual LCC and underlying balances
 ///         on this contract are the receivable state (no shadow ledger).
 /// @dev `COLLECT_AVAILABLE_LIQUIDITY` settles when needed, then `release` credits the locker
 ///      through `MMPositionManager` pull flows (`TAKE`), not direct beneficiary push payout from this contract.
 contract MMQueueCustodian is IMMQueueCustodian, ERC165, INativeSettlementReceiver {
     /// @notice Underlying released to the position manager after settlement paths deliver underlying to this custodian.
     event UnderlyingReleasedToManager(address indexed lcc, uint256 amount);
 
+    // NOTE: Migration hardening: consider making `positionManager` rebindable by `beneficiary`
+    // (e.g., only-beneficiary `rebindPositionManager(newManager)`) to avoid stranding assets on manager replacement.
     address public immutable override positionManager;
     address public immutable override beneficiary;
 
     modifier onlyPositionManager() {
         if (msg.sender != positionManager) revert Errors.InvalidSender();
         _;
     }
 
     /// @dev Accept native underlying from `LiquidityHub` settlement for native-backed LCC markets.
     receive() external payable {}
 
     constructor(address _positionManager, address _beneficiary) {
         if (_positionManager == address(0) || _positionManager.code.length == 0) {
             revert Errors.InvalidAddress(_positionManager);
         }
         if (_beneficiary == address(0)) revert Errors.InvalidAddress(_beneficiary);
         positionManager = _positionManager;
         beneficiary = _beneficiary;
     }
 
     /// @inheritdoc INativeSettlementReceiver
     function supportsNativeSettlementFromFiet() external pure override returns (bool) {
         return true;
     }
 
     /// @inheritdoc ERC165
     function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
         return interfaceId == type(INativeSettlementReceiver).interfaceId || super.supportsInterface(interfaceId);
     }
 
     /// @inheritdoc IMMQueueCustodian
     function totalQueuedLcc(address lcc) external view override returns (uint256) {
         return IERC20(lcc).balanceOf(address(this));
     }
 
     /// @inheritdoc IMMQueueCustodian
     /// @notice Hub `unwrap` as this contract: shortfall queues to `address(this)`; immediate underlying is forwarded to `forwardUnderlyingTo`.
     /// @dev `MMPM` must transfer `amount` LCC to this contract before calling. Canonical Hub: `ILCC(lcc).hub()`.
     function unwrapLcc(address lcc, address forwardUnderlyingTo, uint256 amount) external onlyPositionManager {
         if (amount == 0) return;
         if (forwardUnderlyingTo == address(0)) revert Errors.InvalidAddress(forwardUnderlyingTo);
 
         ILiquidityHub hub = ILiquidityHub(ILCC(lcc).hub());
 
         address underlying = ILCC(lcc).underlying();
         uint256 uBalBefore =
             underlying == address(0) ? address(this).balance : IERC20(underlying).balanceOf(address(this));
 
         uint256 qBefore = hub.settleQueue(lcc, address(this));
         hub.unwrap(lcc, amount);
         uint256 queuedDelta = hub.settleQueue(lcc, address(this)) - qBefore;
 
         if (queuedDelta > 0) {
             uint256 bal = IERC20(lcc).balanceOf(address(this));
             if (bal < queuedDelta) revert Errors.InsufficientBalance(bal, queuedDelta);
         }
 
         uint256 uBalAfter =
             underlying == address(0) ? address(this).balance : IERC20(underlying).balanceOf(address(this));
         uint256 immediateReceived = uBalAfter - uBalBefore;
 
         if (immediateReceived > 0) {
             Currency.wrap(underlying).transfer(forwardUnderlyingTo, immediateReceived);
         }
     }
 
     /// @inheritdoc IMMQueueCustodian
     function release(address lcc, uint256 amount) external override onlyPositionManager {
         if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
         if (amount == 0) return;
 
         address underlying = ILCC(lcc).underlying();
         uint256 available =
             underlying == address(0) ? address(this).balance : IERC20(underlying).balanceOf(address(this));
         uint256 toSend = Math.min(amount, available);
         if (toSend == 0) return;
 
         address to = positionManager;
         Currency.wrap(underlying).transfer(to, toSend);
         emit UnderlyingReleasedToManager(lcc, toSend);
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
+    // NOTE: Migration hardening: consider adding `adoptQueueCustodian(custAddr)` (beneficiary-only; requires
+    // `IMMQueueCustodian(custAddr).positionManager() == address(this)`) and an optional controlled
+    // `drainSpecifiedCustodian(...)` to safely settle+release during migration.
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

## NativeWrapper.sol

File: `contracts/evm/src/modules/NativeWrapper.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/modules/NativeWrapper.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {NativeWrapper as UniNativeWrapper} from "../forks/NativeWrapper.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 import {Errors} from "../libraries/Errors.sol";
 import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
 import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";
 
 /// @title FietNativeWrapper
 /// @notice Used for wrapping and unwrapping native assets in PositionManagers.
 /// @dev Named to avoid colliding with the forked `NativeWrapper` contract name in this codebase.
 abstract contract FietNativeWrapper is UniNativeWrapper {
     constructor(IWETH9 _weth9) UniNativeWrapper(_weth9) {}
 
     /// @dev Implemented by inheritors that already bind a canonical MarketFactory namespace.
     function _canonicalMarketFactory() internal view virtual returns (IMarketFactory);
     /// @dev Implemented by inheritors with canonical LiquidityHub binding.
     function _liquidityHub() internal view virtual returns (ILiquidityHub);
 
     /// @dev Bound `MMQueueCustodian` sending native after Hub `unwrap` / release. Inheritors (e.g. `MMPositionManager`) registry-match `beneficiary` to `custodianFor`.
+    // NOTE: If adding adopt/drain helpers, ensure `custodianFor` is updated (or temporarily toggled) so this
+    // receive-gate recognizes the intended custodian during controlled draining.
     function _isCustodian(address) internal view virtual returns (bool) {
         return false;
     }
 
     /// @notice Validates that the ETH sender is either WETH9, poolManager, canonical LiquidityHub, or a canonical native vault
     /// @dev Uses MarketFactory registry data to avoid interface-probing based sender spoofing.
     function _assertValidEthSender() internal view {
         // If sender is WETH9 or poolManager, allow it (these are trusted sources)
         if (msg.sender == address(WETH9) || msg.sender == address(poolManager)) {
             return;
         }
 
         // Allow canonical Hub-native payouts (e.g. native LCC unwrap-to-self in MMPM).
         if (msg.sender == address(_liquidityHub())) {
             return;
         }
 
         // Native-backed LCC unwrap: bound `MMQueueCustodian` forwards immediate ETH from Hub to this manager for delta credit.
         if (_isCustodian(msg.sender)) {
             return;
         }
 
         IMarketFactory factory = _canonicalMarketFactory();
         address sender = msg.sender;
         if (sender.code.length == 0) {
             revert Errors.InvalidEthSender();
         }
 
         // Canonical vault lookup by sender address; unknown senders map to [0,0].
         address[2] memory underlyingPair = factory.proxyHookToCurrencyPair(sender);
         bool native0 = underlyingPair[0] == address(0);
         bool native1 = underlyingPair[1] == address(0);
 
         // Require exactly one native leg. This rejects unknown senders ([0,0]) and non-native markets.
         if (native0 == native1) {
             revert Errors.InvalidEthSender();
         }
     }
 
     // Best practice: be explicit about intent
     // Only executes on plain transaction (no selector) (ie. poolManager or WETH9 transfer of assets) to MarketVault.
     // Plain transactions are performed by the pool manager or external contracts in native asset routes.
     // ie. Only be executed if the msg.sender is the market vault in route: PM -> MV -> LH
     // This function replaces the forked NativeWrapper receive() to include MarketVault.
     receive() external payable override {
         _assertValidEthSender();
     }
 }
```

[High] Queue-recipient migration to per-recipient custodians in MMPositionManager/Reactive causes automated MM settlements to stall and block decommit/transfer

# Description

The PR changes MM settlement queue ownership from locker addresses to per-recipient MMQueueCustodian contracts, but the included reactive stack remains recipient-address keyed and the destination receiver only settles to the custodian. Without added forwarding from custodian to lockers and bucket draining, automation halts at the custodian and new bucket-empty gates can block decommit/transfer until manual collects.

This PR migrates MM queue ownership to per-recipient MMQueueCustodian addresses. Position hooks now encode a [queueRecipient (the custodian)](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/types/Position.sol#L82-L87), and queue increments and events are keyed to that address. The reactive pipeline (SpokeRSC/HubCallback/HubRSC) remains recipient-address keyed and the provided destination receiver [calls only LiquidityHub.processSettlementFor(lcc, recipient)](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/periphery/BatchProcessSettlement.sol#L47), which now pays the custodian, not the locker. No custodian-deployed event is emitted, and the reactive stack does not forward underlying from the custodian to lockers or drain custodian buckets. The PR also adds gates that [revert decommit and transfer](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/MMPositionManager.sol#L642-L643) when a custodian bucket for a commit token is non-empty. As a result, even with Spokes configured for custodians, automation settles to the custodian but leaves buckets non-empty and lockers unpaid, blocking lifecycle actions until manual collection is performed through MMPM. This is an integration/liveness regression introduced by the PR; funds are not at risk, but end-to-end MM settlement automation is incomplete and can cause persistent availability issues.

# Severity

**Impact Explanation:** [Medium] Significant availability loss and lifecycle blocking for MM positions (decommit/transfer revert) until manual collect; no direct fund loss and a known workaround exists.

**Likelihood Explanation:** [High] Under trusted, diligent ops, Spokes will be configured for custodians; then the included destination receiver deterministically settles to custodians without draining buckets or paying lockers, causing systemic liveness issues across MM queues without special conditions.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
With Spokes configured for custodian recipients, HubRSC dispatches to the destination receiver which [settles LiquidityHub.processSettlementFor(lcc, custodian)](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/periphery/BatchProcessSettlement.sol#L47). Underlying is paid to the custodian, but no automated call forwards it to the locker or drains custodian buckets. Custodian buckets remain non-empty, so [decommit and NFT transfer revert](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/MMPositionManager.sol#L642-L643) until the user manually invokes MMPM collect, which both settles and pays out to the locker.
#### Preconditions / Assumptions
- (a). PR deployed with queueRecipient set to MMQueueCustodian addresses
- (b). Ops deploy/whitelist SpokeRSC for custodian recipients in HubCallback
- (c). Reactive destination receiver remains as included (only calls LiquidityHub.processSettlementFor)

### Scenario 2.
Repeated MM decreases/utility unwraps record slices into custodian buckets (tokenId or utility bucket). Even if reserves allow settlement, the destination receiver pays the custodian only; without manual collect, buckets remain non-empty. Decommit/transfer attempts keep reverting until sufficient manual collects drain the relevant custodian buckets.
#### Preconditions / Assumptions
- (a). PR deployed with custodian recipients active
- (b). Users perform MM decreases/utility unwraps that record custody to custodian buckets
- (c). Reactive destination receiver does not forward underlying from custodian to lockers

### Scenario 3.
If ops do not deploy/whitelist SpokeRSC for the new custodian recipients, LiquidityHub [SettlementQueued(lcc, custodian, ...)](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/LiquidityHub.sol#L1088-L1095) logs are not ingested. HubRSC has no pending entries and never dispatches. Queues and custodian buckets remain populated, and decommit/transfer revert until users manually collect.
#### Preconditions / Assumptions
- (a). PR deployed with custodian recipients active
- (b). Ops have not yet deployed/whitelisted SpokeRSC for the new custodian recipients

# Proposed fix

## MMQueueCustodian.sol

File: `contracts/evm/src/MMQueueCustodian.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/MMQueueCustodian.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
 import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {Errors} from "./libraries/Errors.sol";
 
 /// @title MMQueueCustodian
 /// @notice Per-NFT-recipient queue owner: one custodian serves many commitment NFTs (`bucketId == tokenId`; utility uses `0`).
 /// @dev The Hub `settleQueue(lcc, address(this))` entry is owned by this contract; beneficiary-scoped `_queuedLcc`
 ///      tracks who may collect underlying after `LiquidityHub.processSettlementFor` pays this contract.
 ///
 ///      Intended model:
 ///      - `beneficiary` is the MM batch locker (owner, operator, or seizer) entitled to that staged principal slice.
 ///      - `COLLECT_AVAILABLE_LIQUIDITY` settles LCC against the Hub queue for this custodian, then forwards underlying
 ///        to the beneficiary via `collectUnderlyingToBeneficiary`.
 ///      - `unwrapLccViaHub` calls Hub `unwrap` as this contract (queue owner == `address(this)`), then forwards any
 ///        immediately-received underlying to `forwardUnderlyingTo` (typically MMPM for native, locker or MMPM for ERC20).
 contract MMQueueCustodian is IMMQueueCustodian {
     using CurrencyTransfer for Currency;
     using SafeERC20 for IERC20;
 
     /// @notice Beneficiary-scoped custody increased (MM-backed LCC staged for later Hub settlement).
     event CustodyRecorded(uint256 indexed tokenId, address indexed lcc, address indexed beneficiary, uint256 amount);
 
     /// @notice Underlying paid out after Hub settlement burned custodied LCC against this contract.
     event UnderlyingPaid(uint256 indexed tokenId, address indexed lcc, address indexed beneficiary, uint256 amount);
 
     address public override positionManager;
 
     /// @dev Per-bucket aggregate for `isBucketEmpty(bucketId)` (decommit / transfer guards).
     mapping(uint256 bucketId => uint256) private _bucketQueuedTotal;
 
     // tokenId => lcc => beneficiary => queued custody balance
     mapping(uint256 tokenId => mapping(address lcc => mapping(address beneficiary => uint256 amount))) private
         _queuedLcc;
 
     modifier onlyPositionManager() {
         if (msg.sender != positionManager) revert Errors.InvalidSender();
         _;
     }
 
     /// @dev Accept native underlying from `LiquidityHub` settlement for native-backed LCC markets.
     receive() external payable {}
 
     constructor(address _positionManager) {
         if (_positionManager == address(0) || _positionManager.code.length == 0) {
             revert Errors.InvalidAddress(_positionManager);
         }
         positionManager = _positionManager;
     }
 
     /// @inheritdoc IMMQueueCustodian
     function record(uint256 tokenId, address lcc, address beneficiary, uint256 amount)
         external
         override
         onlyPositionManager
     {
         _record(tokenId, lcc, beneficiary, amount);
     }
 
     function _record(uint256 tokenId, address lcc, address beneficiary, uint256 amount) private {
         if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
         if (beneficiary == address(0)) revert Errors.InvalidAddress(beneficiary);
         if (amount == 0) return;
         _queuedLcc[tokenId][lcc][beneficiary] += amount;
         _bucketQueuedTotal[tokenId] += amount;
         emit CustodyRecorded(tokenId, lcc, beneficiary, amount);
     }
 
     /// @notice Hub `unwrap` as this contract: shortfall queues to `address(this)`; immediate underlying is forwarded to `forwardUnderlyingTo`.
     /// @dev `MMPM` must transfer `amount` LCC to this contract before calling. Native: forward to MMPM (`positionManager`) for delta credit; ERC20: forward per MM routing (`to` or MMPM).
     function unwrapLccViaHub(
         address lcc,
         address forwardUnderlyingTo,
         address beneficiary,
         uint256 bucketId,
         uint256 amount,
         ILiquidityHub hub
     ) external onlyPositionManager {
         if (amount == 0) return;
         if (forwardUnderlyingTo == address(0)) revert Errors.InvalidAddress(forwardUnderlyingTo);
 
         address underlying = ILCC(lcc).underlying();
         uint256 uBalBefore =
             underlying == address(0) ? address(this).balance : IERC20(underlying).balanceOf(address(this));
 
         uint256 qBefore = hub.settleQueue(lcc, address(this));
         hub.unwrap(lcc, amount);
         uint256 queuedDelta = hub.settleQueue(lcc, address(this)) - qBefore;
 
         uint256 uBalAfter =
             underlying == address(0) ? address(this).balance : IERC20(underlying).balanceOf(address(this));
         uint256 immediateReceived = uBalAfter - uBalBefore;
 
         if (queuedDelta > 0) {
             uint256 bal = IERC20(lcc).balanceOf(address(this));
             if (bal < queuedDelta) revert Errors.InsufficientBalance(bal, queuedDelta);
             _record(bucketId, lcc, beneficiary, queuedDelta);
         }
 
         if (immediateReceived > 0) {
             if (underlying == address(0)) {
                 (bool ok,) = forwardUnderlyingTo.call{value: immediateReceived}("");
                 if (!ok) revert Errors.InvalidAmount(immediateReceived, 0);
             } else {
                 IERC20(underlying).safeTransfer(forwardUnderlyingTo, immediateReceived);
             }
         }
     }
 
     /// @inheritdoc IMMQueueCustodian
     function collectUnderlyingToBeneficiary(uint256 tokenId, address lcc, address beneficiary, uint256 amount)
         external
         override
         onlyPositionManager
     {
         if (beneficiary == address(0)) revert Errors.InvalidAddress(beneficiary);
         if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
         if (amount == 0) return;
 
         uint256 q = _queuedLcc[tokenId][lcc][beneficiary];
         if (amount > q) revert Errors.InsufficientBalance(q, amount);
         _queuedLcc[tokenId][lcc][beneficiary] = q - amount;
         _bucketQueuedTotal[tokenId] -= amount;
 
         address underlying = ILCC(lcc).underlying();
         if (underlying == address(0)) {
             (bool ok,) = beneficiary.call{value: amount}("");
             if (!ok) revert Errors.InvalidAmount(amount, 0);
         } else {
             IERC20(underlying).safeTransfer(beneficiary, amount);
         }
         emit UnderlyingPaid(tokenId, lcc, beneficiary, amount);
     }
 
+    // TODO: Add a permissionless `settleAndPay(lcc, tokenId, beneficiary, maxAmount, hub)` that caps by
+    //       (hub.settleQueue, queued slice, holderBal, reserveMarket), calls `hub.processSettlementFor` and then pays beneficiary, finally decrementing `_queuedLcc` and `_bucketQueuedTotal`.
     /// @inheritdoc IMMQueueCustodian
     function isBucketEmpty(uint256 bucketId) external view override returns (bool) {
         return _bucketQueuedTotal[bucketId] == 0;
     }
 
     function queued(uint256 tokenId, address lcc, address beneficiary) external view override returns (uint256) {
         return _queuedLcc[tokenId][lcc][beneficiary];
     }
 }
```

## BatchProcessSettlement.sol

File: `contracts/reactive/src/dest/BatchProcessSettlement.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/reactive/src/dest/BatchProcessSettlement.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {AbstractBatchProcessSettlement} from "evm/periphery/BatchProcessSettlement.sol";
 import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";
 
 /// @notice Reactive destination receiver that batches settlement processing.
 contract BatchProcessSettlement is AbstractBatchProcessSettlement, AbstractCallback {
     error InvalidHubRVMId();
     error InvalidCallbackOrigin(address expectedHubRVMId, address actualCallbackOrigin);
 
+    // TODO: Add a new route `processCustodianSettlements(...)` that invokes
+    //       `MMQueueCustodian(custodian).settleAndPay(lcc, tokenId, beneficiary, maxAmount, liquidityHub)` per item.
     /// @notice Expected HubRSC origin (RVM id) allowed to dispatch batches.
     address public immutable hubRVMId;
 
     /// @param _callbackProxy Reactive callback proxy address for this chain.
     /// https://dev.reactive.network/origins-and-destinations#testnet-chains
     /// @param _liquidityHub LiquidityHub to call on the destination chain.
     /// @param _hubRVMId HubRSC RVM id allowed as callback origin.
     constructor(address _callbackProxy, address _liquidityHub, address _hubRVMId)
         payable
         AbstractBatchProcessSettlement(_liquidityHub)
         AbstractCallback(_callbackProxy)
     {
         if (_hubRVMId == address(0)) revert InvalidHubRVMId();
         hubRVMId = _hubRVMId;
     }
 
     /// @notice Process a batch of settlement requests received from Reactive callbacks.
     /// @param callbackOrigin Originating callback contract address from the source chain.
     /// @param lcc Array of LCC token addresses.
     /// @param recipient Array of recipients.
     /// @param maxAmount Array of max amounts to settle.
     /// @dev Continues on individual failures and emits per-item success/failure.
     /// @custom:emits BatchReceived, SettlementSucceeded, SettlementFailed
     function processSettlements(
         address callbackOrigin,
         address[] memory lcc,
         address[] memory recipient,
         uint256[] memory maxAmount
     ) external authorizedSenderOnly {
         if (callbackOrigin != hubRVMId) {
             revert InvalidCallbackOrigin(hubRVMId, callbackOrigin);
         }
         processSettlements(lcc, recipient, maxAmount);
     }
 }
```

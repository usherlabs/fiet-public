[High] Missing WETH fallback for native payouts in MMQueueCustodian causes frozen funds and blocked commitment lifecycle

# Description

For native-backed LCC queues, MMQueueCustodian forwards ETH to beneficiaries via a raw call without a WETH fallback. Non-payable contract beneficiaries cannot receive payouts, causing collection attempts to revert and leaving custodied entitlements undrainable. New guards also block commitment transfer/decommit while buckets remain non-empty.

The settlement flow was changed to first pay underlying from LiquidityHub to a recipient-keyed MMQueueCustodian, and then forward the underlying from the custodian to the beneficiary. LiquidityHub’s native payout (used previously for final recipients) has a WETH fallback on failure, but MMQueueCustodian.collectUnderlyingToBeneficiary uses a raw ETH call and reverts if the beneficiary is non-payable. There is no fallback to WETH and no way to redirect payout. As a result, for native-backed LCC queues, any non-payable contract beneficiary cannot collect their entitlement: collection reverts indefinitely and the custodian bucket remains non-empty. The PR also added guards that prevent commitment transfer and decommit while the bucket is not drained, so affected commitments can become non-transferable and non-decommittable.

# Severity

**Impact Explanation:** [High] Funds owed to beneficiaries can be frozen indefinitely due to failed native payouts with no WETH fallback or redirection, and commitment NFTs can become non-transferable and non-decommittable due to undrainable buckets.

**Likelihood Explanation:** [Medium] The issue requires native-backed LCC markets and non-payable contract beneficiaries. These are uncommon but realistic conditions, especially as the design explicitly supports contract recipients.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
A locker using a non-payable smart contract attempts COLLECT_AVAILABLE_LIQUIDITY for a native-backed LCC entitlement recorded on their custodian bucket. LiquidityHub successfully settles to the custodian, but MMQueueCustodian.collectUnderlyingToBeneficiary reverts on the raw ETH push to the non-payable locker. The entitlement remains undrained, and future collection attempts keep reverting.
#### Preconditions / Assumptions
- (a). The market’s LCC is backed by native ETH (underlying == address(0))
- (b). The locker/beneficiary is a non-payable smart contract
- (c). There is a positive custodied entitlement recorded for the beneficiary in the custodian bucket
- (d). Sufficient reserve becomes available for LiquidityHub.processSettlementFor to attempt settlement

### Scenario 2.
A commitment owner with a native-backed LCC entitlement recorded in their custodian bucket under tokenId tries to transfer or decommit. Because the beneficiary (locker) is a non-payable contract and collection reverts, the bucket never drains. MMPositionManager’s guards (isBucketEmpty) cause transferFrom and decommit to revert, freezing the commitment’s lifecycle.
#### Preconditions / Assumptions
- (a). The market’s LCC is backed by native ETH (underlying == address(0))
- (b). The locker/beneficiary is a non-payable smart contract
- (c). A positive entitlement is recorded under the commitment’s bucket (tokenId) in the custodian
- (d). MMPositionManager’s transfer/decommit is guarded by isBucketEmpty and requires the bucket to be drained

### Scenario 3.
A valid seizer (acting under protocol rules) uses a non-payable contract address as the locker for SEIZE_POSITION on a victim’s commit with a native-backed leg. The queued principal for the seizure is recorded under the victim’s custodian bucket but keyed to the seizer’s non-payable address. Collection reverts for the seizer, leaving the bucket permanently non-empty and blocking the victim’s transfer/decommit.
#### Preconditions / Assumptions
- (a). The market’s LCC includes a native-backed leg (underlying == address(0))
- (b). Seizure conditions are met allowing SEIZE_POSITION
- (c). The seizer uses a non-payable smart contract address as the locker
- (d). Queued principal from seizure is recorded under the victim’s custodian bucket and keyed to the seizer’s address

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
+import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
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
-            if (!ok) revert Errors.InvalidAmount(amount, 0);
+            if (!ok) {
+                (bool wok, bytes memory wdata) = positionManager.staticcall(abi.encodeWithSignature("WETH9()"));
+                if (!wok || wdata.length < 32) revert Errors.InvalidAmount(amount, 0);
+                address weth = abi.decode(wdata, (address));
+                IWETH9(weth).deposit{value: amount}();
+                IERC20(weth).safeTransfer(beneficiary, amount);
+            }
         } else {
             IERC20(underlying).safeTransfer(beneficiary, amount);
         }
         emit UnderlyingPaid(tokenId, lcc, beneficiary, amount);
     }
 
     /// @inheritdoc IMMQueueCustodian
     function isBucketEmpty(uint256 bucketId) external view override returns (bool) {
         return _bucketQueuedTotal[bucketId] == 0;
     }
 
     function queued(uint256 tokenId, address lcc, address beneficiary) external view override returns (uint256) {
         return _queuedLcc[tokenId][lcc][beneficiary];
     }
 }
```

# Related findings

## [High] Missing WETH fallback in MMQueueCustodian native payout causes frozen queued payouts and blocked commitment transfer/decommit

### Description

The new custodian-mediated collect flow pays the custodian first and then [pushes native ETH directly to the beneficiary](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/MMQueueCustodian.sol#L133-L137) without a WETH fallback. Non-payable beneficiaries cannot receive funds, collects revert, custody buckets never drain, and [commitment transfer/decommit are blocked](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/MMPositionManager.sol#L352-L360). Additionally, if a third party pre-settles the Hub queue to the custodian, ETH can remain stuck on the custodian while [the manager refuses to forward it](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/MMPositionManager.sol#L560-L573).

The PR changed the MM collection path to route queued settlements as: Hub → custodian → beneficiary. [MMPositionManager._collectAvailableLiquidity now calls LiquidityHub.processSettlementFor(lcc, custAddr, amount) and then MMQueueCustodian.collectUnderlyingToBeneficiary(...)](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/MMPositionManager.sol#L560-L573). For native-backed markets, the custodian forwards underlying via a [raw beneficiary.call{value: amount}("")](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/MMQueueCustodian.sol#L133-L137) without a WETH fallback. Previously, the Hub’s direct payout path ([LiquidityHubLib.transferUnderlying](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/libraries/LiquidityHubLib.sol#L576-L587)) applied a WETH fallback when a native push failed. Under the new path, non-payable lockers/advancers/seizers cannot be paid: collects revert, the custodian’s per-bucket totals remain > 0, and commitment transfer/decommit are blocked by [CommitCustodyNotDrained](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/MMPositionManager.sol#L352-L360). A second liveness trap arises when a third party pre-settles the Hub queue to the custodian: [the manager computes amount == 0 and returns early](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/MMPositionManager.sol#L560-L573), never forwarding ETH already on the custodian, leaving custody non-empty and value stuck.

### Severity

**Impact Explanation:** [High] Funds are frozen for affected users (no in-protocol workaround) and, for commitment buckets, the custody ledger remaining non-empty blocks core lifecycle actions (transfer/decommit).

**Likelihood Explanation:** [Medium] Non-payable lockers are plausible though not universal; front-running settlement is feasible but unprofitable griefing. Overall, scenarios are uncommon but realistic.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1 (High): A native-backed market owes queued liquidity to a non-payable locker. The locker calls COLLECT_AVAILABLE_LIQUIDITY; the manager settles Hub → custodian and then calls [custodian.collectUnderlyingToBeneficiary](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/MMPositionManager.sol#L560-L573). The [final native push to the locker reverts due to non-payability](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/MMQueueCustodian.sol#L133-L137), so the transaction reverts, the custody ledger never decreases, and commitment transfer/decommit remain blocked by CommitCustodyNotDrained.
#### Preconditions / Assumptions
- (a). Market is native-backed (ILCC(lcc).underlying() == address(0))
- (b). Beneficiary (locker/advancer/seizer) is a non-payable contract or rejects ETH
- (c). Custodian holds recorded entitlement for the beneficiary and sufficient market-derived LCC is available to burn; Hub reserve available for settlement

### Scenario 2.
Scenario 2 (Medium): A third party front-runs settlement by calling [LiquidityHub.processSettlementFor(lcc, custAddr, ..)](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/LiquidityHub.sol#L931-L941), paying ETH to the custodian and zeroing hubQ. Later, the locker calls COLLECT_AVAILABLE_LIQUIDITY; [the manager computes amount == 0 and returns early](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/MMPositionManager.sol#L560-L573), never calling custodian.collectUnderlyingToBeneficiary. ETH remains stuck on the custodian, the custody ledger does not decrease, and commitment transfer/decommit remain blocked.
#### Preconditions / Assumptions
- (a). Market is native-backed
- (b). Custodian has a non-zero Hub settle queue and sufficient market-derived LCC to burn
- (c). A third party calls LiquidityHub.processSettlementFor(lcc, custAddr, ..) before the locker’s collect, reducing hubQ to zero

### Scenario 3.
Scenario 3 (High): A native-backed UNWRAP_LCC with market shortfall queues residual to the custodian’s utility bucket (tokenId=0) for a non-payable locker. On COLLECT_AVAILABLE_LIQUIDITY for bucket 0, the [final native push reverts](https://github.com/usherlabs/fiet-protocol/blob/84f5c03842082bd9984dbfd2174305fbd7ce4aaa/contracts/evm/src/MMQueueCustodian.sol#L133-L137); residual funds remain uncollectable. Although bucket 0 does not block commitment transfer/decommit, the user’s queued funds are frozen.
#### Preconditions / Assumptions
- (a). Market is native-backed
- (b). UNWRAP_LCC created a shortfall queued to the custodian’s utility bucket (tokenId=0)
- (c). Beneficiary (locker) is a non-payable contract or rejects ETH

### Proposed fix

#### MMQueueCustodian.sol

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
+import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
+interface ILiquidityHubWeth9 { function weth9() external view returns (address); }
 
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
-            if (!ok) revert Errors.InvalidAmount(amount, 0);
+            if (!ok) {
+                // Fallback to WETH when native push fails (mirrors Hub payout behavior).
+                address hub = ILCC(lcc).hub();
+                address wrappedNative = ILiquidityHubWeth9(hub).weth9();
+                IWETH9(wrappedNative).deposit{value: amount}();
+                IERC20(wrappedNative).safeTransfer(beneficiary, amount);
+            }
         } else {
             IERC20(underlying).safeTransfer(beneficiary, amount);
         }
         emit UnderlyingPaid(tokenId, lcc, beneficiary, amount);
     }
 
     /// @inheritdoc IMMQueueCustodian
     function isBucketEmpty(uint256 bucketId) external view override returns (bool) {
         return _bucketQueuedTotal[bucketId] == 0;
     }
 
     function queued(uint256 tokenId, address lcc, address beneficiary) external view override returns (uint256) {
         return _queuedLcc[tokenId][lcc][beneficiary];
     }
 }
```

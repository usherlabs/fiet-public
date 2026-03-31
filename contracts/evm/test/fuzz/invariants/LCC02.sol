// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHub} from "../../../src/LiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../../../src/LCC.sol";
import {MockOracleHelper} from "../mocks/MockOracleHelper.sol";
import {MockERC20Transferable} from "../mocks/MockERC20Transferable.sol";
import {Bounds} from "../../../src/libraries/Bounds.sol";
import {EchidnaLinkedLibs} from "../base/EchidnaLinkedLibs.sol";

/// @notice Echidna harness for LCC-02: bucket accounting consistency with transfer flow.
/// @dev "For non-protocol → protocol transfers, queued-settlement ownership must be annulled
///      before bucket decrement to prevent bleeding into the queue."
///
/// Properties tested:
///   1. Bucket sum (wrapped + marketDerived) always equals balanceOf for non-exempt holders
///   2. Settlement queue tracks our independently maintained model
///   3. Non-protocol → protocol transfers correctly annul queue bleed-through
///   4. totalQueued decreases by exactly the annulled amount
contract LCC02 {
    uint256 internal constant MAX_ACTION_AMOUNT = 1e24;
    uint256 internal constant SEED_BALANCE = 500e18;

    LiquidityHub internal hub;
    LiquidityCommitmentCertificate internal lcc;
    MockERC20Transferable internal underlying;

    // Non-protocol holder whose buckets and queue we track.
    LCC02Holder internal holder;
    // Protocol-bound endpoint (BOUND_ENDPOINT) as transfer target.
    LCC02Holder internal endpoint;

    // Harness-side model for holder's expected queue.
    uint256 internal expectedHolderQueued;

    // Action/result: transfer to protocol correctly annuls queue bleed.
    bool internal checkedTransferAnnuls;
    bool internal lastTransferAnnulsOk;

    // ================================================================
    // Helpers
    // ================================================================

    function _boundAmount(uint256 amount) internal pure returns (uint256) {
        return (amount % MAX_ACTION_AMOUNT) + 1;
    }

    /// @dev Computes the expected annulment for a non-protocol → protocol transfer.
    ///      Mirrors the logic in LiquidityHubLib.annulSettlementBeforeTransfer.
    function _expectedAnnulment(uint256 wrappedBal, uint256 marketBal, uint256 queued, uint256 transferAmt)
        internal
        pure
        returns (uint256 annulled)
    {
        uint256 liquidBalance = wrappedBal + marketBal;
        uint256 transferableWithoutQueue = liquidBalance > queued ? liquidBalance - queued : 0;
        if (transferAmt > transferableWithoutQueue) {
            uint256 bleed = transferAmt - transferableWithoutQueue;
            annulled = bleed < queued ? bleed : queued;
        }
    }

    // ================================================================
    // Constructor
    // ================================================================

    constructor() {
        EchidnaLinkedLibs.deployLCCFactoryLinkedLib();
        EchidnaLinkedLibs.deployLiquidityHubLinkedLib();

        MockOracleHelper oracleHelper = new MockOracleHelper(address(0));
        hub = new LiquidityHub(address(oracleHelper), "Ether", "ETH", 18, address(this));
        hub.setFactory(address(this), true);
        hub.setBoundLevel(address(hub), Bounds.BOUND_EXEMPT);

        address[] memory issuers = new address[](1);
        issuers[0] = address(this);

        underlying = new MockERC20Transferable();
        MockERC20Transferable other = new MockERC20Transferable();
        bytes memory marketRef = abi.encodePacked(address(this));
        (address l0, address l1) = hub.createLCCPair(marketRef, address(underlying), address(other), "TEST", issuers);
        hub.initialize(l0, l1, bytes32(uint256(1)), marketRef);
        address underlying0 = hub.getUnderlying(l0);
        lcc = LiquidityCommitmentCertificate(underlying0 == address(underlying) ? l0 : l1);

        holder = new LCC02Holder();
        endpoint = new LCC02Holder();
        hub.setBoundLevel(address(endpoint), Bounds.BOUND_ENDPOINT);

        // Seed holder with market-derived balance.
        hub.issue(address(lcc), address(holder), SEED_BALANCE);

        // Seed the transfer-annuls check with a disposable holder.
        _seedTransferAnnuls();
    }

    function _seedTransferAnnuls() internal {
        LCC02Holder seedHolder = new LCC02Holder();
        uint256 total = 100;
        uint256 q = 40;

        hub.issue(address(lcc), address(seedHolder), total);
        if (!seedHolder.unwrapToQueue(address(hub), address(lcc), q)) return;

        // After queuing 40, balance is 60. Transfer the remaining 60 to protocol.
        // The annul logic: liquidBalance=60, queue=40, transferableWithoutQueue=20.
        // bleed = 60 - 20 = 40, annulled = min(40, 40) = 40. Queue should go to 0.
        uint256 remaining = total - q;
        uint256 queueBefore = hub.settleQueue(address(lcc), address(seedHolder));
        uint256 totalQueuedBefore = hub.totalQueued(address(lcc));

        if (!seedHolder.transfer(address(lcc), address(hub), remaining)) return;

        uint256 queueAfter = hub.settleQueue(address(lcc), address(seedHolder));
        uint256 totalQueuedAfter = hub.totalQueued(address(lcc));

        checkedTransferAnnuls = true;
        lastTransferAnnulsOk = (queueBefore == q) && (queueAfter == 0) && (totalQueuedAfter == totalQueuedBefore - q);
    }

    /// @dev Deterministic no-liquidity factory callback.
    function useMarketLiquidity(address, bytes32, uint256) external view returns (uint256 used) {
        if (msg.sender != address(hub)) revert();
        return 0;
    }

    // ================================================================
    // Actions — build state
    // ================================================================

    /// @dev Issue market-derived LCC to the tracked holder.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_02_issue_to_holder(uint256 amount) external {
        hub.issue(address(lcc), address(holder), _boundAmount(amount));
    }

    /// @dev Holder queues a settlement claim via unwrapTo (burns LCC, creates queue entry).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_02_queue_settlement(uint256 amount) external {
        uint256 bal = lcc.balanceOf(address(holder));
        if (bal == 0) return;

        uint256 amt = (amount % bal) + 1;
        if (holder.unwrapToQueue(address(hub), address(lcc), amt)) {
            expectedHolderQueued += amt;
        }
    }

    /// @dev Fund market reserve and process a queued settlement.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_02_process_settlement(uint256 amount) external {
        uint256 queued = hub.settleQueue(address(lcc), address(holder));
        if (queued == 0) return;

        uint256 amt = (amount % queued) + 1;
        underlying.mint(address(hub), amt);
        hub.confirmTake(address(lcc), amt, false);

        hub.processSettlementFor(address(lcc), address(holder), amt);
        uint256 queuedAfter = hub.settleQueue(address(lcc), address(holder));
        uint256 settled = queued - queuedAfter;
        expectedHolderQueued -= settled;
    }

    // ================================================================
    // Actions — transfer with queue annulment
    // ================================================================

    /// @dev Transfer holder LCC to protocol (hub, exempt). Exercises annulSettlementBeforeTransfer.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_02_transfer_to_protocol(uint256 amount) external {
        uint256 bal = lcc.balanceOf(address(holder));
        if (bal == 0) return;
        uint256 amt = (amount % bal) + 1;

        (uint256 wrappedBefore, uint256 marketBefore) = lcc.balancesOf(address(holder));
        uint256 queueBefore = hub.settleQueue(address(lcc), address(holder));
        uint256 totalQueuedBefore = hub.totalQueued(address(lcc));

        uint256 expectedAnnul = _expectedAnnulment(wrappedBefore, marketBefore, queueBefore, amt);

        if (!holder.transfer(address(lcc), address(hub), amt)) return;

        uint256 queueAfter = hub.settleQueue(address(lcc), address(holder));
        uint256 totalQueuedAfter = hub.totalQueued(address(lcc));

        bool ok = true;
        // Queue decreased by exactly the predicted annulment.
        ok = ok && (queueAfter == queueBefore - expectedAnnul);
        // totalQueued decreased by the same amount.
        ok = ok && (totalQueuedAfter == totalQueuedBefore - expectedAnnul);

        expectedHolderQueued = queueAfter;
        checkedTransferAnnuls = true;
        lastTransferAnnulsOk = ok;
    }

    /// @dev Transfer holder LCC to endpoint (BOUND_ENDPOINT). Same annulment path.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_02_transfer_to_endpoint(uint256 amount) external {
        uint256 bal = lcc.balanceOf(address(holder));
        if (bal == 0) return;
        uint256 amt = (amount % bal) + 1;

        (uint256 wrappedBefore, uint256 marketBefore) = lcc.balancesOf(address(holder));
        uint256 queueBefore = hub.settleQueue(address(lcc), address(holder));
        uint256 totalQueuedBefore = hub.totalQueued(address(lcc));

        uint256 expectedAnnul = _expectedAnnulment(wrappedBefore, marketBefore, queueBefore, amt);

        if (!holder.transfer(address(lcc), address(endpoint), amt)) return;

        uint256 queueAfter = hub.settleQueue(address(lcc), address(holder));
        uint256 totalQueuedAfter = hub.totalQueued(address(lcc));

        bool ok = true;
        ok = ok && (queueAfter == queueBefore - expectedAnnul);
        ok = ok && (totalQueuedAfter == totalQueuedBefore - expectedAnnul);

        expectedHolderQueued = queueAfter;
        checkedTransferAnnuls = true;
        lastTransferAnnulsOk = ok;
    }

    // ================================================================
    // Properties — always-on
    // ================================================================

    /// @dev Bucket sum must equal ERC20 balanceOf for the non-exempt holder.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_lcc_02_bucket_sum_equals_balance() external view returns (bool) {
        (uint256 wrapped, uint256 marketDerived) = lcc.balancesOf(address(holder));
        return wrapped + marketDerived == lcc.balanceOf(address(holder));
    }

    /// @dev Holder's queue must match our independently tracked model.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_lcc_02_queue_matches_model() external view returns (bool) {
        return hub.settleQueue(address(lcc), address(holder)) == expectedHolderQueued;
    }

    // ================================================================
    // Properties — action/result (transfer annulment)
    // ================================================================

    /// @dev Non-protocol → protocol transfer must annul queue bleed by exactly the predicted amount.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_lcc_02_transfer_annuls_queue_correctly() external view returns (bool) {
        return !checkedTransferAnnuls || lastTransferAnnulsOk;
    }
}

/// @dev Non-protocol holder for bucket/queue testing.
contract LCC02Holder {
    function transfer(address lcc, address to, uint256 amount) external returns (bool ok) {
        (ok,) = lcc.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
    }

    function unwrapToQueue(address hub, address lcc, uint256 amount) external returns (bool ok) {
        (ok,) = hub.call(
            abi.encodeWithSignature(
                "unwrapTo(address,address,address,uint256)", lcc, address(this), address(this), amount
            )
        );
    }
}
